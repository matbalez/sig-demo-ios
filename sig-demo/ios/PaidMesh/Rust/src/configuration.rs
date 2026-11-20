//! Shared production/probe configuration: no external plugin process.
use std::path::{Path, PathBuf};

const CONFIG: &str = concat!(
    "sig_demo_embedded_payments_only = true\n",
    "[logging]\nenabled = false\n",
    "[analytics]\nenabled = false\n",
);

pub fn write(directory: &Path) -> anyhow::Result<PathBuf> {
    let path = directory.join("config.toml");
    std::fs::write(&path, CONFIG)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_owned_in_process_payments_can_be_resolved() {
        use mesh_llm_host_runtime::plugin::{PluginHostMode, parse_config_toml, resolve_plugins};
        let mut config = parse_config_toml(CONFIG).unwrap();
        // No schema lookup is needed for any installed plugin, even a disabled
        // one: the upstream strict validator queries every declared name.
        assert!(config.plugins.is_empty());
        // Even a configured executable is excluded before its path is resolved.
        config.plugins.push(
            serde_json::from_value(serde_json::json!({
                "name":"synthetic-external-wallet",
                "command":"/must-never-run",
                "enabled":true,
            }))
            .unwrap(),
        );
        let resolved = resolve_plugins(
            &config,
            PluginHostMode {
                mesh_visibility: mesh_llm_plugin::MeshVisibility::Public,
            },
        )
        .unwrap();
        assert_eq!(resolved.externals.len(), 1);
        assert_eq!(resolved.externals[0].name, "payments");
        assert!(resolved.externals[0].command.is_empty());
        assert!(resolved.externals[0].installed_metadata.is_none());
    }
}
