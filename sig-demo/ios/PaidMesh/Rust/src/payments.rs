//! Buyer-only payments capability. Seller operations are deliberately absent.
//! Every native request ID is bound to an existing UI invocation before an
//! admission can authorize either of its invoices.

use std::any::Any;
use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use anyhow::{Context, Result, ensure};
use mesh_llm_payments::service::PaymentService;
use mesh_llm_payments_types::contract::{
    AcceptAdmissionRequest, AdvertisedPricing, BillingContract, BillingRevision, CancelRequest,
    Empty, FinishRequest, OpError, PayDepositRequest, RoutingBudgetRequest, SettleFinalRequest,
    ops,
};
use mesh_llm_payments_types::engine::{
    AdvertisedPrices, BoxFuture, EngineSource, PaymentsEngine, PaymentsEngineProvider,
};
use mesh_llm_payments_types::pricing::{Pricing, payment_cap_msat};
use mesh_llm_plugin::{
    InternalRpcPluginBuilder, OperationRouter, PluginMetadata, PluginResult, capability,
    operation_with_schema, plugin_server_info,
};
use mesh_llm_wallet::provisioning::WalletFactory;
use rmcp::model::CallToolResult;
use serde::Serialize;
use serde::de::DeserializeOwned;
use sig_demo_paid_mesh_wallet::WalletContext;

pub struct PaymentRuntime {
    pub service: Arc<PaymentService>,
    pub wallet: Arc<WalletContext>,
}

impl PaymentsEngine for PaymentRuntime {
    fn pricing(&self) -> Result<BTreeMap<String, Pricing>> {
        // Mobile consumes inference. It never offers a model for payment.
        Ok(BTreeMap::new())
    }

    fn has_wallet(&self) -> bool {
        self.service.has_wallet()
    }

    fn into_any(self: Arc<Self>) -> Arc<dyn Any + Send + Sync> {
        self
    }
}

#[derive(Default)]
struct MobileProvider {
    profiles: Mutex<HashMap<PathBuf, Weak<PaymentRuntime>>>,
}

static PROVIDER: OnceLock<Arc<MobileProvider>> = OnceLock::new();

pub fn register(directory: &Path, wallet: Arc<WalletContext>) -> Result<Arc<PaymentRuntime>> {
    let provider = PROVIDER.get_or_init(|| {
        let provider = Arc::new(MobileProvider::default());
        let installed = mesh_llm_host_runtime::install_payments_engine(provider.clone());
        assert!(installed, "paid runtime requires its own payments provider");
        provider
    });
    let directory = directory.canonicalize()?;
    let mut profiles = provider
        .profiles
        .lock()
        .map_err(|_| anyhow::anyhow!("registry poisoned"))?;
    profiles.retain(|_, profile| profile.strong_count() > 0);
    ensure!(
        profiles.get(&directory).and_then(Weak::upgrade).is_none(),
        "profile already open"
    );
    let profile = Arc::new(PaymentRuntime {
        service: Arc::new(PaymentService::with_factory(&directory, wallet.factory())?),
        wallet,
    });
    profiles.insert(directory, Arc::downgrade(&profile));
    Ok(profile)
}

impl PaymentsEngineProvider for MobileProvider {
    fn open(
        &self,
        directory: &Path,
        _external_wallet: Arc<dyn WalletFactory>,
    ) -> Result<Arc<dyn PaymentsEngine>> {
        self.profiles
            .lock()
            .map_err(|_| anyhow::anyhow!("registry poisoned"))?
            .get(&directory.canonicalize()?)
            .and_then(Weak::upgrade)
            .map(|profile| profile as Arc<dyn PaymentsEngine>)
            .context("unregistered mobile payment profile")
    }

    fn serve(
        &self,
        name: &str,
        version: &str,
        source: EngineSource,
        _prices: AdvertisedPrices,
        stream: mesh_llm_plugin::LocalStream,
    ) -> BoxFuture<Result<()>> {
        let router = buyer_router(source);
        let plugin = InternalRpcPluginBuilder::new(PluginMetadata::new(
            name,
            version,
            plugin_server_info(
                "sig-demo-paid-mesh",
                version,
                "Sig paid Mesh buyer",
                "Client-only guarded inference payments",
                None::<String>,
            ),
        ))
        .with_capabilities(vec![mesh_llm_payments_types::contract::CAPABILITY.into()])
        .with_manifest(mesh_llm_plugin::plugin_manifest![capability(
            mesh_llm_payments_types::contract::CAPABILITY
        )])
        .with_operation_router(router)
        .build();
        Box::pin(mesh_llm_plugin::PluginRuntime::run_with_stream(
            plugin, stream,
        ))
    }
}

fn buyer_router(source: EngineSource) -> OperationRouter {
    let mut router = OperationRouter::new();
    add(
        &mut router,
        &source,
        ops::BILLING_CONTRACT,
        |_profile, _: Empty| async {
            Ok(BillingContract {
                revision: BillingRevision::V3,
            })
        },
    );
    add(
        &mut router,
        &source,
        ops::PRICING,
        |_profile, _: Empty| async {
            Ok(AdvertisedPricing {
                configured: true,
                prices: BTreeMap::new(),
            })
        },
    );
    add(
        &mut router,
        &source,
        ops::ROUTING_BUDGET,
        |profile, request: RoutingBudgetRequest| async move {
            Ok(profile.service.routing_budget(request).await)
        },
    );
    add(
        &mut router,
        &source,
        ops::PAYMENT_INTENT,
        |profile, _: Empty| async move { profile.service.ledger.payment_intent() },
    );
    add(
        &mut router,
        &source,
        ops::RECONCILE,
        |profile, _: Empty| async move { profile.service.reconcile().await },
    );
    add(
        &mut router,
        &source,
        ops::FINISH,
        |profile, request: FinishRequest| async move {
            profile
                .service
                .finish_metered(&request.id)
                .await
                .map(|()| Empty {})
        },
    );
    add(
        &mut router,
        &source,
        ops::CANCEL,
        |profile, request: CancelRequest| async move {
            profile.service.cancel(request).map(|()| Empty {})
        },
    );
    add(
        &mut router,
        &source,
        ops::ACCEPT_ADMISSION,
        |profile, request: AcceptAdmissionRequest| async move {
            let id = request.terms.id.clone();
            profile.wallet.bind_request(&id)?;
            let result = profile.service.accept_admission(request).await;
            if result.is_err() {
                // Only this live, completed admission failure proves that a
                // never-accepted ID can be retired. Missing rows after restart
                // remain unknown and may never be inferred as rejected.
                let state = profile.service.ledger.request_state(&id)?;
                if state.as_deref() == Some("pending") {
                    profile.service.ledger.reject(&id)?;
                }
                if matches!(
                    profile.service.ledger.request_state(&id)?.as_deref(),
                    None | Some("rejected")
                ) {
                    profile.wallet.mark_unaccepted(&id)?;
                }
            }
            result.map(|()| Empty {})
        },
    );
    add(
        &mut router,
        &source,
        ops::PAY_DEPOSIT,
        |profile, request: PayDepositRequest| async move {
            let amount = request
                .invoice
                .amount_msat
                .context("amountless inference invoice")?;
            profile.wallet.authorize_invoice(
                &request.request_id,
                &request.invoice,
                amount,
                payment_cap_msat(amount)?,
            )?;
            // Once an operation may submit funds, caller cancellation only drops
            // observation. The guard retains any unresolved reservation durably.
            tokio::spawn(async move {
                let hash = request.invoice.payment_hash.clone();
                let result = profile.service.pay_deposit(request).await;
                if result.is_err() {
                    // This only releases a reservation the guard proves was
                    // never submitted. Uncertain payments remain reserved.
                    profile.wallet.release_unsubmitted(&hash)?;
                }
                result
            })
            .await?
        },
    );
    add(
        &mut router,
        &source,
        ops::SETTLE_FINAL,
        |profile, request: SettleFinalRequest| async move {
            if let Some(invoice) = &request.invoice {
                let amount = invoice
                    .amount_msat
                    .context("amountless inference invoice")?;
                profile.wallet.authorize_final_invoice(
                    &request.request_id,
                    invoice,
                    amount,
                    payment_cap_msat(amount)?,
                )?;
            }
            tokio::spawn(async move {
                let hash = request
                    .invoice
                    .as_ref()
                    .map(|invoice| invoice.payment_hash.clone());
                let result = profile.service.settle_final(request).await;
                if result.is_err() {
                    if let Some(hash) = hash {
                        profile.wallet.release_unsubmitted(&hash)?;
                    }
                }
                result
            })
            .await?
        },
    );
    router
}

fn add<Req, Res, F, Fut>(
    router: &mut OperationRouter,
    source: &EngineSource,
    name: &'static str,
    handler: F,
) where
    Req: DeserializeOwned + Send + 'static,
    Res: Serialize + Send + 'static,
    F: Fn(Arc<PaymentRuntime>, Req) -> Fut + Send + Sync + Copy + 'static,
    Fut: Future<Output = Result<Res>> + Send + 'static,
{
    let source = Arc::clone(source);
    router.add_raw(
        operation_with_schema(name, "Mobile buyer operation", serde_json::Map::new()),
        move |request, _context| {
            let source = Arc::clone(&source);
            Box::pin(async move {
                let result = async {
                    let arguments = request.arguments::<Req>()?;
                    let profile = source()
                        .await?
                        .into_any()
                        .downcast::<PaymentRuntime>()
                        .map_err(|_| anyhow::anyhow!("unexpected payment engine"))?;
                    handler(profile, arguments).await
                }
                .await;
                operation_result(result)
            })
        },
    );
}

fn operation_result<T: Serialize>(result: Result<T>) -> PluginResult<CallToolResult> {
    let internal =
        |error: serde_json::Error| mesh_llm_plugin::PluginError::internal(error.to_string());
    Ok(match result {
        Ok(value) => CallToolResult::structured(serde_json::to_value(value).map_err(internal)?),
        // Never send a wallet SDK's detailed error or account material to a peer.
        Err(_) => CallToolResult::structured_error(
            serde_json::to_value(OpError {
                message: "mobile payment operation unavailable".into(),
            })
            .map_err(internal)?,
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_contains_buyer_operations_and_excludes_seller_and_operator_commands() {
        let source: EngineSource =
            Arc::new(|| Box::pin(async { anyhow::bail!("test source must never open") }));
        let router = buyer_router(source);
        let names = router
            .list_tools_result()
            .tools
            .into_iter()
            .map(|tool| tool.name.to_string())
            .collect::<Vec<_>>();
        assert!(names.contains(&ops::ACCEPT_ADMISSION.to_owned()));
        assert!(names.contains(&ops::PAY_DEPOSIT.to_owned()));
        assert!(names.contains(&ops::SETTLE_FINAL.to_owned()));
        assert!(names.contains(&ops::BILLING_CONTRACT.to_owned()));
        for name in [
            ops::CONTROL,
            ops::SERVE_ADMIT,
            ops::SERVE_SETTLE,
            ops::SERVE_RECOVER,
            ops::AWAIT_ARRIVAL,
            ops::SETTLE_RECEIVED,
        ] {
            assert!(!names.iter().any(|actual| actual == name));
        }
    }
}
