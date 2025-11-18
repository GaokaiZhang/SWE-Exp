#!/bin/bash
################################################################################
# QUICK COMMAND REFERENCE - Copy and paste these commands in order
################################################################################

# Create logs directory
mkdir -p logs

################################################################################
# STEP 1: RUN BASELINE EXPERIMENT
# - Runs 30 test instances (results → django/, trajectories deleted)
# - Runs 201 train instances (results → django/, trajectories → tmp/trajectory/)
# - Combines results → django/all_baseline_*.jsonl
################################################################################
echo "Step 1: Starting baseline experiment..."
nohup bash run_baseline_experiment.sh > logs/script1_baseline.log 2>&1 &
echo "Monitor with: tail -f logs/script1_baseline.log"
echo "Wait for completion before proceeding to Step 2"
echo ""

# Wait for Step 1 to complete before running these commands!

################################################################################
# STEP 2a & 2b: RUN IN PARALLEL (after Step 1 completes)
#
# Script 2: EXPERIENCE EXPERIMENT
# - Extracts issue types from problem statements
# - Mines experiences from 201 train trajectories
# - Runs 30 test instances WITH experience → django/test_with_experience_*.jsonl
#
# Script 3: EVALUATE BASELINE
# - Evaluates baseline patches in Docker → evaluation/baseline_*/
################################################################################
echo "Step 2a: Starting experience experiment..."
nohup bash run_experience_experiment.sh > logs/script2_experience.log 2>&1 &
echo "Monitor with: tail -f logs/script2_experience.log"
echo ""

echo "Step 2b: Starting baseline evaluation (parallel with 2a)..."
nohup bash run_evaluate_baseline.sh > logs/script3_eval_baseline.log 2>&1 &
echo "Monitor with: tail -f logs/script3_eval_baseline.log"
echo "Wait for BOTH to complete before proceeding to Step 3"
echo ""

# Wait for Step 2a AND 2b to complete before running this command!

################################################################################
# STEP 3: EVALUATE EXPERIENCE (after Steps 2a & 2b complete)
# - Evaluates experience patches in Docker → evaluation/experience_*/
# - Compares with baseline to show improvements
################################################################################
echo "Step 3: Starting experience evaluation..."
nohup bash run_evaluate_experience.sh > logs/script4_eval_experience.log 2>&1 &
echo "Monitor with: tail -f logs/script4_eval_experience.log"
echo ""

################################################################################
# MONITORING COMMANDS
################################################################################

# Check all running background jobs
jobs -l

# Monitor each log file
tail -f logs/script1_baseline.log
tail -f logs/script2_experience.log
tail -f logs/script3_eval_baseline.log
tail -f logs/script4_eval_experience.log

# Check if scripts completed
grep -E 'completed|Evaluation complete' logs/*.log

################################################################################
# VERIFICATION COMMANDS
################################################################################

# 1. Check result files exist
ls -lh django/test_baseline_*.jsonl           # 30 test instances (baseline)
ls -lh django/train_baseline_*.jsonl          # 201 train instances (baseline)
ls -lh django/all_baseline_*.jsonl            # Combined 231 instances
ls -lh django/test_with_experience_*.jsonl    # 30 test instances (with experience)

# 2. Check experience files
ls -lh tmp/het/verified_issue_types_final.json
ls -lh tmp/het/verified_experience_tree.json

# 3. Check trajectories (should be ~201 from train set)
ls -d tmp/trajectory/django__django-* | wc -l

# 4. Check evaluations
ls -d evaluation/baseline_*/
ls -d evaluation/experience_*/

# 5. View success rates
cat evaluation/baseline_*/evaluation_summary.json | jq '{resolved: .resolved_count, total: .total_count}'
cat evaluation/experience_*/evaluation_summary.json | jq '{resolved: .resolved_count, total: .total_count}'

################################################################################
# EXECUTION TIMELINE
################################################################################
# Step 1: ~20-40 hours (run first, wait for completion)
# Step 2a & 2b: ~10-20 hours (run in parallel after Step 1)
# Step 3: ~2-4 hours (run after Steps 2a & 2b)
# TOTAL: ~30-50 hours
################################################################################
