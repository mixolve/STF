#pragma once
// Lightweight breadcrumb log for diagnosing crashes inside a host process.
// Deliberately does not install signal handlers or interfere with REAPER.
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/time.h>
#include <unistd.h>

inline void webOscTrace(const char *stage) {
    if (!stage) return;
    const char *home = std::getenv("HOME");
    if (!home || !*home) return;
    char path[2048];
    int n = std::snprintf(path, sizeof(path), "%s/Library/Logs/reaper-web-osc.log", home);
    if (n < 0 || static_cast<size_t>(n) >= sizeof(path)) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    struct timeval tv{};
    gettimeofday(&tv, nullptr);
    char line[768];
    int sz = std::snprintf(line, sizeof(line), "%lld.%03lld pid=%ld %s\n",
        static_cast<long long>(tv.tv_sec), static_cast<long long>(tv.tv_usec / 1000),
        static_cast<long>(getpid()), stage);
    if (sz > 0) {
        const size_t len = static_cast<size_t>(sz) < sizeof(line) ?
            static_cast<size_t>(sz) : sizeof(line) - 1;
        (void)write(fd, line, len);
    }
    close(fd);
}

// Objective-C exception diagnostics live behind the Objective-C++ guard.
#ifdef __OBJC__
#import <Foundation/Foundation.h>
inline void webOscTraceObjCException(const char *context, NSException *exception) {
    webOscTrace(context);
    NSString *details = [NSString stringWithFormat:@"%@ — %@", exception.name ?: @"Exception",
        exception.reason ?: @"no reason"];
    webOscTrace(details.UTF8String);
}
#endif
