#include "CLogiLiquidCursor.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <pthread.h>

typedef int32_t (*LLCCGSDefaultConnectionFunction)(void);
typedef CGError (*LLCCGSSetConnectionPropertyFunction)(int32_t, int32_t,
                                                       CFStringRef, CFTypeRef);

static pthread_once_t llc_application_services_once = PTHREAD_ONCE_INIT;
static void *llc_application_services = NULL;

static void llc_open_application_services(void) {
  llc_application_services =
      dlopen("/System/Library/Frameworks/ApplicationServices.framework/"
             "ApplicationServices",
             RTLD_LAZY | RTLD_LOCAL);
}

int32_t llc_enable_background_cursor_control(void) {
  pthread_once(&llc_application_services_once, llc_open_application_services);
  if (llc_application_services == NULL) {
    return LLC_BACKGROUND_CURSOR_APPLICATION_SERVICES_UNAVAILABLE;
  }

  LLCCGSDefaultConnectionFunction default_connection =
      (LLCCGSDefaultConnectionFunction)dlsym(llc_application_services,
                                             "_CGSDefaultConnection");
  if (default_connection == NULL) {
    return LLC_BACKGROUND_CURSOR_DEFAULT_CONNECTION_UNAVAILABLE;
  }

  LLCCGSSetConnectionPropertyFunction set_connection_property =
      (LLCCGSSetConnectionPropertyFunction)dlsym(llc_application_services,
                                                 "CGSSetConnectionProperty");
  if (set_connection_property == NULL) {
    return LLC_BACKGROUND_CURSOR_PROPERTY_SETTER_UNAVAILABLE;
  }

  int32_t connection = default_connection();
  return set_connection_property(
      connection, connection, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
}
