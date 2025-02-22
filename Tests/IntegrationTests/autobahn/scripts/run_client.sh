#!/bin/bash

# Ensure the script runs from its own directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Define volumes
CONFIG_DIR="$ROOT_DIR/configs"
REPORTS_DIR="$ROOT_DIR/reports"
SERVER_PORT=9002

echo $CONFIG_DIR
echo $REPORTS_DIR

test_cases=(
    "IntegrationTests.AutobahnServerTest/testBasic"
    "IntegrationTests.AutobahnServerTest/testCase12"
    "IntegrationTests.AutobahnServerTest/testCase13_1"
    "IntegrationTests.AutobahnServerTest/testCase13_2"
    "IntegrationTests.AutobahnServerTest/testCase13_3"
    "IntegrationTests.AutobahnServerTest/testCase13_4"
    "IntegrationTests.AutobahnServerTest/testCase13_5"
    "IntegrationTests.AutobahnServerTest/testCase13_6"
    "IntegrationTests.AutobahnServerTest/testCase13_7"
)

json_files=(
    "fuzzingclient.json"
    "fuzzingclient_12.json"
    "fuzzingclient_13_1.json"
    "fuzzingclient_13_2.json"
    "fuzzingclient_13_3.json"
    "fuzzingclient_13_4.json"
    "fuzzingclient_13_5.json"
    "fuzzingclient_13_6.json"
    "fuzzingclient_13_7.json"
)

server_ports=(
    9002
    9003
    9004
    9005
    9006
    9007
    9008
    9009
    9010
)

# Check if the sizes of both arrays are the same
if [ "${#test_cases[@]}" -ne "${#json_files[@]}" ] || [ "${#test_cases[@]}" -ne "${#server_ports[@]}" ]; then
  echo "Error: The number of test cases and JSON files and ports do not match!"
  exit 1
fi

# Example usage: loop over the array and print each test case
for i in "${!test_cases[@]}"; do
    test_case=${test_cases[$i]}
    json_file=${json_files[$i]}
    server_port=${server_ports[$i]}

    echo "Running test case $test_case using $json_file"

    log_file=$(echo "$test_case" | sed 's/\//./g').log


    # Run the server in the background
     swift test -c release --filter "$test_case" &> "$log_file" &

    # Wait for the server to bind to the port
    timeout=30  # Max wait time for the server to start
    elapsed=0

    # Loop to check for the server's PID binding to port
    while ! lsof -n -i :$server_port -t > /dev/null; do
    if (( elapsed >= timeout )); then
        echo "Server did not start on port in time."
        exit 1
    fi
    # Sleep for 1 second before checking again
    sleep 1
    ((elapsed++))
    done

    # Retrieve the server PID from port
    PID=$(lsof -n -i :$server_port -t)
    echo "Server is running with PID: $PID"


    if [ $? -ne 0 ]; then
        echo "Non-zero exit code"
        exit 1
    fi

    sleep 2

    docker run -it --rm \
    -v "$CONFIG_DIR:/config" \
    -v "$REPORTS_DIR:/reports" \
    -p 9001:9001 \
    --name fuzzingclient \
    crossbario/autobahn-testsuite wstest --mode fuzzingclient --spec /config/$json_file

    kill -9 $PID

    echo "=========================== Test $test_case Done ============================"
    sleep 5
done

./check_server_results.py -p "$REPORTS_DIR/servers"
