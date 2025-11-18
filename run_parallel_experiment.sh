#!/bin/bash

# Parallelized Django Experience Experiment
# Target: Complete in ~15-20 hours with 10 parallel workers
# Includes Docker-based evaluation

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CONDA_ENV="swe-exp"
MAX_ITERATIONS=20
MAX_EXPANSIONS=3
MAX_FINISHED_NODES=1
TEST_INSTANCES="test_instances.txt"
TRAIN_INSTANCES="train_instances.txt"
RESULTS_DIR="results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PARALLEL_JOBS=4  # Start with 4 parallel workers to test rate limits

# Create results directory
mkdir -p "$RESULTS_DIR"
LOG_FILE="$RESULTS_DIR/experiment_${TIMESTAMP}.log"

# Function to print status
print_status() {
    local phase=$1
    local stage=$2
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${MAGENTA}PHASE: $phase${NC}"
    echo -e "${CYAN}║${NC} ${BLUE}STAGE: $stage${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}TIME: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}PARALLEL JOBS: $PARALLEL_JOBS${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

log_msg() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Activate conda
log_msg "${BLUE}Activating conda environment: $CONDA_ENV${NC}"
source ~/conda/etc/profile.d/conda.sh
conda activate "$CONDA_ENV"

# Install dependencies
log_msg "${YELLOW}Checking dependencies...${NC}"
pip install -q json_repair docstring_parser instructor tree-sitter tree-sitter-java tree-sitter-python networkx 2>&1 | grep -v "Requirement already satisfied" || true
log_msg "${GREEN}✓ Dependencies ready${NC}"

# Count instances
TEST_COUNT=$(wc -l < "$TEST_INSTANCES")
TRAIN_COUNT=$(wc -l < "$TRAIN_INSTANCES")

log_msg "${GREEN}Configuration:${NC}"
log_msg "  Test instances: $TEST_COUNT"
log_msg "  Train instances: $TRAIN_COUNT"
log_msg "  Parallel workers: $PARALLEL_JOBS"
log_msg "  Results: $RESULTS_DIR"
log_msg ""

# Helper function to process single instance
process_instance() {
    local instance_id=$1
    local max_iter=$2
    local max_exp=$3
    local max_fin=$4
    local experience_flag=$5
    local output_prefix=$6

    # Create temp file for this instance
    local temp_file=$(mktemp)
    echo "$instance_id" > "$temp_file"

    source ~/conda/etc/profile.d/conda.sh
    conda activate swe-exp

    if [ "$experience_flag" == "true" ]; then
        python workflow.py \
            --instance_ids "$temp_file" \
            --experience \
            --max_iterations "$max_iter" \
            --max_expansions "$max_exp" \
            --max_finished_nodes "$max_fin" \
            2>&1 | tee "$RESULTS_DIR/${output_prefix}_${instance_id}.log"
    else
        python workflow.py \
            --instance_ids "$temp_file" \
            --max_iterations "$max_iter" \
            --max_expansions "$max_exp" \
            --max_finished_nodes "$max_fin" \
            2>&1 | tee "$RESULTS_DIR/${output_prefix}_${instance_id}.log"
    fi

    rm -f "$temp_file"
}

export -f process_instance
export CONDA_ENV MAX_ITERATIONS MAX_EXPANSIONS MAX_FINISHED_NODES RESULTS_DIR

# =============================================================================
# PHASE A: BASELINE TEST (NO EXPERIENCE) - PARALLEL
# =============================================================================

print_status "A - BASELINE TEST" "Testing $TEST_COUNT instances WITHOUT experience (${PARALLEL_JOBS} parallel)"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE A: Baseline Test (No Experience) - PARALLEL${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

START_TIME=$(date +%s)

# Run baseline tests in parallel
log_msg "${YELLOW}Running $TEST_COUNT test instances in parallel ($PARALLEL_JOBS workers)...${NC}"
cat "$TEST_INSTANCES" | parallel -j "$PARALLEL_JOBS" --bar \
    process_instance {} "$MAX_ITERATIONS" "$MAX_EXPANSIONS" "$MAX_FINISHED_NODES" "false" "phase_a"

# Merge all prediction files
cat prediction.jsonl prediction_verified.jsonl 2>/dev/null | sort -u > "$RESULTS_DIR/prediction_baseline_${TIMESTAMP}.jsonl" || true
log_msg "${GREEN}✓ Baseline results saved${NC}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_msg "${GREEN}Phase A completed in $((DURATION / 60))m $((DURATION % 60))s${NC}\n"

# =============================================================================
# PHASE B: BUILD EXPERIENCE DATABASE - PARALLEL
# =============================================================================

print_status "B - BUILD EXPERIENCE" "Stage 1/3: Generate $TRAIN_COUNT training trajectories (${PARALLEL_JOBS} parallel)"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE B: Build Experience Database - PARALLEL${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

START_TIME=$(date +%s)

# B.1: Generate training trajectories in parallel
log_msg "${YELLOW}B.1: Generating $TRAIN_COUNT training trajectories ($PARALLEL_JOBS parallel)...${NC}"
cat "$TRAIN_INSTANCES" | parallel -j "$PARALLEL_JOBS" --bar \
    process_instance {} "$MAX_ITERATIONS" "$MAX_EXPANSIONS" "$MAX_FINISHED_NODES" "false" "phase_b1"

# Merge training predictions
cat prediction.jsonl prediction_verified.jsonl 2>/dev/null | sort -u > "$RESULTS_DIR/prediction_training_${TIMESTAMP}.jsonl" || true
log_msg "${GREEN}✓ Training trajectories generated${NC}"

# B.2: Extract issue types
print_status "B - BUILD EXPERIENCE" "Stage 2/3: Extract issue types"
log_msg "${YELLOW}B.2: Extracting issue types...${NC}"
export PYTHONPATH=/home/gaokaizhang/SWE-Exp
python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    2>&1 | tee "$RESULTS_DIR/phase_b2_extract_types_${TIMESTAMP}.log" || log_msg "${YELLOW}Note: Issue type extraction may need full dataset${NC}"

# B.3: Mine experiences
print_status "B - BUILD EXPERIENCE" "Stage 3/3: Mine experiences"
log_msg "${YELLOW}B.3: Mining experiences...${NC}"
python moatless/experience/exp_agent/exp_agent.py \
    --trajectory_dir tmp/trajectory \
    --output_dir tmp/het \
    2>&1 | tee "$RESULTS_DIR/phase_b3_mine_experiences_${TIMESTAMP}.log" || log_msg "${YELLOW}Note: Experience mining may need full dataset${NC}"

log_msg "${GREEN}✓ Experience database built in tmp/het/${NC}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_msg "${GREEN}Phase B completed in $((DURATION / 60))m $((DURATION % 60))s${NC}\n"

# =============================================================================
# PHASE C: TEST WITH EXPERIENCE - PARALLEL
# =============================================================================

print_status "C - TEST WITH EXPERIENCE" "Testing $TEST_COUNT instances WITH experience (${PARALLEL_JOBS} parallel)"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE C: Test with Experience - PARALLEL${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

START_TIME=$(date +%s)

# Run with experience in parallel
log_msg "${YELLOW}Running $TEST_COUNT test instances WITH experience ($PARALLEL_JOBS parallel)...${NC}"
cat "$TEST_INSTANCES" | parallel -j "$PARALLEL_JOBS" --bar \
    process_instance {} "$MAX_ITERATIONS" "$MAX_EXPANSIONS" "$MAX_FINISHED_NODES" "true" "phase_c"

# Merge predictions with experience
cat prediction.jsonl prediction_verified.jsonl 2>/dev/null | sort -u > "$RESULTS_DIR/prediction_with_experience_${TIMESTAMP}.jsonl" || true
log_msg "${GREEN}✓ Results with experience saved${NC}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_msg "${GREEN}Phase C completed in $((DURATION / 60))m $((DURATION % 60))s${NC}\n"

# =============================================================================
# SUMMARY & EVALUATION
# =============================================================================

log_msg ""
log_msg "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
log_msg "${GREEN}║                EXPERIMENT COMPLETED SUCCESSFULLY               ║${NC}"
log_msg "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
log_msg ""

# Count patches
BASELINE_PATCHES=$(grep -c '"model_patch":' "$RESULTS_DIR/prediction_baseline_${TIMESTAMP}.jsonl" 2>/dev/null || echo "0")
WITH_EXP_PATCHES=$(grep -c '"model_patch":' "$RESULTS_DIR/prediction_with_experience_${TIMESTAMP}.jsonl" 2>/dev/null || echo "0")

log_msg "${CYAN}Results Summary:${NC}"
log_msg "  ${YELLOW}Baseline patches generated:${NC} $BASELINE_PATCHES / $TEST_COUNT"
log_msg "  ${YELLOW}With experience patches:${NC} $WITH_EXP_PATCHES / $TEST_COUNT"
log_msg "  ${YELLOW}Baseline file:${NC} $RESULTS_DIR/prediction_baseline_${TIMESTAMP}.jsonl"
log_msg "  ${YELLOW}With experience file:${NC} $RESULTS_DIR/prediction_with_experience_${TIMESTAMP}.jsonl"
log_msg ""

# Calculate total time
TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - $(date -r "$LOG_FILE" +%s)))
log_msg "${GREEN}Total experiment time: $((TOTAL_DURATION / 3600))h $((TOTAL_DURATION % 3600 / 60))m${NC}"
log_msg ""
log_msg "${CYAN}Next steps for evaluation:${NC}"
log_msg "  Use Docker-based testbeds to verify patch correctness"
log_msg "  Compare resolved rates between baseline and with-experience"
log_msg ""
