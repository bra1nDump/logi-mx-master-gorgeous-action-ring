#ifndef C_LOGI_LIQUID_CURSOR_H
#define C_LOGI_LIQUID_CURSOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  LLC_BACKGROUND_CURSOR_OK = 0,
  LLC_BACKGROUND_CURSOR_APPLICATION_SERVICES_UNAVAILABLE = -1,
  LLC_BACKGROUND_CURSOR_DEFAULT_CONNECTION_UNAVAILABLE = -2,
  LLC_BACKGROUND_CURSOR_PROPERTY_SETTER_UNAVAILABLE = -3,
};

/// Enables cursor mutation from this background process's WindowServer
/// connection. Returns zero on success, a negative capability error when the
/// private symbols cannot be resolved, or the positive CGError returned by
/// WindowServer.
int32_t llc_enable_background_cursor_control(void);

#ifdef __cplusplus
}
#endif

#endif
