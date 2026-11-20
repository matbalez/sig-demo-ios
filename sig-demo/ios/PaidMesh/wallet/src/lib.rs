//! Embedded, pay-only Lexe adapter for the private iOS demo.
//!
//! Constructing a context, opening the factory, and inspecting a snapshot never
//! signs up a wallet. Only `setup_wallet` creates recovery material or provisions
//! the user's own Lexe node. There is no plaintext seed/database fallback.

mod guard;
mod observation;
pub mod store;

use anyhow::{Context, Result, bail, ensure};
use async_trait::async_trait;
use fs2::FileExt;
use guard::{Phase, State};
use lexe::{
    config::WalletEnvConfig,
    types::{
        auth::{CredentialsRef, RootSeed},
        bitcoin::Amount,
        command::{CreateInvoiceRequest, GetUpdatedPaymentsRequest},
        payment::{Payment, PaymentDirection, PaymentHash, PaymentKind},
    },
    wallet::LexeWallet,
};
use lexe_api_core::{
    def::UserNodeRunApi,
    models::command::{PayInvoicePreflightRequest, PayInvoiceRequest, PaymentIdStruct},
    types::payments::PaymentId,
};
use mesh_llm_wallet::{
    invoice::Invoice,
    provider::{Balance, PayError, PaymentStatus, Transaction, WalletProvider},
    provisioning::{WalletFactory, WalletPin},
};
use serde_json::{Value, json};
use std::{
    fs::{File, OpenOptions},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use store::ProtectedStore;
use zeroize::Zeroizing;

const MAX_STATE_BYTES: usize = 2 * 1024 * 1024;
const PROVIDER_ID: &str = "sig-demo-ios-lexe-v1";

pub struct WalletContext {
    directory: PathBuf,
    store: Arc<dyn ProtectedStore>,
    state: Mutex<State>,
    wallet: tokio::sync::Mutex<Option<Arc<LexeWallet>>>,
    control: tokio::sync::Mutex<()>,
    submissions: Arc<tokio::sync::Mutex<()>>,
    submission_gate: Mutex<SubmissionGate>,
    terminal_fence: AtomicBool,
    submission_finished: tokio::sync::Notify,
    balance: Mutex<Option<u64>>,
    _lock: File,
}

#[derive(Default)]
struct SubmissionGate {
    active: usize,
}
struct AdmittedSubmission(Arc<WalletContext>);
impl Drop for AdmittedSubmission {
    fn drop(&mut self) {
        if let Ok(mut gate) = self.0.submission_gate.lock() {
            gate.active -= 1;
        }
        self.0.submission_finished.notify_waiters();
    }
}

impl WalletContext {
    /// `directory` must be an existing, protected per-account directory whose
    /// basename is the app's stable SHA256(deployment + ACI) namespace.
    pub fn new(directory: &Path) -> Result<Arc<Self>> {
        let namespace = directory
            .file_name()
            .and_then(|s| s.to_str())
            .context("invalid wallet directory")?;
        store::validate_namespace(namespace)?;
        #[cfg(target_os = "ios")]
        let store: Arc<dyn ProtectedStore> = Arc::new(store::KeychainStore::new(namespace)?);
        #[cfg(not(target_os = "ios"))]
        let store: Arc<dyn ProtectedStore> = Arc::new(store::UnavailableStore);
        Self::with_store(directory, store)
    }

    fn with_store(directory: &Path, store: Arc<dyn ProtectedStore>) -> Result<Arc<Self>> {
        ensure!(
            directory.is_dir(),
            "wallet account directory must already exist"
        );
        let directory = directory
            .canonicalize()
            .context("wallet account directory is unavailable")?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("mobile-wallet.lock"))
            .context("could not lock wallet account")?;
        lock.try_lock_exclusive()
            .context("wallet account is already open")?;
        let state = match store.load()? {
            Some(bytes) => {
                ensure!(bytes.len() <= MAX_STATE_BYTES, "wallet state is too large");
                let state: State = serde_json::from_slice(&bytes)
                    .map_err(|_| anyhow::anyhow!("wallet state is unreadable"))?;
                state.validate()?;
                state
            }
            None => State::default(),
        };
        ensure!(
            state.bindings.is_empty() || directory.join("payments/payments.sqlite3").is_file(),
            "payment ledger is missing; prior obligations require reconciliation"
        );
        // A restored ledger without its device-only Keychain identity must
        // never silently become a different wallet, even on explicit setup.
        if let Some(pin) = WalletPin::load(&directory.join("payments"))? {
            ensure!(
                state.seed.is_some()
                    && state.wallet_id.as_deref() == Some(pin.wallet_id.as_str())
                    && pin.plugin == PROVIDER_ID
                    && pin.provider == "lexe"
                    && pin.network == "mainnet",
                "wallet recovery state does not match its payment ledger"
            );
        }
        let context = Arc::new(Self {
            directory,
            store,
            state: Mutex::new(state),
            wallet: tokio::sync::Mutex::new(None),
            control: tokio::sync::Mutex::new(()),
            submissions: Arc::new(tokio::sync::Mutex::new(())),
            submission_gate: Mutex::new(SubmissionGate::default()),
            submission_finished: tokio::sync::Notify::new(),
            terminal_fence: AtomicBool::new(false),
            balance: Mutex::new(None),
            _lock: lock,
        });
        // A process crash ends permission to bind NEW seller requests. Existing
        // bindings/reservations remain intact for settlement and reconciliation.
        if context.read(|s| s.active_scope.is_some())? {
            context.change(|s| s.orphan_active())?;
        }
        Ok(context)
    }

    fn read<T>(&self, body: impl FnOnce(&State) -> T) -> Result<T> {
        let state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet state is unavailable"))?;
        Ok(body(&state))
    }
    fn change<T>(&self, body: impl FnOnce(&mut State) -> Result<T>) -> Result<T> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet state is unavailable"))?;
        let mut next = state.clone();
        let result = body(&mut next)?;
        next.validate()?;
        let bytes = Zeroizing::new(
            serde_json::to_vec(&next)
                .map_err(|_| anyhow::anyhow!("could not encode wallet state"))?,
        );
        ensure!(
            bytes.len() <= MAX_STATE_BYTES,
            "wallet safety history is full"
        );
        self.store.store(&bytes)?; // durable authorization precedes ANY submission
        *state = next;
        Ok(result)
    }

    pub fn factory(self: &Arc<Self>) -> Arc<dyn WalletFactory> {
        Arc::new(MobileFactory(Arc::clone(self)))
    }
    pub fn snapshot(&self) -> Result<Value> {
        let balance = *self
            .balance
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet balance is unavailable"))?;
        self.read(|state| -> Result<Value> {
            let (spent, reserved, pending) = state.spending(state.day(mesh_llm_wallet::now_ms()))?;
            let fenced = self.terminal_fence.load(Ordering::Acquire);
            let pending_scopes = state.scopes.iter().filter(|(id, scope)| scope.obligation_pending
                || (fenced && !scope.closed && state.bindings.iter().any(|(request_id, scope_id)| scope_id == *id && !state.unaccepted.contains(request_id)))).count();
            Ok(json!({"provisioned": state.provisioned, "ready": state.provisioned && balance.is_some() && !state.safety_blocked && pending == 0 && pending_scopes == 0,
                "setup_pending": state.seed.is_some() && !state.provisioned,
                "balance_msat": balance, "reserved_msat": reserved, "spent_today_msat": spent,
                "daily_budget_msat": state.daily_budget_msat, "per_request_budget_msat": state.per_request_budget_msat,
                "pending_count": pending, "pending_scope_count": pending_scopes,
                "reconciliation_required": pending > 0 || pending_scopes > 0 || state.safety_blocked}))
        })?
    }
    pub fn set_budget(&self, daily_msat: u64, request_msat: u64) -> Result<()> {
        ensure!(
            request_msat <= daily_msat,
            "request spending limit exceeds daily limit"
        );
        self.change(|s| {
            ensure!(
                s.active_scope.is_none(),
                "cannot change limits during inference"
            );
            s.daily_budget_msat = daily_msat;
            s.per_request_budget_msat = request_msat;
            Ok(())
        })
    }
    pub fn begin_request(&self, scope_id: &str) -> Result<()> {
        let gate = self
            .submission_gate
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet is unavailable"))?;
        ensure!(
            !self.terminal_fence.load(Ordering::Acquire),
            "wallet is stopping"
        );
        ensure!(gate.active == 0, "previous payment work is still pending");
        self.change(|s| s.begin(scope_id))?;
        Ok(())
    }
    /// Close the native handle's payment gate before canceling streams or
    /// awaiting node shutdown. No network or persistence operation is performed.
    /// Reopening requires a new WalletContext, never a late begin_request call.
    pub fn fence_new_payments(&self) {
        self.terminal_fence.store(true, Ordering::Release);
    }
    pub fn bind_request(&self, native_request_id: &str) -> Result<()> {
        ensure!(
            !self.terminal_fence.load(Ordering::Acquire),
            "wallet is stopping"
        );
        self.change(|s| s.bind(native_request_id))
    }
    pub fn end_request(&self, scope_id: &str) -> Result<()> {
        self.change(|s| s.end(scope_id))
    }
    pub fn finish_request(&self, scope_id: &str) -> Result<Vec<String>> {
        self.change(|s| s.finish_request(scope_id))
    }
    pub fn bound_request_ids(&self, scope_id: &str) -> Result<Vec<String>> {
        self.read(|s| s.bound_request_ids(scope_id))?
    }
    pub fn mark_reconciliation_required(&self, scope_id: &str) -> Result<()> {
        self.change(|s| s.mark_reconciliation_required(scope_id))
    }
    /// Only after the live engine's acceptance operation has COMPLETED with an
    /// error and its existing ledger proves there was no accepted admission.
    /// Missing records discovered on restart are not this proof.
    pub fn mark_unaccepted(&self, native_request_id: &str) -> Result<()> {
        self.change(|s| s.mark_unaccepted(native_request_id))
    }
    pub fn unresolved_scopes(&self) -> Result<Vec<(String, Vec<String>)>> {
        self.read(|s| {
            s.scopes
                .iter()
                .filter(|(_, scope)| scope.obligation_pending)
                .map(|(id, _)| s.bound_request_ids(id).map(|ids| (id.clone(), ids)))
                .collect()
        })?
    }
    pub fn resume_recovery_scope(&self, scope_id: &str) -> Result<()> {
        ensure!(
            !self.terminal_fence.load(Ordering::Acquire),
            "wallet is stopping"
        );
        self.change(|s| s.resume_recovery_scope(scope_id))
    }
    pub fn authorize_invoice(
        &self,
        native_request_id: &str,
        invoice: &Invoice,
        amount_msat: u64,
        max_total_msat: u64,
    ) -> Result<()> {
        self.authorize_invoice_kind(
            native_request_id,
            invoice,
            amount_msat,
            max_total_msat,
            false,
        )
    }
    pub fn authorize_final_invoice(
        &self,
        native_request_id: &str,
        invoice: &Invoice,
        amount_msat: u64,
        max_total_msat: u64,
    ) -> Result<()> {
        self.authorize_invoice_kind(
            native_request_id,
            invoice,
            amount_msat,
            max_total_msat,
            true,
        )
    }
    fn authorize_invoice_kind(
        &self,
        native_request_id: &str,
        invoice: &Invoice,
        amount_msat: u64,
        max_total_msat: u64,
        is_final: bool,
    ) -> Result<()> {
        invoice.validate_payment(amount_msat, mesh_llm_wallet::now_ms())?;
        let parsed: lexe::types::bitcoin::Invoice = invoice
            .bolt11
            .parse()
            .map_err(|_| anyhow::anyhow!("invalid invoice"))?;
        ensure!(
            parsed.network() == bitcoin::Network::Bitcoin,
            "wallet accepts mainnet invoices only"
        );
        ensure!(
            !self.terminal_fence.load(Ordering::Acquire),
            "wallet is stopping"
        );
        self.change(|s| {
            if is_final {
                s.authorize_final(
                    native_request_id,
                    &invoice.payment_hash,
                    amount_msat,
                    max_total_msat,
                    mesh_llm_wallet::now_ms(),
                )
            } else {
                s.authorize(
                    native_request_id,
                    &invoice.payment_hash,
                    amount_msat,
                    max_total_msat,
                    mesh_llm_wallet::now_ms(),
                )
            }
        })
    }
    /// Safe after a stock service rejection: release only a provably never-sent
    /// authorization, preserving ownership and all Submitted uncertainty.
    pub fn release_unsubmitted(&self, hash: &str) -> Result<()> {
        self.change(|s| s.release_unsubmitted(hash))
    }

    fn admit_submission(self: &Arc<Self>) -> Result<AdmittedSubmission> {
        let mut gate = self
            .submission_gate
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet is unavailable"))?;
        ensure!(
            !self.terminal_fence.load(Ordering::Acquire),
            "wallet is stopping"
        );
        gate.active = gate
            .active
            .checked_add(1)
            .context("wallet submission overflow")?;
        Ok(AdmittedSubmission(Arc::clone(self)))
    }
    fn reserve_submission(&self, hash: &str, debit: u64) -> Result<()> {
        self.change(|s| {
            ensure!(
                !self.terminal_fence.load(Ordering::Acquire),
                "wallet stopped before payment submission"
            );
            s.reserve_submission(hash, debit, mesh_llm_wallet::now_ms())
        })?;
        // Cancellation can arrive while Keychain persistence is in progress.
        // We still know no send has been attempted, so retire this reservation
        // durably instead of letting a delayed preflight initiate payment.
        if self.terminal_fence.load(Ordering::Acquire) {
            self.change(|s| {
                let amount = s
                    .invoices
                    .get(hash)
                    .context("invoice was not authorized")?
                    .amount_msat;
                s.reconcile(hash, amount, 0, false, mesh_llm_wallet::now_ms())
            })?;
            bail!("wallet stopped before payment submission");
        }
        Ok(())
    }

    fn seed(&self) -> Result<RootSeed> {
        self.read(|s| s.seed.as_ref().map(|v| Zeroizing::new(v.clone())))?
            .context("wallet setup is required")?
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("wallet recovery state is unreadable"))
    }
    /// Rust-only handoff to the embedded node. Caller must zero its temporary
    /// byte array after constructing the node's owning SecretKey.
    pub fn node_key_bytes(&self) -> Result<[u8; 32]> {
        self.read(|s| {
            ensure!(s.provisioned, "wallet setup is required");
            let secret = s
                .node_secret
                .as_ref()
                .context("original private buyer identity is unavailable")?;
            secret
                .as_slice()
                .try_into()
                .map_err(|_| anyhow::anyhow!("invalid private buyer identity"))
        })?
    }
    async fn opened_wallet(&self) -> Result<Arc<LexeWallet>> {
        let mut slot = self.wallet.lock().await;
        if let Some(wallet) = slot.as_ref() {
            return Ok(Arc::clone(wallet));
        }
        let seed = self.seed()?;
        let _ = rustls::crypto::ring::default_provider().install_default();
        let wallet = Arc::new(
            LexeWallet::without_db(WalletEnvConfig::mainnet(), CredentialsRef::from(&seed))
                .map_err(|_| anyhow::anyhow!("could not open wallet"))?,
        );
        let wallet_id = wallet.user_config().user_pk.to_string();
        self.read(|s| s.wallet_id.as_ref().is_none_or(|pin| pin == &wallet_id))?
            .then_some(())
            .context("wallet identity does not match its account pin")?;
        *slot = Some(Arc::clone(&wallet));
        Ok(wallet)
    }

    /// EXPLICIT user action only. Recovery state is persisted atomically before
    /// the idempotent signup/provision operation can have any network effect.
    pub async fn setup_wallet(self: &Arc<Self>) -> Result<Value> {
        let _control = self.control.lock().await;
        if self.read(|s| s.seed.is_none())? {
            let seed = RootSeed::generate();
            self.change(|s| {
                ensure!(s.seed.is_none(), "wallet recovery material already exists");
                s.seed = Some(seed.as_bytes().to_vec());
                Ok(())
            })?;
        }
        if self.read(|s| s.node_secret.is_none())? {
            ensure!(
                self.read(|s| s.bindings.is_empty())?,
                "original private buyer identity is unavailable; refusing to replace it"
            );
            let mut secret = Zeroizing::new([0u8; 32]);
            getrandom::fill(secret.as_mut())
                .map_err(|_| anyhow::anyhow!("could not generate private buyer identity"))?;
            self.change(|s| {
                ensure!(
                    s.node_secret.is_none(),
                    "private buyer identity already exists"
                );
                s.node_secret = Some(secret.to_vec());
                Ok(())
            })?;
        }
        let seed = self.seed()?;
        let wallet = self.opened_wallet().await?;
        wallet
            .signup(&seed, None)
            .await
            .map_err(|_| anyhow::anyhow!("wallet setup is incomplete; retry setup to resume"))?;
        let wallet_id = wallet.user_config().user_pk.to_string();
        self.change(|s| {
            s.wallet_id = Some(wallet_id);
            s.provisioned = true;
            Ok(())
        })?;
        self.refresh_wallet().await
    }
    pub async fn refresh_wallet(self: &Arc<Self>) -> Result<Value> {
        ensure!(self.read(|s| s.provisioned)?, "wallet setup is required");
        let wallet = self.opened_wallet().await?;
        let seed = self.seed()?;
        wallet
            .provision(CredentialsRef::from(&seed))
            .await
            .map_err(|_| anyhow::anyhow!("wallet trusted release refresh failed"))?;
        let info = wallet
            .node_info()
            .await
            .map_err(|_| anyhow::anyhow!("wallet balance query failed"))?;
        *self
            .balance
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet balance is unavailable"))? =
            Some(info.lightning_sendable_balance.msat());
        self.reconcile_pending(&wallet).await?;
        self.snapshot()
    }
    pub async fn funding_invoice(self: &Arc<Self>, amount_msat: Option<u64>) -> Result<Value> {
        ensure!(self.read(|s| s.provisioned)?, "wallet setup is required");
        ensure!(
            amount_msat.is_none_or(|v| v > 0),
            "funding amount must be positive"
        );
        let wallet = self.opened_wallet().await?;
        let result = wallet
            .create_invoice(CreateInvoiceRequest {
                amount: amount_msat.map(Amount::from_msat),
                expiration_secs: Some(3600),
                description: Some("Sig demo wallet funding".into()),
                ..Default::default()
            })
            .await
            .map_err(|_| anyhow::anyhow!("could not create wallet funding invoice"))?;
        let invoice = Invoice::parse(&result.invoice.to_string())?;
        Ok(
            json!({"bolt11": invoice.bolt11, "payment_hash": invoice.payment_hash,
            "amount_msat": invoice.amount_msat, "expires_at_ms": invoice.expires_at_ms}),
        )
    }
    /// Observe existing wallet data only. These methods must never call
    /// provision, reconcile_pending, the payment engine, or an outgoing API.
    async fn observation_wallet(&self) -> Result<Arc<LexeWallet>> {
        ensure!(
            self.read(|state| state.provisioned)?,
            "wallet setup is required"
        );
        ensure!(
            self.read(|state| state.active_scope.is_none())?,
            "wallet observation is busy during inference"
        );
        self.opened_wallet().await
    }
    fn cache_observed_balance(&self, value: u64) -> Result<()> {
        *self
            .balance
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet balance is unavailable"))? = Some(value);
        Ok(())
    }
    pub async fn refresh_wallet_observation(&self) -> Result<Value> {
        use observation::ObservationSource;
        let wallet = self.observation_wallet().await?;
        let balance = observation::LexeObservation(&wallet).balance_msat().await?;
        self.cache_observed_balance(balance)?;
        self.snapshot()
    }
    pub async fn funding_status(&self, hash: &str) -> Result<Value> {
        let wallet = self.observation_wallet().await?;
        let status = observation::funding_status(
            &observation::LexeObservation(&wallet),
            hash,
            mesh_llm_wallet::now_ms(),
        )
        .await?;
        self.cache_observed_balance(status.balance_msat)?;
        let mut value = serde_json::to_value(status)?;
        value["wallet"] = self.snapshot()?;
        Ok(value)
    }
    pub async fn transaction_history(&self, cursor: Option<&str>, limit: usize) -> Result<Value> {
        let wallet = self.observation_wallet().await?;
        Ok(serde_json::to_value(
            observation::history(&observation::LexeObservation(&wallet), cursor, limit).await?,
        )?)
    }
    pub async fn confirmed_funding(&self) -> Result<Value> {
        let wallet = self.observation_wallet().await?;
        Ok(serde_json::to_value(
            observation::confirmed_funding(&observation::LexeObservation(&wallet)).await?,
        )?)
    }
    pub async fn drain(self: &Arc<Self>) -> Result<()> {
        // A canceled observer never cancels or retries the underlying send. A
        // bounded drain waits for submission work, then observes unknown hashes.
        self.fence_new_payments();
        // The fence itself is wait-free. Persist the outstanding exchange marker
        // here; even if protected data is locked, still drain owned sends.
        let mark_result = if let Some(scope) = self.read(|s| s.active_scope.clone())? {
            self.change(|s| s.finish_request(&scope).map(|_| ()))
        } else {
            Ok(())
        };
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let finished = self.submission_finished.notified();
                tokio::pin!(finished);
                finished.as_mut().enable();
                if self
                    .submission_gate
                    .lock()
                    .map_err(|_| anyhow::anyhow!("wallet is unavailable"))?
                    .active
                    == 0
                {
                    break;
                }
                finished.await;
            }
            Ok::<_, anyhow::Error>(())
        })
        .await
        .context("payment reconciliation is still pending")??;
        if self.read(|s| s.provisioned)? {
            let wallet = self.opened_wallet().await?;
            tokio::time::timeout(Duration::from_secs(20), self.reconcile_pending(&wallet))
                .await
                .context("payment reconciliation is still pending")??;
        }
        mark_result?;
        Ok(())
    }
    async fn reconcile_pending(&self, wallet: &LexeWallet) -> Result<()> {
        let hashes = self.read(|s| {
            s.invoices
                .iter()
                .filter(|(_, row)| row.phase == Phase::Submitted)
                .map(|(hash, _)| hash.clone())
                .collect::<Vec<_>>()
        })?;
        for hash in hashes {
            if let Some(transaction) = lookup_fresh(wallet, &hash).await? {
                self.observe(&hash, &transaction)?;
            }
        }
        Ok(())
    }
    fn observe(&self, hash: &str, transaction: &Transaction) -> Result<()> {
        ensure!(
            !transaction.inbound && transaction.payment_hash.as_deref() == Some(hash),
            "wallet returned an unrelated payment"
        );
        if transaction.status != PaymentStatus::Pending {
            let debit = transaction
                .amount_msat
                .checked_add(transaction.fee_msat)
                .context("wallet fee overflow")?;
            let violates_quote = self.read(|s| {
                s.invoices.get(hash).is_some_and(|row| {
                    row.phase == Phase::Submitted
                        && ((transaction.status == PaymentStatus::Succeeded
                            && (debit > row.reserved_msat
                                || transaction.amount_msat < row.amount_msat))
                            || (transaction.status == PaymentStatus::Failed
                                && transaction.fee_msat != 0))
                })
            })?;
            if violates_quote {
                self.change(|s| {
                    s.safety_blocked = true;
                    Ok(())
                })?;
                bail!("wallet route guarantee failed; spending is blocked");
            }
            self.change(|s| {
                s.reconcile(
                    hash,
                    transaction.amount_msat,
                    transaction.fee_msat,
                    transaction.status == PaymentStatus::Succeeded,
                    mesh_llm_wallet::now_ms(),
                )
            })?;
        }
        Ok(())
    }

    #[cfg(any(test, feature = "test-support"))]
    pub fn new_with_store(directory: &Path, store: Arc<dyn ProtectedStore>) -> Result<Arc<Self>> {
        Self::with_store(directory, store)
    }
}

struct MobileFactory(Arc<WalletContext>);
#[async_trait]
impl WalletFactory for MobileFactory {
    fn is_provisioned(&self, _: &Path) -> bool {
        self.0.read(|s| s.provisioned).unwrap_or(false)
    }
    async fn open(&self, directory: &Path) -> Result<Arc<dyn WalletProvider>> {
        ensure!(self.0.read(|s| s.provisioned)?, "wallet setup is required");
        let directory = directory
            .canonicalize()
            .context("payment directory is unavailable")?;
        ensure!(
            directory.starts_with(&self.0.directory),
            "payment directory belongs to another account"
        );
        let wallet = self.0.opened_wallet().await?;
        let expected = WalletPin {
            plugin: PROVIDER_ID.into(),
            wallet_id: wallet.user_config().user_pk.to_string(),
            provider: "lexe".into(),
            network: "mainnet".into(),
        };
        match WalletPin::load(&directory)? {
            Some(pin) => ensure!(pin == expected, "payment ledger belongs to another wallet"),
            None => expected.store(&directory)?,
        }
        Ok(Arc::new(MobileProvider {
            context: Arc::clone(&self.0),
            wallet,
        }))
    }
}

struct MobileProvider {
    context: Arc<WalletContext>,
    wallet: Arc<LexeWallet>,
}
#[async_trait]
impl WalletProvider for MobileProvider {
    async fn balance(&self) -> Result<Balance> {
        let info = self
            .wallet
            .node_info()
            .await
            .map_err(|_| anyhow::anyhow!("wallet balance query failed"))?;
        let spendable_msat = info.lightning_sendable_balance.msat();
        *self
            .context
            .balance
            .lock()
            .map_err(|_| anyhow::anyhow!("wallet balance is unavailable"))? = Some(spendable_msat);
        Ok(Balance { spendable_msat })
    }
    async fn transactions(&self, limit: usize) -> Result<Vec<Transaction>> {
        ensure!((1..=1000).contains(&limit), "invalid wallet history limit");
        let mut cursor = None;
        let mut values = Vec::new();
        for _ in 0..100 {
            let result = self
                .wallet
                .get_updated_payments(GetUpdatedPaymentsRequest {
                    start_index: cursor,
                    limit: Some(100),
                })
                .await
                .map_err(|_| anyhow::anyhow!("wallet history query failed"))?;
            let count = result.payments.len();
            for payment in result.payments {
                values.push(transaction(payment));
            }
            if count < 100 {
                values.sort_by_key(|v| std::cmp::Reverse(v.created_at_ms));
                values.truncate(limit);
                return Ok(values);
            }
            ensure!(
                result.updated_index != cursor,
                "wallet history cursor did not advance"
            );
            cursor = result.updated_index;
        }
        bail!("wallet history exceeds the mobile query limit")
    }
    async fn create_invoice(&self, _: Option<u64>, _: u32) -> Result<Invoice> {
        bail!("pay-only wallet cannot issue seller invoices")
    }
    async fn pay(
        &self,
        invoice: &Invoice,
        amount_msat: u64,
        max_total_msat: u64,
    ) -> Result<Transaction, PayError> {
        invoice
            .validate_payment(amount_msat, mesh_llm_wallet::now_ms())
            .map_err(PayError::NotSubmitted)?;
        let row = self
            .context
            .read(|s| s.invoices.get(&invoice.payment_hash).cloned())
            .map_err(PayError::NotSubmitted)?
            .context("invoice was not authorized")
            .map_err(PayError::NotSubmitted)?;
        ensure_pay(
            row.amount_msat == amount_msat && row.ceiling_msat <= max_total_msat,
            "invoice authorization mismatch",
        )?;
        let context = Arc::clone(&self.context);
        let wallet = Arc::clone(&self.wallet);
        let invoice = invoice.clone();
        let admitted = context.admit_submission().map_err(|error| {
            if row.phase == Phase::Authorized {
                PayError::NotSubmitted(error)
            } else {
                PayError::Uncertain(error)
            }
        })?;
        // This owned task survives cancellation of the Mesh caller. The durable
        // Submitted marker is committed before the first submission byte.
        tokio::spawn(async move {
            let _admitted = admitted;
            let hash = invoice.payment_hash.clone();
            let result = submit(Arc::clone(&context), wallet, invoice, amount_msat).await;
            if matches!(&result, Err(PayError::NotSubmitted(_))) {
                let _ = context.release_unsubmitted(&hash);
            }
            result
        })
        .await
        .map_err(|_| {
            PayError::Uncertain(anyhow::anyhow!(
                "payment task interrupted; reconciliation required"
            ))
        })?
    }
    async fn lookup(&self, hash: &str) -> Result<Option<Transaction>> {
        let value = lookup_fresh(&self.wallet, hash).await?;
        if let Some(value) = &value {
            self.context.observe(hash, value)?;
        }
        Ok(value)
    }
    async fn wait_for_payment(&self, hash: &str) -> Result<Transaction> {
        loop {
            if let Some(value) = self.lookup(hash).await? {
                if value.status != PaymentStatus::Pending {
                    return Ok(value);
                }
            }
            tokio::time::sleep(Duration::from_secs(4)).await;
        }
    }
}

fn ensure_pay(condition: bool, message: &'static str) -> Result<(), PayError> {
    if condition {
        Ok(())
    } else {
        Err(PayError::NotSubmitted(anyhow::anyhow!(message)))
    }
}
async fn submit(
    context: Arc<WalletContext>,
    wallet: Arc<LexeWallet>,
    invoice: Invoice,
    amount_msat: u64,
) -> Result<Transaction, PayError> {
    let _submission = context.submissions.lock().await;
    let hash = &invoice.payment_hash;
    let row = context
        .read(|s| s.invoices.get(hash).cloned())?
        .context("invoice was not authorized")?;
    if row.phase == Phase::Authorized {
        ensure_pay(
            !context.terminal_fence.load(Ordering::Acquire),
            "wallet is stopping",
        )?;
    }
    if let Some(existing) = lookup_fresh(&wallet, hash).await.map_err(|error| {
        if row.phase == Phase::Authorized {
            PayError::NotSubmitted(error)
        } else {
            PayError::Uncertain(error)
        }
    })? {
        context.observe(hash, &existing)?;
        return Ok(existing);
    }
    if row.phase != Phase::Authorized {
        return Err(PayError::Uncertain(anyhow::anyhow!(
            "payment outcome is unresolved; automatic resubmission is blocked"
        )));
    }
    ensure_pay(
        !context.terminal_fence.load(Ordering::Acquire),
        "wallet is stopping",
    )?;
    let parsed: lexe::types::bitcoin::Invoice = invoice
        .bolt11
        .parse()
        .map_err(|_| PayError::NotSubmitted(anyhow::anyhow!("invalid invoice")))?;
    ensure_pay(
        parsed.network() == bitcoin::Network::Bitcoin,
        "wallet accepts mainnet invoices only",
    )?;
    let fallback_amount = invoice
        .amount_msat
        .is_none()
        .then(|| Amount::from_msat(amount_msat));
    let route = wallet
        .node_client()
        .pay_invoice_preflight(PayInvoicePreflightRequest {
            invoice: parsed.clone(),
            fallback_amount,
            kind: PaymentKind::Invoice,
        })
        .await
        .map_err(|_| PayError::NotSubmitted(anyhow::anyhow!("wallet fee preflight failed")))?;
    let debit = route
        .amount
        .msat()
        .checked_add(route.fees.msat())
        .context("wallet fee overflow")
        .map_err(PayError::NotSubmitted)?;
    context
        .reserve_submission(hash, debit)
        .map_err(PayError::NotSubmitted)?;
    wallet
        .node_client()
        .pay_invoice(PayInvoiceRequest {
            invoice: parsed,
            fallback_amount,
            message: None,
            personal_note: None,
            kind: PaymentKind::Invoice,
            ldk_route: Some(route.ldk_route),
        })
        .await
        .map_err(|_| {
            PayError::Uncertain(anyhow::anyhow!(
                "wallet payment outcome uncertain; reconcile by hash"
            ))
        })?;
    let result = lookup_fresh(&wallet, hash)
        .await?
        .context("payment submitted; status is not yet available")?;
    context.observe(hash, &result)?;
    Ok(result)
}
async fn lookup_fresh(wallet: &LexeWallet, hash: &str) -> Result<Option<Transaction>> {
    guard::validate_hash(hash)?;
    let hash: PaymentHash = hash
        .parse()
        .map_err(|_| anyhow::anyhow!("invalid payment hash"))?;
    // Exact authoritative lookup; absence never comes from a truncated history
    // scan or an in-memory negative cache.
    let result = wallet
        .node_client()
        .get_payment_by_id(PaymentIdStruct {
            id: PaymentId::Lightning(hash),
        })
        .await
        .map_err(|_| anyhow::anyhow!("wallet payment status query failed"))?;
    Ok(result.maybe_payment.map(Payment::from).map(transaction))
}
fn transaction(payment: Payment) -> Transaction {
    Transaction {
        id: payment.index.to_string(),
        payment_hash: payment.hash.map(|h| h.to_string()),
        inbound: payment.direction == PaymentDirection::Inbound,
        amount_msat: payment.amount.map_or(0, |v| v.msat()),
        fee_msat: payment.fees.msat(),
        status: match payment.status {
            lexe::types::payment::PaymentStatus::Pending => PaymentStatus::Pending,
            lexe::types::payment::PaymentStatus::Completed => PaymentStatus::Succeeded,
            lexe::types::payment::PaymentStatus::Failed => PaymentStatus::Failed,
        },
        claiming: false,
        status_msg: None,
        created_at_ms: payment.created_at.to_millis(),
        settled_at_ms: payment.finalized_at.map(|v| v.to_millis()),
    }
}

#[cfg(test)]
mod tests;
