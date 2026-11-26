#import "RecoveredInterfaces.h"
#import "RecoveredReaperCallbacks.hpp"
#import "OscCodec.hpp"
#import "ActionDispatch.hpp"
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

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
}

- (void)sendState:(int)state toAddress:(const std::string &)address {
    auto packet = recovered::statePacket(address, state);
    const struct sockaddr_in destination = self.destination;
    sendto(self.socketFD, packet.data(), packet.size(), MSG_DONTWAIT,
           reinterpret_cast<const struct sockaddr *>(&destination), sizeof(destination));
}

- (void)sendStateForAction:(int)commandID {
    if (!gReaper.getToggleState) return;
    const int state = gReaper.getToggleState(commandID);
    if (state != 0 && state != 1) return;

    [self sendState:state toAddress:"/reaper/" + std::to_string(commandID)];
    const char *name = gReaper.reverseNamedCommandLookup
        ? gReaper.reverseNamedCommandLookup(commandID) : nullptr;
    if (name && *name) {
        std::string address = "/reaper/";
        if (*name != '_') address += '_';
        address += name;
        [self sendState:state toAddress:address];
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
            if (!request) continue;
            const int commandID = recovered::dispatchAction(*request, gReaper);
            if (commandID > 0) [self sendStateForAction:commandID];
        }
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
