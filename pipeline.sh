#!/bin/bash
################################################################################
# EXPERIENCE PIPELINE - STAGES 2-4
#
# Prerequisites: Stage 1 must be completed for all instances
#   - Train: 201 instances with trajectories in tmp/trajectory/
#   - Test: 30 instances with baseline results in django/test_baseline_final.jsonl
#
# This script:
#   1. Stage 2: Extract issue types from 201 train trajectories
#   2. Stage 3: Build experience tree from 201 train trajectories
#   3. Stage 4: Test 30 instances WITH experience (from 201 train)
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
log_info "  Train trajectories: ${TRAIN_TRAJECTORY_COUNT}/201"
log_info "  Test baseline: ${TEST_BASELINE_COUNT}/30 ($TEST_BASELINE_FILE)"

if [ ${TRAIN_TRAJECTORY_COUNT} -lt 201 ]; then
    log_error "Missing train trajectories! Expected 201, found ${TRAIN_TRAJECTORY_COUNT}"
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
# STAGE 2: EXTRACT ISSUE TYPES FROM 201 TRAIN INSTANCES
################################################################################

log_info "========================================================================"
log_info "STAGE 2: Extract Issue Types from 201 Train Instances"
log_info "========================================================================"

log_info "Extracting issue types from trajectories in tmp/trajectory/..."

python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    2>&1 | tee "$LOG_DIR/stage2_extract_issue_types.log"

if [ $? -eq 0 ] && [ -f "tmp/het/verified_issue_types_final.json" ]; then
    ISSUE_COUNT=$(python -c "import json; print(len(json.load(open('tmp/het/verified_issue_types_final.json'))))" 2>/dev/null || echo "0")
    log_success "Issue types extracted: ${ISSUE_COUNT} instances"
    log_success "Saved to: tmp/het/verified_issue_types_final.json"
else
    log_error "Failed to extract issue types!"
    log_error "Check log: $LOG_DIR/stage2_extract_issue_types.log"
    exit 1
fi

echo ""

################################################################################
# STAGE 3: BUILD EXPERIENCE TREE FROM 201 TRAIN INSTANCES
################################################################################

log_info "========================================================================"
log_info "STAGE 3: Build Experience Tree from 201 Train Instances"
log_info "========================================================================"

log_info "Mining experiences from 201 train trajectories..."

python moatless/experience/exp_agent/exp_agent.py \
    2>&1 | tee "$LOG_DIR/stage3_build_experience.log"

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
# STAGE 4: TEST 30 INSTANCES WITH EXPERIENCE (FROM 201 TRAIN)
################################################################################

log_info "========================================================================"
log_info "STAGE 4: Test 30 Instances WITH Experience (from 201 train)"
log_info "========================================================================"

# Verify experience database
if [ ! -f "tmp/het/verified_experience_tree.json" ]; then
    log_error "Experience database not found - cannot proceed"
    exit 1
fi

log_success "Experience database ready (from 201 train instances)"
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
log_info "  Stage 2: Issue type extraction (201 train) - COMPLETED"
log_info "  Stage 3: Experience tree building (201 train) - COMPLETED"
log_info "  Stage 4: Test WITH experience (30 test) - COMPLETED"
echo ""

log_info "RESULTS:"
log_info "  WITHOUT experience: $TEST_BASELINE_FILE (${TEST_BASELINE_COUNT} instances)"
log_info "  WITH experience: django/test_with_experience_${TIMESTAMP}.jsonl (${EXP_RESULTS} instances)"
echo ""

# Compare patch counts
BASELINE_PATCHES=$(grep -c '"model_patch":' "$TEST_BASELINE_FILE" 2>/dev/null || echo "0")
log_info "PATCH COMPARISON:"
log_info "  WITHOUT experience: ${BASELINE_PATCHES}/30 patches ($((BASELINE_PATCHES * 100 / 30))%)"
log_info "  WITH experience: ${EXP_PATCHES}/30 patches ($((EXP_PATCHES * 100 / 30))%)"

PATCH_DIFF=$((EXP_PATCHES - BASELINE_PATCHES))
if [ $PATCH_DIFF -gt 0 ]; then
    log_success "  Improvement: +${PATCH_DIFF} patches (+$((PATCH_DIFF * 100 / 30))%)"
elif [ $PATCH_DIFF -lt 0 ]; then
    log_info "  Change: ${PATCH_DIFF} patches ($((PATCH_DIFF * 100 / 30))%)"
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
