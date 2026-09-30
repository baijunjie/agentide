#!/bin/sh
set -eu

project="apps/ios/AgentIDEiOS.xcodeproj"
scheme="AgentIDEiOS"
derived_data_path=".build/ios-derived-data"

if [ -n "${AGENTIDE_IOS_SIMULATOR_ID:-}" ]; then
  simulator_id="$AGENTIDE_IOS_SIMULATOR_ID"
else
  simulator_id="$(
    xcodebuild -project "$project" -scheme "$scheme" -showdestinations 2>&1 |
      awk '/platform:iOS Simulator/ && /name:iPhone/ && !/placeholder/ {
        if (match($0, /id:[^,}]*/)) {
          value = substr($0, RSTART + 3, RLENGTH - 3)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          print value
          exit
        }
      }'
  )"
fi

if [ -z "$simulator_id" ]; then
  echo "No available iPhone simulator was found. Set AGENTIDE_IOS_SIMULATOR_ID to choose one explicitly." >&2
  exit 1
fi

run_xcodebuild() {
  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -derivedDataPath "$derived_data_path" \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 180 \
    "$@"
}

run_xcodebuild build-for-testing
run_xcodebuild -only-testing:AgentIDEiOSTests test-without-building

# Use Xcode's test manifest instead of inferring test methods from source. This catches every
# XCTest declaration that Xcode will execute, including tests in new files and async methods.
enumeration_dir="$(mktemp -d -t agentide-ios-tests)"
enumeration_output="$enumeration_dir/tests.json"
trap 'rm -rf "$enumeration_dir"' EXIT HUP INT TERM

run_xcodebuild \
  -only-testing:AgentIDEiOSUITests \
  test-without-building \
  -enumerate-tests \
  -test-enumeration-style flat \
  -test-enumeration-format json \
  -test-enumeration-output-path "$enumeration_output"

if ! jq -e '.errors == [] and (.values | length > 0)' "$enumeration_output" >/dev/null; then
  echo "Xcode did not return a valid iOS UI test manifest." >&2
  exit 1
fi
ui_tests="$(jq -r '.values[].enabledTests[].identifier' "$enumeration_output" | LC_ALL=C sort -u)"
if [ -z "$ui_tests" ]; then
  echo "Xcode did not find any enabled iOS UI tests." >&2
  exit 1
fi
printf '%s\n' "$ui_tests" | while IFS= read -r test_name; do
  run_xcodebuild \
    -only-testing:"$test_name" \
    test-without-building
done
