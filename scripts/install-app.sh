#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="/tmp/dev.ruobin.QuotaBar-build/QuotaBar.app"
target_app="/Applications/QuotaBar.app"
backup_dir="$project_dir/outputs/install-backups"
timestamp="$(date +%Y%m%d-%H%M%S)"

zsh "$project_dir/scripts/build-app.sh"
mkdir -p "$backup_dir"

running_pid="$(pgrep -f '^/Applications/QuotaBar.app/Contents/MacOS/QuotaBar$' | head -1 || true)"
if [[ -n "$running_pid" ]]; then
  kill "$running_pid"
  for _ in {1..20}; do
    if ! kill -0 "$running_pid" 2>/dev/null; then break; fi
    sleep 0.25
  done
fi

if [[ -e "$target_app" ]]; then
  mv "$target_app" "$backup_dir/QuotaBar.app.$timestamp"
fi
ditto "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"
open "$target_app"

echo "$target_app"
