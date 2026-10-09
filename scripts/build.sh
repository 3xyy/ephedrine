#!/bin/bash
# Development: rebuild Ephedrine.app into ~/Applications and relaunch it.
# (First time? Run `scripts/ephedrine setup` instead, since it also installs the Claude Code hooks.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Quit a running copy so the bundle can be replaced. A plain quit lets it
# release lid-closed mode and un-pause apps; pkill (SIGTERM) does the same.
osascript -e 'tell application id "io.github.3xyy.ephedrine" to quit' 2>/dev/null || true
pkill -x Ephedrine 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
"$HERE/bundle.sh" "$HOME/Applications"
open "$HOME/Applications/Ephedrine.app" && echo "✓ Relaunched Ephedrine"
