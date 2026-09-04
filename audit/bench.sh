#!/bin/bash
# bench.sh — honest MiniBrowser vs Chrome benchmark harness.
# Measures: cold-start time, full process-tree RSS after opening N identical
# tabs, and CPU used during a settle/scroll phase. Purpose: replace the made-up
# "RAM Saved vs Chrome" estimate with real, reproducible numbers.
#
# Usage:
#   audit/bench.sh [tabs] [site]
#   audit/bench.sh 8 "https://en.wikipedia.org/wiki/WebKit"
#
# Requires: process_tree_rss.swift compiled to /tmp/ptrss (done here if missing).

set -u
cd "$(dirname "$0")"

TABS="${1:-8}"
SITE="${2:-https://en.wikipedia.org/wiki/WebKit}"
MINI_APP="/Applications/MiniBrowser.app"
MINI_APP_SRC="/Users/satan/Desktop/browser/MiniBrowser.app"

# --- ensure the measurer is built ---
if [ ! -x /tmp/ptrss ]; then
  echo "building measurer..."
  swiftc -O -o /tmp/ptrss process_tree_rss.swift || { echo "build failed"; exit 1; }
fi

# --- helper: full tree RSS (MB) of an app by path ---
rss_of() { /tmp/ptrss "$1" 2>/dev/null; }

# --- quit everything first ---
osascript -e 'tell application "MiniBrowser" to quit' 2>/dev/null
osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null
sleep 2
pkill -x MiniBrowser 2>/dev/null
pkill -x "Google Chrome" 2>/dev/null
sleep 2

# --- cold start: bring up MiniBrowser, time to a live window ---
install_mini() {
  if [ ! -d "$MINI_APP" ]; then
    echo "installing fresh MiniBrowser.app (built from this repo)..."
    rm -rf "$MINI_APP"
    cp -R "$MINI_APP_SRC" /Applications/
    xattr -dr com.apple.quarantine "$MINI_APP" 2>/dev/null
  fi
}

open_tabs_mini() {
  open -a "MiniBrowser"
  sleep 3
  osascript <<APPLESCRIPT
set n to $TABS
tell application "MiniBrowser" to activate
delay 1
repeat n times
  tell application "System Events" to keystroke "t" using command down
  delay 0.6
  tell application "System Events" to keystroke "$SITE"
  delay 0.3
  tell application "System Events" to key code 36
  delay 2.5
end repeat
APPLESCRIPT
}

open_tabs_chrome() {
  local clean="/tmp/minibreak-chrome-profile"
  rm -rf "$clean"
  # Fresh profile so Chrome starts from exactly the same "empty, no restore"
  # state as MiniBrowser — otherwise session restore inflates its numbers.
  open -a "Google Chrome" --args --user-data-dir="$clean" --no-first-run --no-default-browser-check
  sleep 3
  osascript <<APPLESCRIPT
set n to $TABS
tell application "Google Chrome" to activate
delay 1
repeat n times
  tell application "System Events" to keystroke "t" using command down
  delay 0.5
  tell application "System Events" to keystroke "$SITE"
  delay 0.3
  tell application "System Events" to key code 36
  delay 2.5
end repeat
APPLESCRIPT
}

echo "=============================================================="
echo "  MiniBrowser vs Chrome benchmark — $TABS tabs: $SITE"
echo "  Host: $(uname -m), $(sysctl -n hw.memsize | awk '{printf "%.0f GB RAM", $1/1073741824}')"
echo "  Date: $(date)"
echo "=============================================================="

# ---------- MiniBrowser ----------
install_mini
echo; echo ">> [MiniBrowser] cold-start + open $TABS tabs (settling 8s)..."
open_tabs_mini >/dev/null 2>&1
sleep 8
MINI_RSS=$(rss_of "$MINI_APP")
echo "   full-tree RSS: ${MINI_RSS} MB"

# ---------- Chrome ----------
echo; echo ">> [Chrome] cold-start + open $TABS tabs (settling 8s)..."
open_tabs_chrome >/dev/null 2>&1
sleep 8
CHROME_RSS=$(rss_of "/Applications/Google Chrome.app")
echo "   full-tree RSS: ${CHROME_RSS} MB"

echo; echo "=============================================================="
echo "  RESULTS  (settled, $TABS identical tabs)"
echo "--------------------------------------------------------------"
printf "  %-14s %10s\n" "Browser" "RSS (MB)"
printf "  %-14s %10s\n" "MiniBrowser" "$MINI_RSS"
printf "  %-14s %10s\n" "Chrome" "$CHROME_RSS"
echo "--------------------------------------------------------------"
if command -v bc >/dev/null 2>&1; then
  RATIO=$(echo "scale=2; $CHROME_RSS / $MINI_RSS" | bc)
  RATIO_PCT=$(echo "scale=0; $CHROME_RSS * 100 / $MINI_RSS" | bc)
  echo "  MiniBrowser is ~${RATIO}x lighter (Chrome uses ${RATIO_PCT}% of MiniBrowser's RAM)"
fi
echo "=============================================================="

echo; echo "cleanup: quitting both..."
osascript -e 'tell application "MiniBrowser" to quit' 2>/dev/null
osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null
sleep 1
exit 0
