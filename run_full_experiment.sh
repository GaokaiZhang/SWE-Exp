#!/bin/bash

# Full Django Experience Experiment Script
# This script runs a complete 3-phase experiment:
# Phase A: Baseline test (50 instances, no experience)
# Phase B: Build experience (181 training instances)
# Phase C: Test with experience (same 50 instances)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CONDA_ENV="swe-exp"
MAX_ITERATIONS=20
MAX_EXPANSIONS=3
MAX_FINISHED_NODES=1
TEST_INSTANCES="test_instances.txt"
TRAIN_INSTANCES="train_instances.txt"
RESULTS_DIR="results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create results directory
mkdir -p "$RESULTS_DIR"

# Log file
LOG_FILE="$RESULTS_DIR/experiment_${TIMESTAMP}.log"

# Function to print status bar
print_status() {
    local phase=$1
    local stage=$2
    local instance=$3
    local total=$4

    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${MAGENTA}PHASE: $phase${NC}"
    echo -e "${CYAN}║${NC} ${BLUE}STAGE: $stage${NC}"
    if [ -n "$instance" ] && [ -n "$total" ]; then
        echo -e "${CYAN}║${NC} ${YELLOW}PROGRESS: Instance $instance/$total${NC}"
    fi
    echo -e "${CYAN}║${NC} ${GREEN}TIME: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

# Function to log messages
log_msg() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Activate conda environment
log_msg "${BLUE}Activating conda environment: $CONDA_ENV${NC}"
source ~/conda/etc/profile.d/conda.sh
conda activate "$CONDA_ENV"

# Install missing dependencies
log_msg "${YELLOW}Checking dependencies...${NC}"
pip install -q json_repair docstring_parser instructor tree-sitter tree-sitter-java tree-sitter-python 2>&1 | grep -v "Requirement already satisfied" || true
log_msg "${GREEN}✓ Dependencies ready${NC}"

# Count instances
TEST_COUNT=$(wc -l < "$TEST_INSTANCES")
TRAIN_COUNT=$(wc -l < "$TRAIN_INSTANCES")

log_msg "${GREEN}Configuration:${NC}"
log_msg "  Test instances: $TEST_COUNT (from $TEST_INSTANCES)"
log_msg "  Train instances: $TRAIN_COUNT (from $TRAIN_INSTANCES)"
log_msg "  Max iterations: $MAX_ITERATIONS"
log_msg "  Results directory: $RESULTS_DIR"
log_msg ""

# =============================================================================
# PHASE A: BASELINE TEST (NO EXPERIENCE)
# =============================================================================

print_status "A - BASELINE TEST" "Testing WITHOUT experience" "" ""
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE A: Baseline Test (No Experience)${NC}"
log_msg "${MAGENTA}  Testing $TEST_COUNT instances WITHOUT experience${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

START_TIME=$(date +%s)

log_msg "${YELLOW}Running workflow on test instances (no experience)...${NC}"
python workflow.py \
    --instance_ids "$TEST_INSTANCES" \
    --max_iterations "$MAX_ITERATIONS" \
    --max_expansions "$MAX_EXPANSIONS" \
    --max_finished_nodes "$MAX_FINISHED_NODES" \
    2>&1 | tee "$RESULTS_DIR/phase_a_baseline_${TIMESTAMP}.log"

# Move prediction file
if [ -f "prediction.jsonl" ]; then
    mv prediction.jsonl "$RESULTS_DIR/prediction_baseline_${TIMESTAMP}.jsonl"
    log_msg "${GREEN}✓ Baseline results saved to: $RESULTS_DIR/prediction_baseline_${TIMESTAMP}.jsonl${NC}"
else
    log_msg "${RED}✗ Warning: prediction.jsonl not found${NC}"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_msg "${GREEN}Phase A completed in $((DURATION / 60))m $((DURATION % 60))s${NC}\n"

# =============================================================================
# PHASE B: BUILD EXPERIENCE DATABASE
# =============================================================================

print_status "B - BUILD EXPERIENCE" "Stage 1/3: Generate training trajectories" "0" "$TRAIN_COUNT"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE B: Build Experience Database${NC}"
log_msg "${MAGENTA}  Training on $TRAIN_COUNT instances${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

START_TIME=$(date +%s)

# Stage B.1: Generate training trajectories
print_status "B - BUILD EXPERIENCE" "Stage 1/3: Generate training trajectories" "" ""
log_msg "${YELLOW}B.1: Generating training trajectories (no experience)...${NC}"
python workflow.py \
    --instance_ids "$TRAIN_INSTANCES" \
    --max_iterations "$MAX_ITERATIONS" \
    --max_expansions "$MAX_EXPANSIONS" \
    --max_finished_nodes "$MAX_FINISHED_NODES" \
    2>&1 | tee "$RESULTS_DIR/phase_b1_train_trajectories_${TIMESTAMP}.log"

# Move training results
if [ -f "prediction.jsonl" ]; then
    mv prediction.jsonl "$RESULTS_DIR/prediction_training_${TIMESTAMP}.jsonl"
    log_msg "${GREEN}✓ Training results saved${NC}"
fi

# Stage B.2: Extract issue types
print_status "B - BUILD EXPERIENCE" "Stage 2/3: Extract issue types" "" ""
log_msg "${YELLOW}B.2: Extracting issue types from trajectories...${NC}"
PYTHONPATH=$PWD python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    --trajectory_dir tmp/trajectory \
    2>&1 | tee "$RESULTS_DIR/phase_b2_extract_types_${TIMESTAMP}.log"

log_msg "${GREEN}✓ Issue types extracted${NC}"

# Stage B.3: Mine experiences
print_status "B - BUILD EXPERIENCE" "Stage 3/3: Mine experiences from trajectories" "" ""
log_msg "${YELLOW}B.3: Mining experiences and building HET database...${NC}"
PYTHONPATH=$PWD python moatless/experience/exp_agent/exp_agent.py \
    --trajectory_dir tmp/trajectory \
    --output_dir tmp/het \
    2>&1 | tee "$RESULTS_DIR/phase_b3_mine_experiences_${TIMESTAMP}.log"

log_msg "${GREEN}✓ Experience database built in tmp/het/${NC}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_msg "${GREEN}Phase B completed in $((DURATION / 60))m $((DURATION % 60))s${NC}\n"

# =============================================================================
# PHASE C: TEST WITH EXPERIENCE
# =============================================================================

print_status "C - TEST WITH EXPERIENCE" "Testing WITH experience" "" ""
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE C: Test with Experience${NC}"
log_msg "${MAGENTA}  Testing $TEST_COUNT instances WITH experience${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

START_TIME=$(date +%s)

log_msg "${YELLOW}Running workflow on test instances WITH experience...${NC}"
python workflow.py \
    --instance_ids "$TEST_INSTANCES" \
    --experience \
    --max_iterations "$MAX_ITERATIONS" \
    --max_expansions "$MAX_EXPANSIONS" \
    --max_finished_nodes "$MAX_FINISHED_NODES" \
    2>&1 | tee "$RESULTS_DIR/phase_c_with_experience_${TIMESTAMP}.log"

# Move prediction file
if [ -f "prediction.jsonl" ]; then
    mv prediction.jsonl "$RESULTS_DIR/prediction_with_experience_${TIMESTAMP}.jsonl"
    log_msg "${GREEN}✓ Results with experience saved to: $RESULTS_DIR/prediction_with_experience_${TIMESTAMP}.jsonl${NC}"
else
    log_msg "${RED}✗ Warning: prediction.jsonl not found${NC}"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_msg "${GREEN}Phase C completed in $((DURATION / 60))m $((DURATION % 60))s${NC}\n"

# =============================================================================
# EXPERIMENT COMPLETE
# =============================================================================

log_msg ""
log_msg "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
log_msg "${GREEN}║                EXPERIMENT COMPLETED SUCCESSFULLY               ║${NC}"
log_msg "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
log_msg ""
log_msg "${CYAN}Results Summary:${NC}"
log_msg "  ${YELLOW}Baseline (no experience):${NC} $RESULTS_DIR/prediction_baseline_${TIMESTAMP}.jsonl"
log_msg "  ${YELLOW}Training results:${NC} $RESULTS_DIR/prediction_training_${TIMESTAMP}.jsonl"
log_msg "  ${YELLOW}With experience:${NC} $RESULTS_DIR/prediction_with_experience_${TIMESTAMP}.jsonl"
log_msg "  ${YELLOW}Experience database:${NC} tmp/het/"
log_msg ""
log_msg "${CYAN}To compare results:${NC}"
log_msg "  diff $RESULTS_DIR/prediction_baseline_${TIMESTAMP}.jsonl $RESULTS_DIR/prediction_with_experience_${TIMESTAMP}.jsonl"
log_msg ""
log_msg "${CYAN}Full log:${NC} $LOG_FILE"
log_msg ""

# Calculate total time
TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - $(date -r "$LOG_FILE" +%s)))
log_msg "${GREEN}Total experiment time: $((TOTAL_DURATION / 3600))h $((TOTAL_DURATION % 3600 / 60))m${NC}"
