#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH=/private/tmp/whyfi-build
CLANG_CACHE_PATH=/private/tmp/whyfi-clang-cache
SWIFT_CACHE_PATH=/private/tmp/whyfi-swift-cache

VERSION=
BUILD=
FEED_URL=
DOWNLOAD_URL_PREFIX=
SIGN_IDENTITY=
NOTARY_PROFILE=
ED_KEY_FILE=
TEMP_KEY_FILE=
TEMP_NOTARY_DIR=

usage() {
    cat <<'USAGE'
Usage: scripts/release.sh --version VERSION --build BUILD --feed-url URL \
    --download-url-prefix URL --sign-identity IDENTITY \
    [--notary-profile PROFILE] [--ed-key-file PRIVATE_KEY_FILE]

The sign identity may be '-' for an ad-hoc signature.
Without --ed-key-file, Sparkle reads the EdDSA private key from the keychain.
USAGE
}

fail() {
    printf 'release.sh: %s\n' "$1" >&2
    exit 2
}

cleanup() {
    if [[ -n "$TEMP_KEY_FILE" && -f "$TEMP_KEY_FILE" ]]; then
        rm -f "$TEMP_KEY_FILE"
    fi
    if [[ -n "$TEMP_NOTARY_DIR" && -d "$TEMP_NOTARY_DIR" ]]; then
        rm -rf "$TEMP_NOTARY_DIR"
    fi
}
trap cleanup EXIT

while (($# > 0)); do
    case "$1" in
        --version|--build|--feed-url|--download-url-prefix|--sign-identity|--notary-profile|--ed-key-file)
            (($# >= 2)) || fail "missing value for $1"
            case "$1" in
                --version) VERSION="$2" ;;
                --build) BUILD="$2" ;;
                --feed-url) FEED_URL="$2" ;;
                --download-url-prefix) DOWNLOAD_URL_PREFIX="$2" ;;
                --sign-identity) SIGN_IDENTITY="$2" ;;
                --notary-profile) NOTARY_PROFILE="$2" ;;
                --ed-key-file) ED_KEY_FILE="$2" ;;
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
[[ -n "$DOWNLOAD_URL_PREFIX" ]] || fail "--download-url-prefix is required"
[[ -n "$SIGN_IDENTITY" ]] || fail "--sign-identity is required"

BIN_PATH="$(
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
    SWIFT_MODULECACHE_PATH="$SWIFT_CACHE_PATH" \
    swift build -c release --disable-sandbox --scratch-path "$SCRATCH_PATH" --show-bin-path
)"
SPARKLE_TOOLS="$SCRATCH_PATH/artifacts/sparkle/Sparkle/bin"
GENERATE_KEYS="$SPARKLE_TOOLS/generate_keys"
GENERATE_APPCAST="$SPARKLE_TOOLS/generate_appcast"

[[ -x "$GENERATE_KEYS" ]] || fail "resolved Sparkle generate_keys was not found"
[[ -x "$GENERATE_APPCAST" ]] || fail "resolved Sparkle generate_appcast was not found"

KEY_FILE_FOR_SIGNING=
if [[ -n "$ED_KEY_FILE" ]]; then
    if [[ "$ED_KEY_FILE" == "-" ]]; then
        TEMP_KEY_FILE="$(mktemp /private/tmp/whyfi-ed-key.XXXXXX)"
        chmod 600 "$TEMP_KEY_FILE"
        cat > "$TEMP_KEY_FILE"
        KEY_FILE_FOR_SIGNING="$TEMP_KEY_FILE"
    else
        [[ -r "$ED_KEY_FILE" ]] || fail "EdDSA key file is not readable: $ED_KEY_FILE"
        KEY_FILE_FOR_SIGNING="$ED_KEY_FILE"
    fi
fi

if [[ -n "$KEY_FILE_FOR_SIGNING" ]]; then
    PUBLIC_KEY="$(
        CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
        SWIFT_MODULECACHE_PATH="$SWIFT_CACHE_PATH" \
        swift "$ROOT_DIR/scripts/public-key-from-ed-key.swift" "$KEY_FILE_FOR_SIGNING"
    )"
else
    PUBLIC_KEY="$("$GENERATE_KEYS" -p | tr -d '\r\n')"
fi
[[ -n "$PUBLIC_KEY" ]] || fail "could not determine the Sparkle public key"

"$ROOT_DIR/scripts/build-app.sh" \
    --version "$VERSION" \
    --build "$BUILD" \
    --feed-url "$FEED_URL" \
    --ed-public-key "$PUBLIC_KEY" \
    --sign-identity "$SIGN_IDENTITY"

APP_DIR="$ROOT_DIR/dist/WhyFi.app"
RELEASE_DIR="$ROOT_DIR/dist/releases"
ZIP_PATH="$RELEASE_DIR/WhyFi-$VERSION.zip"
mkdir -p "$RELEASE_DIR"

if [[ -n "$NOTARY_PROFILE" ]]; then
    TEMP_NOTARY_DIR="$(mktemp -d /private/tmp/whyfi-notary.XXXXXX)"
    TEMP_NOTARY_ZIP="$TEMP_NOTARY_DIR/WhyFi-$VERSION.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$TEMP_NOTARY_ZIP"
    xcrun notarytool submit "$TEMP_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
fi

rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

APPCAST_ARGS=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
if [[ -n "$KEY_FILE_FOR_SIGNING" ]]; then
    APPCAST_ARGS+=(--ed-key-file "$KEY_FILE_FOR_SIGNING")
fi
"$GENERATE_APPCAST" "${APPCAST_ARGS[@]}" "$RELEASE_DIR"

printf 'Released %s\n' "$RELEASE_DIR"
