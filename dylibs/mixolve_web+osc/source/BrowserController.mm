// AppKit browser for the recovered REAPER extension.
// Dock using host-created SWELL HWND; floating mode remains available.
#import "RecoveredInterfaces.h"
#import "RecoveredReaperCallbacks.hpp"
#include "CrashTrace.hpp"
#include "ToolbarLayout.hpp"
#include "ToolbarVisibility.hpp"
#import <arpa/inet.h>
#include <cmath>
#include <cstdio>

static NSString *const kExtSection = @"CustomWebBrowser";
static NSString *const kOscConfigName = @"browser-osc-feedback.json";
static const char *kLastPageKey = "last_url";
// URL is documented as KVO-compliant on WKWebView. Watch it so address
// changes made through history.pushState/replaceState are remembered too.
static void *kPageURLObservationContext = &kPageURLObservationContext;

@interface BrowserController () {
    webOscVisibility::State _toolbarVisibility;
}
- (void)updateToolbarHover;
- (void)popupDidOpen:(NSNotification *)notification;
- (void)popupDidClose:(NSNotification *)notification;
@property (nonatomic, strong) NSCountedSet *activeToolbarPopups;
@property (nonatomic, strong) NSLayoutConstraint *controlPanelHeightConstraint;
@property (nonatomic, strong) NSTimer *toolbarHoverTimer;
@property (nonatomic, strong) NSView *listenGroup;
@property (nonatomic, strong) NSView *hostGroup;
@property (nonatomic, strong) NSView *sendGroup;
@property (nonatomic) BOOL shuttingDown;
@property (nonatomic) BOOL dockTransitioning;
@property (nonatomic) BOOL observingPageURL;
@property (nonatomic, copy) NSString *lastSavedPageURL;
@end

// A plain NSView has no painted background. In a floating NSWindow this is
// hidden by the window background, but when reparented into the REAPER SWELL
// Docker the transparent pixels expose the host underneath. Draw the panel
// ourselves and declare it opaque so AppKit composites it correctly in both.
@interface OpaqueBrowserControlPanel : NSView
@end
@implementation OpaqueBrowserControlPanel
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirtyRect);
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

@implementation BrowserWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) &&
        [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"l"]) {
        [self makeFirstResponder:self.addressField];
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

@implementation BrowserController
- (NSString *)oscConfigPath {
    auto callbacks = recoveredReaperCallbacks();
    const char *raw = callbacks.getResourcePath ? callbacks.getResourcePath() : nullptr;
    if (!raw || !*raw) return nil;
    NSString *base = [NSString stringWithUTF8String:raw];
    return [base stringByAppendingPathComponent:kOscConfigName];
}
- (NSButton *)button:(NSString *)title action:(SEL)selector {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:selector];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}
- (NSTextField *)oscField:(double)width flexible:(BOOL)flexible {
    (void)flexible;
    NSTextField *field = [NSTextField new];
    field.translatesAutoresizingMaskIntoConstraints = YES;
    field.frame = NSMakeRect(0, 0, width, webOscLayout::kControlHeight);
    return field;
}
- (NSTextField *)oscLabel:(NSString *)label { return [NSTextField labelWithString:label]; }

// A label and its value form an indivisible unit: neither is compressed.
- (NSView *)oscGroup:(NSString *)title field:(NSTextField *)field
              width:(CGFloat)width labelWidth:(CGFloat)labelWidth {
    const CGFloat h = webOscLayout::kControlHeight;
    NSView *group = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, h)];
    NSTextField *caption = [self oscLabel:title];
    caption.frame = NSMakeRect(0, 2, labelWidth, h - 4);
    field.frame = NSMakeRect(labelWidth + 4, 0, width - labelWidth - 4, h);
    [group addSubview:caption];
    [group addSubview:field];
    return group;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    webOscTrace("browser: minimal AppKit init begin");
    NSRect rect = NSMakeRect(180, 160, 960, 680);
    self.window = [[BrowserWindow alloc] initWithContentRect:rect
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    if (!self.window) { webOscTrace("browser: NSWindow returned nil"); return nil; }
    self.window.title = @"REAPER Web + OSC";
    // Do not let the titlebar or our panel impose the old wide minimum.
    self.window.contentMinSize = NSMakeSize(80, 100);
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];
    webOscTrace("browser: window constructed");

    NSView *root = [[NSView alloc] initWithFrame:rect];
    self.window.contentView = root;
    self.content = root;
    // One fixed-height bottom row; WebKit fills all remaining space above.
    self.controlPanel = [OpaqueBrowserControlPanel new];
    self.controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    // Make the bottom panel a separate compositing surface when hosted in SWELL.
    self.controlPanel.wantsLayer = YES;
    [root addSubview:self.controlPanel];

    // Frames are laid out explicitly so no intrinsic content widths can
    // prevent narrowing either the floating window or the REAPER Docker.
    self.address = [NSTextField new];
    self.address.translatesAutoresizingMaskIntoConstraints = YES;
    self.address.placeholderString = @"Enter URL (Cmd+L)";
    self.address.target = self;
    self.address.action = @selector(navigate:);
    self.address.delegate = self;
    self.window.addressField = self.address;
    [self.controlPanel addSubview:self.address];

    self.dockButton = [self button:@"Dock" action:@selector(toggleDock:)];
    self.dockButton.translatesAutoresizingMaskIntoConstraints = YES;
    [self.controlPanel addSubview:self.dockButton];

    self.oscInPort = [self oscField:56 flexible:NO];
    self.oscHost = [self oscField:134 flexible:NO];
    self.oscOutPort = [self oscField:56 flexible:NO];
    self.oscEnable = [NSButton checkboxWithTitle:@"Enabled"
                                           target:self action:@selector(toggleOscEnabled:)];
    self.oscEnable.translatesAutoresizingMaskIntoConstraints = YES;
    for (NSTextField *field in @[self.oscInPort, self.oscHost, self.oscOutPort]) {
        field.delegate = self;
        field.target = self;
        field.action = @selector(applyOscSettings:);
    }
    self.listenGroup = [self oscGroup:@"Listen" field:self.oscInPort
                               width:webOscLayout::kListenWidth labelWidth:38];
    self.hostGroup = [self oscGroup:@"Host" field:self.oscHost
                             width:webOscLayout::kHostWidth labelWidth:28];
    self.sendGroup = [self oscGroup:@"Send" field:self.oscOutPort
                             width:webOscLayout::kSendWidth labelWidth:30];
    [self.controlPanel addSubview:self.listenGroup];
    [self.controlPanel addSubview:self.hostGroup];
    [self.controlPanel addSubview:self.sendGroup];
    [self.controlPanel addSubview:self.oscEnable];

    // Hidden by default. Collapse the panel's Auto Layout height to zero so
    // WKWebView extends all the way down to the window/Docker's bottom edge.
    self.controlPanelHeightConstraint =
        [self.controlPanel.heightAnchor constraintEqualToConstant:0.0];
    [NSLayoutConstraint activateConstraints:@[
        [self.controlPanel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.controlPanel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.controlPanel.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        self.controlPanelHeightConstraint
    ]];
    self.controlPanel.hidden = YES;
    // Native menus, combo-box dropdowns and popovers can extend outside the
    // browser view. Keep the bottom toolbar shown while one is being used.
    // Pair begin/end notifications by popup object (including nested menus).
    self.activeToolbarPopups = [NSCountedSet new];
    NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[NSMenuDidBeginTrackingNotification,
                             NSComboBoxWillPopUpNotification,
                             NSPopoverWillShowNotification]) {
        [notifications addObserver:self selector:@selector(popupDidOpen:)
                             name:name object:nil];
    }
    for (NSString *name in @[NSMenuDidEndTrackingNotification,
                             NSComboBoxWillDismissNotification,
                             NSPopoverDidCloseNotification]) {
        [notifications addObserver:self selector:@selector(popupDidClose:)
                             name:name object:nil];
    }
    // Both floating-window and SWELL Docker resizing change the same root
    // NSView frame. Use a frame-change notification, not only NSWindowDelegate.
    root.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(browserRootFrameDidChange:)
        name:NSViewFrameDidChangeNotification object:root];
    [self updateResponsiveNavigation];
    webOscTrace("browser: adaptive 30pt toolbar hidden; 500ms bottom-edge reveal");

    // A visible native window exists before WebKit initialization. A WebKit
    // failure will no longer turn the Open action into an invisible no-op.
    webOscTrace("browser: creating WKWebView");
    @try {
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        self.web = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
        self.web.navigationDelegate = self;
        self.web.UIDelegate = self;
        self.web.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:self.web];
        [NSLayoutConstraint activateConstraints:@[
            [self.web.topAnchor constraintEqualToAnchor:root.topAnchor],
            [self.web.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [self.web.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [self.web.bottomAnchor constraintEqualToAnchor:self.controlPanel.topAnchor]
        ]];
        [self.web addObserver:self forKeyPath:@"URL"
                         options:NSKeyValueObservingOptionNew
                         context:kPageURLObservationContext];
        self.observingPageURL = YES;
        webOscTrace("browser: WKWebView ready; page URL observation active");
    } @catch (NSException *exception) {
        webOscTraceObjCException("browser: WKWebView exception", exception);
        webOscTrace("browser: WebKit unavailable; see diagnostic log");
    }
    @try { [self loadOscSettings]; }
    @catch (NSException *exception) {
        webOscTraceObjCException("browser: OSC configuration UI exception", exception);
    }
    // Do not depend on mouseMoved delivery from WKWebView or REAPER's SWELL
    // Docker. Poll the global pointer position in AppKit screen coordinates;
    // convert it to the current root view coordinates after every reparent.
    // The weak capture avoids a timer/controller retain cycle.
    __weak BrowserController *weakSelf = self;
    self.toolbarHoverTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES
        block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf updateToolbarHover];
        }];
    [[NSRunLoop mainRunLoop] addTimer:self.toolbarHoverTimer
                               forMode:NSRunLoopCommonModes];
    webOscTrace("browser: minimal AppKit init complete");
    return self;
}

- (void)loadOscSettings {
    NSString *configPath = [self oscConfigPath];
    NSData *data = configPath ? [NSData dataWithContentsOfFile:configPath] : nil;
    NSDictionary *json = nil;
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) json = parsed;
    }
    self.oscHost.stringValue = [json[@"host"] isKindOfClass:[NSString class]] ? json[@"host"] : @"127.0.0.1";
    self.oscInPort.stringValue = [json[@"listenPort"] respondsToSelector:@selector(stringValue)] ? [json[@"listenPort"] stringValue] : @"9003";
    self.oscOutPort.stringValue = [json[@"port"] respondsToSelector:@selector(stringValue)] ? [json[@"port"] stringValue] : @"8000";
    self.oscEnable.state = [json[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
}
// Show a complete control at its native width, or hide the complete unit.
// No minimum-width constraints, scrolling OSC container, or squeezing fields.
- (void)updateResponsiveNavigation {
    const auto layout = webOscLayout::compute(self.content.bounds.size.width);
    const CGFloat h = webOscLayout::kControlHeight;
    const CGFloat y = std::floor((webOscLayout::kPanelHeight - h) / 2.0);
    auto place = [=](NSView *view, webOscLayout::Item item) {
        view.hidden = !item.visible;
        if (item.visible)
            view.frame = NSMakeRect(item.x, y, item.width, h);
    };
    place(self.address, layout.address);
    place(self.dockButton, layout.dock);
    place(self.listenGroup, layout.listen);
    place(self.hostGroup, layout.host);
    place(self.sendGroup, layout.send);
    place(self.oscEnable, layout.enabled);
}
- (void)browserRootFrameDidChange:(NSNotification *)note {
    if (note.object == self.content) [self updateResponsiveNavigation];
}
- (void)windowDidResize:(NSNotification *)note {
    (void)note;
    [self updateResponsiveNavigation];
}
- (BOOL)saveOscEnabled:(BOOL)enabled {
    NSString *path = [self oscConfigPath];
    NSInteger input = self.oscInPort.integerValue, output = self.oscOutPort.integerValue;
    NSString *host = [self.oscHost.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    struct in_addr addr{};
    if (!path || input < 1 || input > 65535 || output < 1 || output > 65535 ||
        inet_pton(AF_INET, host.UTF8String, &addr) != 1) {
        webOscTrace("osc: invalid configuration: expected IPv4 address and ports 1-65535");
        return NO;
    }
    NSDictionary *config = @{@"enabled": @(enabled), @"host": host,
                             @"port": @(output), @"listenPort": @(input)};
    NSError *error = nil;
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&error];
    if (!bytes || ![bytes writeToFile:path options:NSDataWritingAtomic error:&error]) {
        webOscTrace(error.localizedDescription.UTF8String ?: "osc: cannot save configuration");
        return NO;
    }
    self.oscEnable.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    webOscTrace("osc: settings saved");
    return YES;
}
- (void)applyOscSettings:(id)sender { (void)sender; [self saveOscEnabled:self.oscEnable.state == NSControlStateValueOn]; }
- (void)toggleOscEnabled:(id)sender { [self applyOscSettings:sender]; }

// Persist only a URL that WKWebView is displaying. A requested URL can
// fail to load; recording it eagerly would overwrite the last working page.
- (void)persistCurrentPageURL {
    if (self.shuttingDown || !self.web) return;
    NSURL *url = self.web.URL;
    NSString *address = url.absoluteString;
    NSString *scheme = url.scheme.lowercaseString;
    if (!address.length ||
        (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"] &&
         ![address isEqualToString:@"about:blank"])) return;
    // Persistent REAPER ExtState values occupy a single line in an .ini file.
    if ([address rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound)
        return;
    if ([address isEqualToString:self.lastSavedPageURL]) return;
    auto api = recoveredReaperCallbacks();
    if (!api.setExtState) return;
    const char *utf8 = address.UTF8String;
    if (!utf8) return;
    api.setExtState(kExtSection.UTF8String, kLastPageKey, utf8, true);
    self.lastSavedPageURL = address;
    webOscTrace("browser: current page URL saved");
}
- (void)restoreLastPage {
    auto api = recoveredReaperCallbacks();
    if (!api.getExtState || !self.web) return;
    const char *stored = api.getExtState(kExtSection.UTF8String, kLastPageKey);
    if (!stored || !*stored) return;
    NSString *address = [NSString stringWithUTF8String:stored];
    if (!address.length) return;
    webOscTrace("browser: restoring last page URL");
    [self showURL:address];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == kPageURLObservationContext) {
        if (object == self.web && [keyPath isEqualToString:@"URL"] && !self.shuttingDown) {
            [self updateNavigation];
            // Provisional navigations can fail. Wait for didFinishNavigation
            // before storing them, but store same-document URL changes now.
            if (![self.web isLoading]) [self persistCurrentPageURL];
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (void)showURL:(NSString *)text {
    NSString *value = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0 || !self.web) return;
    if (![value containsString:@"://"] && ![value hasPrefix:@"about:"]) value = [@"https://" stringByAppendingString:value];
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    NSString *scheme = parts.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"] && ![value isEqualToString:@"about:blank"]) {
        webOscTrace("browser: unsupported URL scheme (http/https only)");
        return;
    }
    NSURL *url = [NSURL URLWithString:value];
    if (!url) { webOscTrace("browser: invalid URL"); return; }
    self.address.stringValue = value;
    [self.web loadRequest:[NSURLRequest requestWithURL:url]];
}
- (void)navigate:(id)sender { (void)sender; [self showURL:self.address.stringValue]; }
- (void)updateNavigation {
    NSString *address = self.web.URL.absoluteString;
    if (address.length && self.window.firstResponder != self.address.currentEditor)
        self.address.stringValue = address;
}
- (void)webView:(WKWebView *)view didStartProvisionalNavigation:(WKNavigation *)nav {
    (void)view; (void)nav; [self updateNavigation];
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)nav {
    (void)view; (void)nav;
    [self updateNavigation];
    [self persistCurrentPageURL];
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    (void)view; (void)nav;
    webOscTrace(error.localizedDescription.UTF8String ?: "browser: navigation failed");
}
- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [self webView:view didFailProvisionalNavigation:nav withError:error];
}
- (WKWebView *)webView:(WKWebView *)view createWebViewWithConfiguration:(WKWebViewConfiguration *)config
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    (void)config; (void)features;
    if (!action.targetFrame) [view loadRequest:action.request];
    return nil;
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller; (void)message;
}
- (void)controlTextDidBeginEditing:(NSNotification *)note {
    (void)note;
    self.pageEditing = YES;
    // Cmd+L can focus the address field while the toolbar is collapsed.
    // Focused controls should always remain accessible, even if the mouse
    // moves outside the browser while editing or opening a context menu.
    _toolbarVisibility.visible = true;
    _toolbarVisibility.enteredEdgeAt = -1.0;
    [self setControlsVisible:YES];
}
- (void)controlTextDidEndEditing:(NSNotification *)note {
    self.pageEditing = NO;
    id field = note.object;
    if (field == self.oscInPort || field == self.oscHost || field == self.oscOutPort)
        [self applyOscSettings:nil];
}
- (void)controlTextDidChange:(NSNotification *)note { (void)note; }
- (BOOL)control:(NSControl *)control textView:(NSTextView *)editor doCommandBySelector:(SEL)selector {
    (void)editor;
    if (selector == @selector(insertNewline:) && control == self.address) {
        [self navigate:control]; [self.window makeFirstResponder:self.web]; return YES;
    }
    return NO;
}
- (void)popupDidOpen:(NSNotification *)notification {
    if (self.shuttingDown || self.dockTransitioning || !notification.object) return;
    // Never reveal the toolbar just because a menu elsewhere in REAPER opens.
    // Only hold a toolbar that was already shown, or one already held by a
    // previous popup (for nested menus and popovers).
    if (self.controlPanel.hidden && self.activeToolbarPopups.count == 0) return;
    [self.activeToolbarPopups addObject:notification.object];
}
- (void)popupDidClose:(NSNotification *)notification {
    if (notification.object) [self.activeToolbarPopups removeObject:notification.object];
    // Normal hover rules resume on the next timer tick after the popup closes.
}
- (void)setControlsVisible:(BOOL)visible {
    if (!self.controlPanel || !self.controlPanelHeightConstraint ||
        self.controlPanel.hidden == !visible) return;
    // Collapsing height to 0 removes the dead 30pt strip while hidden;
    // WKWebView is constrained to the panel's top anchor and fills the gap.
    self.controlPanelHeightConstraint.constant = visible ? webOscLayout::kPanelHeight : 0.0;
    self.controlPanel.hidden = !visible;
    if (visible) [self updateResponsiveNavigation];
    [self.content setNeedsLayout:YES];
}
- (void)updateToolbarHover {
    const BOOL popupOpen = self.activeToolbarPopups.count > 0;
    // A native popup can transiently change the key window/activation state.
    // Do not collapse its parent toolbar until the popup has actually closed.
    if (self.shuttingDown || self.dockTransitioning || (![NSApp isActive] && !popupOpen)) {
        _toolbarVisibility.reset();
        [self setControlsVisible:NO];
        return;
    }
    // In floating mode this is BrowserWindow. In Docker it is the host
    // window containing the reparented root view; never use self.window for
    // pointer conversion in docked mode.
    NSView *root = self.content;
    NSWindow *hostWindow = root.window;
    if (!hostWindow || !hostWindow.isVisible || NSIsEmptyRect(root.visibleRect)) {
        _toolbarVisibility.reset();
        [self setControlsVisible:NO];
        return;
    }
    NSPoint inWindow = [hostWindow convertPointFromScreen:[NSEvent mouseLocation]];
    NSPoint inRoot = [root convertPoint:inWindow fromView:nil];
    const NSRect bounds = root.bounds;
    const BOOL inside = NSPointInRect(inRoot, bounds);
    // NSView's ordinary coordinate system has its origin at the bottom.
    // Check isFlipped as well, in case the root gets replaced later.
    const CGFloat fromBottom = root.isFlipped ? NSMaxY(bounds) - inRoot.y
                                                : inRoot.y - NSMinY(bounds);
    const BOOL nearBottom = inside && fromBottom <= webOscVisibility::kEdgeTriggerHeight;
    const BOOL overPanel = inside && fromBottom <= webOscLayout::kPanelHeight;
    const double now = NSProcessInfo.processInfo.systemUptime;
    const BOOL show = _toolbarVisibility.update(now, inside, nearBottom, overPanel,
                                                self.pageEditing, popupOpen);
    [self setControlsVisible:show];
}
- (BOOL)editingText { return self.pageEditing; }
- (void)layoutDock {
    if (self.docked && self.dockHost && self.content) {
        self.content.frame = self.dockHost.bounds;
        self.content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self updateResponsiveNavigation];
    }
}
- (BOOL)applyDocked:(BOOL)requested {
    return [self applyDocked:requested persistState:YES];
}
// Shutdown cleanup and startup restoration must not overwrite the user's
// persistent Dock/Undock choice.
- (BOOL)applyDocked:(BOOL)requested persistState:(BOOL)persistState {
    if (![NSThread isMainThread] || self.shuttingDown || self.dockTransitioning)
        return NO;
    if (self.docked == requested) return YES;
    auto api = recoveredReaperCallbacks();

    if (requested) {
        // Never hand a plain NSView to REAPER's DockWindowAddEx. The supplied
        // factory must return a genuine SWELL HWND obtained from the host.
        if (!api.createDockHost || !api.destroyDockHost || !api.dockWindowAddEx ||
            !api.dockWindowRemove || !api.dockWindowActivate) {
            webOscTrace("dock: required REAPER API is missing");
            return NO;
        }
        void *raw = api.createDockHost();
        if (!raw) {
            webOscTrace("dock: cannot create host-backed SWELL window");
            return NO;
        }
        NSView *host = (__bridge NSView *)raw;
        if (![host isKindOfClass:[NSView class]]) {
            api.destroyDockHost(raw);
            webOscTrace("dock: invalid window handle");
            return NO;
        }
        self.dockTransitioning = YES;
        BOOL registeredWithReaper = NO;
        webOscTrace("dock: beginning floating -> docker transition");
        @try {
            [self saveFrame];
            [self.window endEditingFor:self.address];
            // Preserve the root view hierarchy and WKWebView instance.
            // Reparent all controls and WebKit together, without reinitializing.
            // Unparent the *existing* root (and WKWebView) without recreating
            // WebKit, then make it the child of REAPER's genuine SWELL HWND.
            self.window.contentView = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
            self.dockHost = host; // retain until removed from REAPER Docker
            self.content.translatesAutoresizingMaskIntoConstraints = YES;
            self.content.frame = host.bounds;
            self.content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [host addSubview:self.content];
            webOscTrace("dock: WebKit root attached to SWELL child");
            // Register with REAPER only after the view hierarchy is valid.
            api.dockWindowAddEx(raw, "Web Browser", "CustomWebBrowser", true);
            registeredWithReaper = YES;
            self.docked = YES;
            [self layoutDock]; // docker may have resized the SWELL host
            [self.content layoutSubtreeIfNeeded];
            [self.window orderOut:nil];
            api.dockWindowActivate(raw);
            self.dockButton.title = @"Undock";
            if (persistState && api.setExtState)
                api.setExtState(kExtSection.UTF8String, "docked", "1", true);
            webOscTrace("dock: attached to REAPER Docker");
            self.dockTransitioning = NO;
            return YES;
        } @catch (NSException *exception) {
            webOscTraceObjCException("dock: attach failed", exception);
            // Keep WebKit alive before removing/destroying its SWELL parent.
            [self.content removeFromSuperview];
            if (registeredWithReaper) api.dockWindowRemove(raw);
            self.window.contentView = self.content;
            self.dockHost = nil;
            api.destroyDockHost(raw);
            self.docked = NO;
            [self.window makeKeyAndOrderFront:nil];
            self.dockTransitioning = NO;
            return NO;
        }
    }

    if (!api.dockWindowRemove || !api.destroyDockHost) {
        webOscTrace("dock: cannot undock: required API missing");
        return NO;
    }
    self.dockTransitioning = YES;
    webOscTrace("dock: beginning docker -> floating transition");
    NSView *host = self.dockHost;
    void *raw = (__bridge void *)host;
    @try {
        // Detach WebKit *before* allowing REAPER to change the SWELL parent.
        [self.content removeFromSuperview];
        if (raw) api.dockWindowRemove(raw);
        self.window.contentView = self.content;
        self.content.frame = self.window.contentView.bounds;
        [self.content layoutSubtreeIfNeeded];
        self.docked = NO;
        self.dockHost = nil;
        if (raw) api.destroyDockHost(raw);
        [self.window makeKeyAndOrderFront:nil];
        [self.window orderFrontRegardless];
        self.dockButton.title = @"Dock";
        if (persistState && api.setExtState)
            api.setExtState(kExtSection.UTF8String, "docked", "0", true);
        webOscTrace("dock: restored floating window");
        self.dockTransitioning = NO;
        return YES;
    } @catch (NSException *exception) {
        webOscTraceObjCException("dock: detach failed", exception);
        self.dockTransitioning = NO;
        return NO;
    }
}
- (void)toggleDock:(id)sender {
    (void)sender;
    if (![self applyDocked:!self.docked]) {
        webOscTrace("dock: toggle failed; consult diagnostic log");
    }
}
- (void)saveFrame { /* fixed visible initial position in this stability build */ }
- (void)closeBrowser:(id)sender {
    (void)sender;
    if (self.web && ![self.web isLoading]) [self persistCurrentPageURL];
    [self.window orderOut:nil];
}
- (BOOL)windowShouldClose:(id)sender { [self closeBrowser:sender]; return NO; }
- (void)shutdown {
    if (self.shuttingDown) return;
    // Last safety net; ordinary navigation is already persisted immediately.
    if (self.web && ![self.web isLoading]) [self persistCurrentPageURL];
    if (self.observingPageURL) {
        [self.web removeObserver:self forKeyPath:@"URL" context:kPageURLObservationContext];
        self.observingPageURL = NO;
    }
    [self.toolbarHoverTimer invalidate];
    self.toolbarHoverTimer = nil;
    [self.activeToolbarPopups removeAllObjects];
    _toolbarVisibility.reset();
    [self setControlsVisible:NO];
    // Never destroy the SWELL view while it is still registered with Docker.
    if (self.docked) [self applyDocked:NO persistState:NO];
    self.shuttingDown = YES;
    // Includes view-resize and popup lifecycle notifications.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.web.navigationDelegate = nil;
    self.web.UIDelegate = nil;
    [self.web stopLoading];
    self.window.delegate = nil;
}
- (void)dealloc { [self shutdown]; }
@end
