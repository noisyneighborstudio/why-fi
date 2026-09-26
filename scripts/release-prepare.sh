#!/bin/bash
# semantic-release prepare: build the signed (and, with notary credentials, notarized) app
# for the version semantic-release computed, and leave WhyFi-<version>.zip in the checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: release-prepare.sh <version>}
# CFBundleVersion drives Sparkle's ordering, so it must only ever increase.
build=${WHYFI_BUILD_NUMBER:?WHYFI_BUILD_NUMBER required (CI: the workflow run number)}
[[ $build =~ ^[0-9]+$ ]] || { echo "✗ WHYFI_BUILD_NUMBER must be a positive integer: $build" >&2; exit 1; }
: "${WHYFI_SIGN_IDENTITY:?WHYFI_SIGN_IDENTITY required}"
source ./updates.env

scripts/build-app.sh --version "$version" --build "$build" --feed-url "$WHYFI_FEED_URL" \
    --ed-public-key "$SPARKLE_PUBLIC_KEY" --sign-identity "$WHYFI_SIGN_IDENTITY"

app=dist/WhyFi.app
codesign --verify --deep --strict --verbose=2 "$app"
# Every @rpath dependency must resolve inside the bundle, or dyld kills the app before main().
for dep in $(otool -L "$app/Contents/MacOS/netmon-menubar" | awk '/@rpath\//{print $1}'); do
    [[ -e "$app/Contents/Frameworks/${dep#@rpath/}" ]] || { echo "✗ unresolvable dependency: $dep" >&2; exit 1; }
done

if [[ -n ${NOTARY_KEY:-} ]]; then
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID required with NOTARY_KEY}" "${NOTARY_KEY_ISSUER:?NOTARY_KEY_ISSUER required with NOTARY_KEY}"
    notary="${RUNNER_TEMP:-$TMPDIR}/notary.p8"
    (umask 077; printf '%s' "$NOTARY_KEY" > "$notary")
    ditto -c -k --keepParent "$app" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --key "$notary" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER" --wait
    rm -f "$notary" dist/notarize.zip
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
else
    echo "::warning::NOTARY_KEY_P8 is not set; publishing signed but un-notarized (browser downloads will be blocked by Gatekeeper)"
fi

rm -f WhyFi-*.zip
ditto -c -k --keepParent "$app" "WhyFi-$version.zip"
echo "✓ Prepared $version (build $build)"
