//! Recovery material and spending policy are one atomic Keychain value.
//! No seedphrase, SDK database, or plaintext fallback is written to disk.

use anyhow::{Result, bail, ensure};
use zeroize::Zeroizing;

// The SDK binding omits this long-standing Security.framework constant.
#[cfg(target_os = "ios")]
unsafe extern "C" {
    static kSecAttrAccessible: core_foundation::string::CFStringRef;
}

pub trait ProtectedStore: Send + Sync {
    fn load(&self) -> Result<Option<Zeroizing<Vec<u8>>>>;
    /// Must replace the complete value atomically or report failure.
    fn store(&self, value: &[u8]) -> Result<()>;
}

pub fn validate_namespace(value: &str) -> Result<()> {
    ensure!(
        value.len() == 64
            && value
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
        "wallet requires an isolated account namespace"
    );
    Ok(())
}

#[cfg(target_os = "ios")]
pub struct KeychainStore {
    account: String,
}

#[cfg(target_os = "ios")]
impl KeychainStore {
    pub fn new(account: &str) -> Result<Self> {
        validate_namespace(account)?;
        Ok(Self {
            account: account.to_owned(),
        })
    }
    fn options(&self) -> security_framework::passwords::PasswordOptions {
        use security_framework::passwords::PasswordOptions;
        let mut options = PasswordOptions::new_generic_password(
            "dev.matbalez.sig-demo.ios.paid-mesh.lexe.v1",
            &self.account,
        );
        options.set_access_synchronized(Some(false));
        options.use_protected_keychain();
        options
    }
}

#[cfg(target_os = "ios")]
impl ProtectedStore for KeychainStore {
    fn load(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        match security_framework::passwords::generic_password(self.options()) {
            Ok(value) => Ok(Some(Zeroizing::new(value))),
            Err(error) if error.code() == -25300 => Ok(None), // errSecItemNotFound only
            Err(_) => bail!("wallet Keychain is unavailable"),
        }
    }
    fn store(&self, value: &[u8]) -> Result<()> {
        use core_foundation::{
            base::{CFType, TCFType},
            boolean::CFBoolean,
            data::CFData,
            dictionary::CFDictionary,
            string::CFString,
        };
        use security_framework_sys::{
            access_control::kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            item::{
                kSecAttrAccount, kSecAttrService, kSecAttrSynchronizable, kSecClass,
                kSecClassGenericPassword, kSecUseDataProtectionKeychain, kSecValueData,
            },
            keychain_item::{SecItemAdd, SecItemUpdate},
        };
        // Update only the value, using a stable identity query. Access-control
        // attributes belong in Add, never in the query used by SecItemUpdate.
        unsafe fn key(value: core_foundation::string::CFStringRef) -> CFString {
            unsafe { CFString::wrap_under_get_rule(value) }
        }
        let mut pairs: Vec<(CFString, CFType)> = unsafe {
            vec![
                (key(kSecClass), key(kSecClassGenericPassword).into_CFType()),
                (
                    key(kSecAttrService),
                    CFString::new("dev.matbalez.sig-demo.ios.paid-mesh.lexe.v1").into_CFType(),
                ),
                (
                    key(kSecAttrAccount),
                    CFString::new(&self.account).into_CFType(),
                ),
                (
                    key(kSecAttrSynchronizable),
                    CFBoolean::false_value().into_CFType(),
                ),
                (
                    key(kSecUseDataProtectionKeychain),
                    CFBoolean::true_value().into_CFType(),
                ),
            ]
        };
        let query = CFDictionary::from_CFType_pairs(&pairs);
        let value_pair = unsafe { (key(kSecValueData), CFData::from_buffer(value).into_CFType()) };
        let update = CFDictionary::from_CFType_pairs(&[value_pair.clone()]);
        let mut status =
            unsafe { SecItemUpdate(query.as_concrete_TypeRef(), update.as_concrete_TypeRef()) };
        if status == -25300 {
            // errSecItemNotFound, never a locked/corrupt fallback
            pairs.push(value_pair);
            pairs.push(unsafe {
                (
                    key(kSecAttrAccessible),
                    key(kSecAttrAccessibleWhenUnlockedThisDeviceOnly).into_CFType(),
                )
            });
            let add = CFDictionary::from_CFType_pairs(&pairs);
            status = unsafe { SecItemAdd(add.as_concrete_TypeRef(), std::ptr::null_mut()) };
        }
        ensure!(status == 0, "could not persist wallet Keychain state");
        Ok(())
    }
}

#[cfg(not(target_os = "ios"))]
pub struct UnavailableStore;
#[cfg(not(target_os = "ios"))]
impl ProtectedStore for UnavailableStore {
    fn load(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        bail!("wallet Keychain requires iOS")
    }
    fn store(&self, _: &[u8]) -> Result<()> {
        bail!("wallet Keychain requires iOS")
    }
}
