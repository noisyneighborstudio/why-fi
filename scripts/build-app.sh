#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH=/private/tmp/nofi-build
CLANG_CACHE_PATH=/private/tmp/nofi-clang-cache
SWIFT_CACHE_PATH=/private/tmp/nofi-swift-cache
APP_DIR="$ROOT_DIR/dist/nofi.app"

VERSION=
BUILD=
FEED_URL=
ED_PUBLIC_KEY=
SIGN_IDENTITY=

usage() {
    cat <<'USAGE'
Usage: scripts/build-app.sh --version VERSION --build BUILD --feed-url URL \
    --ed-public-key KEY --sign-identity IDENTITY

The sign identity may be '-' for an ad-hoc signature.
USAGE
}

fail() {
    printf 'build-app.sh: %s\n' "$1" >&2
    exit 2
}

while (($# > 0)); do
    case "$1" in
        --version|--build|--feed-url|--ed-public-key|--sign-identity)
            (($# >= 2)) || fail "missing value for $1"
            case "$1" in
                --version) VERSION="$2" ;;
                --build) BUILD="$2" ;;
                --feed-url) FEED_URL="$2" ;;
                --ed-public-key) ED_PUBLIC_KEY="$2" ;;
                --sign-identity) SIGN_IDENTITY="$2" ;;
            esac
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n "$VERSION" ]] || fail "--version is required"
[[ -n "$BUILD" ]] || fail "--build is required"
[[ -n "$FEED_URL" ]] || fail "--feed-url is required"
[[ -n "$ED_PUBLIC_KEY" ]] || fail "--ed-public-key is required"
[[ -n "$SIGN_IDENTITY" ]] || fail "--sign-identity is required"

CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
SWIFT_MODULECACHE_PATH="$SWIFT_CACHE_PATH" \
swift build -c release --disable-sandbox --scratch-path "$SCRATCH_PATH"

BIN_PATH="$(
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
    SWIFT_MODULECACHE_PATH="$SWIFT_CACHE_PATH" \
    swift build -c release --disable-sandbox --scratch-path "$SCRATCH_PATH" --show-bin-path
)"
APP_EXECUTABLE="$BIN_PATH/netmon-menubar"
WIDGET_EXECUTABLE="$BIN_PATH/nofi-widgets"
SPARKLE_SOURCE="$BIN_PATH/Sparkle.framework"

[[ -x "$APP_EXECUTABLE" ]] || fail "release executable was not produced at $APP_EXECUTABLE"
[[ -d "$SPARKLE_SOURCE" ]] || fail "Sparkle.framework was not produced at $SPARKLE_SOURCE"
[[ -x "$WIDGET_EXECUTABLE" ]] || fail "widget executable was not produced at $WIDGET_EXECUTABLE"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"

ENTITLEMENTS_DIR=""
cleanup() {
    if [[ -n "$ENTITLEMENTS_DIR" ]]; then
        rm -rf "$ENTITLEMENTS_DIR"
    fi
}
trap cleanup EXIT

/usr/bin/ditto "$APP_EXECUTABLE" "$APP_DIR/Contents/MacOS/netmon-menubar"
/usr/bin/ditto "$SPARKLE_SOURCE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

# App icon: a multi-resolution icns from the committed 1024 tile (scripts/make-icon.swift).
ICONSET="$(mktemp -d /private/tmp/nofi-icon.XXXXXX)/nofi.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$ROOT_DIR/Resources/nofi.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z $((size * 2)) $((size * 2)) "$ROOT_DIR/Resources/nofi.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/nofi.icns"
rm -rf "$(dirname "$ICONSET")"

INFO_PLIST="$APP_DIR/Contents/Info.plist"
cat > "$INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>studio.noisyneighbor.nofi</string>
    <key>CFBundleIconFile</key>
    <string>nofi</string>
    <key>CFBundleName</key>
    <string>nofi</string>
    <key>CFBundleDisplayName</key>
    <string>nofi</string>
    <key>CFBundleExecutable</key>
    <string>netmon-menubar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0</string>
    <key>CFBundleVersion</key>
    <string>0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>SUFeedURL</key>
    <string></string>
    <key>SUPublicEDKey</key>
    <string></string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD" "$INFO_PLIST"
/usr/bin/plutil -replace SUFeedURL -string "$FEED_URL" "$INFO_PLIST"
/usr/bin/plutil -replace SUPublicEDKey -string "$ED_PUBLIC_KEY" "$INFO_PLIST"

# Widget extension: WidgetKit loads it from PlugIns; its version must match the app's.
WIDGET_DIR="$APP_DIR/Contents/PlugIns/NofiWidgets.appex"
mkdir -p "$WIDGET_DIR/Contents/MacOS"
/usr/bin/ditto "$WIDGET_EXECUTABLE" "$WIDGET_DIR/Contents/MacOS/nofi-widgets"
cat > "$WIDGET_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>studio.noisyneighbor.nofi.widgets</string>
    <key>CFBundleName</key>
    <string>NofiWidgets</string>
    <key>CFBundleDisplayName</key>
    <string>nofi</string>
    <key>CFBundleExecutable</key>
    <string>nofi-widgets</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0</string>
    <key>CFBundleVersion</key>
    <string>0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$WIDGET_DIR/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD" "$WIDGET_DIR/Contents/Info.plist"

APP_EXECUTABLE="$APP_DIR/Contents/MacOS/netmon-menubar"
if ! /usr/bin/otool -l "$APP_EXECUTABLE" | /usr/bin/grep -Fq '@loader_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath '@loader_path/../Frameworks' "$APP_EXECUTABLE"
fi

SPARKLE_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
# Notarization requires a secure timestamp; ad-hoc signatures can't carry one.
TIMESTAMP=()
[[ "$SIGN_IDENTITY" == "-" ]] || TIMESTAMP=(--timestamp)
sign_code() {
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} "$1"
}

for service in Installer.xpc Downloader.xpc; do
    service_path="$SPARKLE_FRAMEWORK/Versions/B/XPCServices/$service"
    if [[ -d "$service_path" ]]; then
        if [[ "$service" == Downloader.xpc ]]; then
            /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --preserve-metadata=entitlements "$service_path"
        else
            sign_code "$service_path"
        fi
    fi
done

sign_code "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
sign_code "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
sign_code "$SPARKLE_FRAMEWORK"
# Entitlements. The widget runs sandboxed and reads the app's snapshot from a shared app group.
# The team-prefixed group needs a team: an ad-hoc signature has none, so ad-hoc builds skip it
# and their widget shows "No recent data". Ad-hoc hardened-runtime builds also need library
# validation off to load the ad-hoc-signed Sparkle.
ENTITLEMENTS_DIR="$(mktemp -d /private/tmp/nofi-entitlements.XXXXXX)"
entitlements() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
    for key in "$@"; do
        case "$key" in
            sandbox) printf '    <key>com.apple.security.app-sandbox</key>\n    <true/>\n' ;;
            group) printf '    <key>com.apple.security.application-groups</key>\n    <array>\n        <string>P8ZBH5878Q.studio.noisyneighbor.nofi</string>\n    </array>\n' ;;
            app-id=*) printf '    <key>com.apple.application-identifier</key>\n    <string>P8ZBH5878Q.%s</string>\n    <key>com.apple.developer.team-identifier</key>\n    <string>P8ZBH5878Q</string>\n' "${key#app-id=}" ;;
            library) printf '    <key>com.apple.security.cs.disable-library-validation</key>\n    <true/>\n' ;;
        esac
    done
    printf '</dict>\n</plist>\n'
}
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    entitlements sandbox > "$ENTITLEMENTS_DIR/widget.plist"
    entitlements library > "$ENTITLEMENTS_DIR/app.plist"
else
    # Developer ID profiles (Resources/profiles) authorize the app group; without them macOS
    # treats the entitlement as unapproved and WidgetKit ignores the app.
    entitlements sandbox group app-id=studio.noisyneighbor.nofi.widgets > "$ENTITLEMENTS_DIR/widget.plist"
    entitlements group app-id=studio.noisyneighbor.nofi > "$ENTITLEMENTS_DIR/app.plist"
    /usr/bin/ditto "$ROOT_DIR/Resources/profiles/studio.noisyneighbor.nofi.widgets.provisionprofile" "$WIDGET_DIR/Contents/embedded.provisionprofile"
    /usr/bin/ditto "$ROOT_DIR/Resources/profiles/studio.noisyneighbor.nofi.provisionprofile" "$APP_DIR/Contents/embedded.provisionprofile"
fi
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --entitlements "$ENTITLEMENTS_DIR/widget.plist" "$WIDGET_DIR"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --entitlements "$ENTITLEMENTS_DIR/app.plist" "$APP_DIR"

printf 'Built %s\n' "$APP_DIR"
