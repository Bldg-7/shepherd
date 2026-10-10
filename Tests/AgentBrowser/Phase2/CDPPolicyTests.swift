import Foundation

@main struct CDPPolicyTests {
    static func main() {
        precondition(CDPRoute("/herdr/default/pane/w1:p1") == CDPRoute("/v1/herdr/default/pane/w1:p1"))
        precondition(CDPRoute("/v1/herdr/named%20session/pane/w1%3Ap1")?.session == "named session")
        for path in ["/", "/v2/herdr/s/pane/p", "/herdr//pane/p", "/herdr/s/pane/p/", "/herdr/s/pane/%2F", "/herdr/s/pane/%00", "/herdr/s/pane/%ZZ", "/herdr/s/pane/p?token=x", "/herdr/s/pane/.."] {
            precondition(CDPRoute(path) == nil, path)
        }
        precondition(CDPPolicy.authenticated(["Bearer disposable"], token: "disposable"))
        precondition(!CDPPolicy.authenticated([], token: "disposable"))
        precondition(!CDPPolicy.authenticated(["Bearer wrong"], token: "disposable"))
        precondition(!CDPPolicy.authenticated(["Bearer disposable", "Bearer disposable"], token: "disposable"))
        for url in ["file:///etc/passwd", "chrome://settings", "devtools://devtools", "javascript:alert(1)", "about:config", "ftp://example.com", "/relative"] {
            precondition(!CDPPolicy.navigationAllowed(url), url)
        }
        precondition(CDPPolicy.navigationAllowed("about:blank"))
        precondition(CDPPolicy.navigationAllowed("about:blank#inline"))
        precondition(!CDPPolicy.navigationAllowed("about:srcdoc"))
        precondition(CDPPolicy.navigationAllowed("http://127.0.0.1:8080"))
        for method in ["Browser.close", "Browser.grantPermissions", "Security.setIgnoreCertificateErrors", "Network.clearBrowserCookies", "Network.clearBrowserCache", "Target.createTarget", "Emulation.setDeviceMetricsOverride"] {
            precondition(!CDPPolicy.pageMethods.contains(method), method)
        }
        print("PASS: route decoding, authentication, navigation and explicit page allowlist")
    }
}
