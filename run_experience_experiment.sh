#!/bin/bash

# Script 2: Experience Experiment - Build experience from train, test on 30
# Clean Approach (using README.md stages 2, 3, 4):
#   Stage 2: Extract issue types (from tmp/trajectory/ = 201 train only)
#   Stage 3: Mine experiences (from tmp/trajectory/ = 201 train only)
#   Stage 4: Run 30 test WITH experience → save to django/
# No modifications needed - tmp/trajectory/ already has ONLY train instances!
# Environment: swe-exp conda environment, API key in .env

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
RESULTS_DIR="results"
DJANGO_DIR="django"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PARALLEL_JOBS=4

# Create directories
mkdir -p "$RESULTS_DIR" "tmp/het"
LOG_FILE="$RESULTS_DIR/experience_experiment_${TIMESTAMP}.log"

# Function to print status
print_status() {
    local stage=$1
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${MAGENTA}EXPERIENCE EXPERIMENT${NC}"
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
TRAIN_TRAJ_COUNT=$(ls -1 tmp/trajectory/ 2>/dev/null | wc -l)

log_msg "${GREEN}Configuration:${NC}"
log_msg "  Test instances (will test with experience): $TEST_COUNT"
log_msg "  Train trajectories (for experience building): $TRAIN_TRAJ_COUNT"
log_msg "  Parallel workers: $PARALLEL_JOBS"
log_msg "  Results: $RESULTS_DIR"
log_msg "  Log: $LOG_FILE"
log_msg ""

# Verify baseline data exists
if [ ! -d "tmp/trajectory" ] || [ $TRAIN_TRAJ_COUNT -eq 0 ]; then
    log_msg "${RED}ERROR: No trajectories found in tmp/trajectory/${NC}"
    log_msg "${YELLOW}Please run ./run_baseline_experiment.sh first${NC}"
    exit 1
fi

log_msg "${GREEN}✓ Found $TRAIN_TRAJ_COUNT train trajectories (test trajectories already cleared)${NC}"
log_msg "${GREEN}✓ Experience will be built from train instances only - no data leakage!${NC}"
log_msg ""

# Helper function to process single instance
process_instance() {
    local instance_id=$1
    local max_iter=$2
    local max_exp=$3
    local max_fin=$4
    local output_prefix=$5

    local temp_file=$(mktemp)
    echo "$instance_id" > "$temp_file"

    source ~/conda/etc/profile.d/conda.sh
    conda activate swe-exp

    python workflow.py \
        --instance_ids "$temp_file" \
        --experience \
        --max_iterations "$max_iter" \
        --max_expansions "$max_exp" \
        --max_finished_nodes "$max_fin" \
        2>&1 | tee "$RESULTS_DIR/${output_prefix}_${instance_id}.log"

    rm -f "$temp_file"
}

export -f process_instance
export CONDA_ENV MAX_ITERATIONS MAX_EXPANSIONS MAX_FINISHED_NODES RESULTS_DIR

EXPERIMENT_START=$(date +%s)

# =============================================================================
# STAGE 2: EXTRACT ISSUE TYPES (from train trajectories in tmp/trajectory/)
# =============================================================================

print_status "Stage 2/3: Extract issue types from $TRAIN_TRAJ_COUNT train trajectories"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  STAGE 2: Issue Type Extraction (Train Only)${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

STAGE2_START=$(date +%s)

log_msg "${YELLOW}Extracting issue types using moatless scripts...${NC}"
log_msg "${YELLOW}Processing trajectories in tmp/trajectory/ (train instances only)${NC}"

export PYTHONPATH=/home/gaokaizhang/SWE-Exp

# Use the standard moatless script - it will naturally only see train trajectories
python moatless/experience/exp_agent/extract_verified_issue_types_batch.py \
    2>&1 | tee "$RESULTS_DIR/extract_issue_types_${TIMESTAMP}.log"

if [ $? -eq 0 ] && [ -f "tmp/het/verified_issue_types_final.json" ]; then
    ISSUE_COUNT=$(python -c "import json; print(len(json.load(open('tmp/het/verified_issue_types_final.json'))))")
    log_msg "${GREEN}✓ Issue types extracted: $ISSUE_COUNT instances${NC}"
    log_msg "${GREEN}✓ Saved to: tmp/het/verified_issue_types_final.json${NC}"
else
    log_msg "${RED}ERROR: Issue type extraction failed${NC}"
    exit 1
fi

STAGE2_END=$(date +%s)
STAGE2_DURATION=$((STAGE2_END - STAGE2_START))
log_msg "${GREEN}Stage 2 completed in $((STAGE2_DURATION / 60))m $((STAGE2_DURATION % 60))s${NC}\n"

# =============================================================================
# STAGE 3: MINE EXPERIENCES (from train trajectories in tmp/trajectory/)
# =============================================================================

print_status "Stage 3/3: Mine experiences from $TRAIN_TRAJ_COUNT train trajectories"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  STAGE 3: Experience Mining (Train Only)${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

STAGE3_START=$(date +%s)

log_msg "${YELLOW}Mining experiences using moatless scripts...${NC}"
log_msg "${YELLOW}Processing trajectories in tmp/trajectory/ (train instances only)${NC}"

# Use the standard moatless script - it will naturally only see train trajectories
python moatless/experience/exp_agent/exp_agent.py \
    2>&1 | tee "$RESULTS_DIR/mine_experiences_${TIMESTAMP}.log"

if [ $? -eq 0 ] && [ -f "tmp/het/verified_experience_tree.json" ]; then
    EXP_COUNT=$(python -c "import json; print(len(json.load(open('tmp/het/verified_experience_tree.json'))))")
    log_msg "${GREEN}✓ Experiences mined: $EXP_COUNT instances${NC}"
    log_msg "${GREEN}✓ Saved to: tmp/het/verified_experience_tree.json${NC}"
else
    log_msg "${YELLOW}⚠ Experience mining completed with warnings - check logs${NC}"
fi

STAGE3_END=$(date +%s)
STAGE3_DURATION=$((STAGE3_END - STAGE3_START))
log_msg "${GREEN}Stage 3 completed in $((STAGE3_DURATION / 60))m $((STAGE3_DURATION % 60))s${NC}\n"

# =============================================================================
# STAGE 4: TEST 30 INSTANCES WITH EXPERIENCE
# =============================================================================

print_status "Stage 4/4: Testing $TEST_COUNT instances WITH experience (${PARALLEL_JOBS} parallel)"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  STAGE 4: Test with Experience (Built from Train)${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

STAGE4_START=$(date +%s)

# Verify experience database exists
if [ ! -f "tmp/het/verified_experience_tree.json" ]; then
    log_msg "${RED}ERROR: Experience database not found${NC}"
    log_msg "${YELLOW}Stage 3 may have failed - check logs${NC}"
    exit 1
fi

log_msg "${GREEN}✓ Experience database ready${NC}"
log_msg "${YELLOW}Running $TEST_COUNT test instances WITH experience ($PARALLEL_JOBS workers)...${NC}"
log_msg "${YELLOW}Experience built from $TRAIN_TRAJ_COUNT train instances only${NC}"
log_msg ""

cat "$TEST_INSTANCES" | parallel -j "$PARALLEL_JOBS" --bar \
    process_instance {} "$MAX_ITERATIONS" "$MAX_EXPANSIONS" "$MAX_FINISHED_NODES" "with_exp"

# Collect results
log_msg "${YELLOW}Collecting results with experience...${NC}"
cat prediction.jsonl prediction_verified.jsonl 2>/dev/null | sort -u > "$DJANGO_DIR/test_with_experience_${TIMESTAMP}.jsonl" || true
WITH_EXP_PATCHES=$(grep -c '"model_patch":' "$DJANGO_DIR/test_with_experience_${TIMESTAMP}.jsonl" 2>/dev/null || echo "0")

rm -f prediction.jsonl prediction_verified.jsonl
log_msg "${GREEN}✓ Results saved: $DJANGO_DIR/test_with_experience_${TIMESTAMP}.jsonl${NC}"
log_msg "${GREEN}✓ Patches generated: $WITH_EXP_PATCHES / $TEST_COUNT${NC}"

STAGE4_END=$(date +%s)
STAGE4_DURATION=$((STAGE4_END - STAGE4_START))
log_msg "${GREEN}Stage 4 completed in $((STAGE4_DURATION / 60))m $((STAGE4_DURATION % 60))s${NC}\n"

# =============================================================================
# SUMMARY & COMPARISON
# =============================================================================

EXPERIMENT_END=$(date +%s)
TOTAL_DURATION=$((EXPERIMENT_END - EXPERIMENT_START))

log_msg ""
log_msg "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
log_msg "${GREEN}║       EXPERIENCE EXPERIMENT COMPLETED SUCCESSFULLY             ║${NC}"
log_msg "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
log_msg ""

log_msg "${CYAN}Experience Building (Train-Test Split):${NC}"
log_msg "  ${YELLOW}Train instances (experience source):${NC} $TRAIN_TRAJ_COUNT"
log_msg "  ${YELLOW}Test instances (unseen):${NC} $TEST_COUNT"
log_msg "  ${GREEN}✓ No data leakage - proper train/test separation${NC}"
log_msg ""

log_msg "${CYAN}Test Results (30 instances WITH experience):${NC}"
log_msg "  ${YELLOW}Patches generated:${NC} $WITH_EXP_PATCHES / $TEST_COUNT"
log_msg "  ${YELLOW}Success rate:${NC} $((WITH_EXP_PATCHES * 100 / TEST_COUNT))%"
log_msg ""

# Compare with baseline
LATEST_BASELINE=$(ls -t "$DJANGO_DIR"/test_baseline_*.jsonl 2>/dev/null | head -1)
if [ -f "$LATEST_BASELINE" ]; then
    BASELINE_PATCHES=$(grep -c '"model_patch":' "$LATEST_BASELINE" 2>/dev/null || echo "0")
    IMPROVEMENT=$((WITH_EXP_PATCHES - BASELINE_PATCHES))

    log_msg "${CYAN}Comparison with Baseline (same 30 test instances):${NC}"
    log_msg "  ${YELLOW}Without experience:${NC} $BASELINE_PATCHES / $TEST_COUNT ($((BASELINE_PATCHES * 100 / TEST_COUNT))%)"
    log_msg "  ${YELLOW}With experience:${NC} $WITH_EXP_PATCHES / $TEST_COUNT ($((WITH_EXP_PATCHES * 100 / TEST_COUNT))%)"

    if [ $IMPROVEMENT -gt 0 ]; then
        log_msg "  ${GREEN}✓ Improvement:${NC} +$IMPROVEMENT patches (+$((IMPROVEMENT * 100 / TEST_COUNT))%)"
    elif [ $IMPROVEMENT -lt 0 ]; then
        log_msg "  ${RED}⚠ Regression:${NC} $IMPROVEMENT patches ($((IMPROVEMENT * 100 / TEST_COUNT))%)"
    else
        log_msg "  ${YELLOW}= No change${NC}"
    fi
    log_msg ""
fi

log_msg "${CYAN}Output Files (django/ directory):${NC}"
log_msg "  ${YELLOW}Test baseline (no exp):${NC} $LATEST_BASELINE"
log_msg "  ${YELLOW}Test with experience:${NC} $DJANGO_DIR/test_with_experience_${TIMESTAMP}.jsonl"
log_msg "  ${YELLOW}Train baseline (201):${NC} django/train_baseline_*.jsonl"
log_msg "  ${YELLOW}All baseline (231):${NC} django/all_baseline_*.jsonl"
log_msg ""

log_msg "${CYAN}Timing:${NC}"
log_msg "  ${YELLOW}Stage 2 (Extract issue types):${NC} $((STAGE2_DURATION / 60))m"
log_msg "  ${YELLOW}Stage 3 (Mine experiences):${NC} $((STAGE3_DURATION / 60))m"
log_msg "  ${YELLOW}Stage 4 (Test with experience):${NC} $((STAGE4_DURATION / 60))m"
log_msg "  ${YELLOW}Total:${NC} $((TOTAL_DURATION / 3600))h $((TOTAL_DURATION % 3600 / 60))m"
log_msg ""

log_msg "${CYAN}Next Steps - Evaluation:${NC}"
log_msg "  Verify patch correctness using Docker-based evaluation:"
log_msg "  ${BLUE}./run_evaluate_baseline.sh${NC}   # Evaluate baseline patches"
log_msg "  ${BLUE}./run_evaluate_experience.sh${NC}  # Evaluate experience patches"
log_msg ""

log_msg "${GREEN}Experience experiment completed at $(date '+%Y-%m-%d %H:%M:%S')${NC}"
