#pragma once
// Public Objective-C interfaces for the reconstructed WebKit + OSC plug-in.
// Only classes that are actually implemented by this project are declared.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <netinet/in.h>

@interface BrowserOscFeedback : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSData *lastConfig;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) int socketFD;
@property (nonatomic) int receiveFD;
@property (nonatomic) int listenPort;
@property (nonatomic) struct sockaddr_in destination;
@property (nonatomic) BOOL enabled;
@property (nonatomic) double nextReload;
- (instancetype)initWithPath:(NSString *)path;
- (void)reloadConfig;
- (void)tick;
- (void)stop;
@end

@interface BrowserWindow : NSWindow
@property (nonatomic, weak) NSTextField *addressField;
- (BOOL)canBecomeKeyWindow;
- (BOOL)canBecomeMainWindow;
- (BOOL)performKeyEquivalent:(NSEvent *)event;
@end

@interface BrowserController : NSObject <NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
                                         WKScriptMessageHandler, NSTextFieldDelegate>
@property (nonatomic, strong) BrowserWindow *window;
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) NSTextField *address;
@property (nonatomic, strong) NSButton *dockButton;
@property (nonatomic, strong) NSView *content;
@property (nonatomic, strong) NSView *dockHost;
@property (nonatomic) BOOL docked;
@property (nonatomic) BOOL pageEditing;
@property (nonatomic, strong) NSView *controlPanel;
@property (nonatomic, strong) NSTextField *oscInPort;
@property (nonatomic, strong) NSTextField *oscOutPort;
@property (nonatomic, strong) NSTextField *oscHost;
@property (nonatomic, strong) NSButton *oscEnable;
- (NSTextField *)oscField:(double)size flexible:(BOOL)flexible;
- (NSTextField *)oscLabel:(NSString *)label;
- (void)loadOscSettings;
- (void)controlTextDidChange:(NSNotification *)note;
- (BOOL)control:(NSControl *)control textView:(NSTextView *)view doCommandBySelector:(SEL)selector;
- (BOOL)saveOscEnabled:(BOOL)enabled;
- (void)applyOscSettings:(id)sender;
- (void)toggleOscEnabled:(id)sender;
- (NSButton *)button:(NSString *)label action:(SEL)action;
- (BOOL)editingText;
- (void)setControlsVisible:(BOOL)visible;
- (void)controlTextDidEndEditing:(NSNotification *)note;
- (void)controlTextDidBeginEditing:(NSNotification *)note;
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message;
- (void)showURL:(NSString *)url;
- (void)restoreLastPage;
- (void)persistCurrentPageURL;
- (void)navigate:(id)sender;
- (void)updateNavigation;
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation;
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error;
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error;
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)features;
- (void)updateResponsiveNavigation;
- (void)browserRootFrameDidChange:(NSNotification *)note;
- (void)windowDidResize:(NSNotification *)note;
- (void)layoutDock;
- (BOOL)applyDocked:(BOOL)docked;
- (BOOL)applyDocked:(BOOL)docked persistState:(BOOL)persistState;
- (void)closeBrowser:(id)sender;
- (void)toggleDock:(id)sender;
- (void)saveFrame;
- (BOOL)windowShouldClose:(id)sender;
- (void)shutdown;
@end
