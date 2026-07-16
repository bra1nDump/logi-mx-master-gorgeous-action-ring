#ifndef C_LOGI_LIQUID_HID_H
#define C_LOGI_LIQUID_HID_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    LLH_STRING_PRODUCT_CAPACITY = 256,
    LLH_STRING_MANUFACTURER_CAPACITY = 128,
    LLH_STRING_TRANSPORT_CAPACITY = 128,
    LLH_STRING_SERIAL_CAPACITY = 128,
    LLH_MAX_REPORT_CAPACITY = 64,
};

typedef struct {
    uint64_t registry_id;
    int32_t vendor_id;
    int32_t product_id;
    int32_t version_number;
    int32_t location_id;
    int32_t primary_usage_page;
    int32_t primary_usage;
    int32_t max_input_report_size;
    int32_t max_output_report_size;
    bool has_vendor_usage_page_ff43;
    bool has_hidpp_long_report_11;
    char product[LLH_STRING_PRODUCT_CAPACITY];
    char manufacturer[LLH_STRING_MANUFACTURER_CAPACITY];
    char transport[LLH_STRING_TRANSPORT_CAPACITY];
    char serial_number[LLH_STRING_SERIAL_CAPACITY];
} LLHDeviceInfo;

/// An open, non-exclusive IOHID connection to one already-paired device.
typedef struct LLHSession LLHSession;

/// Copies Logitech IOHID devices (vendor 0x046D) into `devices`.
/// Returns the total matching count even when it exceeds `capacity`.
size_t llh_copy_logitech_devices(LLHDeviceInfo *devices, size_t capacity);

/// Opens one device and starts a persistent input-report listener.
/// Returns 0 on success. The caller owns the returned session.
int32_t llh_session_open(
    uint64_t registry_id,
    LLHSession **session,
    char *error_message,
    size_t error_message_capacity
);

/// Closes the IOHID connection and releases the session. Safe for NULL.
void llh_session_close(LLHSession *session);

/// Whether the device remains connected to this session.
bool llh_session_is_connected(LLHSession *session);

/// Number of unsolicited input reports discarded because the bounded queue
/// filled before a consumer read them.
uint64_t llh_session_dropped_report_count(LLHSession *session);

/// Serializes one HID++ request against all other transactions on this session.
/// Matching is based on device index, feature index, and software ID. Unmatched
/// input reports stay available through `llh_session_next_report`.
/// Returns 0 on success.
int32_t llh_session_transact(
    LLHSession *session,
    const uint8_t *request,
    size_t request_length,
    uint8_t *response,
    size_t response_capacity,
    size_t *response_length,
    int32_t timeout_ms,
    char *error_message,
    size_t error_message_capacity
);

/// Waits for the next unsolicited input report.
/// Returns 0 on success, 1 on timeout, and a negative value on failure.
int32_t llh_session_next_report(
    LLHSession *session,
    uint8_t *report,
    size_t report_capacity,
    size_t *report_length,
    int32_t timeout_ms,
    char *error_message,
    size_t error_message_capacity
);

#ifdef __cplusplus
}
#endif

#endif
