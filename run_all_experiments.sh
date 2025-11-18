#!/bin/bash
################################################################################
# AUTOMATED EXPERIMENT RUNNER
# Runs all 4 scripts in the correct sequence with automatic waiting
#
# Usage:
#   tmux new -s experiment
#   bash run_all_experiments.sh
#
# Or run in background:
#   nohup bash run_all_experiments.sh > logs/run_all.log 2>&1 &
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create logs directory
mkdir -p logs

# Function to print colored messages
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to wait for a background script to complete
wait_for_script() {
    local script_name=$1
    local log_file=$2
    local pid=$3

    log_info "Waiting for $script_name (PID: $pid) to complete..."
    log_info "Monitor progress with: tail -f $log_file"

    # Wait for the process to finish
    while kill -0 $pid 2>/dev/null; do
        sleep 60  # Check every minute
        # Show last line of log as progress indicator
        if [ -f "$log_file" ]; then
            last_line=$(tail -n 1 "$log_file" 2>/dev/null || echo "")
            if [ -n "$last_line" ]; then
                log_info "[$script_name] Latest: $last_line"
            fi
        fi
    done

    # Check if process completed successfully
    wait $pid
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "$script_name completed successfully!"
    else
        log_error "$script_name failed with exit code $exit_code"
        log_error "Check log file: $log_file"
        exit $exit_code
    fi
}

# Function to wait for multiple scripts in parallel
wait_for_multiple() {
    local script1_name=$1
    local log1=$2
    local pid1=$3
    local script2_name=$4
    local log2=$5
    local pid2=$6

    log_info "Waiting for $script1_name (PID: $pid1) and $script2_name (PID: $pid2) to complete..."

    # Wait for both processes
    local both_running=true
    while $both_running; do
        sleep 60  # Check every minute

        local pid1_running=false
        local pid2_running=false

        if kill -0 $pid1 2>/dev/null; then
            pid1_running=true
            if [ -f "$log1" ]; then
                last_line=$(tail -n 1 "$log1" 2>/dev/null || echo "")
                [ -n "$last_line" ] && log_info "[$script1_name] $last_line"
            fi
        else
            log_success "$script1_name finished"
        fi

        if kill -0 $pid2 2>/dev/null; then
            pid2_running=true
            if [ -f "$log2" ]; then
                last_line=$(tail -n 1 "$log2" 2>/dev/null || echo "")
                [ -n "$last_line" ] && log_info "[$script2_name] $last_line"
            fi
        else
            log_success "$script2_name finished"
        fi

        # Both must be stopped to exit loop
        if ! $pid1_running && ! $pid2_running; then
            both_running=false
        fi
    done

    # Check exit codes
    wait $pid1
    exit_code1=$?
    wait $pid2
    exit_code2=$?

    if [ $exit_code1 -ne 0 ]; then
        log_error "$script1_name failed with exit code $exit_code1"
        exit $exit_code1
    fi

    if [ $exit_code2 -ne 0 ]; then
        log_error "$script2_name failed with exit code $exit_code2"
        exit $exit_code2
    fi

    log_success "Both scripts completed successfully!"
}

################################################################################
# START EXPERIMENT WORKFLOW
################################################################################

log_info "========================================================================"
log_info "STARTING AUTOMATED EXPERIMENT WORKFLOW"
log_info "========================================================================"
log_info "Estimated total time: 30-50 hours"
log_info "All logs will be saved in logs/ directory"
log_info "========================================================================"
echo ""

################################################################################
# STEP 1: BASELINE EXPERIMENT
################################################################################

log_info "========================================================================"
log_info "STEP 1: BASELINE EXPERIMENT"
log_info "========================================================================"
log_info "Running 30 test + 201 train instances without experience..."
log_info "Starting run_baseline_experiment.sh..."

bash run_baseline_experiment.sh > logs/script1_baseline.log 2>&1 &
SCRIPT1_PID=$!

log_info "Script 1 started with PID: $SCRIPT1_PID"
wait_for_script "Script 1 (Baseline)" "logs/script1_baseline.log" $SCRIPT1_PID

# Verify Step 1 outputs
log_info "Verifying Step 1 outputs..."
if [ -f django/test_baseline_*.jsonl ] && [ -f django/train_baseline_*.jsonl ]; then
    log_success "Baseline result files created successfully"
else
    log_warning "Some baseline result files may be missing"
fi

echo ""

################################################################################
# STEP 2a & 2b: EXPERIENCE EXPERIMENT + BASELINE EVALUATION (PARALLEL)
################################################################################

log_info "========================================================================"
log_info "STEP 2: EXPERIENCE EXPERIMENT + BASELINE EVALUATION (PARALLEL)"
log_info "========================================================================"
log_info "Starting Script 2 (Experience) and Script 3 (Eval Baseline) in parallel..."

# Start Script 2: Experience Experiment
bash run_experience_experiment.sh > logs/script2_experience.log 2>&1 &
SCRIPT2_PID=$!
log_info "Script 2 (Experience) started with PID: $SCRIPT2_PID"

# Start Script 3: Evaluate Baseline
bash run_evaluate_baseline.sh > logs/script3_eval_baseline.log 2>&1 &
SCRIPT3_PID=$!
log_info "Script 3 (Eval Baseline) started with PID: $SCRIPT3_PID"

# Wait for both to complete
wait_for_multiple \
    "Script 2 (Experience)" "logs/script2_experience.log" $SCRIPT2_PID \
    "Script 3 (Eval Baseline)" "logs/script3_eval_baseline.log" $SCRIPT3_PID

# Verify Step 2 outputs
log_info "Verifying Step 2 outputs..."
if [ -f tmp/het/verified_experience_tree.json ]; then
    log_success "Experience tree created successfully"
fi
if [ -f django/test_with_experience_*.jsonl ]; then
    log_success "Experience result file created successfully"
fi
if [ -d evaluation/baseline_* ]; then
    log_success "Baseline evaluation directory created successfully"
fi

echo ""

################################################################################
# STEP 3: EVALUATE EXPERIENCE
################################################################################

log_info "========================================================================"
log_info "STEP 3: EVALUATE EXPERIENCE RESULTS"
log_info "========================================================================"
log_info "Starting Script 4 (Eval Experience)..."

bash run_evaluate_experience.sh > logs/script4_eval_experience.log 2>&1 &
SCRIPT4_PID=$!

log_info "Script 4 started with PID: $SCRIPT4_PID"
wait_for_script "Script 4 (Eval Experience)" "logs/script4_eval_experience.log" $SCRIPT4_PID

# Verify Step 3 outputs
log_info "Verifying Step 3 outputs..."
if [ -d evaluation/experience_* ]; then
    log_success "Experience evaluation directory created successfully"
fi

echo ""

################################################################################
# FINAL SUMMARY
################################################################################

log_success "========================================================================"
log_success "ALL EXPERIMENTS COMPLETED SUCCESSFULLY!"
log_success "========================================================================"
echo ""

log_info "RESULTS SUMMARY:"
echo ""

# Count result files
if ls django/test_baseline_*.jsonl 1> /dev/null 2>&1; then
    test_baseline_count=$(cat django/test_baseline_*.jsonl 2>/dev/null | wc -l)
    log_info "Baseline test results: $test_baseline_count instances"
fi

if ls django/train_baseline_*.jsonl 1> /dev/null 2>&1; then
    train_baseline_count=$(cat django/train_baseline_*.jsonl 2>/dev/null | wc -l)
    log_info "Baseline train results: $train_baseline_count instances"
fi

if ls django/test_with_experience_*.jsonl 1> /dev/null 2>&1; then
    test_exp_count=$(cat django/test_with_experience_*.jsonl 2>/dev/null | wc -l)
    log_info "Experience test results: $test_exp_count instances"
fi

echo ""
log_info "EXPERIENCE FILES:"
if [ -f tmp/het/verified_issue_types_final.json ]; then
    log_success "✓ Issue types: tmp/het/verified_issue_types_final.json"
fi
if [ -f tmp/het/verified_experience_tree.json ]; then
    log_success "✓ Experience tree: tmp/het/verified_experience_tree.json"
fi

echo ""
log_info "EVALUATION RESULTS:"

# Show baseline evaluation summary
baseline_eval_dir=$(ls -td evaluation/baseline_* 2>/dev/null | head -1)
if [ -n "$baseline_eval_dir" ] && [ -f "$baseline_eval_dir/evaluation_summary.json" ]; then
    log_info "Baseline evaluation: $baseline_eval_dir"
    if command -v jq &> /dev/null; then
        resolved=$(jq -r '.resolved_count // "N/A"' "$baseline_eval_dir/evaluation_summary.json")
        total=$(jq -r '.total_count // "N/A"' "$baseline_eval_dir/evaluation_summary.json")
        log_success "  Baseline: $resolved / $total resolved"
    fi
fi

# Show experience evaluation summary
exp_eval_dir=$(ls -td evaluation/experience_* 2>/dev/null | head -1)
if [ -n "$exp_eval_dir" ] && [ -f "$exp_eval_dir/evaluation_summary.json" ]; then
    log_info "Experience evaluation: $exp_eval_dir"
    if command -v jq &> /dev/null; then
        resolved=$(jq -r '.resolved_count // "N/A"' "$exp_eval_dir/evaluation_summary.json")
        total=$(jq -r '.total_count // "N/A"' "$exp_eval_dir/evaluation_summary.json")
        log_success "  Experience: $resolved / $total resolved"
    fi
fi

echo ""
log_success "========================================================================"
log_success "Check logs/ directory for detailed execution logs"
log_success "Check django/ directory for all result files"
log_success "Check evaluation/ directory for evaluation summaries"
log_success "========================================================================"
