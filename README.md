# WhyFi

WhyFi is a macOS 14+ menu bar network monitor. The executable target is `netmon-menubar`; the shared monitoring code lives in `NetmonCore`.

## Releasing

Generate the Sparkle EdDSA key pair once on the release machine. After the first release build resolves Sparkle, use the `generate_keys` binary from the required scratch path:

```sh
"/private/tmp/whyfi-build/artifacts/sparkle/Sparkle/bin/generate_keys"
```

The command stores the private key in the login keychain and prints the base64 public key. Pass that public value to `scripts/build-app.sh --ed-public-key` or let `scripts/release.sh` read it from the keychain. The public key goes in the app's `SUPublicEDKey` Info.plist entry. Keep the private key out of this repository. If a file is needed for an automated release, export it with `generate_keys -x` and pass it with `--ed-key-file` from a protected path.

Use a Developer ID Application signing identity for distribution, for example the identity selected by `security find-identity -v -p codesigning`. Pass the literal `-` to make an ad-hoc build for local testing. If the app will be notarized, create a `notarytool` keychain profile on the release machine and pass its name with `--notary-profile`.

Build a release and generate its signed appcast with:

```sh
scripts/release.sh \
  --version 1.0.0 \
  --build 1 \
  --feed-url https://updates.example.invalid/whyfi/appcast.xml \
  --download-url-prefix https://updates.example.invalid/whyfi/ \
  --sign-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile whyfi-notary
```

The script writes `dist/WhyFi.app`, `dist/releases/WhyFi-VERSION.zip`, and `dist/releases/appcast.xml`. The appcast URL and every download URL must be reachable by users without interactive authentication. The GitHub repository is private, so its release assets cannot be used as a Sparkle feed unless the app can authenticate to GitHub.
