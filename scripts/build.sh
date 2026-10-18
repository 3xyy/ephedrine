#!/bin/bash
# Development: rebuild Ephedrine.app into ~/Applications and relaunch it.
# (First time? Run `scripts/ephedrine setup` instead, since it also installs the Claude Code hooks.)
# LID_SIMULATION=1 scripts/build.sh builds the variant that reads
# ~/.claude/ephedrine/simulate-lid ("closed" or "open") instead of the lid sensor.
# (bundle.sh does the build and passes -Xswiftc -DLID_SIMULATION.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Quit a running copy so the bundle can be replaced. A plain quit lets it
# release lid-closed mode and un-pause apps; pkill (SIGTERM) does the same.
osascript -e 'tell application id "io.github.3xyy.ephedrine" to quit' 2>/dev/null || true
pkill -x Ephedrine 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
"$HERE/bundle.sh" "$HOME/Applications"
# A changed icon shows only once Launch Services drops its cached copy.
touch "$HOME/Applications/Ephedrine.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Ephedrine.app" || true
open "$HOME/Applications/Ephedrine.app" && echo "✓ Relaunched Ephedrine"
