The device release uses the same private account and deployment binding as the
simulator. It bundles the native app, notification extension and share extension
under `dev.matbalez.sig-demo.ios.signal`. The two private App Groups and private
shared Keychain group must be enabled for all three bundle identifiers on the
selected Apple Developer team.

`build-device.sh` generates a separate Xcode project, Info.plists and compiler
outputs under an owned `/private/tmp/sig-demo-ios-device-build-*` directory. It
preserves the prepared source project and simulator outputs. Release entitlements
retain Signal's enhanced security protections, complete data protection, private
App Groups and private Keychain. The demo has no APNs integration, so this release
does not request the unused upstream APNs, iCloud, carrier, Wi-Fi Aware or
restricted Signal service entitlements.

The temporary project also stages unchanged upstream asset catalogs from the
locked Git commit into that private directory. It refuses local catalog changes
and verifies each staged file against its Git blob, preserving the original
checkout while avoiding FileProvider read stalls during asset compilation.

The release stages a separate PaidMesh package/framework copy with the required
`C617.1` declaration for wallet, ledger and profile file metadata in its own app
container. Its packaging receipt records unchanged qualified binary hashes
before normal Xcode signing. Original SDK artifacts and their pin receipts are
preserved, and WebRTC's existing privacy manifest stays bundled.

Build the private libsignal production archive for `aarch64-apple-ios` using the
[production profile recipe](../libsignal/README.md), then pass its verified path
explicitly:

```sh
bash sig-demo/ios/build-device.sh --version 0.1.0 --build-number 1 \
  --libsignal /absolute/path/to/aarch64-apple-ios/release/libsignal_ffi.a --check
bash sig-demo/ios/build-device.sh --version 0.1.0 --build-number 1 \
  --libsignal /absolute/path/to/aarch64-apple-ios/release/libsignal_ffi.a \
  --source-archive /absolute/path/SigDemoSource.tar.gz \
  --source-sha256 CORRESPONDING_SOURCE_SHA256
```

The final release bundles the exact compressed corresponding source as
`SigDemoSource.tar.gz`. Supply both source options with its lowercase SHA256.
The temporary project copies that resource, records the hash in generated
metadata, and validates the bundled bytes after archiving and exporting. About
can share this local file. The archive excludes itself; when rebuilding, the
delivered source archive can be supplied again as this external resource.
An archive without the source options is useful for compilation checks, but the
export helper rejects it.

The default produces an unsigned device validation archive. It cannot be
installed or uploaded. Once the developer team is available, repeat with
`--signed --team TEAM_ID`; add `--allow-provisioning-updates` only when creating
or updating that team's profiles is intended. The export helper can also ask
Xcode to automatically sign an unsigned archive when supported by the available
team signing assets. It verifies the signed IPA afterward. Export remains local:

```sh
bash sig-demo/ios/export-device.sh --team TEAM_ID
```

Neither helper uploads. App Store Connect metadata, export compliance, provider
data disclosures, signing access, actual iPhone testing and TestFlight review
remain separate release checks. iOS 16 is the supported deployment minimum;
the installed Xcode 26.6/iOS 26.5 SDK meets Apple's current
[SDK upload minimum](https://developer.apple.com/news/?id=ueeok6yw).
Friends outside the App Store Connect team use external TestFlight testing,
whose first build requires
[TestFlight App Review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/).

Generated release Info.plists omit the inherited
`ITSAppUsesNonExemptEncryption` declaration so the owner can complete App Store
Connect's export-compliance questions for this modified app. Omission does not
claim an exemption, and no Apple compliance code is supplied before approval.
A successful local archive does not establish App Store acceptance or physical
device runtime parity.
