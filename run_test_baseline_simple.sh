#!/bin/bash
################################################################################
# Run 30 Test Instances WITHOUT Experience - Simple Direct Approach
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Baseline (WITHOUT Experience)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Backup old baseline
if [ -f "django/test_baseline.jsonl" ]; then
    BACKUP_FILE="django/test_baseline_backup_$(date +%Y%m%d_%H%M%S).jsonl"
    cp django/test_baseline.jsonl "$BACKUP_FILE"
    echo "✓ Backed up old baseline to $BACKUP_FILE"
fi

# Clear files
echo "✓ Clearing old results..."
> django/test_baseline.jsonl
> prediction_verified.jsonl

echo ""
echo -e "${BLUE}Running workflow.py for 30 test instances...${NC}"
echo "This will take approximately 20-40 minutes"
echo ""

# Run workflow WITHOUT experience
python workflow.py \
    --instance_ids test_instances.txt \
    --max_iterations 20 \
    --max_expansions 3 \
    --max_finished_nodes 1

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Workflow Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Copy results
cp prediction_verified.jsonl django/test_baseline.jsonl

# Show results
COMPLETED=$(wc -l < django/test_baseline.jsonl)
PATCHES=$(grep -c '"model_patch":' django/test_baseline.jsonl 2>/dev/null || echo "0")

echo "Results:"
echo "  Completed: $COMPLETED/30"
echo "  Patches: $PATCHES/30"
echo ""

if [ "$COMPLETED" -eq 30 ]; then
    echo -e "${GREEN}✓ All 30 instances completed!${NC}"
else
    echo "⚠ Only $COMPLETED/30 completed"
    echo ""
    echo "Missing instances:"
    python3 << 'EOF'
import json

with open('test_instances.txt', 'r') as f:
    test_ids = set(line.strip() for line in f if line.strip())

completed_ids = set()
try:
    with open('django/test_baseline.jsonl', 'r') as f:
        for line in f:
            if line.strip():
                data = json.loads(line)
                completed_ids.add(data['instance_id'])
except:
    pass

missing = test_ids - completed_ids
for instance_id in sorted(missing):
    print(f"  - {instance_id}")
EOF
fi

echo ""
echo "Results saved to: django/test_baseline.jsonl"
echo ""
echo -e "${GREEN}To evaluate, run:${NC}"
echo "  bash evaluate.sh django/test_baseline.jsonl"
echo ""
