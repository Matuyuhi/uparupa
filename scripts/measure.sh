#!/bin/sh
# Measures how big and how fast upaa is, for the weekly measurements (.github/workflows/measure.yml).
# Builds the release app, then launches it and presses keys with System Events, as the launch screenshots in test.yml do,
# so it needs a Mac with a desktop session that allows that. Prints each number and writes build/measure/results.json
# (name: number). Names ending in _per_s are better higher; all others are better lower.
# The workflow runs it without the build cache, so the build times are of a cold build.
set -eu
cd "$(dirname "$0")/.."

out="$PWD/build/measure"
rm -rf "$out"
mkdir -p "$out/config"
results="$out/results.tsv"
: > "$results"

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
calc() { awk "BEGIN { printf \"%.$1f\", $2 }"; }
record() {
  case "$2" in '' | *[!0-9.]* | *.*.*) echo "no number for $1: $2" >&2; exit 1 ;; esac
  printf '%s\t%s\n' "$1" "$2" >> "$results"
  echo "$1: $2"
}
kib() { echo $(( $(stat -f%z "$1") / 1024 )); }

# Build
start=$(now)
zig build -Doptimize=ReleaseFast --summary all
zig_done=$(now)
CONFIG=release sh scripts/build-app.sh > /dev/null
app_done=$(now)
record build_zig_s "$(calc 1 "$zig_done - $start")"
record build_swift_and_bundle_s "$(calc 1 "$app_done - $zig_done")"

# Size
app=build/upaa.app
bin="$app/Contents/MacOS/upaa"
record app_kib "$(du -sk "$app" | cut -f1)"
ditto -c -k --keepParent "$app" "$out/upaa.zip"
record zip_kib "$(kib "$out/upaa.zip")"
record binary_kib "$(kib "$bin")"
strip -x -o "$out/upaa-stripped" "$bin"
record binary_stripped_kib "$(kib "$out/upaa-stripped")"
record core_lib_kib "$(kib zig-out/lib/libupaacore.a)"
record metallib_kib "$(kib "$app/Contents/Resources/default.metallib")"

# Without a window: how fast cat goes through a session, and one frame's build (as in test.sh).
[ -f build/bench.txt ] || head -c 15000000 /dev/urandom | base64 -b 100 > build/bench.txt
bench="$("$bin" --bench-headless "$PWD/build/bench.txt")"
record headless_cat_mb_per_s "$(echo "$bench" | sed -n 's/^cat (no rendering): \([0-9.]*\) MB\/s.*/\1/p')"
record headless_frame_ms "$(echo "$bench" | sed -n 's/^1 frame build: \([0-9.]*\) ms.*/\1/p')"

# With a window. Prints the id of the window owned by the given process, or nothing yet.
cat > "$out/window.swift" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
if let id = windows.first(where: { $0["kCGWindowOwnerPID"] as? Int == pid && $0["kCGWindowLayer"] as? Int == 0 })?["kCGWindowNumber"] {
    print(id)
}
SWIFT
swiftc -O "$out/window.swift" -o "$out/window"

pid=
# Each launch starts at the default size, so upaa's saved windows are deleted, and put back at the end, for a Mac in use.
saved=
if defaults export local.upaa "$out/defaults.plist" 2> /dev/null; then saved=1; fi
# Also on a failure on the way, which leaves no app running.
finish() {
  [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
  if [ -n "$saved" ]; then defaults import local.upaa "$out/defaults.plist"; else defaults delete local.upaa 2> /dev/null || true; fi
}
trap finish EXIT
launch() {
  # Each launch starts with no config file, and without the daily update check.
  defaults delete local.upaa 2>/dev/null || true
  XDG_CONFIG_HOME="$out/config" UPAA_NO_UPDATE_CHECK=1 "$bin" -AppleLanguages '(en)' > /dev/null &
  pid=$!
}
calculator() {
  /System/Applications/Calculator.app/Contents/MacOS/Calculator > /dev/null 2>&1 &
  pid=$!
}
quit() {
  kill "$pid"
  wait "$pid" || true
}
# Waits for the window to be on screen.
wait_window() {
  deadline=$(( $(date +%s) + 30 ))
  until [ -n "$("$out/window" "$pid")" ]; do
    kill -0 "$pid" || { echo "the app exited during launch" >&2; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "the app opened no window in 30 seconds" >&2; exit 1; }
    sleep 0.02
  done
}
keys() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" "$@"
}
# CPU seconds the app has used so far (ps prints [hours:]minutes:seconds).
cpu() { ps -o time= -p "$pid" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'; }
# Percent of one core the app used over the given seconds.
cpu_over() {
  before=$(cpu)
  sleep "$1"
  calc 2 "($(cpu) - $before) / $1 * 100"
}
# The app's physical footprint in MiB, as Activity Monitor's Memory column (Metal buffers included).
footprint() {
  vmmap --summary "$pid" 2>/dev/null | awk '/^Physical footprint:/ {
    v = $3; u = substr(v, length(v)); v = substr(v, 1, length(v) - 1)
    if (u == "K") v /= 1024; else if (u == "G") v *= 1024
    printf "%.1f", v }'
}
# Types the command into the window and waits for it to write its time (/usr/bin/time -p) into the given file.
# Prints the seconds it took, and records the app's CPU seconds meanwhile under the given name.
timed() {
  file="$out/$1.time"
  before=$(cpu)
  keys -e "tell application \"System Events\" to keystroke \"/usr/bin/time -p $2 2> $file; clear\"" \
    -e 'tell application "System Events" to key code 36'
  deadline=$(( $(date +%s) + 180 ))
  until grep -q '^real' "$file" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "$2 did not finish in 180 seconds" >&2; exit 1; }
    sleep 0.1
  done
  record "$1_s" "$(awk '/^real/ { print $2 }' "$file")"
  record "$1_app_cpu_s" "$(calc 2 "$(cpu) - $before")"
}

# From starting the process to its window on screen, the middle of three. Calculator's, for how fast the runner opens
# any app's window, and upaa --version's, for the part before AppKit starts.
launch_time() {
  : > "$out/launch.txt"
  for i in 1 2 3; do
    start=$(now)
    "$1"
    wait_window
    echo "$(calc 3 "$(now) - $start")" >> "$out/launch.txt"
    quit
  done
}
launch_time launch
record launch_to_window_s "$(sort -n "$out/launch.txt" | sed -n 2p)"
launch_time calculator
record calculator_launch_to_window_s "$(sort -n "$out/launch.txt" | sed -n 2p)"
: > "$out/version.txt"
for i in 1 2 3; do
  start=$(now)
  "$bin" --version > /dev/null
  echo "$(calc 3 "$(now) - $start")" >> "$out/version.txt"
done
record version_exit_s "$(sort -n "$out/version.txt" | sed -n 2p)"

launch
wait_window
# The mascot greets for about 2 seconds, then idles.
sleep 8
record idle_cpu_percent "$(cpu_over 20)"
record idle_footprint_mib "$(footprint)"

# Hidden (Cmd-H): nothing on screen needs drawing.
osascript -e "tell application \"System Events\" to set visible of (first process whose unix id is $pid) to false"
sleep 3
record hidden_cpu_percent "$(cpu_over 20)"
osascript -e "tell application \"System Events\" to set visible of (first process whose unix id is $pid) to true"
sleep 2

# In a git repository, where the tab list's subtitle and the changes panel read git every 3 seconds.
keys -e "tell application \"System Events\" to keystroke \"cd $PWD; clear\"" -e 'tell application "System Events" to key code 36'
sleep 5
record idle_in_repo_cpu_percent "$(cpu_over 20)"

# Output through the window, drawn as it comes.
timed cat_15mb "cat $PWD/build/bench.txt"
timed yes_2m_lines "sh -c 'yes | head -n 2000000'"

# Four tabs, the last split in two: five shells.
keys -e 'tell application "System Events" to keystroke "t" using command down' -e 'delay 1' \
  -e 'tell application "System Events" to keystroke "t" using command down' -e 'delay 1' \
  -e 'tell application "System Events" to keystroke "t" using command down' -e 'delay 1' \
  -e 'tell application "System Events" to keystroke "d" using command down'
sleep 8
record five_panes_idle_cpu_percent "$(cpu_over 20)"
record five_panes_footprint_mib "$(footprint)"
quit
pid=

awk -F '\t' 'BEGIN { printf "{" } { printf "%s\"%s\": %s", (NR > 1 ? ", " : ""), $1, $2 } END { print "}" }' "$results" > "$out/results.json"
cat "$out/results.json"
