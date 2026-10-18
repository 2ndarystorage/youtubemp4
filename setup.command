#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"
if ! command -v brew >/dev/null; then
  echo 'Homebrewを先に https://brew.sh/ja/ の案内で導入してください。'
  read -r -p 'Enterで閉じる' _answer
  exit 1
fi
brew install python yt-dlp ffmpeg deno
echo '準備が完了しました。start.commandを実行してください。'
read -r -p 'Enterで閉じる' _answer
