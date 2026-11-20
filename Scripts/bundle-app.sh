#!/usr/bin/env bash
set -euo pipefail

CONFIG="release"
OUTPUT_DIR="dist"

usage() {
    cat <<'EOF'
Usage: Scripts/bundle-app.sh [OPTIONS]

Build and bundle Vermouth.app (non-sandboxed, ad-hoc signed) using SwiftPM without Xcode.

Options:
  --configuration <debug|release>   Build configuration (default: release)
  --output <dir>                    Output directory for Vermouth.app (default: dist)
  -h, --help                        Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration|-c)
            if [[ $# -lt 2 ]]; then
                echo "error: --configuration requires an argument (debug|release)" >&2
                exit 1
            fi
            CONFIG="$2"
            shift 2
            ;;
        --output|-o)
            if [[ $# -lt 2 ]]; then
                echo "error: --output requires a directory argument" >&2
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$CONFIG" in
    debug|release)
        ;;
    *)
        echo "error: invalid configuration '$CONFIG' (expected 'debug' or 'release')" >&2
        exit 1
        ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: Scripts/bundle-app.sh must be executed on macOS (Darwin)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_BUNDLE="$OUTPUT_DIR/Vermouth.app"

echo "==> Building VermouthApp and vermouth ($CONFIG)..."
cd "$REPO_ROOT"
swift build -c "$CONFIG" --product VermouthApp
swift build -c "$CONFIG" --product vermouth

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
echo "==> SwiftPM bin path: $BIN_PATH"

APP_BINARY="$BIN_PATH/VermouthApp"
CLI_BINARY="$BIN_PATH/vermouth"
CORE_RESOURCE_BUNDLE="$BIN_PATH/Vermouth_VermouthCore.bundle"

if [[ ! -x "$APP_BINARY" ]]; then
    echo "error: built VermouthApp binary not found at $APP_BINARY" >&2
    exit 1
fi

if [[ ! -x "$CLI_BINARY" ]]; then
    echo "error: built vermouth CLI binary not found at $CLI_BINARY" >&2
    exit 1
fi

if [[ ! -d "$CORE_RESOURCE_BUNDLE" ]]; then
    echo "error: expected Vermouth_VermouthCore.bundle at $CORE_RESOURCE_BUNDLE" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Never place 'vermouth' alongside 'Vermouth' in Contents/MacOS/: on case-insensitive APFS
# that silently overwrites the GUI binary. Name the bundled companion CLI 'vermouth-cli'.
cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/Vermouth"
cp "$CLI_BINARY" "$APP_BUNDLE/Contents/MacOS/vermouth-cli"
chmod +x "$APP_BUNDLE/Contents/MacOS/Vermouth" "$APP_BUNDLE/Contents/MacOS/vermouth-cli"

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Explicitly copy only Vermouth_VermouthCore.bundle (never wildcard *Tests.bundle).
echo "==> Copying Vermouth_VermouthCore.bundle into Contents/Resources/"
cp -R "$CORE_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/Vermouth_VermouthCore.bundle"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Vermouth</string>
    <key>CFBundleExecutable</key>
    <string>Vermouth</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.goudu666.vermouth</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Vermouth</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> Validating Info.plist..."
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

# Remove any stray extended attributes that could interfere with codesign.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "==> Ad-hoc code signing $APP_BUNDLE..."
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/vermouth-cli"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/Vermouth"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Running bundle integrity self-checks..."
if [[ ! -x "$APP_BUNDLE/Contents/MacOS/Vermouth" ]] || [[ ! -x "$APP_BUNDLE/Contents/MacOS/vermouth-cli" ]]; then
    echo "error: expected executable binaries Contents/MacOS/Vermouth and Contents/MacOS/vermouth-cli" >&2
    exit 1
fi

APP_INODE="$(stat -f %i "$APP_BUNDLE/Contents/MacOS/Vermouth")"
CLI_INODE="$(stat -f %i "$APP_BUNDLE/Contents/MacOS/vermouth-cli")"
if [[ "$APP_INODE" == "$CLI_INODE" ]]; then
    echo "error: Contents/MacOS/Vermouth and Contents/MacOS/vermouth-cli share inode $APP_INODE" >&2
    exit 1
fi

if ! otool -L "$APP_BUNDLE/Contents/MacOS/Vermouth" | grep -qE "SwiftUI|AppKit"; then
    echo "error: Contents/MacOS/Vermouth does not link SwiftUI or AppKit (expected GUI binary)" >&2
    otool -L "$APP_BUNDLE/Contents/MacOS/Vermouth" >&2
    exit 1
fi

if [[ ! -d "$APP_BUNDLE/Contents/Resources/Vermouth_VermouthCore.bundle" ]]; then
    echo "error: expected Vermouth_VermouthCore.bundle inside $APP_BUNDLE/Contents/Resources/" >&2
    exit 1
fi

if [[ -n "$(find "$APP_BUNDLE" -maxdepth 1 -name '*.bundle')" ]]; then
    echo "error: resource bundle must not exist at $APP_BUNDLE root" >&2
    exit 1
fi

echo "==> Successfully bundled $APP_BUNDLE (Vermouth inode=$APP_INODE, vermouth-cli inode=$CLI_INODE)"
