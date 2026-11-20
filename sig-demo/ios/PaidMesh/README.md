# Native paid Mesh

This package adds a separate, client-only Mesh payments-v3 runtime beside the
verified free `SigDemoMesh` SDK. The paid runtime embeds the Mesh host and Lexe
wallet libraries in the app process. It does not launch a wallet executable,
load a model, sell inference, or receive inference payments. Creating a wallet
funding invoice is an explicit local wallet action.

The Mesh source is pinned to
[`c7d5157384e072ad82c58916f4d3bcca50894f25`](https://github.com/Mesh-LLM/mesh-llm/tree/c7d5157384e072ad82c58916f4d3bcca50894f25),
after [payments-v3 PR #2407](https://github.com/Mesh-LLM/mesh-llm/pull/2407), merged
as `51956c238cb3e0decfb054714a4f59cd4b45ebf4`. The latest published release checked
for this milestone was v0.78.1; its thin Swift client does not supply the current
payments engine. The free provider retains that unchanged, pinned SDK.

`source.lock.json` records the archive hash, source revision, feature selection,
and supported build targets. `prepare.sh` verifies both the downloaded archive
and the extracted source consumed by Cargo after applying the hash-pinned
`Patches/0001-stable-paid-client-identity.patch`. The patch adds an in-memory
client key injection point, with redacted Debug output and no config
serialization. This preserves the per-account buyer identity needed for v3
recovery; the independent random key is stored alongside the wallet in Keychain
only after explicit setup. The second hash-pinned patch,
`Patches/0002-in-process-payments-only.patch`, makes the explicit app-only
configuration resolve only the injected payments engine before any external
plugin or installed-plugin metadata lookup. Other upstream configurations keep
their original behavior. The shared production/probe config declares no plugins,
so even disabled-plugin schema validation cannot consult the desktop store.
A third hash-pinned patch,
`Patches/0003-release-inference-bridge-on-shutdown.patch`
(SHA256 `301067eac52c6c4e2834c57e666a04b2d3012565ebcd6014f85a0488b605a9f3`), breaks
the `PluginManager`/`InferenceRpcBridge` strong-reference cycle during terminal
shutdown and rejects late bridge installation. That cycle retained a stopped
Node and its account payment/wallet leases after the native handle was freed.
Unexpected source changes cause preparation to fail. The consumer
`Rust/Cargo.lock` locks its dependency graph, including the embedded Lexe SDK.

## Build

Run from the repository root:

```sh
sh sig-demo/ios/PaidMesh/build.sh
```

The script uses Rust 1.95.0, `just`, and the selected Xcode toolchain. It builds
arm64 macOS, iOS simulator, and iOS device libraries, then stages
`Artifacts/SigDemoPaidMeshFFI.xcframework` with an owned dynamic framework per
platform. Native outputs and the pinned source
are kept in ignored `.sig-demo/ios/paid-mesh-*` directories. The package imports
the C module `SigDemoPaidMeshFFI`; all exported functions use the distinct
`sig_demo_paid_mesh_` prefix. Each framework has its executable, install name,
private bundle identifier, headers, and module map before Xcode signs the app.
There is no post-signing metadata repair.

If a synchronized workspace evicts the public source cache, a regular file can
retain its metadata size while its bytes are unavailable. Preparation fails
rather than accepting a short read as a source change. Reconstruct the owned
public cache outside that workspace:

```sh
paid_source_cache=$(mktemp -d /private/tmp/sig-demo-paid-mesh-source-XXXXXX)
PAID_MESH_SOURCE_CACHE="$paid_source_cache" sh sig-demo/ios/PaidMesh/prepare.sh
```

The build-only override accepts an absolute ordinary directory immediately under
`/private/tmp` with that prefix, owned by the current user and not writable by
others. It verifies the original archive and all three patches, checks the complete
prepared tree, holds a no-follow directory descriptor and checks its identity,
then atomically redirects only the ignored public-source path used by Cargo.
It preserves an earlier unavailable cache and changes no wallet or home path.
An empty owned cache is populated from the verified source. Later builds reuse
the verified pointer; if the temporary cache is removed, run the explicit
command again with a new directory. Cache relocation can invalidate Cargo's
path-based build cache. This does not reconstruct unrelated app source or data.

Minimum deployment versions are iOS 16 and macOS 13. Swift uses `-dead_strip`
when linking with the existing free SDK and Rust agent. Only the five prefixed C
functions are exported from the paid framework. Its bundled SQLite and Rust
runtime remain inside that dynamic boundary, preventing it from supplying
SQLite symbols to Signal's separate SQLCipher framework. The original free SDK
binaries and their ABI remain unchanged. Build, link, and
runtime qualification are separate checks; a successful `cargo check` alone
does not establish an iOS link or a successful paid request.

## Lifecycle and C contract

[`include/sig_demo_paid_mesh.h`](include/sig_demo_paid_mesh.h) defines the owned
handle and string API. `create` accepts
`{"version":1,"storage_directory":"absolute per-account directory"}`. The
directory basename is the app's SHA256 namespace for deployment and account.
Creation and passive snapshots do not provision or contact a wallet. The iOS
wallet state is protected by a device-only Keychain item; there is no plaintext
seed or SDK database fallback. Production wallet storage is unavailable on the
macOS qualification host, where tests explicitly inject an empty memory store.

`call` accepts one JSON command and returns
`{"ok":true,"value":...}` or a fixed, sanitized error code. Calls run off the
Swift main actor and are serialized per handle. The supported operations are:

- `snapshot`: passive cached wallet facts.
- `setup_wallet`: explicit wallet signup/setup; retries resume persisted setup.
- `refresh_wallet` with required `daily_budget_msat` and
  `per_request_budget_msat`: apply the current limits, including zero, then
  refresh the existing wallet and reconcile original requests. No signup.
- `funding_invoice` with positive `amount_msat`: create an inbound funding
  invoice; return `bolt11`, `payment_hash`, `amount_msat`, and `expires_at_ms`.
- `refresh_wallet_observation`: read the existing wallet balance without
  provisioning, payment recovery, or Node startup.
- `funding_status` with `payment_hash`: observe that exact inbound invoice and
  then read a fresh balance. Only an authoritative completed payment with a
  positive received amount and completion time is reported as paid.
- `transaction_history` with optional `cursor` and bounded `limit`: read Lexe's
  payment updates. Clients merge records by stable ID, since a later page can
  contain the completed version of an earlier pending record.
- `confirmed_funding`: scan bounded payment history for the earliest completed
  inbound payment. Incomplete or unsupported history cannot initialize limits.
- `start` with `model`, `daily_budget_msat`, `per_request_budget_msat`: start the
  public client and return its private loopback API URL, exact requested model,
  and input/output rate ceilings. The default model is `Qwen3.6-27B-Q6_K`.
- `models`: the exact configured model preference, without an availability
  claim.
- `begin_request` / `end_request` with `scope_id`: open/close one whole Sig
  invocation's budget scope, including sequential tool and model calls. Response
  EOF does not close financial authority: finalization first stops new admissions
  and waits for the original requests' authoritative settlement results.
- `stop`: stop the node, fence new wallet work, and perform bounded payment
  reconciliation.

Snapshots contain `provisioned`, `ready`, `setup_pending`, nullable
`balance_msat`, `reserved_msat`, `spent_today_msat`, `daily_budget_msat`,
`per_request_budget_msat`, `pending_count`, `pending_scope_count`, and
`reconciliation_required`.
Unknown balances remain unknown. A pending payment is never described as
refunded solely because the app stopped or an observer was cancelled.

The four observation commands neither sign up a wallet nor reconcile or submit
payments. The Swift wrapper admits them only while the runtime is idle. The app
pauses invoice polling in the background, resumes the same visible invoice on
return, and drains existing reads before opening a paid inference request.

The Node URL is only used behind the owned Swift streaming proxy. The proxy
allows chat completions for the selected model, injects paid intent, and has no
wallet/operator forwarding path. It retains HTTP status and raw SSE framing.
Cancellation is nonblocking at the C boundary; Swift then waits for the active
call and native teardown before freeing the handle. Node startup uses its own
bounded startup deadline; cancellation that arrives during startup cleans up a
late handle before returning.

`PaidMeshRuntime.shutdown()` permanently retires a lifecycle owner before
awaiting teardown. Later snapshots return only cached state, and later native
creation, observation, control, and inference admission are rejected. A native
factory that finishes after retirement is shut down. Full app/account/provider
teardown uses this operation. `stop()` drains the current context but permits
explicit reuse by that same owner for route refresh or reconciliation. App
callbacks check the current account, provider, generation, cancellation, and
foreground state before and after requesting a snapshot. That Swift defense
alone did not fix the observed resume failure: native teardown also needs the
third source patch to release the plugin manager’s self-owning inference bridge.

## Spending authority

Both budgets start at zero. Unless the user has saved limits, the app initializes
both once to half the first confirmed funding amount, rounded down to whole
units. Later deposits do not reset them. Existing nonzero limits are preserved,
and a manual save, including zero, prevents automatic changes. The default is
based on complete authoritative history, never the current balance or an unpaid
invoice. The foreground wallet monitor can retry this authoritative-history
lookup up to three times independently of invoice-screen visibility. It requires
the same account, generation, and paid provider to remain active and idle; Mesh
startup or another observation does not consume a retry attempt. Only complete
history may initialize limits, and saved/manual markers remain protected. These
lookups are observe-only. The native wallet guard must approve an outgoing
invoice before the wallet can submit it. A buyer-only `payments.v1` capability
binds each Mesh request ID to the active whole-answer scope, then authorizes its
invoice hash and principal before calling the stock v3 settlement engine.
Seller and generic wallet/operator commands are absent from this capability.

The current upstream `allow_paid.max_total_msat` is a legacy terms field, not a
hard request cap. This implementation does not rely on it for spending
authority. The separate durable guard tracks each hash, scope, principal,
fee-inclusive submission reservation, and authoritative terminal result. It
checks the exact Lexe preflight route's amount and fees before submitting that
same route. Uncertain submissions retain their reservations across cancellation,
restart, and day boundaries. A later invocation cannot adopt an earlier request
ID or payment hash. Definite never-submitted errors may release only a
reservation that the guard independently proves was never submitted.

Recovery retains the original request bindings and stable, account-scoped Mesh
buyer key in protected Keychain state. Before opening a new inference route,
the runtime reconciles earlier requests without admitting new ones. Any new
settlement payment must fit both the current limits and the original scope's
limits. Current zero limits prevent a new send; already-submitted payments can
still be observed and retain their reservations. Raising settings cannot expand
the original scope's authority. A bounded failure remains visible as an
outstanding settlement and blocks new paid replies.

Input and output eligibility ceilings are currently fixed at ₿10,000 per
million tokens. Their protocol fields retain the integer
`msat_per_million_tokens` wire format. These control eligible advertised rates separately
from the user's actual fee-inclusive daily and per-invocation payment caps.
They are not a quote or a promise that the requested public model is online.
