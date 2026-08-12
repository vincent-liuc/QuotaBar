#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_binary="/tmp/dev.ruobin.QuotaBar-self-test"

swiftc \
  -parse-as-library \
  "$project_dir/Sources/QuotaBar/StationProfile.swift" \
  "$project_dir/Sources/QuotaBar/Models.swift" \
  "$project_dir/Sources/QuotaBar/AppPreferences.swift" \
  "$project_dir/Sources/QuotaBar/APIClient.swift" \
  "$project_dir/Sources/QuotaBar/AppUpdater.swift" \
  "$project_dir/Sources/QuotaBar/StatusRingRenderer.swift" \
  "$project_dir/Tests/SelfTest.swift" \
  -o "$test_binary"

"$test_binary"
