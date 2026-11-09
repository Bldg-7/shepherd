// Actual Release Objective-C interface, compiled without any CEF include/library.
#import "BrowserEngine.h"
#include <stdio.h>
#include <stdlib.h>
static unsigned checks = 0;
static void expect(BOOL value, const char *name) {
  if (!value) { fprintf(stderr, "FAIL %s\n", name); exit(1); }
  checks++;
}
int main(void) {
  @autoreleasepool {
    expect(NSApp == nil, "no application created");
    expect(!SHBEngine.isAvailable && !SHBEngine.isRunning, "explicitly unavailable");
    NSUInteger generation = SHBEngine.generation;
    [SHBEngine prepare];
    expect(NSApp == nil && SHBEngine.generation == generation, "prepare has no side effects");
    NSError *error = nil;
    expect(![SHBEngine startWithRootCachePath:@"/fixture-only/no-create" error:&error], "start refused");
    expect([error.domain isEqualToString:SHBEngineErrorDomain] && error.code == SHBEngineErrorUnavailable,
           "unavailable error not a success");
    expect([error.localizedDescription isEqualToString:@"Browser integration is unavailable in this build."],
           "truthful error including arm64 Release");
    expect([SHBEngine shutDownWithin:0] && !SHBEngine.isRunning && SHBEngine.generation == generation,
           "shutdown has no browser to retire");
    SHBProfile *profile = [[SHBProfile alloc] initWithFolder:@"/fixture-only/no-create"];
    expect(![profile prepareCredentialProxyOnPort:1 username:@"nonsecret-fixture" password:@"nonsecret-fixture"
              authorities:@[] networkPolicy:^BOOL(NSString *value) { abort(); }
              certificatePolicy:^BOOL(NSString *host, NSArray<NSData *> *chain) { abort(); }],
           "credential proxy unavailable, policies never called");
    expect(![profile removeCredentialProxy], "no unproven restoration acknowledgment");
    expect(NSApp == nil && !SHBEngine.isAvailable, "no application or capability created");
    printf("{\"passed\":true,\"checks\":%u,\"cefAvailable\":false,\"applicationCreated\":false}\n", checks);
  }
  return 0;
}
