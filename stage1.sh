#!/bin/bash
################################################################################
# STAGE 1: TRAJECTORY COLLECTION (WITHOUT EXPERIENCE)
#
# Usage:
#   bash stage1.sh train train_instances.txt
#   bash stage1.sh test test_instances.txt
#
# Features:
#   - Runs workflow.py WITHOUT experience to collect baseline trajectories
#   - Auto-retries failed instances (updates instances_to_rerun_MODE.txt)
#   - For TEST mode: moves trajectories to backup to prevent data leakage
#   - For TRAIN mode: keeps trajectories for experience extraction (Stages 2-3)
#
# Output files:
#   - django/train_baseline.jsonl (TRAIN mode)
#   - django/test_baseline.jsonl (TEST mode)
#   - tmp/trajectory/ (TRAIN trajectories only)
#   - tmp/trajectory_test_backup/ (TEST trajectories)
################################################################################

set -e

# Parse arguments
MODE=$1
INSTANCE_FILE=$2

if [ -z "$MODE" ] || [ -z "$INSTANCE_FILE" ]; then
    echo "Usage: bash stage1.sh <train|test> <instance_file>"
    echo ""
    echo "Examples:"
    echo "  bash stage1.sh train train_instances.txt"
    echo "  bash stage1.sh test test_instances.txt"
    exit 1
fi

if [ "$MODE" != "train" ] && [ "$MODE" != "test" ]; then
    echo "Error: MODE must be 'train' or 'test'"
    exit 1
fi

if [ ! -f "$INSTANCE_FILE" ]; then
    echo "Error: Instance file not found: $INSTANCE_FILE"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $1"
}

# Configuration
OUTPUT_FILE="django/${MODE}_baseline.jsonl"
RERUN_FILE="instances_to_rerun_${MODE}.txt"
COMPLETE_FILE="django/${MODE}_baseline_complete_only.jsonl"
BACKUP_FILE="django/${MODE}_baseline_before_rerun.jsonl"

log_info "========================================================================"
log_info "STAGE 1: TRAJECTORY COLLECTION - ${MODE^^} MODE"
log_info "========================================================================"
log_info "Mode: $MODE"
log_info "Input: $INSTANCE_FILE"
log_info "Output: $OUTPUT_FILE"
echo ""

# Count instances
TOTAL_COUNT=$(wc -l < "$INSTANCE_FILE")
log_info "Instances to process: $TOTAL_COUNT"
echo ""

# Step 1: Backup existing baseline if it exists
if [ -f "$OUTPUT_FILE" ]; then
    log_info "Step 1: Backup existing baseline..."
    cp "$OUTPUT_FILE" "$BACKUP_FILE"
    log_success "Backed up to $BACKUP_FILE"

    # Extract instances with patches (to keep)
    log_info "Extracting instances with patches..."
    python3 << EXTRACT_COMPLETE
import json

with open('$OUTPUT_FILE', 'r') as f:
    data = [json.loads(line) for line in f if line.strip()]

complete = [d for d in data if d.get('model_patch') and d['model_patch'].strip()]

with open('$COMPLETE_FILE', 'w') as f:
    for entry in complete:
        f.write(json.dumps(entry) + '\n')

print(f"✓ Saved {len(complete)} complete instances")
EXTRACT_COMPLETE

    COMPLETE_COUNT=$(wc -l < "$COMPLETE_FILE")
    log_success "Kept $COMPLETE_COUNT instances with patches"
else
    log_info "Step 1: No existing baseline found, starting fresh"
    > "$COMPLETE_FILE"
    COMPLETE_COUNT=0
fi

echo ""

# Step 2: Remove old trajectories for instances to rerun
log_info "Step 2: Removing old trajectories for instances to rerun..."
REMOVED=0
while IFS= read -r instance_id; do
    if [ -d "tmp/trajectory/$instance_id" ]; then
        rm -rf "tmp/trajectory/$instance_id"
        ((REMOVED++))
    fi
done < "$INSTANCE_FILE"
log_success "Removed $REMOVED old trajectories"
echo ""

# Step 3: Clear prediction file
log_info "Step 3: Clearing prediction file..."
> prediction_verified.jsonl
log_success "Cleared prediction_verified.jsonl"
echo ""

# Step 4: Run workflow.py WITHOUT experience
log_info "========================================================================"
log_info "Step 4: Running workflow.py for $TOTAL_COUNT instances (WITHOUT experience)..."
log_info "========================================================================"
log_info "This will take approximately $((TOTAL_COUNT * 10 / 60)) hours"
echo ""

python workflow.py \
    --instance_ids "$INSTANCE_FILE" \
    --max_iterations 20 \
    --max_expansions 3 \
    --max_finished_nodes 1

echo ""

# Step 5: Merge results
log_info "========================================================================"
log_info "Step 5: Merging results..."
log_info "========================================================================"

if [ ! -f "prediction_verified.jsonl" ] || [ ! -s "prediction_verified.jsonl" ]; then
    log_error "No predictions generated!"
    if [ -f "$BACKUP_FILE" ]; then
        log_warning "Restoring backup..."
        cp "$BACKUP_FILE" "$OUTPUT_FILE"
    fi
    exit 1
fi

NEW_RESULTS=$(wc -l < prediction_verified.jsonl)
log_info "Generated $NEW_RESULTS new results"

# Merge complete + new results
cat "$COMPLETE_FILE" > "$OUTPUT_FILE"
cat prediction_verified.jsonl >> "$OUTPUT_FILE"

FINAL_COUNT=$(wc -l < "$OUTPUT_FILE")
log_success "Final count: $FINAL_COUNT instances in $OUTPUT_FILE"
echo ""

# Step 6: For TEST mode, move trajectories to backup
if [ "$MODE" = "test" ]; then
    log_info "========================================================================"
    log_info "Step 6: Moving TEST trajectories to backup (prevent data leakage)..."
    log_info "========================================================================"

    mkdir -p tmp/trajectory_test_backup

    python3 << MOVE_TEST_TRAJ
import json
import os
import shutil

with open('$OUTPUT_FILE', 'r') as f:
    test_ids = [json.loads(line)['instance_id'] for line in f if line.strip()]

moved = 0
for test_id in test_ids:
    traj_path = f'tmp/trajectory/{test_id}'
    backup_path = f'tmp/trajectory_test_backup/{test_id}'
    if os.path.exists(traj_path):
        if os.path.exists(backup_path):
            shutil.rmtree(backup_path)
        shutil.move(traj_path, backup_path)
        moved += 1

print(f"✓ Moved {moved} test trajectories to tmp/trajectory_test_backup/")
MOVE_TEST_TRAJ

    echo ""
fi

# Step 7: Check completion status
log_info "========================================================================"
log_info "Step 7: Checking completion status..."
log_info "========================================================================"

python3 << CHECK_COMPLETION
import json

with open('$OUTPUT_FILE', 'r') as f:
    data = [json.loads(line) for line in f if line.strip()]

with_patch = [d for d in data if d.get('model_patch') and d['model_patch'].strip()]
without_patch = [d['instance_id'] for d in data if not d.get('model_patch') or not d['model_patch'].strip()]

print(f"")
print(f"Complete (with patches): {len(with_patch)}/$TOTAL_COUNT")
print(f"Still missing patches: {len(without_patch)}/$TOTAL_COUNT")

if without_patch:
    print(f"")
    print(f"Instances still missing patches:")
    for inst_id in sorted(without_patch)[:20]:
        print(f"  {inst_id}")

    if len(without_patch) > 20:
        print(f"  ... and {len(without_patch) - 20} more")

    # Update rerun file for next iteration
    with open('$RERUN_FILE', 'w') as f:
        for inst_id in without_patch:
            f.write(inst_id + '\n')

    print(f"")
    print(f"✓ Updated $RERUN_FILE with {len(without_patch)} instances")
    print(f"")
    print(f"To rerun these again:")
    print(f"  bash stage1.sh $MODE $RERUN_FILE")
else:
    print(f"")
    print(f"✓ ALL $TOTAL_COUNT instances now have patches!")
    if [ "$MODE" = "train" ]; then
        print(f"✓ Ready for: bash pipeline.sh")
    fi

CHECK_COMPLETION

echo ""
log_success "========================================================================"
log_success "STAGE 1 COMPLETE - ${MODE^^} MODE"
log_success "========================================================================"
echo ""
