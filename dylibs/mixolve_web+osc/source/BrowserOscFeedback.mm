// FUNCTIONAL REIMPLEMENTATION, NOT THE ORIGINAL OBJECTIVE-C++ SOURCE.
// Confirmed from binary: class/property/method names, JSON key names,
// loopback UDP listen socket, nonblocking recv, OSC input/output,
// action enumeration and polling periods (reload 1s, enumerate 2s).
// Inferred: some defaults, action filtering, snapshot interval, error policy.
#import "RecoveredInterfaces.h"
#import "RecoveredReaperCallbacks.hpp"
#import "OscCodec.hpp"
#import "ActionDispatch.hpp"
#include <arpa/inet.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
#include <limits>
#include <cstdlib>

static RecoveredReaperCallbacks gReaper;
void installRecoveredReaperCallbacks(RecoveredReaperCallbacks callbacks) { gReaper = callbacks; }
RecoveredReaperCallbacks recoveredReaperCallbacks() { return gReaper; }

static int parsePort(id obj) {
    if (![obj isKindOfClass:NSNumber.class]) return 0;
    int v = [obj intValue];
    return (v > 0 && v <= 65535) ? v : 0;
}

@implementation BrowserOscFeedback
- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _states = [NSMutableDictionary dictionary];
        _watches = @[];
        _receiveFD = -1;
        _socketFD = socket(AF_INET, SOCK_DGRAM, 0);
        _destination = {};
        [self reloadConfig];
    }
    return self;
}

- (void)reloadConfig {
    NSData *raw = [NSData dataWithContentsOfFile:self.path];
    if (!raw || [raw isEqual:self.lastConfig]) return;
    NSError *jsonError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:raw options:0 error:&jsonError];
    if (![value isKindOfClass:NSDictionary.class]) {
        NSLog(@"Browser OSC: invalid JSON in %@", self.path);
        return;
    }
    NSDictionary *config = (NSDictionary *)value;
    id hostValue = config[@"host"];
    NSString *host = [hostValue isKindOfClass:NSString.class] ? hostValue : @"127.0.0.1";
    int port = parsePort(config[@"port"]);
    int listenPort = parsePort(config[@"listenPort"]);
    BOOL enable = [config[@"enabled"] respondsToSelector:@selector(boolValue)]
        ? [config[@"enabled"] boolValue] : NO;

    struct sockaddr_in target = {};
    target.sin_len = sizeof(target); // macOS-specific field
    target.sin_family = AF_INET;
    target.sin_port = htons(static_cast<uint16_t>(port));
    if (port == 0 || inet_pton(AF_INET, host.UTF8String, &target.sin_addr) != 1) {
        NSLog(@"Browser OSC: invalid destination/reapers in %@; keeping previous configuration", self.path);
        return;
    }
    self.lastConfig = raw;
    self.destination = target;
    self.enabled = enable;
    self.nextEnumeration = 0;

    // Only the local loopback interface is exposed, matching the binary.
    if (self.receiveFD != -1 && (!enable || self.listenPort != listenPort)) {
        close(self.receiveFD);
        self.receiveFD = -1;
    }
    if (enable && listenPort != 0 && self.receiveFD == -1) {
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in bindAddr = {};
        bindAddr.sin_len = sizeof(bindAddr);
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_port = htons(static_cast<uint16_t>(listenPort));
        inet_pton(AF_INET, "127.0.0.1", &bindAddr.sin_addr);
        if (fd >= 0 && bind(fd, reinterpret_cast<sockaddr *>(&bindAddr), sizeof(bindAddr)) == 0) {
            int flags = fcntl(fd, F_GETFL, 0);
            if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            self.receiveFD = fd;
            self.listenPort = listenPort;
        } else {
            if (fd >= 0) close(fd);
            NSLog(@"Browser OSC: cannot listen on 127.0.0.1:%d", listenPort);
        }
    }
    if (!enable) self.listenPort = 0;
    [self.states removeAllObjects];
    self.nextSnapshot = 0;
    self.snapshotPending = YES;
}

- (void)enumerateActions {
    // The original enumerates the Main action section, keeping only those
    // whose toggle state is 0 or 1, and adds a named alias when present.
    if (!gReaper.enumerateAction || !gReaper.getToggleState) return;
    NSMutableArray *results = [NSMutableArray array];
    NSMutableSet *valid = [NSMutableSet set];
    for (size_t index = 0; index < 100000; ++index) {
        int commandID = 0;
        const char *actionDescription = nullptr;
        if (!gReaper.enumerateAction(index, &commandID, &actionDescription)) break;
        if (commandID <= 0) continue;
        const int state = gReaper.getToggleState(commandID);
        if (state != 0 && state != 1) continue;
        NSString *numeric = [NSString stringWithFormat:@"/reaper/%d", commandID];
        if (![valid containsObject:numeric]) {
            [results addObject:@{@"id": @(commandID), @"address": numeric}];
            [valid addObject:numeric];
        }
        if (gReaper.reverseNamedCommandLookup) {
            const char *name = gReaper.reverseNamedCommandLookup(commandID);
            if (name && *name) {
                NSString *alias = [NSString stringWithUTF8String:name];
                if (alias.length) {
                    if (![alias hasPrefix:@"_"]) alias = [@"_" stringByAppendingString:alias];
                    NSString *address = [@"/reaper/" stringByAppendingString:alias];
                    if (![valid containsObject:address]) {
                        [results addObject:@{@"id": @(commandID), @"address": address}];
                        [valid addObject:address];
                    }
                }
            }
        }
    }
    self.watches = results;
    for (NSString *key in self.states.allKeys) {
        if (![valid containsObject:key]) [self.states removeObjectForKey:key];
    }
}

- (void)tick {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now >= self.nextReload) {
        [self reloadConfig];
        self.nextReload = now + 1.0;
    }
    if (!self.enabled || self.socketFD < 0) return;

    if (self.receiveFD >= 0) {
        uint8_t bytes[2048];
        // Avoid starving UI updates on a flood of UDP messages.
        for (int i = 0; i < 64; ++i) {
            ssize_t n = recv(self.receiveFD, bytes, sizeof(bytes), 0);
            if (n <= 0) break;
            auto message = recovered::parseOsc(bytes, static_cast<size_t>(n));
            if (!message) continue;
            auto request = recovered::actionRequest(*message);
            if (request) recovered::dispatchAction(*request, gReaper);
        }
    }
    if (now >= self.nextEnumeration) {
        [self enumerateActions];
        self.nextEnumeration = now + 2.0;
    }
    const BOOL snapshot = self.snapshotPending || now >= self.nextSnapshot;
    if (snapshot) [self.states removeAllObjects];
    for (NSDictionary *item in self.watches) {
        NSNumber *commandID = item[@"id"];
        NSString *address = item[@"address"];
        if (!commandID || !address || !gReaper.getToggleState) continue;
        int state = gReaper.getToggleState(commandID.intValue);
        if (state < 0) continue;
        NSNumber *cached = self.states[address];
        if (!snapshot && cached && cached.intValue == state) continue;
        auto packet = recovered::statePacket(address.UTF8String, state);
        const struct sockaddr_in dest = self.destination;
        ssize_t sent = sendto(self.socketFD, packet.data(), packet.size(), 0,
                              reinterpret_cast<const struct sockaddr *>(&dest), sizeof(dest));
        if (sent == static_cast<ssize_t>(packet.size())) self.states[address] = @(state);
    }
    if (snapshot) {
        self.nextSnapshot = now + 5.0; // snapshot interval; see binary analysis
        self.snapshotPending = NO;
    }
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    if (self.socketFD >= 0) { close(self.socketFD); self.socketFD = -1; }
    if (self.receiveFD >= 0) { close(self.receiveFD); self.receiveFD = -1; }
}

- (void)dealloc {
    // Under ARC, dealloc cannot call [super dealloc].
    [self stop];
}
@end
