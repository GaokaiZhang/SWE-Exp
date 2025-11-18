#!/bin/bash

# Script 4: Evaluate Experience Patches
# Purpose:
#   - Verify patch correctness from experience experiment (with experience)
#   - Uses Docker-based testbed evaluation
#   - Runs after Script 2 completes
#   - Compares results with baseline evaluation
# Environment: swe-exp conda environment, Docker access

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
RESULTS_DIR="results"
EVAL_DIR="evaluation"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PARALLEL_JOBS=3  # Conservative for Docker evaluations

# Create directories
mkdir -p "$EVAL_DIR"
LOG_FILE="$EVAL_DIR/eval_experience_${TIMESTAMP}.log"

# Function to print status
print_status() {
    local stage=$1
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${MAGENTA}EXPERIENCE PATCH EVALUATION${NC}"
    echo -e "${CYAN}║${NC} ${BLUE}STAGE: $stage${NC}"
    echo -e "${CYAN}║${NC} ${GREEN}TIME: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}PARALLEL JOBS: $PARALLEL_JOBS${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

log_msg() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_to_file() {
    echo "$1" >> "$LOG_FILE"
}

# Activate conda
log_msg "${BLUE}Activating conda environment: $CONDA_ENV${NC}"
source ~/conda/etc/profile.d/conda.sh
conda activate "$CONDA_ENV"

# Find the latest experience prediction file
log_msg "${YELLOW}Looking for experience predictions...${NC}"
EXPERIENCE_FILE=$(ls -t "$RESULTS_DIR"/prediction_with_experience_*.jsonl 2>/dev/null | head -1)

if [ -z "$EXPERIENCE_FILE" ]; then
    log_msg "${RED}ERROR: No experience prediction file found in $RESULTS_DIR${NC}"
    log_msg "${YELLOW}Please run ./run_experience_experiment.sh first${NC}"
    exit 1
fi

log_msg "${GREEN}✓ Found experience predictions: $EXPERIENCE_FILE${NC}"

# Count instances
TOTAL_INSTANCES=$(wc -l < "$EXPERIENCE_FILE")
log_msg "${GREEN}Total instances to evaluate: $TOTAL_INSTANCES${NC}"

if [ $TOTAL_INSTANCES -eq 0 ]; then
    log_msg "${RED}ERROR: Experience file is empty${NC}"
    exit 1
fi

log_msg ""
log_msg "${GREEN}Configuration:${NC}"
log_msg "  Predictions file: $EXPERIENCE_FILE"
log_msg "  Total patches: $TOTAL_INSTANCES"
log_msg "  Parallel workers: $PARALLEL_JOBS"
log_msg "  Output directory: $EVAL_DIR"
log_msg "  Log file: $LOG_FILE"
log_msg ""

# Check Docker
log_msg "${YELLOW}Checking Docker access...${NC}"
if ! docker ps &> /dev/null; then
    log_msg "${RED}ERROR: Cannot access Docker. Please check Docker daemon is running.${NC}"
    exit 1
fi
log_msg "${GREEN}✓ Docker access confirmed${NC}"

# Create Python evaluation script (same as baseline)
EVAL_SCRIPT="$EVAL_DIR/evaluate_predictions_experience.py"
cat > "$EVAL_SCRIPT" << 'PYTHON_SCRIPT_END'
#!/usr/bin/env python3
"""
Evaluate predictions from experience experiment using Docker testbeds.
Reads predictions JSONL, runs each patch through testbed, generates evaluation report.
"""

import json
import os
import sys
import logging
from datetime import datetime
from pathlib import Path
from typing import Dict, List
import traceback

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def load_predictions(predictions_file: str) -> List[Dict]:
    """Load predictions from JSONL file."""
    predictions = []
    logger.info(f"Loading predictions from {predictions_file}")

    with open(predictions_file, 'r') as f:
        for line_num, line in enumerate(f, 1):
            try:
                pred = json.loads(line.strip())
                if pred.get('model_patch'):
                    predictions.append(pred)
                else:
                    logger.warning(f"Line {line_num}: No model_patch found, skipping")
            except json.JSONDecodeError as e:
                logger.error(f"Line {line_num}: JSON decode error: {e}")

    logger.info(f"Loaded {len(predictions)} predictions with patches")
    return predictions


def evaluate_single_patch(prediction: Dict, eval_dir: str) -> Dict:
    """Evaluate a single patch using testbed."""
    instance_id = prediction['instance_id']
    patch = prediction['model_patch']

    logger.info(f"Evaluating {instance_id}")

    result = {
        'instance_id': instance_id,
        'resolved': False,
        'error': None,
        'test_output': None,
        'evaluation_time': None
    }

    start_time = datetime.now()

    try:
        # Import here to avoid import errors if testbed not available
        from moatless.benchmark.utils import get_moatless_instance
        from moatless.benchmark.swebench import create_repository
        from moatless.runtime.testbed import TestbedEnvironment

        # Get instance and create repository
        instance = get_moatless_instance(instance_id=instance_id)
        repository = create_repository(instance)

        # Create testbed environment
        runtime = TestbedEnvironment(
            repository=repository,
            instance=instance,
        )

        # Evaluate the patch
        logger.info(f"{instance_id}: Running tests...")
        eval_result = runtime.evaluate(patch=patch)

        if eval_result:
            result['resolved'] = eval_result.resolved
            result['test_output'] = {
                'resolved': eval_result.resolved,
                'passed_tests': getattr(eval_result, 'passed_tests', []),
                'failed_tests': getattr(eval_result, 'failed_tests', []),
            }
            logger.info(f"{instance_id}: {'✓ RESOLVED' if eval_result.resolved else '✗ FAILED'}")
        else:
            result['error'] = "Evaluation returned None"
            logger.error(f"{instance_id}: Evaluation returned None")

    except Exception as e:
        result['error'] = str(e)
        result['traceback'] = traceback.format_exc()
        logger.error(f"{instance_id}: ERROR - {e}")
        logger.debug(f"{instance_id}: Traceback:\n{traceback.format_exc()}")

    result['evaluation_time'] = (datetime.now() - start_time).total_seconds()

    # Save individual result
    instance_result_file = os.path.join(eval_dir, f"{instance_id}.json")
    with open(instance_result_file, 'w') as f:
        json.dump(result, f, indent=2)

    return result


def evaluate_predictions(predictions_file: str, output_dir: str, instance_id: str = None):
    """Evaluate all predictions or a single instance."""

    # Load predictions
    predictions = load_predictions(predictions_file)

    if not predictions:
        logger.error("No predictions to evaluate")
        return

    # Filter to single instance if specified
    if instance_id:
        predictions = [p for p in predictions if p['instance_id'] == instance_id]
        if not predictions:
            logger.error(f"Instance {instance_id} not found in predictions")
            return

    # Create output directory
    os.makedirs(output_dir, exist_ok=True)

    # Evaluate predictions
    results = []
    for i, pred in enumerate(predictions, 1):
        logger.info(f"\n{'='*60}")
        logger.info(f"Evaluating {i}/{len(predictions)}: {pred['instance_id']}")
        logger.info(f"{'='*60}")

        result = evaluate_single_patch(pred, output_dir)
        results.append(result)

    # Generate summary
    resolved_count = sum(1 for r in results if r['resolved'])
    error_count = sum(1 for r in results if r['error'])

    summary = {
        'timestamp': datetime.now().isoformat(),
        'predictions_file': predictions_file,
        'total_instances': len(results),
        'resolved': resolved_count,
        'failed': len(results) - resolved_count - error_count,
        'errors': error_count,
        'success_rate': f"{resolved_count / len(results) * 100:.1f}%" if results else "0%",
        'results': results
    }

    # Save summary
    summary_file = os.path.join(output_dir, 'evaluation_summary.json')
    with open(summary_file, 'w') as f:
        json.dump(summary, f, indent=2)

    logger.info(f"\n{'='*60}")
    logger.info("EVALUATION SUMMARY")
    logger.info(f"{'='*60}")
    logger.info(f"Total instances: {summary['total_instances']}")
    logger.info(f"Resolved: {summary['resolved']}")
    logger.info(f"Failed: {summary['failed']}")
    logger.info(f"Errors: {summary['errors']}")
    logger.info(f"Success rate: {summary['success_rate']}")
    logger.info(f"\nSummary saved to: {summary_file}")
    logger.info(f"{'='*60}\n")


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='Evaluate predictions using Docker testbeds')
    parser.add_argument('--predictions', required=True, help='Path to predictions JSONL file')
    parser.add_argument('--output-dir', required=True, help='Output directory for evaluation results')
    parser.add_argument('--instance-id', help='Evaluate single instance only')

    args = parser.parse_args()

    evaluate_predictions(args.predictions, args.output_dir, args.instance_id)
PYTHON_SCRIPT_END

chmod +x "$EVAL_SCRIPT"

# =============================================================================
# RUN EVALUATION
# =============================================================================

print_status "Evaluating $TOTAL_INSTANCES experience patches with Docker testbeds"

START_TIME=$(date +%s)

# Create output directory for this evaluation
OUTPUT_DIR="$EVAL_DIR/experience_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

log_msg "${YELLOW}Running evaluation (this will take a while)...${NC}"
log_msg "${YELLOW}Each instance requires Docker container setup and test execution${NC}"
log_msg ""
log_msg "${CYAN}Monitor progress:${NC}"
log_msg "  ${BLUE}watch -n 5 'ls -1 $OUTPUT_DIR/*.json | wc -l'${NC}"
log_msg "  ${BLUE}tail -f $LOG_FILE${NC}"
log_msg ""

# Extract instance IDs and run parallel evaluations
log_msg "${YELLOW}Extracting instance IDs...${NC}"
INSTANCE_IDS=$(python3 -c "
import json
import sys
with open('$EXPERIENCE_FILE', 'r') as f:
    for line in f:
        pred = json.loads(line)
        if pred.get('model_patch'):
            print(pred['instance_id'])
" 2>&1 | tee -a "$LOG_FILE")

if [ -z "$INSTANCE_IDS" ]; then
    log_msg "${RED}ERROR: Could not extract instance IDs${NC}"
    exit 1
fi

log_msg "${GREEN}✓ Extracted instance IDs${NC}"

# Evaluate instances in parallel
evaluate_instance() {
    local instance_id=$1
    local predictions_file=$2
    local output_dir=$3

    source ~/conda/etc/profile.d/conda.sh
    conda activate swe-exp

    python3 "$EVAL_SCRIPT" \
        --predictions "$predictions_file" \
        --output-dir "$output_dir" \
        --instance-id "$instance_id" \
        2>&1 | tee "$output_dir/${instance_id}_eval.log"
}

export -f evaluate_instance
export EVAL_SCRIPT CONDA_ENV

log_msg "${YELLOW}Starting parallel evaluation with $PARALLEL_JOBS workers...${NC}"
echo "$INSTANCE_IDS" | parallel -j "$PARALLEL_JOBS" --bar \
    evaluate_instance {} "$EXPERIENCE_FILE" "$OUTPUT_DIR"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# =============================================================================
# GENERATE FINAL SUMMARY & COMPARISON
# =============================================================================

log_msg ""
log_msg "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
log_msg "${GREEN}║        EXPERIENCE EVALUATION COMPLETED SUCCESSFULLY            ║${NC}"
log_msg "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
log_msg ""

# Parse results
RESOLVED=$(grep -l '"resolved": true' "$OUTPUT_DIR"/*.json 2>/dev/null | wc -l)
FAILED=$(grep -l '"resolved": false' "$OUTPUT_DIR"/*.json 2>/dev/null | wc -l)
ERRORS=$(grep -l '"error":' "$OUTPUT_DIR"/*.json 2>/dev/null | grep -v '"error": null' | wc -l)

log_msg "${CYAN}Evaluation Results (With Experience):${NC}"
log_msg "  ${YELLOW}Total instances:${NC} $TOTAL_INSTANCES"
log_msg "  ${GREEN}✓ Resolved (patches work):${NC} $RESOLVED"
log_msg "  ${RED}✗ Failed (patches don't work):${NC} $FAILED"
log_msg "  ${RED}⚠ Errors (evaluation failed):${NC} $ERRORS"
log_msg "  ${YELLOW}Success rate:${NC} $((RESOLVED * 100 / TOTAL_INSTANCES))%"
log_msg ""

# Try to compare with baseline
BASELINE_EVAL=$(ls -td "$EVAL_DIR"/baseline_*/ 2>/dev/null | head -1)
if [ -n "$BASELINE_EVAL" ]; then
    BASELINE_RESOLVED=$(grep -l '"resolved": true' "$BASELINE_EVAL"/*.json 2>/dev/null | wc -l)
    BASELINE_FAILED=$(grep -l '"resolved": false' "$BASELINE_EVAL"/*.json 2>/dev/null | wc -l)

    IMPROVEMENT=$((RESOLVED - BASELINE_RESOLVED))
    IMPROVEMENT_PCT=$((IMPROVEMENT * 100 / TOTAL_INSTANCES))

    log_msg "${CYAN}Comparison with Baseline:${NC}"
    log_msg "  ${YELLOW}Baseline resolved:${NC} $BASELINE_RESOLVED ($((BASELINE_RESOLVED * 100 / TOTAL_INSTANCES))%)"
    log_msg "  ${YELLOW}Experience resolved:${NC} $RESOLVED ($((RESOLVED * 100 / TOTAL_INSTANCES))%)"

    if [ $IMPROVEMENT -gt 0 ]; then
        log_msg "  ${GREEN}✓ Improvement:${NC} +$IMPROVEMENT instances (+${IMPROVEMENT_PCT}%)"
    elif [ $IMPROVEMENT -lt 0 ]; then
        log_msg "  ${RED}⚠ Regression:${NC} $IMPROVEMENT instances (${IMPROVEMENT_PCT}%)"
    else
        log_msg "  ${YELLOW}= No change:${NC} Same number of resolved instances"
    fi

    log_msg ""
    log_msg "  ${YELLOW}Baseline results:${NC} $BASELINE_EVAL"
    log_msg "  ${YELLOW}Experience results:${NC} $OUTPUT_DIR"
else
    log_msg "${YELLOW}No baseline evaluation found for comparison${NC}"
    log_msg "${YELLOW}Run ./run_evaluate_baseline.sh to generate baseline evaluation${NC}"
fi

log_msg ""

log_msg "${CYAN}Timing:${NC}"
log_msg "  ${YELLOW}Total time:${NC} $((DURATION / 60))m $((DURATION % 60))s"
log_msg "  ${YELLOW}Average per instance:${NC} $((DURATION / TOTAL_INSTANCES))s (~$((DURATION / TOTAL_INSTANCES / 60))m)"
log_msg ""

log_msg "${CYAN}Output Files:${NC}"
log_msg "  ${YELLOW}Results directory:${NC} $OUTPUT_DIR"
log_msg "  ${YELLOW}Summary:${NC} $OUTPUT_DIR/evaluation_summary.json"
log_msg "  ${YELLOW}Individual results:${NC} $OUTPUT_DIR/<instance_id>.json"
log_msg "  ${YELLOW}Log file:${NC} $LOG_FILE"
log_msg ""

# Check if summary exists
if [ -f "$OUTPUT_DIR/evaluation_summary.json" ]; then
    log_msg "${GREEN}✓ Evaluation summary generated${NC}"
    log_msg "${CYAN}View summary:${NC}"
    log_msg "  ${BLUE}cat $OUTPUT_DIR/evaluation_summary.json | jq .${NC}"
else
    log_msg "${YELLOW}⚠ Summary file not found - check individual results${NC}"
fi

log_msg ""
log_msg "${CYAN}Analysis Commands:${NC}"
log_msg "  ${BLUE}# View resolved instances${NC}"
log_msg "  ${BLUE}grep -l '\"resolved\": true' $OUTPUT_DIR/*.json${NC}"
log_msg ""
log_msg "  ${BLUE}# View failed instances${NC}"
log_msg "  ${BLUE}grep -l '\"resolved\": false' $OUTPUT_DIR/*.json${NC}"
log_msg ""
log_msg "  ${BLUE}# Compare baseline vs experience${NC}"
log_msg "  ${BLUE}diff <(grep -l '\"resolved\": true' $BASELINE_EVAL/*.json | xargs -n1 basename) \\${NC}"
log_msg "  ${BLUE}     <(grep -l '\"resolved\": true' $OUTPUT_DIR/*.json | xargs -n1 basename)${NC}"
log_msg ""

log_msg "${GREEN}Experience evaluation completed at $(date '+%Y-%m-%d %H:%M:%S')${NC}"
log_msg ""
log_msg "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
log_msg "${GREEN}  ALL EXPERIMENTS COMPLETED!${NC}"
log_msg "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
