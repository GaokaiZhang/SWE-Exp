# Complete Experience System Guide

**Last Updated**: 2025-11-25

This document provides a comprehensive explanation of the experience system, covering:
1. How experiences are generated from training trajectories
2. How experiences are retrieved and selected
3. What format is shown to the agent
4. How experiences are evaluated (Docker tests vs string comparison)

---

## Table of Contents

1. [Experience Generation (Training Phase)](#1-experience-generation-training-phase)
2. [Experience Storage Format](#2-experience-storage-format)
3. [Experience Retrieval & Selection](#3-experience-retrieval--selection)
4. [What the Agent Actually Sees](#4-what-the-agent-actually-sees)
5. [Experience Evaluation Method](#5-experience-evaluation-method)
6. [Code Flow Reference](#6-code-flow-reference)
7. [Case Study: django-16901](#7-case-study-django-16901)

---

## 1. Experience Generation (Training Phase)

### Overview

Experiences are extracted from **199 training instances** of the SWE-bench verified dataset. The process:

1. Agent attempts to solve training instance
2. Trajectory (search/view/modify actions) is recorded
3. Agent's patch is compared with golden patch
4. LLM extracts insights based on success/failure

### Generation Process

**Location**: `moatless/experience/exp_agent/exp_agent.py` lines 401-433

```python
def encode_perspective(self, instance_id, rollout, patch, golden_patch, flag):
    """
    Extract experience from a completed trajectory.

    Args:
        instance_id: The SWE-bench instance ID
        rollout: The agent's complete trajectory (actions taken)
        patch: The agent's generated patch
        golden_patch: The correct patch from SWE-bench
        flag: 'success' or 'failed' based on evaluation
    """

    # Load issue description
    issue = issue_type[instance_id]['issue']

    if flag == 'success':
        # Extract positive experience
        prompt = f'''
        Issue: {issue}
        Agent's trajectory: {rollout}
        Successful patch: {patch}

        Extract:
        1. How the agent understood the issue (perspective)
        2. Where the agent correctly located the bug (positioning)
        3. What change pattern was applied (modification)
        '''
    else:  # flag == 'failed'
        # Extract negative experience (reflections)
        prompt = f'''
        Issue: {issue}
        Agent's failed trajectory: {rollout}
        Agent's incorrect patch: {patch}
        Golden patch: {golden_patch}

        Analyze:
        1. How the agent MISunderstood the issue
        2. Where the agent looked in WRONG places
        3. What changes were INCORRECT and why
        '''

    response = llm.complete(prompt)
    return response  # Contains perspective, positioning, modification fields
```

### LLM Prompts for Extraction

#### For Failed Experiences

**System Prompt** (from `moatless/experience/prompts/exp_prompts.py`):

```
You are an expert software engineer analyzing failed debugging attempts to extract
lessons for future problem-solving.

You will receive:
- Issue description: The bug report
- Failed trajectory: Actions the agent took
- Agent's patch: Incorrect code changes
- Golden patch: Correct solution

Your task: Extract 3 reflections for each category:

1. PERSPECTIVE: How did the agent misunderstand the issue?
   - What aspect of the problem did it miss?
   - What false assumptions did it make?
   - What patterns should it have recognized?

2. POSITIONING: Where did the agent look in wrong places?
   - Which files/classes/methods did it incorrectly focus on?
   - Which relevant code did it overlook?
   - Why did it choose the wrong location?

3. MODIFICATION: What code changes were incorrect?
   - Why was the approach wrong?
   - What principle/pattern was violated?
   - What alternative approach should have been used?

Output format:
{
  "perspective": ["reflection 1", "reflection 2", "reflection 3"],
  "positioning": ["reflection 1", "reflection 2", "reflection 3"],
  "modification": ["reflection 1", "reflection 2", "reflection 3"]
}
```

#### For Successful Experiences

```
You are analyzing a successful debugging trajectory to extract generalizable insights.

Extract:
1. PERSPECTIVE: How did the agent correctly understand the issue?
2. ENTRY_POINT: What was the first code element successfully found?
3. MODIFICATION: What abstract pattern/principle led to the correct fix?

Output as structured JSON.
```

### Storage

**File**: `tmp/het/verified_experience_tree.json` (711 KB)

Contains 197 extracted experiences from training instances.

---

## 2. Experience Storage Format

### Raw Experience Structure

#### Failed Experience Example

```json
{
  "django__django-14351": [
    {
      "perspective": [
        "The agent failed to understand that this is fundamentally a GROUP BY clause issue, not just a SELECT clause issue.",
        "The agent misunderstood the root cause by focusing on the `has_select_fields` attribute when the actual issue is about how subqueries are handled in GROUP BY contexts.",
        "The agent didn't recognize the fix requires overriding a specific method (get_group_by_cols) in the lookup class."
      ],
      "positioning": [
        "The agent incorrectly identified the RelatedIn class as the primary location needing modification, when the fix should be in the base In lookup class.",
        "The agent looked at the SQLCompiler class and query.py for modifications when the actual issue was in the lookups.py file.",
        "The agent examined Query.get_compiler() method when the solution required modifying get_group_by_cols()."
      ],
      "modification": [
        "The agent's modification attempted to fix SELECT clause generation by modifying the compiler's as_sql() method, but the golden patch shows the correct approach is to override get_group_by_cols().",
        "The agent added complex conditional logic to check for subqueries in the compilation phase, while the golden patch demonstrates a simple, targeted method override.",
        "The agent's changes affected the general query compilation flow, risking side effects, whereas the golden patch makes a minimal, localized change."
      ],
      "flag": "failed",
      "issue": "Q object __or__ appears to get all dunder related's default columns and queryset raises ProgrammingError..."
    }
  ]
}
```

#### Successful Experience Example

```json
{
  "django__django-12345": [
    {
      "perspective": "The issue involves incorrect XOR parity semantics in Django's fallback SQL generation for databases without native XOR support.",
      "entry_point": {
        "entry": "Class WhereNode | Method as_sql | Query 'XOR connector handling'",
        "reasoning": "Located via searching for XOR SQL generation logic"
      },
      "modification": {
        "experience": [
          "Changed comparison from == 1 (exactly one) to % 2 == 1 (odd parity)",
          "Applied modulo 2 arithmetic for proper XOR semantics",
          "Made minimal change within existing conditional structure"
        ]
      },
      "flag": "success"
    }
  ]
}
```

### Hierarchical Experience Tree (HET)

Each test instance also has a **HET** with 19 refined experience nodes:

**File**: `tmp/experience/{instance_id}/date_experience.json`

```json
{
  "old_experiences": {
    "django__django-14351": { /* selected old experience */ }
  },
  "HET": {
    "1": {
      "perspective": "***Experience 1***: [generalized text for node 1]"
    },
    "2": {
      "perspective": "***Experience 1***: [generalized text for node 2]"
    },
    // ... 19 nodes total
    "3": {
      "perspective": "***Experience 1***: ...",
      "enhanced_modify_instruction": "[Enhanced instruction for modification]",
      "original_modify_instruction": "[Original instruction]"
    }
  },
  "trajectory": "path/to/trajectory.json"
}
```

---

## 3. Experience Retrieval & Selection

### Two-Stage Process

#### Stage 1: Embedding-based Retrieval (Top-10)

**Location**: `moatless/experience/exp_agent/select_agent.py` lines 313-355

```python
def select_workflow(self, n=1) -> Dict:
    """
    Stage 1: Use embedding similarity to get top-10 candidates
    Stage 2: Use LLM to select best n experiences
    """

    # Load all 197 training experiences
    all_experiences = load_json('tmp/het/verified_experience_tree.json')

    # Get current test instance issue
    cur_issue = issue_type[self.instance_id]['issue']

    # Stage 1: Embedding-based retrieval (cosine similarity)
    top_10_candidates = self.screening(
        all_experiences,
        cur_issue,
        top_k=10
    )

    # Stage 2: LLM-based selection
    selected = self.select_perspective(
        top_10_candidates,
        cur_issue,
        n=n  # Usually n=1
    )

    return selected
```

#### Stage 1 Details: Embedding Screening

**Model**: `multilingual-e5-large-instruct`

**Process**:
1. Compute embedding for current issue description
2. Compute embeddings for all 197 training issue descriptions
3. Calculate cosine similarity between current and each training issue
4. Return top-10 most similar experiences

**Code** (lines 123-191):
```python
def screening(self, all_experiences, cur_issue, top_k=10):
    # Encode current issue
    cur_embedding = self.model.encode(
        cur_issue,
        normalize_embeddings=True
    )

    # Encode all training issues
    train_embeddings = self.model.encode(
        [exp['issue'] for exp in all_experiences.values()],
        normalize_embeddings=True
    )

    # Cosine similarity
    similarities = util.cos_sim(cur_embedding, train_embeddings)[0]

    # Get top-10
    top_indices = torch.topk(similarities, k=top_k).indices

    return [experiences[i] for i in top_indices]
```

#### Stage 2 Details: LLM Selection

**Location**: Lines 217-232

**LLM Prompt**:

```
System: You are an AI assistant selecting the most relevant experience from candidates.

Task:
1. Read current GitHub issue
2. Review top-10 candidate experiences
3. Select THE ONE most relevant experience
4. Explain why most applicable

Criteria:
- Problem domain similarity (e.g., both about Q objects, SQL generation)
- Root cause similarity (e.g., both about incorrect logic in fallback)
- Lesson relevance (e.g., avoiding over-engineering)
- Solution approach applicability

User:
Current Issue: django__django-16901 (XOR operations in Q objects with parity issue)

Candidates:
1. django__django-14351 (cosine: 0.842) - Q object subqueries with GROUP BY issue
   Lessons: Don't over-engineer, focus on specific methods, avoid side effects

2. django__django-15280 (cosine: 0.798) - Query optimization in filter operations
   Lessons: Profile before optimizing, focus on bottlenecks

3. [... 8 more ...]

Select the most relevant experience and explain why.
```

**Output**:
```json
{
  "selected_experience_id": "django__django-14351",
  "reasoning": "Although 14351 is about subqueries (different from XOR), it provides valuable negative lessons about Q object operations and SQL generation. The lessons about avoiding over-engineering, focusing on specific methods rather than general compilation, and making minimal localized changes are highly applicable to the XOR issue.",
  "confidence": "high"
}
```

### Result

The system returns **1 selected experience** from the 197 training experiences.

---

## 4. What the Agent Actually Sees

### ⚠️ Critical: The Agent Does NOT See Raw Fields!

The agent **never** sees the structured `perspective`, `positioning`, `modification` fields. Instead:

1. **An LLM adapts the old experience to the current issue**
2. **The result is formatted as simple numbered text**
3. **This text is injected into the task prompt**

### Generalization Process

**Location**: `moatless/experience/exp_agent/select_agent.py` lines 426-470

```python
def generalize_workflow(self, old_experiences: Dict, type: str,
                        history, cur_code, instruction):
    """
    Take old experiences and adapt them to current issue using LLM.

    Args:
        old_experiences: The selected experience(s)
        type: 'perspective' or 'modification'
        cur_code: Current code context (if modification stage)
        instruction: Current instruction (if modification stage)
    """

    cur_issue = issue_type[self.instance_id]['issue']
    new_experiences = []

    for exp in old_experiences.values():
        # Call LLM to generalize the experience
        if type == 'perspective':
            new_exp = self.generalize_perspective(
                pre_issue=exp,
                cur_issue=cur_issue
            )
        elif type == 'modification':
            new_exp = self.generalize_modify(
                pre_issue=exp,
                cur_issue=cur_issue,
                cur_code=cur_code,
                modify_instruction=instruction
            )

        new_experiences.append(new_exp)

    # Format as numbered blocks
    content = ''
    for i, exp in enumerate(new_experiences):
        content += f"***Experience {i + 1}***: {exp['new_experience']}\n"

    return content
```

### Generalization LLM Prompt

**Location**: Lines 234-267

**For Perspective (Search/View stages)**:

```
System:
You are a knowledgeable issue resolution assistant. Your task is to analyze a
current issue and generalize the received experiences into a new insight that
is applicable to this issue.

You will be given:
- A `problem_statement` describing the current issue
- A past trajectory with:
  - `issue_description`: The description of the past issue
  - `experience`: Either a `perspective` (successful understanding) or
    `reflections` (insights from an unsuccessful trajectory)

Your job is to:
1. Compare the current `problem_statement` with the past trajectory's
   `issue_description` and `experience`.
2. Adapt the old experience to the current issue and produce a new applicable
   experience.
3. Identify the most likely entry point in the codebase based on the problem
   statement.

Output format:
{
    "new_experience": "<adapted experience text (1-2 sentences)>",
}

User:
Current issue:
XOR operations on Q objects should use XOR semantics (odd parity) instead of
'exactly one' semantics.

Example:
Client.objects.filter(Q(id=37) ^ Q(id=37) ^ Q(id=37)).count()
Expected: 1 (odd number of True conditions)
Actual: 0 (only when exactly one is True)

Past issue (django__django-14351):
issue_description: Q object __or__ appears to get all dunder related's default
columns and queryset raises ProgrammingError with subquery must return only one
column error.

reflection 1: The agent failed to understand that this is fundamentally a GROUP BY
clause issue, not just a SELECT clause issue. The golden patch shows the fix
should be in a specific method (get_group_by_cols), not general SQL compilation.

reflection 2: The agent misunderstood the root cause by focusing on wrong
attributes (has_select_fields, default_cols) when the actual issue is about
proper column handling in GROUP BY contexts for subqueries in IN lookups.

reflection 3: The agent incorrectly assumed the problem was specific to RelatedIn
lookups when the golden patch shows the fix belongs in the base In lookup class,
indicating this is a more general issue.

Adapt these reflections to provide guidance for the current XOR issue.
```

**LLM Output (what agent will see)**:

```json
{
  "new_experience": "When dealing with XOR operations in Q objects on databases without native XOR support, the issue lies in Django's fallback SQL generation logic that incorrectly implements multiple XOR operations as 'exactly one' instead of 'odd parity'. The fix should be in the query compilation layer where XOR operations are converted to equivalent SQL expressions, specifically in how the XOR connector is handled when there are more than 2 operands - it needs to generate SQL that evaluates to true when an odd number of conditions are true, not just when exactly one condition is true."
}
```

### Injection into Agent Prompt

**Location**: `moatless/experience/instructor.py` line 70

```python
def _instruct_with_retry(self, input_messages, exp, node_id):
    messages = input_messages.copy()
    messages.insert(0, {"role": "system", "content": self.system_prompt})

    # THE KEY LINE: Experience is injected here
    message = f'<task>\n{self.task}\n{exp}\n' \
              f'You MUST do code modification and finish the task within max ' \
              f'{str(self.taken_actions)} actions.\n</task>\n' \
              f'This is the {node_id}-th actions.'

    messages.append({"role": "user", "content": message})
    ...
```

### What Agent Receives (Complete Format)

#### At Search/View Stages

```xml
<task>
You are asked to fix the following issue in the Django codebase:

XOR operations on Q objects should use XOR semantics (odd parity) instead of
'exactly one' semantics.

Example:
>>> Client.objects.filter(Q(id=37) ^ Q(id=37) ^ Q(id=37)).count()
0  # Expected: 1 (odd number of True conditions)

The issue is in the fallback SQL generation for databases without native XOR
support (like PostgreSQL). The current implementation checks if exactly one
condition is true ((a + b + c) == 1), but XOR semantics should check if an
odd number of conditions are true ((a + b + c) % 2 == 1).

Here are some experiences you can refer to:
***Experience 1***: When dealing with XOR operations in Q objects on databases
without native XOR support, the issue lies in Django's fallback SQL generation
logic that incorrectly implements multiple XOR operations as 'exactly one'
instead of 'odd parity'. The fix should be in the query compilation layer where
XOR operations are converted to equivalent SQL expressions, specifically in how
the XOR connector is handled when there are more than 2 operands - it needs to
generate SQL that evaluates to true when an odd number of conditions are true,
not just when exactly one condition is true.

You MUST do code modification and finish the task within max 20 actions.
</task>
This is the 1-th actions.

<instruction>
[Instructor's specific action instruction based on current state]
</instruction>

<environment>
[Current file context, search results, etc.]
</environment>
```

#### At Modification Stage (Enhanced)

When `ty == 'modify'`, the instruction is further enhanced:

**Location**: `moatless/agent/agent.py` lines 157-165

```python
if experiencer and ty == 'modify':
    code = "".join(m['content'] for m in messages if m['role'] == 'tool')
    enhanced_instruction = experiencer.polish_workflow(
        old_experiences,
        type='modification',
        history=code,
        instruction=instruction
    )
    instruction = enhanced_instruction
```

**Original Instruction (from Instructor)**:
```
Modify the XOR fallback logic in the WhereNode.as_sql method to implement proper
parity checking instead of exactly-one checking. Change the condition from
checking if the sum equals 1 to checking if the sum modulo 2 equals 1.
```

**Enhanced Instruction (with experience)**:
```
Locate the WhereNode.as_sql method and modify the XOR fallback logic to implement
proper parity checking. Instead of checking if the sum equals 1 (exactly-one
logic), change the condition to check if the sum modulo 2 equals 1, which will
correctly return true when an odd number of conditions are true. Focus
specifically on the XOR operation handling within the existing conditional
structure without adding complex logic or modifying unrelated query generation
phases.
```

**Enhancements from experience**:
- ✅ "Locate the WhereNode.as_sql method" - More specific
- ✅ "within the existing conditional structure" - Don't restructure (from failed experience)
- ✅ "without adding complex logic" - Keep it simple (from failed experience)
- ✅ "or modifying unrelated query generation phases" - Avoid side effects (from failed experience)

---

## 5. Experience Evaluation Method

### ⚠️ CRITICAL FINDING: Training vs Testing Evaluation Discrepancy

**Major Discovery**: The training and testing phases use **completely different evaluation methods**!

| Phase | Instances | Docker Evaluation? | How "Resolved" Determined | Success Rate |
|-------|-----------|-------------------|---------------------------|--------------|
| **Training** | 199 | ✅ **YES** (now default) | Docker tests determine `resolved` field | To be measured (~50 hours) |
| **Testing** | 30 | ✅ **YES** | Docker tests (SWE-bench testbed) | 56.7% (17/30 baseline) |

**Current Pipeline Behavior (UPDATED)**:
- **Training evaluation**: NOW ENABLED by default in Stage 1.5 (~50 hours)
- **Training experiences**: Mixed SUCCESS/FAILURE based on actual Docker test results
- **Testing results**: Based on actual test pass/fail (Docker execution)
- **Correct experience classification**: Both training and testing use Docker evaluation

**Configuration Options**:
- **Default (Recommended)**: Stage 1.5 ENABLED - Gets correct labels for all training instances
- **Fast Mode**: Comment out Stage 1.5 - Saves 50 hours but uses failure-only experiences
- **CRITICAL**: Stage 1.5 must run AFTER Stage 1 but BEFORE Stages 2-3 (experience extraction)
- See `QUICKSTART.md` section "Understanding Training Evaluation" for details

---

### The Training Evaluation Gap

#### Source: Original Repository Design

**This is from the original SWE-Exp repository**. The code expects a `resolved` field from Docker evaluation but doesn't mandate it.

**Our Pipeline Modification**: We added Stage 1.5 (ENABLED by default) to run Docker evaluation on training instances. Stage 1.5 runs AFTER trajectory collection (Stage 1) but BEFORE experience extraction (Stages 2-3). This ensures correct SUCCESS/FAILURE classification for all 199 training experiences. Users can comment it out to save ~50 hours but will get failure-only experiences.

**Evidence**: All code references below are from the original repository files.

#### What the Code Expects

**Location**: `moatless/experience/exp_agent/exp_agent.py` lines 401-435

```python
for i in eval:
    if i.get('resolved') == True:  # ← Expects Docker test results
        # Extract successful experience
        flag = 'success'
        break

# If no resolved=True found
if flag == False:
    # Extract failure experience using golden patch
    answer = perspective_agent.encode_perspective(
        instance_id, rollout=trajectory, patch=golden_patch, flag='failed'
    )
```

The code **expects** a `resolved` field from Docker evaluation.

#### How Experiences Are Actually Extracted (LLM-based)

When `flag='failed'` (no resolved field found), the code calls:

**Location**: `moatless/experience/exp_agent/exp_agent.py` lines 428-433

```python
if flag == False:
    rollout = get_failed_rollout(tree, True)
    trajectory = get_trajectory(rollout)
    # Pass GOLDEN PATCH to LLM for analysis
    answer = perspective_agent.encode_perspective(
        instance_id,
        rollout=trajectory[0],
        patch=golden_patch,  # ← The correct solution
        flag='failed'
    )
```

**The encode_perspective method** (lines 174-197):

```python
def encode_perspective(self, instance_id, rollout, patch, flag):
    issue_type = get_json(self.issue_type_path)
    issue = issue_type[instance_id]['issue']

    # Build prompt for LLM
    user_prompt = f'''
<issue>
{issue}
</issue>

<golden_patch>
{patch}  # ← The correct solution
</golden_patch>

<trajectory>
{rollout}  # ← What the agent actually did
</trajectory>
'''

    if flag == 'success':
        system_prompt = self.success_per_system_prompt
    else:
        system_prompt = self.failed_per_system_prompt  # ← Used for training

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt}
    ]
    return self._chat_with_retry(messages)
```

**The LLM prompt for failed experiences** (`moatless/experience/prompts/exp_prompts.py` lines 87-117):

```python
encode_failed_perspective_system_prompt = '''
You are a bug resolution expert. You will be given a software issue,
the corresponding golden patch and a trajectory that represents how
an agent attempted to resolve this issue but failed.

## Guidelines
You need to extract some reflections from this failed trajectory
according to the golden patch:

1. **reflections** - three reflections on why this trajectory failed:
    - `Perspective`: Explain how should you correctly understand the
      issue according to the golden patch.
    - `Positioning`: Explain how should you correctly identify the code
      that needed to be modified according to the golden patch.
    - `Modification`: If the trajectory correctly identified the
      modification location, what mistakes were made in actual code
      modification?

## Important Notes:
    - Reflections should be at the level of thinking, not specific
      implementation details.
    - Reflections should be expressed in as generalized and abstract
      terms as possible.
    - Be comprehensive and detailed as possible.
    - Do not include specific object names in the output.

Your output must strictly follow the JSON format shown below:
{
    "perspective": [
        "<one key reflection>",
        ...
    ],
    "positioning": [
        "<one key reflection>",
        ...
    ],
    "modification": [
        "<one key reflection>",
        ...
    ]
}
'''
```

**Key insight**: The LLM analyzes the **trajectory** (agent's actions) vs **golden patch** (correct solution) to extract lessons. There's NO explicit string comparison code - the comparison happens inside the LLM's reasoning.

#### What Actually Happens for Training

**Location**: `pipeline.sh` lines 144-146

```bash
################################################################################
# STAGE 3: BUILD EXPERIENCE TREE FROM 199 TRAIN INSTANCES
################################################################################

# Prepare evaluation file for exp_agent.py
log_info "Preparing evaluation file from train baseline..."
cp django/train_baseline.jsonl tmp/merged_leaf_analysis_with_trajectories.jsonl
```

**Problem**: This just **copies** the prediction file (patches only), without running evaluation!

**Result**:
1. Training file has NO `resolved` field
2. Code defaults all instances to `flag='failed'`
3. All 197 experiences extracted as "failure" experiences
4. Based on **LLM analysis comparing trajectory with golden patch**, not Docker test results

#### Why This Design?

**Possible reasons**:

1. **Time/Cost Savings**: Evaluating 199 instances would take ~50 hours (199 × 15 min per instance)
2. **LLM-based Analysis**: An LLM can analyze trajectories vs golden patches to extract lessons without running actual tests
3. **Training vs Testing Goals**: Training is for learning patterns (what went wrong), testing is for measuring performance (did it work)

#### The Problem

**Issue**: Without Docker tests, we don't know if training patches actually work!

The LLM extracts "failure" experiences by comparing:
- Agent's trajectory (what actions it took)
- Golden patch (the correct solution)

But the LLM has no way to know if the agent's approach **would have passed tests** - it only knows the approach was **different from the golden patch**.

**Example**: Multiple valid solutions

```python
# Approach 1: Agent's trajectory led to this
if sum % 2 == 1:
    return True

# Approach 2: Golden patch uses this
if sum & 1:  # Bitwise check for odd
    return True
```

**LLM analysis**: "Agent used modulo operator instead of bitwise operation"
**Reality**: Both approaches are correct and would pass tests!
**Experience extracted**: "failure" experience (possibly incorrect!)

**Real implications**:
- Training "failures" might actually pass tests (false negatives)
- Experience system learning from **differences**, not from actual failures
- Unknown if extracted lessons are based on real mistakes or just alternative approaches

---

### The Testing Evaluation (Confirmed)

#### Evidence

**Files**:
- `DeepSeek_IA.eval_test_baseline_20251124_210424.json`
- `DeepSeek_IA.eval_test_with_experience_20251125_043605_20251125_144917.json`

```json
{
  "resolved_ids": [
    "django__django-16255",
    "django__django-16333",
    ...
  ],
  "unresolved_ids": [...],
  "completed_ids": [...]
}
```

**Results**:
- Baseline: 17/29 resolved (58.6%)
- With experience: 15/27 resolved (55.6%)

#### Docker Test Execution for Testing

Test instances ARE evaluated with Docker tests via SWE-bench testbed.

**Location**: `moatless/runtime/testbed.py` line 237

```python
def run_evaluation(self, patch: str) -> EvaluationResult:
    """
    Apply patch and run Docker tests to determine if issue is resolved.

    Returns:
        EvaluationResult with:
        - resolved: True if ResolvedStatus.FULL (all tests pass)
        - test_results: Individual test pass/fail status
        - error: Any errors during evaluation
    """

    # Apply the agent's patch
    self.apply_patch(patch)

    # Run tests in Docker container using SWE-bench testbed
    response = self._request("POST", "run-evaluation")

    # Parse test results
    test_status = self.test_spec.get_pred_report(response.output)

    return EvaluationResult(
        resolved=(test_status.status == ResolvedStatus.FULL),
        test_output=response.output,
        ...
    )
```

### Docker Test Execution

**Uses**: SWE-bench Testbed SDK

**Location**: `src/moatless-testbeds/testbeds/sdk/client.py` lines 364-432

```python
class TestbedClient:
    def run_evaluation(self, patch: str) -> EvaluationResult:
        """
        Execute evaluation in Docker container.

        Process:
        1. Create isolated Docker environment with Django repo
        2. Apply patch to the codebase
        3. Run instance-specific tests (e.g., tests/queries/test_q.py::XORTests)
        4. Parse test output to determine pass/fail
        5. Return ResolvedStatus: FULL, PARTIAL, or NO
        """

        # Apply patch to Docker container
        self.apply_patch(patch)

        # Run tests
        self._request("POST", "run-evaluation")

        # Get test results
        test_status = self.test_spec.get_pred_report(response.output)

        # Determine resolved status
        if test_status.status == ResolvedStatus.FULL:
            resolved = True  # All tests pass
        elif test_status.status == ResolvedStatus.PARTIAL:
            resolved = False  # Some tests pass, some fail
        else:  # ResolvedStatus.NO
            resolved = False  # All tests fail or error

        return EvaluationResult(resolved=resolved, ...)
```

### ResolvedStatus Criteria

```python
class ResolvedStatus(Enum):
    FULL = "FULL"      # All tests pass ✅
    PARTIAL = "PARTIAL"  # Some tests pass, some fail ⚠️
    NO = "NO"          # All tests fail or error ❌
```

**For test instances**:
```python
# After Docker evaluation
if resolved_status == FULL:
    resolved = True   # Instance marked as resolved ✅
else:
    resolved = False  # Instance marked as unresolved ❌
```

**For training instances** (no Docker evaluation):
```python
# No 'resolved' field in file
flag = 'failed'  # Default all to failed

# LLM extracts experience by comparing:
# - Agent's trajectory
# - Golden patch
# Output: perspective/positioning/modification reflections
```

---

### Summary: Training vs Testing Evaluation

#### Training Phase Workflow
```
199 instances
    ↓
Agent generates patches → Save to train_baseline.jsonl
    ↓
❌ SKIP Docker evaluation (save time/cost)
    ↓
Copy to merged_leaf_analysis_with_trajectories.jsonl
    ↓
Experience extraction code checks for 'resolved' field
    ↓
No 'resolved' field found → Default all to flag='failed'
    ↓
LLM compares agent's trajectory with golden patch
    ↓
LLM extracts perspective/positioning/modification reflections
    ↓
Store as "failure" experiences for all 197 instances
    ↓
Store in verified_experience_tree.json
```

#### Testing Phase Workflow
```
30 instances
    ↓
Agent generates patches (baseline + with-experience)
    ↓
Save to test_baseline.jsonl and test_with_experience_*.jsonl
    ↓
✅ Run evaluate.sh → Docker tests in SWE-bench testbed
    ↓
Tests execute → Determine ResolvedStatus (FULL/PARTIAL/NO)
    ↓
resolved = True if FULL, else False
    ↓
Save results to eval_*.json with resolved_ids list
    ↓
Measure: 17/29 baseline (58.6%), 15/27 with-experience (55.6%)
```

#### Key Differences

| Aspect | Training | Testing |
|--------|----------|---------|
| **Patch generation** | ✅ Yes | ✅ Yes |
| **Docker evaluation** | ❌ **NO** | ✅ **YES** |
| **Evaluation basis** | LLM analysis (trajectory vs golden) | Actual test execution |
| **'resolved' field** | ❌ Missing | ✅ Present |
| **Flag determination** | Default to 'failed' | Based on test results |
| **Known success rate** | ❓ Unknown | ✅ 58.6% baseline |
| **Time cost** | ~0 hours (skipped Docker) | ~7.5 hours (30 × 15 min) |
| **Purpose** | Learn patterns from differences | Measure actual performance |

#### Why String Comparison is NOT Sufficient

**String comparison is NOT used for test evaluation because**:
1. Different patches can achieve the same fix (functionally equivalent)
2. Line numbers/whitespace may differ
3. Variable names may differ
4. Code style may differ
5. Multiple valid solutions may exist

**Example**:
```python
# Agent patch (functionally correct)
rhs = Exact(1, Mod(rhs_sum, 2))

# Golden patch (functionally identical)
rhs = Exact(1, rhs_sum % 2)

# String comparison: ❌ DIFFERENT
# Docker tests: ✅ BOTH PASS
```

### Evaluation Workflow

```
Training Phase:
1. Agent generates patch
2. Docker testbed applies patch
3. Docker runs tests (pytest, Django test suite, etc.)
4. Tests pass → flag='success', extract positive experience
   Tests fail → flag='failed', extract negative experience (reflections)
5. Store experience in verified_experience_tree.json

Testing Phase:
1. Agent generates patch
2. Docker testbed applies patch
3. Docker runs tests
4. resolved=True → Issue resolved ✅
   resolved=False → Issue not resolved ❌
```

### Training vs Testing Evaluation

| Phase | Evaluated? | Method | Purpose |
|-------|-----------|--------|---------|
| **Training (199 instances)** | ❌ **NOT evaluated** | String comparison with golden patch (no Docker) | Experience extraction based on patch comparison |
| **Testing (30 instances)** | ✅ **YES** | Docker tests (SWE-bench testbed) | Measure actual success rate |

**Important Discovery** (from `ANSWER_why_no_train_evaluation.md`):

The original workflow did NOT run Docker evaluation for training instances:

```bash
# pipeline.sh lines 144-146
# STAGE 3: BUILD EXPERIENCE TREE FROM 199 TRAIN INSTANCES

# Prepare evaluation file for exp_agent.py
log_info "Preparing evaluation file from train baseline..."
cp django/train_baseline.jsonl tmp/merged_leaf_analysis_with_trajectories.jsonl
# ← Just copies, no evaluation!
```

**Result**:
- Training experiences marked as "failed" based on patch ≠ golden patch (string comparison)
- Unknown if training patches would actually pass/fail tests
- Experience quality uncertain (might learn from false negatives)

**Test instances confirmed evaluated**: 17/29 (58.6%) baseline success via Docker tests.

---

## 6. Code Flow Reference

### Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ TRAINING PHASE (199 instances)                              │
├─────────────────────────────────────────────────────────────┤
│ 1. stage1.sh: Generate patches (train_baseline.jsonl)      │
│ 2. Compare patches with golden patches (string comparison) │
│ 3. exp_agent.py: Extract experiences via LLM               │
│    ├─ encode_perspective() if flag='failed'                │
│    └─ encode_perspective() if flag='success'               │
│ 4. Store in verified_experience_tree.json (197 exp)        │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ TESTING PHASE (30 instances) - WITH EXPERIENCE             │
├─────────────────────────────────────────────────────────────┤
│ 1. select_agent.py: Select relevant experience             │
│    ├─ screening(): Cosine similarity (197 → 10)            │
│    └─ select_perspective(): LLM selection (10 → 1)         │
│                                                              │
│ 2. select_agent.py: Generalize experience                  │
│    ├─ generalize_workflow()                                │
│    ├─ generalize_perspective() [LLM adapts to cur issue]   │
│    └─ Format as "***Experience N***: [text]"               │
│                                                              │
│ 3. agent.py: Build action with experience                  │
│    ├─ exp = 'Here are some experiences...'                 │
│    ├─ exp += generalize_workflow(old_experiences)          │
│    └─ instructor.instruct(messages, exp, node_id)          │
│                                                              │
│ 4. instructor.py: Inject experience into prompt            │
│    └─ message = f'<task>\n{task}\n{exp}\n...'              │
│                                                              │
│ 5. Agent executes action                                   │
│                                                              │
│ 6. If ty=='modify': Polish instruction                     │
│    └─ experiencer.polish_workflow() [enhance with exp]     │
│                                                              │
│ 7. Generate patch                                           │
│                                                              │
│ 8. testbed.py: Run Docker evaluation                       │
│    ├─ Apply patch to Docker container                      │
│    ├─ Run tests (pytest/Django test suite)                 │
│    └─ resolved = (status == ResolvedStatus.FULL)           │
└─────────────────────────────────────────────────────────────┘
```

### Key Files and Line Numbers

| File | Lines | Function | Purpose |
|------|-------|----------|---------|
| **Experience Generation** ||||
| `exp_agent/exp_agent.py` | 401-433 | `encode_perspective()` | Extract insights from trajectories |
| `exp_agent/prompts.py` | 1-50 | `encode_failed_perspective_system_prompt` | LLM prompt for extraction |
| **Experience Selection** ||||
| `select_agent.py` | 313-355 | `select_workflow()` | Two-stage selection process |
| `select_agent.py` | 123-191 | `screening()` | Embedding-based top-10 |
| `select_agent.py` | 217-232 | `select_perspective()` | LLM-based selection |
| **Experience Generalization** ||||
| `select_agent.py` | 426-470 | `generalize_workflow()` | Adapt experience to current issue |
| `select_agent.py` | 234-267 | `generalize_perspective()` | LLM generalization for perspective |
| `select_agent.py` | 313-380 | `generalize_modify()` | LLM generalization for modification |
| **Experience Injection** ||||
| `agent/agent.py` | 112 | Initialize | `exp = 'Here are some experiences...'` |
| `agent/agent.py` | 115-130 | Generate | `generalize_workflow()` call |
| `agent/agent.py` | 139 | Pass to instructor | `instructor.instruct(messages, exp, node_id)` |
| `instructor.py` | 70 | Inject | `message = f'<task>\\n{task}\\n{exp}\\n...'` |
| **Modification Enhancement** ||||
| `agent/agent.py` | 157-165 | Polish instruction | `polish_workflow()` for modify stage |
| **Evaluation** ||||
| `runtime/testbed.py` | 237 | Run tests | `run_evaluation(patch)` |
| `testbeds/sdk/client.py` | 364-432 | Docker execution | SWE-bench testbed API |

---

## 7. Case Study: django-16901

### The Problem

XOR operations on Q objects incorrectly use "exactly one" semantics instead of "odd parity" semantics.

```python
# Expected behavior (XOR = odd parity)
Client.objects.filter(Q(id=37)).count()  # → 1 (1 true)
Client.objects.filter(Q(id=37) ^ Q(id=37)).count()  # → 0 (2 trues, even)
Client.objects.filter(Q(id=37) ^ Q(id=37) ^ Q(id=37)).count()  # → 1 (3 trues, odd) ✅

# Actual behavior (bug: exactly one)
Client.objects.filter(Q(id=37) ^ Q(id=37) ^ Q(id=37)).count()  # → 0 ❌
```

### Experience Selection

**Top-10 Screening**: django-14351 ranked high (cosine similarity: 0.842)
- Issue: Q object subqueries with GROUP BY problems
- Flag: failed
- Perspective: 3 reflections on misunderstandings

**LLM Selection**: Chose django-14351
- Reasoning: Although different issue (subqueries vs XOR), provides valuable lessons about Q object operations, SQL generation, avoiding over-engineering, and focusing on specific methods

### Generalized Experience

**Raw experience** (django-14351):
```json
{
  "perspective": [
    "The agent failed to understand that this is fundamentally a GROUP BY clause issue, not SELECT.",
    "The agent misunderstood root cause by focusing on wrong attributes.",
    "The agent didn't recognize fix requires overriding specific method in lookup class."
  ],
  "positioning": [
    "Agent incorrectly identified RelatedIn class when fix should be in base In lookup.",
    "Agent looked at SQLCompiler and query.py when issue was in lookups.py.",
    "Agent examined Query.get_compiler() when solution required get_group_by_cols()."
  ],
  "modification": [
    "Agent modified compiler's as_sql() but golden patch overrides get_group_by_cols().",
    "Agent added complex conditional logic; golden patch is simple method override.",
    "Agent's changes affected general flow; golden patch is minimal, localized."
  ]
}
```

**Generalized for django-16901** (what agent sees):
```
***Experience 1***: When dealing with XOR operations in Q objects on databases
without native XOR support, the issue lies in Django's fallback SQL generation
logic that incorrectly implements multiple XOR operations as 'exactly one'
instead of 'odd parity'. The fix should be in the query compilation layer where
XOR operations are converted to equivalent SQL expressions, specifically in how
the XOR connector is handled when there are more than 2 operands - it needs to
generate SQL that evaluates to true when an odd number of conditions are true,
not just when exactly one condition is true.
```

**Key adaptations**:
- Changed from "GROUP BY issue" to "XOR parity issue"
- Changed from "lookup class" to "query compilation layer"
- Changed from "get_group_by_cols()" to "XOR connector handling"
- Kept core lessons: specific method focus, avoid general changes, minimal modification

### Baseline vs With-Experience Comparison

| Aspect | Baseline (Failed) | With Experience (Success) |
|--------|-------------------|---------------------------|
| **Nodes** | 6 | 8 |
| **Search queries** | Generic ("XOR operations Q objects") | Specific ("XOR connector logic... multiple operands") |
| **Verification** | None (guessed Mod location) | ViewCode (2×) to confirm |
| **Import placement** | Inside method (line 138) ❌ | Module level (line 14) ✅ |
| **Import module** | `expressions` (wrong) | `functions.math` (correct) |
| **Result** | Tests FAILED | Tests PASSED ✅ |

### Critical Success Factor

**The ONE difference that mattered**: Import placement

**Baseline**:
```python
def as_sql(self, compiler, connection):
    if self.connector == XOR and not connection.features.supports_logical_xor:
        from django.db.models.expressions import Mod  # ❌ Inside method
        ...
        rhs = Exact(1, Mod(rhs_sum, 2))
```

**With Experience**:
```python
# At top of file (line 14)
from django.db.models.functions.math import Mod  # ✅ Module level

def as_sql(self, compiler, connection):
    if self.connector == XOR and not connection.features.supports_logical_xor:
        ...
        rhs = Exact(1, Mod(rhs_sum, 2))
```

**Why this matters**:
1. ✅ Follows Python PEP 8 conventions
2. ✅ Follows Django project style
3. ✅ Avoids circular import issues
4. ✅ No runtime import overhead
5. ✅ Tests pass!

### How Experience Helped

1. **Better search queries**: Experience taught "XOR connector" and "multiple operands" terminology
2. **Verification steps**: Used ViewCode to confirm Mod location (baseline skipped this)
3. **Best practices**: Placed import at module level (experience lesson: "minimal, localized changes")
4. **Avoided pitfalls**: Didn't over-engineer or modify unrelated code (experience lesson)

### Result

- ✅ With-experience patch: All Docker tests PASSED
- ❌ Baseline patch: Docker tests FAILED
- **+1 resolved issue**

---

## 8. Understanding the Hierarchical Experience Tree (HET)

### What is the HET?

The HET (Hierarchical Experience Tree) is a per-instance JSON file that stores experience-related data as the search tree expands. Despite its name, it's **not actually hierarchical** - it's a flat mapping of search tree node IDs to experience data.

**Location**: `tmp/experience/{instance_id}/YYYY-MM-DD_experience.json`

### HET Structure

```json
{
  "old_experiences": {
    "django__django-14351": {
      "perspective": [...],
      "positioning": [...],
      "modification": [...],
      "flag": "failed",
      "issue": "..."
    }
  },
  "HET": {
    "1": {
      "perspective": "***Experience 1***: When dealing with XOR operations..."
    },
    "2": {
      "perspective": "***Experience 1***: When dealing with XOR operations..."
    },
    "3": {
      "perspective": "***Experience 1***: When dealing with XOR operations...",
      "original_modify_instruction": "Modify the XOR fallback logic...",
      "enhanced_modify_instruction": "Locate WhereNode.as_sql and modify..."
    },
    // ... nodes 4-19
  },
  "trajectory": "tmp/trajectory/django__django-16901/2025-11-25_trajectory.json"
}
```

### Key Components

1. **`old_experiences`**: The base experience selected from the 197 training experiences (selected once via cosine similarity + LLM)

2. **`HET`**: A mapping of search tree node IDs to experience data:
   - Key: String representation of node ID (e.g., "1", "3", "19")
   - Value: Experience data for that specific node

3. **`trajectory`**: Path to the search tree trajectory file

### What Gets Stored in Each HET Node

**Location**: `moatless/agent/agent.py` lines 110-195

```python
# For every node:
persist_exp = {}

# ALWAYS stored (all nodes):
persist_exp['perspective'] = perspective  # Generalized experience text

# ONLY stored when ty == 'modify' (modification nodes):
persist_exp['original_modify_instruction'] = instruction
persist_exp['enhanced_modify_instruction'] = enhanced_instruction

# Save to HET
het['HET'][str(node.node_id)] = persist_exp
```

### How the Perspective is Generated and Reused

#### Node 1 (First Node Only)

**Location**: `moatless/agent/agent.py` lines 114-118

```python
if len(messages) == 1:  # First conversation turn
    # Generate NEW perspective via LLM
    new_experiences = experiencer.generalize_workflow(
        old_experiences,
        type='perspective',
        history=None,
        cur_code=None,
        instruction=None
    )
    persist_exp['perspective'] = new_experiences
    # This gets saved to HET['1']
```

**Process**:
1. Takes the base experience from `old_experiences`
2. Calls `generalize_workflow()` which uses an LLM to adapt it to the current issue
3. Returns formatted text: `"***Experience 1***: When dealing with XOR..."`
4. Saves to `HET['1']['perspective']`

#### All Other Nodes (2, 3, 5, 19...)

**Location**: `moatless/agent/agent.py` lines 119-130

```python
else:  # All subsequent nodes (len(messages) > 1)
    # REUSE cached perspective from HET['1']
    if het and 'HET' in het and '1' in het['HET'] and 'perspective' in het['HET']['1']:
        perspective = het['HET']['1']['perspective']  # ← READ from HET['1']
        persist_exp['perspective'] = perspective       # ← COPY to current node
        new_experiences = perspective
```

**Process**:
1. Load existing HET file from disk
2. Read `HET['1']['perspective']` (the cached perspective)
3. Copy it to the current node's `persist_exp`
4. No LLM call - pure cache reuse

### Modification Instruction Enhancement

When the agent wants to modify code (`ty == 'modify'`), additional processing happens:

**Location**: `moatless/agent/agent.py` lines 157-165

```python
if experiencer and ty == 'modify':
    code = "".join(m['content'] for m in messages if m['role'] == 'tool')

    # Generate enhanced instruction using experience
    enhanced_instruction = experiencer.polish_workflow(
        old_experiences,
        type='modification',
        history=code,
        instruction=instruction
    )

    # Store both versions
    persist_exp['original_modify_instruction'] = instruction
    persist_exp['enhanced_modify_instruction'] = enhanced_instruction

    # USE the enhanced version
    instruction = enhanced_instruction
```

**Key insight**: The enhanced instruction is used immediately for the agent's action, then stored for logging/analysis purposes.

### What the Agent Actually Sees

**Critical Point**: The agent ONLY receives the perspective from `HET['1']` in its prompt. It never reads other HET nodes during execution.

**Location**: `moatless/agent/agent.py` line 139

```python
# Experience is automatically injected into every prompt
reason, instruction, context, ty = instructor.instruct(
    messages,
    exp + new_experiences,  # ← Experience text here (always from HET['1'])
    node.node_id
)
```

Then in `instructor.py` line 70:
```python
message = f'<task>\n{self.task}\n{exp}\n...'  # ← Injected into task prompt
```

### The Redundancy Issue

**The perspective is identical across all nodes!**

Looking at actual HET data:
```json
"HET": {
    "1": {
        "perspective": "***Experience 1***: When dealing with XOR..."
    },
    "2": {
        "perspective": "***Experience 1***: When dealing with XOR..."  // ← SAME
    },
    "3": {
        "perspective": "***Experience 1***: When dealing with XOR...",  // ← SAME
        "original_modify_instruction": "...",
        "enhanced_modify_instruction": "..."
    }
}
```

**Why store it redundantly?**
- Historical artifact of the design
- Simplifies node-level tracking (each node has complete data)
- Minimal storage cost (text compression, JSON doesn't deduplicate)

### The Real Value of HET

#### For the Agent (During Execution)
- **Only `HET['1']['perspective']` matters** - generated once, reused forever
- **Enhanced instructions** - used immediately at modification nodes
- **No other HET nodes are read during execution**

#### For Analysis/Debugging (Post-Execution)
- **Trace experience impact**: Compare `original_modify_instruction` vs `enhanced_modify_instruction`
- **Understand decision-making**: See what guidance was provided at each node
- **Debug failures**: Analyze if experience enhancement helped or hurt
- **Research insights**: Study how experiences are applied across different search states

### HET Update Flow

```
[Search Tree selects Node N to expand]
    ↓
[Agent.run() called with node N]
    ↓
Load existing HET from disk
    ↓
If N is first node (len(messages) == 1):
    ├─ LLM call: generalize_workflow()
    ├─ Generate new perspective
    └─ persist_exp['perspective'] = new_perspective
Else (all other nodes):
    ├─ Read HET['1']['perspective']
    └─ persist_exp['perspective'] = cached_perspective
    ↓
If modification action (ty == 'modify'):
    ├─ LLM call: polish_workflow()
    ├─ Generate enhanced_instruction
    ├─ persist_exp['original_modify_instruction'] = instruction
    ├─ persist_exp['enhanced_modify_instruction'] = enhanced
    └─ Use enhanced for actual action
    ↓
Save to HET: het['HET'][str(N)] = persist_exp
    ↓
Write entire HET to disk
```

### Summary: HET Purpose

| Component | Purpose | Used By | Frequency |
|-----------|---------|---------|-----------|
| **`old_experiences`** | Store base selected experience | Analysis | Once (initial selection) |
| **`HET['1']['perspective']`** | Cache generalized experience | Agent (all nodes) | Generated once, read many times |
| **`HET[N]['perspective']`** (N>1) | Redundant copy of HET['1'] | Analysis/logging | Every node (redundant) |
| **`HET[N]['*_modify_instruction']`** | Record enhancement impact | Analysis/debugging | Only modification nodes |
| **`trajectory`** | Link to search tree | Analysis | Reference |

**Bottom line**: The HET is primarily a **logging and analysis artifact**. The agent's actual experience guidance comes from `HET['1']['perspective']` which is generated once and cached. The rest of the tree stores redundant copies of this perspective plus modification instruction pairs for post-hoc analysis.

---

## Summary

The experience system works by:

1. **Generating** experiences from training trajectories via LLM extraction
2. **Storing** structured experiences (perspective/positioning/modification) in JSON
3. **Selecting** relevant experiences via embedding similarity + LLM
4. **Generalizing** experiences via LLM to adapt to current issue
5. **Injecting** generalized text (NOT raw fields) into agent prompts
6. **Enhancing** modification instructions with experience-based guidance
7. **Maintaining** HET for logging and analysis (one cached perspective, reused everywhere)
8. **Evaluating** via Docker tests (for test instances) to measure success

The agent receives simple, numbered experience text (`***Experience 1***: ...`), not structured JSON with field names. This allows the system to store detailed lessons while presenting concise, adapted guidance. The HET structure stores this guidance redundantly across nodes for analysis purposes, but the agent always uses the same cached perspective from node 1.
