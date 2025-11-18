#!/bin/bash

# Script 1: Baseline Experiment - Run ALL data WITHOUT experience
# Clean Approach:
#   Phase 1: Run 30 test → save to django/, CLEAR trajectories
#   Phase 2: Run 201 train → save to django/, keep trajectories (for experience building)
#   Phase 3: Combine all results → django/all_baseline_*.jsonl
# Result: tmp/trajectory/ only has 201 TRAIN instances (ready for Script 2)
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
TRAIN_INSTANCES="train_instances.txt"
RESULTS_DIR="results"
DJANGO_DIR="django"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PARALLEL_JOBS=4

# Create directories
mkdir -p "$RESULTS_DIR" "$DJANGO_DIR"
LOG_FILE="$RESULTS_DIR/baseline_experiment_${TIMESTAMP}.log"

# Function to print status
print_status() {
    local stage=$1
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${MAGENTA}BASELINE EXPERIMENT (NO EXPERIENCE)${NC}"
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
TOTAL_COUNT=$((TEST_COUNT + TRAIN_COUNT))

log_msg "${GREEN}Configuration:${NC}"
log_msg "  Test instances: $TEST_COUNT"
log_msg "  Train instances: $TRAIN_COUNT"
log_msg "  Total instances: $TOTAL_COUNT"
log_msg "  Parallel workers: $PARALLEL_JOBS"
log_msg "  Results: $RESULTS_DIR"
log_msg "  Django archive: $DJANGO_DIR"
log_msg "  Log: $LOG_FILE"
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
# PHASE 1: RUN 30 TEST INSTANCES (will be cleared after)
# =============================================================================

print_status "Phase 1/3: Testing $TEST_COUNT instances WITHOUT experience"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE 1: Test Instances Baseline (will clear trajectories)${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

PHASE1_START=$(date +%s)

log_msg "${YELLOW}Running $TEST_COUNT test instances ($PARALLEL_JOBS workers)...${NC}"

cat "$TEST_INSTANCES" | parallel -j "$PARALLEL_JOBS" --bar \
    process_instance {} "$MAX_ITERATIONS" "$MAX_EXPANSIONS" "$MAX_FINISHED_NODES" "test_baseline"

# Collect test results
log_msg "${YELLOW}Collecting test baseline results...${NC}"
cat prediction.jsonl prediction_verified.jsonl 2>/dev/null | sort -u > "$DJANGO_DIR/test_baseline_${TIMESTAMP}.jsonl" || true
TEST_PATCHES=$(grep -c '"model_patch":' "$DJANGO_DIR/test_baseline_${TIMESTAMP}.jsonl" 2>/dev/null || echo "0")

rm -f prediction.jsonl prediction_verified.jsonl
log_msg "${GREEN}✓ Test results saved: $DJANGO_DIR/test_baseline_${TIMESTAMP}.jsonl${NC}"
log_msg "${GREEN}✓ Test patches: $TEST_PATCHES / $TEST_COUNT${NC}"

# IMPORTANT: Clear test trajectories - we only want train trajectories for experience
log_msg "${YELLOW}Clearing test trajectories (only train trajectories needed for experience)...${NC}"
while IFS= read -r instance_id; do
    rm -rf "tmp/trajectory/$instance_id" 2>/dev/null || true
done < "$TEST_INSTANCES"
log_msg "${GREEN}✓ Test trajectories cleared${NC}"

PHASE1_END=$(date +%s)
PHASE1_DURATION=$((PHASE1_END - PHASE1_START))
log_msg "${GREEN}Phase 1 completed in $((PHASE1_DURATION / 60))m $((PHASE1_DURATION % 60))s${NC}\n"

# =============================================================================
# PHASE 2: RUN 201 TRAIN INSTANCES (keep trajectories for experience)
# =============================================================================

print_status "Phase 2/3: Training $TRAIN_COUNT instances WITHOUT experience"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE 2: Train Instances Baseline (keep for experience)${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

PHASE2_START=$(date +%s)

log_msg "${YELLOW}Running $TRAIN_COUNT train instances ($PARALLEL_JOBS workers)...${NC}"
log_msg "${YELLOW}These trajectories will be kept for experience building in Script 2${NC}"

cat "$TRAIN_INSTANCES" | parallel -j "$PARALLEL_JOBS" --bar \
    process_instance {} "$MAX_ITERATIONS" "$MAX_EXPANSIONS" "$MAX_FINISHED_NODES" "train_baseline"

# Collect train results
log_msg "${YELLOW}Collecting train baseline results...${NC}"
cat prediction.jsonl prediction_verified.jsonl 2>/dev/null | sort -u > "$DJANGO_DIR/train_baseline_${TIMESTAMP}.jsonl" || true
TRAIN_PATCHES=$(grep -c '"model_patch":' "$DJANGO_DIR/train_baseline_${TIMESTAMP}.jsonl" 2>/dev/null || echo "0")

rm -f prediction.jsonl prediction_verified.jsonl
log_msg "${GREEN}✓ Train results saved: $DJANGO_DIR/train_baseline_${TIMESTAMP}.jsonl${NC}"
log_msg "${GREEN}✓ Train patches: $TRAIN_PATCHES / $TRAIN_COUNT${NC}"

# Count remaining trajectories (should be ONLY train)
TRAJ_COUNT=$(ls -1 tmp/trajectory/ 2>/dev/null | wc -l)
log_msg "${GREEN}✓ Train trajectories kept: $TRAJ_COUNT (for experience building)${NC}"

PHASE2_END=$(date +%s)
PHASE2_DURATION=$((PHASE2_END - PHASE2_START))
log_msg "${GREEN}Phase 2 completed in $((PHASE2_DURATION / 60))m $((PHASE2_DURATION % 60))s${NC}\n"

# =============================================================================
# PHASE 3: COMBINE ALL RESULTS
# =============================================================================

print_status "Phase 3/3: Combining all baseline results"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
log_msg "${MAGENTA}  PHASE 3: Merge Results${NC}"
log_msg "${MAGENTA}═══════════════════════════════════════════════════════════${NC}\n"

log_msg "${YELLOW}Combining test + train baseline results...${NC}"
cat "$DJANGO_DIR/test_baseline_${TIMESTAMP}.jsonl" "$DJANGO_DIR/train_baseline_${TIMESTAMP}.jsonl" 2>/dev/null | \
    sort -u > "$DJANGO_DIR/all_baseline_${TIMESTAMP}.jsonl" || true

TOTAL_PATCHES=$(grep -c '"model_patch":' "$DJANGO_DIR/all_baseline_${TIMESTAMP}.jsonl" 2>/dev/null || echo "0")
log_msg "${GREEN}✓ Combined baseline: $DJANGO_DIR/all_baseline_${TIMESTAMP}.jsonl${NC}"
log_msg "${GREEN}✓ Total patches: $TOTAL_PATCHES / $TOTAL_COUNT${NC}"

# =============================================================================
# SUMMARY
# =============================================================================

EXPERIMENT_END=$(date +%s)
TOTAL_DURATION=$((EXPERIMENT_END - EXPERIMENT_START))

log_msg ""
log_msg "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
log_msg "${GREEN}║        BASELINE EXPERIMENT COMPLETED SUCCESSFULLY              ║${NC}"
log_msg "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
log_msg ""

log_msg "${CYAN}Results Summary:${NC}"
log_msg "  ${YELLOW}Test instances (30):${NC} $TEST_PATCHES patches"
log_msg "  ${YELLOW}Train instances (201):${NC} $TRAIN_PATCHES patches"
log_msg "  ${YELLOW}Total (231):${NC} $TOTAL_PATCHES patches ($((TOTAL_PATCHES * 100 / TOTAL_COUNT))%)"
log_msg ""

log_msg "${CYAN}Output Files (django/ directory):${NC}"
log_msg "  ${YELLOW}Test baseline:${NC} $DJANGO_DIR/test_baseline_${TIMESTAMP}.jsonl"
log_msg "  ${YELLOW}Train baseline:${NC} $DJANGO_DIR/train_baseline_${TIMESTAMP}.jsonl"
log_msg "  ${YELLOW}Combined (all 231):${NC} $DJANGO_DIR/all_baseline_${TIMESTAMP}.jsonl"
log_msg ""

log_msg "${CYAN}Train/Test Separation Status:${NC}"
log_msg "  ${YELLOW}Trajectories in tmp/trajectory/:${NC} $TRAJ_COUNT (ONLY train instances)"
log_msg "  ${YELLOW}Test trajectories:${NC} Cleared (no data leakage)"
log_msg "  ${GREEN}✓ Ready for Script 2 - experience will be built from train only${NC}"
log_msg ""

log_msg "${CYAN}Timing:${NC}"
log_msg "  ${YELLOW}Phase 1 (30 test):${NC} $((PHASE1_DURATION / 60))m"
log_msg "  ${YELLOW}Phase 2 (201 train):${NC} $((PHASE2_DURATION / 60))m"
log_msg "  ${YELLOW}Total:${NC} $((TOTAL_DURATION / 3600))h $((TOTAL_DURATION % 3600 / 60))m"
log_msg "  ${YELLOW}Average per instance:${NC} $((TOTAL_DURATION / TOTAL_COUNT))s"
log_msg ""

log_msg "${CYAN}Next Steps:${NC}"
log_msg "  1. All baseline data ready in django/ folder"
log_msg "  2. Train trajectories ready in tmp/trajectory/ for experience building"
log_msg "  3. Run Script 2 to build experience and test with experience:"
log_msg "     ${BLUE}./run_experience_experiment.sh${NC}"
log_msg ""

log_msg "${GREEN}Baseline experiment completed at $(date '+%Y-%m-%d %H:%M:%S')${NC}"
