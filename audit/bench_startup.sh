#!/bin/bash
# bench_startup.sh — cold-start time: from process launch until the app's main
# process is alive, has spawned its helper processes, and has grown past its
# initial image size (proxy for "UI up and ready"). Measures the same way for
# both MiniBrowser and Chrome so the comparison is apples-to-apples.
#
# Usage: audit/bench_startup.sh [runs]
set -u
RUNS="${1:-5}"

MINI="/Applications/MiniBrowser.app"
CHROME="/Applications/Google Chrome.app"
PROFILE="/tmp/minibreak-chrome-profile"

quit_all() {
  osascript -e 'tell application "MiniBrowser" to quit' 2>/dev/null
  osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null
  sleep 2
  pkill -x MiniBrowser 2>/dev/null
  pkill -x "Google Chrome" 2>/dev/null
  pkill -x "Google Chrome Helper" 2>/dev/null
  sleep 1
}

# returns seconds from `open -a` to the app being "ready":
# main pid alive AND total tree RSS > 30MB (i.e. webview spawned, not just the
# thin executable image).
time_ready_mini() {
  local t0=$(python3 -c 'import time; print(time.time())')
  open -a "MiniBrowser" >/dev/null 2>&1
  while true; do
    local pid=$(pgrep -x MiniBrowser | head -1)
    if [ -n "$pid" ]; then
      local rss=$(/tmp/ptrss "$MINI" 2>/dev/null)
      if [ -n "$rss" ] && [ "$(echo "$rss >= 30" | bc)" = "1" ]; then
        break
      fi
    fi
    sleep 0.05
  done
  local t1=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(round($t1 - $t0, 2))"
}

time_ready_chrome() {
  local t0=$(python3 -c 'import time; print(time.time())')
  rm -rf "$PROFILE"
  open -a "Google Chrome" --args --user-data-dir="$PROFILE" --no-first-run >/dev/null 2>&1
  while true; do
    local pid=$(pgrep -x "Google Chrome" | head -1)
    if [ -n "$pid" ]; then
      local rss=$(/tmp/ptrss "/Applications/Google Chrome.app" 2>/dev/null)
      if [ -n "$rss" ] && [ "$(echo "$rss >= 60" | bc)" = "1" ]; then
        break
      fi
    fi
    sleep 0.05
  done
  local t1=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(round($t1 - $t0, 2))"
}

if [ ! -x /tmp/ptrss ]; then
  swiftc -O -o /tmp/ptrss "$(dirname "$0")/process_tree_rss.swift" || exit 1
fi

echo "== Cold-start benchmark: $RUNS runs each =="
echo "Host: $(uname -m) | $(date)"

declare -a MT CT
for ((i=0;i<RUNS;i++)); do
  quit_all
  MT+=("$(time_ready_mini)")
  quit_all; sleep 1
  CT+=("$(time_ready_chrome)")
  echo "run $((i+1)): Mini $((i+1))s=${MT[$i]:-?}  Chrome ${CT[$i]:-?}"
done

# median via sort
m_med=$(printf '%s\n' "${MT[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
c_med=$(printf '%s\n' "${CT[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')

echo "==================================================="
printf "  %-14s %s\n" "Browser" "median cold-start (s)"
printf "  %-14s %s\n" "MiniBrowser" "$m_med"
printf "  %-14s %s\n" "Chrome" "$c_med"
echo "---------------------------------------------------"
echo "  MiniBrowser cold-start ratio: ~$(echo "scale=2; $m_med/$c_med" | bc)x of Chrome's"
echo "==================================================="

quit_all
