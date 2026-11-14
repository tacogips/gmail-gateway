#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "GmailGatewayPlatform.h"
#include <stdio.h>

int gmail_gateway_rename_exclusive(int source_directory, const char *source,
                                  int destination_directory, const char *destination) {
#if defined(__linux__)
    return renameat2(source_directory, source, destination_directory, destination, RENAME_NOREPLACE);
#else
    return renameatx_np(source_directory, source, destination_directory, destination, RENAME_EXCL);
#endif
}
