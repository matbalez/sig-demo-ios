// No credentials, network connection, or app state are used by this ABI test.
#include "signal_ffi.h"
#include <stdio.h>
#include <stdlib.h>

static int check_constructor(uint16_t port, SignalBorrowedBuffer certificate, bool should_succeed) {
  SignalMutPointerBridgedStringMap config = {0};
  SignalFfiError *error = signal_bridged_string_map_new(&config, 0);
  if (error) { signal_error_free(error); return 1; }
  SignalMutPointerConnectionManager manager = {0};
  error = signal_connection_manager_new_local_demo(
      &manager, (const int8_t*)"sig-ios-bridge-smoke", port, certificate, config, 1);
  bool succeeded = error == NULL && manager.raw != NULL;
  if (error) signal_error_free(error);
  if (manager.raw) {
    error = signal_connection_manager_destroy(manager);
    if (error) { signal_error_free(error); return 2; }
  }
  error = signal_bridged_string_map_destroy(config);
  if (error) { signal_error_free(error); return 3; }
  return succeeded == should_succeed ? 0 : 4;
}

int main(int argc, char **argv) {
  if (check_constructor(14443, (SignalBorrowedBuffer){0}, false)) return 10;
  const uint8_t malformed[] = {1, 2, 3};
  if (check_constructor(14443, (SignalBorrowedBuffer){malformed, sizeof malformed}, false)) return 11;
  if (argc == 2) {
    // Use only the pinned upstream public test certificate, never app config.
    FILE *fixture = fopen(argv[1], "rb");
    if (!fixture) return 12;
    uint8_t bytes[65536];
    size_t length = fread(bytes, 1, sizeof bytes, fixture);
    bool invalid_length = ferror(fixture) || !feof(fixture) || length == 0;
    fclose(fixture);
    if (invalid_length) return 13;
    SignalBorrowedBuffer certificate = {bytes, length};
    if (check_constructor(0, certificate, false)) return 14;
    if (check_constructor(14443, certificate, true)) return 15;
  }
  puts("Private bridge ABI constructor and teardown checks passed; no connection started");
  return 0;
}
