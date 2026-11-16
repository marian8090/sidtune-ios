#ifndef SIDTUNE_SEVENZIP_H
#define SIDTUNE_SEVENZIP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A small C facade over the LZMA SDK's 7z reader, so Swift needs no knowledge of the SDK's types.
typedef struct sz_archive sz_archive;

/// Opens a .7z file and reads its header. `temp_dir` (may be NULL) is where dictionaries of 16 MiB or more are memory-mapped
/// from an unlinked file instead of allocated, which keeps them out of the app's dirty-memory footprint. On failure returns
/// NULL and writes a message to `error`.
sz_archive *sz_open(const char *path, const char *temp_dir, char *error, size_t error_size);
void sz_close(sz_archive *archive);

uint32_t sz_count(const sz_archive *archive);
bool sz_is_dir(const sz_archive *archive, uint32_t index);
uint64_t sz_size(const sz_archive *archive, uint32_t index);
/// Writes the entry's path as NUL-terminated UTF-8 and returns its length, or the size needed if `size` is too small.
size_t sz_name(const sz_archive *archive, uint32_t index, char *buffer, size_t size);

/// Return non-zero to stop extracting.
typedef int (*sz_file_callback)(void *context, uint32_t index, const uint8_t *data, size_t size);

/// Decodes every solid block that holds a wanted entry, front to back, and calls `callback` once per wanted non-empty entry
/// in archive order. Blocks without a wanted entry are skipped, so their compression methods don't matter. Each entry's
/// CRC is checked. Returns 0 on success, 1 if the callback stopped it, or -1 with a message in `error`.
int sz_extract(sz_archive *archive, const bool *wanted, sz_file_callback callback, void *context, char *error, size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
