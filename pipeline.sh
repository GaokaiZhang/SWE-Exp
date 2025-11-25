#!/bin/bash
################################################################################
# EXPERIENCE PIPELINE - STAGES 1.5, 2-4
#
# Prerequisites: Stage 1 must be completed for all instances
#   - Train: 199 instances with trajectories in tmp/trajectory/
#   - Test: 30 instances with baseline results in django/test_baseline.jsonl
#
# This script:
#   1. Stage 1.5: (OPTIONAL) Evaluate train patches with Docker (~50 hours)
#   2. Stage 2: Extract issue types from 199 train trajectories
#   3. Stage 3: Build experience tree from 199 train trajectories
#   4. Stage 3.5: Extract issue types from 30 test instances
#   5. Stage 4: Test 30 instances WITH experience (from 199 train)
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
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

################################################################################
# SETUP
################################################################################

log_info "========================================================================"
log_info "EXPERIENCE PIPELINE - STAGES 2-4"
log_info "========================================================================"

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

# Verify prerequisites
TRAIN_TRAJECTORY_COUNT=$(ls tmp/trajectory/ 2>/dev/null | wc -l)
TEST_BASELINE_FILE="django/test_baseline.jsonl"
TEST_BASELINE_COUNT=$(wc -l < "$TEST_BASELINE_FILE" 2>/dev/null || echo "0")

log_info "Prerequisites check:"
log_info "  Train trajectories: ${TRAIN_TRAJECTORY_COUNT}/199"
log_info "  Test baseline: ${TEST_BASELINE_COUNT}/30 ($TEST_BASELINE_FILE)"

if [ ${TRAIN_TRAJECTORY_COUNT} -lt 199 ]; then
    log_error "Missing train trajectories! Expected 199, found ${TRAIN_TRAJECTORY_COUNT}"
    log_error "Please run: bash stage1.sh train train_instances.txt"
    exit 1
fi

if [ ${TEST_BASELINE_COUNT} -ne 30 ]; then
    log_error "Missing test baseline! Expected 30, found ${TEST_BASELINE_COUNT}"
    log_error "Please run: bash stage1.sh test test_instances.txt"
    exit 1
fi

log_success "All prerequisites met"

# Create directories
mkdir -p tmp/het
export PYTHONPATH=/home/gaokaizhang/SWE-Exp

echo ""

################################################################################
# STAGE 1.5: (OPTIONAL) EVALUATE TRAIN PATCHES WITH DOCKER
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
# - WITH evaluation (~50 hours for 199 instances):
#   ✅ Accurate success/failure classification from actual test results
#   ✅ Learn from both successful and failed solution patterns
#   ✅ Higher quality experience database
#   ❌ Requires ~50 hours (199 instances × 15 min each)
#   ❌ Significant computational resources
#
# - WITHOUT evaluation (default):
#   ✅ Fast pipeline execution (skip 50 hours)
#   ✅ Still generates useful failure analysis experiences
#   ✅ Good for quick experimentation
#   ❌ All training experiences treated as failures
#   ❌ Missing successful solution patterns from training set
#
# RECOMMENDATION:
# - Quick experimentation: Keep commented out (default)
# - Production/Research: Uncomment to enable full evaluation
#
################################################################################

# Stage 1.5: Enable training evaluation (ENABLED by default for correct experience classification)
log_info "========================================================================"
log_info "STAGE 1.5: Evaluate Train Patches with Docker"
log_info "========================================================================"
log_info "This evaluates 199 training patches to get accurate resolved status"
log_info "Estimated time: ~50 hours (199 instances × 15 min)"
echo ""

log_info "Evaluating django/train_baseline.jsonl with Docker..."
bash evaluate.sh django/train_baseline.jsonl 2>&1 | tee "$LOG_DIR/stage1.5_evaluate_train.log"

if [ $? -eq 0 ]; then
    # Find the evaluation results directory
    EVAL_DIR=$(ls -td evaluation_results/eval_train_baseline_* 2>/dev/null | head -1)

    if [ -f "$EVAL_DIR/report.json" ]; then
        log_success "Evaluation completed: $EVAL_DIR/report.json"

        # Merge evaluation results with trajectory data
        log_info "Merging resolved status into trajectory data..."
        python3 << 'PYEOF'
import json
import sys
import os

# Find evaluation directory
eval_dir = None
for d in sorted(os.listdir('evaluation_results'), reverse=True):
    if d.startswith('eval_train_baseline_'):
        eval_dir = os.path.join('evaluation_results', d)
        break

if not eval_dir:
    print("ERROR: Could not find evaluation results directory")
    sys.exit(1)

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

# Merge resolved status into trajectories
merged = []
resolved_count = 0
for result in eval_results:
    instance_id = result['instance_id']
    if instance_id in trajectories:
        traj = trajectories[instance_id]
        traj['resolved'] = result.get('resolved', False)
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
            RESOLVED=$(grep -o '"resolved": true' "$EVAL_DIR/report.json" | wc -l)
            log_info "Training evaluation results: ${RESOLVED}/199 resolved"
        else
            log_error "Failed to merge evaluation results!"
            exit 1
        fi
    else
        log_error "Evaluation report not found: $EVAL_DIR/report.json"
        exit 1
    fi
else
    log_error "Evaluation failed! Check log: $LOG_DIR/stage1.5_evaluate_train.log"
    exit 1
fi

echo ""

# Note: To skip Docker evaluation (saves 50 hours but all experiences will be FAILURES),
# comment out the above block and uncomment the following:
# log_info "========================================================================"
# log_info "STAGE 1.5: Skipping Docker Evaluation (Fast Mode)"
# log_info "========================================================================"
# log_info "Using train trajectories WITHOUT Docker evaluation"
# log_info "Note: All 199 training experiences will be classified as FAILURES"
# echo ""
# cp django/train_baseline.jsonl tmp/merged_leaf_analysis_with_trajectories.jsonl
# if [ $? -eq 0 ]; then
#     log_success "Prepared: tmp/merged_leaf_analysis_with_trajectories.jsonl"
#     log_info "File contains trajectory data without 'resolved' field"
# else
#     log_error "Failed to prepare evaluation file!"
#     exit 1
# fi

echo ""

################################################################################
# STAGE 2: EXTRACT ISSUE TYPES FROM 199 TRAIN INSTANCES
################################################################################

log_info "========================================================================"
log_info "STAGE 2: Extract Issue Types from 199 Train Instances"
log_info "========================================================================"

log_info "Extracting issue types from trajectories in tmp/trajectory/..."

python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    2>&1 | tee "$LOG_DIR/stage2_extract_issue_types.log"

# Merge batch files
log_info "Merging batch issue type files..."
python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    --merge \
    2>&1 | tee -a "$LOG_DIR/stage2_extract_issue_types.log"

# Save as TRAIN issue types (explicit train/test split)
if [ -f "tmp/verified_issue_types_merged.json" ]; then
    cp tmp/verified_issue_types_merged.json tmp/het/train_issue_types.json
    log_info "Saved TRAIN issue types to tmp/het/train_issue_types.json"
fi

if [ $? -eq 0 ] && [ -f "tmp/het/train_issue_types.json" ]; then
    TRAIN_ISSUE_COUNT=$(python -c "import json; print(len(json.load(open('tmp/het/train_issue_types.json'))))" 2>/dev/null || echo "0")
    log_success "TRAIN issue types extracted: ${TRAIN_ISSUE_COUNT} instances"
else
    log_error "Failed to extract TRAIN issue types!"
    log_error "Check log: $LOG_DIR/stage2_extract_issue_types.log"
    exit 1
fi

echo ""

################################################################################
# STAGE 3: BUILD EXPERIENCE TREE FROM 199 TRAIN INSTANCES
################################################################################

log_info "========================================================================"
log_info "STAGE 3: Build Experience Tree from 199 Train Instances"
log_info "========================================================================"

log_info "Mining experiences from 199 train trajectories..."

python moatless/experience/exp_agent/exp_agent.py \
    2>&1 | tee "$LOG_DIR/stage3_build_experience.log"

# Copy experience tree to tmp/het/ for workflow.py
if [ -f "tmp/verified_experience_tree.json" ]; then
    cp tmp/verified_experience_tree.json tmp/het/verified_experience_tree.json
    log_info "Copied experience tree to tmp/het/ for workflow.py"
fi

if [ $? -eq 0 ] && [ -f "tmp/het/verified_experience_tree.json" ]; then
    EXP_COUNT=$(python -c "import json; data=json.load(open('tmp/het/verified_experience_tree.json')); print(len(data))" 2>/dev/null || echo "0")
    log_success "Experience tree built: ${EXP_COUNT} instances"
    log_success "Saved to: tmp/het/verified_experience_tree.json"
else
    log_error "Failed to build experience tree!"
    log_error "Check log: $LOG_DIR/stage3_build_experience.log"
    exit 1
fi

echo ""

################################################################################
# STAGE 3.5: EXTRACT ISSUE TYPES FROM 30 TEST INSTANCES (NEW!)
################################################################################

log_info "========================================================================"
log_info "STAGE 3.5: Extract Issue Types from 30 Test Instances"
log_info "========================================================================"

log_info "Extracting test issue types for experience retrieval (no data leakage)"

# Create Python script to extract test issue types with retry logic
python << 'PYTHON_EOF' 2>&1 | tee "$LOG_DIR/stage3.5_extract_test_issue_types.log"
import json
import time
import sys
from moatless.benchmark.utils import get_moatless_instance
from moatless.experience.exp_agent.extract_verified_issue_types_batch import IssueAgent
from moatless.experience.prompts.exp_prompts import issue_type_system_prompt, issue_type_user_prompt
from moatless.completion.completion import CompletionModel
import os

# Load test instances
with open('test_instances.txt', 'r') as f:
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
    log_error "Check log: $LOG_DIR/stage3.5_extract_test_issue_types.log"
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
# STAGE 4: TEST 30 INSTANCES WITH EXPERIENCE (FROM 199 TRAIN)
################################################################################

log_info "========================================================================"
log_info "STAGE 4: Test 30 Instances WITH Experience (from 199 train)"
log_info "========================================================================"

# Verify experience database
if [ ! -f "tmp/het/verified_experience_tree.json" ]; then
    log_error "Experience database not found - cannot proceed"
    exit 1
fi

log_success "Experience database ready (from 199 train instances)"
log_info "Running 30 test instances WITH experience..."

# Clear prediction file
> prediction_verified.jsonl

# Run test instances with experience
python workflow.py \
    --instance_ids test_instances.txt \
    --max_iterations 20 \
    --max_expansions 3 \
    --max_finished_nodes 1 \
    --experience \
    2>&1 | tee "$LOG_DIR/stage4_test_with_experience.log"

# Save experience results
mkdir -p django
if [ -f "prediction_verified.jsonl" ]; then
    cp prediction_verified.jsonl "django/test_with_experience_${TIMESTAMP}.jsonl"
    EXP_RESULTS=$(wc -l < prediction_verified.jsonl)
    EXP_PATCHES=$(grep -c '"model_patch":' prediction_verified.jsonl 2>/dev/null || echo "0")
    log_success "Experience test completed: ${EXP_RESULTS} results, ${EXP_PATCHES} patches"
    log_success "Saved to: django/test_with_experience_${TIMESTAMP}.jsonl"
else
    log_error "No experience test results generated!"
    exit 1
fi

echo ""

################################################################################
# FINAL SUMMARY
################################################################################

log_success "========================================================================"
log_success "EXPERIENCE PIPELINE COMPLETED!"
log_success "========================================================================"
echo ""

log_info "EXECUTION SUMMARY:"
log_info "  Stage 2: Issue type extraction (199 train) - COMPLETED"
log_info "  Stage 3: Experience tree building (199 train) - COMPLETED"
log_info "  Stage 3.5: Issue type extraction (30 test) - COMPLETED (NEW!)"
log_info "  Stage 4: Test WITH experience (30 test) - COMPLETED"
echo ""

log_info "DATA FILES:"
log_info "  Train issue types: tmp/het/train_issue_types.json (${TRAIN_ISSUE_COUNT})"
log_info "  Test issue types: tmp/het/test_issue_types.json (${TEST_ISSUE_COUNT})"
log_info "  Experience tree: tmp/het/verified_experience_tree.json (${EXP_COUNT})"
echo ""

log_info "RESULTS:"
log_info "  WITHOUT experience: $TEST_BASELINE_FILE (${TEST_BASELINE_COUNT} instances)"
log_info "  WITH experience: django/test_with_experience_${TIMESTAMP}.jsonl (${EXP_RESULTS} instances)"
echo ""

# Compare patch counts (with safe arithmetic)
BASELINE_PATCHES=$(grep -c '"model_patch":' "$TEST_BASELINE_FILE" 2>/dev/null || echo "0")
log_info "PATCH COMPARISON:"

# Safe percentage calculation
if [ ${TEST_BASELINE_COUNT} -gt 0 ]; then
    BASELINE_PCT=$((BASELINE_PATCHES * 100 / TEST_BASELINE_COUNT))
    log_info "  WITHOUT experience: ${BASELINE_PATCHES}/30 patches (${BASELINE_PCT}%)"
else
    log_info "  WITHOUT experience: ${BASELINE_PATCHES}/30 patches"
fi

if [ ${EXP_RESULTS} -gt 0 ]; then
    EXP_PCT=$((EXP_PATCHES * 100 / EXP_RESULTS))
    log_info "  WITH experience: ${EXP_PATCHES}/30 patches (${EXP_PCT}%)"
else
    log_info "  WITH experience: ${EXP_PATCHES}/30 patches"
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
log_info "  1. Compare results: $TEST_BASELINE_FILE vs django/test_with_experience_${TIMESTAMP}.jsonl"
log_info "  2. Evaluate patches:"
log_info "       bash evaluate.sh django/test_baseline.jsonl"
log_info "       bash evaluate.sh django/test_with_experience_${TIMESTAMP}.jsonl"
echo ""

log_success "All logs saved to: ${LOG_DIR}/"
log_success "========================================================================"
