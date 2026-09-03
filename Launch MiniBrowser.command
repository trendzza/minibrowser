#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/MiniBrowser.app/Contents/MacOS/MiniBrowser" >/dev/null 2>&1 &
