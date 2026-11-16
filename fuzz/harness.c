/* libFuzzer entry for one MoonBit fuzz target. scripts/fuzz.mbtx compiles
 * this file once per target with -DMTTP_FUZZ_ENTRY=mttp_fuzz_h1 (or _ws) and
 * links it with the C that moonc generates for this package, built with its
 * `main` renamed away: libFuzzer supplies main. It is not a native-stub, so
 * the gates' ordinary native build never sees it. */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <moonbit.h>

void moonbit_runtime_init(int argc, char **argv);
void moonbit_init(void);
int32_t MTTP_FUZZ_ENTRY(moonbit_bytes_t);

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  moonbit_runtime_init(*argc, *argv);
  moonbit_init();
  return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  /* Inputs are a few KiB; refuse what the MoonBit length cannot hold. */
  if (size > (1 << 20)) {
    return -1;
  }
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)size, 0);
  memcpy(bytes, data, size);
  /* An exported MoonBit function owns its arguments and releases them. A
   * violated invariant aborts inside it, which libFuzzer reports as a crash
   * and saves the input. */
  MTTP_FUZZ_ENTRY(bytes);
  return 0;
}
