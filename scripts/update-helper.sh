#!/bin/zsh
set -u

staged="$1"
current="$2"
backup="$3"
expected_version="$4"
log="$5"
old_pid="$6"
bundle_id="dev.ruobin.QuotaBar"

exec >> "$log" 2>&1

quotabar_pids() {
  local pid process_path app_path process_bundle_id
  for pid in $(/usr/bin/pgrep -x QuotaBar 2>/dev/null); do
    process_path="$(/bin/ps -p "$pid" -o comm= 2>/dev/null)"
    [[ "$process_path" == */Contents/MacOS/QuotaBar ]] || continue
    app_path="${process_path%/Contents/MacOS/QuotaBar}"
    [[ "$app_path" == *.app ]] || continue
    process_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null)"
    [[ "$process_bundle_id" == "$bundle_id" ]] && print -r -- "$pid"
  done
}

stop_quotabar_processes() {
  local pids pid
  pids="$(quotabar_pids)"
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && /bin/kill "$pid" 2>/dev/null || true
    done <<< "$pids"
  fi
  for _ in {1..40}; do
    [[ -z "$(quotabar_pids)" ]] && return 0
    sleep 0.25
  done
  pids="$(quotabar_pids)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && /bin/kill -KILL "$pid" 2>/dev/null || true
  done <<< "$pids"
  for _ in {1..20}; do
    [[ -z "$(quotabar_pids)" ]] && return 0
    sleep 0.25
  done
  return 1
}

single_current_pid() {
  local pids pid process_path total=0 matched=0 current_pid=""
  pids="$(quotabar_pids)"
  [[ -n "$pids" ]] || return 1
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    (( total += 1 ))
    process_path="$(/bin/ps -p "$pid" -o comm= 2>/dev/null)"
    if [[ "$process_path" == "$current/Contents/MacOS/QuotaBar" ]]; then
      (( matched += 1 ))
      current_pid="$pid"
    fi
  done <<< "$pids"
  (( total == 1 && matched == 1 )) || return 1
  print -r -- "$current_pid"
}

wait_for_stable_current() {
  local candidate_pid="" stable_pid=""
  for _ in {1..40}; do
    candidate_pid="$(single_current_pid || true)"
    [[ -n "$candidate_pid" ]] && break
    sleep 0.25
  done
  [[ -n "$candidate_pid" ]] || return 1
  sleep 3
  stable_pid="$(single_current_pid || true)"
  [[ "$stable_pid" == "$candidate_pid" ]] || return 1
  /bin/kill -0 "$stable_pid" 2>/dev/null
}

restore_previous_app() {
  stop_quotabar_processes || return 10
  if [[ -e "$current" ]]; then
    /bin/rm -rf "$current" || return 11
  fi
  [[ ! -e "$current" ]] || return 12
  if ! /bin/mv "$backup" "$current"; then
    [[ -e "$backup" ]] && /usr/bin/open "$backup" 2>/dev/null || true
    return 13
  fi
  if ! /usr/bin/open "$current"; then
    return 14
  fi
  wait_for_stable_current || return 15
  /bin/rm -rf "$staged"
  return 0
}

# The parent app requests termination immediately after starting this helper.
# Stop other QuotaBar app copies first, then force the old process down only if it stalls.
for pid in $(quotabar_pids); do
  if [[ "$pid" != "$old_pid" ]]; then /bin/kill "$pid" 2>/dev/null || true; fi
done
for _ in {1..120}; do
  [[ -z "$(quotabar_pids)" ]] && break
  sleep 0.25
done
if [[ -n "$(quotabar_pids)" ]] && ! stop_quotabar_processes; then
  /bin/rm -rf "$staged"
  /usr/bin/open "$current" 2>/dev/null || true
  exit 1
fi

if ! /bin/mv "$current" "$backup"; then
  /bin/rm -rf "$staged"
  /usr/bin/open "$current" 2>/dev/null || true
  wait_for_stable_current || true
  exit 2
fi

if /bin/mv "$staged" "$current"; then
  /usr/bin/xattr -cr "$current"
  installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$current/Contents/Info.plist" 2>/dev/null)"
  if [[ "$installed_version" == "$expected_version" ]] &&
     /usr/bin/open "$current" && wait_for_stable_current; then
    /bin/rm -rf "$backup"
    exit 0
  fi
fi

if restore_previous_app; then
  exit 3
fi

# Keep the backup and log for manual recovery. If possible, launch the backup in place.
[[ -e "$backup" ]] && /usr/bin/open "$backup" 2>/dev/null || true
exit 4
