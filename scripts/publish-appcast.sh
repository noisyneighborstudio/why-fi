#!/bin/bash
# semantic-release publish: sign the zip with Sparkle's EdDSA key, upload it to the release,
# then push appcast.xml to the `appcasts` branch. Zip first, so the enclosure URL resolves
# before any client can read the appcast. Hosting lives in updates.env.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: publish-appcast.sh <version> <git-tag>}
tag=${2:?git tag required}
build=${NOFI_BUILD_NUMBER:?NOFI_BUILD_NUMBER required}
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY required}"
export GH_TOKEN=${NOFI_UPDATES_TOKEN:?NOFI_UPDATES_TOKEN required (write access to the updates repo)}
source ./updates.env

artifact="nofi-$version.zip"
[[ -f $artifact ]] || { echo "✗ missing $artifact; prepare did not run" >&2; exit 1; }

# Key via stdin: never on disk, never in argv.
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | /private/tmp/nofi-build/artifacts/sparkle/Sparkle/bin/sign_update -f - -p "$artifact")
[[ ${#signature} -eq 88 ]] || { echo "✗ unexpected signature from sign_update" >&2; exit 1; }
# A key that doesn't match the app's SUPublicEDKey makes every client reject the update.
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' dist/nofi.app/Contents/Info.plist)
swift scripts/verify-signature.swift "$public_key" "$signature" "$artifact" \
    || { echo "✗ SPARKLE_PRIVATE_KEY does not match SUPublicEDKey" >&2; exit 1; }

gh release upload "$tag" -R "$NOFI_UPDATES_REPO" --clobber "$artifact"
url="https://github.com/$NOFI_UPDATES_REPO/releases/download/$tag/$artifact"
# A fresh asset can answer 504 for minutes, and clients fetch it as soon as the appcast names
# it. Wait until it downloads whole three times running.
size=$(stat -f %z "$artifact") served=0 got=""
for _ in $(seq 1 60); do
    got=$(curl -sL -o /dev/null -w '%{http_code} %{size_download}' "$url" || true)
    if [[ $got == "200 $size" ]]; then
        served=$((served + 1)); (( served >= 3 )) && break
    else
        served=0
    fi
    sleep 20
done
(( served >= 3 )) || { echo "✗ $url still not downloadable after 20 min (last: $got)" >&2; exit 1; }

# Token as a header from the environment: out of argv, out of .git/config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
remote="https://github.com/$NOFI_UPDATES_REPO.git"
publication=$(mktemp -d)
if [[ -n $(git ls-remote --heads "$remote" appcasts) ]]; then
    git clone --quiet --depth 1 --branch appcasts "$remote" "$publication"
else
    git init --quiet -b appcasts "$publication"
fi
# Builds 1–2 shipped as WhyFi (studio.noisyneighbor.whyfi). Sparkle can't install an app with
# a different name and bundle ID over them, so they get a "Learn More…" link to the download instead.
first_nofi_build=3
published=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat > "$publication/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>nofi Updates</title><item>
<title>nofi $version</title><pubDate>$published</pubDate>
<link>https://github.com/$NOFI_UPDATES_REPO/releases/latest</link>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<sparkle:informationalUpdate><sparkle:belowVersion>$first_nofi_build</sparkle:belowVersion></sparkle:informationalUpdate>
<enclosure url="$url" sparkle:version="$build" sparkle:shortVersionString="$version" length="$size" type="application/octet-stream" sparkle:edSignature="$signature"/>
</item></channel></rss>
XML
git -C "$publication" add -- appcast.xml
git -C "$publication" -c user.name=github-actions -c user.email=github-actions@github.com \
    commit --quiet -m "Publish $version"
git -C "$publication" push --quiet "$remote" HEAD:appcasts
rm -rf "$publication"
echo "✓ Published $version → $NOFI_FEED_URL"
