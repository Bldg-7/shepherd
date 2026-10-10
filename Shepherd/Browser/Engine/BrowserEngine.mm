// CEF behind the Objective-C interface in BrowserEngine.h. What each piece is
// for, and what phase 0 found out about it, is in docs/agent-browser-plan.md;
// plan items are cited by their IDs.
#import "BrowserEngine.h"

#if TARGET_OS_OSX

NSErrorDomain const SHBEngineErrorDomain = @"BrowserEngine";

static NSUInteger gGeneration = 0;
static int gDevToolsMessageID = 0;

namespace {

NSError *EngineError(SHBEngineError code, NSString *message) {
  return [NSError errorWithDomain:SHBEngineErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

}  // namespace

// The CEF build the app carries is Apple silicon only; an Intel slice of the
// app compiles the stubs at the end of this file instead.
#if defined(__arm64__)

#include <crt_externs.h>
#include <objc/runtime.h>

#include <algorithm>
#include <atomic>
#include "include/cef_resource_request_handler.h"
#include "include/cef_task.h"
#include <map>
#include <memory>
#include <functional>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_library_loader.h"


namespace {
class PageClient;
}

@interface SHBPage ()
- (instancetype)initPopupFromOpener:(SHBPage *)opener inBackground:(BOOL)inBackground;
- (PageClient *)client;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)applyWebAccessibility;
- (void)browserClosed;
- (NSString *)shutdownState;
- (void)titleChanged:(NSString *)title;
- (void)urlChanged:(NSString *)url;
- (void)loadingChanged:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
@property (nonatomic, weak, nullable) NSView *creationParent;
@end

@interface SHBProfile ()
@property (nonatomic) NSInteger credentialProxyPort;
@property (nonatomic, copy) NSString *credentialProxyUsername;
@property (nonatomic, copy) NSString *credentialProxyPassword;
@property (nonatomic, copy) BOOL (^credentialNetworkPolicy)(NSString *authority);
@property (nonatomic, copy) BOOL (^credentialCertificatePolicy)(NSString *host, NSArray<NSData *> *chain);
@end

namespace {

class CredentialCallbackTask : public CefTask {
 public:
  explicit CredentialCallbackTask(std::function<void()> callback) : callback_(std::move(callback)) {}
  void Execute() override { callback_(); }
 private:
  std::function<void()> callback_;
  IMPLEMENT_REFCOUNTING(CredentialCallbackTask);
};

NSString *ToNSString(const CefString &string) {
  return [NSString stringWithUTF8String:string.ToString().c_str()] ?: @"";
}

// An error as a DevTools method reports one, for a method that fails before
// it reaches the page.
NSString *DevToolsError(NSString *message) {
  return [NSString stringWithFormat:@"{\"message\":\"%@\"}", message];
}

// Has CEF make a page's view a subview of `parent`, filling it. Alloy: a bare
// page, without Chrome's own tab strip and toolbar.
void PlacePage(CefWindowInfo &info, NSView *parent) {
  info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(parent),
                  CefRect(0, 0, (int)parent.bounds.size.width, (int)parent.bounds.size.height));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
}

// Every page that exists or is being created, kept alive until it has
// closed: a page its owner lets go of while it closes still has to see the
// close through. CEF must not be shut down while there are any.
NSMutableSet<SHBPage *> *gPages = nil;

// MARK: - The application class (plan item A16)

// CEF needs the application object to implement CefAppProtocol: it has to
// know when the app is in the middle of dispatching an event. SwiftUI runs its
// own NSApplication subclass and ignores NSPrincipalClass, so the protocol is
// added to whatever class NSApp is, at run time (PatchApplicationClass below).
BOOL gHandlingSendEvent = NO;
BOOL IsHandlingSendEvent(id, SEL) { return gHandlingSendEvent; }
void SetHandlingSendEvent(id, SEL, BOOL value) { gHandlingSendEvent = value; }
IMP gOriginalSendEvent = nullptr;
void SendEvent(id self, SEL cmd, NSEvent *event) {
  CefScopedSendingEvent sendingEventScoper;
  ((void (*)(id, SEL, NSEvent *))gOriginalSendEvent)(self, cmd, event);
}

// MARK: - Accessibility (plan item A18)

// Chromium builds no accessibility tree for a page — so VoiceOver finds
// nothing in it — until the app turns it on with SetAccessibilityState. The
// app is to do that when an assistive app asks for it, which it does by
// setting an attribute on the application object: AXEnhancedUserInterface
// (VoiceOver) or AXManualAccessibility (others; the attribute Chrome and
// Electron take too). AppKit knows the first, but not the second.
NSString *const kEnhancedUserInterface = @"AXEnhancedUserInterface";
NSString *const kManualAccessibility = @"AXManualAccessibility";
bool gWebAccessibility = false;

void SetWebAccessibility(bool enabled) {
  if (gWebAccessibility == enabled) return;
  gWebAccessibility = enabled;
  for (SHBPage *page in gPages) {
    [page applyWebAccessibility];
  }
}

IMP gOriginalAccessibilitySetValue = nullptr;
void AccessibilitySetValue(id self, SEL cmd, id value, NSString *attribute) {
  if ([attribute isEqualToString:kManualAccessibility]) {
    SetWebAccessibility([value boolValue]);
    return;
  }
  if ([attribute isEqualToString:kEnhancedUserInterface]) SetWebAccessibility([value boolValue]);
  ((void (*)(id, SEL, id, NSString *))gOriginalAccessibilitySetValue)(self, cmd, value, attribute);
}

IMP gOriginalAccessibilityAttributeValue = nullptr;
id AccessibilityAttributeValue(id self, SEL cmd, NSString *attribute) {
  if ([attribute isEqualToString:kManualAccessibility]) return @(gWebAccessibility);
  return ((id (*)(id, SEL, NSString *))gOriginalAccessibilityAttributeValue)(self, cmd, attribute);
}

IMP gOriginalAccessibilityIsAttributeSettable = nullptr;
BOOL AccessibilityIsAttributeSettable(id self, SEL cmd, NSString *attribute) {
  if ([attribute isEqualToString:kManualAccessibility]) return YES;
  return ((BOOL (*)(id, SEL, NSString *))gOriginalAccessibilityIsAttributeSettable)(self, cmd, attribute);
}

// MARK: - Patching the application class

// Puts `replacement` in place of the class's method for `selector` and
// returns the method it replaces. A method the class inherits rather than
// defines is overridden on the class itself, leaving its superclass alone.
IMP Override(Class cls, SEL selector, IMP replacement) {
  Method method = class_getInstanceMethod(cls, selector);
  IMP original = method_getImplementation(method);
  if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
    method_setImplementation(method, replacement);
  }
  return original;
}

// Gives NSApp's class CefAppProtocol and the accessibility attributes above.
// Only the first call does anything.
void PatchApplicationClass() {
  if ([NSApp conformsToProtocol:@protocol(CefAppProtocol)]) return;
  Class cls = [NSApp class];
  class_addMethod(cls, @selector(isHandlingSendEvent), (IMP)IsHandlingSendEvent, "B@:");
  class_addMethod(cls, @selector(setHandlingSendEvent:), (IMP)SetHandlingSendEvent, "v@:B");
  gOriginalSendEvent = Override(cls, @selector(sendEvent:), (IMP)SendEvent);
  gOriginalAccessibilitySetValue =
      Override(cls, @selector(accessibilitySetValue:forAttribute:), (IMP)AccessibilitySetValue);
  gOriginalAccessibilityAttributeValue =
      Override(cls, @selector(accessibilityAttributeValue:), (IMP)AccessibilityAttributeValue);
  gOriginalAccessibilityIsAttributeSettable =
      Override(cls, @selector(accessibilityIsAttributeSettable:), (IMP)AccessibilityIsAttributeSettable);
  class_addProtocol(cls, @protocol(CrAppProtocol));
  class_addProtocol(cls, @protocol(CrAppControlProtocol));
  class_addProtocol(cls, @protocol(CefAppProtocol));
  // VoiceOver may have been on since before the class was patched to
  // notice it being turned on.
  if (NSWorkspace.sharedWorkspace.isVoiceOverEnabled) {
    gWebAccessibility = true;
  }
}

// MARK: - The message loop

// CEF runs on the app's main run loop ("external message pump"): it says when
// it next wants to do work, and a timer covers whatever that misses, as in
// cefclient's own external pump.
bool gRunning = false;
bool gDoingWork = false;
uint64_t gScheduledWork = 0;
NSTimer *gPumpTimer = nil;

void DoWork() {
  // CefDoMessageLoopWork must not be re-entered, which a run loop spun from
  // inside it (a menu, a modal panel) would otherwise do through the timer.
  if (!gRunning || gDoingWork) return;
  gDoingWork = true;
  // Native CEF child browsers are destroyed when CefBrowserHostView deallocs.
  // Drain borrowed AppKit views after each CEF turn, including synchronous quit.
  @autoreleasepool { CefDoMessageLoopWork(); }
  gDoingWork = false;
}

void ScheduleWork(int64_t delayMs) {
  uint64_t ticket = ++gScheduledWork;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, std::max<int64_t>(delayMs, 0) * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   // Only the latest request counts; it replaces the earlier ones.
                   if (ticket == gScheduledWork) DoWork();
                 });
}

class EngineApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString &processType, CefRefPtr<CefCommandLine> commandLine) override {
    if (!processType.empty()) return;
    // Start from a trusted configuration, ignoring all external Chromium
    // switches (debugging TCP, sandbox/certificate overrides included).
    commandLine->Reset();
    commandLine->SetProgram((*_NSGetArgv())[0]);
    // Pages that aren't on screen keep running at full speed: an agent may
    // be working in them (A6).
    commandLine->AppendSwitch("disable-background-timer-throttling");
    commandLine->AppendSwitch("disable-renderer-backgrounding");
    commandLine->AppendSwitch("disable-backgrounding-occluded-windows");
    // Every pane has a profile of its own, and each would otherwise get a
    // cache of up to several hundred megabytes (A15).
    commandLine->AppendSwitchWithValue("disk-cache-size", std::to_string(64 * 1024 * 1024));
    // Without it, Chromium answers HTTP authentication itself — with a
    // prompt the Alloy style has no place for, so the request just fails
    // (ERR_INVALID_AUTH_CREDENTIALS) — and never asks GetAuthCredentials
    // (A10; CEF issue #3603).
    commandLine->AppendSwitch("disable-chrome-login-prompt");
#if DEBUG
    // Chromium keeps the key it encrypts cookies with in the Keychain, whose
    // access list names the app's signature. A development build is signed
    // ad hoc and gets a new signature with every build, and the Keychain
    // would ask for permission after each one.
    commandLine->AppendSwitch("use-mock-keychain");
#endif
  }

  void OnScheduleMessagePumpWork(int64_t delayMs) override {
    dispatch_async(dispatch_get_main_queue(), ^{ ScheduleWork(delayMs); });
  }

  bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine>, const CefString &) override {
    // Another copy of the app tried to start CEF on the same folder. It is
    // turned away (see startWithRootCachePath:); nothing to do here.
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(EngineApp);
};

CefScopedLibraryLoader *gLibraryLoader = nullptr;

}  // namespace

// MARK: - Engine

@implementation SHBEngine
+ (NSUInteger)generation { return gGeneration; }
+ (NSInteger)nextDevToolsMessageID {
  // Never wrap/reuse an ID while the native agent may still have it pending.
  return gDevToolsMessageID == INT_MAX ? 0 : ++gDevToolsMessageID;
}

+ (BOOL)isAvailable {
  return YES;
}

+ (BOOL)isRunning {
  return gRunning;
}

+ (void)prepare {
  PatchApplicationClass();
}

+ (BOOL)startWithRootCachePath:(NSString *)rootCachePath error:(NSError **)error {
  if (gRunning) return YES;
  PatchApplicationClass();

  if (!gLibraryLoader) {
    gLibraryLoader = new CefScopedLibraryLoader();
    if (!gLibraryLoader->LoadInMain()) {
      delete gLibraryLoader;
      gLibraryLoader = nullptr;
      if (error) {
        *error = EngineError(SHBEngineErrorLoadFailed,
                             @"The browser engine (Chromium Embedded Framework) couldn't be loaded.");
      }
      return NO;
    }
  }

  NSString *helper = [NSBundle.mainBundle.privateFrameworksPath
      stringByAppendingPathComponent:@"Shepherd Helper.app/Contents/MacOS/Shepherd Helper"];
  char *trustedArgv[] = {(*_NSGetArgv())[0], nullptr};
  CefMainArgs args(1, trustedArgv);
  CefSettings settings;
  settings.external_message_pump = true;
  settings.command_line_args_disabled = true;
  // Zero in settings means disabled; NEVER append --remote-debugging-port=0.
  settings.remote_debugging_port = 0;
  settings.no_sandbox = false;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.browser_subprocess_path) = helper.UTF8String;
  CefString(&settings.root_cache_path) = rootCachePath.UTF8String;
  CefString(&settings.log_file) = [rootCachePath stringByAppendingPathComponent:@"engine.log"].UTF8String;
  if (!CefInitialize(args, settings, new EngineApp(), nullptr)) {
    if (error) {
      *error = EngineError(SHBEngineErrorStartFailed,
                           @"The browser engine didn't start. Another copy of Shepherd may be using the browser.");
    }
    return NO;
  }
  gRunning = true;
  ++gGeneration;
  gPages = [NSMutableSet set];
  gPumpTimer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *) { DoWork(); }];
  [NSRunLoop.mainRunLoop addTimer:gPumpTimer forMode:NSRunLoopCommonModes];
  return YES;
}

+ (BOOL)shutDownWithin:(NSTimeInterval)timeout {
  if (!gRunning) return YES;
  for (SHBPage *page in gPages.allObjects) {
    [page closeForcing:YES];
  }
  // The pages close over several turns of CEF's work, which nothing else
  // drives from here on: the caller doesn't return to the run loop first.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (gPages.count > 0 && deadline.timeIntervalSinceNow > 0) {
    DoWork();
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  if (gPages.count > 0) {
    NSLog(@"Browser shutdown timed out with %lu live pages; preserving engine for retry.", (unsigned long)gPages.count);
    for (SHBPage *page in gPages.allObjects) NSLog(@"Browser shutdown state: %@", [page shutdownState]);
    return NO;
  }
  [gPumpTimer invalidate];
  gPumpTimer = nil;
  // Flushes cookies and the rest to disk (F8).
  CefShutdown();
  gRunning = false;
  return YES;
}

@end

// MARK: - Profile

@implementation SHBProfile {
 @public
  CefRefPtr<CefRequestContext> _context;
  CefRefPtr<CefValue> _originalProxy;
}

- (instancetype)initWithFolder:(NSString *)folder {
  if ((self = [super init])) {
    // Chromium canonicalizes root_cache_path itself, but CEF compares
    // request-context paths literally. Foundation deliberately shortens
    // /private/tmp to /tmp; realpath keeps the physical spelling we need.
    char *parent = realpath(folder.stringByDeletingLastPathComponent.UTF8String, nullptr);
    _folder = folder.length == 0 ? @"" : parent ? [[NSString stringWithUTF8String:parent] stringByAppendingPathComponent:folder.lastPathComponent]
                     : [folder copy];
    free(parent);
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = _folder.UTF8String;
    // Logins that use session cookies survive the app being restarted too.
    settings.persist_session_cookies = true;
    _context = CefRequestContext::CreateContext(settings, nullptr);
  }
  return self;
}

- (BOOL)prepareCredentialProxyOnPort:(NSInteger)port username:(NSString *)username password:(NSString *)password
                       authorities:(NSArray<NSString *> *)authorities networkPolicy:(BOOL (^)(NSString *))networkPolicy
                 certificatePolicy:(BOOL (^)(NSString *, NSArray<NSData *> *))certificatePolicy {
  NSAssert(NSThread.isMainThread, @"Native networking is main-thread owned");
  if (!_context || self.credentialProxyPort || port < 1 || port > 65535 || username.length != 64 || password.length != 64 ||
      authorities.count == 0 || authorities.count > 128 || !networkPolicy || !certificatePolicy) return NO;
  for (SHBPage *page in gPages) if (page.profile == self) return NO;
  // Do not overwrite a custom/PAC/system proxy or repartition shared profiles.
  auto original = _context->GetPreference("proxy");
  if (!original || original->GetType() != VTYPE_DICTIONARY || !_context->CanSetPreference("proxy")) return NO;
  auto dictionary = original->GetDictionary();
  if (dictionary->GetSize() != 1 || dictionary->GetString("mode") != "system") return NO;
  for (NSString *authority in authorities) if (!networkPolicy(authority)) return NO;
  auto proxy = CefDictionaryValue::Create();
  proxy->SetString("mode", "fixed_servers");
  proxy->SetString("server", std::string("http://127.0.0.1:") + std::to_string(port));
  // Chromium otherwise implicitly bypasses loopback destinations.
  proxy->SetString("bypass_list", "<-loopback>");
  auto value = CefValue::Create(); value->SetDictionary(proxy);
  CefString error;
  if (!_context->SetPreference("proxy", value, error)) return NO;
  _originalProxy = original->Copy();
  self.credentialProxyPort = port;
  self.credentialProxyUsername = username;
  self.credentialProxyPassword = password;
  self.credentialNetworkPolicy = networkPolicy;
  self.credentialCertificatePolicy = certificatePolicy;
  return YES;
}

- (BOOL)removeCredentialProxy {
  NSAssert(NSThread.isMainThread, @"Native networking is main-thread owned");
  if (!self.credentialProxyPort) return YES;
  for (SHBPage *page in gPages) if (page.profile == self) return NO;
  // Revoke/close proxy sockets before calling this. CEF explicitly recommends
  // CloseAllConnections only after all other CEF objects are released.
  self.credentialNetworkPolicy = nil;
  self.credentialCertificatePolicy = nil;
  self.credentialProxyUsername = nil;
  self.credentialProxyPassword = nil;
  CefString error;
  if (!_originalProxy || !_context->SetPreference("proxy", _originalProxy, error)) return NO;
  self.credentialProxyPort = 0;
  _originalProxy = nullptr;
  _context->ClearHttpAuthCredentials(nullptr);
  _context->CloseAllConnections(nullptr);
  return YES;
}

@end

// This observer dispatches trusted native messages. Target-session detach,
// not observer removal, restores agent-owned Chromium inspector state.
namespace {
class NativeObserver : public CefDevToolsMessageObserver {
 public:
  explicit NativeObserver(void (^handler)(NSString *)) : handler_([handler copy]) {}
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void *message, size_t size) override {
    NSString *text = [[NSString alloc] initWithBytes:message length:size encoding:NSUTF8StringEncoding];
    if (handler_ && text) handler_(text);
    return false;
  }
  void OnDevToolsAgentAttached(CefRefPtr<CefBrowser> browser) override {
    if (handler_) handler_(@"{\"nativeAgentAttached\":true}");
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    if (handler_) handler_(@"{\"nativeAgentDetached\":true}");
  }
  void Clear() { handler_ = nil; }
 private:
  void (^handler_)(NSString *);
  IMPLEMENT_REFCOUNTING(NativeObserver);
};
}
@interface SHBNativeLease ()
- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser handler:(void (^)(NSString *))handler;
@end
@implementation SHBNativeLease {
  CefRefPtr<CefBrowser> _nativeBrowser;
  CefRefPtr<NativeObserver> _nativeObserver;
  CefRefPtr<CefRegistration> _nativeRegistration;
}
- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser handler:(void (^)(NSString *))handler {
  if ((self = [super init])) {
    _nativeBrowser = browser;
    _nativeObserver = new NativeObserver(handler);
    _nativeRegistration = browser->GetHost()->AddDevToolsMessageObserver(_nativeObserver);
  }
  return self;
}
- (BOOL)sendMessage:(NSString *)json {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  return _nativeBrowser && _nativeRegistration && _nativeBrowser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
}
- (void)invalidate {
  if (_nativeObserver) _nativeObserver->Clear();
  _nativeRegistration = nullptr;
  _nativeObserver = nullptr;
  _nativeBrowser = nullptr;
}
@end

// MARK: - Page

namespace {

typedef void (^DevToolsCompletion)(NSString *_Nullable, NSString *_Nullable);

// One per page: CEF's view of the page's owner. Calls go on to the page's
// delegate. Every handler here runs on the UI thread, which is the main
// thread.
class PageClient : public CefClient,
                   public CefLifeSpanHandler,
                   public CefDisplayHandler,
                   public CefLoadHandler,
                   public CefRequestHandler,
                   public CefResourceRequestHandler,
                   public CefJSDialogHandler,
                   public CefPermissionHandler,
                   public CefDownloadHandler,
                   public CefDevToolsMessageObserver {
 public:
  explicit PageClient(SHBPage *page) : credentialRoute(page.profile.credentialProxyPort != 0), page_(page) {}
  const bool credentialRoute;

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

  // MARK: Life span

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    devToolsRegistration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    [page_ browserCreated:browser];
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popupID,
                     const CefString &targetURL, const CefString &targetFrameName,
                     WindowOpenDisposition disposition, bool userGesture, const CefPopupFeatures &features,
                     CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client, CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extraInfo, bool *noJavascriptAccess) override {
    // A popup becomes another tab of the same pane (C4). It is still a real
    // popup — CEF creates it, so it keeps its opener, which sign-in popups
    // need — only hosted as a child view instead of a window of its own.
    if (!AgentURLAllowed(targetURL)) return true;
    SHBPage *page = page_;
    NSView *parent = page.creationParent;
    if (!page || !parent || !page.delegate) return true;
    BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    SHBPage *popup = [[SHBPage alloc] initPopupFromOpener:page inBackground:background];
    popup.creationParent = parent;
    popups_[popupID] = popup;
    PlacePage(windowInfo, parent);
    client = [popup client];
    return false;
  }

  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popupID) override {
    auto it = popups_.find(popupID);
    if (it == popups_.end()) return;
    [gPages removeObject:it->second];
    popups_.erase(it);
  }

  // The popup exists now: it is no longer one CEF may abort.
  void PopupCreated(SHBPage *popup) {
    for (auto it = popups_.begin(); it != popups_.end(); ++it) {
      if (it->second == popup) {
        popups_.erase(it);
        return;
      }
    }
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // Left to CEF's default (false), closing a page asks the window it is in
    // to close — the Shepherd window (F13). Taking the page's view out of
    // the window instead lets the close complete on its own.
    // CEF a03e714 native-mac destroys the browser from its host view's
    // dealloc. DoClose(true) alone cancels closing; repeated CloseBrowser
    // does not destroy a retained host view. Hold it only to the enclosing
    // CEF/close autorelease pool so dealloc happens after this callback.
    NSView *__autoreleasing view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    [view removeFromSuperview];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    devToolsRegistration_ = nullptr;
    for (auto &entry : pendingDevTools_) {
      entry.second(nil, DevToolsError(@"The page closed."));
    }
    pendingDevTools_.clear();
    [page_ browserClosed];
  }

  // MARK: Display and loading

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &url) override {
    if (frame->IsMain()) [page_ urlChanged:ToNSString(url)];
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    [page_ titleChanged:ToNSString(title)];
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                            bool canGoForward) override {
    [page_ loadingChanged:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  }

  // MARK: Requests

  std::atomic<bool> agentControlled{false};
  std::atomic<bool> agentDownloadsAllowed{true};
  bool AgentURLAllowed(const CefString &url) {
    if (!agentControlled.load()) return true;
    NSString *text = ToNSString(url);
    NSURLComponents *components = [NSURLComponents componentsWithString:text];
    NSString *scheme = components.scheme.lowercaseString;
    return [@[@"http", @"https", @"ws", @"wss", @"data", @"blob"] containsObject:scheme] ||
        ([scheme isEqualToString:@"about"] && !components.host && !components.query &&
         [@[@"blank", @"srcdoc"] containsObject:components.path]);
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool userGesture, bool isRedirect) override {
    return !AgentURLAllowed(request->GetURL());
  }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
      bool isNavigation, bool isDownload, const CefString &initiator, bool &disableDefaultHandling) override {
    return this;
  }
  cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, CefRefPtr<CefCallback> callback) override {
    if (!AgentURLAllowed(request->GetURL())) return RV_CANCEL;
    // Never forward page-supplied provenance, even with the broker disabled.
    CefRequest::HeaderMap headers;
    request->GetHeaderMap(headers);
    for (auto it = headers.begin(); it != headers.end();) {
      std::string name = it->first.ToString();
      std::transform(name.begin(), name.end(), name.begin(), ::tolower);
      if (name == "x-shepherd-credential-ticket") it = headers.erase(it); else ++it;
    }
    request->SetHeaderMap(headers);
    if (!credentialRoute || request->GetMethod() != "POST") return RV_CONTINUE;
    __weak SHBPage *weakPage = page_;
    if (!browser || !frame || !frame->IsValid()) return RV_CANCEL;
    auto post = request->GetPostData();
    CefPostData::ElementVector elements;
    if (!post || post->HasExcludedElements()) return RV_CANCEL;
    post->GetElements(elements);
    if (elements.size() != 1 || elements[0]->GetType() != PDE_TYPE_BYTES || elements[0]->GetBytesCount() > 65536) return RV_CANCEL;
    std::string body(elements[0]->GetBytesCount(), '\0');
    if (elements[0]->GetBytes(body.size(), body.data()) != body.size()) return RV_CANCEL;
    const std::string url = request->GetURL().ToString();
    const int browserID = browser->GetIdentifier();
    const std::string frameID = frame->GetIdentifier().ToString();
    const uint64_t requestID = request->GetIdentifier();
    auto finished = std::make_shared<std::atomic<bool>>(false);
    auto complete = [finished, callback, request, url, body](NSString *ticket) {
      if (finished->exchange(true)) return;
      std::string issued = ticket ? ticket.UTF8String : "";
      CefPostTask(TID_IO, new CredentialCallbackTask([callback, request, url, body, issued] {
        auto current = request->GetPostData();
        CefPostData::ElementVector elements;
        if (current) current->GetElements(elements);
        std::string bytes(body.size(), '\0');
        const bool valid = issued.size() == 64 && std::all_of(issued.begin(), issued.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); });
        if (!valid || request->GetURL().ToString() != url || request->GetMethod() != "POST" || !current || current->HasExcludedElements() ||
            elements.size() != 1 || elements[0]->GetType() != PDE_TYPE_BYTES || elements[0]->GetBytesCount() != body.size() ||
            elements[0]->GetBytes(bytes.size(), bytes.data()) != bytes.size() || bytes != body) { callback->Cancel(); return; }
        request->SetHeaderByName("X-Shepherd-Credential-Ticket", issued, true);
        callback->Continue();
      }));
    };
    dispatch_async(dispatch_get_main_queue(), ^{
      SHBPage *page = weakPage;
      // Normal OFF/local browser POST behavior remains unchanged. The gate is
      // profile installation, not the presence of a connected vendor alone.
      if (!page || page.isClosed || !page.profile.credentialProxyPort) { complete(nil); return; }
      if (!page.credentialRequestIssuer) { complete(nil); return; }
      NSDictionary *evidence = @{@"engineGeneration": @(gGeneration), @"browserID": @(browserID),
        @"frameID": [NSString stringWithUTF8String:frameID.c_str()], @"requestID": @(requestID),
        @"url": [NSString stringWithUTF8String:url.c_str()], @"method": @"POST",
        @"body": [NSData dataWithBytes:body.data() length:body.size()]};
      page.credentialRequestIssuer(evidence, ^(NSString *ticket) {
        if (!weakPage || weakPage.isClosed || !weakPage.profile.credentialProxyPort) complete(nil); else complete(ticket);
      });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ complete(nil); });
    return RV_CONTINUE_ASYNC;
  }

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &targetURL,
                        WindowOpenDisposition disposition, bool userGesture) override {
    if (!AgentURLAllowed(targetURL)) return true;
    if (disposition != CEF_WOD_NEW_FOREGROUND_TAB && disposition != CEF_WOD_NEW_BACKGROUND_TAB &&
        disposition != CEF_WOD_NEW_WINDOW) {
      return false;
    }
    [page_.delegate page:page_
        requestsNewPageWithURL:ToNSString(targetURL)
                  inBackground:disposition == CEF_WOD_NEW_BACKGROUND_TAB];
    return true;
  }

  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser, const CefString &originURL, bool isProxy,
                          const CefString &host, int port, const CefString &realm, const CefString &scheme,
                          CefRefPtr<CefAuthCallback> callback) override {
    // The one handler CEF calls on its IO thread rather than the UI thread:
    // the page and its delegate are the main thread's.
    __weak SHBPage *weakPage = page_;
    NSString *hostName = ToNSString(host), *realmName = ToNSString(realm);
    dispatch_async(dispatch_get_main_queue(), ^{
      SHBPage *page = weakPage;
      if (page.profile.credentialProxyPort && isProxy) {
        if (page.isClosed || ![hostName isEqualToString:@"127.0.0.1"] || port != page.profile.credentialProxyPort || scheme != "basic" ||
            !page.profile.credentialProxyUsername || !page.profile.credentialProxyPassword) callback->Cancel();
        else callback->Continue(page.profile.credentialProxyUsername.UTF8String, page.profile.credentialProxyPassword.UTF8String);
        return;
      }
      id<SHBPageDelegate> delegate = page.delegate;
      if (!delegate) {
        callback->Cancel();
        return;
      }
      [delegate page:page
          requestCredentialsForHost:hostName
                              realm:realmName
                            isProxy:isProxy
                         completion:^(NSString *user, NSString *password) {
                           if (user && password) {
                             callback->Continue(user.UTF8String, password.UTF8String);
                           } else {
                             callback->Cancel();
                           }
                         }];
    });
    return true;
  }

  bool OnCertificateError(CefRefPtr<CefBrowser> browser, cef_errorcode_t error, const CefString &url,
                          CefRefPtr<CefSSLInfo> info, CefRefPtr<CefCallback> callback) override {
    SHBProfile *profile = page_.profile;
    if (!profile.credentialProxyPort || !profile.credentialCertificatePolicy || page_.isClosed ||
        error != ERR_CERT_AUTHORITY_INVALID || !info) return false;
    NSURLComponents *components = [NSURLComponents componentsWithString:ToNSString(url)];
    if (![components.scheme isEqualToString:@"https"] || components.user || components.password || !components.host) return false;
    auto certificate = info->GetX509Certificate();
    if (!certificate) return false;
    NSMutableArray<NSData *> *chain = [NSMutableArray array];
    auto append = [&](CefRefPtr<CefBinaryValue> value) {
      if (!value || value->GetSize() == 0 || value->GetSize() > 65536) return false;
      NSMutableData *data = [NSMutableData dataWithLength:value->GetSize()];
      if (value->GetData(data.mutableBytes, data.length, 0) != data.length) return false;
      [chain addObject:data]; return true;
    };
    if (!append(certificate->GetDEREncoded())) return false;
    CefX509Certificate::IssuerChainBinaryList issuers;
    certificate->GetDEREncodedIssuerChain(issuers);
    if (issuers.size() > 8) return false;
    for (auto issuer : issuers) if (!append(issuer)) return false;
    if (!profile.credentialCertificatePolicy(components.host, chain)) return false;
    callback->Continue(); return true;
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int errorCode,
                                 const CefString &errorString) override {
    NSString *reason;
    switch (status) {
      case TS_PROCESS_OOM: reason = @"out of memory"; break;
      case TS_PROCESS_WAS_KILLED: reason = @"killed"; break;
      case TS_PROCESS_CRASHED: reason = @"crashed"; break;
      default: reason = ToNSString(errorString); break;
    }
    [page_.delegate page:page_ renderProcessDidTerminateWithReason:reason];
  }

  // MARK: JavaScript dialogs (A9)

  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString &originURL, JSDialogType type,
                  const CefString &message, const CefString &defaultPrompt,
                  CefRefPtr<CefJSDialogCallback> callback, bool &suppressMessage) override {
    if (page_.agentControlled) {
      // CEF a03e714's mac runner leaves its NSAlert behind when CDP Handle
      // drops the helper. Own the callback instead; the scoped proxy completes it.
      pendingAgentDialog_ = callback;
      return true;
    }
    id<SHBPageDelegate> delegate = page_.delegate;
    if (!delegate) return false;
    SHBDialogKind kind = type == JSDIALOGTYPE_CONFIRM  ? SHBDialogKindConfirm
                         : type == JSDIALOGTYPE_PROMPT ? SHBDialogKindPrompt
                                                       : SHBDialogKindAlert;
    [delegate page:page_
          runDialog:kind
            message:ToNSString(message)
        defaultText:ToNSString(defaultPrompt)
         completion:^(BOOL accepted, NSString *text) {
           callback->Continue(accepted, text.UTF8String);
         }];
    return true;
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString &message, bool isReload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    if (page_.agentControlled) {
      pendingAgentDialog_ = callback;
      return true;
    }
    id<SHBPageDelegate> delegate = page_.delegate;
    if (!delegate) return false;
    [delegate page:page_
          runDialog:SHBDialogKindBeforeUnload
            message:ToNSString(message)
        defaultText:@""
         completion:^(BOOL accepted, NSString *) {
           callback->Continue(accepted, CefString());
         }];
    return true;
  }

  bool HandleAgentDialog(bool accept, const CefString &text) {
    if (!pendingAgentDialog_) return false;
    CefRefPtr<CefJSDialogCallback> callback = pendingAgentDialog_;
    pendingAgentDialog_ = nullptr;
    callback->Continue(accept, text);
    return true;
  }

  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override {
    HandleAgentDialog(false, CefString());
    [page_.delegate pageDidDismissDialog:page_];
  }

  // MARK: Permissions (A10)

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString &origin, uint32_t permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    // The app has no access to the camera or the microphone, nor to the
    // screen; see the delegate.
    callback->Cancel();
    return true;
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptID, const CefString &origin,
                              uint32_t permissions, CefRefPtr<CefPermissionPromptCallback> callback) override {
    id<SHBPageDelegate> delegate = page_.delegate;
    if (!delegate) return false;
    [delegate page:page_
        requestPermissions:(SHBPermission)permissions
                 forOrigin:ToNSString(origin)
                completion:^(BOOL granted) {
                  callback->Continue(granted ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
                }];
    return true;
  }

  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptID,
                                 cef_permission_request_result_t result) override {
    [page_.delegate pageDidDismissPermissionRequest:page_];
  }

  // MARK: Downloads (G7)

  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString &url, const CefString &method) override {
    return !agentControlled.load() || agentDownloadsAllowed.load();
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                        const CefString &suggestedName, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    NSString *name = [ToNSString(suggestedName) lastPathComponent];
    if (page_.agentDownloadFolder) {
      [page_.delegate page:page_ downloadDidChange:@{
          @"event": @"Browser.downloadWillBegin", @"guid": [NSString stringWithFormat:@"shepherd-%u", item->GetId()],
          @"url": ToNSString(item->GetURL()), @"suggestedFilename": name}];
      NSString *path = [page_.agentDownloadFolder stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%u-%@", item->GetId(), name]];
      callback->Continue(path.UTF8String, false);
      return true;
    }
#if DEBUG
    // BrowserSelfTest's downloads: into its own folder, without the panel,
    // which can't be operated from inside the app.
    NSString *testFolder = NSProcessInfo.processInfo.environment[@"SHEPHERD_BROWSER_SELFTEST_DOWNLOADS"];
    if (testFolder) {
      callback->Continue([testFolder stringByAppendingPathComponent:name].UTF8String, false);
      return true;
    }
#endif
    // Into the Downloads folder, by way of the save panel, as a person
    // downloading something expects. Where an agent's downloads go is the
    // CDP proxy's business (phase 2).
    NSString *downloads = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject;
    callback->Continue([downloads stringByAppendingPathComponent:name].UTF8String, true);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (page_.agentControlled) {
      NSString *state = item->IsComplete() ? @"completed" : item->IsCanceled() ? @"canceled" : @"inProgress";
      [page_.delegate page:page_ downloadDidChange:@{
          @"event": @"Browser.downloadProgress", @"guid": [NSString stringWithFormat:@"shepherd-%u", item->GetId()],
          @"state": state, @"totalBytes": @(item->GetTotalBytes()), @"receivedBytes": @(item->GetReceivedBytes()),
          @"filePath": ToNSString(item->GetFullPath())}];
    }
    if (!item->IsComplete()) return;
    // What Safari and Chrome do too: the Downloads stack in the Dock bounces.
    NSString *path = ToNSString(item->GetFullPath());
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished"
                                                                 object:path];
  }

  // MARK: DevTools

#if DEBUG
  void SetAppObserver(CefRefPtr<CefBrowser> browser, bool enabled) {
    devToolsRegistration_ = enabled ? browser->GetHost()->AddDevToolsMessageObserver(this) : nullptr;
  }

#endif

  void ExpectDevToolsResult(int messageID, DevToolsCompletion completion) {
    pendingDevTools_[messageID] = [completion copy];
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int messageID, bool success, const void *result,
                              size_t size) override {
    auto it = pendingDevTools_.find(messageID);
    if (it == pendingDevTools_.end()) return;
    DevToolsCompletion completion = it->second;
    pendingDevTools_.erase(it);
    NSString *json = [[NSString alloc] initWithBytes:result length:size encoding:NSUTF8StringEncoding] ?: @"";
    success ? completion(json, nil) : completion(nil, json);
  }

 private:
  __weak SHBPage *page_;
  // Popups CEF is still creating, by the ID OnBeforePopupAborted gets.
  std::map<int, SHBPage *> popups_;
  std::map<int, DevToolsCompletion> pendingDevTools_;
  CefRefPtr<CefJSDialogCallback> pendingAgentDialog_;
  CefRefPtr<CefRegistration> devToolsRegistration_;
  IMPLEMENT_REFCOUNTING(PageClient);
};

}  // namespace

@implementation SHBPage {
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<PageClient> _client;
  __weak SHBPage *_opener;
  BOOL _openedInBackground;
  // Closing was asked for, maybe before the page had been created.
  BOOL _closeRequested;
  BOOL _forceClose;
}

- (instancetype)initWithURL:(NSString *)url
                    profile:(SHBProfile *)profile
                 parentView:(NSView *)parentView
                   delegate:(id<SHBPageDelegate>)delegate {
  if ((self = [super init])) {
    _profile = profile;
    _delegate = delegate;
    _creationParent = parentView;
    _title = @"";
    _url = [url copy];
    _client = new PageClient(self);
    [gPages addObject:self];

    CefWindowInfo info;
    PlacePage(info, parentView);
    CefBrowserSettings settings;
    if (!CefBrowserHost::CreateBrowser(info, _client, url.UTF8String, settings, nullptr, profile->_context)) {
      _isClosed = YES;
      [gPages removeObject:self];
    }
  }
  return self;
}

- (instancetype)initPopupFromOpener:(SHBPage *)opener inBackground:(BOOL)inBackground {
  if ((self = [super init])) {
    _profile = opener.profile;
    self.agentDownloadFolder = opener.agentDownloadFolder;
    _delegate = opener.delegate;
    _opener = opener;
    _openedInBackground = inBackground;
    _title = @"";
    _url = @"";
    _client = new PageClient(self);
    self.agentControlled = opener.agentControlled;
    self.agentDownloadsAllowed = opener.agentDownloadsAllowed;
    [gPages addObject:self];
  }
  return self;
}

- (BOOL)agentDownloadsAllowed { return _client && _client->agentDownloadsAllowed.load(); }
- (void)setAgentDownloadsAllowed:(BOOL)value { if (_client) _client->agentDownloadsAllowed.store(value); }

- (BOOL)agentControlled { return _client && _client->agentControlled.load(); }
- (void)setAgentControlled:(BOOL)value {
  if (!_client) return;
  _client->agentControlled.store(value);
  if (!value) _client->HandleAgentDialog(false, CefString());
}

- (BOOL)handleAgentDialogAccept:(BOOL)accept text:(NSString *)text {
  return _client && _client->HandleAgentDialog(accept, text.UTF8String);
}

- (PageClient *)client {
  return _client.get();
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  _url = ToNSString(browser->GetMainFrame()->GetURL());
  NSView *view = self.view;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  SHBPage *opener = _opener;
  if (opener) {
    id<SHBPageDelegate> delegate = opener.delegate;
    if (delegate) {
      [delegate page:opener didOpenPopup:self inBackground:_openedInBackground];
    } else {
      _closeRequested = YES;
      _forceClose = YES;
    }
    opener->_client->PopupCreated(self);
  }
  if (_closeRequested) {
    // Closed before it had finished being created.
    _browser->GetHost()->CloseBrowser(_forceClose);
    return;
  }
  [self applyWebAccessibility];
  [self.delegate pageDidCreateView:self];
}

- (void)applyWebAccessibility {
  if (_browser) _browser->GetHost()->SetAccessibilityState(gWebAccessibility ? STATE_ENABLED : STATE_DISABLED);
}

- (void)browserClosed {
  // The set below may hold the last reference to this page.
  SHBPage *keepAlive = self;
  _browser = nullptr;
  _isClosed = YES;
  [gPages removeObject:keepAlive];
  [keepAlive.delegate pageDidClose:keepAlive];
}

- (void)titleChanged:(NSString *)title {
  _title = [title copy];
  [self.delegate pageDidChangeState:self];
}

- (void)urlChanged:(NSString *)url {
  _url = [url copy];
  [self.delegate pageDidChangeState:self];
}

- (void)loadingChanged:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
  _isLoading = isLoading;
  _canGoBack = canGoBack;
  _canGoForward = canGoForward;
  [self.delegate pageDidChangeState:self];
}

- (NSView *)view {
  if (!_browser) return nil;
  return CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(_browser->GetHost()->GetWindowHandle());
}

- (SHBNativeLease *)makeNativeLeaseWithHandler:(void (^)(NSString *))handler {
  if (!_browser) return nil;
  return [[SHBNativeLease alloc] initWithBrowser:_browser handler:handler];
}
#if DEBUG
- (void)setAppDevToolsObserverEnabled:(BOOL)enabled { if (_browser) _client->SetAppObserver(_browser, enabled); }
- (void)closeDevToolsFrontendForProbe { if (_browser) _browser->GetHost()->CloseDevTools(); }

#endif
- (void)loadURL:(NSString *)url {
  if (_browser) _browser->GetMainFrame()->LoadURL(url.UTF8String);
}

- (void)goBack {
  if (_browser) _browser->GoBack();
}

- (void)goForward {
  if (_browser) _browser->GoForward();
}

- (void)reload {
  if (_browser) _browser->Reload();
}

- (void)stopLoading {
  if (_browser) _browser->StopLoad();
}

- (void)focus {
  if (!_browser) return;
  NSView *view = self.view;
  [view.window makeFirstResponder:view];
  _browser->GetHost()->SetFocus(true);
}

- (NSString *)shutdownState {
  return [NSString stringWithFormat:@"id=%d requested=%d force=%d parent=%d ready=%d valid=%d",
      _browser ? _browser->GetIdentifier() : -1, _closeRequested, _forceClose,
      self.view.superview != nil, _browser && _browser->GetHost()->IsReadyToBeClosed(),
      _browser && _browser->IsValid()];
}

- (void)closeForcing:(BOOL)force {
  if (_isClosed) return;
  _closeRequested = YES;
  _forceClose = _forceClose || force;
  @autoreleasepool {
    if (_client) _client->HandleAgentDialog(false, CefString());
    if (_browser) _browser->GetHost()->CloseBrowser(force);
  }
}

- (void)runDevToolsMethod:(NSString *)method
               parameters:(NSDictionary<NSString *, id> *)parameters
               completion:(void (^)(NSString *, NSString *))completion {
  if (!_browser) {
    completion(nil, DevToolsError(@"The page isn't open."));
    return;
  }
  CefRefPtr<CefDictionaryValue> params;
  if (parameters) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:parameters options:0 error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    CefRefPtr<CefValue> value = json ? CefParseJSON(json.UTF8String, JSON_PARSER_RFC) : nullptr;
    if (value) params = value->GetDictionary();
  }
  int requestedID = (int)[SHBEngine nextDevToolsMessageID];
  int messageID = requestedID ? _browser->GetHost()->ExecuteDevToolsMethod(requestedID, method.UTF8String, params) : 0;
  if (messageID == 0) {
    completion(nil, DevToolsError(@"The method couldn't be run."));
    return;
  }
  _client->ExpectDevToolsResult(messageID, completion);
}

@end

#else  // An Intel slice: no browser.

@implementation SHBEngine
+ (NSUInteger)generation { return gGeneration; }
+ (NSInteger)nextDevToolsMessageID {
  // Never wrap/reuse an ID while the native agent may still have it pending.
  return gDevToolsMessageID == INT_MAX ? 0 : ++gDevToolsMessageID;
}
+ (BOOL)isAvailable { return NO; }
+ (BOOL)isRunning { return NO; }
+ (void)prepare {}
+ (BOOL)startWithRootCachePath:(NSString *)rootCachePath error:(NSError **)error {
  if (error) *error = EngineError(SHBEngineErrorUnavailable, @"The browser needs a Mac with Apple silicon.");
  return NO;
}
+ (BOOL)shutDownWithin:(NSTimeInterval)timeout { return YES; }
@end

@implementation SHBNativeLease
- (BOOL)sendMessage:(NSString *)json { return NO; }
- (void)invalidate {}
@end

@implementation SHBProfile
- (instancetype)initWithFolder:(NSString *)folder {
  if ((self = [super init])) _folder = [folder copy];
  return self;
}
@end

@implementation SHBPage
- (instancetype)initWithURL:(NSString *)url profile:(SHBProfile *)profile parentView:(NSView *)parentView delegate:(id<SHBPageDelegate>)delegate {
  if ((self = [super init])) {
    _profile = profile;
    _title = @"";
    _url = [url copy];
    _isClosed = YES;
  }
  return self;
}
- (SHBNativeLease *)makeNativeLeaseWithHandler:(void (^)(NSString *))handler { return nil; }
- (void)setAppDevToolsObserverEnabled:(BOOL)enabled {}
- (void)closeDevToolsFrontendForProbe {}
- (NSView *)view { return nil; }
- (void)loadURL:(NSString *)url {}
- (void)goBack {}
- (void)goForward {}
- (void)reload {}
- (void)stopLoading {}
- (void)focus {}
- (void)closeForcing:(BOOL)force {}
- (BOOL)handleAgentDialogAccept:(BOOL)accept text:(NSString *)text { return NO; }
- (void)runDevToolsMethod:(NSString *)method parameters:(NSDictionary<NSString *, id> *)parameters completion:(void (^)(NSString *, NSString *))completion {
  completion(nil, @"{\"message\":\"No browser in this build.\"}");
}
@end

#endif
#endif
