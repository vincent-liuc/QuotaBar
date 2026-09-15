#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="/tmp/dev.ruobin.QuotaBar-build/QuotaBar.app"
target_app="/Applications/QuotaBar.app"
backup_dir="$project_dir/outputs/install-backups"
timestamp="$(date +%Y%m%d-%H%M%S)"

zsh "$project_dir/scripts/build-app.sh"
mkdir -p "$backup_dir"

running_pids=("${(@f)$(pgrep -f '^/Applications/QuotaBar.app/Contents/MacOS/QuotaBar$' || true)}")
for running_pid in "${running_pids[@]}"; do
  [[ -n "$running_pid" ]] && kill "$running_pid"
done
for _ in {1..40}; do
  remaining_pids="$(pgrep -f '^/Applications/QuotaBar.app/Contents/MacOS/QuotaBar$' || true)"
  [[ -z "$remaining_pids" ]] && break
  sleep 0.25
done
if [[ -n "${remaining_pids:-}" ]]; then
  echo "Unable to stop existing QuotaBar processes: ${remaining_pids//$'\n'/, }" >&2
  exit 1
fi

if [[ -e "$target_app" ]]; then
  mv "$target_app" "$backup_dir/QuotaBar.app.$timestamp"
fi
ditto "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"
open "$target_app"

echo "$target_app"
