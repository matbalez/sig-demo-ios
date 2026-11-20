# Building Sig Demo for iPhone

Run the commands from the repository root on an Apple Silicon Mac. Use the Xcode version in [upstream.lock.json](upstream.lock.json), its iPhoneOS SDK, Rust 1.95.0, Python 3.12 or newer, Node.js, Ruby with RubyGems, Git, CMake, protobuf's `protoc`, `just`, and `rg`. The local-model build targets iOS 17 or later. Allow disk space for Xcode, Rust objects, the free Mesh XCFramework and a 1.10 GB model download.

## Configure a separate demo service

Your service operator must supply an invite-enabled Signal-compatible demo server and its public client configuration. That configuration includes the private deployment’s public CA certificate, Signal trust roots, public parameters and HTTPS service URLs. The URLs must share the same loopback TLS origin. The optional `sigDemoRelay` selects the actual relay host and port reached by the phone. A local install uses isolated app and Keychain groups. Remote inference and Brave require a demo account with the appropriate provider access.

1. Put the public configuration in `.sig-demo/public-client.json`. The validator in [public-client-config.mjs](public-client-config.mjs) defines the accepted fields. The [configuration tests](public-client-config.test.mjs) show their shape with synthetic data.
2. Set [ApprovedRelay.txt](SigDemoKit/Sources/SigDemoKit/Resources/ApprovedRelay.txt) to your service's relay hostname or IP address, one host on one line. It defaults to `localhost`. Swift and the configuration generator both read this build-time allowlist entry. The port is supplied in the public JSON.
3. Use an invite issued by that same server to create a demo identity on your iPhone. Keep invite codes, wallet material, API keys, provisioning profiles and signing credentials out of the public configuration and source tree.

## Prepare the source and dependencies

```sh
rustup toolchain install 1.95.0
rustup target add --toolchain 1.95.0 aarch64-apple-ios
ios=sig-demo/ios
checkout="$PWD/.sig-demo/ios/chatgpt/Signal-iOS"
node "$ios/prepare-upstream.mjs" --config .sig-demo/public-client.json --checkout "$checkout"
sh "$ios/fetch-dependencies.sh" "$checkout"
python3 "$ios/libsignal/prepare.py"
cargo +1.95.0 fetch --locked --manifest-path .sig-demo/ios/libsignal/Cargo.toml
CARGO_PROFILE_RELEASE_OPT_LEVEL=3 CARGO_PROFILE_RELEASE_LTO=thin CARGO_PROFILE_RELEASE_DEBUG=0 \
  bash "$ios/libsignal/build.sh" aarch64-apple-ios release
python3 "$ios/libsignal/overlay-pod.py" --pod "$checkout/Pods/LibSignalClient" --target aarch64-apple-ios --profile release
sh "$ios/build-native-agent.sh" --device-only
python3 "$ios/Mesh/prepare.py"
PAID_MESH_TARGETS=aarch64-apple-ios sh "$ios/PaidMesh/build.sh"
python3 "$ios/LocalModel/prepare.py" --root .sig-demo/ios/local-model-work --models-only
```

The release project rebuilds its Ruby environment from the pinned gem archives. Populate that cache if it is empty. In a shell at the repository root:

```sh
mkdir -p .sig-demo/ios/ruby-gems/cache
(
  cd .sig-demo/ios/ruby-gems/cache
  for spec in CFPropertyList:3.0.8 atomos:0.1.3 base64:0.3.0 claide:1.1.0 colored2:3.1.2 nanaimo:0.4.0 nkf:0.3.0 rexml:3.4.4 xcodeproj:1.28.1; do
    gem fetch "${spec%:*}" --version "${spec#*:}" --platform ruby
  done
)
```

## Archive and sign

```sh
bash sig-demo/ios/build-device.sh --build-number 1 \
  --checkout "$checkout" \
  --libsignal "$PWD/.sig-demo/ios/libsignal-build/aarch64-apple-ios/release/libsignal_ffi.a" \
  --local-models "$PWD/.sig-demo/ios/local-model-work/Models"
```

By default this produces an unsigned archive. For a signed archive, use bundle identifiers and app groups available to your Apple Developer team, configure the app and its two extensions, and pass `--signed --team TEAM_ID`. The bundle-prefix isolation checks in the pin, patches, public configuration and release tooling must agree when you choose new identifiers. For distributions bundling corresponding source, the archive script accepts `--source-archive` and `--source-sha256`.

## Run configuration checks

```sh
node --test sig-demo/ios/public-client-config.test.mjs
swift test --package-path sig-demo/ios/SigDemoKit
```

The [native-agent build](build-native-agent.sh), [libsignal recipe](libsignal/README.md), [local-model pins](LocalModel/source.lock.json) and [paid client build](PaidMesh/build.sh) contain the dependency versions and platform details.
