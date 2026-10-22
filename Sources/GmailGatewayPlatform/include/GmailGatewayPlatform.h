#ifndef GMAIL_GATEWAY_PLATFORM_H
#define GMAIL_GATEWAY_PLATFORM_H

// Atomically move a directory-relative file only if the destination is absent.
// Returns -1 and preserves errno on failure; no non-atomic fallback is allowed.
int gmail_gateway_rename_exclusive(int source_directory, const char *source,
                                  int destination_directory, const char *destination);

#endif
