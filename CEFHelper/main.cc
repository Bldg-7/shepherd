// The helper executable of the macOS app's browser: every Chromium
// sub-process (renderer, GPU, network and the rest) runs this. It is built by
// scripts/cef.sh, not by Xcode, and copied five times under the names CEF
// looks for ("Shepherd Helper", "Shepherd Helper (Renderer)", ...), which
// only differ in the entitlements they are signed with.

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // Before anything else: once the sandbox is on, the process can no longer
  // open the framework or most other files.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }

  // The framework is loaded at run time rather than linked, as the sandbox
  // requires.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
