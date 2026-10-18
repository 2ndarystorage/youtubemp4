#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"
export VIDEO_SAVER_DIR="${VIDEO_SAVER_DIR:-/Volumes/M2NVMe/YouTubeMP4}"
exec caffeinate -i python3 server.py
