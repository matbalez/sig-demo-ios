//! Read-only wallet queries. This boundary deliberately has no provisioning,
//! recovery, authorization, or payment-submission operation.

use anyhow::{Context, Result, ensure};
use async_trait::async_trait;
use lexe::{
    types::payment::{
        Payment, PaymentDirection, PaymentHash, PaymentKind, PaymentRail, PaymentStatus,
        PaymentUpdatedIndex,
    },
    wallet::LexeWallet,
};
use lexe_api_core::{
    def::UserNodeRunApi,
    models::command::{GetUpdatedPayments, PaymentIdStruct},
    types::payments::PaymentId,
};
use serde::Serialize;
use std::collections::BTreeMap;

const PAGE_LIMIT: usize = 100;
const SUMMARY_PAGES: usize = 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Inbound,
    Outbound,
    Info,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pending,
    Completed,
    Failed,
}

#[derive(Clone, Debug, Serialize)]
pub struct HistoryEntry {
    pub id: String,
    pub payment_hash: Option<String>,
    pub direction: Direction,
    pub status: Status,
    pub amount_msat: Option<u64>,
    pub fee_msat: u64,
    pub created_at_ms: u64,
    pub confirmed_at_ms: Option<u64>,
}

#[derive(Clone)]
pub(crate) struct ObservedPayment {
    pub entry: HistoryEntry,
    pub updated_at_ms: u64,
    pub expires_at_ms: Option<u64>,
    pub is_invoice: bool,
    pub supported_funding: bool,
}

impl From<Payment> for ObservedPayment {
    fn from(value: Payment) -> Self {
        let status = match value.status {
            PaymentStatus::Pending => Status::Pending,
            PaymentStatus::Completed => Status::Completed,
            PaymentStatus::Failed => Status::Failed,
        };
        Self {
            entry: HistoryEntry {
                id: value.index.to_string(),
                payment_hash: value.hash.map(|hash| hash.to_string()),
                direction: match value.direction {
                    PaymentDirection::Inbound => Direction::Inbound,
                    PaymentDirection::Outbound => Direction::Outbound,
                    PaymentDirection::Info => Direction::Info,
                },
                status,
                amount_msat: value.amount.map(|amount| amount.msat()),
                fee_msat: value.fees.msat(),
                created_at_ms: value.created_at.to_millis(),
                // A failed payment's finalized_at is not a confirmation.
                confirmed_at_ms: (status == Status::Completed)
                    .then_some(value.finalized_at.map(|time| time.to_millis()))
                    .flatten(),
            },
            updated_at_ms: value.updated_at.to_millis(),
            expires_at_ms: value.expires_at.map(|time| time.to_millis()),
            is_invoice: value.rail == PaymentRail::Invoice && value.kind == PaymentKind::Invoice,
            supported_funding: !matches!(
                value.rail,
                PaymentRail::Unknown(_) | PaymentRail::WaivedFee
            ) && !matches!(value.kind, PaymentKind::Unknown(_)),
        }
    }
}

pub(crate) struct SourcePage {
    pub payments: Vec<ObservedPayment>,
    pub cursor: Option<String>,
}

#[async_trait]
pub(crate) trait ObservationSource: Sync {
    async fn balance_msat(&self) -> Result<u64>;
    async fn payment(&self, hash: &str) -> Result<Option<ObservedPayment>>;
    async fn page(&self, cursor: Option<&str>, limit: usize) -> Result<SourcePage>;
}

pub(crate) struct LexeObservation<'a>(pub &'a LexeWallet);
#[async_trait]
impl ObservationSource for LexeObservation<'_> {
    async fn balance_msat(&self) -> Result<u64> {
        self.0
            .node_info()
            .await
            .map(|info| info.lightning_sendable_balance.msat())
            .map_err(|_| anyhow::anyhow!("wallet balance query failed"))
    }
    async fn payment(&self, hash: &str) -> Result<Option<ObservedPayment>> {
        super::guard::validate_hash(hash)?;
        let hash: PaymentHash = hash
            .parse()
            .map_err(|_| anyhow::anyhow!("invalid payment hash"))?;
        let id = PaymentId::Lightning(hash);
        let response = self
            .0
            .node_client()
            .get_payment_by_id(PaymentIdStruct { id: id.clone() })
            .await
            .map_err(|_| anyhow::anyhow!("wallet invoice status query failed"))?;
        response
            .maybe_payment
            .map(|payment| {
                ensure!(payment.id == id, "wallet returned an unrelated payment ID");
                Ok(ObservedPayment::from(Payment::from(payment)))
            })
            .transpose()
    }
    async fn page(&self, cursor: Option<&str>, limit: usize) -> Result<SourcePage> {
        let start_index = parse_cursor(cursor)?;
        let response = self
            .0
            .node_client()
            .get_updated_payments(GetUpdatedPayments {
                start_index,
                limit: Some(u16::try_from(limit)?),
            })
            .await
            .map_err(|_| anyhow::anyhow!("wallet history query failed"))?;
        let cursor = response
            .payments
            .last()
            .map(|payment| serde_json::to_string(&payment.updated_index()))
            .transpose()?;
        Ok(SourcePage {
            payments: response
                .payments
                .into_iter()
                .map(Payment::from)
                .map(ObservedPayment::from)
                .collect(),
            cursor,
        })
    }
}

pub(crate) fn parse_cursor(cursor: Option<&str>) -> Result<Option<PaymentUpdatedIndex>> {
    cursor
        .map(|cursor| {
            ensure!(
                !cursor.is_empty() && cursor.len() <= 512 && !cursor.chars().any(char::is_control),
                "invalid history cursor"
            );
            serde_json::from_str(cursor).map_err(|_| anyhow::anyhow!("invalid history cursor"))
        })
        .transpose()
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FundingState {
    Pending,
    Paid,
    Expired,
    Failed,
}

#[derive(Serialize)]
pub struct FundingObservation {
    pub payment_hash: String,
    pub state: FundingState,
    pub received_msat: Option<u64>,
    pub confirmed_at_ms: Option<u64>,
    pub balance_msat: u64,
}

pub(crate) async fn funding_status(
    source: &impl ObservationSource,
    hash: &str,
    now_ms: u64,
) -> Result<FundingObservation> {
    super::guard::validate_hash(hash)?;
    let payment = source
        .payment(hash)
        .await?
        .context("funding invoice was not found")?;
    ensure!(
        payment.entry.payment_hash.as_deref() == Some(hash)
            && payment.entry.direction == Direction::Inbound
            && payment.is_invoice,
        "wallet returned an unrelated funding invoice"
    );
    let (state, received_msat, confirmed_at_ms) = match payment.entry.status {
        Status::Completed => {
            let amount = payment
                .entry
                .amount_msat
                .filter(|amount| *amount > 0)
                .context("funding receipt amount is unavailable")?;
            let confirmed = payment
                .entry
                .confirmed_at_ms
                .context("funding confirmation time is unavailable")?;
            (FundingState::Paid, Some(amount), Some(confirmed))
        }
        Status::Failed => (FundingState::Failed, None, None),
        Status::Pending if payment.expires_at_ms.is_some_and(|expiry| now_ms >= expiry) => {
            (FundingState::Expired, None, None)
        }
        Status::Pending => (FundingState::Pending, None, None),
    };
    // A successful paid response promises a fresh balance, not merely a cached
    // value. Failure here keeps the observer retrying without claiming refresh.
    let balance_msat = source.balance_msat().await?;
    Ok(FundingObservation {
        payment_hash: hash.into(),
        state,
        received_msat,
        confirmed_at_ms,
        balance_msat,
    })
}

#[derive(Serialize)]
pub struct HistoryPage {
    pub transactions: Vec<HistoryEntry>,
    pub next_cursor: Option<String>,
    pub has_more: bool,
}

pub(crate) async fn history(
    source: &impl ObservationSource,
    cursor: Option<&str>,
    limit: usize,
) -> Result<HistoryPage> {
    ensure!(
        (1..=PAGE_LIMIT).contains(&limit),
        "invalid wallet history limit"
    );
    let page = source.page(cursor, limit).await?;
    ensure!(
        page.payments.len() <= limit,
        "wallet exceeded history limit"
    );
    let has_more = page.payments.len() == limit;
    if has_more {
        ensure!(
            page.cursor.is_some() && page.cursor.as_deref() != cursor,
            "wallet history cursor did not advance"
        );
    }
    Ok(HistoryPage {
        transactions: page
            .payments
            .into_iter()
            .map(|payment| payment.entry)
            .collect(),
        next_cursor: has_more.then_some(page.cursor).flatten(),
        has_more,
    })
}

#[derive(Clone, Serialize)]
pub struct ConfirmedFunding {
    pub id: String,
    pub amount_msat: u64,
    pub confirmed_at_ms: u64,
}
#[derive(Serialize)]
pub struct FundingSummary {
    pub initial_funding: Option<ConfirmedFunding>,
    pub history_complete: bool,
}

pub(crate) async fn confirmed_funding(source: &impl ObservationSource) -> Result<FundingSummary> {
    let mut cursor = None;
    let mut entries = BTreeMap::<String, ObservedPayment>::new();
    for _ in 0..SUMMARY_PAGES {
        let page = source.page(cursor.as_deref(), PAGE_LIMIT).await?;
        ensure!(
            page.payments.len() <= PAGE_LIMIT,
            "wallet exceeded history limit"
        );
        let complete = page.payments.len() < PAGE_LIMIT;
        for payment in page.payments {
            let slot = entries
                .entry(payment.entry.id.clone())
                .or_insert_with(|| payment.clone());
            if payment.updated_at_ms >= slot.updated_at_ms {
                *slot = payment;
            }
        }
        if complete {
            let mut funding = Vec::new();
            for payment in entries.into_values() {
                if payment.entry.direction != Direction::Inbound
                    || payment.entry.status != Status::Completed
                {
                    continue;
                }
                if !payment.supported_funding {
                    return Ok(FundingSummary {
                        initial_funding: None,
                        history_complete: false,
                    });
                }
                let Some(amount) = payment.entry.amount_msat.filter(|amount| *amount > 0) else {
                    return Ok(FundingSummary {
                        initial_funding: None,
                        history_complete: false,
                    });
                };
                let Some(confirmed) = payment.entry.confirmed_at_ms else {
                    return Ok(FundingSummary {
                        initial_funding: None,
                        history_complete: false,
                    });
                };
                funding.push(ConfirmedFunding {
                    id: payment.entry.id,
                    amount_msat: amount,
                    confirmed_at_ms: confirmed,
                });
            }
            funding.sort_by(|a, b| (a.confirmed_at_ms, &a.id).cmp(&(b.confirmed_at_ms, &b.id)));
            return Ok(FundingSummary {
                initial_funding: funding.into_iter().next(),
                history_complete: true,
            });
        }
        ensure!(
            page.cursor.is_some() && page.cursor != cursor,
            "wallet history cursor did not advance"
        );
        cursor = page.cursor;
    }
    Ok(FundingSummary {
        initial_funding: None,
        history_complete: false,
    })
}

#[cfg(test)]
mod tests;
