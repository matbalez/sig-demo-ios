# Native public Mesh inference

`SigDemoMesh` adds an optional **free public Mesh** route to the on-device Sig
agent. ChatGPT remains a separate selectable provider. This package uses Mesh's
released, in-process thin client: it starts no local model server, downloads no
models, opens no wallet, and executes no Mesh or Lexe subprocess. It has no
inference-provider fallback.

## Pinned dependency

The latest published Mesh release checked on 2026-10-23 is **v0.78.1**. Use the
matching Swift source and original XCFramework together:

| Input                   | Pin                                                                |
| ----------------------- | ------------------------------------------------------------------ |
| Source commit           | `bc215ce5b880e21c6c3840b8574ab64f83278821`                         |
| Source archive SHA-256  | `f357109751e0fb67294c8e76dfdd5d7932a79a939dda9f7780b6046079a041ad` |
| XCFramework ZIP         | `MeshLLMFFI.xcframework.zip`, 725,689,894 bytes                    |
| XCFramework ZIP SHA-256 | `7014d92e720065149451de25ef72602ce4fb45c8df7504acf07c18a77e8aedd8` |
| Platforms               | arm64 iOS device, simulator, Mac Catalyst, macOS                   |
| Minimum iOS deployment  | 16.0                                                               |

Run this before resolving the local package:

```sh
python3 sig-demo/ios/Mesh/prepare.py
```

The script verifies both downloaded archives against `source.lock.json` and
prepares `.sig-demo/ios/mesh-sdk-v0.78.1`. Downloads and extracted dependencies
stay ignored. The source archive can reuse the existing verified research
download. A separate derived framework cache is linked into the SDK package.
The upstream source, generated Swift, C header, and static binary are unchanged.

Upstream omits `CFBundleExecutable` and `CFBundleShortVersionString` from all four
framework wrapper plists. The preparation script makes an APFS clone (or ordinary
copy) in a versioned metadata cache and adds `CFBundleExecutable=MeshLLMFFI` and
`CFBundleShortVersionString=0.78.1` before Xcode processing and signing. It retains
upstream's framework identifier and `CFBundleVersion=1`. Every other file is
compared byte-for-byte by SHA-256, and symlinks/layout are checked against the
original extraction. The XCFramework root plist is unchanged. This metadata-only
patch is recorded in `source.lock.json`. Existing version 1 metadata cache links
are verified against the pinned original before moving to the new cache.

The framework contains a static archive. During app embedding, Xcode removes
that archive from the resource/privacy wrapper and creates its normal codeless
framework stub. Correct executable metadata lets strict staging verify that
Xcode-produced wrapper while the actual Mesh code remains linked into the app.

For the iOS 17 local-model app, `stage-device.py` makes a build-local device
package and sets the wrapper's `MinimumOSVersion` to the deployment target
Xcode uses to link the generated stub. The script verifies the original
arm64 static archive against `deviceStaticArchiveSHA256` in the lockfile.
The cached SDK and its original iOS 16 minimum remain available to other
builds. The archive inspector compares each executable’s deployment load command
with its own bundle plist and the app’s deployment floor.

The package supplies `Network.framework`, `Security.framework`, `resolv`, and
macOS `IOKit.framework` in addition to upstream's framework dependencies.
Normal linker dead stripping is required when linking Mesh and the Sig Rust
agent into one executable: without it their different Rust standard libraries
produce a duplicate `rust_eh_personality` symbol. Use
`DEAD_CODE_STRIPPING=YES` in Xcode. No duplicate-symbol suppression, symbol
renaming, or binary repackaging is used.
The stronger constructor/session native smoke links successfully but still
reports an unused duplicate-personality warning; it is retained in the evidence
logs. This is not a warning-free native link qualification.

Primary references: [release](https://github.com/Mesh-LLM/mesh-llm/releases/tag/v0.78.1),
[release assets](https://github.com/Mesh-LLM/mesh-llm/releases/expanded_assets/v0.78.1),
[package manifest](https://github.com/Mesh-LLM/mesh-llm/blob/v0.78.1/Package.swift).

## Transport and lifecycle

`MeshSDKPublicTransport` implements `MeshInferenceTransport` using the public
generated `MeshClientHandle`. This is the same thin engine wrapped by upstream
`Client` and `Client.connectPublic`; direct access gives our adapter explicit
native request IDs and terminal callback acknowledgements.

The app supplies a separately scoped owner identity. The adapter discovers
public Nostr listings, selects a nonfull listing advertising the requested exact
model, and constructs its client from that listing's public join token. If no
model was selected yet, it returns that listing's advertised model catalog.
Catalog entries are deduplicated and validated; they establish discovery, not
live availability or tool-use capability. A missing selected model fails.
Automatic selection preserves the publisher's advertised order. The current
publisher puts its own hosted models before models learned from peers, so
alphabetically sorting that catalog before choosing a model can select a model
the contacted bootstrap cannot serve. This preference is not an availability
guarantee; public models and capacity can change.
The thin client does not expose an individual peer chooser or an
`x-mesh-target` header, so the app does not present a node-pinning control.

Every raw Chat Completions request retains its tools, tool choice, and other
JSON fields while the adapter overwrites these two fields:

```json
{ "stream": true, "mesh_payment": { "mode": "free_only" } }
```

Upstream public listings contain no pricing metadata. Discovery therefore cannot
positively filter all priced sellers before trying inference. The thin client
has no payment exchange or wallet; priced sellers reject ordinary inference
with HTTP 402. The adapter maps that result to `paymentRequired`, creates no
payment, and does not switch providers. Public availability can change between
discovery and a request.

The response preserves HTTP status/content type and raw SSE, including tool-call
argument deltas, usage, and `[DONE]`. Before queueing, the native callback rejects
raw/data fields larger than 1 MiB and limits their cumulative UTF-8 storage to
16 MiB. Non-stream requests are rejected by the loopback bridge: the released
SDK's non-stream request and HTTP model-list methods have no cancellable request
ID or response-read deadline, so this package does not call them.

Cancellation explicitly signals each native request ID. `stop()` cancels streams,
disconnects the client, and waits for their Rust terminal callbacks. Upstream
emits those callbacks after its direct QUIC request has closed its endpoint.
Startup generation checks dispose late clients after a background/provider
change. Public discovery uses an upstream five-second fetch timeout; the FFI
lookup itself is not Swift-cancellable, so teardown drains that lookup before
returning. An upstream `MESH_CLIENT_API_BASE` override is refused to prevent
changing the app's transport implicitly. The app runs this route only while
foreground and keeps its local agent, chat context, and search tool on-device.

Primary implementation references:
[public discovery](https://github.com/Mesh-LLM/mesh-llm/blob/v0.78.1/crates/mesh-llm-api-client/src/discover.rs),
[publisher model order](https://github.com/Mesh-LLM/mesh-llm/blob/c7d5157384e072ad82c58916f4d3bcca50894f25/mesh/crates/mesh-llm-host-runtime/src/network/nostr/publish.rs#L560-L573),
[thin client](https://github.com/Mesh-LLM/mesh-llm/blob/v0.78.1/crates/mesh-client/src/client/builder.rs),
[raw SSE and cancellation](https://github.com/Mesh-LLM/mesh-llm/blob/v0.78.1/crates/mesh-client/src/client/builder/openai_stream.rs),
[priced-seller rejection](https://github.com/Mesh-LLM/mesh-llm/blob/v0.78.1/crates/mesh-llm-host-runtime/src/network/openai/response/routing.rs).
