#!/bin/sh
set -eu

project="apps/ios/AgentIDEiOS.xcodeproj"
scheme="AgentIDEiOS"

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

exec xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -parallel-testing-enabled NO \
  test
