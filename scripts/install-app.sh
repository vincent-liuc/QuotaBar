#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="/tmp/dev.ruobin.QuotaBar-build/QuotaBar.app"
target_app="/Applications/QuotaBar.app"
backup_dir="$project_dir/outputs/install-backups"
failure_dir="$project_dir/outputs/install-failures"
timestamp="$(date +%Y%m%d-%H%M%S)-$$"
backup_app="$backup_dir/QuotaBar.app.$timestamp"
failed_app="$failure_dir/QuotaBar.app.$timestamp"
had_previous_install=0
backup_created=0
bundle_id="dev.ruobin.QuotaBar"

zsh "$project_dir/scripts/build-app.sh"
mkdir -p "$backup_dir" "$failure_dir"

quotabar_pids() {
  local pid process_path app_path process_bundle_id
  for pid in $(pgrep -x QuotaBar 2>/dev/null); do
    process_path="$(ps -p "$pid" -o comm= 2>/dev/null)"
    if [[ "$process_path" == */Contents/MacOS/QuotaBar ]]; then
      app_path="${process_path%/Contents/MacOS/QuotaBar}"
      if [[ "$app_path" == *.app ]]; then
        process_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null)"
        [[ "$process_bundle_id" == "$bundle_id" ]] && print -r -- "$pid"
      fi
    elif [[ "$process_path" == "$project_dir"/.build/*/QuotaBar ]]; then
      print -r -- "$pid"
    fi
  done
}

stop_quotabar_processes() {
  local running_pids remaining_pids running_pid
  running_pids="$(quotabar_pids)"
  if [[ -n "$running_pids" ]]; then
    while IFS= read -r running_pid; do
      [[ -n "$running_pid" ]] && kill "$running_pid" 2>/dev/null || true
    done <<< "$running_pids"
  fi
  for _ in {1..40}; do
    remaining_pids="$(quotabar_pids)"
    [[ -z "$remaining_pids" ]] && return 0
    sleep 0.25
  done
  echo "Unable to stop existing QuotaBar processes: ${remaining_pids//$'\n'/, }" >&2
  return 1
}

single_app_pid() {
  local expected_app="$1"
  local all_pids pid process_path total=0 matched=0 target_pid=""
  all_pids="$(quotabar_pids)"
  [[ -n "$all_pids" ]] || return 1
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    (( total += 1 ))
    process_path="$(ps -p "$pid" -o comm= 2>/dev/null)"
    if [[ "$process_path" == "$expected_app/Contents/MacOS/QuotaBar" ]]; then
      (( matched += 1 ))
      target_pid="$pid"
    fi
  done <<< "$all_pids"
  (( total == 1 && matched == 1 )) || return 1
  print -r -- "$target_pid"
}

single_target_pid() {
  single_app_pid "$target_app"
}

force_stop_quotabar_processes() {
  local remaining_pids pid
  stop_quotabar_processes && return 0
  remaining_pids="$(quotabar_pids)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
  done <<< "$remaining_pids"
  for _ in {1..20}; do
    [[ -z "$(quotabar_pids)" ]] && return 0
    sleep 0.25
  done
  return 1
}

relaunch_original_and_exit() {
  local reason="$1" relaunched_pid="" stable_pid=""
  force_stop_quotabar_processes || true
  if [[ -e "$target_app" ]] && open "$target_app"; then
    for _ in {1..40}; do
      relaunched_pid="$(single_target_pid || true)"
      [[ -n "$relaunched_pid" ]] && break
      sleep 0.25
    done
    if [[ -n "$relaunched_pid" ]]; then
      sleep 2
      stable_pid="$(single_target_pid || true)"
    fi
  fi
  echo "$reason" >&2
  if [[ -z "$relaunched_pid" || "$stable_pid" != "$relaunched_pid" ]]; then
    echo "CRITICAL: original QuotaBar remains on disk but did not relaunch cleanly" >&2
  fi
  exit 1
}

[[ -e "$target_app" ]] && had_previous_install=1

if ! stop_quotabar_processes; then
  relaunch_original_and_exit "Unable to stop existing QuotaBar processes"
fi

if (( had_previous_install )); then
  if ! mv "$target_app" "$backup_app"; then
    relaunch_original_and_exit "Unable to create a recoverable backup of the installed QuotaBar"
  fi
  backup_created=1
fi

rollback_install() {
  local reason="$1"
  local failed_preserved=0 restored=0 restored_on_disk=0 restored_pid=""
  set +e
  if ! force_stop_quotabar_processes || [[ -n "$(quotabar_pids)" ]]; then
    echo "$reason" >&2
    echo "CRITICAL: unable to stop the failed QuotaBar; the previous backup remains at $backup_app" >&2
    set -e
    return 0
  fi
  if [[ -e "$target_app" ]]; then
    if mv "$target_app" "$failed_app"; then
      failed_preserved=1
    else
      echo "Unable to preserve failed installation; removing only the newly installed app" >&2
      rm -rf "$target_app"
    fi
  fi
  if [[ -e "$target_app" ]]; then
    echo "$reason" >&2
    echo "CRITICAL: failed QuotaBar could not be cleared; the previous backup remains at $backup_app" >&2
    set -e
    return 0
  fi
  if (( backup_created )); then
    if mv "$backup_app" "$target_app"; then
      restored_on_disk=1
      if open "$target_app"; then
        for _ in {1..40}; do
          restored_pid="$(single_target_pid || true)"
          [[ -n "$restored_pid" ]] && break
          sleep 0.25
        done
      fi
      [[ -n "$restored_pid" ]] && restored=1
    else
      echo "CRITICAL: unable to restore previous QuotaBar from $backup_app" >&2
      if [[ -e "$backup_app" ]] && open "$backup_app"; then
        for _ in {1..40}; do
          restored_pid="$(single_app_pid "$backup_app" || true)"
          [[ -n "$restored_pid" ]] && break
          sleep 0.25
        done
        if [[ -n "$restored_pid" ]]; then
          sleep 2
          [[ "$(single_app_pid "$backup_app" || true)" == "$restored_pid" ]] && restored=1
        fi
      fi
    fi
  fi
  echo "$reason" >&2
  if (( restored )); then
    if (( restored_on_disk )); then
      echo "Installation rolled back to $target_app" >&2
    else
      echo "Previous QuotaBar is running from its backup at $backup_app" >&2
    fi
    (( failed_preserved )) && echo "Failed app preserved at $failed_app" >&2
  elif (( restored_on_disk )); then
    echo "CRITICAL: previous QuotaBar was restored on disk but did not relaunch cleanly" >&2
  fi
  set -e
}

if ! ditto "$source_app" "$target_app"; then
  rollback_install "Unable to copy QuotaBar into Applications"
  exit 1
fi
if ! codesign --verify --deep --strict "$target_app"; then
  rollback_install "Installed QuotaBar failed signature verification"
  exit 1
fi
if ! open "$target_app"; then
  rollback_install "Unable to launch installed QuotaBar"
  exit 1
fi

launched_pid=""
for _ in {1..40}; do
  launched_pid="$(single_target_pid || true)"
  [[ -n "$launched_pid" ]] && break
  sleep 0.25
done

if [[ -z "$launched_pid" ]]; then
  rollback_install "Installed QuotaBar did not reach a single running process"
  exit 1
fi

sleep 2
stable_pid="$(single_target_pid || true)"
if [[ "$stable_pid" != "$launched_pid" ]]; then
  rollback_install "Installed QuotaBar did not remain running as one stable process"
  exit 1
fi

echo "$target_app"
