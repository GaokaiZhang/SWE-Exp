# SWE-Exp Quickstart

## Objective
Compare 30 test instances solved **without** vs **with** experience learned from 201 train instances.

## Prerequisites

### Required Files
```
SWE-Exp/
├── .env                    # ANTHROPIC_API_KEY=sk-ant-...
├── train_instances.txt     # 201 train instance IDs (one per line)
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
# Train (201 instances): Collect trajectories for experience extraction
bash stage1.sh train train_instances.txt

# Test (30 instances): Collect baseline results for comparison
bash stage1.sh test test_instances.txt
```

**Features:**
- Auto-retries failed instances
- Train: keeps trajectories in `tmp/trajectory/` for experience extraction
- Test: moves trajectories to `tmp/trajectory_test_backup/` to prevent data leakage

**Output:**
- `django/train_baseline.jsonl` - 201 train results
- `django/test_baseline.jsonl` - 30 test results (baseline)
- `tmp/trajectory/` - 201 train trajectories only

**If instances fail:**
```bash
# Rerun incomplete instances (auto-generated rerun file)
bash stage1.sh train instances_to_rerun_train.txt
bash stage1.sh test instances_to_rerun_test.txt
```

### Stages 2-4: Experience Pipeline (WITH Experience)

Extract experiences from 201 train instances and apply to 30 test instances.

```bash
bash pipeline.sh
```

**What it does:**
1. **Stage 2**: Extract issue types from 201 train trajectories
2. **Stage 3**: Build experience tree from 201 train instances
3. **Stage 4**: Run 30 test instances WITH experience

**Prerequisites check:**
- `tmp/trajectory/` must have 201 train trajectories
- `django/test_baseline.jsonl` must have 30 test results

**Output:**
- `tmp/het/verified_issue_types_final.json` - Issue classifications
- `tmp/het/verified_experience_tree.json` - Experience database
- `django/test_with_experience_TIMESTAMP.jsonl` - Test results WITH experience

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
- `evaluation_results/eval_*/report.json` - Evaluation results

## File Organization

### Input Files
```
├── train_instances.txt              # 201 train IDs
└── test_instances.txt               # 30 test IDs
```

### Stage 1 Output (WITHOUT Experience)
```
├── django/
│   ├── train_baseline.jsonl         # 201 train results
│   └── test_baseline.jsonl          # 30 test baseline results
└── tmp/
    ├── trajectory/                  # 201 TRAIN trajectories only
    │   ├── django__django-11001/
    │   └── ...
    └── trajectory_test_backup/      # 30 test trajectories (backup)
```

### Stage 2-3 Output (Experience Extraction)
```
└── tmp/
    └── het/
        ├── verified_issue_types_final.json    # Issue classifications
        └── verified_experience_tree.json      # Experience database
```

### Stage 4 Output (WITH Experience)
```
└── django/
    └── test_with_experience_20241119_153045.jsonl  # Test WITH experience
```

### Stage 5 Output (Evaluation)
```
└── evaluation_results/
    ├── eval_test_baseline_20241119_160000/
    │   └── report.json
    └── eval_test_with_experience_20241119_163000/
        └── report.json
```

## Quick Commands

```bash
# Check Stage 1 completion status
wc -l django/train_baseline.jsonl django/test_baseline.jsonl
ls tmp/trajectory/ | wc -l  # Should be 201 (train only)

# Check Stage 2-3 output
ls tmp/het/verified_*.json

# Check Stage 4 output
ls -lh django/test_with_experience_*.jsonl

# Compare patch counts
grep -c '"model_patch":' django/test_baseline.jsonl
grep -c '"model_patch":' django/test_with_experience_*.jsonl

# View evaluation results
cat evaluation_results/*/report.json | jq '[.[] | select(.resolved == true) | .instance_id] | length'
```

## Data Split

- **Train (201)**: Older Django instances used to build experience
- **Test (30)**: Latest 30 Django instances from SWE-bench_Verified
- **No overlap**: Test instances are NOT in train set (no data leakage)

## Troubleshooting

### Stage 1: Some instances fail to generate patches
```bash
# Auto-retry using generated rerun file
bash stage1.sh train instances_to_rerun_train.txt
```

### Stage 2-4: Prerequisites not met
```bash
# Check trajectory count
ls tmp/trajectory/ | wc -l  # Must be 201

# Check test baseline exists
wc -l django/test_baseline.jsonl  # Must be 30

# Verify no test trajectories leaked into train
ls tmp/trajectory/ | grep -f test_instances.txt  # Should be empty
```

### Evaluation: Docker not running
```bash
# Start Docker
sudo systemctl start docker

# Or if permission issues
sudo usermod -aG docker $USER
newgrp docker
```

## Summary Workflow

```bash
# 1. Stage 1: Collect trajectories WITHOUT experience
bash stage1.sh train train_instances.txt  # → django/train_baseline.jsonl (201)
bash stage1.sh test test_instances.txt    # → django/test_baseline.jsonl (30)

# 2. Stages 2-4: Extract experience and apply to test
bash pipeline.sh  # → django/test_with_experience_*.jsonl (30)

# 3. Stage 5: Evaluate both
bash evaluate.sh django/test_baseline.jsonl              # Baseline
bash evaluate.sh django/test_with_experience_*.jsonl     # With experience

# 4. Compare results in evaluation_results/
```
