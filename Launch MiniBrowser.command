#!/bin/bash
# MiniBrowser (c) 2026 Trendzza. All rights reserved. Free forever, non-commercial — see LICENSE.
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/MiniBrowser.app/Contents/MacOS/MiniBrowser" >/dev/null 2>&1 &
