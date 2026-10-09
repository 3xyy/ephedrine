#!/bin/bash
# Build Ephedrine.app into <out-dir> (SwiftPM release build + app bundle + signature).
#   scripts/bundle.sh <out-dir>
# Signing: $CODESIGN_IDENTITY if set ("-" = ad-hoc), else a code-signing
# identity named "Ephedrine Dev" if you have one, else ad-hoc. A stable identity
# keeps macOS permissions (Automation, Notifications) across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: bundle.sh <out-dir>}"
APP="$OUT/Ephedrine.app"

echo "› Building (swift build -c release)…"
# --disable-sandbox: SwiftPM's own sandbox can't nest inside Homebrew's.
swift build -c release --disable-sandbox --package-path "$ROOT"
BIN="$(swift build -c release --disable-sandbox --package-path "$ROOT" --show-bin-path)/Ephedrine"

echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ephedrine"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift icon/make-icon.swift

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    # No -v: a self-signed cert isn't "trusted" but still signs fine.
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null | sed -n 's/.*"\(Ephedrine Dev\)".*/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "  signed with '$IDENTITY'"
else
    [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] && echo "  couldn't sign with '$IDENTITY', using ad-hoc"
    codesign --force --sign - "$APP"
    echo "  ad-hoc signed (macOS asks for Automation/Notifications again after each rebuild)"
fi
echo "✓ Built $APP"
