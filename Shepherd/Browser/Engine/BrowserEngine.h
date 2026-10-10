// The browser engine as Swift sees it: CEF (the Chromium Embedded Framework)
// behind three Objective-C classes. macOS only; on Apple silicon only, since
// that is the only CEF build the app carries (see scripts/cef.sh) — elsewhere
// `BrowserEngine.isAvailable` is false and nothing else may be used.
//
// Everything here is used on the main thread, which is also CEF's UI thread
// (the app pumps CEF's message loop itself; see BrowserEngine.mm).
#include <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Why the engine didn't start.
extern NSErrorDomain const SHBEngineErrorDomain;
typedef NS_ERROR_ENUM(SHBEngineErrorDomain, SHBEngineError) {
  /// The framework couldn't be loaded.
  SHBEngineErrorLoadFailed = 1,
  /// This build of the app has no browser: it runs as Intel code.
  SHBEngineErrorUnavailable = 2,
  /// CEF didn't start, most likely because another copy of the app is
  /// using the same folder.
  SHBEngineErrorStartFailed = 3,
} NS_SWIFT_NAME(BrowserEngineError);

/// CEF itself: started once, on first use, and shut down as the app quits.
NS_SWIFT_NAME(BrowserEngine)
NS_SWIFT_UI_ACTOR
@interface SHBEngine : NSObject

/// Whether this build of the app has a browser at all.
@property (class, readonly) BOOL isAvailable;
@property (class, readonly) BOOL isRunning;
/// Monotonic generation and shared IDs for all native/app DevTools requests.
@property (class, readonly) NSUInteger generation;
+ (NSInteger)nextDevToolsMessageID;

/// Readies the application object for CEF, without loading CEF: call once
/// the app has launched. From then on, an assistive app asking for web
/// accessibility is noticed even before the first page (plan item A18).
+ (void)prepare;

/// Starts CEF. Every profile's folder must be inside `rootCachePath`.
+ (BOOL)startWithRootCachePath:(NSString *)rootCachePath error:(NSError **)error;

/// Closes every page at once, without asking the pages, and shuts CEF down.
/// Returns NO if pages do not close within `timeout`; never calls CefShutdown
/// with live pages. It is meant
/// for `applicationShouldTerminate`, where nothing asynchronous gets to run
/// again (plan item F8).
+ (BOOL)shutDownWithin:(NSTimeInterval)timeout;

@end

/// Trusted native observer. Invalidating it is NOT Target-session teardown.
NS_SWIFT_NAME(BrowserNativeLease)
NS_SWIFT_UI_ACTOR
@interface SHBNativeLease : NSObject
- (BOOL)sendMessage:(NSString *)json;
- (void)invalidate;
@end

/// Cookies, logins and the rest of what sites store: a CEF request context
/// with its own folder (plan item 8, decision 1).
NS_SWIFT_NAME(BrowserProfile)
NS_SWIFT_UI_ACTOR
@interface SHBProfile : NSObject
- (instancetype)initWithFolder:(NSString *)folder;
- (instancetype)init NS_UNAVAILABLE;
@property (readonly, copy) NSString *folder;
/// App-only networking. Installs only on an unused context with unchanged default
/// routing; policy must independently confirm system DIRECT for every authority.
/// Credentials authenticate the loopback bridge, never a password-manager item.
- (BOOL)prepareCredentialProxyOnPort:(NSInteger)port
                          username:(NSString *)username
                          password:(NSString *)password
                       authorities:(NSArray<NSString *> *)authorities
                     networkPolicy:(BOOL (^)(NSString *authority))networkPolicy
                 certificatePolicy:(BOOL (^)(NSString *host, NSArray<NSData *> *chain))certificatePolicy;
/// Call only after native pages have closed and broker requests were revoked.
/// NO means restoration is not proven; never release/reuse that proxy endpoint.
- (BOOL)removeCredentialProxy;
@end

/// What a site can ask permission for, as CEF numbers it
/// (cef_permission_request_types_t). Only the ones the app names; a request
/// can carry others too.
typedef NS_OPTIONS(NSUInteger, SHBPermission) {
  SHBPermissionCamera = 1 << 2,
  SHBPermissionClipboard = 1 << 4,
  SHBPermissionTopLevelStorageAccess = 1 << 5,
  SHBPermissionLocalFonts = 1 << 7,
  SHBPermissionGeolocation = 1 << 8,
  SHBPermissionIdleDetection = 1 << 11,
  SHBPermissionMicrophone = 1 << 12,
  SHBPermissionMIDISysex = 1 << 13,
  SHBPermissionMultipleDownloads = 1 << 14,
  SHBPermissionNotifications = 1 << 15,
  SHBPermissionStorageAccess = 1 << 20,
  SHBPermissionWindowManagement = 1 << 23,
  SHBPermissionFileSystemAccess = 1 << 24,
} NS_SWIFT_NAME(BrowserPermission);

typedef NS_ENUM(NSInteger, SHBDialogKind) {
  SHBDialogKindAlert,
  SHBDialogKindConfirm,
  SHBDialogKindPrompt,
  /// "Leave this page?" — the page has unsaved changes.
  SHBDialogKindBeforeUnload,
} NS_SWIFT_NAME(BrowserDialogKind);

@class SHBPage;

/// What a page tells its owner. Every method is called on the main thread.
NS_SWIFT_NAME(BrowserPageDelegate)
NS_SWIFT_UI_ACTOR
@protocol SHBPageDelegate <NSObject>
/// The page's view exists now (`SHBPage.view`).
- (void)pageDidCreateView:(SHBPage *)page;
/// The title, URL, loading state or history moved on.
- (void)pageDidChangeState:(SHBPage *)page;
/// The page opened another one — `window.open`, a link meant for a new tab
/// or window. `popup` is already loading, under this page's profile and
/// with this page as its opener; it is the owner's to show and keep.
- (void)page:(SHBPage *)page didOpenPopup:(SHBPage *)popup inBackground:(BOOL)inBackground;
/// A link the person asked to open in a new tab (⌘-click, middle click).
/// The page doesn't open it itself; that is up to the owner.
- (void)page:(SHBPage *)page requestsNewPageWithURL:(NSString *)url inBackground:(BOOL)inBackground;
/// The page's renderer process ended without the page being closed. The
/// page shows nothing until it is reloaded.
- (void)page:(SHBPage *)page renderProcessDidTerminateWithReason:(NSString *)reason;
/// A JavaScript dialog. The page waits until `completion` is called — once.
- (void)page:(SHBPage *)page
    runDialog:(SHBDialogKind)kind
      message:(NSString *)message
  defaultText:(NSString *)defaultText
   completion:(void (^)(BOOL accepted, NSString *text))completion;
/// The page navigated away or closed while a dialog was up; it no longer
/// waits for it.
- (void)pageDidDismissDialog:(SHBPage *)page;
/// A server asks for a user name and password (HTTP authentication).
/// `completion` with nil cancels.
- (void)page:(SHBPage *)page
    requestCredentialsForHost:(NSString *)host
                        realm:(NSString *)realm
                      isProxy:(BOOL)isProxy
                   completion:(void (^)(NSString *_Nullable user, NSString *_Nullable password))completion;
/// A site asks for permissions. Camera and microphone never get here: the
/// app has no access to either, so they are turned down at once.
- (void)page:(SHBPage *)page
    requestPermissions:(SHBPermission)permissions
             forOrigin:(NSString *)origin
            completion:(void (^)(BOOL granted))completion;
/// The site withdrew the permission request it made last.
- (void)pageDidDismissPermissionRequest:(SHBPage *)page;
/// The page is gone: it was closed, or it closed itself (`window.close`).
- (void)pageDidClose:(SHBPage *)page;
/// Download metadata only; the owner decides whether to deliver it to CDP.
- (void)page:(SHBPage *)page downloadDidChange:(NSDictionary<NSString *, id> *)metadata;
@end

/// One browser tab: a CEF browser and its view.
NS_SWIFT_NAME(BrowserPage)
NS_SWIFT_UI_ACTOR
@interface SHBPage : NSObject

/// Starts loading `url` in a new page under `profile`. The page's view is
/// made a subview of `parentView` once it exists (see the delegate); move
/// it anywhere after that.
- (instancetype)initWithURL:(NSString *)url
                    profile:(SHBProfile *)profile
                 parentView:(NSView *)parentView
                   delegate:(id<SHBPageDelegate>)delegate;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<SHBPageDelegate> delegate;
@property (nonatomic, readonly) SHBProfile *profile;
/// Nil until the page has been created, and again once it has closed.
@property (nonatomic, readonly, nullable) NSView *view;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *url;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL isClosed;
/// Request-layer guard while CDP controls the page (including redirects/popups).
@property (nonatomic) BOOL agentControlled;
@property (nonatomic) BOOL agentDownloadsAllowed;
@property (nonatomic, copy, nullable) NSString *agentDownloadFolder;
/// Trusted app-only provenance issuer. Body is always the original nonsecret
/// browser body. nil ticket cancels; no issuer means broker requests unsupported.
/// The issuer must bind native page/frame/document identity to its live DOM lease.
@property (nonatomic, copy, nullable) void (^credentialRequestIssuer)(NSDictionary<NSString *, id> *evidence, void (^completion)(NSString *_Nullable ticket));

- (SHBNativeLease *)makeNativeLeaseWithHandler:(void (^)(NSString *json))handler NS_SWIFT_NAME(makeNativeLease(handler:));
#if DEBUG
- (void)setAppDevToolsObserverEnabled:(BOOL)enabled;
- (void)closeDevToolsFrontendForProbe;
#endif
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
/// Gives the page the keyboard.
- (void)focus;
/// Closes the page. Unless `force`, the page may first ask whether to leave
/// (a `beforeunload` dialog) and stay open if the answer is no.
- (void)closeForcing:(BOOL)force;
/// Completes this page's owned agent dialog without CEF's native NSAlert runner.
- (BOOL)handleAgentDialogAccept:(BOOL)accept text:(NSString *)text NS_SWIFT_NAME(handleAgentDialog(accept:text:));

/// Runs a DevTools protocol method on this page, for the app's own use.
/// `completion` gets the result as JSON, or nil and the error as JSON.
- (void)runDevToolsMethod:(NSString *)method
               parameters:(nullable NSDictionary<NSString *, id> *)parameters
               completion:(void (^)(NSString *_Nullable result, NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif
