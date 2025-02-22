#!/bin/bash

# Ensure the script runs from its own directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Define volumes
CONFIG_DIR="$ROOT_DIR/configs"
REPORTS_DIR="$ROOT_DIR/reports"

echo $CONFIG_DIR
echo $REPORTS_DIR

# Run Docker container
docker run -it --rm \
    -v "$CONFIG_DIR:/config" \
    -v "$REPORTS_DIR:/reports" \
    -p 9001:9001 \
    --name fuzzingserver \
    crossbario/autobahn-testsuite wstest --mode fuzzingserver --spec /config/fuzzingserver.json
