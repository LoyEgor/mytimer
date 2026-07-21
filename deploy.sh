#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
local_app="$root/MyTimer.app"
installed_app="/Applications/MyTimer.app"
local_bin="$local_app/Contents/MacOS/MyTimer"
installed_bin="$installed_app/Contents/MacOS/MyTimer"

"$root/build.sh"
"$local_bin" --selftest

pkill -x MyTimer 2>/dev/null || true
for _ in {1..30}; do
    pgrep -x MyTimer >/dev/null || break
    sleep 0.1
done
if pgrep -x MyTimer >/dev/null; then
    echo "Failed to stop the running MyTimer process" >&2
    exit 1
fi

ditto "$local_app" "$installed_app"
local_hash=$(shasum -a 256 "$local_bin" | awk '{print $1}')
installed_hash=$(shasum -a 256 "$installed_bin" | awk '{print $1}')
if [[ "$local_hash" != "$installed_hash" ]]; then
    echo "Installed binary does not match the local build" >&2
    exit 1
fi

open "$installed_app"
pid=""
for _ in {1..30}; do
    pid=$(pgrep -f "^${installed_bin}$" | head -n 1 || true)
    [[ -n "$pid" ]] && break
    sleep 0.1
done
if [[ -z "$pid" ]]; then
    echo "Installed MyTimer did not start" >&2
    exit 1
fi
for running_pid in $(pgrep -x MyTimer); do
    running_command=$(ps -p "$running_pid" -o command= | xargs)
    if [[ "$running_command" != "$installed_bin" ]]; then
        echo "Unexpected MyTimer process: $running_command" >&2
        exit 1
    fi
done

"$installed_bin" --selftest
echo "Deployed and verified $installed_app pid=$pid sha256=$installed_hash"
