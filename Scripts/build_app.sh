#!/bin/bash
# Builds the release binary and assembles ProductivityManager.app.
#
# The real .app bundle matters for permissions (ADR-0004): macOS attaches the
# Accessibility grant to the bundle identity, so running from a proper bundle
# keeps the consent once granted — a bare executable would re-prompt per
# terminal context.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=${1:-release}
swift build -c "$CONFIGURATION"

APP="build/ProductivityManager.app"
CONTENTS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$CONTENTS" "$RESOURCES"

BINARY=$(swift build -c "$CONFIGURATION" --show-bin-path)
cp "$BINARY/ProductivityManager" "$CONTENTS/"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                    <string>Productivity Manager</string>
    <key>CFBundleDisplayName</key>             <string>Productivity Manager</string>
    <key>CFBundleIdentifier</key>              <string>com.lakshaysoin.productivity-manager</string>
    <key>CFBundleVersion</key>                 <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>      <string>0.1.0</string>
    <key>CFBundleExecutable</key>              <string>ProductivityManager</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>LSMinimumSystemVersion</key>          <string>13.0</string>
    <!-- Faceless menu-bar app: no Dock icon, no main window (ADR-0007). -->
    <key>LSUIElement</key>                     <true/>
    <key>NSHighResolutionCapable</key>         <true/>
    <!-- Honest usage strings shown alongside the OS prompts (ADR-0004). -->
    <key>NSAccessibilityUsageDescription</key>
    <string>Productivity Manager reads your frontmost window's title to tell
which task you are focused on (e.g. watching YouTube vs reading an article in
one browser). Data never leaves this Mac.</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/PkgInfo" << 'PKG'
APPL????
PKG

# Strip quarantine-adjacent metadata that makes codesign complain.
xattr -cr "$APP" 2>/dev/null || true

# Prefer the stable self-signed dev identity (created once) so macOS TCC
# grants (Accessibility / Automation) SURVIVE rebuilds. Ad-hoc signatures
# change every build and silently void permissions each time.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'ProductivityManager Dev' | awk '{print $2}' | head -1)
if [ -n "${IDENTITY:-}" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with stable identity: ProductivityManager Dev"
else
    codesign --force --sign - "$APP"
    echo "WARNING: signed ad-hoc — permission grants will not survive rebuilds"
fi
echo "Built $APP"
