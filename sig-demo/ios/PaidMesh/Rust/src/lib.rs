//! The paid runtime uses a separate C namespace from the released free SDK.
//! No model-serving backend or wallet process is started by this adapter.

use mesh_llm_host_runtime::sdk::{EmbeddedMeshNodeBuilder, EmbeddedMeshNodeConfig};

mod configuration;
mod ffi;
mod payments;

/// Configuration qualification: client mode must never request a local model.
pub fn client_configuration() -> EmbeddedMeshNodeConfig {
    EmbeddedMeshNodeBuilder::default()
        .client()
        .auto_join(true)
        .publish(false)
        .enumerate_host(false)
        .listen_all(false)
        .console_ui(false)
        .build()
}

/// No-funds opt-in qualification used by the public-catalog example. The
/// caller must inject an empty memory store; this never provisions a wallet.
#[cfg(feature = "test-support")]
pub async fn inspect_public_catalog(
    directory: &std::path::Path,
    wallet: std::sync::Arc<sig_demo_paid_mesh_wallet::WalletContext>,
) -> anyhow::Result<serde_json::Value> {
    use anyhow::ensure;
    use std::time::Duration;
    let payment_directory = directory.join("payments");
    std::fs::create_dir_all(&payment_directory)?;
    let profile = payments::register(&payment_directory, wallet.clone())?;
    ensure!(
        wallet.snapshot()?["provisioned"] == false,
        "probe requires empty wallet state"
    );
    let config_path = configuration::write(directory)?;
    let port = || -> anyhow::Result<u16> {
        Ok(
            std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?
                .local_addr()?
                .port(),
        )
    };
    let config = EmbeddedMeshNodeBuilder::default()
        .client()
        .auto_join(true)
        .enumerate_host(false)
        .listen_all(false)
        .publish(false)
        .console_ui(false)
        .config_path(config_path)
        .isolated_config(true)
        .owner_key(directory.join("unused-owner-keystore"))
        .api_port(port()?)
        .console_port(port()?)
        .startup_timeout(Duration::from_secs(35))
        .build();
    let node = mesh_llm_host_runtime::sdk::start_embedded_node(config).await?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let result = async {
        let mut latest = serde_json::Value::Null;
        for _ in 0..25 {
            let response = client
                .get(format!("{}/models", node.api_base_url()))
                .send()
                .await?
                .error_for_status()?;
            let bytes = response.bytes().await?;
            ensure!(
                bytes.len() <= 2 * 1024 * 1024,
                "catalog exceeds probe limit"
            );
            latest = serde_json::from_slice(&bytes)?;
            if latest["data"].as_array().is_some_and(|items| {
                items.iter().any(|item| {
                    item["id"] == "Qwen3.6-27B-Q6_K" && item["payment"]["paid_available"] == true
                })
            }) {
                break;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        ensure!(
            wallet.snapshot()?["provisioned"] == false,
            "probe created a wallet"
        );
        Ok::<_, anyhow::Error>(latest)
    }
    .await;
    node.stop().await?;
    wallet.drain().await?;
    drop(profile);
    result
}
