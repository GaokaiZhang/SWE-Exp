# SWE-Exp Quickstart

## Objective
Compare 30 test instances solved **without** vs **with** experience learned from a 201-instance train set (actual runs may be fewer if some train cases are intentionally skipped).

## Prerequisites

### Required Files
```
SWE-Exp/
├── .env                           # ANTHROPIC_API_KEY=sk-ant-...
├── train_instances_expected.txt   # 201 train instance IDs (expected, one per line)
├── test_instances_expected.txt    # 30 test instance IDs (expected, one per line)
├── train_instances_actual.txt     # AUTO-GENERATED after Stage 1
├── test_instances_actual.txt      # AUTO-GENERATED after Stage 1
└── instances_fail.txt             # 2 known hard train IDs (included in expected list)
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
# Train (201 expected): Collect trajectories for experience extraction
bash stage1.sh train train_instances_expected.txt

# Test (30 instances): Collect baseline results for comparison
bash stage1.sh test test_instances_expected.txt
```

**Features:**
- Auto-retries failed instances
- Train: keeps trajectories in `tmp/trajectory/` for experience extraction
- Test: moves trajectories to `tmp/trajectory_test_backup/` to prevent data leakage
- Auto-generates `train_instances_actual.txt` and `test_instances_actual.txt` (downstream stages use these actual lists so you don't have to rerun hard instances)

**Output:**
- `django/train_baseline.jsonl` - train results
- `django/test_baseline.jsonl` - test results (baseline)
- `train_instances_actual.txt`, `test_instances_actual.txt` - actual IDs collected in this run
- `tmp/trajectory/` - train trajectories only (pipeline will move any test trajectories out)
- `tmp/trajectory_test_backup/` - Backup location for test trajectories

**If instances fail or are incomplete:**

The system provides two ways to handle incomplete instances:

**Method 1: Using `rerun_incomplete.sh` (Recommended for train)**
```bash
# Automatically handles cleanup, merging, and retry
bash rerun_incomplete.sh
```

This script will:
- ✓ Compare `train_baseline.jsonl` against `train_instances_expected.txt` (201 expected)
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

### Stages 1.1-5: Experience Pipeline (WITH Experience)

After Stage 1 completes (trajectories collected), run the experience pipeline.

```bash
bash pipeline.sh
```

**What it does:**
1. **Stage 1.1**: Evaluate train patches with Docker (default ON)
   - Uses `train_baseline.jsonl` (actual train runs) to label SUCCESS/FAILURE
2. **Stage 2**: Extract issue types from train trajectories
3. **Stage 2.1**: Build experience tree from train trajectories
   - Uses `tmp/merged_leaf_analysis_with_trajectories.jsonl` prepared in Stage 1.1
4. **Stage 3**: Extract issue types from test instances (no leakage)
   - Uses `test_instances_actual.txt`
5. **Stage 4**: Run test instances WITH experience
   - Uses `test_instances_actual.txt`
6. **Stage 5**: Evaluate test patches (baseline + with-experience) via `evaluate.sh`

**Prerequisites check:**
- Stage 1 will log expected vs actual counts (train: 201 expected, test: 30 expected)
- Downstream stages use `*_actual.txt` so you don't need to rerun hard instances

**Output:**
- `tmp/het/train_issue_types.json` - Train issue classifications (from `train_instances_actual.txt`)
- `tmp/het/test_issue_types.json` - Test issue classifications (from `test_instances_actual.txt`)
- `tmp/het/verified_experience_tree.json` - Experience database (train only)
- `django/test_with_experience_TIMESTAMP.jsonl` - Test results WITH experience
- `evaluation_results/eval_test_baseline_*/report.json` - Baseline Docker evaluation
- `evaluation_results/eval_test_with_experience_*/report.json` - With-experience Docker evaluation

### Stage 5: Evaluation

Stage 5 of `pipeline.sh` already evaluates baseline and with-experience files using the SWE-bench harness. Rerun manually if you need to regenerate reports:

```bash
# Evaluate baseline (WITHOUT experience)
bash evaluate.sh django/test_baseline.jsonl

# Evaluate WITH experience (use actual timestamp)
bash evaluate.sh django/test_with_experience_<TIMESTAMP>.jsonl
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

#### Training Instances (201 expected)
- **By default: YES Docker evaluation** (Stage 1.1 ENABLED for correct labels)
- Docker evaluation runs for ~50 hours to classify each training instance (train_instances_actual.txt)
- Experience extraction (Stages 2/2.1) uses `resolved` field for correct classification
- With `resolved` field: Mixed SUCCESS/FAILURE experiences based on actual test results
- Without `resolved` field: All treated as FAILURE experiences (if Stage 1.1 skipped)
- **CRITICAL**: Evaluation must happen in Stage 1.1 BEFORE experience extraction (Stages 2-3)

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
- ❌ Requires ~50 hours (train_size × ~15 min)
- ❌ Significant computational resources

#### Option B: Skip Training Evaluation (Fast Mode)
**Pros:**
- ✅ Fast pipeline (~0 hours vs ~50 hours)
- ✅ Still generates valuable failure analysis experiences
- ✅ Experiences explain what approaches fail and why
- ✅ Suitable for quick experimentation

**Cons:**
- ❌ All training experiences treated as failures
- ❌ Missing successful solution patterns from training set
- ❌ May reduce experience quality for similar successful cases

### Training Evaluation: Enabled by Default

**Stage 1.1 is ENABLED by default** in `pipeline.sh` for correct experience classification.

**What happens automatically:**
1. Runs `evaluate.sh django/train_baseline.jsonl` (~50 hours for the train set)
2. Merges `resolved` status from evaluation results into trajectory data
3. Creates `tmp/merged_leaf_analysis_with_trajectories.jsonl` with proper classification
4. Enables correct SUCCESS/FAILURE experience extraction in Stages 2/2.1

**Correct workflow order:**
- ✅ Stage 1 → Stage 1.1 (evaluation) → Stage 2/2.1 (experience extraction)
- ❌ Stage 1 → Stage 2/2.1 → Stage 1.1 (too late, wrong labels!)

### How to Skip Training Evaluation (Fast Mode)

To skip Docker evaluation and save ~50 hours (but get failure-only experiences), edit `pipeline.sh`:

```bash
# In pipeline.sh:
# Comment out the Stage 1.1 evaluation block
# Uncomment the "Fast Mode" block just below it:

log_info "========================================================================"
log_info "STAGE 1.1: Skipping Docker Evaluation (Fast Mode)"
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
├── train_instances_expected.txt      # 201 train IDs (expected)
├── train_instances_actual.txt        # Generated after Stage 1
├── test_instances_expected.txt       # 30 test IDs (expected)
├── test_instances_actual.txt         # Generated after Stage 1
└── instances_fail.txt                # 2 known hard train IDs (included in expected list)
```

### Key Output Files

#### django/ - Prediction Results (Keep These!)
```
django/
├── train_baseline.jsonl             # Train instances - Stage 1 results (WITHOUT experience)
│                                     # Used to build experience database in Stage 2-3
│
├── test_baseline.jsonl              # Test instances - Stage 1 results (WITHOUT experience)
│                                     # Baseline for comparison
│
├── test_with_experience_TIMESTAMP.jsonl  # Stage 4 results (WITH experience)
│
└── archived_files/                  # Historical backup files
```

**Important Notes:**
- `train_baseline.jsonl`: Generated once from `train_instances_expected.txt`; downstream stages use `train_instances_actual.txt`
- `test_baseline.jsonl`: Baseline results (uses `test_instances_actual.txt`)
- `test_with_experience_TIMESTAMP.jsonl`: Results with experience guidance (Stage 4)
- These are the core files for performance comparison and evaluation

### Stage 1 Output (WITHOUT Experience)
```
└── tmp/
    ├── trajectory/                  # TRAIN trajectories only (from train_instances_actual.txt)
    │   ├── django__django-11001/
    │   │   └── 2025-11-22_trajectory.json
    │   └── ...
    └── trajectory_test_backup/      # Test trajectories (backup, prevent leakage)
```

### Stage 2-3 Output (Experience Extraction)
```
└── tmp/
    └── het/
        ├── train_issue_types.json          # Train issue types (train_instances_actual.txt)
        ├── test_issue_types.json           # Test issue types (test_instances_actual.txt)
        └── verified_experience_tree.json   # Experience database (train only)
```

### Stage 5 Output (Evaluation)
```
└── evaluation/
    ├── eval_test_baseline.json             # Evaluation: WITHOUT experience (uses test_instances_actual.txt)
    ├── eval_test_with_experience.json      # Evaluation: WITH experience
    └── comparison_<timestamp>.json         # Performance comparison on common instances
```

## Quick Commands

```bash
# Check Stage 1 completion status
wc -l django/train_baseline.jsonl django/test_baseline.jsonl
ls tmp/trajectory/ | wc -l  # Should match train_instances_actual.txt (train only)

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

- **Train (201 expected)**: Django instances used to build experience
  - Includes two known hard IDs in `instances_fail.txt`; they stay in the expected list even if they fail to run
  - Actual runs are recorded in `train_instances_actual.txt` after Stage 1
- **Test (30)**: Latest 30 Django instances from SWE-bench_Verified (`test_instances_expected.txt`)
  - Actual runs are recorded in `test_instances_actual.txt` after Stage 1
- **No overlap**: Test instances are NOT in train set (pipeline verifies)

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
1. Check `train_baseline.jsonl` against `train_instances_expected.txt` (201 total) and `train_instances_actual.txt`
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
ls tmp/trajectory/ | wc -l  # Should match train_instances_actual.txt (<= 201)

# Check test baseline exists
wc -l django/test_baseline.jsonl  # Should be <= 30 (matches test_instances_actual.txt)

# Verify no test trajectories leaked into train
ls tmp/trajectory/ | grep -f test_instances_expected.txt  # Should be empty
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
# - django/train_baseline.jsonl (train_instances_actual.txt)
# - django/test_baseline.jsonl (test_instances_actual.txt WITHOUT experience)
# - tmp/trajectory/ (train trajectories)

# Step 1: Run experience pipeline (Stages 1.1-5)
bash pipeline.sh
# This will:
# - Extract experiences from train instances (Stages 2/2.1)
# - Extract issue types for test instances (Stage 3)
# - Apply experiences to test instances (Stage 4)
# - Evaluate baseline + with-experience patches (Stage 5)
# - Output: django/test_with_experience_TIMESTAMP.jsonl and evaluation_results/*
```

**Summary:** After Stage 1, running `pipeline.sh` completes Stages 1.1–5 and produces both patch files and evaluation reports.

## Experience Source, Format, and Usage (Brief)

- **Source:** Experiences are mined from the train trajectories after Docker evaluation in Stage 1.1. Each train instance is labeled `resolved=True/False`; successes yield “success” experiences, failures yield “failed” reflections.
- **Format:** Stored in `tmp/verified_experience_tree.json` (copied to `tmp/het/`). Keys are train instance IDs; each value includes fields like `perspective`, `positioning`, `modification`, and a `flag` of `success` or `failed`.
- **Usage:** During Stage 4, `workflow.py` loads `tmp/het/verified_experience_tree.json` plus test issue types. `SelectAgent` retrieves the most relevant train experience, generalizes it to the current test issue, and injects the guidance into the agent prompt (`***Experience 1***: ...`). Modification steps also get enhanced instructions based on the selected experience.
