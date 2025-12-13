#!/bin/bash
# Test script for Quiz Agent API server

set -e

cd "$(dirname "$0")"

echo "=== Testing Quiz Agent API Server ==="
echo

# Activate virtual environment
source .venv/bin/activate

# Change to quiz-agent directory
cd apps/quiz-agent

# Start server in background
echo "Starting server..."
python -m app.main > /tmp/quiz-agent.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server to start
echo "Waiting for server to initialize..."
sleep 12

# Check if server is running
if ps -p $SERVER_PID > /dev/null; then
    echo "✓ Server process is running"
else
    echo "✗ Server process died"
    cat /tmp/quiz-agent.log
    exit 1
fi

# Test health endpoint
echo "Testing health endpoint..."
HEALTH_RESPONSE=$(curl -s http://localhost:8002/api/v1/health 2>&1)
if echo "$HEALTH_RESPONSE" | grep -q "healthy"; then
    echo "✓ Health endpoint responded successfully"
    echo "  Response: $HEALTH_RESPONSE"
else
    echo "✗ Health endpoint failed"
    echo "  Response: $HEALTH_RESPONSE"
    echo
    echo "Server log:"
    cat /tmp/quiz-agent.log
    kill $SERVER_PID 2>/dev/null
    exit 1
fi

# Show first 50 lines of server log
echo
echo "=== Server Startup Log (first 50 lines) ==="
head -50 /tmp/quiz-agent.log

# Cleanup
echo
echo "Stopping server..."
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null || true

echo
echo "✅ Server test completed successfully!"
