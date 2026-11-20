//! Explicit no-funds public-network qualification. The ephemeral protected
//! store contains no recovery material and its factory remains unprovisioned.
use std::sync::{Arc, Mutex};

use anyhow::Result;
use sig_demo_paid_mesh_wallet::store::ProtectedStore;
use zeroize::Zeroizing;

#[derive(Default)]
struct MemoryStore(Mutex<Option<Vec<u8>>>);

impl ProtectedStore for MemoryStore {
    fn load(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        Ok(self.0.lock().unwrap().clone().map(Zeroizing::new))
    }
    fn store(&self, value: &[u8]) -> Result<()> {
        *self.0.lock().unwrap() = Some(value.to_vec());
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    anyhow::ensure!(
        std::env::args().any(|argument| argument == "--public-catalog"),
        "explicit --public-catalog opt-in required"
    );
    let directory = tempfile::tempdir()?;
    let wallet = sig_demo_paid_mesh_wallet::WalletContext::new_with_store(
        directory.path(),
        Arc::new(MemoryStore::default()),
    )?;
    let result = sig_demo_paid_mesh::inspect_public_catalog(directory.path(), wallet).await?;
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
