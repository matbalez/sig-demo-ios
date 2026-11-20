# Embedded iOS Lexe payer

This crate implements Mesh `WalletFactory` / `WalletProvider` directly in the
iOS process. It does not load the desktop wallet plugin, seed files, wallet
configuration, or wallet database. It exposes no manual send or model-serving
invoice operation. A separate explicit funding control creates a real invoice.

## Source qualification

- Mesh source is pinned to
  `c7d5157384e072ad82c58916f4d3bcca50894f25`, extracted by the paid build tooling
  into `.sig-demo/ios/paid-mesh-probe/source` (archive SHA256
  `2a71914b65693b047183f5ff116c25e5757668f5e75e3c25991de3f73ec7aa85`).
- Lexe and its direct API types are both exactly `0.1.24`. This is the version
  already qualified for iOS and used by the current public
  [Mesh Lexe wallet plugin](https://github.com/Mesh-LLM/lexe-wallet/blob/main/src/lexe.rs).
  The public plugin module inspected on 2026-10-23 had Git blob
  `dec8d24708c057790fb69eeddce8a87d05e62cfb`. Its source is a reference for the
  preflight/route-continuation API, not a dependency of this crate.
- The registry's newest Lexe release observed during implementation was
  `0.1.27`. This adapter deliberately keeps the qualified version pair rather
  than combining newer API types with the older SDK. Upgrading requires another
  source and target-build review.
- [Official SDK documentation](https://docs.lexe.tech/rust/) describes root-seed
  and delegated-client credentials. This implementation uses `without_db`,
  retaining no SDK seedphrase file or payment database. The `unstable` feature
  is necessary for the explicit node preflight API. The API model promises that
  submitting the returned `ldk_route` preserves the preflighted fees.

## Account and lifecycle boundary

The app creates a protected, excluded-from-backup account directory whose final
component is the lowercase SHA256 of deployment identity and ACI. Keychain
service `dev.matbalez.sig-demo.ios.paid-mesh.lexe.v1` uses that stable hash as its
account. A single atomic generic-password value holds recovery material, the
wallet identity, budgets, request bindings, and payment reservations. It is
nonsynchronizable and `WhenUnlockedThisDeviceOnly`. There is no plaintext or
host-Keychain fallback. A process lock rejects two owners of the same account.
The same protected value contains an independently generated 32-byte buyer-node
identity. Explicit setup persists it before any Mesh connection. The node key
is stable for this account/deployment and is never returned to Swift, exported
in a snapshot, or replaced when prior request bindings exist.

`new`, `snapshot`, and factory discovery are passive. `setup_wallet` is an
explicit user action: persist the seed first, then perform idempotent signup and
trusted-node provisioning. A failed setup resumes the same seed. A restored
payment ledger with missing or mismatched Keychain identity fails closed.
`refresh_wallet` refreshes trusted releases, obtains a real balance and
reconciles pending hashes. `funding_invoice` is explicit and does not send money.

One `begin_request` scope covers the entire Sig answer, including subsequent
tool/model calls. The buyer-only Mesh router binds every native seller request
ID before admission and authorizes each exact invoice hash before payment.
Neither an old seller ID nor an invoice hash can move to a different scope.
`finish_request` first closes admission to new seller IDs and records an
outstanding exchange obligation. Only final-settlement invoices for already
bound IDs can be authorized while finishing. The native owner waits for the
Mesh ledger's authoritative terminal exchange state before `end_request` closes
all submissions. HTTP EOF alone is insufficient: Mesh closes its HTTP output
before paying the final invoice. Submitted hashes remain available for
observation and reconciliation, retaining their original ownership.

Restart retains unresolved scopes and their buyer identity. Recovery can resume
only the original bound IDs, with admissions closed, before publishing a new
inference route. Both original per-answer and original daily limits remain in
force alongside the current limits; increasing settings cannot enlarge an old
authorization. Missing/corrupt ledger data and bounded recovery failures remain
visible as reconciliation required and block new inference. An authenticated
buyer identity cannot be regenerated to escape an old obligation.

The synchronous `fence_new_payments` closes the native handle before node
shutdown or any cancellation await. It cannot be reopened by a late request;
the next foreground runtime creates a new context. `drain` applies this same
fence to authorizations, bindings, and submissions before waiting on
owned submission tasks. Tasks are counted before spawning. Delayed preflight
results must pass the same fence again before committing a payment. Dropping a
caller only stops observation; it never cancels or repeats the actual send.
The drain is bounded: an unresolved payment remains reserved and visible as
requiring reconciliation. Its absence from a truncated history is never treated
as proof that it was not sent.

## Spending limits

Both limits start at zero, disabling new payments. The per-request limit covers
all native requests in one answer. The daily limit uses midnight UTC, and a
persisted day high-water mark prevents clock rollback from resetting spending.
Uncertain reservations count on every subsequent day until reconciled.
The first cut also blocks a new inference scope while any submitted hash is
pending or unknown; refresh must observe its authoritative terminal result.

Before submission, Lexe returns the exact route amount and fee. The adapter
atomically checks and reserves their sum against the invoice authorization,
whole-answer limit, and daily limit. It submits that same route, never the
high-level SDK operation that discards the route. A pending or unknown hash
cannot be automatically resubmitted. An authoritative terminal result releases
or finalizes the reservation. A violation of the quoted route guarantee blocks
new spending. Mesh's own payment ledger remains responsible for inference
settlement; this journal only enforces wallet authorization and spending limits.

The safety journal is deliberately bounded to 2048 invoice/request records and
2 MiB. Exhaustion fails closed. Safe long-term compaction requires retention of
ownership and idempotency guarantees; deleting wallet state is not a supported
way to reset limits or history.

Wire amounts remain millisatoshi integers. The app formats user-visible bitcoin
amounts with its `₿` base-unit convention.
