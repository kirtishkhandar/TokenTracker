#!/bin/bash
set -euo pipefail

# TokenTracker build script
# Builds a macOS .app bundle from Swift sources without an Xcode project.
# Requires: Xcode command line tools (swiftc)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="TokenTracker"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "=== Building $APP_NAME ==="

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Find all Swift source files
SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$SCRIPT_DIR/Sources" -name "*.swift" -type f)

echo "Compiling ${#SWIFT_FILES[@]} Swift files..."

# Compile
swiftc \
    -o "$MACOS/$APP_NAME" \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -framework SwiftUI \
    -framework AppKit \
    -import-objc-header /dev/null \
    "${SWIFT_FILES[@]}" \
    2>&1

# If on Intel Mac, rebuild for x86_64
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    echo "Detected Intel Mac, recompiling for x86_64..."
    swiftc \
        -o "$MACOS/$APP_NAME" \
        -target x86_64-apple-macos14.0 \
        -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
        -framework SwiftUI \
        -framework AppKit \
        -import-objc-header /dev/null \
        "${SWIFT_FILES[@]}" \
        2>&1
fi

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

# Copy proxy server script
cp "$SCRIPT_DIR/proxy/proxy_server.py" "$RESOURCES/proxy_server.py"
chmod +x "$RESOURCES/proxy_server.py"

# Sign ad-hoc (needed for network entitlements)
codesign --force --sign - \
    --entitlements "$SCRIPT_DIR/TokenTracker.entitlements" \
    "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "=== Build complete ==="
echo "App bundle: $APP_BUNDLE"
echo ""
echo "To install, run:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
echo ""
echo "To run directly:"
echo "  open \"$APP_BUNDLE\""
