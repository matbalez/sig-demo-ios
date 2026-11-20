use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use zeroize::Zeroize;

pub const MAX_RECORDS: usize = 2048;

#[derive(Clone, Serialize, Deserialize)]
pub struct State {
    pub version: u32,
    pub seed: Option<Vec<u8>>,
    #[serde(default)]
    pub node_secret: Option<Vec<u8>>,
    pub wallet_id: Option<String>,
    pub provisioned: bool,
    #[serde(default)]
    pub safety_blocked: bool,
    pub daily_budget_msat: u64,
    pub per_request_budget_msat: u64,
    pub day_highwater: u64,
    pub active_scope: Option<String>,
    pub scopes: BTreeMap<String, Scope>,
    pub bindings: BTreeMap<String, String>,
    #[serde(default)]
    pub unaccepted: BTreeSet<String>,
    pub invoices: BTreeMap<String, Authorization>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            version: 1,
            seed: None,
            node_secret: None,
            wallet_id: None,
            provisioned: false,
            safety_blocked: false,
            daily_budget_msat: 0,
            per_request_budget_msat: 0,
            day_highwater: 0,
            active_scope: None,
            scopes: BTreeMap::new(),
            bindings: BTreeMap::new(),
            unaccepted: BTreeSet::new(),
            invoices: BTreeMap::new(),
        }
    }
}
impl Drop for State {
    fn drop(&mut self) {
        if let Some(seed) = &mut self.seed {
            seed.zeroize();
        }
        if let Some(secret) = &mut self.node_secret {
            secret.zeroize();
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Scope {
    cap_msat: u64,
    #[serde(default)]
    daily_cap_msat: u64,
    #[serde(default)]
    admission_closed: bool,
    #[serde(default)]
    pub obligation_pending: bool,
    #[serde(default)]
    recovery: bool,
    pub closed: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Phase {
    Authorized,
    Submitted,
    Succeeded,
    Failed,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Authorization {
    pub request_id: String,
    pub scope_id: String,
    pub amount_msat: u64,
    pub ceiling_msat: u64,
    pub reserved_msat: u64,
    pub phase: Phase,
    pub charged_day: u64,
    pub actual_debit_msat: u64,
    #[serde(default)]
    final_invoice: bool,
}

impl State {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.version == 1, "unsupported wallet state version");
        ensure!(
            self.seed.as_ref().is_none_or(|v| v.len() == 32),
            "invalid wallet recovery state"
        );
        ensure!(
            self.node_secret.as_ref().is_none_or(|v| v.len() == 32),
            "invalid private Mesh identity state"
        );
        ensure!(
            !self.provisioned
                || (self.seed.is_some() && self.wallet_id.is_some() && self.node_secret.is_some()),
            "incomplete wallet recovery state"
        );
        ensure!(
            self.wallet_id.is_none() || self.seed.is_some(),
            "wallet identity has no recovery material"
        );
        ensure!(
            self.invoices.len() <= MAX_RECORDS
                && self.scopes.len() <= MAX_RECORDS
                && self.bindings.len() <= MAX_RECORDS,
            "wallet safety history is full"
        );
        ensure!(
            self.active_scope
                .as_ref()
                .is_none_or(|id| self.scopes.get(id).is_some_and(|s| !s.closed)),
            "invalid active wallet scope"
        );
        for scope_id in self.bindings.values() {
            ensure!(
                self.scopes.contains_key(scope_id),
                "seller request has no wallet scope"
            );
        }
        ensure!(
            self.unaccepted
                .iter()
                .all(|id| self.bindings.contains_key(id)
                    && !self.invoices.values().any(|row| &row.request_id == id)),
            "invalid unaccepted admission receipt"
        );
        for (hash, value) in &self.invoices {
            validate_hash(hash)?;
            ensure!(
                self.bindings.get(&value.request_id) == Some(&value.scope_id)
                    && self.scopes.contains_key(&value.scope_id),
                "wallet authorization has no request scope"
            );
            ensure!(
                value.amount_msat > 0 && value.amount_msat <= value.ceiling_msat,
                "invalid wallet authorization"
            );
            ensure!(
                value.reserved_msat <= value.ceiling_msat,
                "invalid wallet reservation"
            );
            if value.phase == Phase::Submitted {
                ensure!(
                    value.reserved_msat >= value.amount_msat,
                    "incomplete wallet reservation"
                );
            }
            if matches!(value.phase, Phase::Succeeded | Phase::Failed) {
                ensure!(
                    value.reserved_msat == 0,
                    "terminal payment has a reservation"
                );
            }
        }
        Ok(())
    }
    pub fn day(&self, now_ms: u64) -> u64 {
        self.day_highwater.max(now_ms / 86_400_000)
    }
    pub fn spending(&self, day: u64) -> Result<(u64, u64, u64)> {
        let mut spent = 0u64;
        let mut reserved = 0u64;
        let mut pending = 0u64;
        for row in self.invoices.values() {
            match row.phase {
                Phase::Succeeded if row.charged_day == day => {
                    spent = spent
                        .checked_add(row.actual_debit_msat)
                        .ok_or_else(|| anyhow::anyhow!("wallet total overflow"))?
                }
                Phase::Submitted | Phase::Authorized => {
                    reserved = reserved
                        .checked_add(row.reserved_msat)
                        .ok_or_else(|| anyhow::anyhow!("wallet total overflow"))?;
                    if row.phase == Phase::Submitted {
                        pending += 1;
                    }
                }
                _ => {}
            }
        }
        Ok((spent, reserved, pending))
    }
    fn assert_caps(&self, hash: &str, proposed: u64, day: u64) -> Result<()> {
        ensure!(!self.safety_blocked, "wallet safety check requires review");
        let row = self
            .invoices
            .get(hash)
            .ok_or_else(|| anyhow::anyhow!("invoice was not authorized"))?;
        let scope = self
            .scopes
            .get(&row.scope_id)
            .ok_or_else(|| anyhow::anyhow!("invoice scope is unavailable"))?;
        ensure!(
            self.daily_budget_msat > 0 && self.per_request_budget_msat > 0 && scope.cap_msat > 0,
            "paid inference spending is disabled"
        );
        ensure!(
            proposed <= row.ceiling_msat,
            "payment exceeds invoice authorization"
        );
        let mut daily = proposed;
        let mut request = proposed;
        for (other_hash, other) in &self.invoices {
            if other_hash == hash {
                continue;
            }
            let debit = match other.phase {
                Phase::Succeeded => other.actual_debit_msat,
                Phase::Authorized | Phase::Submitted => other.reserved_msat,
                Phase::Failed => 0,
            };
            if other.scope_id == row.scope_id {
                request = request
                    .checked_add(debit)
                    .ok_or_else(|| anyhow::anyhow!("wallet total overflow"))?;
            }
            if matches!(other.phase, Phase::Authorized | Phase::Submitted)
                || (other.phase == Phase::Succeeded && other.charged_day == day)
            {
                daily = daily
                    .checked_add(debit)
                    .ok_or_else(|| anyhow::anyhow!("wallet total overflow"))?;
            }
        }
        ensure!(
            daily <= self.daily_budget_msat.min(scope.daily_cap_msat),
            "daily spending limit reached"
        );
        ensure!(
            request <= scope.cap_msat.min(self.per_request_budget_msat),
            "request spending limit reached"
        );
        Ok(())
    }
    pub fn begin(&mut self, scope_id: &str) -> Result<()> {
        ensure!(!self.safety_blocked, "wallet safety check requires review");
        ensure!(
            !self.scopes.values().any(|scope| scope.obligation_pending),
            "an earlier inference exchange requires reconciliation"
        );
        ensure!(
            !self
                .invoices
                .values()
                .any(|row| row.phase == Phase::Submitted),
            "previous payment is still pending; reconcile before starting another request"
        );
        validate_id(scope_id)?;
        ensure!(
            self.active_scope.is_none(),
            "a paid inference request is already active"
        );
        ensure!(
            !self.scopes.contains_key(scope_id),
            "paid request scope cannot be reused"
        );
        ensure!(
            self.scopes.len() < MAX_RECORDS,
            "wallet safety history is full"
        );
        ensure!(self.provisioned, "wallet setup is required");
        ensure!(
            self.daily_budget_msat > 0 && self.per_request_budget_msat > 0,
            "paid inference spending is disabled"
        );
        self.scopes.insert(
            scope_id.to_owned(),
            Scope {
                cap_msat: self.per_request_budget_msat,
                daily_cap_msat: self.daily_budget_msat,
                admission_closed: false,
                obligation_pending: false,
                recovery: false,
                closed: false,
            },
        );
        self.active_scope = Some(scope_id.to_owned());
        Ok(())
    }
    pub fn bind(&mut self, request_id: &str) -> Result<()> {
        validate_id(request_id)?;
        ensure!(
            !self.unaccepted.contains(request_id),
            "rejected seller request cannot be reused"
        );
        let active = self
            .active_scope
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("no active paid inference request"))?;
        ensure!(
            self.scopes
                .get(active)
                .is_some_and(|scope| !scope.admission_closed && !scope.closed),
            "paid request admissions are closed"
        );
        if let Some(scope) = self.bindings.get(request_id) {
            ensure!(
                scope == active,
                "seller request belongs to an earlier invocation"
            );
            return Ok(());
        }
        ensure!(
            self.bindings.len() < MAX_RECORDS,
            "wallet safety history is full"
        );
        self.bindings.insert(request_id.to_owned(), active.clone());
        Ok(())
    }
    pub fn authorize(
        &mut self,
        request_id: &str,
        hash: &str,
        amount: u64,
        ceiling: u64,
        now_ms: u64,
    ) -> Result<()> {
        self.authorize_kind(request_id, hash, amount, ceiling, now_ms, false)
    }
    pub fn authorize_final(
        &mut self,
        request_id: &str,
        hash: &str,
        amount: u64,
        ceiling: u64,
        now_ms: u64,
    ) -> Result<()> {
        self.authorize_kind(request_id, hash, amount, ceiling, now_ms, true)
    }
    fn authorize_kind(
        &mut self,
        request_id: &str,
        hash: &str,
        amount: u64,
        ceiling: u64,
        now_ms: u64,
        final_invoice: bool,
    ) -> Result<()> {
        ensure!(
            !self.unaccepted.contains(request_id),
            "seller request was never accepted"
        );
        validate_hash(hash)?;
        ensure!(
            amount > 0 && amount <= ceiling,
            "invalid payment authorization"
        );
        let scope_id = self
            .bindings
            .get(request_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("seller request was not bound"))?;
        ensure!(
            self.scopes
                .get(&scope_id)
                .is_some_and(|scope| !scope.closed)
                && self.active_scope.as_deref() == Some(scope_id.as_str()),
            "paid request scope has ended"
        );
        ensure!(
            self.scopes
                .get(&scope_id)
                .is_some_and(|scope| !scope.admission_closed || final_invoice),
            "only final settlement is allowed while finishing or recovering"
        );
        if let Some(row) = self.invoices.get(hash) {
            ensure!(
                row.scope_id == scope_id
                    && row.request_id == request_id
                    && row.amount_msat == amount
                    && row.final_invoice == final_invoice
                    && row.ceiling_msat == ceiling,
                "invoice authorization cannot change ownership or amount"
            );
            return Ok(());
        }
        ensure!(
            self.invoices.len() < MAX_RECORDS,
            "wallet safety history is full"
        );
        let day = self.day(now_ms);
        self.day_highwater = day;
        self.invoices.insert(
            hash.to_owned(),
            Authorization {
                request_id: request_id.to_owned(),
                scope_id,
                amount_msat: amount,
                ceiling_msat: ceiling,
                reserved_msat: amount,
                phase: Phase::Authorized,
                charged_day: day,
                actual_debit_msat: 0,
                final_invoice,
            },
        );
        self.assert_caps(hash, amount, day)
    }
    pub fn reserve_submission(
        &mut self,
        hash: &str,
        actual_route_debit: u64,
        now_ms: u64,
    ) -> Result<()> {
        let row = self
            .invoices
            .get(hash)
            .ok_or_else(|| anyhow::anyhow!("invoice was not authorized"))?;
        ensure!(
            row.phase == Phase::Authorized,
            "payment already submitted; reconciliation required"
        );
        ensure!(
            self.scopes
                .get(&row.scope_id)
                .is_some_and(|scope| !scope.closed)
                && self.active_scope.as_deref() == Some(row.scope_id.as_str()),
            "paid request scope has ended"
        );
        ensure!(
            actual_route_debit >= row.amount_msat,
            "invalid quoted payment amount"
        );
        let day = self.day(now_ms);
        self.assert_caps(hash, actual_route_debit, day)?;
        self.day_highwater = day;
        let row = self.invoices.get_mut(hash).unwrap();
        row.reserved_msat = actual_route_debit;
        row.charged_day = day;
        row.phase = Phase::Submitted;
        Ok(())
    }
    pub fn reconcile(
        &mut self,
        hash: &str,
        amount: u64,
        fees: u64,
        succeeded: bool,
        now_ms: u64,
    ) -> Result<()> {
        let day = self.day(now_ms);
        self.day_highwater = day;
        let row = self
            .invoices
            .get_mut(hash)
            .ok_or_else(|| anyhow::anyhow!("payment is not authorized"))?;
        let actual = amount
            .checked_add(fees)
            .ok_or_else(|| anyhow::anyhow!("wallet total overflow"))?;
        if row.phase == Phase::Succeeded {
            ensure!(
                succeeded && row.actual_debit_msat == actual,
                "payment terminal result changed"
            );
            return Ok(());
        }
        if row.phase == Phase::Failed {
            ensure!(!succeeded, "payment terminal result changed");
            return Ok(());
        }
        ensure!(
            row.phase == Phase::Submitted,
            "wallet returned a payment never submitted by this adapter"
        );
        if succeeded {
            ensure!(
                amount >= row.amount_msat,
                "wallet terminal amount is incomplete; spending is blocked"
            );
            ensure!(
                actual <= row.reserved_msat,
                "wallet exceeded its preflighted route; spending is blocked"
            );
            row.actual_debit_msat = actual;
            row.phase = Phase::Succeeded;
        } else {
            ensure!(
                fees == 0,
                "failed payment charged a fee; reconciliation required"
            );
            row.phase = Phase::Failed;
        }
        row.charged_day = day;
        row.reserved_msat = 0;
        Ok(())
    }
    pub fn end(&mut self, scope_id: &str) -> Result<()> {
        if self.active_scope.as_deref() != Some(scope_id) {
            bail!("paid request scope is not active");
        }
        self.active_scope = None;
        let scope = self.scopes.get_mut(scope_id).unwrap();
        scope.closed = true;
        scope.admission_closed = true;
        scope.obligation_pending = false;
        scope.recovery = false;
        for row in self
            .invoices
            .values_mut()
            .filter(|row| row.scope_id == scope_id && row.phase == Phase::Authorized)
        {
            // Nothing was sent. A later settlement may re-reserve this known
            // hash after fresh preflight; never release Submitted uncertainty.
            row.reserved_msat = 0;
        }
        // Authorized-but-unsent invoices remain associated with the original
        // scope. They cannot be adopted by a later invocation.
        Ok(())
    }
    pub fn bound_request_ids(&self, scope_id: &str) -> Result<Vec<String>> {
        ensure!(
            self.scopes.contains_key(scope_id),
            "unknown paid request scope"
        );
        Ok(self
            .bindings
            .iter()
            .filter(|(id, scope)| {
                scope.as_str() == scope_id && !self.unaccepted.contains(id.as_str())
            })
            .map(|(id, _)| id.clone())
            .collect())
    }
    pub fn finish_request(&mut self, scope_id: &str) -> Result<Vec<String>> {
        ensure!(
            self.active_scope.as_deref() == Some(scope_id),
            "paid request scope is not active"
        );
        let ids = self.bound_request_ids(scope_id)?;
        let scope = self.scopes.get_mut(scope_id).unwrap();
        scope.admission_closed = true;
        scope.obligation_pending |= !ids.is_empty();
        Ok(ids)
    }
    pub fn mark_reconciliation_required(&mut self, scope_id: &str) -> Result<()> {
        let scope = self
            .scopes
            .get_mut(scope_id)
            .ok_or_else(|| anyhow::anyhow!("unknown paid request scope"))?;
        scope.admission_closed = true;
        scope.obligation_pending = true;
        Ok(())
    }
    pub fn mark_unaccepted(&mut self, request_id: &str) -> Result<()> {
        ensure!(
            self.bindings.contains_key(request_id),
            "seller request was not bound"
        );
        ensure!(
            !self
                .invoices
                .values()
                .any(|row| row.request_id == request_id),
            "an invoiced admission cannot be marked unaccepted"
        );
        self.unaccepted.insert(request_id.to_owned());
        Ok(())
    }
    pub fn orphan_active(&mut self) -> Result<()> {
        if let Some(id) = self.active_scope.clone() {
            let ids = self.bound_request_ids(&id)?;
            let was_pending = self
                .scopes
                .get(&id)
                .ok_or_else(|| anyhow::anyhow!("unknown paid request scope"))?
                .obligation_pending;
            self.end(&id)?;
            self.scopes.get_mut(&id).unwrap().obligation_pending = was_pending || !ids.is_empty();
        }
        Ok(())
    }
    pub fn resume_recovery_scope(&mut self, scope_id: &str) -> Result<()> {
        ensure!(!self.safety_blocked, "wallet safety check requires review");
        ensure!(
            self.active_scope
                .as_deref()
                .is_none_or(|active| active == scope_id),
            "another paid request is active"
        );
        let scope = self
            .scopes
            .get_mut(scope_id)
            .ok_or_else(|| anyhow::anyhow!("unknown paid request scope"))?;
        ensure!(
            scope.obligation_pending,
            "scope has no unresolved obligation"
        );
        ensure!(
            scope.cap_msat > 0 && scope.daily_cap_msat > 0,
            "original spending authority is unavailable"
        );
        scope.closed = false;
        scope.admission_closed = true;
        scope.recovery = true;
        self.active_scope = Some(scope_id.to_owned());
        Ok(())
    }
    pub fn release_unsubmitted(&mut self, hash: &str) -> Result<()> {
        validate_hash(hash)?;
        if let Some(row) = self.invoices.get_mut(hash) {
            if row.phase == Phase::Authorized {
                row.reserved_msat = 0;
            }
        }
        Ok(())
    }
}

fn validate_id(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control),
        "invalid request identifier"
    );
    Ok(())
}
pub fn validate_hash(hash: &str) -> Result<()> {
    ensure!(
        hash.len() == 64
            && hash
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
        "invalid payment hash"
    );
    Ok(())
}
