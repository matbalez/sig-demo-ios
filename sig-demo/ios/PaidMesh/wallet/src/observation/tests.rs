use super::*;
use std::{
    collections::VecDeque,
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

struct ReadOnlySource {
    payment: Option<ObservedPayment>,
    balance: Option<u64>,
    pages: Mutex<VecDeque<SourcePage>>,
    balance_reads: AtomicUsize,
    history_reads: AtomicUsize,
    expected_hash: String,
}
impl ReadOnlySource {
    fn new(payment: Option<ObservedPayment>) -> Self {
        Self {
            payment,
            balance: Some(70_000),
            pages: Mutex::new(VecDeque::new()),
            balance_reads: AtomicUsize::new(0),
            history_reads: AtomicUsize::new(0),
            expected_hash: "ab".repeat(32),
        }
    }
    fn with_pages(pages: Vec<SourcePage>) -> Self {
        let source = Self::new(None);
        *source.pages.lock().unwrap() = pages.into();
        source
    }
}
#[async_trait]
impl ObservationSource for ReadOnlySource {
    async fn balance_msat(&self) -> Result<u64> {
        self.balance_reads.fetch_add(1, Ordering::SeqCst);
        self.balance.context("synthetic balance failure")
    }
    async fn payment(&self, hash: &str) -> Result<Option<ObservedPayment>> {
        assert_eq!(
            hash, self.expected_hash,
            "must query the exact requested invoice"
        );
        Ok(self.payment.clone())
    }
    async fn page(&self, _: Option<&str>, limit: usize) -> Result<SourcePage> {
        assert!((1..=100).contains(&limit));
        self.history_reads.fetch_add(1, Ordering::SeqCst);
        self.pages
            .lock()
            .unwrap()
            .pop_front()
            .context("unexpected extra history query")
    }
}
fn payment(
    id: &str,
    direction: Direction,
    status: Status,
    created: u64,
    confirmed: Option<u64>,
    amount: Option<u64>,
) -> ObservedPayment {
    ObservedPayment {
        entry: HistoryEntry {
            id: id.into(),
            payment_hash: Some("ab".repeat(32)),
            direction,
            status,
            amount_msat: amount,
            fee_msat: 250,
            created_at_ms: created,
            confirmed_at_ms: confirmed,
        },
        updated_at_ms: confirmed.unwrap_or(created),
        expires_at_ms: Some(100),
        is_invoice: true,
        supported_funding: true,
    }
}

#[tokio::test]
async fn exact_paid_invoice_uses_actual_received_principal_and_fresh_balance() {
    let source = ReadOnlySource::new(Some(payment(
        "paid",
        Direction::Inbound,
        Status::Completed,
        1,
        Some(80),
        Some(10_001),
    )));
    let result = funding_status(&source, &"ab".repeat(32), 200)
        .await
        .unwrap();
    assert_eq!(result.state, FundingState::Paid); // Completed wins even after expiry.
    assert_eq!(result.received_msat, Some(10_001)); // Do not subtract the separate fee again.
    assert_eq!(result.confirmed_at_ms, Some(80));
    assert_eq!(result.balance_msat, 70_000);
    assert_eq!(source.balance_reads.load(Ordering::SeqCst), 1);
    assert_eq!(source.history_reads.load(Ordering::SeqCst), 0); // No truncated history inference.
}

#[tokio::test]
async fn unpaid_expired_failed_and_missing_invoice_cannot_become_paid() {
    let pending = payment(
        "pending",
        Direction::Inbound,
        Status::Pending,
        1,
        None,
        Some(99_000),
    );
    let source = ReadOnlySource::new(Some(pending));
    let result = funding_status(&source, &"ab".repeat(32), 50).await.unwrap();
    assert_eq!(result.state, FundingState::Pending);
    assert_eq!(result.received_msat, None);
    assert_eq!(
        funding_status(&source, &"ab".repeat(32), 100)
            .await
            .unwrap()
            .state,
        FundingState::Expired
    );
    let source = ReadOnlySource::new(Some(payment(
        "failed",
        Direction::Inbound,
        Status::Failed,
        1,
        None,
        Some(99_000),
    )));
    assert_eq!(
        funding_status(&source, &"ab".repeat(32), 200)
            .await
            .unwrap()
            .state,
        FundingState::Failed
    );
    assert!(
        funding_status(&ReadOnlySource::new(None), &"ab".repeat(32), 200)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn unrelated_outgoing_noninvoice_or_unconfirmed_receipt_is_rejected() {
    let paid = payment(
        "paid",
        Direction::Inbound,
        Status::Completed,
        1,
        Some(2),
        Some(5_000),
    );
    for kind in 0..5 {
        let mut invalid = paid.clone();
        match kind {
            0 => invalid.entry.payment_hash = Some("cd".repeat(32)),
            1 => invalid.entry.direction = Direction::Outbound,
            2 => invalid.is_invoice = false,
            3 => invalid.entry.amount_msat = None,
            _ => invalid.entry.confirmed_at_ms = None,
        }
        let source = ReadOnlySource::new(Some(invalid));
        assert!(funding_status(&source, &"ab".repeat(32), 3).await.is_err());
        assert_eq!(source.balance_reads.load(Ordering::SeqCst), 0);
    }
}

#[tokio::test]
async fn paid_status_does_not_claim_balance_refresh_when_that_read_failed() {
    let mut source = ReadOnlySource::new(Some(payment(
        "paid",
        Direction::Inbound,
        Status::Completed,
        1,
        Some(2),
        Some(5_000),
    )));
    source.balance = None;
    assert!(funding_status(&source, &"ab".repeat(32), 3).await.is_err());
}

#[tokio::test]
async fn earliest_funding_uses_completion_order_not_invoice_creation_or_balance() {
    let source = ReadOnlySource::with_pages(vec![SourcePage {
        payments: vec![
            payment(
                "created-first-paid-later",
                Direction::Inbound,
                Status::Completed,
                1,
                Some(20),
                Some(9_000),
            ),
            payment(
                "paid-first",
                Direction::Inbound,
                Status::Completed,
                2,
                Some(10),
                Some(5_001),
            ),
            payment(
                "outgoing",
                Direction::Outbound,
                Status::Completed,
                0,
                Some(1),
                Some(99_000),
            ),
            payment(
                "info",
                Direction::Info,
                Status::Completed,
                0,
                Some(1),
                Some(99_000),
            ),
            payment(
                "unpaid",
                Direction::Inbound,
                Status::Pending,
                0,
                None,
                Some(99_000),
            ),
        ],
        cursor: Some("end".into()),
    }]);
    let result = confirmed_funding(&source).await.unwrap();
    assert!(result.history_complete);
    let initial = result.initial_funding.unwrap();
    assert_eq!(initial.id, "paid-first");
    assert_eq!(initial.amount_msat, 5_001);
    assert_eq!(initial.confirmed_at_ms, 10);
    assert_eq!(source.balance_reads.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn malformed_or_truncated_history_provides_no_automatic_spending_basis() {
    for malformed in [
        payment(
            "missing-amount",
            Direction::Inbound,
            Status::Completed,
            1,
            Some(2),
            None,
        ),
        payment(
            "missing-time",
            Direction::Inbound,
            Status::Completed,
            1,
            None,
            Some(5_000),
        ),
    ] {
        let source = ReadOnlySource::with_pages(vec![SourcePage {
            payments: vec![malformed],
            cursor: None,
        }]);
        let summary = confirmed_funding(&source).await.unwrap();
        assert!(!summary.history_complete && summary.initial_funding.is_none());
    }
    let pages = (0..10)
        .map(|page| SourcePage {
            payments: (0..100)
                .map(|row| {
                    payment(
                        &format!("{page}-{row}"),
                        Direction::Inbound,
                        Status::Completed,
                        1,
                        Some(2),
                        Some(5_000),
                    )
                })
                .collect(),
            cursor: Some(format!("page-{page}")),
        })
        .collect();
    let source = ReadOnlySource::with_pages(pages);
    let summary = confirmed_funding(&source).await.unwrap();
    assert!(!summary.history_complete && summary.initial_funding.is_none());
    assert_eq!(source.history_reads.load(Ordering::SeqCst), 10);
}

#[tokio::test]
async fn unsupported_completed_inbound_never_initializes_limits() {
    let mut unsupported = payment(
        "future-rail",
        Direction::Inbound,
        Status::Completed,
        1,
        Some(2),
        Some(5_000),
    );
    unsupported.supported_funding = false;
    let source = ReadOnlySource::with_pages(vec![SourcePage {
        payments: vec![unsupported],
        cursor: None,
    }]);
    let summary = confirmed_funding(&source).await.unwrap();
    assert!(!summary.history_complete && summary.initial_funding.is_none());
}

#[tokio::test]
async fn history_pagination_is_bounded_and_requires_forward_progress() {
    let source = ReadOnlySource::with_pages(vec![SourcePage {
        payments: vec![payment(
            "one",
            Direction::Inbound,
            Status::Pending,
            1,
            None,
            Some(1_000),
        )],
        cursor: Some("same".into()),
    }]);
    assert!(history(&source, Some("same"), 1).await.is_err());
    assert!(history(&source, None, 0).await.is_err());
    assert!(history(&source, None, 101).await.is_err());
    let source = ReadOnlySource::with_pages(vec![SourcePage {
        payments: vec![],
        cursor: None,
    }]);
    let empty = history(&source, None, 50).await.unwrap();
    assert!(!empty.has_more && empty.next_cursor.is_none());
}

#[test]
fn history_projection_excludes_invoice_secrets_notes_and_counterparties() {
    let row = payment(
        "stable-id",
        Direction::Inbound,
        Status::Completed,
        1,
        Some(2),
        Some(5_000),
    )
    .entry;
    let value = serde_json::to_value(row).unwrap();
    let mut keys = value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    keys.sort();
    assert_eq!(
        keys,
        [
            "amount_msat",
            "confirmed_at_ms",
            "created_at_ms",
            "direction",
            "fee_msat",
            "id",
            "payment_hash",
            "status"
        ]
    );
    assert!(parse_cursor(Some(&"x".repeat(513))).is_err());
    assert!(parse_cursor(Some("\n")).is_err());
    assert!(parse_cursor(Some("{} unexpected")).is_err());
}
