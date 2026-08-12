#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_binary="/tmp/dev.ruobin.OpenAIUsageBar-self-test"

swiftc \
  -parse-as-library \
  "$project_dir/Sources/OpenAIUsageBar/Models.swift" \
  "$project_dir/Sources/OpenAIUsageBar/AppPreferences.swift" \
  "$project_dir/Sources/OpenAIUsageBar/APIClient.swift" \
  "$project_dir/Sources/OpenAIUsageBar/AppUpdater.swift" \
  "$project_dir/Tests/SelfTest.swift" \
  -o "$test_binary"

"$test_binary"
