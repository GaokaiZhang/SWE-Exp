# SWE-Exp Quickstart

## Objective
Compare 30 test instances solved **without** vs **with** experience learned from 199 train instances.

## Prerequisites

### Required Files
```
SWE-Exp/
├── .env                    # ANTHROPIC_API_KEY=sk-ant-...
├── train_instances.txt     # 199 train instance IDs (one per line)
├── instances_fail.txt      # 2 failed train instance IDs
└── test_instances.txt      # 30 test instance IDs (one per line)
```

### Setup
```bash
# 1. Install dependencies
conda env create -f environment.yml
conda activate swe-exp

# 2. Configure API key
echo "ANTHROPIC_API_KEY=sk-ant-..." > .env
```

## Complete Pipeline

### Stage 1: Trajectory Collection (WITHOUT Experience)

Collect baseline trajectories and patches without any prior experience.

```bash
# Train (199 instances): Collect trajectories for experience extraction
bash stage1.sh train train_instances.txt

# Test (30 instances): Collect baseline results for comparison
bash stage1.sh test test_instances.txt
```

**Features:**
- Auto-retries failed instances
- Train: keeps trajectories in `tmp/trajectory/` for experience extraction
- Test: moves trajectories to `tmp/trajectory_test_backup/` to prevent data leakage

**Output:**
- `django/train_baseline.jsonl` - 199 train results
- `django/test_baseline.jsonl` - 30 test results (baseline)
- `tmp/trajectory/` - 199 train trajectories only (pipeline will move any test trajectories out)
- `tmp/trajectory_test_backup/` - Backup location for test trajectories

**If instances fail or are incomplete:**

The system provides two ways to handle incomplete instances:

**Method 1: Using `rerun_incomplete.sh` (Recommended for train)**
```bash
# Automatically handles cleanup, merging, and retry
bash rerun_incomplete.sh
```

This script will:
- ✓ Compare `train_baseline.jsonl` against `train_instances.txt` (199 expected)
- ✓ Identify missing instances or instances without patches
- ✓ Auto-update `instances_to_rerun.txt`
- ✓ Remove old incomplete trajectories
- ✓ Retry failed instances
- ✓ Merge results back into `train_baseline.jsonl`

**Method 2: Using `stage1.sh` (For test instances)**
```bash
# Manually specify instances to rerun
bash stage1.sh train instances_to_rerun_train.txt
bash stage1.sh test instances_to_rerun_test.txt
```

### Stages 1.5-5: Experience Pipeline (WITH Experience)

After Stage 1 completes (trajectories collected), run the experience pipeline.

```bash
bash pipeline.sh
```

**What it does:**
1. **Stage 1.5**: Evaluate train patches with Docker (~50 hours)
   - **Default: ENABLED** - Gets correct SUCCESS/FAILURE labels for all 199 training instances
   - Runs SWE-bench harness to determine which training patches actually pass tests
   - **IMPORTANT**: Must run BEFORE experience extraction to get correct labels (pipeline enforces this)
2. **Stage 2**: Extract issue types from 199 train trajectories
3. **Stage 3**: Build experience tree from 199 train instances (with 3x retry)
   - Uses `tmp/merged_leaf_analysis_with_trajectories.jsonl` (prepared in Stage 1.5)
   - Retries failed extractions up to 3 times per instance
4. **Stage 3.5**: Extract issue types from 30 test instances
   - Enables test instances to query the train-only experience database
   - Verifies no data leakage (test ∩ experience tree = ∅)
5. **Stage 4**: Run 30 test instances WITH experience
6. **Stage 5**: Evaluate test patches (baseline + with-experience) via `evaluate.sh`

**Prerequisites check:**
- `tmp/trajectory/` must have 199 train trajectories
- `django/test_baseline.jsonl` must have 30 test results

**Output:**
- `tmp/het/train_issue_types.json` - Train issue classifications (199)
- `tmp/het/test_issue_types.json` - Test issue classifications (30)
- `tmp/het/verified_experience_tree.json` - Experience database (train only)
- `django/test_with_experience_TIMESTAMP.jsonl` - Test results WITH experience
- `evaluation_results/eval_test_baseline_*/report.json` - Baseline Docker evaluation
- `evaluation_results/eval_test_with_experience_*/report.json` - With-experience Docker evaluation

### Stage 5: Evaluation

Evaluate patches using SWE-bench harness.

```bash
# Evaluate baseline (WITHOUT experience)
bash evaluate.sh django/test_baseline.jsonl

# Evaluate WITH experience (use actual timestamp)
bash evaluate.sh django/test_with_experience_20241119_153045.jsonl
```

**Requirements:**
- Docker installed and running
- ~15 min/instance × 30 instances = ~7.5 hours per run

**Output:**
- `evaluation_results/eval_*/report.json` - Evaluation results with `resolved` field

## Understanding Training Evaluation

### Key Design Decision: Training vs Testing Evaluation

The SWE-Exp experience system has an important distinction between training and testing:

#### Testing Instances (30 instances)
- **ALWAYS evaluated with Docker** (Stage 5)
- SWE-bench harness runs actual tests to determine `resolved` status
- Results used to measure system performance
- Time: ~7.5 hours for 30 instances

#### Training Instances (199 instances)
- **By default: YES Docker evaluation** (Stage 1.5 ENABLED for correct labels)
- Docker evaluation runs for ~50 hours to classify each training instance
- Experience extraction (Stage 3) uses `resolved` field for correct classification
- With `resolved` field: Mixed SUCCESS/FAILURE experiences based on actual test results
- Without `resolved` field: All treated as FAILURE experiences (if Stage 1.5 skipped)
- **CRITICAL**: Evaluation must happen in Stage 1.5 BEFORE experience extraction (Stages 2-3)

### How Experience Extraction Works

The experience extraction logic in `moatless/experience/exp_agent/exp_agent.py`:

```python
# For each training instance:
for i in eval:
    if i.get('resolved') == True:  # Check Docker evaluation result
        # Extract SUCCESS experience
        # Analyzes: "What strategy worked in this case?"
        extract_success_experience(trajectory, agent_patch)
    else:
        # Extract FAILURE experience (default without evaluation)
        # Analyzes: "What went wrong vs golden patch?"
        extract_failure_experience(trajectory, golden_patch)
```

### Trade-offs: To Evaluate Training Set or Not?

#### Option A: Evaluate Training Set with Docker (Default, Recommended)
**Pros:**
- ✅ Mixed success/failure experiences based on actual test results
- ✅ Captures successful strategies from training set
- ✅ Accurate experience classification
- ✅ Best for production/research quality results
- ✅ **NOW ENABLED BY DEFAULT**

**Cons:**
- ❌ Requires ~50 hours (199 × 15 min)
- ❌ Significant computational resources

#### Option B: Skip Training Evaluation (Fast Mode)
**Pros:**
- ✅ Fast pipeline (~0 hours vs ~50 hours)
- ✅ Still generates valuable failure analysis experiences
- ✅ Experiences explain what approaches fail and why
- ✅ Suitable for quick experimentation

**Cons:**
- ❌ All 199 training experiences treated as failures
- ❌ Missing successful solution patterns from training set
- ❌ May reduce experience quality for similar successful cases

### Training Evaluation: Enabled by Default

**Stage 1.5 is now ENABLED by default** in `pipeline.sh` for correct experience classification.

**What happens automatically:**
1. Runs `evaluate.sh django/train_baseline.jsonl` (~50 hours)
2. Merges `resolved` status from evaluation results into trajectory data
3. Creates `tmp/merged_leaf_analysis_with_trajectories.jsonl` with proper classification
4. Enables correct SUCCESS/FAILURE experience extraction in Stage 3

**Correct workflow order:**
- ✅ Stage 1 → Stage 1.5 (evaluation) → Stage 2-3 (experience extraction)
- ❌ Stage 1 → Stage 2-3 → Stage 1.5 (too late, wrong labels!)

### How to Skip Training Evaluation (Fast Mode)

To skip Docker evaluation and save ~50 hours (but get failure-only experiences), edit `pipeline.sh`:

```bash
# In pipeline.sh (around line 136-241):
# Comment out the Stage 1.5 evaluation block (lines 136-224)
# Uncomment the "Fast Mode" block (lines 226-241):

log_info "========================================================================"
log_info "STAGE 1.5: Skipping Docker Evaluation (Fast Mode)"
log_info "========================================================================"
# ... (rest of fast mode block)
```

### Current Results (Without Training Evaluation)

Based on our experiments:
- **Training**: 0% resolved (never evaluated, all treated as failures)
- **Testing Baseline**: 17/30 = 56.7% resolved (Docker evaluated)
- **Testing With Experience**: 15/27 = 55.6% resolved (Docker evaluated)

The similar performance suggests that failure-only experiences may still be valuable, though this hypothesis requires more validation with training evaluation enabled.

## File Organization

### Input Files
```
├── train_instances.txt              # 199 train IDs
├── instances_fail.txt               # 2 failed train IDs
└── test_instances.txt               # 30 test IDs
```

### Key Output Files

#### django/ - Prediction Results (Keep These!)
```
django/
├── train_baseline.jsonl             # 199 train instances - Stage 1 results (WITHOUT experience)
│                                     # Used to build experience database in Stage 2-3
│
├── test_baseline.jsonl              # 30 test instances - Stage 1 results (WITHOUT experience)
│                                     # Baseline for comparison
│
├── test_with_experience.jsonl       # 25 test instances - Stage 4 results (WITH experience)
│                                     # 5 instances timed out, see analysis
│
└── archived_files/                  # Historical backup files
```

**Important Notes:**
- `train_baseline.jsonl`: Generated once from 199 train instances, used as input for experience extraction (Stages 2-3)
- `test_baseline.jsonl`: Baseline results (30 instances, no experience guidance)
- `test_with_experience.jsonl`: Results with experience guidance (25/30 completed, 5 timed out)
- These are the core files for performance comparison and evaluation

### Stage 1 Output (WITHOUT Experience)
```
└── tmp/
    ├── trajectory/                  # 199 TRAIN trajectories only
    │   ├── django__django-11001/
    │   │   └── 2025-11-22_trajectory.json
    │   └── ...
    └── trajectory_test_backup/      # 30 test trajectories (backup, prevent leakage)
```

### Stage 2-3 Output (Experience Extraction)
```
└── tmp/
    └── het/
        ├── train_issue_types.json          # Train issue types (199)
        ├── test_issue_types.json           # Test issue types (30)
        └── verified_experience_tree.json   # Experience database (train only, 199 instances)
```

### Stage 5 Output (Evaluation)
```
└── evaluation/
    ├── eval_test_baseline.json             # Evaluation: WITHOUT experience (30 instances)
    ├── eval_test_with_experience.json      # Evaluation: WITH experience (25 instances)
    └── comparison_25_common_instances.json # Performance comparison on 25 common instances
```

## Quick Commands

```bash
# Check Stage 1 completion status
wc -l django/train_baseline.jsonl django/test_baseline.jsonl
ls tmp/trajectory/ | wc -l  # Should be 199 (train only)

# Check Stage 2-3 output
ls -lh tmp/het/*.json

# Check Stage 4 output
ls -lh django/test_with_experience_*.jsonl

# Compare patch counts
grep -c '"model_patch":' django/test_baseline.jsonl
grep -c '"model_patch":' django/test_with_experience_*.jsonl

# View evaluation results
cat evaluation_results/*/report.json | jq '[.[] | select(.resolved == true) | .instance_id] | length'
```

## Data Split & Leakage Prevention

- **Train (199)**: Older Django instances used to build experience
  - Originally 201 instances, but 2 failed to generate patches due to timeouts
  - Failed instances (recorded in `instances_fail.txt`):
    - `django__django-13212`
    - `django__django-13513`
  - Successfully completed: 199 instances in `train_instances.txt`
- **Test (30)**: Latest 30 Django instances from SWE-bench_Verified
- **No overlap**: Test instances are NOT in train set

**Data Leakage Prevention:**
- Explicit train/test split (separate files, not repo-based filtering)
- Test issue types used only as search queries, NOT for building experiences
- Experience tree built exclusively from train trajectories
- Automatic verification: pipeline checks test ∩ experience tree = ∅

## Troubleshooting

### Stage 1: Some instances fail to generate patches

**For train instances (recommended):**
```bash
# Use rerun_incomplete.sh - automatically detects and retries incomplete instances
bash rerun_incomplete.sh
```

The script will:
1. Check `train_baseline.jsonl` against `train_instances.txt` (199 total)
2. Find instances that are missing or without patches
3. Update `instances_to_rerun.txt` automatically
4. Clean up incomplete trajectories
5. Rerun failed instances
6. Merge results back

**For manual control or test instances:**
```bash
# Manually specify instances to retry
bash stage1.sh train instances_to_rerun_train.txt
bash stage1.sh test instances_to_rerun_test.txt
```

**Increasing timeout for difficult instances:**
```bash
# Edit workflow.py to increase timeout (default: 600s = 10 min)
sed -i 's/INSTANCE_TIMEOUT = 600/INSTANCE_TIMEOUT = 1200/' workflow.py

# Then run rerun script
bash rerun_incomplete.sh
```

### Stage 2-4: Prerequisites not met
```bash
# Check trajectory count
ls tmp/trajectory/ | wc -l  # Must be 199

# Check test baseline exists
wc -l django/test_baseline.jsonl  # Must be 30

# Verify no test trajectories leaked into train
ls tmp/trajectory/ | grep -f test_instances.txt  # Should be empty
```

### Stage 3: KeyError: 'leaf' or 'leaf_id'
If you encounter `KeyError: 'leaf'` during Stage 3, the evaluation file format is incorrect. This is automatically fixed by pipeline.sh, but if running exp_agent.py manually:

```bash
# Prepare the correct evaluation file
cp django/train_baseline.jsonl tmp/merged_leaf_analysis_with_trajectories.jsonl

# Then run Stage 3
python moatless/experience/exp_agent/exp_agent.py
```

**Note**: The exp_agent.py script now supports both 'leaf' and 'leaf_id' field names for backward compatibility.

### Evaluation: Docker not running
```bash
# Start Docker
sudo systemctl start docker

# Or if permission issues
sudo usermod -aG docker $USER
newgrp docker
```

## Complete Workflow for Comparison

To compare 30 test instances WITHOUT vs WITH experience:

```bash
# Prerequisites: You should already have these from Stage 1
# - django/train_baseline.jsonl (199 train instances)
# - django/test_baseline.jsonl (30 test instances WITHOUT experience)
# - tmp/trajectory/ (199 train trajectories)

# Step 1: Run experience pipeline (Stages 1.5-5)
bash pipeline.sh
# This will:
# - Extract experiences from 199 train instances
# - Extract issue types for 30 test instances (Stage 3.5)
# - Apply experiences to 30 test instances (Stage 4)
# - Evaluate baseline + with-experience patches (Stage 5)
# - Output: django/test_with_experience_TIMESTAMP.jsonl and evaluation_results/*
```

**Summary:** After Stage 1, running `pipeline.sh` completes Stages 1.5–5 and produces both patch files and evaluation reports.

## Experience Source, Format, and Usage (Brief)

- **Source:** Experiences are mined from the 199 train trajectories after Docker evaluation in Stage 1.5. Each train instance is labeled `resolved=True/False`; successes yield “success” experiences, failures yield “failed” reflections.
- **Format:** Stored in `tmp/verified_experience_tree.json` (copied to `tmp/het/`). Keys are train instance IDs; each value includes fields like `perspective`, `positioning`, `modification`, and a `flag` of `success` or `failed`.
- **Usage:** During Stage 4, `workflow.py` loads `tmp/het/verified_experience_tree.json` plus test issue types. `SelectAgent` retrieves the most relevant train experience, generalizes it to the current test issue, and injects the guidance into the agent prompt (`***Experience 1***: ...`). Modification steps also get enhanced instructions based on the selected experience.
