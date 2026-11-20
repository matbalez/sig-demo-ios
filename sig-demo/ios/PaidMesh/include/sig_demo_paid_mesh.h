#ifndef SIG_DEMO_PAID_MESH_H
#define SIG_DEMO_PAID_MESH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SigDemoPaidMeshHandle SigDemoPaidMeshHandle;

/* Configuration v1: {"version":1,"storage_directory":"absolute app-owned path"}.
 * Creation is passive: it must not provision a wallet or contact a provider.
 * NULL indicates invalid configuration. All blocking operations run off main.
 */
SigDemoPaidMeshHandle *sig_demo_paid_mesh_create(const char *configuration_json);

/* Owned UTF-8 JSON envelope: {"ok":true,"value":...} or
 * {"ok":false,"error":{"code":"fixed_code"}}. Free with string_free.
 * Only one call may be active for a handle. cancel may race that call.
 * Supported operations and their payloads are documented in README.md.
 * Read-only wallet commands: refresh_wallet_observation, funding_status
 * (payment_hash only), transaction_history (cursor, limit<=100), and
 * confirmed_funding. They never provision, recover, or submit a payment.
 */
char *sig_demo_paid_mesh_call(SigDemoPaidMeshHandle *handle, const char *command_json);

/* Nonblocking cancellation request. A subsequent stop drains native cleanup.
 * Free requires all call/cancel invocations to have completed first.
 */
void sig_demo_paid_mesh_cancel(SigDemoPaidMeshHandle *handle);
void sig_demo_paid_mesh_free(SigDemoPaidMeshHandle *handle);
void sig_demo_paid_mesh_string_free(char *string);

#ifdef __cplusplus
}
#endif
#endif
