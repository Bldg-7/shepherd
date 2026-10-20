import Foundation

/// A link clicked in a terminal to an HTML file on this Mac, which opens as
/// a page in a browser, as a web link does, rather than as source in the
/// file preview.
///
/// Only from a pane of this Mac's own herdr: its paths are this Mac's, which
/// a browser here can read. A pane on an SSH machine or a herdr machine
/// keeps the preview, whose source is all it shows of the file. Nothing is
/// looked up on disk first: a file that isn't there is the browser's to say.
nonisolated enum TerminalPageLink {
    /// The extensions of a file that opens as a page, lowercased. Not
    /// `.xhtml` or `.svg`, which the preview shows as before.
    static let pageExtensions: Set<String> = ["html", "htm"]

    /// Whether HTML file links in a pane open as pages: only in a pane of
    /// this Mac's own herdr. `machineIsLocal` is the pane's Machine's,
    /// `onHerdrMachine` whether the pane is on one of its herdr machines.
    static func opensPages(machineIsLocal: Bool, onHerdrMachine: Bool) -> Bool {
        machineIsLocal && !onHerdrMachine
    }

    /// `raw`, a link clicked in a terminal, as the `file:` URL of the HTML
    /// page it points to, or nil for any other link, and for one the file
    /// preview can't take either (it says why). Resolved as the preview
    /// resolves it (`FilePreviewLink.resolve`), against the pane's working
    /// directory: a `file:` link's fragment is kept for the page, a
    /// `path:line` link's line is dropped, and a query is refused.
    static func pageURL(_ raw: String, directory: String?, hostname: String, additionalHosts: Set<String> = []) -> String? {
        guard raw.utf8.count <= 8192, !raw.isEmpty, !raw.unicodeScalars.contains(where: isControl) else { return nil }
        var link = raw
        var fragment: String?
        if raw.lowercased().hasPrefix("file:") {
            // The preview takes a fragment for a line (`#L12`); a page has
            // anchors there, so the fragment goes with the page instead.
            guard var components = URLComponents(string: raw) else { return nil }
            fragment = components.percentEncodedFragment
            components.percentEncodedFragment = nil
            guard let withoutFragment = components.string else { return nil }
            link = withoutFragment
        }
        guard let resolved = try? FilePreviewLink.resolve(link, directory: directory, hostname: hostname, additionalHosts: additionalHosts),
              pageExtensions.contains((resolved.path as NSString).pathExtension.lowercased()) else { return nil }
        return fileURL(path: resolved.path, percentEncodedFragment: fragment)
    }

    /// Whether `url` is a page link, as `pageURL` makes them: a `file:`
    /// URL. Anything else that reaches `openWeb` is a web link.
    static func isPageURL(_ url: String) -> Bool {
        url.lowercased().hasPrefix("file:")
    }

    /// `url` as a page link to open: a `file:` URL of an absolute path to an
    /// HTML file, without a host, credentials, port or query, nor control
    /// characters or whitespace, and at most 8 KB. Nil for anything else.
    static func validatedURL(_ url: String) -> String? {
        guard url.utf8.count <= 8192, !url.unicodeScalars.contains(where: { isControl($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: url), components.scheme?.lowercased() == "file",
              components.host?.isEmpty ?? true, components.user == nil, components.password == nil,
              components.port == nil, components.query == nil,
              let path = components.percentEncodedPath.removingPercentEncoding, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: isControl),
              pageExtensions.contains((path as NSString).pathExtension.lowercased()),
              components.url != nil else { return nil }
        return url
    }

    /// Whether a browser tab's address shows a file of this Mac: a `file:`
    /// URL, or the source of one. Such a tab is emptied before an agent is
    /// given the browser (`PaneBrowser.emptyLocalFileTabs`).
    static func isLocalFileAddress(_ address: String) -> Bool {
        let lowered = address.lowercased()
        return lowered.hasPrefix("file:") || lowered.hasPrefix("view-source:file:")
    }

    /// The `file:` URL of `path`, built from its characters as they are:
    /// Korean and other composed names stay composed (NFC), where
    /// `URL(fileURLWithPath:)` would decompose them.
    private static func fileURL(path: String, percentEncodedFragment: String?) -> String? {
        var url = URLComponents()
        url.scheme = "file"
        url.host = ""
        url.path = path
        if let percentEncodedFragment, !percentEncodedFragment.isEmpty {
            url.percentEncodedFragment = percentEncodedFragment
        }
        return url.string
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
    }
}

/// Where a link clicked in a pane's terminal goes, decided before anything
/// is opened or read.
nonisolated enum TerminalLinkRoute: Equatable, Sendable {
    /// An `http(s)` link, to open as `openWeb` decides.
    case web(String)
    /// An HTML file on this Mac, as a `file:` URL (`TerminalPageLink`), to
    /// open as a web link is.
    case page(String)
    /// A file, as clicked, for the preview beside the pane, which says why
    /// when it can't show it.
    case file(String)

    /// Nil for a link that is none of these, which opens nothing.
    /// `opensPages` is `TerminalPageLink.opensPages` for the clicked pane.
    init?(link: String, directory: String?, hostname: String, additionalHosts: Set<String>, opensPages: Bool) {
        let raw = link.lowercased().hasPrefix("file:") ? link : link.trimmingCharacters(in: .whitespaces)
        if TerminalWebLink.isWebLink(raw) {
            self = .web(raw)
            return
        }
        if opensPages, let page = TerminalPageLink.pageURL(raw, directory: directory, hostname: hostname, additionalHosts: additionalHosts) {
            self = .page(page)
            return
        }
        do {
            _ = try FilePreviewLink.resolve(raw, directory: directory, hostname: hostname, additionalHosts: additionalHosts)
        }
        catch FilePreviewError.unsupportedLink { return nil }
        catch { /* Show file-path errors in the preview, without reading. */ }
        self = .file(raw)
    }
}

/// Hands a link to the Mac's default browser. A web link goes to whatever
/// opens it. A page — an HTML file on this Mac — goes to the app that opens
/// `https` links, which is the browser, rather than to the app that opens
/// its file type: for `.html` that can be an editor. With no app for
/// `https` links, it goes to whatever opens it, as a web link does.
///
/// The opening itself is given, so that what decides it runs without
/// opening anything.
struct DefaultBrowserOpener {
    /// The app that opens `https` links, if there is one.
    var webBrowser: () -> URL?
    /// Opens a URL in whatever opens it.
    var openWithDefaultApp: (URL) -> Void
    /// Opens a URL in the app at the second URL.
    var openWithApp: (URL, URL) -> Void

    func open(_ url: URL) {
        if url.isFileURL, let browser = webBrowser() {
            openWithApp(url, browser)
        } else {
            openWithDefaultApp(url)
        }
    }
}
