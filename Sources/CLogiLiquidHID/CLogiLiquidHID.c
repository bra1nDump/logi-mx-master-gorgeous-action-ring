#include "CLogiLiquidHID.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach/mach_error.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    LLH_REPORT_QUEUE_CAPACITY = 128,
};

typedef struct {
    uint8_t bytes[LLH_MAX_REPORT_CAPACITY];
    size_t length;
} LLHQueuedReport;

struct LLHSession {
    // Retain the manager that produced `device` for the full session. Releasing
    // it immediately after enumeration can deliver a removal callback even
    // though the Bluetooth device itself is still connected.
    IOHIDManagerRef manager;
    IOHIDDeviceRef device;
    dispatch_queue_t callback_queue;
    dispatch_semaphore_t cancellation_semaphore;
    uint8_t callback_buffer[LLH_MAX_REPORT_CAPACITY];

    pthread_mutex_t transaction_mutex;
    pthread_mutex_t state_mutex;
    pthread_cond_t state_changed;

    bool connected;
    bool closing;
    bool removal_callback_received;
    IOReturn removal_result;
    bool transaction_active;
    uint8_t expected_report_id;
    uint8_t expected_device_index;
    uint8_t expected_feature_index;
    uint8_t expected_function_id;
    uint8_t expected_software_id;
    uint8_t expected_function_software_byte;
    uint8_t transaction_response[LLH_MAX_REPORT_CAPACITY];
    size_t transaction_response_length;

    LLHQueuedReport report_queue[LLH_REPORT_QUEUE_CAPACITY];
    size_t report_queue_head;
    size_t report_queue_count;
    uint64_t dropped_report_count;
};

static void write_error(char *destination, size_t capacity, const char *message) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    snprintf(destination, capacity, "%s", message);
}

static void clear_error(char *destination, size_t capacity) {
    if (destination != NULL && capacity > 0) {
        destination[0] = '\0';
    }
}

static int32_t number_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return -1;
    }

    int32_t result = -1;
    CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &result);
    return result;
}

static void string_property(
    IOHIDDeviceRef device,
    CFStringRef key,
    char *destination,
    size_t capacity
) {
    if (capacity == 0) {
        return;
    }
    destination[0] = '\0';

    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return;
    }

    CFStringGetCString(
        (CFStringRef)value,
        destination,
        (CFIndex)capacity,
        kCFStringEncodingUTF8
    );
}

static uint64_t registry_id(IOHIDDeviceRef device) {
    io_service_t service = IOHIDDeviceGetService(device);
    uint64_t identifier = 0;
    if (service != MACH_PORT_NULL) {
        IORegistryEntryGetRegistryEntryID(service, &identifier);
    }
    return identifier;
}

static void inspect_elements(
    IOHIDDeviceRef device,
    bool *has_ff43,
    bool *has_report_11
) {
    *has_ff43 = false;
    *has_report_11 = false;

    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(
        device,
        NULL,
        kIOHIDOptionsTypeNone
    );
    if (elements == NULL) {
        return;
    }

    CFIndex count = CFArrayGetCount(elements);
    for (CFIndex index = 0; index < count; index++) {
        IOHIDElementRef element =
            (IOHIDElementRef)CFArrayGetValueAtIndex(elements, index);
        if (IOHIDElementGetUsagePage(element) == 0xFF43) {
            *has_ff43 = true;
        }
        if (IOHIDElementGetReportID(element) == 0x11) {
            *has_report_11 = true;
        }
    }

    CFRelease(elements);
}

static IOHIDManagerRef create_logitech_manager(void) {
    IOHIDManagerRef manager = IOHIDManagerCreate(
        kCFAllocatorDefault,
        kIOHIDOptionsTypeNone
    );
    if (manager == NULL) {
        return NULL;
    }

    int32_t vendor = 0x046D;
    CFNumberRef vendor_number = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt32Type,
        &vendor
    );
    const void *keys[] = { CFSTR(kIOHIDVendorIDKey) };
    const void *values[] = { vendor_number };
    CFDictionaryRef matching = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(matching);
    CFRelease(vendor_number);
    return manager;
}

typedef struct {
    LLHDeviceInfo *devices;
    size_t capacity;
    size_t count;
} CopyDevicesContext;

static void copy_device(const void *value, void *raw_context) {
    CopyDevicesContext *context = (CopyDevicesContext *)raw_context;
    IOHIDDeviceRef device = (IOHIDDeviceRef)value;
    size_t index = context->count;
    context->count += 1;

    if (index >= context->capacity || context->devices == NULL) {
        return;
    }

    LLHDeviceInfo *result = &context->devices[index];
    memset(result, 0, sizeof(*result));
    result->registry_id = registry_id(device);
    result->vendor_id = number_property(device, CFSTR(kIOHIDVendorIDKey));
    result->product_id = number_property(device, CFSTR(kIOHIDProductIDKey));
    result->version_number = number_property(device, CFSTR(kIOHIDVersionNumberKey));
    result->location_id = number_property(device, CFSTR(kIOHIDLocationIDKey));
    result->primary_usage_page =
        number_property(device, CFSTR(kIOHIDPrimaryUsagePageKey));
    result->primary_usage = number_property(device, CFSTR(kIOHIDPrimaryUsageKey));
    result->max_input_report_size =
        number_property(device, CFSTR(kIOHIDMaxInputReportSizeKey));
    result->max_output_report_size =
        number_property(device, CFSTR(kIOHIDMaxOutputReportSizeKey));
    inspect_elements(
        device,
        &result->has_vendor_usage_page_ff43,
        &result->has_hidpp_long_report_11
    );

    string_property(
        device,
        CFSTR(kIOHIDProductKey),
        result->product,
        sizeof(result->product)
    );
    string_property(
        device,
        CFSTR(kIOHIDManufacturerKey),
        result->manufacturer,
        sizeof(result->manufacturer)
    );
    string_property(
        device,
        CFSTR(kIOHIDTransportKey),
        result->transport,
        sizeof(result->transport)
    );
    string_property(
        device,
        CFSTR(kIOHIDSerialNumberKey),
        result->serial_number,
        sizeof(result->serial_number)
    );
}

size_t llh_copy_logitech_devices(LLHDeviceInfo *devices, size_t capacity) {
    IOHIDManagerRef manager = create_logitech_manager();
    if (manager == NULL) {
        return 0;
    }

    CFSetRef device_set = IOHIDManagerCopyDevices(manager);
    if (device_set == NULL) {
        CFRelease(manager);
        return 0;
    }

    CopyDevicesContext context = {
        .devices = devices,
        .capacity = capacity,
        .count = 0,
    };
    CFSetApplyFunction(device_set, copy_device, &context);
    CFRelease(device_set);
    CFRelease(manager);
    return context.count;
}

typedef struct {
    uint64_t target_registry_id;
    IOHIDDeviceRef found;
} FindDeviceContext;

static void find_device(const void *value, void *raw_context) {
    FindDeviceContext *context = (FindDeviceContext *)raw_context;
    IOHIDDeviceRef device = (IOHIDDeviceRef)value;
    if (context->found == NULL &&
        registry_id(device) == context->target_registry_id) {
        context->found = device;
        CFRetain(device);
    }
}

static bool normalize_report(
    uint32_t report_id,
    const uint8_t *report,
    CFIndex report_length,
    uint8_t *normalized,
    size_t *normalized_length
) {
    *normalized_length = 0;
    if (report == NULL || report_length <= 0) {
        return false;
    }

    if (report[0] == 0x10 || report[0] == 0x11) {
        *normalized_length = (size_t)report_length;
        if (*normalized_length > LLH_MAX_REPORT_CAPACITY) {
            *normalized_length = LLH_MAX_REPORT_CAPACITY;
        }
        memcpy(normalized, report, *normalized_length);
        return true;
    }

    if (report_id == 0 || report_id > UINT8_MAX) {
        return false;
    }
    normalized[0] = (uint8_t)report_id;
    *normalized_length = (size_t)report_length + 1;
    if (*normalized_length > LLH_MAX_REPORT_CAPACITY) {
        *normalized_length = LLH_MAX_REPORT_CAPACITY;
    }
    memcpy(normalized + 1, report, *normalized_length - 1);
    return true;
}

static bool report_matches_transaction(
    LLHSession *session,
    const uint8_t *report,
    size_t length
) {
    if (!session->transaction_active || length < 4 ||
        report[0] != session->expected_report_id ||
        report[1] != session->expected_device_index) {
        return false;
    }

    bool normal_response =
        report[2] == session->expected_feature_index &&
        (report[3] & 0x0F) == session->expected_software_id &&
        ((report[3] >> 4) == session->expected_function_id ||
         (report[3] >> 4) == ((session->expected_function_id + 1) & 0x0F));

    // HID++ 2.0 errors use feature index 0xFF, then echo the original
    // feature index and function/software byte.
    bool error_response =
        length >= 6 &&
        report[2] == 0xFF &&
        report[3] == session->expected_feature_index &&
        report[4] == session->expected_function_software_byte;

    return normal_response || error_response;
}

static void enqueue_report_locked(
    LLHSession *session,
    const uint8_t *report,
    size_t length
) {
    if (session->report_queue_count == LLH_REPORT_QUEUE_CAPACITY) {
        session->report_queue_head =
            (session->report_queue_head + 1) % LLH_REPORT_QUEUE_CAPACITY;
        session->report_queue_count -= 1;
        session->dropped_report_count += 1;
    }

    size_t tail = (session->report_queue_head + session->report_queue_count) %
        LLH_REPORT_QUEUE_CAPACITY;
    LLHQueuedReport *queued = &session->report_queue[tail];
    queued->length = length;
    memcpy(queued->bytes, report, length);
    session->report_queue_count += 1;
}

static void input_report_callback(
    void *raw_context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t report_id,
    uint8_t *report,
    CFIndex report_length
) {
    (void)sender;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput) {
        return;
    }

    LLHSession *session = (LLHSession *)raw_context;
    uint8_t normalized[LLH_MAX_REPORT_CAPACITY] = {0};
    size_t normalized_length = 0;
    if (!normalize_report(
            report_id,
            report,
            report_length,
            normalized,
            &normalized_length
        ) || normalized_length == 0) {
        return;
    }

    pthread_mutex_lock(&session->state_mutex);
    if (report_matches_transaction(session, normalized, normalized_length)) {
        memcpy(
            session->transaction_response,
            normalized,
            normalized_length
        );
        session->transaction_response_length = normalized_length;
        session->transaction_active = false;
    } else {
        enqueue_report_locked(session, normalized, normalized_length);
    }
    pthread_cond_broadcast(&session->state_changed);
    pthread_mutex_unlock(&session->state_mutex);
}

static void removal_callback(
    void *raw_context,
    IOReturn result,
    void *sender
) {
    (void)result;
    (void)sender;
    LLHSession *session = (LLHSession *)raw_context;
    pthread_mutex_lock(&session->state_mutex);
    session->removal_callback_received = true;
    session->removal_result = result;
    session->connected = false;
    pthread_cond_broadcast(&session->state_changed);
    pthread_mutex_unlock(&session->state_mutex);
}

static struct timespec deadline_after_milliseconds(int32_t timeout_ms) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    if (timeout_ms < 0) {
        timeout_ms = 0;
    }
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }
    return deadline;
}

int32_t llh_session_open(
    uint64_t target_registry_id,
    LLHSession **out_session,
    char *error_message,
    size_t error_message_capacity
) {
    if (out_session == NULL) {
        write_error(error_message, error_message_capacity, "session output is required");
        return -1;
    }
    *out_session = NULL;

    IOHIDManagerRef manager = create_logitech_manager();
    if (manager == NULL) {
        write_error(error_message, error_message_capacity, "could not create IOHIDManager");
        return -2;
    }
    CFSetRef device_set = IOHIDManagerCopyDevices(manager);
    if (device_set == NULL) {
        CFRelease(manager);
        write_error(error_message, error_message_capacity, "no Logitech IOHID devices found");
        return -3;
    }

    FindDeviceContext find_context = {
        .target_registry_id = target_registry_id,
        .found = NULL,
    };
    CFSetApplyFunction(device_set, find_device, &find_context);
    CFRelease(device_set);
    if (find_context.found == NULL) {
        CFRelease(manager);
        write_error(error_message, error_message_capacity, "target registry ID was not found");
        return -4;
    }

    LLHSession *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        CFRelease(find_context.found);
        CFRelease(manager);
        write_error(error_message, error_message_capacity, "could not allocate HID session");
        return -5;
    }
    session->manager = manager;
    session->device = find_context.found;
    session->connected = true;

    if (pthread_mutex_init(&session->transaction_mutex, NULL) != 0 ||
        pthread_mutex_init(&session->state_mutex, NULL) != 0 ||
        pthread_cond_init(&session->state_changed, NULL) != 0) {
        CFRelease(session->device);
        CFRelease(session->manager);
        free(session);
        write_error(error_message, error_message_capacity, "could not initialize HID session synchronization");
        return -6;
    }

    IOReturn open_result =
        IOHIDDeviceOpen(session->device, kIOHIDOptionsTypeNone);
    if (open_result != kIOReturnSuccess) {
        char buffer[256];
        snprintf(
            buffer,
            sizeof(buffer),
            "IOHIDDeviceOpen failed: %s (0x%08x)",
            mach_error_string(open_result),
            open_result
        );
        write_error(error_message, error_message_capacity, buffer);
        pthread_cond_destroy(&session->state_changed);
        pthread_mutex_destroy(&session->state_mutex);
        pthread_mutex_destroy(&session->transaction_mutex);
        CFRelease(session->device);
        CFRelease(session->manager);
        free(session);
        return -7;
    }

    session->callback_queue = dispatch_queue_create(
        "com.logiliquid.controls.hid-input",
        DISPATCH_QUEUE_SERIAL
    );
    session->cancellation_semaphore = dispatch_semaphore_create(0);
    if (session->callback_queue == NULL ||
        session->cancellation_semaphore == NULL) {
        IOHIDDeviceClose(session->device, kIOHIDOptionsTypeNone);
        pthread_cond_destroy(&session->state_changed);
        pthread_mutex_destroy(&session->state_mutex);
        pthread_mutex_destroy(&session->transaction_mutex);
        CFRelease(session->device);
        CFRelease(session->manager);
        free(session);
        write_error(error_message, error_message_capacity, "could not create HID callback queue");
        return -8;
    }

    IOHIDDeviceRegisterInputReportCallback(
        session->device,
        session->callback_buffer,
        sizeof(session->callback_buffer),
        input_report_callback,
        session
    );
    IOHIDDeviceRegisterRemovalCallback(
        session->device,
        removal_callback,
        session
    );
    IOHIDDeviceSetDispatchQueue(session->device, session->callback_queue);
    dispatch_semaphore_t cancellation = session->cancellation_semaphore;
    IOHIDDeviceSetCancelHandler(session->device, ^{
        dispatch_semaphore_signal(cancellation);
    });
    IOHIDDeviceActivate(session->device);

    *out_session = session;
    clear_error(error_message, error_message_capacity);
    return 0;
}

void llh_session_close(LLHSession *session) {
    if (session == NULL) {
        return;
    }

    pthread_mutex_lock(&session->transaction_mutex);
    pthread_mutex_lock(&session->state_mutex);
    session->closing = true;
    session->connected = false;
    session->transaction_active = false;
    pthread_cond_broadcast(&session->state_changed);
    pthread_mutex_unlock(&session->state_mutex);

    IOHIDDeviceCancel(session->device);
    dispatch_semaphore_wait(
        session->cancellation_semaphore,
        DISPATCH_TIME_FOREVER
    );
    IOHIDDeviceClose(session->device, kIOHIDOptionsTypeNone);
    CFRelease(session->device);
    CFRelease(session->manager);
#if !OS_OBJECT_USE_OBJC
    dispatch_release(session->cancellation_semaphore);
    dispatch_release(session->callback_queue);
#endif

    pthread_mutex_unlock(&session->transaction_mutex);
    pthread_cond_destroy(&session->state_changed);
    pthread_mutex_destroy(&session->state_mutex);
    pthread_mutex_destroy(&session->transaction_mutex);
    free(session);
}

bool llh_session_is_connected(LLHSession *session) {
    if (session == NULL) {
        return false;
    }
    pthread_mutex_lock(&session->state_mutex);
    bool connected = session->connected && !session->closing;
    pthread_mutex_unlock(&session->state_mutex);
    return connected;
}

uint64_t llh_session_dropped_report_count(LLHSession *session) {
    if (session == NULL) {
        return 0;
    }
    pthread_mutex_lock(&session->state_mutex);
    uint64_t count = session->dropped_report_count;
    pthread_mutex_unlock(&session->state_mutex);
    return count;
}

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
) {
    if (response_length != NULL) {
        *response_length = 0;
    }
    if (session == NULL) {
        write_error(error_message, error_message_capacity, "HID session is not open");
        return -1;
    }
    if (request == NULL || request_length != 20 || request[0] != 0x11) {
        write_error(error_message, error_message_capacity, "request must be one 20-byte HID++ long report (0x11)");
        return -2;
    }

    pthread_mutex_lock(&session->transaction_mutex);
    pthread_mutex_lock(&session->state_mutex);
    if (!session->connected || session->closing) {
        pthread_mutex_unlock(&session->state_mutex);
        pthread_mutex_unlock(&session->transaction_mutex);
        write_error(error_message, error_message_capacity, "HID device is disconnected");
        return -3;
    }

    session->expected_report_id = request[0];
    session->expected_device_index = request[1];
    session->expected_feature_index = request[2];
    session->expected_function_id = request[3] >> 4;
    session->expected_software_id = request[3] & 0x0F;
    session->expected_function_software_byte = request[3];
    session->transaction_response_length = 0;
    session->transaction_active = true;
    pthread_mutex_unlock(&session->state_mutex);

    IOReturn write_result = IOHIDDeviceSetReport(
        session->device,
        kIOHIDReportTypeOutput,
        request[0],
        request,
        (CFIndex)request_length
    );
    if (write_result != kIOReturnSuccess) {
        pthread_mutex_lock(&session->state_mutex);
        session->transaction_active = false;
        pthread_mutex_unlock(&session->state_mutex);
        pthread_mutex_unlock(&session->transaction_mutex);
        char buffer[256];
        snprintf(
            buffer,
            sizeof(buffer),
            "IOHIDDeviceSetReport failed: %s (0x%08x)",
            mach_error_string(write_result),
            write_result
        );
        write_error(error_message, error_message_capacity, buffer);
        return -4;
    }

    struct timespec deadline = deadline_after_milliseconds(timeout_ms);
    pthread_mutex_lock(&session->state_mutex);
    int wait_result = 0;
    while (session->transaction_active && session->connected &&
           !session->closing && wait_result != ETIMEDOUT) {
        wait_result = pthread_cond_timedwait(
            &session->state_changed,
            &session->state_mutex,
            &deadline
        );
    }

    if (session->transaction_active) {
        session->transaction_active = false;
        bool disconnected = !session->connected || session->closing;
        pthread_mutex_unlock(&session->state_mutex);
        pthread_mutex_unlock(&session->transaction_mutex);
        write_error(
            error_message,
            error_message_capacity,
            disconnected
                ? "HID device disconnected while waiting for a response"
                : "timed out waiting for a matching HID++ response"
        );
        return disconnected ? -5 : -6;
    }

    size_t length = session->transaction_response_length;
    if (response == NULL || response_capacity < length) {
        pthread_mutex_unlock(&session->state_mutex);
        pthread_mutex_unlock(&session->transaction_mutex);
        write_error(error_message, error_message_capacity, "response buffer is too small");
        return -7;
    }
    memcpy(response, session->transaction_response, length);
    pthread_mutex_unlock(&session->state_mutex);
    pthread_mutex_unlock(&session->transaction_mutex);

    if (response_length != NULL) {
        *response_length = length;
    }
    clear_error(error_message, error_message_capacity);
    return 0;
}

int32_t llh_session_next_report(
    LLHSession *session,
    uint8_t *report,
    size_t report_capacity,
    size_t *report_length,
    int32_t timeout_ms,
    char *error_message,
    size_t error_message_capacity
) {
    if (report_length != NULL) {
        *report_length = 0;
    }
    if (session == NULL) {
        write_error(error_message, error_message_capacity, "HID session is not open");
        return -1;
    }

    struct timespec deadline = deadline_after_milliseconds(timeout_ms);
    pthread_mutex_lock(&session->state_mutex);
    int wait_result = 0;
    while (session->report_queue_count == 0 && session->connected &&
           !session->closing && wait_result != ETIMEDOUT) {
        wait_result = pthread_cond_timedwait(
            &session->state_changed,
            &session->state_mutex,
            &deadline
        );
    }

    if (session->report_queue_count == 0) {
        bool disconnected = !session->connected || session->closing;
        pthread_mutex_unlock(&session->state_mutex);
        if (disconnected) {
            char buffer[256];
            if (session->removal_callback_received) {
                snprintf(
                    buffer,
                    sizeof(buffer),
                    "HID device removal callback: %s (0x%08x)",
                    mach_error_string(session->removal_result),
                    session->removal_result
                );
            } else {
                snprintf(buffer, sizeof(buffer), "HID device is disconnected");
            }
            write_error(error_message, error_message_capacity, buffer);
            return -2;
        }
        clear_error(error_message, error_message_capacity);
        return 1;
    }

    LLHQueuedReport *queued = &session->report_queue[session->report_queue_head];
    if (report == NULL || report_capacity < queued->length) {
        pthread_mutex_unlock(&session->state_mutex);
        write_error(error_message, error_message_capacity, "report buffer is too small");
        return -3;
    }

    size_t length = queued->length;
    memcpy(report, queued->bytes, length);
    session->report_queue_head =
        (session->report_queue_head + 1) % LLH_REPORT_QUEUE_CAPACITY;
    session->report_queue_count -= 1;
    pthread_mutex_unlock(&session->state_mutex);

    if (report_length != NULL) {
        *report_length = length;
    }
    clear_error(error_message, error_message_capacity);
    return 0;
}
