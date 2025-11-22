#!/bin/bash
################################################################################
# RERUN INCOMPLETE INSTANCES UNTIL ALL HAVE PATCHES
################################################################################

set -e

echo "=========================================================================="
echo "RERUNNING INCOMPLETE INSTANCES"
echo "=========================================================================="

# Count instances to rerun
RERUN_COUNT=$(wc -l < instances_to_rerun.txt)
echo ""
echo "Instances to rerun: $RERUN_COUNT"

# Step 1: Backup current baseline
echo ""
echo "Step 1: Backup current baseline..."
cp django/train_baseline.jsonl django/train_baseline_before_rerun.jsonl
echo "✓ Backed up to django/train_baseline_before_rerun.jsonl"

# Step 2: Extract instances WITH patches (to keep)
echo ""
echo "Step 2: Extracting instances with patches..."
python3 << 'EXTRACT_COMPLETE'
import json

with open('django/train_baseline.jsonl', 'r') as f:
    train_data = [json.loads(line) for line in f if line.strip()]

# Keep only instances with patches
complete = [d for d in train_data if d.get('model_patch') and d['model_patch'].strip()]

with open('django/train_baseline_complete_only.jsonl', 'w') as f:
    for entry in complete:
        f.write(json.dumps(entry) + '\n')

print(f"✓ Saved {len(complete)} complete instances")
EXTRACT_COMPLETE

COMPLETE_COUNT=$(wc -l < django/train_baseline_complete_only.jsonl)
echo "✓ Kept $COMPLETE_COUNT instances with patches"

# Step 3: Remove trajectories for instances to rerun
echo ""
echo "Step 3: Removing old trajectories for rerun instances..."
REMOVED=0
while IFS= read -r instance_id; do
    instance_id=$(echo "$instance_id" | tr -d '\r\n' | xargs)  # Clean whitespace
    if [ -n "$instance_id" ]; then
        echo "  Checking: $instance_id"
        if [ -d "tmp/trajectory/$instance_id" ]; then
            echo "    Removing tmp/trajectory/$instance_id"
            rm -rf "tmp/trajectory/$instance_id"
            REMOVED=$((REMOVED + 1))
        fi
    fi
done < instances_to_rerun.txt
echo "✓ Removed $REMOVED old trajectories"

# Step 4: Clear prediction file
echo ""
echo "Step 4: Clearing prediction file..."
> prediction_verified.jsonl
echo "✓ Cleared prediction_verified.jsonl"

# Step 5: Run workflow.py for incomplete instances
echo ""
echo "=========================================================================="
echo "Step 5: Running workflow.py for $RERUN_COUNT instances..."
echo "=========================================================================="
echo "This will take approximately $((RERUN_COUNT * 10 / 60)) hours"
echo ""

python workflow.py \
    --instance_ids instances_to_rerun.txt \
    --max_iterations 20 \
    --max_expansions 3 \
    --max_finished_nodes 1

# Step 6: Merge results
echo ""
echo "=========================================================================="
echo "Step 6: Merging results..."
echo "=========================================================================="

if [ ! -f "prediction_verified.jsonl" ] || [ ! -s "prediction_verified.jsonl" ]; then
    echo "✗ ERROR: No predictions generated!"
    echo "✗ Restoring backup..."
    cp django/train_baseline_before_rerun.jsonl django/train_baseline.jsonl
    exit 1
fi

NEW_RESULTS=$(wc -l < prediction_verified.jsonl)
echo "Generated $NEW_RESULTS new results"

# Merge complete + new results
cat django/train_baseline_complete_only.jsonl > django/train_baseline.jsonl
cat prediction_verified.jsonl >> django/train_baseline.jsonl

FINAL_COUNT=$(wc -l < django/train_baseline.jsonl)
echo "✓ Final count: $FINAL_COUNT instances in train_baseline.jsonl"

# Step 7: Check completion status by comparing with expected train instances
echo ""
echo "=========================================================================="
echo "Step 7: Checking completion status..."
echo "=========================================================================="

python3 << 'CHECK_COMPLETION'
import json
import os

# Read expected train instances
if not os.path.exists('train_instances.txt'):
    print("✗ ERROR: train_instances.txt not found!")
    exit(1)

with open('train_instances.txt', 'r') as f:
    expected_instances = set(line.strip() for line in f if line.strip())

print(f"Expected train instances: {len(expected_instances)}")

# Read current train_baseline.jsonl
with open('django/train_baseline.jsonl', 'r') as f:
    train_data = [json.loads(line) for line in f if line.strip()]

# Build sets for analysis
baseline_ids = {d['instance_id'] for d in train_data}
with_patch = {d['instance_id'] for d in train_data if d.get('model_patch') and d['model_patch'].strip()}
without_patch = {d['instance_id'] for d in train_data if not d.get('model_patch') or not d['model_patch'].strip()}

# Find all incomplete instances (missing from baseline OR in baseline without patch)
missing_from_baseline = expected_instances - baseline_ids
incomplete_instances = sorted(missing_from_baseline | without_patch)

print(f"")
print(f"Status:")
print(f"  In baseline with patches: {len(with_patch)}/{len(expected_instances)}")
print(f"  In baseline without patches: {len(without_patch)}")
print(f"  Missing from baseline: {len(missing_from_baseline)}")
print(f"  Total incomplete: {len(incomplete_instances)}/{len(expected_instances)}")

if incomplete_instances:
    print(f"")
    print(f"Incomplete instances (missing or without patches):")
    for inst_id in incomplete_instances[:20]:
        if inst_id in missing_from_baseline:
            print(f"  ✗ {inst_id} - NOT in baseline")
        else:
            print(f"  ⚠ {inst_id} - in baseline but NO patch")

    if len(incomplete_instances) > 20:
        print(f"  ... and {len(incomplete_instances) - 20} more")

    # Update instances_to_rerun.txt for next iteration
    with open('instances_to_rerun.txt', 'w') as f:
        for inst_id in incomplete_instances:
            f.write(inst_id + '\n')

    print(f"")
    print(f"✓ Updated instances_to_rerun.txt with {len(incomplete_instances)} instances")
    print(f"")
    print(f"To rerun these again:")
    print(f"  bash rerun_incomplete.sh")
else:
    print(f"")
    print(f"✓ ALL {len(expected_instances)} instances now have patches!")
    print(f"✓ Ready for: bash pipeline.sh")
    # Clear instances_to_rerun.txt
    with open('instances_to_rerun.txt', 'w') as f:
        pass

CHECK_COMPLETION

echo ""
echo "=========================================================================="
echo "RERUN COMPLETE"
echo "=========================================================================="
