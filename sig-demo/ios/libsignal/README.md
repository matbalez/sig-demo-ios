# Private iOS libsignal transport

This patch adds a normal Swift/C/Rust constructor to the exact `LibSignalClient`
version used by Signal-iOS 8.32.0.1910. It connects the native Signal chat client
to the app-owned localhost relay using the supplied private DER CA. It never
selects Signal production or staging as the environment.

The source is pinned to libsignal v0.103.1, commit
`e8cc2dddd578859b4a029c9c94670b24ce2b616a`. `source.lock.json` records the
reviewed patch and resulting file hashes. Upstream sources and native artifacts
live in the ignored `.sig-demo/ios/` directory.

```sh
python3 sig-demo/ios/libsignal/prepare.py
sig-demo/ios/libsignal/build.sh aarch64-apple-ios-sim debug
sig-demo/ios/libsignal/build.sh aarch64-apple-ios debug
python3 sig-demo/ios/libsignal/overlay-pod.py \
  --pod .sig-demo/ios/chatgpt/Signal-iOS/Pods/LibSignalClient
```

Prerequisites are Xcode with the requested iOS SDK, Rust 1.95.0 with the requested
Apple target installed, CMake, and `protoc`. The build script can locate the
already-cached public vendored `protoc`. Cargo builds are locked and offline;
fetch public dependencies once with `cargo +1.95.0 fetch --locked` from the
prepared source if necessary. The pinned source requires Rust 1.93.1 or newer.

For a distribution build, use a separate source checkout and build directory
outside any cloud-synced folder, verify the same pin and patch, then select the
production Cargo profile explicitly. The defaults retain the faster development
profile used by the simulator build.

```sh
export SIG_DEMO_LIBSIGNAL_SOURCE=/private/tmp/your-verified-libsignal-source
export SIG_DEMO_LIBSIGNAL_BUILD_DIR=/private/tmp/your-libsignal-release-build
python3 sig-demo/ios/libsignal/prepare.py --source "$SIG_DEMO_LIBSIGNAL_SOURCE"
CARGO_PROFILE_RELEASE_OPT_LEVEL=3 \
CARGO_PROFILE_RELEASE_LTO=thin \
CARGO_PROFILE_RELEASE_DEBUG=0 \
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
  sig-demo/ios/libsignal/build.sh aarch64-apple-ios release
sig-demo/ios/libsignal/smoke-link.sh \
  "$SIG_DEMO_LIBSIGNAL_BUILD_DIR/aarch64-apple-ios/release/libsignal_ffi.a" \
  aarch64-apple-ios
```

The last command links a device Mach-O executable against the real C ABI. It
does not execute it on an iPhone, sign an app, or prove device connectivity.

Pass the complete artifact path printed by the overlay tool to `xcodebuild` as
`LIBSIGNAL_FFI_LIB_TO_LINK=...`, preserve inherited linker flags, and include
`-lc++ -lresolv` for the native runtime. The overlay selects the Pod's local source mode;
the native archive is built by the explicit command above. Simulator debug
builds include upstream bridge testing exports required by the Pod's simulator
Swift sources; device builds omit those exports.

```swift
let net = try Net(
    localDemoChatPort: 14_443,
    rootCertificateDer: privateCaDer,
    userAgent: userAgent,
    buildVariant: .beta
)
```

The custom environment uses IPv4 `127.0.0.1`, TLS hostname `localhost`, HTTP/2
extended CONNECT, and only the supplied CA. HTTP/2 is required by the existing
private server's `/v1/websocket/` transport. The private constructor uses a
static-only resolver: it installs neither system DNS nor Cloudflare DoH.
Unsupported CDSI, SVR2, and SVR-B routes terminate on localhost port 1. There are
no domain-fronting reflectors or proxy fallback routes. Swift rejects proxy
configuration and unsupported CDSI, key-transparency, and backup operations;
backup-chain creation has a precondition because its upstream API is
nonthrowing. The local environment's distinct enum marker also fails official
Rust environment conversion rather than choosing a public environment.

`setRemoteConfig`, `clearProxy`, and network-change handling retain the private
environment and resolver. The relay must start before requesting a chat
connection. This transport change does not register an account or send an
inference request.
