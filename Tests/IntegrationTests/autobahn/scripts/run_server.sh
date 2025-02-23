#!/bin/bash

# Ensure the script runs from its own directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Define volumes
CONFIG_DIR="$ROOT_DIR/configs"
REPORTS_DIR="$ROOT_DIR/reports"
FUZZING_SERVER_NAME="fuzzingserver"

echo $CONFIG_DIR
echo $REPORTS_DIR


# Run Docker container
docker run -d --rm \
    -v "$CONFIG_DIR:/config" \
    -v "$REPORTS_DIR:/reports" \
    -p 9001:9001 \
    --name "$FUZZING_SERVER_NAME" \
    crossbario/autobahn-testsuite wstest --mode fuzzingserver --spec /config/fuzzingserver.json &

echo "waiting for server to be ready"
sleep 5

swift test -c release --filter IntegrationTests.AutobahnClientTest

docker logs $FUZZING_SERVER_NAME > "$FUZZING_SERVER_NAME.log" 

FUZZING_SERVER_ID=$(docker ps -f "name=$FUZZING_SERVER_NAME" --format "{{.ID}}")
docker stop $FUZZING_SERVER_ID
