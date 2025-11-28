#!/bin/bash
################################################################################
# EXPERIENCE PIPELINE - STAGES 1.5, 2-4
#
# Prerequisites: Stage 1 must be completed for all instances
#   - Train: Expected list in train_instances_expected.txt (201 ids)
#   - Test:  Expected list in test_instances_expected.txt (30 ids)
#
# This script:
#   1. Stage 1: Collect trajectories WITHOUT experience (train + test)
#   1.1 Stage 1.1: (OPTIONAL) Evaluate train patches with Docker (~50 hours)
#   2. Stage 2: Extract train issue types (experience extraction)
#   2.1 Stage 2.1: Build experience tree (experience extraction)
#   3. Stage 3: Extract test issue types (retrieval prep, no leakage)
#   4. Stage 4: Run test instances WITH experience (experience reuse)
#   5. Stage 5.x: Evaluate baseline vs with-experience results
################################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="logs/pipeline_${TIMESTAMP}"
mkdir -p "$LOG_DIR"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') - $1" | tee -a "$LOG_DIR/main.log"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') - $1" | tee -a "$LOG_DIR/main.log"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $1" | tee -a "$LOG_DIR/main.log"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%H:%M:%S') - $1" | tee -a "$LOG_DIR/main.log"
}

start_stage() {
    local stage_label="$1"
    local description="$2"
    log_info "========================================================================"
    log_info "STAGE ${stage_label}: ${description}"
    log_info "========================================================================"
}

EXPECTED_TRAIN_FILE="train_instances_expected.txt"
EXPECTED_TEST_FILE="test_instances_expected.txt"
ACTUAL_TRAIN_FILE="train_instances_actual.txt"
ACTUAL_TEST_FILE="test_instances_actual.txt"
TRAIN_BASELINE_FILE="django/train_baseline.jsonl"
TEST_BASELINE_FILE="django/test_baseline.jsonl"

################################################################################
# SETUP
################################################################################

# Activate conda environment
source ~/conda/etc/profile.d/conda.sh
conda activate swe-exp

# Verify API key
log_info "Verifying ANTHROPIC_API_KEY..."
python -c "
from dotenv import load_dotenv
import os
import sys
env_path = os.path.join(os.getcwd(), '.env')
load_dotenv(env_path)
key = os.getenv('ANTHROPIC_API_KEY')
if not key or not key.startswith('sk-ant-'):
    print('ERROR: ANTHROPIC_API_KEY not found or invalid in .env file')
    sys.exit(1)
"
if [ $? -ne 0 ]; then
    log_error "Failed to verify ANTHROPIC_API_KEY"
    exit 1
fi
log_success "ANTHROPIC_API_KEY verified"

################################################################################
# STAGE 1: TRAJECTORY COLLECTION (TRAIN & TEST) FOR FAIR COMPARISON
################################################################################

for file in "$EXPECTED_TRAIN_FILE" "$EXPECTED_TEST_FILE"; do
    if [ ! -f "$file" ]; then
        log_error "Missing instance file: $file"
        exit 1
    fi
done

TRAIN_EXPECTED_COUNT=$(wc -l < "$EXPECTED_TRAIN_FILE")
TEST_EXPECTED_COUNT=$(wc -l < "$EXPECTED_TEST_FILE")

start_stage "1" "Collect trajectories WITHOUT experience (train + test)"
log_info "Train list (expected): $EXPECTED_TRAIN_FILE (${TRAIN_EXPECTED_COUNT} ids)"
log_info "Test list (expected):  $EXPECTED_TEST_FILE (${TEST_EXPECTED_COUNT} ids)"

if ! bash stage1.sh train "$EXPECTED_TRAIN_FILE" 2>&1 | tee "$LOG_DIR/stage1_train.log"; then
    log_error "Stage 1 (train) run failed"
    exit 1
fi

if ! bash stage1.sh test "$EXPECTED_TEST_FILE" 2>&1 | tee "$LOG_DIR/stage1_test.log"; then
    log_error "Stage 1 (test) run failed"
    exit 1
fi

log_info "Deriving actual instance lists from Stage 1 outputs..."
if ! python <<PYEOF 2>&1 | tee "$LOG_DIR/stage1_actual_lists.log"; then
import json, os, sys

expected_train = [line.strip() for line in open("${EXPECTED_TRAIN_FILE}") if line.strip()]
expected_test = [line.strip() for line in open("${EXPECTED_TEST_FILE}") if line.strip()]

def write_actual(jsonl_path, out_path, expected, label):
    if not os.path.isfile(jsonl_path):
        print(f"ERROR: Missing {jsonl_path}")
        sys.exit(1)

    ids = []
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            ids.append(obj["instance_id"])

    with open(out_path, "w") as out:
        out.write("\n".join(ids))
        if ids:
            out.write("\n")

    missing = [i for i in expected if i not in ids]
    extra = [i for i in ids if i not in expected]

    print(f"{label} actual: {len(ids)} ids (expected {len(expected)})")
    if missing:
        print(f"  Missing {len(missing)} expected ids: {', '.join(missing[:10])}" + (" ..." if len(missing) > 10 else ""))
    if extra:
        print(f"  Unexpected {len(extra)} ids: {', '.join(extra[:10])}" + (" ..." if len(extra) > 10 else ""))
    if not ids:
        print(f"ERROR: No ids found in {jsonl_path}")
        sys.exit(1)

write_actual("${TRAIN_BASELINE_FILE}", "${ACTUAL_TRAIN_FILE}", expected_train, "Train")
write_actual("${TEST_BASELINE_FILE}", "${ACTUAL_TEST_FILE}", expected_test, "Test")
PYEOF
    log_error "Failed to derive actual instance lists"
    exit 1
fi

TRAIN_ACTUAL_COUNT=$(wc -l < "$ACTUAL_TRAIN_FILE")
TEST_ACTUAL_COUNT=$(wc -l < "$ACTUAL_TEST_FILE")
TRAIN_BASELINE_COUNT=$(wc -l < "$TRAIN_BASELINE_FILE" 2>/dev/null || echo "0")
TEST_BASELINE_COUNT=$(wc -l < "$TEST_BASELINE_FILE" 2>/dev/null || echo "0")
log_success "Recorded actual instance lists: Train ${TRAIN_ACTUAL_COUNT}/${TRAIN_EXPECTED_COUNT}, Test ${TEST_ACTUAL_COUNT}/${TEST_EXPECTED_COUNT}"

# Ensure tmp/trajectory only contains TRAIN trajectories (move any test runs to backup)
log_info "Ensuring tmp/trajectory contains train trajectories only..."
python <<PYEOF 2>/dev/null
import os
import shutil

train_ids = set(line.strip() for line in open('${EXPECTED_TRAIN_FILE}') if line.strip())
test_ids = set(line.strip() for line in open('${EXPECTED_TEST_FILE}') if line.strip())
traj_root = 'tmp/trajectory'
backup_root = 'tmp/trajectory_test_backup'

if not os.path.isdir(traj_root):
    print("  WARNING: tmp/trajectory does not exist")
else:
    moved = 0
    unexpected = []
    for name in os.listdir(traj_root):
        src = os.path.join(traj_root, name)
        if not os.path.isdir(src):
            continue
        if name in test_ids:
            os.makedirs(backup_root, exist_ok=True)
            dst = os.path.join(backup_root, name)
            if os.path.exists(dst):
                shutil.rmtree(dst)
            shutil.move(src, dst)
            moved += 1
        elif name not in train_ids:
            unexpected.append(name)

    print(f"  Moved {moved} test trajectories to {backup_root}")
    if unexpected:
        extra = f" ... (+{len(unexpected)-5} more)" if len(unexpected) > 5 else ""
        print(f"  WARNING: Unexpected trajectories found: {', '.join(unexpected[:5])}{extra}")
PYEOF
log_success "Trajectory directory sanitized"

# Create directories
mkdir -p tmp/het
export PYTHONPATH=/home/gaokaizhang/SWE-Exp

echo ""

################################################################################
# STAGE 1.1: (OPTIONAL) EVALUATE TRAIN PATCHES WITH DOCKER
################################################################################
#
# IMPORTANT: This stage should run AFTER Stage 1 (trajectory collection)
#            but BEFORE Stage 2-3 (experience extraction)
#
# WHY THIS MATTERS:
# - exp_agent.py (Stage 3) uses the 'resolved' field to determine:
#   * resolved=True  → Extract SUCCESS experience (what worked)
#   * resolved=False/missing → Extract FAILURE experience (what went wrong)
# - Without evaluation: ALL 199 training instances → FAILURE experiences
# - With evaluation: Mixed SUCCESS/FAILURE experiences based on actual tests
#
# TRADE-OFFS:
# - WITH evaluation (~15 min per train instance):
#   ✅ Accurate success/failure classification from actual test results
#   ✅ Learn from both successful and failed solution patterns
#   ✅ Higher quality experience database
#   ❌ Requires ~15 min per train instance (hours scale with train set size)
#   ❌ Significant computational resources
#
# - WITHOUT evaluation (skip this block):
#   ✅ Fast pipeline execution
#   ✅ Still generates useful failure analysis experiences
#   ✅ Good for quick experimentation
#   ❌ All training experiences treated as failures
#   ❌ Missing successful solution patterns from training set
#
# RECOMMENDATION:
# - Production/Research: Keep enabled for accurate labels (default)
# - Quick experimentation: Comment out this block to skip evaluation
#
################################################################################

start_stage "1.1" "Evaluate train patches with Docker (labels for experience quality)"
log_info "Input: ${TRAIN_BASELINE_FILE} (${TRAIN_ACTUAL_COUNT}/${TRAIN_EXPECTED_COUNT} instances)"
log_info "Estimated time: ~$((${TRAIN_ACTUAL_COUNT} * 15 / 60)) hours (${TRAIN_ACTUAL_COUNT} instances × 15 min)"
echo ""

log_info "Evaluating ${TRAIN_BASELINE_FILE} with Docker..."
if ! bash evaluate.sh "$TRAIN_BASELINE_FILE" 2>&1 | tee "$LOG_DIR/stage1.1_evaluate_train.log"; then
    log_error "Evaluation failed! Check log: $LOG_DIR/stage1.1_evaluate_train.log"
    exit 1
fi

# Find or build the evaluation results directory
EVAL_DIR=$(ls -td evaluation_results/eval_train_baseline_* 2>/dev/null | head -1)

if [ -z "$EVAL_DIR" ] || [ ! -f "$EVAL_DIR/report.json" ]; then
    # Reconstruct report.json from per-instance reports if needed
    log_info "evaluation_results missing; rebuilding report.json from logs/run_evaluation..."
    PYTHONPATH=/home/gaokaizhang/SWE-Exp python3 << 'PYEOF'
import json, os, glob
from pathlib import Path

def build_report_from_logs():
    log_dir_candidates = sorted(glob.glob('logs/run_evaluation/eval_train_baseline_*'), reverse=True)
    if not log_dir_candidates:
        raise FileNotFoundError("No run_evaluation logs found for train baseline")
    log_dir = log_dir_candidates[0]
    per_instance = glob.glob(os.path.join(log_dir, 'DeepSeek_IA', '*', 'report.json'))
    if not per_instance:
        raise FileNotFoundError(f"No per-instance report.json files under {log_dir}")
    results = []
    for path in per_instance:
        data = json.load(open(path))
        if len(data) != 1:
            continue
        inst_id, entry = next(iter(data.items()))
        results.append({
            "instance_id": inst_id,
            "resolved": entry.get("resolved", False),
            "patch_successfully_applied": entry.get("patch_successfully_applied"),
            "patch_exists": entry.get("patch_exists"),
            "patch_is_None": entry.get("patch_is_None"),
            "tests_status": entry.get("tests_status"),
        })
    run_id = Path(log_dir).name
    out_dir = os.path.join('evaluation_results', run_id)
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, 'report.json')
    json.dump(results, open(out_path, 'w'), indent=2)
    print(out_path)

path = None
try:
    path = build_report_from_logs()
except Exception as e:
    print(f"ERROR: {e}")
    raise
PYEOF
    EVAL_DIR=$(ls -td evaluation_results/eval_train_baseline_* 2>/dev/null | head -1)
fi

if [ -f "$EVAL_DIR/report.json" ]; then
    log_success "Evaluation completed: $EVAL_DIR/report.json"

    # Merge evaluation results with trajectory data, adding tree path and leaf_id
    log_info "Merging resolved status into trajectory data..."
    PYTHONPATH=/home/gaokaizhang/SWE-Exp python3 << 'PYEOF'
import json
import sys
import os
import glob
from moatless.search_tree import SearchTree

def find_latest_trajectory(instance_id: str) -> str | None:
    base_dir = os.path.join('tmp', 'trajectory', instance_id)
    if not os.path.isdir(base_dir):
        return None
    files = glob.glob(os.path.join(base_dir, '*_trajectory.json'))
    return max(files, key=os.path.getctime) if files else None

def get_leaf_id(tree_path: str) -> tuple[int | None, str]:
    tree = SearchTree.from_file(tree_path)
    finished = tree.get_finished_nodes()
    if finished:
        return finished[0].node_id, "finished"

    best = tree.get_best_trajectory()
    if best:
        return best.node_id, "best_leaf"

    return None, "missing"

# Find evaluation directory
eval_dir = sorted([d for d in glob.glob('evaluation_results/eval_train_baseline_*') if os.path.isdir(d)], reverse=True)
if not eval_dir:
    print("ERROR: Could not find evaluation results directory")
    sys.exit(1)
eval_dir = eval_dir[0]

# Load trajectory data
trajectories = {}
with open('django/train_baseline.jsonl', 'r') as f:
    for line in f:
        data = json.loads(line)
        trajectories[data['instance_id']] = data

# Load evaluation results
report_path = os.path.join(eval_dir, 'report.json')
with open(report_path, 'r') as f:
    eval_results = json.load(f)

# Merge resolved status into trajectories with metadata
merged = []
resolved_count = 0
for result in eval_results:
    instance_id = result['instance_id']
    if instance_id in trajectories:
        traj = trajectories[instance_id]
        traj['resolved'] = result.get('resolved', False)

        tree_path = find_latest_trajectory(instance_id)
        if not tree_path:
            raise FileNotFoundError(f"No trajectory file found for {instance_id}")
        traj['trajectory_path'] = tree_path
        traj['source_tree_path'] = tree_path

        leaf_id, leaf_source = get_leaf_id(tree_path)
        if leaf_id is None:
            raise ValueError(f"No finished or leaf nodes found in trajectory for {instance_id}")
        traj['leaf_id'] = leaf_id
        if leaf_source == "best_leaf":
            print(f"WARNING: No finished nodes for {instance_id}; using best leaf node_id={leaf_id}")

        if traj['resolved']:
            resolved_count += 1
        merged.append(traj)
    else:
        print(f"WARNING: {instance_id} in evaluation but not in train_baseline.jsonl")

# Write merged file
with open('tmp/merged_leaf_analysis_with_trajectories.jsonl', 'w') as f:
    for item in merged:
        f.write(json.dumps(item) + '\n')

print(f"Merged {len(merged)} instances with evaluation results")
print(f"Resolved: {resolved_count}/{len(merged)} ({100*resolved_count/len(merged):.1f}%)")
PYEOF

    if [ $? -eq 0 ]; then
        log_success "Merged evaluation results → tmp/merged_leaf_analysis_with_trajectories.jsonl"
        TRAIN_EVAL_COUNT=$(wc -l < tmp/merged_leaf_analysis_with_trajectories.jsonl 2>/dev/null || echo "0")
        RESOLVED=$(grep -o '"resolved": true' "$EVAL_DIR/report.json" | wc -l)
        log_info "Training evaluation results: ${RESOLVED}/${TRAIN_EVAL_COUNT} resolved"
    else
        log_error "Failed to merge evaluation results!"
        exit 1
    fi
else
    log_error "Evaluation report not found: $EVAL_DIR/report.json"
    exit 1
fi

echo ""

# # Note: To skip Docker evaluation (fast mode; all experiences treated as FAILURES),
# # comment out the above block and uncomment the following:
# # log_info "========================================================================"
# # log_info "STAGE 1.1: Skipping Docker Evaluation (Fast Mode)"
# # log_info "========================================================================"
# # log_info "Using train trajectories WITHOUT Docker evaluation"
# # log_info "Note: All training experiences will be classified as FAILURES"
# # echo ""
# # cp ${TRAIN_BASELINE_FILE} tmp/merged_leaf_analysis_with_trajectories.jsonl
# # if [ $? -eq 0 ]; then
# #     log_success "Prepared: tmp/merged_leaf_analysis_with_trajectories.jsonl"
# #     log_info "File contains trajectory data without 'resolved' field"
# # else
# #     log_error "Failed to prepare evaluation file!"
# #     exit 1
# # fi

# echo ""

################################################################################
# STAGE 2: EXTRACT TRAIN ISSUE TYPES (EXPERIENCE EXTRACTION)
################################################################################

start_stage "2" "Extract train issue types (experience extraction)"
log_info "Source trajectories: tmp/trajectory/ (${TRAIN_ACTUAL_COUNT} actual train runs)"

if ! python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    2>&1 | tee "$LOG_DIR/stage2_extract_issue_types.log"; then
    log_error "Failed during issue type extraction"
    exit 1
fi

# Merge batch files
log_info "Merging batch issue type files..."
if ! python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    --merge \
    2>&1 | tee -a "$LOG_DIR/stage2_extract_issue_types.log"; then
    log_error "Failed to merge issue type batches (see $LOG_DIR/stage2_extract_issue_types.log)"
    exit 1
fi

# Save as TRAIN issue types (explicit train/test split)
if [ -f "tmp/verified_issue_types_merged.json" ]; then
    cp tmp/verified_issue_types_merged.json tmp/het/train_issue_types.json
    log_info "Saved TRAIN issue types to tmp/het/train_issue_types.json"
fi

if [ -f "tmp/het/train_issue_types.json" ]; then
    TRAIN_ISSUE_COUNT=$(python -c "import json; print(len(json.load(open('tmp/het/train_issue_types.json'))))" 2>/dev/null || echo "0")
    log_success "TRAIN issue types extracted: ${TRAIN_ISSUE_COUNT} instances"
else
    log_error "Failed to extract TRAIN issue types!"
    log_error "Check log: $LOG_DIR/stage2_extract_issue_types.log"
    exit 1
fi

echo ""

################################################################################
# STAGE 2.1: BUILD EXPERIENCE TREE (EXPERIENCE EXTRACTION)
################################################################################

start_stage "2.1" "Build experience tree from train trajectories"
log_info "Mining experiences from train runs (${TRAIN_ACTUAL_COUNT} actual instances)"

if ! python moatless/experience/exp_agent/exp_agent.py \
    2>&1 | tee "$LOG_DIR/stage2.1_build_experience.log"; then
    log_error "Failed to build experience tree (see $LOG_DIR/stage2.1_build_experience.log)"
    exit 1
fi

# Copy experience tree to tmp/het/ for workflow.py
if [ -f "tmp/verified_experience_tree.json" ]; then
    cp tmp/verified_experience_tree.json tmp/het/verified_experience_tree.json
    log_info "Copied experience tree to tmp/het/ for workflow.py"
fi

if [ -f "tmp/het/verified_experience_tree.json" ]; then
    EXP_COUNT=$(python -c "import json; data=json.load(open('tmp/het/verified_experience_tree.json')); print(len(data))" 2>/dev/null || echo "0")
    log_success "Experience tree built: ${EXP_COUNT} instances"
    log_success "Saved to: tmp/het/verified_experience_tree.json"
else
    log_error "Failed to build experience tree!"
    log_error "Check log: $LOG_DIR/stage2.1_build_experience.log"
    exit 1
fi

echo ""

################################################################################
# STAGE 3: EXTRACT TEST ISSUE TYPES (RETRIEVAL PREP)
################################################################################

start_stage "3" "Extract test issue types for retrieval (no leakage)"
log_info "Test instances (actual): ${ACTUAL_TEST_FILE} (${TEST_ACTUAL_COUNT}/${TEST_EXPECTED_COUNT})"

# Create Python script to extract test issue types with retry logic
python <<PYTHON_EOF 2>&1 | tee "$LOG_DIR/stage3_extract_test_issue_types.log"
import json
import time
import sys
from moatless.benchmark.utils import get_moatless_instance
from moatless.experience.exp_agent.extract_verified_issue_types_batch import IssueAgent
from moatless.experience.prompts.exp_prompts import issue_type_system_prompt, issue_type_user_prompt
from moatless.completion.completion import CompletionModel
import os

# Load test instances
with open('${ACTUAL_TEST_FILE}', 'r') as f:
    test_ids = [line.strip() for line in f if line.strip()]

print(f"Extracting issue types for {len(test_ids)} test instances...")

# Initialize completion model
api_key = os.getenv("ANTHROPIC_API_KEY")
completion_model = CompletionModel(model="claude-sonnet-4-20250514", temperature=0.7, model_api_key=api_key)
issue_agent = IssueAgent(system_prompt=issue_type_system_prompt, user_prompt=issue_type_user_prompt, completion=completion_model)

test_issue_types = {}
failed_instances = []
max_retries = 3

for idx, instance_id in enumerate(test_ids):
    retry_count = 0

    while retry_count < max_retries:
        try:
            print(f"[{idx+1}/{len(test_ids)}] {instance_id} (attempt {retry_count+1}/{max_retries})")

            instance = get_moatless_instance(instance_id=instance_id)
            issue = instance['problem_statement']

            answer = issue_agent.analyze(issue)
            answer['issue'] = issue
            test_issue_types[instance_id] = answer

            print(f"  ✓ {answer['issue_type']}")
            time.sleep(10)
            break

        except Exception as e:
            retry_count += 1
            print(f"  ✗ Attempt {retry_count} failed: {str(e)}")

            if retry_count >= max_retries:
                print(f"  ✗ Failed after {max_retries} attempts")
                test_issue_types[instance_id] = {
                    "error": str(e),
                    "issue_type": "unknown",
                    "description": f"Failed after {max_retries} attempts",
                    "issue": ""
                }
                failed_instances.append(instance_id)
            else:
                print(f"  ⟳ Retrying in 15s...")
                time.sleep(15)

# Save test issue types
with open('tmp/het/test_issue_types.json', 'w') as f:
    json.dump(test_issue_types, f, ensure_ascii=False, indent=4)

print()
print(f"TEST issue types: {len(test_issue_types) - len(failed_instances)}/{len(test_ids)} successful")
if failed_instances:
    print(f"Failed: {failed_instances}")
    sys.exit(1)
PYTHON_EOF

if [ $? -eq 0 ] && [ -f "tmp/het/test_issue_types.json" ]; then
    TEST_ISSUE_COUNT=$(python -c "import json; print(len(json.load(open('tmp/het/test_issue_types.json'))))" 2>/dev/null || echo "0")
    log_success "TEST issue types extracted: ${TEST_ISSUE_COUNT} instances"
    log_success "Saved to: tmp/het/test_issue_types.json"
else
    log_error "Failed to extract TEST issue types!"
    log_error "Check log: $LOG_DIR/stage3_extract_test_issue_types.log"
    exit 1
fi

# Verify train/test separation (no data leakage)
log_info "Verifying train/test separation..."
python << 'VERIFY_EOF'
import json

train = json.load(open('tmp/het/train_issue_types.json'))
test = json.load(open('tmp/het/test_issue_types.json'))
exp = json.load(open('tmp/het/verified_experience_tree.json'))

overlap = set(train.keys()) & set(test.keys())
test_in_exp = set(test.keys()) & set(exp.keys())

print(f"Train: {len(train)}, Test: {len(test)}, Exp: {len(exp)}")

if overlap:
    print(f"✗ OVERLAP: {len(overlap)} instances in both train and test!")
    exit(1)
else:
    print(f"✓ No train/test overlap")

if test_in_exp:
    print(f"✗ LEAKAGE: {len(test_in_exp)} test instances in experience tree!")
    exit(1)
else:
    print(f"✓ No test data in experience tree")
VERIFY_EOF

if [ $? -ne 0 ]; then
    log_error "Data leakage detected!"
    exit 1
fi
log_success "Train/test separation verified - no data leakage"

echo ""

################################################################################
# STAGE 4: TEST INSTANCES WITH EXPERIENCE (EXPERIENCE REUSE)
################################################################################

start_stage "4" "Run test instances WITH experience"

# Verify experience database
if [ ! -f "tmp/het/verified_experience_tree.json" ]; then
    log_error "Experience database not found - cannot proceed"
    exit 1
fi

log_success "Experience database ready (from train instances)"
log_info "Running ${TEST_ACTUAL_COUNT} test instances WITH experience..."

# Clear prediction file
> prediction_verified.jsonl

# Run test instances with experience
python workflow.py \
    --instance_ids "$ACTUAL_TEST_FILE" \
    --max_iterations 20 \
    --max_expansions 3 \
    --max_finished_nodes 1 \
    --experience \
    2>&1 | tee "$LOG_DIR/stage4_test_with_experience.log"

# Save experience results
mkdir -p django
WITH_EXP_FILE="django/test_with_experience_${TIMESTAMP}.jsonl"
if [ -f "prediction_verified.jsonl" ]; then
    cp prediction_verified.jsonl "$WITH_EXP_FILE"
    EXP_RESULTS=$(wc -l < prediction_verified.jsonl)
    EXP_PATCHES=$(grep -c '"model_patch":' prediction_verified.jsonl 2>/dev/null || echo "0")
    log_success "Experience test completed: ${EXP_RESULTS} results, ${EXP_PATCHES} patches"
    log_success "Saved to: $WITH_EXP_FILE"
else
    log_error "No experience test results generated!"
    exit 1
fi

echo ""

################################################################################
# STAGE 5: EVALUATE PATCHES (TEST BASELINE & WITH EXPERIENCE)
################################################################################

start_stage "5.1" "Evaluate baseline patches (WITHOUT experience)"
if ! bash evaluate.sh "$TEST_BASELINE_FILE" 2>&1 | tee "$LOG_DIR/stage5.1_evaluate_baseline.log"; then
    log_error "Baseline evaluation failed (see $LOG_DIR/stage5.1_evaluate_baseline.log)"
    exit 1
fi
BASELINE_EVAL_DIR=$(ls -td evaluation_results/eval_test_baseline_* 2>/dev/null | head -1)

start_stage "5.2" "Evaluate patches WITH experience"
if ! bash evaluate.sh "$WITH_EXP_FILE" 2>&1 | tee "$LOG_DIR/stage5.2_evaluate_with_experience.log"; then
    log_error "With-experience evaluation failed (see $LOG_DIR/stage5.2_evaluate_with_experience.log)"
    exit 1
fi
EXP_EVAL_DIR=$(ls -td evaluation_results/eval_test_with_experience_* 2>/dev/null | head -1)

if [ -n "$BASELINE_EVAL_DIR" ] && [ -f "$BASELINE_EVAL_DIR/report.json" ]; then
    BASELINE_RESOLVED=$(grep -o '"resolved": true' "$BASELINE_EVAL_DIR/report.json" | wc -l)
    BASELINE_TOTAL=$(python - <<'PY' "$BASELINE_EVAL_DIR/report.json"
import json,sys
print(len(json.load(open(sys.argv[1]))))
PY
)
    log_success "Baseline eval resolved: ${BASELINE_RESOLVED}/${BASELINE_TOTAL} (report: $BASELINE_EVAL_DIR/report.json)"
else
    log_warning "Baseline evaluation report not found"
fi

if [ -n "$EXP_EVAL_DIR" ] && [ -f "$EXP_EVAL_DIR/report.json" ]; then
    EXP_RESOLVED=$(grep -o '"resolved": true' "$EXP_EVAL_DIR/report.json" | wc -l)
    EXP_TOTAL=$(python - <<'PY' "$EXP_EVAL_DIR/report.json"
import json,sys
print(len(json.load(open(sys.argv[1]))))
PY
)
    log_success "With-experience eval resolved: ${EXP_RESOLVED}/${EXP_TOTAL} (report: $EXP_EVAL_DIR/report.json)"
else
    log_warning "With-experience evaluation report not found"
fi

# Build side-by-side comparison for actual test instances
start_stage "5.3" "Build baseline vs experience comparison"
python - <<'PY' "$TEST_BASELINE_FILE" "$WITH_EXP_FILE" "$BASELINE_EVAL_DIR" "$EXP_EVAL_DIR" "$TIMESTAMP" "$ACTUAL_TEST_FILE"
import json, os, sys
from pathlib import Path

baseline_file, exp_file, base_eval_dir, exp_eval_dir, ts, test_file = sys.argv[1:]

def load_jsonl(path):
    data = {}
    with open(path) as f:
        for line in f:
            line=line.strip()
            if not line:
                continue
            obj=json.loads(line)
            data[obj["instance_id"]]=obj.get("model_patch","")
    return data

def load_report(dir_path):
    rep=os.path.join(dir_path, "report.json")
    if not os.path.exists(rep):
        return {}
    data=json.load(open(rep))
    return {d["instance_id"]: bool(d.get("resolved")) for d in data}

test_ids=[line.strip() for line in open(test_file) if line.strip()]
baseline_patches=load_jsonl(baseline_file)
exp_patches=load_jsonl(exp_file) if os.path.exists(exp_file) else {}
baseline_res=load_report(base_eval_dir) if base_eval_dir else {}
exp_res=load_report(exp_eval_dir) if exp_eval_dir else {}

rows=[]
for tid in test_ids:
    rows.append({
        "instance_id": tid,
        "baseline_resolved": baseline_res.get(tid, False),
        "experience_resolved": exp_res.get(tid, False),
        "baseline_patch": baseline_patches.get(tid, ""),
        "experience_patch": exp_patches.get(tid, ""),
    })

out_dir=Path("evaluation_results")
out_dir.mkdir(exist_ok=True)
out_path=out_dir / f"comparison_{ts}.jsonl"
with open(out_path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")

base_acc=sum(1 for r in rows if r["baseline_resolved"]) / len(rows) if rows else 0
exp_acc=sum(1 for r in rows if r["experience_resolved"]) / len(rows) if rows else 0
print(f"[INFO] Baseline resolved: {sum(1 for r in rows if r['baseline_resolved'])}/{len(rows)} ({base_acc*100:.1f}%)")
print(f"[INFO] With-experience resolved: {sum(1 for r in rows if r['experience_resolved'])}/{len(rows)} ({exp_acc*100:.1f}%)")
print(f"[INFO] Comparison written to {out_path}")
PY

echo ""

################################################################################
# FINAL SUMMARY
################################################################################

log_success "========================================================================"
log_success "EXPERIENCE PIPELINE COMPLETED!"
log_success "========================================================================"
echo ""

log_info "EXECUTION SUMMARY:"
log_info "  Stage 1: Trajectory collection - COMPLETED (train ${TRAIN_ACTUAL_COUNT}/${TRAIN_EXPECTED_COUNT}, test ${TEST_ACTUAL_COUNT}/${TEST_EXPECTED_COUNT})"
log_info "  Stage 1.1: Train evaluation (Docker) - COMPLETED"
log_info "  Stage 2: Train issue type extraction - COMPLETED (${TRAIN_ISSUE_COUNT})"
log_info "  Stage 2.1: Experience tree building - COMPLETED (${EXP_COUNT})"
log_info "  Stage 3: Test issue type extraction - COMPLETED (${TEST_ISSUE_COUNT})"
log_info "  Stage 4: Test WITH experience - COMPLETED (${EXP_RESULTS} results)"
log_info "  Stage 5: Evaluation (baseline + with-experience) - COMPLETED"
echo ""

log_info "DATA FILES:"
log_info "  Train instances (expected): ${EXPECTED_TRAIN_FILE} (${TRAIN_EXPECTED_COUNT})"
log_info "  Train instances (actual):   ${ACTUAL_TRAIN_FILE} (${TRAIN_ACTUAL_COUNT})"
log_info "  Test instances (expected):  ${EXPECTED_TEST_FILE} (${TEST_EXPECTED_COUNT})"
log_info "  Test instances (actual):    ${ACTUAL_TEST_FILE} (${TEST_ACTUAL_COUNT})"
log_info "  Train issue types: tmp/het/train_issue_types.json (${TRAIN_ISSUE_COUNT})"
log_info "  Test issue types: tmp/het/test_issue_types.json (${TEST_ISSUE_COUNT})"
log_info "  Experience tree: tmp/het/verified_experience_tree.json (${EXP_COUNT})"
echo ""

log_info "RESULTS:"
log_info "  WITHOUT experience: $TEST_BASELINE_FILE (${TEST_BASELINE_COUNT} instances)"
log_info "  WITH experience: $WITH_EXP_FILE (${EXP_RESULTS} instances)"
echo ""

# Compare patch counts (with safe arithmetic)
BASELINE_PATCHES=$(grep -c '"model_patch":' "$TEST_BASELINE_FILE" 2>/dev/null || echo "0")
log_info "PATCH COMPARISON:"

# Safe percentage calculation
if [ ${TEST_BASELINE_COUNT} -gt 0 ]; then
    BASELINE_PCT=$((BASELINE_PATCHES * 100 / TEST_BASELINE_COUNT))
    log_info "  WITHOUT experience: ${BASELINE_PATCHES}/${TEST_BASELINE_COUNT} patches (${BASELINE_PCT}%)"
else
    log_info "  WITHOUT experience: ${BASELINE_PATCHES}/${TEST_BASELINE_COUNT} patches"
fi

if [ ${EXP_RESULTS} -gt 0 ]; then
    EXP_PCT=$((EXP_PATCHES * 100 / EXP_RESULTS))
    log_info "  WITH experience: ${EXP_PATCHES}/${EXP_RESULTS} patches (${EXP_PCT}%)"
else
    log_info "  WITH experience: ${EXP_PATCHES}/${EXP_RESULTS} patches"
fi

PATCH_DIFF=$((EXP_PATCHES - BASELINE_PATCHES))
if [ $PATCH_DIFF -gt 0 ]; then
    log_success "  Improvement: +${PATCH_DIFF} patches"
elif [ $PATCH_DIFF -lt 0 ]; then
    log_info "  Regression: ${PATCH_DIFF} patches"
else
    log_info "  No change in patch count"
fi

echo ""
log_info "NEXT STEPS:"
log_info "  1. Compare results: $TEST_BASELINE_FILE vs $WITH_EXP_FILE"
log_info "  2. Re-run evaluations if needed:"
log_info "       bash evaluate.sh $TEST_BASELINE_FILE"
log_info "       bash evaluate.sh $WITH_EXP_FILE"
echo ""

log_success "All logs saved to: ${LOG_DIR}/"
log_success "========================================================================"
