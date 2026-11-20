//! Small synchronous C boundary. Swift dispatches calls away from its executor;
//! cancellation uses a separate atomic generation and never waits on the call.

use std::ffi::{CStr, CString, c_char};
use std::net::{Ipv4Addr, TcpListener};
use std::path::{Component, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Result, ensure};
use mesh_llm_host_runtime::sdk::{EmbeddedMeshNodeBuilder, EmbeddedMeshNodeHandle};
use mesh_llm_payments::ledger::{ApprovalMode, Policy};
use serde::Deserialize;
use serde_json::{Value, json};
use sig_demo_paid_mesh_wallet::WalletContext;

use crate::payments::{self, PaymentRuntime};

// Rate eligibility is distinct from the guard's fee-inclusive payment caps.
const MAX_RATE_MSAT_PER_MILLION: u64 = 10_000_000;
const DEFAULT_MODEL: &str = "Qwen3.6-27B-Q6_K";
const MAX_COMMAND_BYTES: usize = 16 * 1024;

#[derive(Debug)]
struct MobileFailure(&'static str);
impl std::fmt::Display for MobileFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}
impl std::error::Error for MobileFailure {}

#[derive(Clone, Copy)]
enum StartupStage {
    WalletRefresh,
    Recovery,
    Policy,
    BuyerIdentity,
    NodeStart,
}

impl StartupStage {
    fn marker(self) -> &'static str {
        match self {
            Self::WalletRefresh => "WALLET_REFRESH",
            Self::Recovery => "RECOVERY",
            Self::Policy => "POLICY",
            Self::BuyerIdentity => "BUYER_IDENTITY",
            Self::NodeStart => "NODE_START",
        }
    }

    fn code(self) -> &'static str {
        match self {
            Self::WalletRefresh => "startup_wallet_refresh_failed",
            Self::Recovery => "startup_recovery_failed",
            Self::Policy => "startup_policy_failed",
            Self::BuyerIdentity => "startup_buyer_identity_failed",
            Self::NodeStart => "startup_node_start_failed",
        }
    }
}

fn http_failure_category(timeout: bool, connect: bool, status: Option<u16>) -> &'static str {
    if timeout {
        "REQWEST_TIMEOUT"
    } else if connect {
        "REQWEST_CONNECT"
    } else {
        match status {
            Some(401) => "HTTP_401",
            Some(403) => "HTTP_403",
            Some(429) => "HTTP_429",
            Some(500..=599) => "HTTP_5XX",
            _ => "REQWEST_OTHER",
        }
    }
}

fn wallet_failure_category(message: Option<&str>) -> Option<&'static str> {
    match message {
        Some("wallet trusted release refresh failed") => Some("WALLET_PROVISION"),
        Some("wallet balance query failed") => Some("WALLET_BALANCE"),
        _ => None,
    }
}

fn io_failure_category(kind: std::io::ErrorKind) -> &'static str {
    match kind {
        std::io::ErrorKind::PermissionDenied => "IO_PERMISSION_DENIED",
        std::io::ErrorKind::NotFound => "IO_NOT_FOUND",
        std::io::ErrorKind::AddrInUse => "IO_ADDR_IN_USE",
        std::io::ErrorKind::AddrNotAvailable => "IO_ADDR_UNAVAILABLE",
        std::io::ErrorKind::TimedOut => "IO_TIMEOUT",
        std::io::ErrorKind::ConnectionRefused => "IO_CONNECTION_REFUSED",
        std::io::ErrorKind::ConnectionReset => "IO_CONNECTION_RESET",
        std::io::ErrorKind::Interrupted => "IO_INTERRUPTED",
        std::io::ErrorKind::UnexpectedEof => "IO_UNEXPECTED_EOF",
        _ => "IO_OTHER",
    }
}

// The pinned SDK formats a worker error into this String context during
// startup cleanup. Inspect that outer String before an inner static message,
// but return only this finite vocabulary. Never format or emit its contents.
fn sdk_startup_failure_category(message: Option<&str>) -> Option<&'static str> {
    let message = message?;
    let worker =
        message.strip_prefix("failed to shut down embedded mesh runtime after startup error: ");
    if let Some(cause) = worker {
        return Some(sdk_worker_failure_category(cause));
    }
    if message.starts_with("Invalid config ") {
        return Some("SDK_CONFIG_INVALID");
    }
    if message.starts_with("Failed to read config ") {
        return Some("SDK_CONFIG_READ");
    }
    if message.starts_with("timed out waiting for embedded mesh console at ") {
        return Some("SDK_CONSOLE_TIMEOUT");
    }
    None
}

fn sdk_worker_failure_category(cause: &str) -> &'static str {
    // Exact source literals from the pinned SDK/runtime and iroh 1.4.1.
    for (message, category) in [
        (
            "Operation not permitted (os error 1)",
            "SDK_WORKER_IO_NOT_PERMITTED",
        ),
        (
            "No such file or directory (os error 2)",
            "SDK_WORKER_IO_NOT_FOUND",
        ),
        (
            "Permission denied (os error 13)",
            "SDK_WORKER_IO_PERMISSION_DENIED",
        ),
        (
            "Address already in use (os error 48)",
            "SDK_WORKER_IO_ADDR_IN_USE",
        ),
        (
            "Operation not supported (os error 45)",
            "SDK_WORKER_IO_UNSUPPORTED",
        ),
        (
            "Invalid argument (os error 22)",
            "SDK_WORKER_IO_INVALID_ARGUMENT",
        ),
        ("build embedded mesh runtime", "SDK_WORKER_RUNTIME_BUILD"),
        ("join smart auto task", "SDK_WORKER_DISCOVERY_TASK"),
        (
            "fixed disk prompt-cache mode requires a positive budget",
            "SDK_WORKER_KV_BUDGET",
        ),
        (
            "fixed disk prompt-cache mode has no budget",
            "SDK_WORKER_KV_BUDGET",
        ),
        (
            "cannot determine home directory for the disk prompt cache",
            "SDK_WORKER_KV_HOME",
        ),
        ("cannot determine home directory", "SDK_WORKER_HOME"),
        (
            "Failed to determine own binary path",
            "SDK_WORKER_BINARY_PATH",
        ),
        ("Binary has no parent directory", "SDK_WORKER_BINARY_PARENT"),
        (
            "unregistered mobile payment profile",
            "SDK_WORKER_PAYMENT_PROFILE",
        ),
        ("no payments engine installed", "SDK_WORKER_PAYMENT_ENGINE"),
        (
            "embedded client key requires client mode",
            "SDK_WORKER_CLIENT_MODE",
        ),
        (
            "termination-signal forwarder exited before registering its signal streams",
            "SDK_WORKER_SIGNAL_FORWARDER",
        ),
        ("Failed to bind sockets", "SDK_WORKER_IROH_SOCKETS"),
        (
            "Failed to create internal QUIC endpoint",
            "SDK_WORKER_IROH_QUIC",
        ),
        ("Failed to create netmon monitor", "SDK_WORKER_IROH_NETMON"),
        (
            "Invalid transport configuration",
            "SDK_WORKER_IROH_TRANSPORT",
        ),
        ("Invalid CA root configuration", "SDK_WORKER_IROH_CA_ROOT"),
        (
            "Failed to create an address lookup service",
            "SDK_WORKER_IROH_LOOKUP",
        ),
        (
            "Missing or incompatible rustls crypto provider configured",
            "SDK_WORKER_IROH_CRYPTO",
        ),
        (
            "Error constructing TLS configuration",
            "SDK_WORKER_IROH_TLS",
        ),
        (
            "embedded mesh runtime thread panicked",
            "SDK_WORKER_PANICKED",
        ),
    ] {
        if cause == message {
            return category;
        }
    }
    // These SDK-owned prefixes precede a dynamic path/plugin/error. The suffix
    // is intentionally neither parsed nor logged.
    for (prefix, category) in [
        (
            "could not register signal streams: ",
            "SDK_WORKER_SIGNAL_REGISTRATION",
        ),
        (
            "no runtime to observe signals with: ",
            "SDK_WORKER_SIGNAL_RUNTIME",
        ),
        ("Invalid config ", "SDK_WORKER_CONFIG_INVALID"),
        ("Failed to read config ", "SDK_WORKER_CONFIG_READ"),
        (
            "Failed to load owner keystore ",
            "SDK_WORKER_OWNER_KEYSTORE",
        ),
        ("Failed to load trust store ", "SDK_WORKER_TRUST_STORE"),
        ("inspect ", "SDK_WORKER_IDENTITY_INSPECT"),
        ("create ", "SDK_WORKER_IDENTITY_CREATE"),
        ("write ", "SDK_WORKER_IDENTITY_WRITE"),
        ("remove ", "SDK_WORKER_IDENTITY_REMOVE"),
        ("restricting ", "SDK_WORKER_PAYMENT_DIRECTORY"),
        ("Failed to launch plugin '", "SDK_WORKER_PLUGIN_LAUNCH"),
        (
            "Timed out waiting for plugin '",
            "SDK_WORKER_PLUGIN_TIMEOUT",
        ),
        ("Plugin '", "SDK_WORKER_PLUGIN"),
        ("timed out after ", "SDK_WORKER_STOP_TIMEOUT"),
    ] {
        if cause.starts_with(prefix) {
            return category;
        }
    }
    "SDK_WORKER_OTHER"
}

fn sdk_startup_error_category(error: &anyhow::Error) -> Option<&'static str> {
    // SDK cleanup stores its worker cause in an outer String. Check it first:
    // anyhow's inner &str would otherwise hide that outer diagnostic context.
    if let Some(category) =
        sdk_startup_failure_category(error.downcast_ref::<String>().map(String::as_str))
    {
        return Some(category);
    }
    if error.downcast_ref::<&'static str>().copied()
        == Some("embedded mesh runtime exited before the console became ready")
    {
        return Some("SDK_WORKER_EXITED");
    }
    None
}

fn startup_failure_category(error: &anyhow::Error) -> &'static str {
    if error.downcast_ref::<MobileFailure>().is_some() {
        return "PRECONDITION";
    }
    if let Some(category) = sdk_startup_error_category(error) {
        return category;
    }
    // Compare only owned static message values. Never format an Error or emit
    // a dynamically supplied string, URL, request, identity, or wallet value.
    let message = error
        .downcast_ref::<&'static str>()
        .copied()
        .or_else(|| error.downcast_ref::<String>().map(String::as_str));
    if let Some(category) = wallet_failure_category(message) {
        return category;
    }
    if error
        .downcast_ref::<tokio::time::error::Elapsed>()
        .is_some()
    {
        return "TOKIO_TIMEOUT";
    }
    if let Some(error) = error.downcast_ref::<reqwest::Error>() {
        return http_failure_category(
            error.is_timeout(),
            error.is_connect(),
            error.status().map(|status| status.as_u16()),
        );
    }
    if let Some(error) = error.downcast_ref::<std::io::Error>() {
        return io_failure_category(error.kind());
    }
    "OTHER"
}

fn startup_diagnostic(stage: StartupStage, outcome: &'static str, category: &'static str) {
    write_startup_diagnostic(&mut std::io::stderr().lock(), stage, outcome, category);
}

fn write_startup_diagnostic(
    output: &mut dyn std::io::Write,
    stage: StartupStage,
    outcome: &'static str,
    category: &'static str,
) {
    // A closed stderr must not change startup, cancellation, or payment policy.
    let _ = writeln!(
        output,
        "SIG_DEMO_PAID_NATIVE_STAGE_{}_{}_{}",
        stage.marker(),
        outcome,
        category,
    );
}

// Preserve public preconditions and expose only a fixed stage for an otherwise
// opaque failure. Never retain or serialize the underlying error description.
fn startup_stage<T>(result: Result<T>, stage: StartupStage) -> Result<T> {
    match result {
        Ok(value) => {
            startup_diagnostic(stage, "PASS", "NONE");
            Ok(value)
        }
        Err(error) => {
            startup_diagnostic(stage, "FAIL", startup_failure_category(&error));
            if error.downcast_ref::<MobileFailure>().is_some() {
                Err(error)
            } else {
                Err(MobileFailure(stage.code()).into())
            }
        }
    }
}

fn require(condition: bool, code: &'static str) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(MobileFailure(code).into())
    }
}

pub struct SigDemoPaidMeshHandle {
    runtime: tokio::runtime::Runtime,
    session: Mutex<Session>,
    wallet: Arc<WalletContext>,
    cancellation_generation: AtomicU64,
    stopping: AtomicBool,
}

struct Session {
    directory: PathBuf,
    wallet: Arc<WalletContext>,
    payments: Arc<PaymentRuntime>,
    node: Option<EmbeddedMeshNodeHandle>,
    model: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    version: u8,
    storage_directory: PathBuf,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Start {
        #[serde(default = "default_model")]
        model: String,
        daily_budget_msat: u64,
        per_request_budget_msat: u64,
    },
    Snapshot,
    SetupWallet,
    RefreshWallet {
        daily_budget_msat: u64,
        per_request_budget_msat: u64,
    },
    FundingInvoice {
        amount_msat: Option<u64>,
    },
    RefreshWalletObservation,
    FundingStatus {
        payment_hash: String,
    },
    TransactionHistory {
        cursor: Option<String>,
        limit: usize,
    },
    ConfirmedFunding,
    Models,
    BeginRequest {
        scope_id: String,
    },
    EndRequest {
        scope_id: String,
    },
    Stop,
}

fn default_model() -> String {
    DEFAULT_MODEL.into()
}

impl Session {
    fn new(config: Configuration) -> Result<Self> {
        ensure!(config.version == 1, "unsupported configuration");
        let directory = config.storage_directory;
        ensure!(
            directory.is_absolute() && directory.components().count() >= 3,
            "invalid account directory"
        );
        ensure!(
            !directory
                .components()
                .any(|component| matches!(component, Component::ParentDir)),
            "invalid account directory"
        );
        std::fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
        }
        let directory = directory.canonicalize()?;
        let payment_directory = directory.join("payments");
        std::fs::create_dir_all(&payment_directory)?;
        let wallet = WalletContext::new(&directory)?;
        let payments = payments::register(&payment_directory, Arc::clone(&wallet))?;
        Ok(Self {
            directory,
            wallet,
            payments,
            node: None,
            model: None,
        })
    }

    async fn execute(&mut self, command: Command, cancelled: impl Fn() -> bool) -> Result<Value> {
        if matches!(
            &command,
            Command::RefreshWalletObservation
                | Command::FundingStatus { .. }
                | Command::TransactionHistory { .. }
                | Command::ConfirmedFunding
        ) {
            require(
                self.wallet.snapshot()?["provisioned"] == true,
                "wallet_not_set_up",
            )?;
        }
        match command {
            Command::Snapshot => self.wallet.snapshot(),
            Command::SetupWallet => {
                tokio::time::timeout(Duration::from_secs(45), self.wallet.setup_wallet()).await?
            }
            Command::RefreshWallet {
                daily_budget_msat,
                per_request_budget_msat,
            } => {
                self.wallet
                    .set_budget(daily_budget_msat, per_request_budget_msat)?;
                self.refresh(cancelled).await
            }
            Command::FundingInvoice { amount_msat } => {
                tokio::time::timeout(
                    Duration::from_secs(45),
                    self.wallet.funding_invoice(amount_msat),
                )
                .await?
            }
            Command::RefreshWalletObservation => {
                tokio::time::timeout(
                    Duration::from_secs(45),
                    self.wallet.refresh_wallet_observation(),
                )
                .await?
            }
            Command::FundingStatus { payment_hash } => {
                tokio::time::timeout(
                    Duration::from_secs(45),
                    self.wallet.funding_status(&payment_hash),
                )
                .await?
            }
            Command::TransactionHistory { cursor, limit } => {
                tokio::time::timeout(
                    Duration::from_secs(45),
                    self.wallet.transaction_history(cursor.as_deref(), limit),
                )
                .await?
            }
            Command::ConfirmedFunding => {
                tokio::time::timeout(Duration::from_secs(45), self.wallet.confirmed_funding())
                    .await?
            }
            Command::Models => self.models().await,
            Command::BeginRequest { scope_id } => {
                require(self.node.is_some(), "stopped")?;
                let snapshot = self.wallet.snapshot()?;
                require(
                    snapshot["reconciliation_required"] != true,
                    "payment_pending",
                )?;
                require(
                    snapshot["balance_msat"]
                        .as_u64()
                        .is_some_and(|value| value > 0),
                    "insufficient_funds",
                )?;
                validate_request_id(&scope_id)?;
                self.wallet.begin_request(&scope_id)?;
                Ok(json!({}))
            }
            Command::EndRequest { scope_id } => {
                validate_request_id(&scope_id)?;
                self.wallet.finish_request(&scope_id)?;
                self.wait_scope_terminal(&scope_id, &cancelled, Duration::from_secs(90))
                    .await?;
                self.wallet.end_request(&scope_id)?;
                Ok(json!({}))
            }
            Command::Start {
                model,
                daily_budget_msat,
                per_request_budget_msat,
            } => {
                self.start(model, daily_budget_msat, per_request_budget_msat, cancelled)
                    .await
            }
            Command::Stop => self.stop().await,
        }
    }

    async fn start(
        &mut self,
        model: String,
        daily: u64,
        per_request: u64,
        cancelled: impl Fn() -> bool,
    ) -> Result<Value> {
        ensure!(valid_model(&model), "invalid model");
        require(
            self.wallet.snapshot()?["provisioned"] == true,
            "wallet_not_set_up",
        )?;
        ensure!(
            daily <= i64::MAX as u64 && per_request <= daily,
            "invalid budget"
        );
        startup_stage(
            self.wallet.set_budget(daily, per_request),
            StartupStage::Policy,
        )?;
        require(daily > 0 && per_request > 0, "spending_disabled")?;
        ensure!(self.node.is_none(), "runtime already started");
        // Provider activation may refresh an existing wallet; signup remains
        // exclusive to the explicit setup_wallet command.
        startup_stage(
            async {
                tokio::time::timeout(Duration::from_secs(45), self.wallet.refresh_wallet())
                    .await??;
                Ok(())
            }
            .await,
            StartupStage::WalletRefresh,
        )?;
        // Recovery cannot expand the original scope authority. Current saved
        // limits (including zero) also constrain every new submission.
        startup_stage(
            self.recover_scopes(&cancelled).await,
            StartupStage::Recovery,
        )?;
        let snapshot = self.wallet.snapshot()?;
        require(
            snapshot["reconciliation_required"] != true,
            "payment_pending",
        )?;
        require(
            snapshot["balance_msat"]
                .as_u64()
                .is_some_and(|value| value > 0),
            "insufficient_funds",
        )?;
        require(!cancelled(), "stopped")?;
        startup_stage(
            self.payments.service.ledger.set_policy(&Policy {
                mode: ApprovalMode::Automatic,
                daily_budget_msat: Some(daily),
            }),
            StartupStage::Policy,
        )?;
        self.ensure_node(&cancelled).await?;
        let base_url = self
            .node
            .as_ref()
            .expect("started node")
            .api_base_url()
            .to_owned();
        self.model = Some(model.clone());
        Ok(json!({"api_base_url":base_url,"model":model,
            "max_input_msat_per_million":MAX_RATE_MSAT_PER_MILLION,
            "max_output_msat_per_million":MAX_RATE_MSAT_PER_MILLION}))
    }

    async fn ensure_node(&mut self, cancelled: &impl Fn() -> bool) -> Result<()> {
        startup_stage(self.start_node(cancelled).await, StartupStage::NodeStart)
    }

    async fn start_node(&mut self, cancelled: &impl Fn() -> bool) -> Result<()> {
        if self.node.is_some() {
            return Ok(());
        }
        require(!cancelled(), "stopped")?;
        // No global Mesh configuration, installed plugin store, or external
        // wallet process is consulted. This config lives beside this account.
        let config_path = crate::configuration::write(&self.directory)?;
        let key_bytes = zeroize::Zeroizing::new(startup_stage(
            self.wallet.node_key_bytes(),
            StartupStage::BuyerIdentity,
        )?);
        let node_key = iroh::SecretKey::from_bytes(&key_bytes);
        let node = EmbeddedMeshNodeBuilder::default()
            .client()
            .client_secret_key(node_key)
            .auto_join(true)
            .publish(false)
            .enumerate_host(false)
            .listen_all(false)
            .console_ui(false)
            .config_path(config_path)
            .isolated_config(true)
            // Explicit absent account path prevents probing an unrelated
            // default owner keystore in the embedding process's home.
            .owner_key(self.directory.join("unused-owner-keystore"))
            .api_port(unused_loopback_port()?)
            .console_port(unused_loopback_port()?)
            .startup_timeout(Duration::from_secs(35))
            .build();
        let handle = mesh_llm_host_runtime::sdk::start_embedded_node(node).await?;
        if cancelled() {
            handle.stop().await?;
            return Err(MobileFailure("stopped").into());
        }
        self.node = Some(handle);
        Ok(())
    }

    async fn recover_scopes(&mut self, cancelled: &impl Fn() -> bool) -> Result<()> {
        for (scope, _) in self.wallet.unresolved_scopes()? {
            self.wallet.resume_recovery_scope(&scope)?;
            self.ensure_node(cancelled).await?;
            if let Err(error) = self
                .wait_scope_terminal(&scope, cancelled, Duration::from_secs(90))
                .await
            {
                if let Some(node) = self.node.take() {
                    let _ = node.stop().await;
                }
                return Err(error);
            }
            self.wallet.end_request(&scope)?;
        }
        Ok(())
    }

    async fn wait_scope_terminal(
        &self,
        scope: &str,
        cancelled: &impl Fn() -> bool,
        timeout: Duration,
    ) -> Result<()> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            // Admission is now closed. Only durable, positively proven
            // unaccepted receipts may remove IDs while this wait is active.
            let ids = self.wallet.bound_request_ids(scope)?;
            let all_terminal = ids.iter().try_fold(true, |ready, id| -> Result<bool> {
                Ok(ready
                    && terminal_request_state(
                        self.payments.service.ledger.request_state(id)?.as_deref(),
                    ))
            })?;
            if all_terminal {
                return Ok(());
            }
            if cancelled() || tokio::time::Instant::now() >= deadline {
                self.wallet.mark_reconciliation_required(scope)?;
                return Err(MobileFailure("payment_pending").into());
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn refresh(&mut self, cancelled: impl Fn() -> bool) -> Result<Value> {
        tokio::time::timeout(Duration::from_secs(45), self.wallet.refresh_wallet()).await??;
        let temporary_node = self.node.is_none();
        self.recover_scopes(&cancelled).await?;
        if temporary_node {
            if let Some(node) = self.node.take() {
                node.stop().await?;
            }
        }
        self.wallet.snapshot()
    }

    async fn models(&self) -> Result<Value> {
        // The owned proxy uses only the configured exact model. Returning that
        // preference does not assert that a public seller is currently online.
        Ok(json!([{"id":self.model.as_deref().unwrap_or(DEFAULT_MODEL),
                    "name":self.model.as_deref().unwrap_or(DEFAULT_MODEL)}]))
    }

    async fn stop(&mut self) -> Result<Value> {
        self.wallet.fence_new_payments();
        let node_result = if let Some(handle) = self.node.take() {
            handle.stop().await
        } else {
            Ok(())
        };
        self.model = None;
        // Observation is bounded by the wallet adapter. Uncertain reservations
        // remain durable; closing the runtime never claims they were refunded.
        let wallet_result = self.wallet.drain().await;
        node_result?;
        wallet_result?;
        Ok(json!({}))
    }
}

fn terminal_request_state(state: Option<&str>) -> bool {
    matches!(state, Some("completed" | "failed" | "rejected"))
}

fn valid_model(value: &str) -> bool {
    !value.is_empty() && value.len() <= 1024 && !value.chars().any(char::is_control)
}

fn validate_request_id(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
        "invalid request ID"
    );
    Ok(())
}

fn unused_loopback_port() -> Result<u16> {
    Ok(TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?
        .local_addr()?
        .port())
}

unsafe fn bounded_text<'a>(input: *const c_char) -> Result<&'a str> {
    ensure!(!input.is_null(), "missing input");
    // The C caller supplies a valid NUL-terminated string for this call.
    let value = unsafe { CStr::from_ptr(input) };
    ensure!(
        value.to_bytes().len() <= MAX_COMMAND_BYTES,
        "input too large"
    );
    Ok(value.to_str()?)
}

fn output(value: Value) -> *mut c_char {
    CString::new(value.to_string())
        .expect("JSON contains no literal NUL")
        .into_raw()
}

fn failure(code: &str) -> *mut c_char {
    output(json!({"ok":false,"error":{"code":code}}))
}

/// # Safety
/// `input` must point to a valid NUL-terminated UTF-8 configuration for the
/// duration of the call. The returned handle is freed exactly once with free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sig_demo_paid_mesh_create(
    input: *const c_char,
) -> *mut SigDemoPaidMeshHandle {
    let result = std::panic::catch_unwind(|| -> Result<_> {
        let config = serde_json::from_str(unsafe { bounded_text(input)? })?;
        let session = Session::new(config)?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("sig-paid-mesh")
            .build()?;
        let wallet = Arc::clone(&session.wallet);
        Ok(Box::new(SigDemoPaidMeshHandle {
            runtime,
            session: Mutex::new(session),
            wallet,
            cancellation_generation: AtomicU64::new(0),
            stopping: AtomicBool::new(false),
        }))
    });
    match result {
        Ok(Ok(handle)) => Box::into_raw(handle),
        _ => std::ptr::null_mut(),
    }
}

/// # Safety
/// `handle` must be live and uniquely owned by the caller; calls are serialized.
/// `input` is a valid NUL-terminated command. Only cancel may overlap this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sig_demo_paid_mesh_call(
    handle: *mut SigDemoPaidMeshHandle,
    input: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return failure("invalid_configuration");
    }
    let handle = unsafe { &*handle };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<_> {
        let command: Command = serde_json::from_str(unsafe { bounded_text(input)? })?;
        if !matches!(
            command,
            Command::Snapshot | Command::EndRequest { .. } | Command::Stop
        ) {
            ensure!(!handle.stopping.load(Ordering::Acquire), "runtime stopping");
        }
        let generation = handle.cancellation_generation.load(Ordering::Acquire);
        let mut session = handle
            .session
            .try_lock()
            .map_err(|_| anyhow::anyhow!("busy"))?;
        handle.runtime.block_on(session.execute(command, || {
            handle.stopping.load(Ordering::Acquire)
                || handle.cancellation_generation.load(Ordering::Acquire) != generation
        }))
    }));
    match result {
        Ok(Ok(value)) => output(json!({"ok":true,"value":value})),
        Ok(Err(error)) => failure(
            error
                .downcast_ref::<MobileFailure>()
                .map_or("unavailable", |error| error.0),
        ),
        _ => failure("unavailable"),
    }
}

/// # Safety
/// A non-null handle must remain live until this call returns; free cannot race.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sig_demo_paid_mesh_cancel(handle: *mut SigDemoPaidMeshHandle) {
    if let Some(handle) = unsafe { handle.as_ref() } {
        handle.stopping.store(true, Ordering::Release);
        handle
            .cancellation_generation
            .fetch_add(1, Ordering::AcqRel);
        handle.wallet.fence_new_payments();
    }
}

/// # Safety
/// A non-null handle must have been returned by create, must not have been
/// freed, and must have no concurrent call or cancel invocations.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sig_demo_paid_mesh_free(handle: *mut SigDemoPaidMeshHandle) {
    if handle.is_null() {
        return;
    }
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let handle = unsafe { Box::from_raw(handle) };
        // Fence even if an earlier panic poisoned the session mutex. Teardown
        // must never leave background payment admissions open while dropping.
        handle.wallet.fence_new_payments();
        if let Ok(mut session) = handle.session.lock() {
            let _ = handle.runtime.block_on(session.stop());
        }
    }));
}

/// # Safety
/// A non-null string must have been returned by call and not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sig_demo_paid_mesh_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mesh_llm_host_runtime::plugin::{
        PluginHostMode, PluginManager, PluginRpcBridge, ResolvedPlugins, RpcResult, proto,
    };
    use mesh_llm_payments_types::{pricing::Pricing, terms::RequestTerms};
    use sig_demo_paid_mesh_wallet::store::ProtectedStore;
    use std::future::Future;
    use zeroize::Zeroizing;

    #[test]
    fn sdk_worker_io_classifier_requires_exact_darwin_literal() {
        for (cause, expected) in [
            (
                "Operation not permitted (os error 1)",
                "SDK_WORKER_IO_NOT_PERMITTED",
            ),
            (
                "No such file or directory (os error 2)",
                "SDK_WORKER_IO_NOT_FOUND",
            ),
            (
                "Permission denied (os error 13)",
                "SDK_WORKER_IO_PERMISSION_DENIED",
            ),
            (
                "Address already in use (os error 48)",
                "SDK_WORKER_IO_ADDR_IN_USE",
            ),
            (
                "Operation not supported (os error 45)",
                "SDK_WORKER_IO_UNSUPPORTED",
            ),
            (
                "Invalid argument (os error 22)",
                "SDK_WORKER_IO_INVALID_ARGUMENT",
            ),
        ] {
            assert_eq!(sdk_worker_failure_category(cause), expected);
            assert_eq!(
                sdk_worker_failure_category(&format!("{cause}: synthetic path")),
                "SDK_WORKER_OTHER"
            );
        }
    }

    #[test]
    fn sdk_outer_string_context_wins_over_inner_static_exit_message() {
        let error = anyhow::anyhow!("embedded mesh runtime exited before the console became ready")
            .context("failed to shut down embedded mesh runtime after startup error: Failed to create netmon monitor".to_owned());
        assert_eq!(
            sdk_startup_error_category(&error),
            Some("SDK_WORKER_IROH_NETMON")
        );
        assert_eq!(
            sdk_startup_error_category(&anyhow::anyhow!(
                "embedded mesh runtime exited before the console became ready"
            )),
            Some("SDK_WORKER_EXITED")
        );
        assert_eq!(
            sdk_startup_error_category(&anyhow::anyhow!("synthetic unrelated error")),
            None
        );
    }

    #[test]
    fn sdk_worker_classifier_matches_only_pinned_labels() {
        for (cause, expected) in [
            ("build embedded mesh runtime", "SDK_WORKER_RUNTIME_BUILD"),
            (
                "cannot determine home directory for the disk prompt cache",
                "SDK_WORKER_KV_HOME",
            ),
            (
                "could not register signal streams: synthetic detail",
                "SDK_WORKER_SIGNAL_REGISTRATION",
            ),
            (
                "no runtime to observe signals with: synthetic detail",
                "SDK_WORKER_SIGNAL_RUNTIME",
            ),
            ("Failed to create netmon monitor", "SDK_WORKER_IROH_NETMON"),
            ("Failed to bind sockets", "SDK_WORKER_IROH_SOCKETS"),
            (
                "Missing or incompatible rustls crypto provider configured",
                "SDK_WORKER_IROH_CRYPTO",
            ),
            (
                "Failed to load trust store /synthetic/private/path",
                "SDK_WORKER_TRUST_STORE",
            ),
            (
                "unregistered mobile payment profile",
                "SDK_WORKER_PAYMENT_PROFILE",
            ),
            ("synthetic unknown private detail", "SDK_WORKER_OTHER"),
            ("prefix Failed to create netmon monitor", "SDK_WORKER_OTHER"),
            (
                "Failed to create netmon monitor with synthetic suffix",
                "SDK_WORKER_OTHER",
            ),
        ] {
            let wrapped =
                format!("failed to shut down embedded mesh runtime after startup error: {cause}");
            assert_eq!(sdk_startup_failure_category(Some(&wrapped)), Some(expected));
        }
    }

    #[test]
    fn sdk_classifier_requires_exact_wrapper_or_sdk_prefix() {
        assert_eq!(sdk_startup_failure_category(None), None);
        assert_eq!(
            sdk_startup_failure_category(Some("synthetic private detail")),
            None
        );
        assert_eq!(
            sdk_startup_failure_category(Some("Failed to create netmon monitor")),
            None
        );
        assert_eq!(
            sdk_startup_failure_category(Some(
                "prefix failed to shut down embedded mesh runtime after startup error: Failed to create netmon monitor"
            )),
            None
        );
        assert_eq!(
            sdk_startup_failure_category(Some("Invalid config /synthetic/private/path")),
            Some("SDK_CONFIG_INVALID")
        );
        assert_eq!(
            sdk_startup_failure_category(Some(
                "timed out waiting for embedded mesh console at http://synthetic.invalid"
            )),
            Some("SDK_CONSOLE_TIMEOUT")
        );
    }

    #[test]
    fn sdk_classifier_never_emits_unknown_suffix() {
        let private = "synthetic-private-wallet-path-and-error";
        let wrapped =
            format!("failed to shut down embedded mesh runtime after startup error: {private}");
        let category = sdk_startup_failure_category(Some(&wrapped)).unwrap();
        let mut output = Vec::new();
        write_startup_diagnostic(&mut output, StartupStage::NodeStart, "FAIL", category);
        assert_eq!(
            output,
            b"SIG_DEMO_PAID_NATIVE_STAGE_NODE_START_FAIL_SDK_WORKER_OTHER\n"
        );
        assert!(!String::from_utf8(output).unwrap().contains(private));
    }

    #[test]
    fn startup_wallet_categories_require_exact_owned_messages() {
        assert_eq!(
            wallet_failure_category(Some("wallet trusted release refresh failed")),
            Some("WALLET_PROVISION")
        );
        assert_eq!(
            wallet_failure_category(Some("wallet balance query failed")),
            Some("WALLET_BALANCE")
        );
        assert_eq!(
            wallet_failure_category(Some("synthetic unknown detail")),
            None
        );
        assert_eq!(
            wallet_failure_category(Some("wallet balance query failed: synthetic detail")),
            None
        );
        assert_eq!(wallet_failure_category(None), None);
    }

    #[test]
    fn startup_io_categories_are_fixed() {
        for (kind, expected) in [
            (std::io::ErrorKind::PermissionDenied, "IO_PERMISSION_DENIED"),
            (std::io::ErrorKind::NotFound, "IO_NOT_FOUND"),
            (std::io::ErrorKind::AddrInUse, "IO_ADDR_IN_USE"),
            (std::io::ErrorKind::AddrNotAvailable, "IO_ADDR_UNAVAILABLE"),
            (std::io::ErrorKind::TimedOut, "IO_TIMEOUT"),
            (
                std::io::ErrorKind::ConnectionRefused,
                "IO_CONNECTION_REFUSED",
            ),
            (std::io::ErrorKind::ConnectionReset, "IO_CONNECTION_RESET"),
            (std::io::ErrorKind::Interrupted, "IO_INTERRUPTED"),
            (std::io::ErrorKind::UnexpectedEof, "IO_UNEXPECTED_EOF"),
            (std::io::ErrorKind::Other, "IO_OTHER"),
        ] {
            assert_eq!(io_failure_category(kind), expected);
        }
    }

    #[test]
    fn startup_http_categories_are_fixed_and_prioritize_timeout() {
        for (timeout, connect, status, expected) in [
            (true, true, Some(503), "REQWEST_TIMEOUT"),
            (false, true, None, "REQWEST_CONNECT"),
            (false, false, Some(401), "HTTP_401"),
            (false, false, Some(403), "HTTP_403"),
            (false, false, Some(429), "HTTP_429"),
            (false, false, Some(500), "HTTP_5XX"),
            (false, false, Some(599), "HTTP_5XX"),
            (false, false, Some(400), "REQWEST_OTHER"),
            (false, false, None, "REQWEST_OTHER"),
        ] {
            assert_eq!(http_failure_category(timeout, connect, status), expected);
        }
    }

    #[test]
    fn startup_diagnostic_output_is_fixed_and_closed_stderr_is_nonfatal() {
        struct Closed;
        impl std::io::Write for Closed {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
        }
        for (stage, tag) in [
            (StartupStage::WalletRefresh, "WALLET_REFRESH"),
            (StartupStage::Recovery, "RECOVERY"),
            (StartupStage::Policy, "POLICY"),
            (StartupStage::BuyerIdentity, "BUYER_IDENTITY"),
            (StartupStage::NodeStart, "NODE_START"),
        ] {
            let mut output = Vec::new();
            write_startup_diagnostic(&mut output, stage, "PASS", "NONE");
            assert_eq!(
                output,
                format!("SIG_DEMO_PAID_NATIVE_STAGE_{tag}_PASS_NONE\n").as_bytes()
            );
        }
        write_startup_diagnostic(&mut Closed, StartupStage::NodeStart, "FAIL", "OTHER");
    }

    #[test]
    fn startup_stage_exposes_only_fixed_codes_for_opaque_errors() {
        for (stage, expected) in [
            (StartupStage::WalletRefresh, "startup_wallet_refresh_failed"),
            (StartupStage::Recovery, "startup_recovery_failed"),
            (StartupStage::Policy, "startup_policy_failed"),
            (StartupStage::BuyerIdentity, "startup_buyer_identity_failed"),
            (StartupStage::NodeStart, "startup_node_start_failed"),
        ] {
            let error = startup_stage::<()>(
                Err(anyhow::anyhow!("synthetic private failure detail")),
                stage,
            )
            .unwrap_err();
            let code = error.downcast_ref::<MobileFailure>().unwrap().0;
            assert_eq!(code, expected);
            let response = failure(code);
            let envelope: Value =
                serde_json::from_slice(unsafe { CStr::from_ptr(response).to_bytes() }).unwrap();
            unsafe { sig_demo_paid_mesh_string_free(response) };
            assert_eq!(envelope, json!({"ok":false,"error":{"code":expected}}));
            assert!(!error.to_string().contains("private"));
        }
    }

    #[test]
    fn startup_stage_preserves_typed_preconditions_and_more_specific_stages() {
        for code in [
            "stopped",
            "payment_pending",
            "wallet_locked",
            "startup_buyer_identity_failed",
        ] {
            let error = anyhow::Error::new(MobileFailure(code)).context("synthetic context");
            let error = startup_stage::<()>(Err(error), StartupStage::Recovery).unwrap_err();
            assert_eq!(error.downcast_ref::<MobileFailure>().unwrap().0, code);
        }
    }

    #[test]
    fn startup_stage_does_not_change_success() {
        assert_eq!(startup_stage(Ok(17), StartupStage::NodeStart).unwrap(), 17);
    }

    struct MemoryStore(Mutex<Vec<u8>>);
    impl ProtectedStore for MemoryStore {
        fn load(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
            Ok(Some(Zeroizing::new(self.0.lock().unwrap().clone())))
        }
        fn store(&self, value: &[u8]) -> Result<()> {
            *self.0.lock().unwrap() = value.to_vec();
            Ok(())
        }
    }

    fn session() -> (tempfile::TempDir, Session) {
        session_with_provisioned(true)
    }

    struct ManagerOwningBridge {
        _manager: PluginManager,
    }

    impl PluginRpcBridge for ManagerOwningBridge {
        fn handle_request(
            &self,
            _: String,
            _: String,
            _: String,
        ) -> std::pin::Pin<Box<dyn Future<Output = Result<RpcResult, proto::ErrorResponse>> + Send>>
        {
            Box::pin(async {
                Ok(RpcResult {
                    result_json: "null".into(),
                })
            })
        }

        fn handle_notification(
            &self,
            _: String,
            _: String,
            _: String,
        ) -> std::pin::Pin<Box<dyn Future<Output = ()> + Send>> {
            Box::pin(async {})
        }
    }

    async fn empty_plugin_manager() -> PluginManager {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        PluginManager::start(
            &ResolvedPlugins {
                externals: Vec::new(),
                inactive: Vec::new(),
            },
            PluginHostMode {
                mesh_visibility: mesh_llm_plugin::MeshVisibility::Private,
            },
            tx,
        )
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn shutdown_releases_bridge_that_owns_its_plugin_manager() {
        let manager = empty_plugin_manager().await;
        let bridge = Arc::new(ManagerOwningBridge {
            _manager: manager.clone(),
        });
        let weak = Arc::downgrade(&bridge);
        manager.set_rpc_bridge(Some(bridge)).await;
        manager.shutdown().await;
        let released = weak.upgrade().is_none();
        // Also clean the deliberately failing pre-patch case in this fixture.
        manager.set_rpc_bridge(None).await;
        assert!(released, "terminal shutdown retained its own bridge");
    }

    #[tokio::test]
    async fn terminal_shutdown_rejects_late_bridge_reinstallation() {
        let manager = empty_plugin_manager().await;
        manager.shutdown().await;
        let bridge = Arc::new(ManagerOwningBridge {
            _manager: manager.clone(),
        });
        let weak = Arc::downgrade(&bridge);
        manager.set_rpc_bridge(Some(bridge)).await;
        let rejected = weak.upgrade().is_none();
        manager.set_rpc_bridge(None).await;
        assert!(
            rejected,
            "late install recreated a terminal ownership cycle"
        );
    }

    fn session_with_provisioned(provisioned: bool) -> (tempfile::TempDir, Session) {
        let directory = tempfile::tempdir().unwrap();
        let store = MemoryStore(Mutex::new(
            serde_json::to_vec(&json!({
                "version":1,"seed":provisioned.then(||vec![9u8;32]),"node_secret":provisioned.then(||vec![7u8;32]),
                "wallet_id":provisioned.then_some("synthetic"),"provisioned":provisioned,"safety_blocked":false,
                "daily_budget_msat":100000,"per_request_budget_msat":20000,
                "day_highwater":0,"active_scope":null,"scopes":{},"bindings":{},"invoices":{}
            }))
            .unwrap(),
        ));
        let wallet = WalletContext::new_with_store(directory.path(), Arc::new(store)).unwrap();
        let payment_directory = directory.path().join("payments");
        std::fs::create_dir_all(&payment_directory).unwrap();
        let payments = payments::register(&payment_directory, wallet.clone()).unwrap();
        payments
            .service
            .ledger
            .set_policy(&Policy {
                mode: ApprovalMode::Automatic,
                daily_budget_msat: Some(100000),
            })
            .unwrap();
        if provisioned {
            wallet.begin_request("scope").unwrap();
            wallet.bind_request("seller-id").unwrap();
        }
        let session = Session {
            directory: directory.path().to_owned(),
            wallet,
            payments,
            node: None,
            model: None,
        };
        (directory, session)
    }

    #[test]
    fn actual_c_boundary_recognizes_observers_without_provisioning_or_network() {
        let (_directory, session) = session_with_provisioned(false);
        let handle = Box::into_raw(Box::new(SigDemoPaidMeshHandle {
            runtime: tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap(),
            wallet: Arc::clone(&session.wallet),
            session: Mutex::new(session),
            cancellation_generation: AtomicU64::new(0),
            stopping: AtomicBool::new(false),
        }));
        for command in [
            json!({"op":"refresh_wallet_observation"}),
            json!({"op":"funding_status","payment_hash":"ab".repeat(32)}),
            json!({"op":"transaction_history","cursor":null,"limit":50}),
            json!({"op":"confirmed_funding"}),
        ] {
            let input = CString::new(command.to_string()).unwrap();
            let response = unsafe { sig_demo_paid_mesh_call(handle, input.as_ptr()) };
            assert!(!response.is_null());
            let value: Value =
                serde_json::from_slice(unsafe { CStr::from_ptr(response).to_bytes() }).unwrap();
            unsafe { sig_demo_paid_mesh_string_free(response) };
            assert_eq!(value["ok"], false);
            assert_eq!(value["error"]["code"], "wallet_not_set_up");
        }
        let session = unsafe { &*handle }.session.lock().unwrap();
        assert_eq!(session.wallet.snapshot().unwrap()["provisioned"], false);
        assert_eq!(session.wallet.snapshot().unwrap()["setup_pending"], false);
        drop(session);
        unsafe { sig_demo_paid_mesh_free(handle) };
    }

    fn propose(session: &Session) {
        session
            .payments
            .service
            .ledger
            .propose(&RequestTerms {
                exchange_id: None,
                id: "seller-id".into(),
                peer: "synthetic-peer".into(),
                payee: None,
                model: "synthetic-model".into(),
                pricing: Pricing {
                    input_msat_per_million: 1000,
                    output_msat_per_million: 1000,
                    cache_discount_percent: 0,
                },
                max_output_tokens: 100,
                max_total_msat: 10000,
                expires_at_ms: u64::MAX / 2,
            })
            .unwrap();
    }

    #[tokio::test]
    async fn missing_pending_and_approved_engine_rows_never_clear_obligation() {
        for state in ["missing", "pending", "approved"] {
            let (_directory, session) = session();
            if state != "missing" {
                propose(&session);
            }
            if state == "approved" {
                session
                    .payments
                    .service
                    .ledger
                    .approve("seller-id", 0)
                    .unwrap();
            }
            session.wallet.finish_request("scope").unwrap();
            assert!(
                session
                    .wait_scope_terminal("scope", &|| false, Duration::ZERO)
                    .await
                    .is_err()
            );
            assert_eq!(
                session.wallet.snapshot().unwrap()["reconciliation_required"],
                true
            );
            assert!(session.wallet.begin_request("next").is_err());
        }
    }

    #[tokio::test]
    async fn only_authoritative_engine_terminal_rows_allow_scope_close() {
        for state in ["completed", "failed", "rejected"] {
            let (_directory, session) = session();
            propose(&session);
            if state == "rejected" {
                session.payments.service.ledger.reject("seller-id").unwrap();
            } else {
                session
                    .payments
                    .service
                    .ledger
                    .approve("seller-id", 0)
                    .unwrap();
                // These writes simulate engine FINISH/definitive failure. The
                // production EOF hook must only observe, never make them.
                if state == "completed" {
                    session.payments.service.ledger.finish("seller-id").unwrap();
                } else {
                    session
                        .payments
                        .service
                        .ledger
                        .fail_authorization_if_idle("seller-id")
                        .unwrap();
                }
            }
            session.wallet.finish_request("scope").unwrap();
            session
                .wait_scope_terminal("scope", &|| false, Duration::ZERO)
                .await
                .unwrap();
            session.wallet.end_request("scope").unwrap();
            assert_eq!(
                session.wallet.snapshot().unwrap()["reconciliation_required"],
                false
            );
            session.wallet.begin_request("next").unwrap();
        }
    }

    #[tokio::test]
    async fn late_live_unaccepted_receipt_is_rechecked_while_waiting() {
        let (_directory, session) = session();
        session.wallet.finish_request("scope").unwrap();
        let wallet = session.wallet.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            wallet.mark_unaccepted("seller-id").unwrap();
        });
        session
            .wait_scope_terminal("scope", &|| false, Duration::from_secs(1))
            .await
            .unwrap();
        session.wallet.end_request("scope").unwrap();
        assert_eq!(
            session.wallet.snapshot().unwrap()["reconciliation_required"],
            false
        );
    }

    #[test]
    fn persistent_client_identity_debug_is_redacted() {
        let key = iroh::SecretKey::from_bytes(&[13u8; 32]);
        let config = EmbeddedMeshNodeBuilder::default()
            .client()
            .client_secret_key(key)
            .build();
        let debug = format!("{config:?}");
        assert!(debug.contains("SecretKey(..)"));
        assert!(!debug.contains(&"0d".repeat(32)));
    }
}
