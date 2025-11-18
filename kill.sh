#!/bin/bash

# Script to kill all workflow.py processes

echo "Searching for workflow.py processes..."

# Find all workflow.py processes
PIDS=$(pgrep -f "python.*workflow\.py")

if [ -z "$PIDS" ]; then
    echo "No workflow.py processes found."
    exit 0
fi

echo "Found the following workflow.py processes:"
ps aux | grep "python.*workflow\.py" | grep -v grep

echo ""
echo "Killing processes..."

# Kill all workflow.py processes
pkill -9 -f "python.*workflow\.py"

# Wait a moment for processes to be killed
sleep 1

# Verify they're gone
REMAINING=$(pgrep -f "python.*workflow\.py")

if [ -z "$REMAINING" ]; then
    echo "✓ All workflow.py processes have been killed successfully."
else
    echo "Warning: Some processes may still be running:"
    ps aux | grep "python.*workflow\.py" | grep -v grep
fi
