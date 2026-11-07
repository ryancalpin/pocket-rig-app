#include "include/CMoonlight.h"
#include <stdarg.h>
#include <stdio.h>

static PRLogSink gSink = NULL;

void PRSetLogSink(PRLogSink sink) { gSink = sink; }

static void PRLogTrampoline(const char *format, ...) {
    if (gSink == NULL) return;
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    gSink(buffer);
}

void PRInstallLogCallback(PCONNECTION_LISTENER_CALLBACKS callbacks) {
    callbacks->logMessage = PRLogTrampoline;
}
