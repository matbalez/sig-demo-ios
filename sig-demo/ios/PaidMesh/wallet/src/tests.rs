use super::*;

#[derive(Default)]
struct MemoryStore {
    value: Mutex<Option<Vec<u8>>>,
    fail: AtomicBool,
}
impl ProtectedStore for MemoryStore {
    fn load(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        Ok(self.value.lock().unwrap().clone().map(Zeroizing::new))
    }
    fn store(&self, value: &[u8]) -> Result<()> {
        ensure!(
            !self.fail.load(Ordering::SeqCst),
            "synthetic persistence failure"
        );
        *self.value.lock().unwrap() = Some(value.to_vec());
        Ok(())
    }
}
fn ready_state() -> State {
    let mut state = State::default();
    state.provisioned = true;
    state.seed = Some(vec![9; 32]);
    state.node_secret = Some(vec![7; 32]);
    state.wallet_id = Some("synthetic-wallet".into());
    state.daily_budget_msat = 1000;
    state.per_request_budget_msat = 600;
    state
}
fn hash(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}
fn begin(state: &mut State, scope: &str, request: &str) {
    state.begin(scope).unwrap();
    state.bind(request).unwrap();
}
fn synthetic_ledger_marker(directory: &Path) {
    std::fs::create_dir_all(directory.join("payments")).unwrap();
    // This test only exercises wallet-store durability, not SQLite parsing.
    std::fs::write(
        directory.join("payments/payments.sqlite3"),
        b"synthetic ledger marker",
    )
    .unwrap();
}

#[test]
fn zero_limits_and_unprovisioned_state_cannot_start_spending() {
    let mut state = State::default();
    assert!(state.begin("a").is_err());
    state.provisioned = true;
    assert!(state.begin("a").is_err());
    assert!(state.bind("unknown").is_err());
}

#[tokio::test]
async fn read_only_wallet_observers_never_set_up_an_unprovisioned_account() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    assert!(context.refresh_wallet_observation().await.is_err());
    assert!(context.funding_status(&hash(1)).await.is_err());
    assert!(context.transaction_history(None, 50).await.is_err());
    assert!(context.confirmed_funding().await.is_err());
    assert!(store.value.lock().unwrap().is_none());
    assert!(
        context
            .read(|state| state.seed.is_none() && !state.provisioned && state.node_secret.is_none())
            .unwrap()
    );
    assert!(context.wallet.lock().await.is_none());
}
#[test]
fn one_invocation_shares_request_limit_across_model_and_tool_turns() {
    let mut state = ready_state();
    begin(&mut state, "whole-answer", "first-model-call");
    state
        .authorize("first-model-call", &hash(1), 300, 1000, 0)
        .unwrap();
    state.reserve_submission(&hash(1), 350, 0).unwrap();
    state.reconcile(&hash(1), 300, 50, true, 0).unwrap();
    state.bind("second-model-call").unwrap();
    state
        .authorize("second-model-call", &hash(2), 250, 1000, 0)
        .unwrap();
    assert!(state.reserve_submission(&hash(2), 251, 0).is_err());
}
#[test]
fn fee_inclusive_limit_is_checked_before_submission() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state.authorize("r", &hash(1), 580, 1000, 0).unwrap();
    assert!(state.reserve_submission(&hash(1), 601, 0).is_err());
    assert!(state.invoices[&hash(1)].phase == Phase::Authorized);
    state.reserve_submission(&hash(1), 600, 0).unwrap();
    assert_eq!(state.spending(0).unwrap(), (0, 600, 1));
}
#[test]
fn uncertain_reservations_survive_scope_close_and_utc_day_rollover() {
    let mut state = ready_state();
    begin(&mut state, "yesterday", "r");
    state.authorize("r", &hash(1), 550, 1000, 0).unwrap();
    state.reserve_submission(&hash(1), 600, 0).unwrap();
    state.end("yesterday").unwrap();
    assert_eq!(state.spending(1).unwrap(), (0, 600, 1));
    assert!(state.begin("today").is_err());
    state
        .reconcile(&hash(1), 550, 50, true, 86_400_000)
        .unwrap();
    begin(&mut state, "today", "new-r");
    state
        .authorize("new-r", &hash(2), 400, 1000, 86_400_000)
        .unwrap();
    assert!(state.reserve_submission(&hash(2), 401, 86_400_000).is_err());
    assert_eq!(state.spending(1).unwrap(), (600, 400, 0));
}
#[test]
fn invoice_hash_never_changes_owner_and_submitted_hash_never_resubmits() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state.authorize("r", &hash(1), 100, 500, 0).unwrap();
    state.reserve_submission(&hash(1), 110, 0).unwrap();
    assert!(state.reserve_submission(&hash(1), 110, 0).is_err());
    state.end("a").unwrap();
    state.reconcile(&hash(1), 100, 10, true, 0).unwrap();
    begin(&mut state, "b", "s");
    assert!(state.bind("r").is_err());
    assert!(state.authorize("s", &hash(1), 100, 500, 0).is_err());
    assert!(state.authorize("r", &hash(1), 101, 500, 0).is_err());
}
#[test]
fn terminal_reconciliation_releases_failed_reservation_and_is_idempotent() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state.authorize("r", &hash(1), 100, 500, 0).unwrap();
    state.reserve_submission(&hash(1), 120, 0).unwrap();
    state.reconcile(&hash(1), 100, 0, false, 0).unwrap();
    assert_eq!(state.spending(0).unwrap(), (0, 0, 0));
    state.reconcile(&hash(1), 100, 0, false, 0).unwrap();
    assert!(state.reconcile(&hash(1), 100, 20, true, 0).is_err());
}
#[test]
fn closing_unsent_authorization_releases_only_its_reservation_and_revokes_sending() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state.authorize("r", &hash(1), 100, 500, 0).unwrap();
    state.authorize("r", &hash(2), 100, 500, 0).unwrap();
    state.reserve_submission(&hash(2), 110, 0).unwrap();
    state.end("a").unwrap();
    assert_eq!(state.spending(0).unwrap(), (0, 110, 1));
    assert!(state.reserve_submission(&hash(1), 105, 0).is_err());
    assert!(state.authorize("r", &hash(3), 100, 500, 0).is_err());
    assert_eq!(state.spending(0).unwrap(), (0, 110, 1));
}
#[test]
fn persistence_failure_rolls_back_authorization_before_network_can_run() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    context
        .change(|state| {
            *state = ready_state();
            Ok(())
        })
        .unwrap();
    context.begin_request("a").unwrap();
    context.bind_request("r").unwrap();
    store.fail.store(true, Ordering::SeqCst);
    assert!(
        context
            .change(|s| s.authorize("r", &hash(1), 100, 500, 0))
            .is_err()
    );
    assert!(context.read(|s| s.invoices.is_empty()).unwrap());
}
#[test]
fn restart_closes_scope_but_preserves_unknown_reservation_and_identity() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    context
        .change(|s| {
            *s = ready_state();
            begin(s, "a", "r");
            s.authorize("r", &hash(1), 100, 500, 0)?;
            s.reserve_submission(&hash(1), 110, 0)
        })
        .unwrap();
    synthetic_ledger_marker(directory.path());
    drop(context);
    let restored = WalletContext::new_with_store(directory.path(), store).unwrap();
    assert!(restored.read(|s| s.active_scope.is_none()).unwrap());
    assert_eq!(restored.snapshot().unwrap()["reserved_msat"], 110);
    assert_eq!(restored.snapshot().unwrap()["pending_count"], 1);
    assert!(restored.bind_request("new-r").is_err());
}
#[test]
fn passive_snapshot_and_factory_never_generate_seed_or_open_wallet() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    let snapshot = context.snapshot().unwrap();
    assert_eq!(snapshot["provisioned"], false);
    assert_eq!(snapshot["ready"], false);
    assert_eq!(snapshot["balance_msat"], Value::Null);
    assert!(!context.factory().is_provisioned(directory.path()));
    assert!(store.load().unwrap().is_none());
    assert!(context.read(|s| s.seed.is_none()).unwrap());
}
#[test]
fn clock_rollback_cannot_reset_daily_spending() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state
        .authorize("r", &hash(1), 100, 500, 86_400_000)
        .unwrap();
    state.reserve_submission(&hash(1), 110, 86_400_000).unwrap();
    state
        .reconcile(&hash(1), 100, 10, true, 86_400_000)
        .unwrap();
    assert_eq!(state.day(0), 1);
    assert_eq!(state.spending(state.day(0)).unwrap(), (110, 0, 0));
}
#[test]
fn namespace_is_separate_from_signal_and_requires_stable_account_hash() {
    assert!(store::validate_namespace(&"a".repeat(64)).is_ok());
    assert!(store::validate_namespace("production").is_err());
    assert!(store::validate_namespace(&"A".repeat(64)).is_err());
}
#[tokio::test]
async fn real_sdk_without_database_constructs_with_ephemeral_seed_only() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let seed = RootSeed::generate();
    let wallet =
        LexeWallet::without_db(WalletEnvConfig::mainnet(), CredentialsRef::from(&seed)).unwrap();
    assert!(!wallet.user_config().user_pk.to_string().is_empty());
    // No signup, node request, funding, filesystem SDK cache or payment.
}

#[tokio::test]
async fn drain_counts_admitted_task_before_it_is_scheduled_and_fences_new_work() {
    let directory = tempfile::tempdir().unwrap();
    let context =
        WalletContext::new_with_store(directory.path(), Arc::new(MemoryStore::default())).unwrap();
    let admitted = context.admit_submission().unwrap(); // no spawned task has run
    let draining_context = Arc::clone(&context);
    let draining = tokio::spawn(async move { draining_context.drain().await });
    tokio::task::yield_now().await;
    assert!(!draining.is_finished());
    assert!(context.admit_submission().is_err());
    assert!(context.bind_request("late-seller-request").is_err());
    drop(admitted);
    draining.await.unwrap().unwrap();
    assert!(context.admit_submission().is_err());
    assert!(context.begin_request("late-invocation").is_err());
}

#[test]
fn delayed_preflight_cannot_commit_submission_after_stop_fence() {
    let directory = tempfile::tempdir().unwrap();
    let context =
        WalletContext::new_with_store(directory.path(), Arc::new(MemoryStore::default())).unwrap();
    context
        .change(|s| {
            *s = ready_state();
            begin(s, "a", "r");
            s.authorize("r", &hash(1), 100, 500, 0)
        })
        .unwrap();
    context.fence_new_payments();
    assert!(context.reserve_submission(&hash(1), 110).is_err());
    assert!(
        context
            .read(|s| s.invoices[&hash(1)].phase == Phase::Authorized)
            .unwrap()
    );
    context.release_unsubmitted(&hash(1)).unwrap();
    assert_eq!(context.snapshot().unwrap()["reserved_msat"], 0);
}

#[test]
fn service_rejection_can_release_only_a_provably_unsubmitted_reservation() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state.authorize("r", &hash(1), 100, 500, 0).unwrap();
    state.authorize("r", &hash(2), 100, 500, 0).unwrap();
    state.reserve_submission(&hash(2), 110, 0).unwrap();
    state.release_unsubmitted(&hash(1)).unwrap();
    state.release_unsubmitted(&hash(2)).unwrap();
    assert_eq!(state.spending(0).unwrap(), (0, 110, 1));
}

#[test]
fn corrupt_protected_state_never_regenerates_a_seed() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    store.store(b"corrupt synthetic state").unwrap();
    assert!(WalletContext::new_with_store(directory.path(), store.clone()).is_err());
    assert_eq!(
        store.load().unwrap().unwrap().as_slice(),
        b"corrupt synthetic state"
    );
}

#[test]
fn restored_payment_ledger_without_keychain_identity_never_creates_new_wallet() {
    let directory = tempfile::tempdir().unwrap();
    let pin = WalletPin {
        plugin: PROVIDER_ID.into(),
        wallet_id: "synthetic-prior-wallet".into(),
        provider: "lexe".into(),
        network: "mainnet".into(),
    };
    pin.store(&directory.path().join("payments")).unwrap();
    let store = Arc::new(MemoryStore::default());
    assert!(WalletContext::new_with_store(directory.path(), store.clone()).is_err());
    assert!(store.load().unwrap().is_none());
}

#[test]
fn violation_of_route_fee_guarantee_blocks_all_new_spending_durably() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    context
        .change(|s| {
            *s = ready_state();
            begin(s, "a", "r");
            s.authorize("r", &hash(1), 100, 500, 0)?;
            s.reserve_submission(&hash(1), 110, 0)
        })
        .unwrap();
    let payment = Transaction {
        id: "synthetic-payment".into(),
        payment_hash: Some(hash(1)),
        inbound: false,
        amount_msat: 100,
        fee_msat: 11,
        status: PaymentStatus::Succeeded,
        claiming: false,
        status_msg: None,
        created_at_ms: 0,
        settled_at_ms: Some(0),
    };
    assert!(context.observe(&hash(1), &payment).is_err());
    assert_eq!(context.snapshot().unwrap()["ready"], false);
    assert_eq!(context.snapshot().unwrap()["reconciliation_required"], true);
    context.end_request("a").unwrap();
    assert!(context.begin_request("b").is_err());
    synthetic_ledger_marker(directory.path());
    drop(context);
    let restored = WalletContext::new_with_store(directory.path(), store).unwrap();
    assert!(restored.begin_request("c").is_err());
}

#[test]
fn cancellation_during_reservation_persistence_retires_known_unsent_payment() {
    #[derive(Default)]
    struct FencingStore {
        memory: MemoryStore,
        target: Mutex<Option<std::sync::Weak<WalletContext>>>,
    }
    impl ProtectedStore for FencingStore {
        fn load(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
            self.memory.load()
        }
        fn store(&self, value: &[u8]) -> Result<()> {
            self.memory.store(value)?;
            if let Some(context) = self
                .target
                .lock()
                .unwrap()
                .as_ref()
                .and_then(std::sync::Weak::upgrade)
            {
                context.fence_new_payments();
            }
            Ok(())
        }
    }
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(FencingStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    context
        .change(|s| {
            *s = ready_state();
            begin(s, "a", "r");
            s.authorize("r", &hash(1), 100, 500, 0)
        })
        .unwrap();
    *store.target.lock().unwrap() = Some(Arc::downgrade(&context));
    assert!(context.reserve_submission(&hash(1), 110).is_err());
    assert!(
        context
            .read(|s| s.invoices[&hash(1)].phase == Phase::Failed)
            .unwrap()
    );
    assert_eq!(context.snapshot().unwrap()["reserved_msat"], 0);
    assert_eq!(context.snapshot().unwrap()["pending_count"], 0);
}

#[test]
fn new_scope_waits_for_authoritative_terminal_result_of_previous_submission() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state.authorize("r", &hash(1), 100, 500, 0).unwrap();
    state.reserve_submission(&hash(1), 110, 0).unwrap();
    state.end("a").unwrap();
    assert!(state.begin("b").is_err());
    state.reconcile(&hash(1), 100, 0, false, 0).unwrap();
    assert!(state.begin("b").is_ok());
}

#[test]
fn completed_payment_without_full_principal_cannot_understate_spending() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    state.authorize("r", &hash(1), 100, 500, 0).unwrap();
    state.reserve_submission(&hash(1), 110, 0).unwrap();
    assert!(state.reconcile(&hash(1), 0, 0, true, 0).is_err());
    assert_eq!(state.spending(0).unwrap(), (0, 110, 1));
}

#[test]
fn finishing_fences_admissions_but_allows_only_original_final_settlement() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    assert_eq!(state.finish_request("a").unwrap(), vec!["r"]);
    assert!(state.bind("new-r").is_err());
    assert!(state.authorize("r", &hash(1), 100, 500, 0).is_err());
    assert!(
        state
            .authorize_final("unknown-r", &hash(1), 100, 500, 0)
            .is_err()
    );
    state.authorize_final("r", &hash(1), 100, 500, 0).unwrap();
    state.reserve_submission(&hash(1), 110, 0).unwrap();
    state.reconcile(&hash(1), 100, 10, true, 0).unwrap();
    state.end("a").unwrap();
    assert!(state.authorize_final("r", &hash(2), 100, 500, 0).is_err());
    assert!(state.begin("next").is_ok());
}

#[test]
fn orphaned_uninvoiced_obligation_stays_visible_and_recovers_only_under_original_scope() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    context
        .change(|s| {
            *s = ready_state();
            begin(s, "original", "accepted-r");
            s.finish_request("original")?;
            Ok(())
        })
        .unwrap();
    synthetic_ledger_marker(directory.path());
    drop(context);
    let context = WalletContext::new_with_store(directory.path(), store).unwrap();
    assert_eq!(context.snapshot().unwrap()["pending_count"], 0);
    assert_eq!(context.snapshot().unwrap()["pending_scope_count"], 1);
    assert_eq!(context.snapshot().unwrap()["reconciliation_required"], true);
    assert!(context.begin_request("new-scope").is_err());
    assert_eq!(
        context.unresolved_scopes().unwrap(),
        vec![("original".into(), vec!["accepted-r".into()])]
    );
    context.set_budget(5000, 5000).unwrap();
    context.resume_recovery_scope("original").unwrap();
    assert!(context.bind_request("new-r").is_err());
    assert!(
        context
            .change(|s| s.authorize_final("accepted-r", &hash(1), 601, 1000, 0))
            .is_err()
    );
    context
        .change(|s| {
            s.authorize_final("accepted-r", &hash(1), 100, 1000, 0)?;
            s.reserve_submission(&hash(1), 110, 0)?;
            s.reconcile(&hash(1), 100, 10, true, 0)
        })
        .unwrap();
    context.end_request("original").unwrap();
    assert!(context.unresolved_scopes().unwrap().is_empty());
    assert!(context.begin_request("new-scope").is_ok());
}

#[test]
fn increasing_settings_never_enlarges_original_daily_authority_during_recovery() {
    let mut state = ready_state();
    state.per_request_budget_msat = 1000;
    begin(&mut state, "prior", "prior-r");
    state.authorize("prior-r", &hash(1), 400, 1000, 0).unwrap();
    state.reserve_submission(&hash(1), 400, 0).unwrap();
    state.reconcile(&hash(1), 400, 0, true, 0).unwrap();
    state.end("prior").unwrap();
    begin(&mut state, "original", "r");
    state.finish_request("original").unwrap();
    state.orphan_active().unwrap();
    state.daily_budget_msat = 5000;
    state.per_request_budget_msat = 5000;
    state.resume_recovery_scope("original").unwrap();
    let mut rejected = state.clone();
    assert!(
        rejected
            .authorize_final("r", &hash(2), 601, 5000, 0)
            .is_err()
    );
    state.authorize_final("r", &hash(2), 599, 5000, 0).unwrap();
    assert!(state.reserve_submission(&hash(2), 601, 0).is_err());
    state.reserve_submission(&hash(2), 600, 0).unwrap();
}

#[test]
fn native_buyer_key_is_stable_private_and_never_generated_by_snapshot() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    assert!(context.node_key_bytes().is_err());
    assert!(store.load().unwrap().is_none());
    context
        .change(|s| {
            *s = ready_state();
            s.node_secret = Some(vec![7; 32]);
            Ok(())
        })
        .unwrap();
    assert_eq!(context.node_key_bytes().unwrap(), [7; 32]);
    drop(context);
    let restored = WalletContext::new_with_store(directory.path(), store).unwrap();
    assert_eq!(restored.node_key_bytes().unwrap(), [7; 32]);
    assert!(
        !restored
            .snapshot()
            .unwrap()
            .to_string()
            .contains("node_secret")
    );
    assert!(!restored.snapshot().unwrap().to_string().contains("seed"));
}

#[test]
fn missing_engine_ledger_cannot_prove_durable_bound_request_was_abandoned() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store.clone()).unwrap();
    context
        .change(|s| {
            *s = ready_state();
            begin(s, "a", "r");
            Ok(())
        })
        .unwrap();
    drop(context);
    assert!(WalletContext::new_with_store(directory.path(), store).is_err());
}

#[test]
fn permanent_user_fence_cannot_be_reopened_even_for_recovery() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let context = WalletContext::new_with_store(directory.path(), store).unwrap();
    context
        .change(|s| {
            *s = ready_state();
            begin(s, "a", "r");
            s.finish_request("a")?;
            Ok(())
        })
        .unwrap();
    context.fence_new_payments();
    assert!(context.resume_recovery_scope("a").is_err());
    assert_eq!(context.snapshot().unwrap()["reconciliation_required"], true);
}

#[test]
fn explicit_unaccepted_receipt_excludes_wait_but_preserves_permanent_ownership() {
    let mut state = ready_state();
    begin(&mut state, "a", "rejected-r");
    state.mark_unaccepted("rejected-r").unwrap();
    assert!(state.finish_request("a").unwrap().is_empty());
    assert!(
        state
            .authorize_final("rejected-r", &hash(1), 100, 1000, 0)
            .is_err()
    );
    state.end("a").unwrap();
    state.begin("b").unwrap();
    assert!(state.bind("rejected-r").is_err());
}

#[test]
fn unknown_or_invoiced_admission_cannot_be_marked_unaccepted() {
    let mut state = ready_state();
    begin(&mut state, "a", "r");
    assert!(state.mark_unaccepted("unknown-r").is_err());
    state.authorize("r", &hash(1), 100, 1000, 0).unwrap();
    assert!(state.mark_unaccepted("r").is_err());
    state.reserve_submission(&hash(1), 110, 0).unwrap();
    assert!(state.mark_unaccepted("r").is_err());
}

#[test]
fn unaccepted_receipt_survives_restart_but_unknown_absence_does_not() {
    let mut state = ready_state();
    begin(&mut state, "a", "rejected-r");
    state.bind("unknown-r").unwrap();
    state.mark_unaccepted("rejected-r").unwrap();
    state.orphan_active().unwrap();
    assert_eq!(state.bound_request_ids("a").unwrap(), vec!["unknown-r"]);
    assert!(state.scopes["a"].obligation_pending);
    let copy: State = serde_json::from_slice(&serde_json::to_vec(&state).unwrap()).unwrap();
    assert_eq!(copy.bound_request_ids("a").unwrap(), vec!["unknown-r"]);
    assert!(copy.unaccepted.contains("rejected-r"));
}

#[test]
fn zero_or_reduced_current_recovery_limits_never_enlarge_old_authority() {
    let mut state = ready_state();
    begin(&mut state, "original", "r");
    state.authorize_final("r", &hash(1), 100, 1000, 0).unwrap();
    state.reserve_submission(&hash(1), 110, 0).unwrap();
    state.finish_request("original").unwrap();
    state.orphan_active().unwrap();
    state.daily_budget_msat = 0;
    state.per_request_budget_msat = 0;
    state.resume_recovery_scope("original").unwrap();
    let mut attempt = state.clone();
    assert!(attempt.authorize_final("r", &hash(2), 1, 1000, 0).is_err());
    assert!(state.reserve_submission(&hash(1), 110, 0).is_err()); // never resubmit unknown
    state.reconcile(&hash(1), 100, 10, true, 0).unwrap(); // prior payment may be observed at zero
    state.daily_budget_msat = 1000;
    state.per_request_budget_msat = 200;
    state.authorize_final("r", &hash(2), 80, 1000, 0).unwrap();
    assert!(state.reserve_submission(&hash(2), 91, 0).is_err()); // prior debit + new fee > current cap
    state.reserve_submission(&hash(2), 90, 0).unwrap();
}
