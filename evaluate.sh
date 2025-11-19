#!/bin/bash
################################################################################
# EVALUATE PATCHES USING SWE-BENCH HARNESS
#
# Usage:
#   bash evaluate.sh <prediction_file.jsonl>
#
# Examples:
#   bash evaluate.sh django/test_baseline.jsonl
#   bash evaluate.sh django/test_with_experience_20241119.jsonl
#   bash evaluate.sh django/train_baseline.jsonl
#
# Requirements:
#   - Docker installed and running
#   - 120GB storage, 16GB RAM, 8+ CPU cores recommended
#   - swebench 4.1.0 installed in swe-exp conda env
#
# Time estimate: ~15 min/instance
################################################################################

set -e

# Parse command line argument
PREDICTION_FILE=$1

if [ -z "$PREDICTION_FILE" ]; then
    echo "Usage: bash evaluate.sh <prediction_file.jsonl>"
    echo ""
    echo "Examples:"
    echo "  bash evaluate.sh django/test_baseline.jsonl"
    echo "  bash evaluate.sh django/test_with_experience_20241119.jsonl"
    exit 1
fi

if [ ! -f "$PREDICTION_FILE" ]; then
    echo "Error: Prediction file not found: $PREDICTION_FILE"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

################################################################################
# CONFIGURATION
################################################################################

# Evaluation parameters
DATASET_NAME="princeton-nlp/SWE-bench_Verified"
MAX_WORKERS=4
TIMEOUT=900  # 15 minutes per instance

# Extract run ID from filename
FILENAME=$(basename "$PREDICTION_FILE" .jsonl)
RUN_ID="eval_${FILENAME}_$(date +%Y%m%d_%H%M%S)"

INSTANCE_COUNT=$(wc -l < "$PREDICTION_FILE")
ESTIMATED_HOURS=$((INSTANCE_COUNT * 15 / 60))

log_info "========================================================================"
log_info "SWE-BENCH EVALUATION"
log_info "========================================================================"
log_info "Prediction file: $PREDICTION_FILE"
log_info "Instances: $INSTANCE_COUNT"
log_info "Estimated time: ~${ESTIMATED_HOURS} hours"
echo ""

# Activate conda environment
source ~/conda/etc/profile.d/conda.sh
conda activate swe-exp
log_success "Activated swe-exp conda environment"
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    log_error "Please install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker ps &> /dev/null; then
    log_error "Docker daemon is not running or you don't have permissions"
    log_error "Start Docker or add your user to docker group: sudo usermod -aG docker $USER"
    exit 1
fi

log_success "Docker is available"
echo ""

################################################################################
# RUN EVALUATION
################################################################################

log_info "========================================================================"
log_info "STARTING EVALUATION"
log_info "========================================================================"
log_info "Run ID: $RUN_ID"
log_info "Workers: $MAX_WORKERS"
log_info "Timeout per instance: ${TIMEOUT}s"
echo ""

python -m swebench.harness.run_evaluation \
    --dataset_name "$DATASET_NAME" \
    --predictions_path "$PREDICTION_FILE" \
    --max_workers $MAX_WORKERS \
    --timeout $TIMEOUT \
    --run_id "$RUN_ID"

if [ $? -eq 0 ]; then
    log_success "Evaluation completed successfully"
    log_info "Results saved to: evaluation_results/${RUN_ID}/"
    echo ""

    # Show summary if report.json exists
    REPORT_FILE="evaluation_results/${RUN_ID}/report.json"
    if [ -f "$REPORT_FILE" ]; then
        log_info "SUMMARY:"
        RESOLVED=$(grep -o '"resolved": true' "$REPORT_FILE" | wc -l)
        log_success "  Resolved: ${RESOLVED}/${INSTANCE_COUNT} instances"
        echo ""
    fi
else
    log_error "Evaluation failed!"
    exit 1
fi

################################################################################
# SUMMARY
################################################################################

log_success "========================================================================"
log_success "EVALUATION COMPLETE"
log_success "========================================================================"
echo ""

log_info "Results location: evaluation_results/${RUN_ID}/"
log_info ""
log_info "To view detailed results:"
log_info "  cat evaluation_results/${RUN_ID}/report.json | jq"
log_info ""
log_info "To view resolved instances:"
log_info "  cat evaluation_results/${RUN_ID}/report.json | jq '[.[] | select(.resolved == true) | .instance_id]'"
echo ""
