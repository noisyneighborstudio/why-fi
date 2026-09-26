# nofi

nofi is a macOS 14+ menu bar network monitor. The executable target is `netmon-menubar`; the shared monitoring code lives in `NetmonCore`.

## Releasing

nofi updates itself with Sparkle 2. Every push to `main` runs `.github/workflows/release.yml`:
`swift test`, then semantic-release. semantic-release reads conventional commits (`feat:` minor,
`fix:` patch, `!` or `BREAKING CHANGE:` major), tags the repo, and creates the GitHub release. A
push with no releasable commits publishes nothing.

- **Version.** `CFBundleShortVersionString` is semantic-release's version. `CFBundleVersion` is the
  workflow run number, which only increases; Sparkle orders updates by it.
- **Build.** `scripts/release-prepare.sh` runs `scripts/build-app.sh` with the Developer ID
  identity, checks the signature and every framework dependency, notarizes and staples when the
  notary secrets exist, and zips `nofi-<version>.zip`.
- **Publish.** `scripts/publish-appcast.sh` signs the zip with the Sparkle EdDSA key, checks the
  signature against the `SUPublicEDKey` baked into the app, uploads the zip to the release, waits
  until GitHub serves it, then commits `appcast.xml` to the `appcasts` branch.

`updates.env` is the one place hosting is configured. The feed is
`https://raw.githubusercontent.com/noisyneighborstudio/nofi/appcasts/appcast.xml`, and both it
and the release zips must be readable without credentials. The Sparkle key is the login-keychain
account `whyfi`, the app's former name (`generate_keys --account whyfi`); its public half is `SPARKLE_PUBLIC_KEY` in
`updates.env`.

### Repo secrets

| Secret | What |
| ------ | ---- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID Application certificate and private key as .p12, base64 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the .p12 export password |
| `BUILD_KEYCHAIN_PASSWORD` | any random string (password of the throwaway CI keychain) |
| `DEVELOPER_ID_APPLICATION` | the identity name, e.g. `Developer ID Application: Name (TEAMID)` |
| `SPARKLE_PRIVATE_KEY` | `generate_keys --account whyfi -x <file>`; must match `SPARKLE_PUBLIC_KEY` |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` | optional App Store Connect API key; without them builds are signed but not notarized |

Key material stays in runner-temporary files or stdin and is removed in an `always()` step.

### Widgets

`nofi-widgets` is a WidgetKit extension that `scripts/build-app.sh` packages as
`Contents/PlugIns/NofiWidgets.appex`. The app writes a snapshot of the last five minutes to the
app group `P8ZBH5878Q.studio.noisyneighbor.nofi` and asks WidgetKit to reload on state changes
(at most once a minute) and otherwise every five minutes. The widget shows "No recent data" ten
minutes after the last snapshot.

The app group needs the Developer ID provisioning profiles in `Resources/profiles` (bundle IDs
`studio.noisyneighbor.nofi` and `.widgets`, App Groups capability, certificate
`Developer ID Application: Seth Webster (P8ZBH5878Q)`). Without them macOS treats the entitlement
as unapproved and WidgetKit ignores the app. Ad-hoc builds skip the group, so their widget shows
"No recent data". Profiles tie to the signing certificate, so regenerate them when it's renewed.

### Local builds

`scripts/build-app.sh --version V --build N --feed-url URL --ed-public-key KEY --sign-identity ID`
builds `dist/nofi.app`. Pass `-` as the identity for an ad-hoc build.
