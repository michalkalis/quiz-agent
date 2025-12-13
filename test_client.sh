#!/bin/bash
# Test script for Quiz Agent terminal client

set -e

cd "$(dirname "$0")"

echo "=== Testing Quiz Agent Terminal Client ==="
echo

# Activate virtual environment
source .venv/bin/activate

# Start server in background
echo "Starting Quiz Agent API server..."
cd apps/quiz-agent
python -m app.main > /tmp/quiz-agent-server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"
cd ../..

# Wait for server to start
echo "Waiting for server to initialize..."
sleep 8

# Check if server is running
if ! ps -p $SERVER_PID > /dev/null; then
    echo "✗ Server process died"
    cat /tmp/quiz-agent-server.log
    exit 1
fi

echo "✓ Server is running"
echo

# Test API endpoints
echo "Testing API endpoints..."
echo

echo "1. Health Check:"
curl -s http://localhost:8002/api/v1/health | python -m json.tool
echo

echo "2. Create Session:"
SESSION_RESPONSE=$(curl -s -X POST "http://localhost:8002/api/v1/sessions" \
  -H "Content-Type: application/json" \
  -d '{"max_questions": 3, "difficulty": "medium", "mode": "single"}')
echo "$SESSION_RESPONSE" | python -m json.tool

SESSION_ID=$(echo "$SESSION_RESPONSE" | python -c "import sys, json; print(json.load(sys.stdin)['session_id'])")
echo
echo "Session ID: $SESSION_ID"
echo

echo "3. Start Quiz:"
QUIZ_RESPONSE=$(curl -s -X POST "http://localhost:8002/api/v1/sessions/$SESSION_ID/start" \
  -H "Content-Type: application/json" \
  -d '{}')
echo "$QUIZ_RESPONSE" | python -m json.tool | head -30
echo

QUESTION=$(echo "$QUIZ_RESPONSE" | python -c "import sys, json; data=json.load(sys.stdin); print(data['current_question']['question'] if 'current_question' in data and data['current_question'] else 'No question')")
echo "First Question: $QUESTION"
echo

echo "4. Submit Answer:"
ANSWER_RESPONSE=$(curl -s -X POST "http://localhost:8002/api/v1/sessions/$SESSION_ID/input" \
  -H "Content-Type: application/json" \
  -d '{"input": "Paris"}')
echo "$ANSWER_RESPONSE" | python -m json.tool | head -40

# Cleanup
echo
echo "Stopping server..."
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null || true

echo
echo "✅ Client test completed successfully!"
echo
echo "To test the interactive terminal client, run:"
echo "  cd apps/quiz-agent/cli"
echo "  python quiz.py"
