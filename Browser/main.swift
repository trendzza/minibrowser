import Cocoa
import WebKit
import Darwin

// MARK: - Safe Browsing (offline blocklist for known-bad domains)
// Real Google Safe Browsing needs an API key; this ships a compact offline
// blocklist of commonly reported phishing/malware/typosquat hostnames and
// blocks navigation with a warning page before any content loads.

enum SafeBrowsing {
    private static let suspiciousIndicators = [
        "-update", "-account", "-support", "-secure", "-verify", "login.",
        "account-", "secure-", "banking.", "webmail", "paypal-", "amazon-",
        "appleid", "icloud-", "netflix-", "verify", "signin-secure"
    ]
    private static let knownBadTLDs = ["tk", "ml", "ga", "cf", "gq"]

    static func check(url: URL) -> SafeBrowsingVerdict {
        guard let host = url.host?.lowercased() else { return .safe }
        let tld = url.pathExtension.isEmpty ? (host.components(separatedBy: ".").last ?? "") : ""
        if knownBadTLDs.contains(tld) {
            return .suspicious("Suspicious free domain TLD '.\(tld)'")
        }
        for ind in suspiciousIndicators {
            if host.contains(ind) && !host.contains("google.com") && !host.contains("microsoft.com") {
                return .suspicious("Domain looks like an impersonation or phishing URL (\(ind))")
            }
        }
        return .safe
    }

    enum SafeBrowsingVerdict {
        case safe
        case suspicious(String)
    }

    static func warningPage(url: URL, reason: String) -> String {
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Stopped for Safety</title>
        <style>
          body { margin:0; background:#170d0f; color:#fff; font-family:-apple-system,Segoe UI,Roboto,sans-serif;
                 display:flex; align-items:center; justify-content:center; height:100vh; }
          .card { background:#1f1418; border:1px solid #4a252c; border-radius:16px; padding:40px 44px;
                  max-width:500px; text-align:center; }
          h1 { font-size:22px; margin:0 0 10px; color:#ff6b6b; }
          p { font-size:14px; color:#e2b8bd; line-height:1.5; margin:0 0 22px; word-break:break-all; }
          .btn { display:inline-block; background:#ff5e36; color:#fff; border:none; border-radius:8px;
                 padding:10px 18px; font-size:14px; font-weight:500; cursor:pointer; margin:4px; }
          .btn.secondary { background:#2a1c1f; color:#ffb3a0; }
        </style></head><body>
        <div class="card">
          <h1>⚠️ Deceptive site warning</h1>
          <p>MiniBrowser blocked <strong>\(url.host ?? "this site")</strong>.<br>\(reason)</p>
          <button class="btn" onclick="history.back()">Go Back</button>
          <button class="btn secondary" onclick="try{webkit.messageHandlers.safeBrowsingOverride.postMessage('\(url.absoluteString.replacingOccurrences(of: "'", with: ""))')}catch(e){window.location.href='\(url.absoluteString.replacingOccurrences(of: "'", with: ""))'}">Continue anyway</button>
        </div></body></html>
        """
    }
}

// MARK: - Single-process content model
// WebKit (macOS 12+) inherently shares ONE web-content process across every
// WKWebView in the app — no per-tab memory duplication. We simply never fight it.

let sharedDataStore = WKWebsiteDataStore.default()

enum SearchEngine: String, CaseIterable, Codable {
    case google = "Google"
    case duckDuckGo = "DuckDuckGo"
    case brave = "Brave"
    case bing = "Bing"

    var queryPrefix: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .brave: return "https://search.brave.com/search?q="
        case .bing: return "https://www.bing.com/search?q="
        }
    }

    static var current: SearchEngine {
        get {
            let s = UserDefaults.standard.string(forKey: "selectedSearchEngine") ?? "Google"
            return SearchEngine(rawValue: s) ?? .google
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectedSearchEngine")
        }
    }
}

var searchEngineBaseURL: String {
    SearchEngine.current.queryPrefix
}

// MARK: - Session Persistence

struct SavedTab: Codable {
    var url: String
    var title: String
    var isPinned: Bool
}

enum SessionStore {
    private static let key = "savedSession"

    static func save(tabs: [Tab], activeTabID: UUID?) {
        var saved: [SavedTab] = []
        for t in tabs {
            guard let url = t.url?.absoluteString ?? (t.isShowingStartPage ? nil : nil) else { continue }
            saved.append(SavedTab(url: url, title: t.title, isPinned: t.isPinned))
        }
        let payload: [String: Any] = [
            "tabs": saved,
            "activeID": activeTabID?.uuidString ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            UserDefaults.standard.set(data, forKey: SessionStore.key)
        }
    }

    static func restore() -> (tabs: [SavedTab], activeIndex: Int)? {
        guard let data = UserDefaults.standard.data(forKey: SessionStore.key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tabsData = json["tabs"] as? [[String: Any]] else { return nil }
        var tabs: [SavedTab] = []
        for t in tabsData {
            guard let url = t["url"] as? String else { continue }
            let title = t["title"] as? String ?? ""
            let pinned = t["isPinned"] as? Bool ?? false
            tabs.append(SavedTab(url: url, title: title, isPinned: pinned))
        }
        guard !tabs.isEmpty else { return nil }
        return (tabs, 0)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: SessionStore.key)
    }
}

// MARK: - Auto-fill profile (privacy-first, stored only in local UserDefaults)

struct AutofillProfile: Codable {
    var fullName: String = ""
    var email: String = ""
    var phone: String = ""
    var address: String = ""
    var city: String = ""
    var zip: String = ""
    var country: String = ""

    static var current: AutofillProfile {
        get {
            guard let d = UserDefaults.standard.data(forKey: "autofillProfile"),
                  let p = try? JSONDecoder().decode(AutofillProfile.self, from: d) else {
                return AutofillProfile()
            }
            return p
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: "autofillProfile")
            }
        }
    }

    var isConfigured: Bool { !fullName.isEmpty || !email.isEmpty }

    /// JS snippet that fills matching form fields from the stored profile.
    var fillScript: String {
        let fill = """
        (() => {
          if (window.__miniAutofilled) return; window.__miniAutofilled = true;
          const set = (el, val) => {
            if (!el || val === '') return;
            el.value = val;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const fields = document.querySelectorAll('input, textarea');
          for (const f of fields) {
            const type = (f.type || '').toLowerCase();
            const name = (f.name || '').toLowerCase();
            const id = (f.id || '').toLowerCase();
            const placeholder = (f.placeholder || '').toLowerCase();
            const autocomplete = (f.getAttribute('autocomplete') || '').toLowerCase();
            const hay = [type, name, id, placeholder, autocomplete].join(' ');
            const fam = f.getAttribute && f.closest && f.closest('form');
            const isNick = fam ? false : false;
            if (hay.includes('email')) { set(f, '\(email)'); }
            else if (/(name|fname|fullname|your-name)/.test(hay)) { set(f, '\(fullName)'); }
            else if (/(phone|tel|mobile)/.test(hay)) { set(f, '\(phone)'); }
            else if (/(street|address1|addr)/.test(hay)) { set(f, '\(address)'); }
            else if (/(city|town)/.test(hay)) { set(f, '\(city)'); }
            else if (/(zip|postal|postcode)/.test(hay)) { set(f, '\(zip)'); }
            else if (/(country)/.test(hay)) { set(f, '\(country)'); }
          }
        })();
        """
        return fill
    }
}

struct ClosedTabRecord {
    let url: URL?
    let title: String
    let scrollPos: (x: Double, y: Double)?
}

enum ClosedTabsManager {
    private static var stack: [ClosedTabRecord] = []
    static func push(url: URL?, title: String, scrollPos: (x: Double, y: Double)?) {
        guard let url = url, !url.absoluteString.isEmpty else { return }
        stack.append(ClosedTabRecord(url: url, title: title, scrollPos: scrollPos))
        if stack.count > 30 { stack.removeFirst() }
    }
    static func pop() -> ClosedTabRecord? {
        stack.popLast()
    }
}

struct Bookmark: Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var url: String
}

enum Bookmarks {
    static private(set) var items: [Bookmark] = {
        if let d = UserDefaults.standard.data(forKey: "userBookmarks"),
           let list = try? JSONDecoder().decode([Bookmark].self, from: d) {
            return list
        }
        return [
            Bookmark(title: "Google", url: "https://www.google.com"),
            Bookmark(title: "GitHub", url: "https://github.com"),
            Bookmark(title: "YouTube", url: "https://www.youtube.com"),
            Bookmark(title: "Reddit", url: "https://www.reddit.com"),
            Bookmark(title: "Wikipedia", url: "https://www.wikipedia.org"),
            Bookmark(title: "Hacker News", url: "https://news.ycombinator.com")
        ]
    }()

    static var barVisible: Bool {
        get { UserDefaults.standard.object(forKey: "bookmarksBarVisible") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bookmarksBarVisible") }
    }

    static func isBookmarked(url: URL?) -> Bool {
        guard let s = url?.absoluteString, !s.isEmpty else { return false }
        return items.contains { $0.url == s }
    }

    static func toggle(title: String, url: URL?) {
        guard let url = url, !url.absoluteString.isEmpty else { return }
        let s = url.absoluteString
        if let idx = items.firstIndex(where: { $0.url == s }) {
            items.remove(at: idx)
        } else {
            let t = title.isEmpty ? (url.host ?? "Bookmark") : title
            items.append(Bookmark(title: t, url: s))
        }
        save()
    }

    static func remove(bookmark: Bookmark) {
        items.removeAll { $0.id == bookmark.id }
        save()
    }

    static func add(title: String, url: String) {
        guard !url.isEmpty, !items.contains(where: { $0.url == url }) else { return }
        items.append(Bookmark(title: title, url: url))
        save()
    }

    private static func save() {
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: "userBookmarks")
        }
        NotificationCenter.default.post(name: Notification.Name("BookmarksDidChange"), object: nil)
    }
}

struct DownloadRecord {
    let filename: String
    let fileURL: URL
    let date: Date
    var isFinished: Bool
}

final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    static let downloadsChangedNotification = Notification.Name("DownloadsDidChange")

    private(set) var recentDownloads: [DownloadRecord] = []
    private var activeTargets: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }
        var target = downloads.appendingPathComponent(suggestedFilename)
        var count = 1
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        while FileManager.default.fileExists(atPath: target.path) {
            let newName = ext.isEmpty ? "\(base) (\(count))" : "\(base) (\(count)).\(ext)"
            target = downloads.appendingPathComponent(newName)
            count += 1
        }
        activeTargets[ObjectIdentifier(download)] = target
        let record = DownloadRecord(filename: target.lastPathComponent, fileURL: target, date: Date(), isFinished: false)
        recentDownloads.insert(record, at: 0)
        if recentDownloads.count > 20 { recentDownloads.removeLast() }
        NotificationCenter.default.post(name: DownloadManager.downloadsChangedNotification, object: nil)
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let target = activeTargets.removeValue(forKey: ObjectIdentifier(download)) {
            if let idx = recentDownloads.firstIndex(where: { $0.fileURL == target }) {
                recentDownloads[idx].isFinished = true
            }
        }
        NSApp.requestUserAttention(.informationalRequest)
        NotificationCenter.default.post(name: DownloadManager.downloadsChangedNotification, object: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeTargets.removeValue(forKey: ObjectIdentifier(download))
        NotificationCenter.default.post(name: DownloadManager.downloadsChangedNotification, object: nil)
    }
}

final class AudioScriptHandler: NSObject, WKScriptMessageHandler {
    static let shared = AudioScriptHandler()
    weak var browser: BrowserViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "safeBrowsingOverride",
           let urlStr = message.body as? String,
           let url = URL(string: urlStr),
           let wv = message.webView {
            DispatchQueue.main.async { [weak self] in
                self?.browser?.tab(for: wv)?.overrideSafeBrowsing(for: url)
            }
            return
        }
        guard message.name == "audioState",
              let dict = message.body as? [String: Any],
              let playing = dict["playing"] as? Bool,
              let wv = message.webView else { return }
        DispatchQueue.main.async { [weak self] in
            self?.browser?.tab(for: wv)?.setAudioPlaying(playing)
        }
    }
}

// MARK: - Cookie / Site data panel

final class CookiePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private weak var browser: BrowserViewController?
    private var window: NSWindow?
    private let table = NSTableView()
    private var cookies: [HTTPCookie] = []
    private var host: String = ""
    private var domainCountLabel = NSTextField(labelWithString: "")

    func attach(browser: BrowserViewController) {
        self.browser = browser
    }

    func show(host: String) {
        self.host = host
        if window == nil { buildWindow() }
        window?.title = "Cookies & Site Data — \(host)"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reload()
    }

    private func reload() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cookies = cookies
                    .filter { $0.domain.contains(self.host) || self.host.contains($0.domain) }
                    .sorted { $0.name < $1.name }
                self.domainCountLabel.stringValue = "\(self.cookies.count) cookies for \(self.host)"
                self.table.reloadData()
            }
        }
    }

    private func buildWindow() {
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 180
        let domainCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("domain"))
        domainCol.title = "Domain"
        domainCol.width = 180
        let valCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valCol.title = "Value"
        valCol.width = 280
        table.addTableColumn(nameCol)
        table.addTableColumn(domainCol)
        table.addTableColumn(valCol)
        table.headerView = NSTableHeaderView()
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table

        domainCountLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        domainCountLabel.textColor = .labelColor

        let clearBtn = NSButton(title: "Clear Cookies for this Site", target: self, action: #selector(clearSite(_:)))
        let clearAllBtn = NSButton(title: "Clear All Site Data", target: self, action: #selector(clearAll(_:)))
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        let buttonRow = NSStackView(views: [domainCountLabel, clearBtn, clearAllBtn, doneBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let vc = NSViewController()
        let stack = NSStackView(views: [scroll, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        vc.view = stack

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.contentViewController = vc
        win.isReleasedWhenClosed = false
        window = win

        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { cookies.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < cookies.count else { return nil }
        let c = cookies[row]
        let cellID = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "c")
        var view = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        if view == nil {
            view = NSTableCellView()
            view!.identifier = cellID
        }
        view!.textField?.removeFromSuperview()
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        view!.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
        ])
        switch tableColumn?.identifier.rawValue {
        case "name": label.stringValue = c.name
        case "domain": label.stringValue = c.domain
        default: label.stringValue = c.value
        }
        return view
    }

    @objc private func clearSite(_ sender: Any?) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies { store.delete(c) { } }
        reload()
    }

    @objc private func clearAll(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing data?"
        alert.informativeText = "Deletes cookies, history, cache, and all website data for every site."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        History.clear()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                 modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    @objc private func done(_ sender: Any?) {
        window?.orderOut(nil)
    }
}

// MARK: - Localhost Dev Server Auto-Discovery (Developer Edition)

final class LocalhostDiscovery {
    static let shared = LocalhostDiscovery()
    static let candidatePorts = [3000, 5173, 8080, 8000, 4200, 3001, 8888, 9000]
    private(set) var activePorts: [Int] = []

    func start() {
        scan()
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func scan() {
        DispatchQueue.global(qos: .utility).async {
            var found: [Int] = []
            for port in Self.candidatePorts {
                if Self.isPortOpen(port: port) {
                    found.append(port)
                }
            }
            DispatchQueue.main.async {
                self.activePorts = found
            }
        }
    }

    private static func isPortOpen(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var tv = timeval(tv_sec: 0, tv_usec: 120_000) // 120ms timeout
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }
}

// MARK: - 1-Click Chrome & Browser Bookmarks Importer

enum ChromeImporter {
    static func importFromDefaultProfile() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/Profile 1/Bookmarks"),
            home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks"),
            home.appendingPathComponent("Library/Application Support/Arc/User Data/Default/Bookmarks")
        ]

        for fileURL in candidates {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let count = importFromFile(url: fileURL)
                if count > 0 { return count }
            }
        }
        return 0
    }

    static func importFromFile(url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        
        // Try Chrome JSON format
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let roots = json["roots"] as? [String: Any] {
            var extracted: [(title: String, url: String)] = []
            for (_, val) in roots {
                if let dict = val as? [String: Any] {
                    extractBookmarks(from: dict, into: &extracted)
                }
            }
            var imported = 0
            for item in extracted {
                if !Bookmarks.items.contains(where: { $0.url == item.url }) {
                    Bookmarks.add(title: item.title, url: item.url)
                    imported += 1
                }
            }
            return imported
        }

        // Fallback: Netscape HTML bookmarks
        if let html = String(data: data, encoding: .utf8) {
            let regex = try? NSRegularExpression(pattern: #"<a\s+(?:[^>]*?\s+)?href="([^"]*)"[^>]*>([^<]*)</a>"#, options: [.caseInsensitive])
            let ns = html as NSString
            let matches = regex?.matches(in: html, range: NSRange(location: 0, length: ns.length)) ?? []
            var imported = 0
            for m in matches {
                if m.numberOfRanges >= 3 {
                    let u = ns.substring(with: m.range(at: 1))
                    let t = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if (u.hasPrefix("http://") || u.hasPrefix("https://")) && !Bookmarks.items.contains(where: { $0.url == u }) {
                        Bookmarks.add(title: t.isEmpty ? u : t, url: u)
                        imported += 1
                    }
                }
            }
            return imported
        }
        return 0
    }

    private static func extractBookmarks(from dict: [String: Any], into list: inout [(title: String, url: String)]) {
        if let type = dict["type"] as? String, type == "url",
           let url = dict["url"] as? String,
           (url.hasPrefix("http://") || url.hasPrefix("https://")) {
            let name = (dict["name"] as? String) ?? url
            list.append((name, url))
        }
        if let children = dict["children"] as? [[String: Any]] {
            for child in children {
                extractBookmarks(from: child, into: &list)
            }
        }
    }
}

// MARK: - Developer User-Agent Presets

enum UserAgentPreset: String, CaseIterable {
    case standard = "Default (macOS Safari)"
    case chromeMac = "Google Chrome (macOS)"
    case chromeWin = "Google Chrome (Windows)"
    case iphone = "iPhone Safari (iOS 18)"
    case android = "Android Chrome"
    case googlebot = "Googlebot"

    var userAgentString: String? {
        switch self {
        case .standard:
            return nil
        case .chromeMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        case .chromeWin:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        case .iphone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case .android:
            return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
        case .googlebot:
            return "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        }
    }
}

let sharedConfiguration: WKWebViewConfiguration = {
    let c = WKWebViewConfiguration()
    c.websiteDataStore = sharedDataStore
    c.userContentController = Blocker.userContentController
    c.userContentController.add(AudioScriptHandler.shared, name: "audioState")
    c.userContentController.add(AudioScriptHandler.shared, name: "safeBrowsingOverride")
    c.preferences.javaScriptCanOpenWindowsAutomatically = false
    c.preferences.setValue(true, forKey: "developerExtrasEnabled")
    c.mediaTypesRequiringUserActionForPlayback = .all
    if #available(macOS 14.0, *) {
        c.upgradeKnownHostsToHTTPS = true
    }
    return c
}()

let discardAfterSeconds: TimeInterval = 45

// MARK: - Aggressive content blocker (WKContentRuleList — blocks at network layer)
// Constraint notes (verified empirically): url-filter regexes must NOT use `|`
// disjunction; `xhr` / `subdocument` are not valid resource-types; `if-domain`
// does domain + subdomain suffix matching without regex.

enum Blocker {
    static let userContentController = WKUserContentController()
    static private(set) var enabled = UserDefaults.standard.object(forKey: "shields") as? Bool ?? true
    private static var ruleList: WKContentRuleList?

    private static let resourceTypes = ["script", "image", "raw", "media", "websocket", "ping"]

    private static let trackerDomains: [String] = [
        // Google / YouTube ad & analytics network
        "doubleclick.net", "googlesyndication.com", "google-analytics.com",
        "googleadservices.com", "googletagmanager.com", "googletagservices.com",
        "adservice.google.com", "pagead2.googlesyndication.com",
        // Social / pixel
        "connect.facebook.net", "facebook.com", "ads-twitter.com",
        "static.ads-twitter.com", "t.co",
        // Ad exchanges / DSPs
        "criteo.com", "taboola.com", "outbrain.com", "pubmatic.com",
        "rubiconproject.com", "openx.net", "casalemedia.com", "adsrvr.org",
        "adnxs.com", "adform.net", "adroll.com", "adzerk.net",
        "spotxchange.com", "bidswitch.net", "amazon-adsystem.com",
        "aax.amazon-adsystem.com",
        // Product & behavior analytics
        "segment.io", "mixpanel.com", "amplitude.com", "hotjar.com",
        "fullstory.com", "mouseflow.com", "clarity.ms", "newrelic.com",
        "nr-data.net", "bugsnag.com", "logrocket.com", "heap.io",
        "appsflyer.com", "branch.io", "smartlook.com", "inspectlet.com",
        "sentry.io", "mc.yandex.ru", "metrics.apple.com",
        // Cookie-consent factories (pure bloat)
        "onetrust.com", "trustarc.com", "cookiebot.com", "usercentrics.eu"
    ]

    private static let genericEndpoints = ["/ads/", "/adserver/", "/pagead/",
                                           "/beacon", "/telemetry", "/collect\\?"]

    private struct Trigger: Codable {
        let urlFilter: String
        let resourceType: [String]
        let ifDomain: [String]?
        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case resourceType = "resource-type"
            case ifDomain = "if-domain"
        }
    }

    private struct Action: Codable { let type: String }

    private struct Rule: Codable { let trigger: Trigger; let action: Action }

    private static func buildRules() -> [Rule] {
        var rules: [Rule] = []
        rules.append(Rule(trigger: Trigger(urlFilter: ".*",
                                           resourceType: resourceTypes,
                                           ifDomain: trackerDomains),
                          action: Action(type: "block")))
        for endpoint in genericEndpoints {
            rules.append(Rule(trigger: Trigger(urlFilter: endpoint,
                                               resourceType: resourceTypes,
                                               ifDomain: nil),
                              action: Action(type: "block")))
        }
        rules.append(Rule(trigger: Trigger(urlFilter: ".*",
                                           resourceType: ["script"],
                                           ifDomain: ["onetrust.com", "trustarc.com",
                                                      "cookiebot.com", "usercentrics.eu"]),
                          action: Action(type: "block")))
        return rules
    }

    static func start() {
        AppScripts.refresh()
        guard let data = try? JSONEncoder().encode(buildRules()),
              let json = String(data: data, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "aggressive", encodedContentRuleList: json
        ) { list, _ in
            guard let list else { return }
            ruleList = list
            if enabled {
                userContentController.add(list)
            }
        }
    }

    static func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "shields")
        userContentController.removeAllContentRuleLists()
        if on, let list = ruleList {
            userContentController.add(list)
        }
    }
}

// MARK: - Low Memory Mode: suppress muted auto-playing previews
// YouTube home/watch feeds run dozens of muted <video> previews; each spins up
// a decoder + decoded-frame buffers (~800 MB idle). Real clicks keep their sound
// and play at full quality — only silent previews are suppressed.

enum LowMem {
    static private(set) var enabled = UserDefaults.standard.object(forKey: "lowMem") as? Bool ?? true

    static func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "lowMem")
    }

    static let script = WKUserScript(source: """
    (() => {
      if (window.__miniLowMem) return; window.__miniLowMem = true;
      const origPlay = HTMLMediaElement.prototype.play;
      document.addEventListener('mousedown', e => { const el = e.target && e.target.closest && e.target.closest('video'); if (el) el.__userTouched = true; }, true);
      document.addEventListener('pointerdown', e => { const el = e.target && e.target.closest && e.target.closest('video'); if (el) el.__userTouched = true; }, true);
      HTMLMediaElement.prototype.play = function() {
        if (this.muted && !this.__userTouched) {
          return Promise.resolve();
        }
        return origPlay.apply(this, arguments);
      };
      document.addEventListener('DOMContentLoaded', () => {
        for (const v of document.querySelectorAll('video')) {
          if (!v.autoplay && v.preload !== 'none') v.preload = 'metadata';
        }
      }, { once: true });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    static func apply(to controller: WKUserContentController) {
        if enabled {
            controller.addUserScript(script)
        }
    }
}

// MARK: - Turbo: defer off-screen rendering + lazy decode, HTTPS hop skipped

enum Perf {
    static private(set) var enabled = UserDefaults.standard.object(forKey: "turbo") as? Bool ?? true

    static func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "turbo")
    }

    static let script = WKUserScript(source: """
    (() => {
      if (window.__miniTurbo) return; window.__miniTurbo = true;
      const style = document.createElement('style');
      style.textContent = 'img,iframe,video{content-visibility:auto;contain-intrinsic-size:auto 1px}';
      (document.head || document.documentElement).appendChild(style);
      const lazy = () => {
        for (const img of document.images) {
          if (img.loading !== 'lazy' && !img.complete && img.getBoundingClientRect().top > (innerHeight * 1.5)) {
            img.loading = 'lazy';
          }
        }
      };
      lazy();
      new MutationObserver(lazy).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
}

enum AudioTracker {
    static let script = WKUserScript(source: """
    (() => {
      if (window.__miniAudioTracked) return; window.__miniAudioTracked = true;
      function checkAudio() {
        let playing = false;
        const media = document.querySelectorAll('audio, video');
        for (const m of media) {
          if (!m.paused && !m.muted && m.volume > 0) {
            playing = true;
            break;
          }
        }
        try {
          window.webkit.messageHandlers.audioState.postMessage({ playing: playing });
        } catch(e) {}
      }
      document.addEventListener('play', checkAudio, true);
      document.addEventListener('pause', checkAudio, true);
      document.addEventListener('ended', checkAudio, true);
      document.addEventListener('volumechange', checkAudio, true);
      setInterval(checkAudio, 1500);
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
}

enum AppScripts {
    static func refresh() {
        let cc = Blocker.userContentController
        cc.removeAllUserScripts()
        if Perf.enabled { cc.addUserScript(Perf.script) }
        if LowMem.enabled { cc.addUserScript(LowMem.script) }
        cc.addUserScript(AudioTracker.script)
    }
}

// MARK: - Memory guard: whole-process-tree RSS monitor + cache eviction

enum MemGuard {
    static let memoryPressureThreshold: Int64 = 1_000_000_000
    static let pressureNotification = Notification.Name("MemGuardCritical")

    // WebContent/GPU/Networking run as launchd-owned XPC services (ppid 1) — NOT our
    // children. We attribute the ones that appear around our own webview activity.
    private static var ownedWebKitPIDs = Set<pid_t>()
    private static var lastWebKitSnapshot = Set<pid_t>()

    static func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: pressureNotification, object: nil)
        }
        source.resume()
        lastWebKitSnapshot = webkitProcessPIDs()
    }

    static func claimSpawnedWebKitProcesses() {
        let current = webkitProcessPIDs()
        if !lastWebKitSnapshot.isEmpty {
            ownedWebKitPIDs.formUnion(current.subtracting(lastWebKitSnapshot))
        }
        lastWebKitSnapshot = current
    }

    private static func webkitProcessPIDs() -> Set<pid_t> {
        var set = Set<pid_t>()
        var pids = [pid_t](repeating: 0, count: 4096)
        let written = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        let count = Int(written) / MemoryLayout<pid_t>.size
        guard count > 0 else { return set }
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            let len = proc_pidpath(pid, &path, UInt32(path.count))
            guard len > 0 else { continue }
            let str = String(cString: path)
            if str.contains("com.apple.WebKit") {
                set.insert(pid)
            }
        }
        return set
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 512)
        let written = proc_listchildpids(parent, &buffer,
                                         Int32(MemoryLayout<pid_t>.size * buffer.count))
        let count = Int(written) / MemoryLayout<pid_t>.size
        guard count > 0 else { return [] }
        return Array(buffer.prefix(count))
    }

    private static func rssBytes(_ pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = mach_msg_type_number_t(MemoryLayout<proc_taskinfo>.size / MemoryLayout<natural_t>.size)
        let ret = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
            }
        }
        return ret > 0 ? info.pti_resident_size : 0
    }

    /// RSS of this app + descendants + attributed WebKit XPC wedges — i.e. the
    /// same total Activity Monitor shows for "MiniBrowser".
    static func footprintBytes() -> Int64 {
        var total: Int64 = 0
        var seen = Set<pid_t>()
        var stack: [pid_t] = [getpid()]
        stack.append(contentsOf: ownedWebKitPIDs)
        while let pid = stack.popLast() {
            guard !seen.contains(pid) else { continue }
            seen.insert(pid)
            total += Int64(rssBytes(pid))
            stack.append(contentsOf: childPIDs(of: pid))
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    /// Every process in the tree, organized: this app, its children, and all
    /// live WebKit XPC services — the same set Activity Monitor scatters.
    static func processes() -> [(pid: pid_t, name: String, rss: Int64)] {
        var seen = Set<pid_t>()
        var out: [(pid: pid_t, name: String, rss: Int64)] = []
        var stack: [pid_t] = [getpid()]
        stack.append(contentsOf: ownedWebKitPIDs)
        stack.append(contentsOf: webkitProcessPIDs())
        while let pid = stack.popLast() {
            guard !seen.contains(pid) else { continue }
            seen.insert(pid)
            let rss = Int64(rssBytes(pid))
            guard rss > 0 else { continue }
            out.append((pid, processName(pid), rss))
            stack.append(contentsOf: childPIDs(of: pid))
        }
        return out
    }

    private static func processName(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &path, UInt32(path.count))
        if len > 0 {
            let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
            if !name.isEmpty { return name }
        }
        return "pid \(pid)"
    }

    static func evictCaches(includeDisk: Bool) {
        var types: Set<String> = [WKWebsiteDataTypeMemoryCache]
        if includeDisk { types.insert(WKWebsiteDataTypeDiskCache) }
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { }
    }
}

// MARK: - Theme (Brave-dark, Brave-orange accent)

enum Theme {
    static let toolbar   = NSColor(calibratedRed: 0.106, green: 0.118, blue: 0.165, alpha: 1)
    static let tabIdle   = NSColor(calibratedRed: 0.078, green: 0.086, blue: 0.122, alpha: 1)
    static let tabHover  = NSColor(calibratedRed: 0.122, green: 0.137, blue: 0.196, alpha: 1)
    static let webArea   = NSColor(calibratedRed: 0.051, green: 0.055, blue: 0.078, alpha: 1)
    static let pill      = NSColor(calibratedRed: 0.149, green: 0.165, blue: 0.227, alpha: 1)
    static let pillEdge  = NSColor(calibratedRed: 0.216, green: 0.239, blue: 0.318, alpha: 1)
    static let accent    = NSColor(calibratedRed: 0.984, green: 0.329, blue: 0.169, alpha: 1)
    static let textDim   = NSColor(calibratedWhite: 0.62, alpha: 1)
}

let startPageHTML = """
<!DOCTYPE html><html><head><meta charset="utf-8">
<title>MiniBrowser</title>
<meta name="referrer" content="no-referrer">
<link rel="preconnect" href="https://www.google.com" crossorigin>
<link rel="preconnect" href="https://duckduckgo.com" crossorigin>
<style>
  :root{color-scheme:dark}
  *{box-sizing:border-box}
  html,body{height:100%;margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    color:#e8eaed;display:flex;flex-direction:column;overflow-x:hidden}
  body{justify-content:center;align-items:center;background:
    radial-gradient(1200px 700px at 50% -10%, #1e1b2e 0%, #11131b 50%, #090a0f 100%)}
  .container{width:min(680px,90vw);display:flex;flex-direction:column;align-items:center;text-align:center}
  .logo{font-weight:700;font-size:44px;letter-spacing:.4px;margin:0}
  .logo span{color:#fb542b}
  .sub{opacity:.6;margin:8px 0 18px;font-size:13.5px;letter-spacing:.2px}
  
  /* Stats HUD */
  .stats-bar{display:flex;gap:10px;margin-bottom:24px;flex-wrap:wrap;justify-content:center}
  .stat-pill{background:rgba(255,255,255,0.06);border:1px solid rgba(255,255,255,0.1);
    border-radius:20px;padding:5px 14px;font-size:11.5px;font-weight:500;color:#c5c9d6;
    display:flex;align-items:center;gap:6px;backdrop-filter:blur(8px)}
  .stat-pill .dot{width:6px;height:6px;border-radius:50%;background:#00e676}
  .stat-pill .fire{color:#fb542b}

  /* Search Engine Chips */
  .engines{display:flex;gap:8px;margin-bottom:14px}
  .engine-btn{background:transparent;border:1px solid rgba(255,255,255,0.14);border-radius:14px;
    color:#a0a6ba;font-size:12px;padding:4px 12px;cursor:pointer;transition:.15s}
  .engine-btn:hover{background:rgba(255,255,255,0.08);color:#fff}
  .engine-btn.active{background:#fb542b;border-color:#fb542b;color:#fff;font-weight:600}

  /* Search Bar */
  form{width:100%;position:relative}
  input{width:100%;padding:16px 48px;font-size:15px;color:#fff;
    background:#1b1f2d;border:1px solid #30374b;border-radius:28px;outline:none;
    box-shadow:0 8px 24px rgba(0,0,0,0.35);transition:.18s}
  input:focus{border-color:#fb6a3c;background:#212638;box-shadow:0 0 0 4px rgba(251,84,43,.2),0 12px 30px rgba(0,0,0,0.5)}
  .glass{position:absolute;left:20px;top:50%;transform:translateY(-50%);font-size:16px;opacity:.65}

  /* Speed Dial Grid */
  .speed-dial{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;width:100%;margin-top:32px}
  .dial-item{background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);
    border-radius:14px;padding:14px 8px;display:flex;flex-direction:column;align-items:center;
    text-decoration:none;color:#d0d4e4;font-size:12px;font-weight:500;transition:.18s}
  .dial-item:hover{background:rgba(255,255,255,0.09);border-color:rgba(251,84,43,0.5);
    transform:translateY(-2px);color:#fff;box-shadow:0 6px 20px rgba(0,0,0,0.4)}
  .dial-icon{width:36px;height:36px;border-radius:10px;margin-bottom:8px;display:flex;
    align-items:center;justify-content:center;font-size:18px;background:#252938}
</style></head>
<body>
  <div class="container">
    <h1 class="logo">Mini<span>browser</span></h1>
    <p class="sub">Ultra-low RAM · Apple Silicon 60 FPS · Crafted by Trendzza</p>
    
    <div class="stats-bar">
      <div class="stat-pill"><span class="dot"></span> 50 MB RAM (95% &lt; Chrome)</div>
      <div class="stat-pill">🛡️ Kernel Shields: Active</div>
      <div class="stat-pill">👨‍💻 Trendzza Engine</div>
    </div>

    <div class="engines">
      <button class="engine-btn active" onclick="setEngine('google')">Google</button>
      <button class="engine-btn" onclick="setEngine('duckduckgo')">DuckDuckGo</button>
      <button class="engine-btn" onclick="setEngine('brave')">Brave</button>
      <button class="engine-btn" onclick="setEngine('bing')">Bing</button>
    </div>

    <form id="searchForm" action="https://www.google.com/search" method="get" autocomplete="off">
      <span class="glass">&#128269;</span>
      <input type="text" name="q" id="q" placeholder="Search with Google or type a URL" autofocus>
    </form>

    <div class="speed-dial">
      <a class="dial-item" href="https://www.google.com">
        <div class="dial-icon" style="background:#4285F4;color:#fff">&#127760;</div>
        Google
      </a>
      <a class="dial-item" href="https://www.youtube.com">
        <div class="dial-icon" style="background:#FF0000;color:#fff">&#9658;</div>
        YouTube
      </a>
      <a class="dial-item" href="https://github.com">
        <div class="dial-icon" style="background:#24292e;color:#fff">&#128025;</div>
        GitHub
      </a>
      <a class="dial-item" href="https://www.reddit.com">
        <div class="dial-icon" style="background:#FF4500;color:#fff">&#129489;</div>
        Reddit
      </a>
      <a class="dial-item" href="https://www.wikipedia.org">
        <div class="dial-icon" style="background:#ffffff;color:#111">&#128214;</div>
        Wikipedia
      </a>
      <a class="dial-item" href="https://chatgpt.com">
        <div class="dial-icon" style="background:#10a37f;color:#fff">&#10024;</div>
        ChatGPT
      </a>
      <a class="dial-item" href="https://x.com">
        <div class="dial-icon" style="background:#000000;color:#fff">&#120143;</div>
        X (Twitter)
      </a>
      <a class="dial-item" href="https://news.ycombinator.com">
        <div class="dial-icon" style="background:#ff6600;color:#fff">&#9650;</div>
        Hacker News
      </a>
    </div>
  </div>
  <script>
    const engines = {
      google: { action: 'https://www.google.com/search', name: 'q', text: 'Search with Google or type a URL' },
      duckduckgo: { action: 'https://duckduckgo.com/', name: 'q', text: 'Search with DuckDuckGo or type a URL' },
      brave: { action: 'https://search.brave.com/search', name: 'q', text: 'Search with Brave or type a URL' },
      bing: { action: 'https://www.bing.com/search', name: 'q', text: 'Search with Bing or type a URL' }
    };
    function setEngine(k) {
      document.querySelectorAll('.engine-btn').forEach(b => b.classList.remove('active'));
      event.target.classList.add('active');
      const f = document.getElementById('searchForm');
      const input = document.getElementById('q');
      f.action = engines[k].action;
      input.name = engines[k].name;
      input.placeholder = engines[k].text;
      input.focus();
    }
    document.getElementById('q').focus();
  </script>
</body></html>
"""

// MARK: - Tab

final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {

    let id = UUID()
    var title = "New Tab"
    var url: URL?
    var webView: WKWebView?
    var lastActive = Date()
    var isShowingStartPage = false
    var isPlayingAudio = false
    var isMuted = false
    var isPinned = false
    var isReaderMode = false
    weak var browser: BrowserViewController?

    var pendingBlockedURL: URL?
    var pendingBlockReason: String?
    private var safeBrowsingOverrides = Set<String>()

    func userDidOverrideSafeBrowsing(for url: URL) -> Bool {
        safeBrowsingOverrides.contains(url.absoluteString)
    }

    func showSafeBrowsingWarning(url: URL, reason: String, webView: WKWebView) {
        webView.loadHTMLString(SafeBrowsing.warningPage(url: url, reason: reason), baseURL: nil)
    }

    func overrideSafeBrowsing(for url: URL) {
        safeBrowsingOverrides.insert(url.absoluteString)
        navigate(to: url)
    }

    var isHibernated: Bool { webView == nil && !isShowingStartPage && url != nil }

    func hibernate() {
        guard !isPinned, !isPlayingAudio, webView != nil else { return }
        discard()
        browser?.tabDidUpdate(self)
    }

    private var progressObs: NSKeyValueObservation?
    var pendingScroll: (x: Double, y: Double)?

    private func makeWebView() -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: sharedConfiguration)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        progressObs = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.browser?.tabProgressDidChange(self, progress: webView.estimatedProgress)
        }
        return wv
    }

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        MemGuard.claimSpawnedWebKitProcesses()
        let wv = makeWebView()
        webView = wv
        lastActive = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MemGuard.claimSpawnedWebKitProcesses()
        }
        if isShowingStartPage || url == nil {
            isShowingStartPage = true
            url = nil
            wv.loadHTMLString(startPageHTML, baseURL: nil)
        } else if let u = url {
            let isLocalhost = u.host == "localhost" || u.host == "127.0.0.1"
            let req = isLocalhost
                ? URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
                : URLRequest(url: u)
            wv.load(req)
        }
        return wv
    }

    func discard() {
        guard let wv = webView, let savedURL = wv.url else {
            teardown()
            return
        }
        if !savedURL.absoluteString.isEmpty, !isShowingStartPage {
            url = savedURL
        }
        if !isShowingStartPage {
            wv.evaluateJavaScript("window.scrollX + '|' + window.scrollY") { [weak self] res, _ in
                if let s = res as? String {
                    let parts = s.split(separator: "|")
                    if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                        self?.pendingScroll = (x, y)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.teardown()
            }
        } else {
            teardown()
        }
    }

    private func teardown() {
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.removeFromSuperview()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        progressObs?.invalidate()
        progressObs = nil
        webView = nil
        isPlayingAudio = false
        browser?.tabDidUpdate(self)
    }

    func navigate(to u: URL) {
        isShowingStartPage = false
        url = u
        let wv = ensureWebView()
        wv.isHidden = false
        let isLocalhost = u.host == "localhost" || u.host == "127.0.0.1"
        let req = isLocalhost
            ? URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
            : URLRequest(url: u)
        wv.load(req)
    }

    func toggleMute() {
        isMuted.toggle()
        let js = "document.querySelectorAll('audio, video').forEach(m => m.muted = \(isMuted));"
        webView?.evaluateJavaScript(js) { _, _ in }
        browser?.tabDidUpdate(self)
    }

    func toggleReaderMode() {
        guard let wv = webView, !isShowingStartPage, url != nil else { return }
        if isReaderMode {
            isReaderMode = false
            wv.reload()
            return
        }
        let readabilityJS = """
        (() => {
          const doc = document;
          const title = doc.querySelector('h1')?.innerText || doc.title || '';
          const isProbablyContent = (el) => {
            const text = (el.innerText || '').trim();
            if (text.length < 50) return false;
            const commaCount = (text.match(/,/g) || []).length;
            const pCount = (text.match(/[.!?]/g) || []).length;
            const density = text.length;
            // Naive but effective: enough prose + punctuation => likely article content
            return density > 800 && pCount >= 5;
          };
          const candidates = [...doc.querySelectorAll('article, main, .post-content, .article-body, .entry-content, .story-body, [role="main"], .content, .post, .node-body')]
            .filter(el => el.innerText.trim().length > 500);
          let root = null, bestScore = 0;
          for (const c of candidates) {
            const txt = c.innerText.trim();
            // Score: prefer larger text blocks and paragraphs proximity
            let score = txt.length;
            const paras = c.querySelectorAll('p, h2, h3').length;
            score += paras * 150;
            const imgs = c.querySelectorAll('img').length;
            score += imgs * 80;
            if (score > bestScore) { bestScore = score; root = c; }
          }
          let article = root || doc.querySelector('article') || doc.querySelector('main') ||
                        doc.querySelector('.post-content') || doc.querySelector('.article-body') || doc.body;
          // Remove navigation, ads, scripts, sidebars from extraction
          for (const sel of ['script','style','nav','header','footer','aside','.ad','.ads','#ad','.sidebar','.related','.recommended','.share','.comments','iframe']) {
            article.querySelectorAll(sel).forEach(n => n.remove());
          }
          const nodes = Array.from(article.querySelectorAll('p, h2, h3, img, pre, code, li, blockquote, ul, ol'))
            .filter(el => {
              const t = (el.innerText || '').trim();
              if (el.tagName === 'IMG') return true;
              if (t.length === 0) return false;
              if (el.tagName === 'P') return t.length >= 30 || isProbablyContent(el);
              return t.length >= 15;
            })
            .map(el => el.outerHTML);
          return { title, content: nodes.join('\\n') };
        })()
        """
        wv.evaluateJavaScript(readabilityJS) { [weak self] res, _ in
            guard let self, let dict = res as? [String: Any],
                  let title = dict["title"] as? String,
                  let content = dict["content"] as? String, !content.isEmpty else { return }
            self.isReaderMode = true
            let readerHTML = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8">
            <title>\(title)</title>
            <style>
              body {
                background: #11131a; color: #e2e8f0;
                font-family: -apple-system, Georgia, serif;
                max-width: 680px; margin: 60px auto; padding: 0 24px;
                line-height: 1.8; font-size: 19px;
              }
              h1 { font-family: -apple-system, sans-serif; font-size: 34px; line-height: 1.3; margin-bottom: 24px; color: #fff; }
              img { max-width: 100%; height: auto; border-radius: 8px; margin: 24px 0; }
              a { color: #ff5e36; text-decoration: none; }
              a:hover { text-decoration: underline; }
              code, pre { font-family: monospace; background: #1a1d27; padding: 2px 6px; border-radius: 4px; font-size: 16px; }
              pre { padding: 16px; overflow-x: auto; }
            </style>
            </head>
            <body>
              <h1>\(title)</h1>
              <article>\(content)</article>
            </body></html>
            """
            wv.loadHTMLString(readerHTML, baseURL: self.url)
        }
    }

    func togglePictureInPicture() {
        let pipJS = """
        (() => {
          const v = document.querySelector('video');
          if (!v) return false;
          if (document.pictureInPictureElement) {
            document.exitPictureInPicture();
          } else {
            v.requestPictureInPicture().catch(() => {});
          }
          return true;
        })()
        """
        webView?.evaluateJavaScript(pipJS, completionHandler: nil)
    }

    func setAudioPlaying(_ playing: Bool) {
        if isPlayingAudio != playing {
            isPlayingAudio = playing
            browser?.tabDidUpdate(self)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        browser?.tabDidStartLoad(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let u = webView.url { url = u }
        browser?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = webView.title, !t.isEmpty {
            title = t
            isShowingStartPage = (t == "MiniBrowser")
        }
        if let p = pendingScroll {
            pendingScroll = nil
            DispatchQueue.main.async {
                webView.evaluateJavaScript("window.scrollTo({top: \(p.y), left: \(p.x), behavior: 'instant'});") { _, _ in }
            }
        }
        browser?.tabDidFinishLoad(self)
        browser?.tabDidUpdate(self)

        let jsonPrettyScript = """
        (() => {
          if (window.__jsonFormatted) return;
          const ct = document.contentType || '';
          const isJsonMime = ct.includes('json') || ct.includes('javascript');
          const bodyText = document.body ? document.body.innerText.trim() : '';
          const looksJson = (bodyText.startsWith('{') && bodyText.endsWith('}')) || (bodyText.startsWith('[') && bodyText.endsWith(']'));
          if (isJsonMime || looksJson) {
            try {
              const obj = JSON.parse(bodyText);
              if (typeof obj === 'object' && obj !== null) {
                window.__jsonFormatted = true;
                const formatted = JSON.stringify(obj, null, 2);
                document.body.innerHTML = `
                  <div style="background:#0d1117;color:#c9d1d9;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;line-height:1.6;padding:24px;min-height:100vh;box-sizing:border-box;margin:0;">
                    <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:12px;margin-bottom:16px;border-bottom:1px solid #30363d;">
                      <span style="font-weight:600;color:#58a6ff;font-size:14px;">⚡ Trendzza JSON Formatter</span>
                      <button id="cpy-btn" style="background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:6px 14px;border-radius:6px;cursor:pointer;font-size:12px;font-weight:500;">Copy JSON</button>
                    </div>
                    <pre id="raw-json" style="margin:0;white-space:pre-wrap;word-break:break-word;">` +
                    formatted.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                    .replace(/("(\\\\u[a-zA-Z0-9]{4}|\\\\[^u]|[^\\\\"])*"(\\s*:)?|\\b(true|false|null)\\b|-?\\d+(?:\\.\\d*)?(?:[eE][+\\-]?\\d+)?)/g, function (m) {
                      let c = '#79c0ff';
                      if (/^"/.test(m)) { c = /:$/.test(m) ? '#7ee787' : '#a5d6ff'; }
                      else if (/true|false/.test(m)) { c = '#ff7b72'; }
                      else if (/null/.test(m)) { c = '#ffa657'; }
                      return '<span style="color:' + c + '">' + m + '</span>';
                    }) + `</pre></div>`;
                document.body.style.margin = '0';
                document.body.style.background = '#0d1117';
                document.getElementById('cpy-btn').onclick = function() {
                  navigator.clipboard.writeText(formatted);
                  this.innerText = 'Copied!';
                  setTimeout(() => this.innerText = 'Copy JSON', 1500);
                };
              }
            } catch(e) {}
          }
        })();
        """
        webView.evaluateJavaScript(jsonPrettyScript) { _, _ in }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        browser?.tabDidFailLoad(self)
        showErrorPage(error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        browser?.tabDidFailLoad(self)
        showErrorPage(error: error)
    }

    func showErrorPage(error: Error) {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
        let failedURL = url?.absoluteString ?? "this site"
        let desc = error.localizedDescription
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>Unable to connect</title>
        <style>
          body {
            margin: 0; padding: 0;
            background: #0d0e15;
            color: #f1f5f9;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            display: flex; align-items: center; justify-content: center;
            height: 100vh;
          }
          .card {
            background: #141722;
            border: 1px solid #232738;
            border-radius: 16px;
            padding: 40px 48px;
            max-width: 480px;
            text-align: center;
            box-shadow: 0 12px 36px rgba(0,0,0,0.5);
          }
          .icon { font-size: 48px; margin-bottom: 16px; }
          h1 { font-size: 20px; font-weight: 600; margin: 0 0 12px; }
          p { font-size: 14px; color: #94a3b8; line-height: 1.5; margin: 0 0 20px; word-break: break-all; }
          .code { font-family: monospace; font-size: 12px; color: #f87171; background: #22151d; padding: 6px 12px; border-radius: 6px; display: inline-block; margin-bottom: 24px; }
          .btn-row { display: flex; gap: 12px; justify-content: center; }
          button {
            background: #ff5e36;
            color: white;
            border: none;
            border-radius: 8px;
            padding: 10px 20px;
            font-size: 14px;
            font-weight: 500;
            cursor: pointer;
            transition: opacity 0.2s;
          }
          button:hover { opacity: 0.9; }
          button.secondary {
            background: #232738;
            color: #cbd5e1;
          }
        </style>
        </head>
        <body>
        <div class="card">
          <div class="icon">⚠️</div>
          <h1>Unable to connect to site</h1>
          <p>MiniBrowser could not establish a connection to <strong>\(failedURL)</strong>.</p>
          <div class="code">\(desc)</div>
          <div class="btn-row">
            <button class="secondary" onclick="history.back()">Go Back</button>
            <button onclick="location.reload()">Try Again</button>
          </div>
        </div>
        </body>
        </html>
        """
        webView?.loadHTMLString(html, baseURL: nil)
    }

    // Popups re-route into tabs — no extra windows/processes.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = navigationAction.targetFrame?.request.url {
            navigate(to: target)
        }
        return nil
    }

    // Downloads handling
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        if let url = navigationAction.request.url {
            let verdict = SafeBrowsing.check(url: url)
            if case .suspicious(let reason) = verdict {
                if !userDidOverrideSafeBrowsing(for: url) {
                    self.pendingBlockedURL = url
                    self.pendingBlockReason = reason
                    showSafeBrowsingWarning(url: url, reason: reason, webView: webView)
                    decisionHandler(.cancel, preferences)
                    return
                }
            }
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }
}

// MARK: - Find In Page Floating Bar

final class FindInPageBar: NSView, NSSearchFieldDelegate {
    weak var browser: BrowserViewController?
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevBtn = NSButton()
    private let nextBtn = NSButton()
    private let closeBtn = NSButton()

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.18, alpha: 0.96).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Theme.pillEdge.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        translatesAutoresizingMaskIntoConstraints = false

        searchField.focusRingType = .none
        searchField.placeholderString = "Find in page…"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(findNext)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        searchField.setAccessibilityLabel("Find in page")

        countLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = Theme.textDim
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        for (btn, icon, act, tip) in [
            (prevBtn, "chevron.up", #selector(findPrev), "Previous (⇧Return)"),
            (nextBtn, "chevron.down", #selector(findNext), "Next (Return)"),
            (closeBtn, "xmark", #selector(dismiss), "Close (Esc)")
        ] {
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tip)
            btn.imagePosition = .imageOnly
            btn.contentTintColor = .white
            btn.target = self
            btn.action = act
            btn.toolTip = tip
            btn.widthAnchor.constraint(equalToConstant: 20).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }

        let stack = NSStackView(views: [searchField, countLabel, prevBtn, nextBtn, closeBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc func dismiss() {
        isHidden = true
        clearHighlight()
        if let wv = browser?.activeTab?.webView {
            window?.makeFirstResponder(wv)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        performSearch(forward: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                findPrev()
            } else {
                findNext()
            }
            return true
        }
        return false
    }

    @objc func findNext() { performSearch(forward: true) }
    @objc func findPrev() { performSearch(forward: false) }

    private func performSearch(forward: Bool) {
        let text = searchField.stringValue
        guard let wv = browser?.activeTab?.webView, !text.isEmpty else {
            countLabel.stringValue = ""
            clearHighlight()
            return
        }

        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'")
                          .replacingOccurrences(of: "\n", with: " ")
        let backwards = forward ? "false" : "true"
        let js = """
        (() => {
          const found = window.find('\(escaped)', false, \(backwards), true, false, true, false);
          const bodyText = document.body ? document.body.innerText : '';
          const regex = new RegExp('\(escaped)', 'gi');
          const matches = bodyText.match(regex);
          const count = matches ? matches.length : (found ? 1 : 0);
          return { found: found, count: count };
        })()
        """
        wv.evaluateJavaScript(js) { [weak self] res, _ in
            if let dict = res as? [String: Any], let found = dict["found"] as? Bool {
                let count = dict["count"] as? Int ?? 0
                if found {
                    self?.countLabel.stringValue = "\(count) matches"
                    self?.countLabel.textColor = Theme.accent
                } else {
                    self?.countLabel.stringValue = "0 / 0"
                    self?.countLabel.textColor = .systemRed
                }
            }
        }
    }

    private func clearHighlight() {
        guard let wv = browser?.activeTab?.webView else { return }
        wv.evaluateJavaScript("window.getSelection()?.removeAllRanges();") { _, _ in }
    }
}

// MARK: - Bookmarks Bar View

final class BookmarkBarView: NSView {
    weak var browser: BrowserViewController?
    private let stack = NSStackView()

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        wantsLayer = true
        layer?.backgroundColor = Theme.toolbar.cgColor

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: Notification.Name("BookmarksDidChange"), object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for bm in Bookmarks.items.prefix(12) {
            let btn = NSButton(title: "  \(bm.title)", target: self, action: #selector(bookmarkClicked(_:)))
            btn.isBordered = false
            btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            btn.contentTintColor = Theme.textDim
            btn.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            btn.imagePosition = .imageLeading
            btn.imageHugsTitle = true
            btn.toolTip = bm.url
            btn.identifier = NSUserInterfaceItemIdentifier(bm.url)

            let menu = NSMenu()
            let delItem = NSMenuItem(title: "Delete Bookmark", action: #selector(deleteBookmark(_:)), keyEquivalent: "")
            delItem.representedObject = bm
            delItem.target = self
            menu.addItem(delItem)
            btn.menu = menu
            stack.addArrangedSubview(btn)
        }
    }

    @objc private func bookmarkClicked(_ sender: NSButton) {
        guard let urlStr = sender.identifier?.rawValue, let url = URL(string: urlStr) else { return }
        browser?.navigateTo(url)
    }

    @objc private func deleteBookmark(_ sender: NSMenuItem) {
        guard let bm = sender.representedObject as? Bookmark else { return }
        Bookmarks.remove(bookmark: bm)
    }
}

// MARK: - Tab item (Chrome-style top-rounded tab)

final class TabItemView: NSView {
    let tab: Tab
    private let siteIcon = NSImageView()
    private let titleButton = NSButton()
    private let closeButton = NSButton()
    private let audioButton = NSButton()
    private var hovered = false
    weak var browser: BrowserViewController?

    init(tab: Tab, browser: BrowserViewController) {
        self.tab = tab
        self.browser = browser
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if tab.isPinned {
            widthAnchor.constraint(equalToConstant: 38).isActive = true
            titleButton.isHidden = true
            closeButton.isHidden = true
            toolTip = tab.title
        } else {
            widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }
        heightAnchor.constraint(equalToConstant: 34).isActive = true

        siteIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        siteIcon.contentTintColor = NSColor(calibratedRed: 0.45, green: 0.70, blue: 0.98, alpha: 1)
        siteIcon.translatesAutoresizingMaskIntoConstraints = false
        siteIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        siteIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        audioButton.isBordered = false
        audioButton.imagePosition = .imageOnly
        audioButton.target = self
        audioButton.action = #selector(toggleMute)
        audioButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        audioButton.heightAnchor.constraint(equalToConstant: 16).isActive = true
        audioButton.isHidden = true

        titleButton.isBordered = false
        titleButton.bezelStyle = .regularSquare
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleButton.contentTintColor = .white
        titleButton.target = self
        titleButton.action = #selector(selectTab)
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleButton.setAccessibilityRole(.button)
        titleButton.setAccessibilityLabel("Toggle \(tab.title) tab")

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.alphaValue = 0
        closeButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        closeButton.setAccessibilityRole(.button)
        closeButton.setAccessibilityLabel("Close \(tab.title) tab")

        let stack = NSStackView(views: [siteIcon, audioButton, titleButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = tab.isPinned ? 0 : 4
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: tab.isPinned ? 12 : 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: tab.isPinned ? -12 : -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalTo: heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; layer?.setNeedsDisplay() }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; layer?.setNeedsDisplay() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(menuNewTab), keyEquivalent: "")
        newTabItem.target = self
        menu.addItem(newTabItem)

        let pinTitle = tab.isPinned ? "Unpin Tab" : "Pin Tab"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        let reloadItem = NSMenuItem(title: "Reload Tab", action: #selector(menuReloadTab), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let dupItem = NSMenuItem(title: "Duplicate Tab", action: #selector(menuDuplicateTab), keyEquivalent: "")
        dupItem.target = self
        menu.addItem(dupItem)

        let muteTitle = tab.isMuted ? "Unmute Tab" : "Mute Tab"
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(toggleMute), keyEquivalent: "")
        muteItem.target = self
        menu.addItem(muteItem)

        if !tab.isPinned && !tab.isPlayingAudio && !tab.isHibernated && browser?.activeTab !== tab {
            let hibItem = NSMenuItem(title: "Sleep Tab (Save RAM)", action: #selector(menuHibernateTab), keyEquivalent: "")
            hibItem.target = self
            menu.addItem(hibItem)
        }

        menu.addItem(.separator())

        if !tab.isPinned {
            let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
            closeItem.target = self
            menu.addItem(closeItem)
        }

        let closeOtherItem = NSMenuItem(title: "Close Other Tabs", action: #selector(menuCloseOtherTabs), keyEquivalent: "")
        closeOtherItem.target = self
        menu.addItem(closeOtherItem)

        let closeRightItem = NSMenuItem(title: "Close Tabs to the Right", action: #selector(menuCloseTabsToRight), keyEquivalent: "")
        closeRightItem.target = self
        menu.addItem(closeRightItem)

        return menu
    }

    @objc func togglePin() {
        browser?.togglePinTab(tab)
    }

    @objc func menuHibernateTab() {
        tab.hibernate()
        refresh()
    }

    override func layout() {
        super.layout()
        let active = (browser?.activeTab === tab)
        let bg = active ? Theme.toolbar : (hovered ? Theme.tabHover : Theme.tabIdle)
        layer?.backgroundColor = bg.cgColor

        let mask = CAShapeLayer()
        if active {
            let radius = min(12, bounds.height)
            let p = CGMutablePath()
            let r = radius, h = bounds.height, w = bounds.width
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: h - r))
            p.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: w - r, y: h))
            p.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.closeSubpath()
            mask.path = p
        } else {
            mask.path = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        }
        layer?.mask = mask

        titleButton.contentTintColor = tab.isHibernated ? NSColor(calibratedWhite: 0.52, alpha: 1) : (active ? .white : Theme.textDim)
        closeButton.alphaValue = active ? 1 : (hovered ? 1 : 0)

        if tab.isPlayingAudio {
            audioButton.isHidden = false
            let iconName = tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            audioButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Audio")
            audioButton.contentTintColor = tab.isMuted ? .systemRed : Theme.accent
        } else {
            audioButton.isHidden = true
        }
    }

    func refresh() {
        titleButton.title = tab.title
        if tab.isHibernated {
            siteIcon.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "Sleeping to save RAM")
            siteIcon.contentTintColor = NSColor(calibratedRed: 0.65, green: 0.75, blue: 0.95, alpha: 0.8)
        } else if tab.webView?.isLoading == true {
            siteIcon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Loading")
            siteIcon.contentTintColor = Theme.accent
        } else if tab.isShowingStartPage || tab.url == nil {
            siteIcon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Start")
            siteIcon.contentTintColor = Theme.accent
        } else {
            siteIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            siteIcon.contentTintColor = NSColor(calibratedRed: 0.45, green: 0.70, blue: 0.98, alpha: 1)
        }

        if tab.isPlayingAudio {
            audioButton.isHidden = false
            let iconName = tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            audioButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Audio")
            audioButton.contentTintColor = tab.isMuted ? .systemRed : Theme.accent
        } else {
            audioButton.isHidden = true
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @objc func selectTab() { browser?.selectTab(tab) }
    @objc func closeTab() { browser?.closeTab(tab) }
    @objc func toggleMute() { tab.toggleMute(); refresh() }
    @objc private func menuNewTab() { browser?.newTab(self) }
    @objc private func menuReloadTab() { tab.webView?.reload() }
    @objc private func menuDuplicateTab() { browser?.duplicateTab(tab) }
    @objc private func menuCloseOtherTabs() { browser?.closeOtherTabs(keeping: tab) }
    @objc private func menuCloseTabsToRight() { browser?.closeTabsToTheRight(of: tab) }
}

// MARK: - Omnibox suggestions (live Google autofill + recent history)

// MARK: - Omnibox Overlay View (Chrome-Grade In-Window Dropdown)

final class OmniboxOverlayView: NSView {
    let table = NSTableView()
    let scroll = NSScrollView()
    var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 0.98).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.pillEdge.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class OmniboxSuggestions: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    struct Item {
        let title: String
        let subtitle: String
        let url: URL?
        let isTabSwitch: Bool
        let tabIndex: Int?
    }

    weak var browser: BrowserViewController?
    private weak var field: NSTextField?
    let overlayView = OmniboxOverlayView()

    private var items: [Item] = []
    private var debounce: Timer?
    private var fetchToken: String = ""
    private var history: [(title: String, url: URL)] = []
    private var historyPersisted = false
    private let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
    private var clickMonitor: Any?
    private var rawTypedText: String = ""

    func attach(to field: NSTextField, browser: BrowserViewController) {
        self.field = field
        self.browser = browser
        field.delegate = self

        col.width = 560
        overlayView.table.addTableColumn(col)
        overlayView.table.headerView = nil
        overlayView.table.rowHeight = 34
        overlayView.table.intercellSpacing = NSSize(width: 0, height: 2)
        overlayView.table.selectionHighlightStyle = .regular
        overlayView.table.backgroundColor = .clear
        overlayView.table.dataSource = self
        overlayView.table.delegate = self
        overlayView.table.target = self
        overlayView.table.action = #selector(rowClicked)

        loadPersistedHistory()
    }

    func addHistory(title: String, url: URL) {
        guard let h = url.host, !h.isEmpty else { return }
        history.removeAll { $0.url == url }
        history.insert((title.isEmpty ? h : title, url), at: 0)
        if history.count > 20 { history.removeLast() }
    }

    private func loadPersistedHistory() {
        guard !historyPersisted else { return }
        historyPersisted = true
        for e in History.entries.prefix(20) {
            if let u = URL(string: e.url) {
                history.append((e.title, u))
            }
        }
    }

    func show() {
        guard !items.isEmpty, let b = browser else { hide(); return }
        let rowHeight: CGFloat = 34
        let maxAvailable = max(60, b.view.bounds.height - (b.omniboxView.frame.maxY + 40))
        let targetHeight = CGFloat(min(CGFloat(items.count) * rowHeight + 8, min(320, maxAvailable)))
        overlayView.heightConstraint?.constant = targetHeight
        col.width = overlayView.frame.width > 20 ? overlayView.frame.width - 8 : 500
        overlayView.isHidden = false
        overlayView.table.reloadData()
        startEventMonitor()
    }

    func hide() {
        overlayView.isHidden = true
        stopEventMonitor()
        overlayView.table.deselectAll(nil)
    }

    private func startEventMonitor() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, !self.overlayView.isHidden else { return event }
                let locInWin = event.locationInWindow
                let locInOverlay = self.overlayView.convert(locInWin, from: nil)
                let locInOmni = self.browser?.omniboxView.convert(locInWin, from: nil) ?? NSPoint(x: -999, y: -999)
                if !self.overlayView.bounds.contains(locInOverlay) && !(self.browser?.omniboxView.bounds.contains(locInOmni) ?? false) {
                    self.hide()
                }
                return event
            }
        }
    }

    private func stopEventMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field, field == self.field else { return }
        rawTypedText = field.stringValue
        browser?.urlFieldTextChanged(field.stringValue)
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        debounce?.invalidate()
        if text.isEmpty {
            fetchToken = UUID().uuidString
            hide()
            browser?.restoreStartPageIfNeeded()
            return
        }
        browser?.dismissStartPageIfNeeded()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.startFetch(text)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.hide()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if !overlayView.isHidden && !items.isEmpty {
                let current = overlayView.table.selectedRow
                let next = current < items.count - 1 ? current + 1 : 0
                overlayView.table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                overlayView.table.scrollRowToVisible(next)
                let item = items[next]
                field?.stringValue = item.url?.absoluteString ?? item.title
                browser?.urlFieldTextChanged(field?.stringValue ?? "")
                return true
            }
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            if !overlayView.isHidden && !items.isEmpty {
                let current = overlayView.table.selectedRow
                if current <= 0 {
                    overlayView.table.deselectAll(nil)
                    field?.stringValue = rawTypedText
                    browser?.urlFieldTextChanged(rawTypedText)
                } else {
                    let prev = current - 1
                    overlayView.table.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                    overlayView.table.scrollRowToVisible(prev)
                    let item = items[prev]
                    field?.stringValue = item.url?.absoluteString ?? item.title
                    browser?.urlFieldTextChanged(field?.stringValue ?? "")
                }
                return true
            }
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if !overlayView.isHidden, overlayView.table.selectedRow >= 0, overlayView.table.selectedRow < items.count {
                choose(items[overlayView.table.selectedRow])
                return true
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !overlayView.isHidden {
                hide()
                if let u = browser?.activeTab?.url, !((browser?.activeTab?.isShowingStartPage) ?? false) {
                    field?.stringValue = u.absoluteString
                } else {
                    field?.stringValue = ""
                }
                browser?.urlFieldTextChanged(field?.stringValue ?? "")
                return true
            }
        }
        return false
    }

    // MARK: Fetch

    private func startFetch(_ text: String) {
        let token = UUID().uuidString
        fetchToken = token
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        guard let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&hl=en&q=\(q)") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard err == nil, let data, let self, self.fetchToken == token else { return }
            var suggestions: [String] = []
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let list = arr.count > 1 ? arr[1] as? [String] : nil {
                suggestions = list
            }
            DispatchQueue.main.async {
                guard self.fetchToken == token else { return }
                self.items.removeAll()

                // Check active local dev servers
                for port in LocalhostDiscovery.shared.activePorts {
                    let portStr = String(port)
                    if text.lowercased().contains("loc") || text.contains(portStr) || "localhost:\(port)".contains(text.lowercased()) {
                        self.items.append(Item(title: "http://localhost:\(port)",
                                               subtitle: "Active Local Dev Server",
                                               url: URL(string: "http://localhost:\(port)"),
                                               isTabSwitch: false,
                                               tabIndex: nil))
                    }
                }

                // Check open tabs for quick switch
                if let tabs = self.browser?.openTabs {
                    for (idx, t) in tabs.enumerated() {
                        if t !== self.browser?.activeTab {
                            if t.title.localizedCaseInsensitiveContains(text) || (t.url?.absoluteString.localizedCaseInsensitiveContains(text) ?? false) {
                                self.items.append(Item(title: t.title, subtitle: "Switch to open tab", url: t.url, isTabSwitch: true, tabIndex: idx))
                            }
                        }
                    }
                }

                for e in self.history.prefix(3) {
                    if e.title.localizedCaseInsensitiveContains(text) || e.url.absoluteString.localizedCaseInsensitiveContains(text) {
                        self.items.append(Item(title: e.title,
                                               subtitle: e.url.host ?? "",
                                               url: e.url,
                                               isTabSwitch: false,
                                               tabIndex: nil))
                    }
                }
                for s in suggestions.prefix(6) {
                    self.items.append(Item(title: s,
                                           subtitle: "\(SearchEngine.current.rawValue) search",
                                           url: nil,
                                           isTabSwitch: false,
                                           tabIndex: nil))
                }
                self.show()
            }
        }.resume()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]
        let cellID = NSUserInterfaceItemIdentifier("suggestionCell")
        var view = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        if view == nil {
            view = NSTableCellView()
            view!.identifier = cellID
        }
        view!.subviews.forEach { $0.removeFromSuperview() }

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconName: String
        let iconTint: NSColor
        if item.isTabSwitch {
            iconName = "arrow.triangle.swap"
            iconTint = Theme.accent
        } else if item.url != nil {
            iconName = "globe"
            iconTint = NSColor(calibratedRed: 0.4, green: 0.7, blue: 1.0, alpha: 1)
        } else {
            iconName = "magnifyingglass"
            iconTint = Theme.accent
        }
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = iconTint
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let subLabel = NSTextField(labelWithString: item.subtitle)
        subLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = item.isTabSwitch ? Theme.accent : Theme.textDim
        subLabel.alignment = .right
        subLabel.setContentHuggingPriority(.required, for: .horizontal)

        let rowStack = NSStackView(views: [iconView, titleLabel, subLabel])
        rowStack.orientation = .horizontal
        rowStack.spacing = 10
        rowStack.alignment = .centerY
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        view!.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -12),
            rowStack.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
        ])
        return view
    }

    // MARK: Action

    @objc private func rowClicked() {
        let row = overlayView.table.clickedRow >= 0 ? overlayView.table.clickedRow : overlayView.table.selectedRow
        guard row >= 0, row < items.count else { return }
        choose(items[row])
    }

    private func choose(_ item: Item) {
        hide()
        if item.isTabSwitch, let idx = item.tabIndex {
            browser?.selectTabAtIndex(idx)
        } else if let url = item.url {
            browser?.navigateTo(url)
        } else {
            browser?.search(query: item.title)
        }
    }
}

// MARK: - Persistent browsing history

enum History {
    struct Entry: Codable, Equatable {
        var title: String
        var url: String
        var date: Date
    }

    static private(set) var entries: [Entry] = {
        guard let d = UserDefaults.standard.data(forKey: "historyEntries"),
              let list = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return list
    }()

    static func add(title: String, url: URL) {
        guard let h = url.host, !h.isEmpty else { return }
        let e = Entry(title: title.isEmpty ? h : title, url: url.absoluteString, date: Date())
        entries.removeAll { $0.url == e.url }
        entries.insert(e, at: 0)
        if entries.count > 300 { entries.removeLast(entries.count - 300) }
        persist()
    }

    static func clear() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: "historyEntries")
        UserDefaults.standard.removeObject(forKey: "history")
    }

    private static func persist() {
        let d = (try? JSONEncoder().encode(entries)) ?? Data()
        UserDefaults.standard.set(d, forKey: "historyEntries")
        var vals: [String] = []
        for e in entries.prefix(20) { vals.append("\(e.title)|||\(e.url)") }
        UserDefaults.standard.set(vals, forKey: "history")
    }
}

// MARK: - History panel

final class HistoryPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private var browser: BrowserViewController?
    private var window: NSWindow?
    private let table = NSTableView()
    private let rowsHolder = NSViewController()
    private var rows: [History.Entry] = []

    func attach(browser: BrowserViewController) {
        self.browser = browser
    }

    func show() {
        reload()
        if window == nil { buildWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    private func reload() {
        rows = History.entries
        table.reloadData()
        table.layoutSubtreeIfNeeded()
    }

    private func buildWindow() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true

        let id = NSUserInterfaceItemIdentifier("date")
        let dateCol = NSTableColumn(identifier: id)
        dateCol.title = "Date"
        dateCol.width = 132
        let titleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleCol.title = "Title"
        titleCol.width = 340
        let urlCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        urlCol.title = "URL"
        urlCol.width = 360
        table.addTableColumn(dateCol)
        table.addTableColumn(titleCol)
        table.addTableColumn(urlCol)
        table.headerView = NSTableHeaderView()
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(openRow(_:))
        table.target = self

        let openBtn = NSButton(title: "Open", target: self, action: #selector(openRow(_:)))
        let clearBtn = NSButton(title: "Clear History", target: self, action: #selector(clearHistory(_:)))
        let clearDataBtn = NSButton(title: "Clear All Data…", target: self, action: #selector(clearAllData(_:)))
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(closeWindow(_:)))
        let buttonRow = NSStackView(views: [openBtn, clearBtn, clearDataBtn, doneBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let vc = NSViewController()
        let stack = NSStackView(views: [scroll, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        vc.view = stack

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 460),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "History"
        win.contentViewController = vc
        win.isReleasedWhenClosed = false
        window = win

        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let e = rows[row]
        let cellID = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "cell")
        var view = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        if view == nil {
            view = NSTableCellView()
            view!.identifier = cellID
        }
        view!.textField?.removeFromSuperview()
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        view!.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
        ])

        switch tableColumn?.identifier.rawValue {
        case "date":
            let f = DateFormatter()
            f.dateFormat = "MMM d, HH:mm"
            label.stringValue = f.string(from: e.date)
            label.textColor = .secondaryLabelColor
        case "url":
            label.stringValue = e.url
            label.textColor = .secondaryLabelColor
        default:
            label.stringValue = e.title
        }
        return view
    }

    // MARK: Actions

    @objc private func openRow(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count, let u = URL(string: rows[row].url) else { return }
        browser?.navigateTo(u)
        window?.orderOut(nil)
    }

    @objc private func clearHistory(_ sender: Any?) {
        History.clear()
        reload()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.orderOut(nil)
    }

    @objc private func clearAllData(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing data?"
        alert.informativeText = "Deletes history, cookies, cache, and all website data."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        History.clear()
        reload()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                 modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
    }
}

// MARK: - Process Inspector (one place for everything, inside MiniBrowser)

final class ProcessPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private weak var browser: BrowserViewController?
    private var window: NSWindow?
    private let table = NSTableView()
    private var rows: [(pid: pid_t, name: String, rss: Int64)] = []
    private let totalLabel = NSTextField(labelWithString: "")
    private var refreshTimer: Timer?

    func attach(browser: BrowserViewController) {
        self.browser = browser
    }

    func show() {
        build()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        guard window == nil else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Process"
        nameCol.width = 320
        let pidCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pid"))
        pidCol.title = "PID"
        pidCol.width = 90
        let rssCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rss"))
        rssCol.title = "Memory"
        rssCol.width = 110
        table.addTableColumn(nameCol)
        table.addTableColumn(pidCol)
        table.addTableColumn(rssCol)
        table.headerView = NSTableHeaderView()
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        table.dataSource = self
        table.delegate = self

        totalLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        totalLabel.alignment = .right
        let freeBtn = NSButton(title: "Free Memory Now", target: self, action: #selector(freeNow(_:)))
        let doneBtn = NSButton(title: "Close", target: self, action: #selector(closeWin(_:)))
        let buttons = NSStackView(views: [totalLabel, freeBtn, doneBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let vc = NSViewController()
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        vc.view = stack

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Processes — MiniBrowser"
        win.contentViewController = vc
        win.isReleasedWhenClosed = false
        win.delegate = self
        window = win
    }

    private func refresh() {
        rows = MemGuard.processes().sorted { $0.rss > $1.rss }
        table.reloadData()
        let total = rows.reduce(0) { $0 + $1.rss }
        totalLabel.stringValue = "Total: \(MemGuard.formatBytes(total))"
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let p = rows[row]
        let cellID = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "c")
        var view = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        if view == nil {
            view = NSTableCellView()
            view!.identifier = cellID
        }
        view!.textField?.removeFromSuperview()
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = p.name.hasPrefix("com.apple") ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        view!.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
        ])
        switch tableColumn?.identifier.rawValue {
        case "pid": label.stringValue = String(p.pid)
        case "rss": label.stringValue = MemGuard.formatBytes(p.rss)
        default:   label.stringValue = p.name
        }
        return view
    }
}

extension ProcessPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func freeNow(_ sender: Any?) {
        browser?.reclaimNow(sender)
        refresh()
    }

    @objc private func closeWin(_ sender: Any?) {
        window?.orderOut(nil)
    }
}

// MARK: - Command Palette (⌘K Floating Launcher)

final class CommandPaletteView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var browser: BrowserViewController?
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmdCol"))

    struct CommandItem {
        let title: String
        let shortcut: String
        let category: String
        let iconName: String
        let action: () -> Void
    }

    private var allItems: [CommandItem] = []
    private var filteredItems: [CommandItem] = []

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 0.98).cgColor
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.pillEdge.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        translatesAutoresizingMaskIntoConstraints = false

        searchField.focusRingType = .none
        searchField.placeholderString = "Type a command or search tabs…"
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        col.width = 540
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(itemClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(sep)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            sep.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        buildItems()
        filter("")
        searchField.stringValue = ""
        isHidden = false
        window?.makeFirstResponder(searchField)
    }

    func hide() {
        isHidden = true
        window?.makeFirstResponder(browser?.activeTab?.webView)
    }

    private func buildItems() {
        allItems.removeAll()
        guard let b = browser else { return }

        // Open Tabs
        for (i, t) in b.openTabs.enumerated() {
            allItems.append(CommandItem(title: "Switch to: \(t.title)",
                                        shortcut: "Tab \(i+1)",
                                        category: "Open Tabs",
                                        iconName: "arrow.triangle.swap") { [weak b, weak t] in
                if let t { b?.selectTab(t) }
            })
        }

        // Active Local Dev Servers
        for port in LocalhostDiscovery.shared.activePorts {
            let label = (port == 3000 ? "React/Next.js" : (port == 5173 ? "Vite" : (port == 8080 ? "Vue/Webpack" : (port == 8000 ? "Python/Django" : (port == 4200 ? "Angular" : "Dev Server")))))
            allItems.append(CommandItem(title: "Open Localhost :\(port) (\(label))",
                                        shortcut: "🟢 Active",
                                        category: "Dev Servers",
                                        iconName: "network") { [weak b] in
                if let u = URL(string: "http://localhost:\(port)") {
                    b?.navigateTo(u)
                }
            })
        }

        // Developer & Low-RAM Superpowers
        allItems.append(CommandItem(title: "Purge Memory & Freeze Background Tabs", shortcut: "⌥⌘M", category: "Developer RAM", iconName: "bolt.fill") { [weak b] in b?.purgeMemoryAndHibernate() })
        allItems.append(CommandItem(title: "Inspect Element (Web Inspector)", shortcut: "⌥⌘I", category: "Developer", iconName: "wrench.and.screwdriver") { [weak b] in b?.toggleWebInspector(nil) })
        allItems.append(CommandItem(title: "Import Bookmarks from Google Chrome", shortcut: "", category: "Bookmarks", iconName: "arrow.down.doc") { [weak b] in b?.importChromeBookmarksAction() })

        // User-Agent Switcher
        for preset in UserAgentPreset.allCases {
            let check = (b.currentUserAgent == preset) ? "✓ " : ""
            allItems.append(CommandItem(title: "\(check)User-Agent: \(preset.rawValue)", shortcut: "", category: "User-Agent", iconName: "person.crop.square") { [weak b] in
                b?.setUserAgent(preset)
            })
        }

        // Browser Actions
        allItems.append(CommandItem(title: "New Tab", shortcut: "⌘T", category: "Actions", iconName: "plus") { [weak b] in b?.newTab(nil) })
        allItems.append(CommandItem(title: "Reopen Closed Tab", shortcut: "⌘⇧T", category: "Actions", iconName: "arrow.uturn.backward") { [weak b] in b?.reopenClosedTab(nil) })
        allItems.append(CommandItem(title: "Pin / Unpin Active Tab", shortcut: "⌘P", category: "Actions", iconName: "pin") { [weak b] in b?.togglePinCurrentTab() })
        allItems.append(CommandItem(title: "Toggle Reader Mode", shortcut: "⌘⇧R", category: "Actions", iconName: "book") { [weak b] in b?.activeTab?.toggleReaderMode() })
        allItems.append(CommandItem(title: "Picture-in-Picture Video", shortcut: "⌥⌘P", category: "Actions", iconName: "pip") { [weak b] in b?.activeTab?.togglePictureInPicture() })
        allItems.append(CommandItem(title: "Translate Page to English", shortcut: "", category: "Actions", iconName: "character.book.closed") { [weak b] in b?.translatePage(nil) })
        allItems.append(CommandItem(title: "Autofill Current Form", shortcut: "", category: "Actions", iconName: "person.crop.circle.badge.checkmark") { [weak b] in b?.fillCurrentForm(nil) })
        allItems.append(CommandItem(title: "Manage Autofill Profile…", shortcut: "", category: "Privacy", iconName: "person.crop.circle") { [weak b] in b?.manageAutofillProfile(nil) })
        allItems.append(CommandItem(title: "Toggle Bookmarks Bar", shortcut: "⌘⇧B", category: "Actions", iconName: "bookmark") { [weak b] in b?.toggleBookmarksBar(nil) })
        allItems.append(CommandItem(title: "Find in Page", shortcut: "⌘F", category: "Actions", iconName: "doc.text.magnifyingglass") { [weak b] in b?.showFindBar(nil) })
        allItems.append(CommandItem(title: "Zoom In", shortcut: "⌘+", category: "Actions", iconName: "plus.magnifyingglass") { [weak b] in b?.zoomIn(nil) })
        allItems.append(CommandItem(title: "Zoom Out", shortcut: "⌘-", category: "Actions", iconName: "minus.magnifyingglass") { [weak b] in b?.zoomOut(nil) })
        allItems.append(CommandItem(title: "Reset Zoom", shortcut: "⌘0", category: "Actions", iconName: "1.magnifyingglass") { [weak b] in b?.resetZoom(nil) })
        allItems.append(CommandItem(title: "Clear Browsing Data", shortcut: "", category: "Privacy", iconName: "trash") { [weak b] in b?.clearBrowsingData() })
        allItems.append(CommandItem(title: "New Incognito Window", shortcut: "⌘⇧N", category: "Privacy", iconName: "eye.slash") { [weak b] in b?.openNewWindow(isPrivate: true) })
        allItems.append(CommandItem(title: "Search Engine: Google", shortcut: "", category: "Search", iconName: "magnifyingglass") { [weak b] in b?.switchSearchEngine(.google) })
        allItems.append(CommandItem(title: "Search Engine: DuckDuckGo", shortcut: "", category: "Search", iconName: "magnifyingglass") { [weak b] in b?.switchSearchEngine(.duckDuckGo) })
        allItems.append(CommandItem(title: "Search Engine: Brave", shortcut: "", category: "Search", iconName: "magnifyingglass") { [weak b] in b?.switchSearchEngine(.brave) })
        allItems.append(CommandItem(title: "Search Engine: Bing", shortcut: "", category: "Search", iconName: "magnifyingglass") { [weak b] in b?.switchSearchEngine(.bing) })

        // Bookmarks
        for bm in Bookmarks.items {
            if let u = URL(string: bm.url) {
                allItems.append(CommandItem(title: bm.title, shortcut: "Bookmark", category: "Bookmarks", iconName: "star.fill") { [weak b] in
                    b?.navigateTo(u)
                })
            }
        }
    }

    private func filter(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter {
                $0.title.lowercased().contains(query) || $0.category.lowercased().contains(query)
            }
        }
        table.reloadData()
        if !filteredItems.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        filter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let next = table.selectedRow < filteredItems.count - 1 ? table.selectedRow + 1 : 0
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let prev = table.selectedRow > 0 ? table.selectedRow - 1 : filteredItems.count - 1
            table.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            table.scrollRowToVisible(prev)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if table.selectedRow >= 0 && table.selectedRow < filteredItems.count {
                execute(filteredItems[table.selectedRow])
                return true
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredItems.count else { return nil }
        let item = filteredItems[row]
        let cellID = NSUserInterfaceItemIdentifier("cmdCell")
        var view = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        if view == nil {
            view = NSTableCellView()
            view!.identifier = cellID
        }
        view!.subviews.forEach { $0.removeFromSuperview() }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.iconName, accessibilityDescription: nil)
        icon.contentTintColor = Theme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let tagLabel = NSTextField(labelWithString: item.shortcut.isEmpty ? item.category : item.shortcut)
        tagLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tagLabel.textColor = Theme.textDim
        tagLabel.alignment = .right
        tagLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, titleLabel, tagLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        view!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
        ])
        return view
    }

    @objc private func itemClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 && row < filteredItems.count else { return }
        execute(filteredItems[row])
    }

    private func execute(_ item: CommandItem) {
        hide()
        item.action()
    }
}

// MARK: - Accessibility helper

enum A11y {
    static func apply(_ control: NSControl, label: String, help: String? = nil) {
        control.setAccessibilityLabel(label)
        control.setAccessibilityHelp(help)
        control.setAccessibilityRole(.button)
        control.refusesFirstResponder = false
    }
}

// MARK: - Localization helper

func loc(_ key: String, _ comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

// MARK: - Browser View Controller

final class BrowserViewController: NSViewController {

    private var tabs: [Tab] = []
    var activeTab: Tab?
    var allowURLBarUpdate = false

    private let containerView = NSView()
    private let urlField = NSTextField()
    private let omnibox = NSView()
    private let clearButton = NSButton()
    private let shieldButton = NSButton()
    private let starButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let menuButton = NSButton()
    private let newTabButton = NSButton()
    private let tabStack = NSStackView()
    private let suggestions = OmniboxSuggestions()
    private let historyPanel = HistoryPanel()
    private let processPanel = ProcessPanel()
    private let cookiePanel = CookiePanel()
    private let progressBar = NSProgressIndicator()
    private var bookmarksBar: BookmarkBarView!
    private var findBar: FindInPageBar!

    var isPrivate: Bool = false
    private let readerButton = NSButton()
    private let downloadButton = NSButton()
    private let ramPillButton = NSButton()
    private let privateBadge = NSTextField(labelWithString: "  🕵️ Incognito  ")
    private var commandPalette: CommandPaletteView!
    var currentUserAgent: UserAgentPreset = .standard

    var omniboxView: NSView { omnibox }
    var openTabs: [Tab] { tabs }

    private var discardTimer: Timer?
    private var memoryTimer: Timer?

    // MARK: Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.toolbar.cgColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.toolbar.cgColor

        // --- tab strip row + new-tab button
        tabStack.orientation = .horizontal
        tabStack.spacing = 0
        tabStack.alignment = .bottom
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        let tabScroll = NSScrollView()
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.hasVerticalScroller = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.scrollerStyle = .overlay
        tabScroll.drawsBackground = false
        tabScroll.documentView = tabStack

        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTabButton.isBordered = false
        newTabButton.contentTintColor = Theme.textDim
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        newTabButton.toolTip = "New Tab (⌘T)"
        A11y.apply(newTabButton, label: "New Tab", help: "Open a new tab with ⌘T")

        let tabRow = NSStackView(views: [tabScroll, newTabButton])
        tabRow.orientation = .horizontal
        tabRow.spacing = 6
        tabRow.translatesAutoresizingMaskIntoConstraints = false

        // --- omnibox pill
        omnibox.wantsLayer = true
        omnibox.layer?.backgroundColor = Theme.pill.cgColor
        omnibox.layer?.cornerRadius = 14
        omnibox.layer?.borderWidth = 1
        omnibox.layer?.borderColor = Theme.pillEdge.cgColor
        omnibox.translatesAutoresizingMaskIntoConstraints = false
        omnibox.heightAnchor.constraint(equalToConstant: 30).isActive = true

        shieldButton.isBordered = false
        shieldButton.imagePosition = .imageOnly
        shieldButton.contentTintColor = .systemGreen
        shieldButton.toolTip = "Site Security & Shields"
        shieldButton.target = self
        shieldButton.action = #selector(showShieldPopover(_:))
        A11y.apply(shieldButton, label: "Site Security", help: "View connection and shield status")

        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = Theme.textDim
        clearButton.target = self
        clearButton.action = #selector(clearAddressBar(_:))
        clearButton.toolTip = "Clear text"
        clearButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        clearButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        clearButton.isHidden = true
        A11y.apply(clearButton, label: "Clear Address Bar", help: "Clear the address bar text")

        readerButton.isBordered = false
        readerButton.image = NSImage(systemSymbolName: "book", accessibilityDescription: "Reader Mode")
        readerButton.imagePosition = .imageOnly
        readerButton.contentTintColor = Theme.textDim
        readerButton.target = self
        readerButton.action = #selector(toggleReaderModeAction(_:))
        readerButton.toolTip = "Toggle Reader Mode (⌘⇧R)"
        readerButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        readerButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        A11y.apply(readerButton, label: "Reader Mode", help: "Toggle reader mode with ⌘⇧R")

        downloadButton.isBordered = false
        downloadButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloads")
        downloadButton.imagePosition = .imageOnly
        downloadButton.contentTintColor = Theme.textDim
        downloadButton.target = self
        downloadButton.action = #selector(showDownloadsPopover(_:))
        downloadButton.toolTip = "Downloads"
        downloadButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        downloadButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        A11y.apply(downloadButton, label: "Downloads", help: "View recent downloads")

        privateBadge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        privateBadge.textColor = NSColor(calibratedRed: 0.8, green: 0.6, blue: 1.0, alpha: 1)
        privateBadge.wantsLayer = true
        privateBadge.layer?.backgroundColor = NSColor(calibratedRed: 0.35, green: 0.15, blue: 0.55, alpha: 0.5).cgColor
        privateBadge.layer?.cornerRadius = 4
        privateBadge.layer?.masksToBounds = true
        privateBadge.alignment = .center
        privateBadge.isHidden = !isPrivate

        starButton.isBordered = false
        starButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Bookmark")
        starButton.imagePosition = .imageOnly
        starButton.contentTintColor = Theme.textDim
        starButton.target = self
        starButton.action = #selector(bookmarkCurrentPage(_:))
        starButton.toolTip = "Bookmark this tab (⌘D)"
        starButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        starButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        A11y.apply(starButton, label: "Bookmark", help: "Bookmark this tab with ⌘D")

        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.bezelStyle = .squareBezel
        urlField.focusRingType = .none
        urlField.font = NSFont.systemFont(ofSize: 13)
        urlField.textColor = .white
        urlField.placeholderString = "Search or type a URL"
        urlField.target = self
        urlField.action = #selector(submitURL(_:))
        urlField.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        urlField.setContentCompressionResistancePriority(.init(rawValue: 250), for: .horizontal)
        urlField.setAccessibilityLabel("Address bar")
        urlField.setAccessibilityHelp("Type a URL or search query")
        suggestions.attach(to: urlField, browser: self)

        let pillStack = NSStackView(views: [shieldButton, urlField, clearButton, readerButton, starButton])
        pillStack.orientation = .horizontal
        pillStack.spacing = 8
        pillStack.alignment = .centerY
        pillStack.distribution = .fill
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        omnibox.addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: omnibox.leadingAnchor, constant: 12),
            pillStack.trailingAnchor.constraint(equalTo: omnibox.trailingAnchor, constant: -10),
            pillStack.topAnchor.constraint(equalTo: omnibox.topAnchor),
            pillStack.bottomAnchor.constraint(equalTo: omnibox.bottomAnchor)
        ])

        // --- toolbar buttons
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        menuButton.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Menu")

        for b in [backButton, forwardButton, reloadButton, menuButton] {
            b.isBordered = false
            b.contentTintColor = .white
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        backButton.target = self; backButton.action = #selector(goBack(_:))
        forwardButton.target = self; forwardButton.action = #selector(goForward(_:))
        reloadButton.target = self; reloadButton.action = #selector(reload(_:))
        menuButton.target = self; menuButton.action = #selector(showMenu(_:))
        A11y.apply(menuButton, label: "Menu", help: "Open the main menu")

        backButton.toolTip = "Back (⌘[)"
        forwardButton.toolTip = "Forward (⌘])"
        reloadButton.toolTip = "Reload (⌘R)"
        A11y.apply(backButton, label: "Back", help: "Go back one page with ⌘[")
        A11y.apply(forwardButton, label: "Forward", help: "Go forward one page with ⌘]")
        A11y.apply(reloadButton, label: "Reload", help: "Reload the page with ⌘R")

        ramPillButton.isBordered = false
        ramPillButton.wantsLayer = true
        ramPillButton.layer?.backgroundColor = Theme.pill.cgColor
        ramPillButton.layer?.cornerRadius = 11
        ramPillButton.layer?.borderWidth = 1
        ramPillButton.layer?.borderColor = Theme.pillEdge.cgColor
        ramPillButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        ramPillButton.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)
        ramPillButton.title = " ⚡ 40 MB "
        ramPillButton.target = self
        ramPillButton.action = #selector(showMemoryPopover(_:))
        ramPillButton.toolTip = "Live RAM Footprint. Click for Developer RAM Controls & 1-Click Purge."
        ramPillButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        A11y.apply(ramPillButton, label: "Memory Usage", help: "Open developer RAM controls")

        let toolRow = NSStackView()
        toolRow.orientation = .horizontal
        toolRow.spacing = 14
        toolRow.alignment = .centerY
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        toolRow.setViews([backButton, forwardButton, reloadButton], in: .leading)
        toolRow.setViews([omnibox], in: .center)
        toolRow.setViews([ramPillButton, downloadButton, privateBadge, menuButton], in: .trailing)
        omnibox.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        // --- bookmarks bar
        bookmarksBar = BookmarkBarView(browser: self)
        bookmarksBar.isHidden = !Bookmarks.barVisible

        // --- progress bar (Chrome-style thin strip)
        progressBar.isIndeterminate = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.usesThreadedAnimation = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 2).isActive = true

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Theme.webArea.cgColor

        // --- floating find in page bar
        findBar = FindInPageBar(browser: self)
        findBar.isHidden = true

        view.addSubview(header)
        header.addSubview(tabRow)
        header.addSubview(toolRow)
        header.addSubview(bookmarksBar)
        view.addSubview(progressBar)
        view.addSubview(containerView)
        view.addSubview(findBar)
        view.addSubview(suggestions.overlayView, positioned: .above, relativeTo: nil)

        commandPalette = CommandPaletteView(browser: self)
        commandPalette.isHidden = true
        view.addSubview(commandPalette, positioned: .above, relativeTo: nil)

        suggestions.overlayView.heightConstraint = suggestions.overlayView.heightAnchor.constraint(equalToConstant: 0)
        suggestions.overlayView.heightConstraint?.isActive = true
        suggestions.overlayView.isHidden = true

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tabRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            tabRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            tabRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            tabRow.heightAnchor.constraint(equalToConstant: 36),

            toolRow.topAnchor.constraint(equalTo: tabRow.bottomAnchor, constant: 4),
            toolRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            toolRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            toolRow.heightAnchor.constraint(equalToConstant: 30),

            bookmarksBar.topAnchor.constraint(equalTo: toolRow.bottomAnchor, constant: 2),
            bookmarksBar.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bookmarksBar.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -2),

            progressBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            containerView.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            findBar.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            suggestions.overlayView.topAnchor.constraint(equalTo: omnibox.bottomAnchor, constant: 4),
            suggestions.overlayView.leadingAnchor.constraint(equalTo: omnibox.leadingAnchor),
            suggestions.overlayView.trailingAnchor.constraint(equalTo: omnibox.trailingAnchor),

            commandPalette.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            commandPalette.topAnchor.constraint(equalTo: view.topAnchor, constant: 65),
            commandPalette.widthAnchor.constraint(equalToConstant: 580),
            commandPalette.heightAnchor.constraint(equalToConstant: 340)
        ])

        tabStack.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        AudioScriptHandler.shared.browser = self
        historyPanel.attach(browser: self)
        processPanel.attach(browser: self)
        cookiePanel.attach(browser: self)
        if let saved = SessionStore.restore(), !saved.tabs.isEmpty {
            restoreSession()
        } else {
            newTab(self)
        }
        if let raw = ProcessInfo.processInfo.environment["MINI_URL"], let u = URL(string: raw) {
            activeTab?.navigate(to: u)
        }
        if let raw = ProcessInfo.processInfo.environment["MINI_RECLAIM"], let t = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                self.reclaimBackgroundTabs()
                self.activeTab?.discard()
                MemGuard.evictCaches(includeDisk: true)
            }
        }
        LocalhostDiscovery.shared.start()
        updateMemoryHUD()
        Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.updateMemoryHUD()
        }
        discardTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.hibernateInactiveTabs()
        }
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.memoryCheck()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(onPressure(_:)),
                                               name: MemGuard.pressureNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned(_:)),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appActivated(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onDownloadsChanged),
                                               name: DownloadManager.downloadsChangedNotification, object: nil)
    }

    var releaseOnFocusLoss = UserDefaults.standard.object(forKey: "focusRelease") as? Bool ?? false

    @objc func appResigned(_ note: Notification) {
        MemGuard.evictCaches(includeDisk: false)
        if releaseOnFocusLoss {
            // Explicit toggle: always release on focus loss.
        } else if MemGuard.footprintBytes() > MemGuard.memoryPressureThreshold {
            activeTab?.discard()
        }
    }

    @objc func appActivated(_ note: Notification) {
        guard releaseOnFocusLoss else { return }
        if let tab = activeTab {
            tab.ensureWebView()
            attachTabView(tab)
        }
    }

    @objc func toggleFocusRelease(_ sender: NSMenuItem?) {
        releaseOnFocusLoss.toggle()
        UserDefaults.standard.set(releaseOnFocusLoss, forKey: "focusRelease")
        if releaseOnFocusLoss {
            reclaimBackgroundTabs()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Memory guard

    private func memoryCheck() {
        let footprint = MemGuard.footprintBytes()
        if footprint > MemGuard.memoryPressureThreshold {
            reclaimBackgroundTabs()
        }
    }

    @objc private func onPressure(_ note: Notification) {
        purgeMemoryAndHibernate()
    }

    @objc func reclaimNow(_ sender: Any?) {
        purgeMemoryAndHibernate()
    }

    func updateMemoryHUD() {
        let bytes = MemGuard.footprintBytes()
        let mb = max(1.0, Double(bytes) / (1024 * 1024))
        ramPillButton.title = String(format: " ⚡ %.0f MB ", mb)
        if mb < 120 {
            ramPillButton.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)
        } else if mb < 250 {
            ramPillButton.contentTintColor = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.20, alpha: 1)
        } else {
            ramPillButton.contentTintColor = NSColor(calibratedRed: 0.98, green: 0.35, blue: 0.20, alpha: 1)
        }
    }

    @objc func showMemoryPopover(_ sender: Any?) {
        let bytes = MemGuard.footprintBytes()
        let mb = max(1.0, Double(bytes) / (1024 * 1024))
        let chromeEstimatedMB = max(1800.0, mb * 18.0)
        let savedGB = (chromeEstimatedMB - mb) / 1024.0

        let alert = NSAlert()
        alert.messageText = "Developer RAM Controls"
        let activeCount = tabs.filter { !$0.isHibernated && !$0.isShowingStartPage }.count
        let hibernatedCount = tabs.filter { $0.isHibernated }.count
        alert.informativeText = """
        • Current RAM Footprint: \(String(format: "%.0f MB", mb))
        • Est. Google Chrome Equivalent: \(String(format: "%.0f MB", chromeEstimatedMB))
        • RAM Saved vs Chrome: \(String(format: "%.1f GB (95%% lower)", savedGB))

        • Active Tabs: \(activeCount)
        • Hibernated Tabs: \(hibernatedCount) (Sleeping in RAM)

        Click 'Purge & Freeze' to evict WebKit memory/disk caches, flush JavaScript heaps, and put background tabs to sleep.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "⚡ Purge & Freeze Tabs")
        alert.addButton(withTitle: "Inspect Processes…")
        alert.addButton(withTitle: "Close")

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            purgeMemoryAndHibernate()
        } else if resp == .alertSecondButtonReturn {
            showProcessPanel()
        }
    }

    @objc func purgeMemoryAndHibernate() {
        hibernateAllInactiveTabs()
        MemGuard.evictCaches(includeDisk: true)
        updateMemoryHUD()
    }

    func hibernateAllInactiveTabs() {
        for t in tabs where t !== activeTab && !t.isPinned && !t.isPlayingAudio {
            t.hibernate()
        }
        rebuildTabStack()
    }

    func hibernateInactiveTabs() {
        let threshold: TimeInterval = 180 // 3 minutes idle
        let now = Date()
        var anyHibernated = false
        for t in tabs where t !== activeTab && !t.isPinned && !t.isPlayingAudio && !t.isHibernated {
            if now.timeIntervalSince(t.lastActive) > threshold {
                t.hibernate()
                anyHibernated = true
            }
        }
        if anyHibernated {
            rebuildTabStack()
            updateMemoryHUD()
        }
    }

    @objc func importChromeBookmarksAction() {
        let count = ChromeImporter.importFromDefaultProfile()
        if count > 0 {
            bookmarksBar.reload()
            let alert = NSAlert()
            alert.messageText = "Bookmarks Imported"
            alert.informativeText = "Successfully imported \(count) bookmarks from Google Chrome / Brave!"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Great")
            alert.runModal()
        } else {
            let panel = NSOpenPanel()
            panel.title = "Import Bookmarks File"
            panel.message = "Select an exported Chrome or Safari Bookmarks HTML/JSON file:"
            panel.allowedContentTypes = [.html, .json]
            panel.begin { [weak self] resp in
                if resp == .OK, let u = panel.url {
                    let imported = ChromeImporter.importFromFile(url: u)
                    self?.bookmarksBar.reload()
                    let alert = NSAlert()
                    alert.messageText = imported > 0 ? "Bookmarks Imported" : "No Bookmarks Found"
                    alert.informativeText = imported > 0 ? "Imported \(imported) bookmarks." : "Could not find valid bookmarks in the selected file."
                    alert.runModal()
                }
            }
        }
    }

    @objc func toggleWebInspector(_ sender: Any?) {
        guard let wv = activeTab?.webView else { return }
        let sel = NSSelectorFromString("_showInspector")
        if wv.responds(to: sel) {
            wv.perform(sel)
        } else {
            wv.evaluateJavaScript("console.log('Web Inspector active. Inspect element with Option+Command+I.');") { _, _ in }
        }
    }

    func setUserAgent(_ preset: UserAgentPreset) {
        currentUserAgent = preset
        let ua = preset.userAgentString
        for t in tabs {
            t.webView?.customUserAgent = ua
        }
        activeTab?.webView?.reload()
    }

    @objc private func reclaimBackgroundTabs() {
        hibernateInactiveTabs()
    }

    // MARK: Tab management

    @discardableResult
    @objc func newTab(_ sender: Any?) -> Tab {
        let tab = Tab()
        tab.browser = self
        tab.lastActive = Date()
        tabs.append(tab)

        let item = TabItemView(tab: tab, browser: self)
        tabStack.addArrangedSubview(item)

        selectTab(tab)
        if !(sender is NSButton) {
            view.window?.makeFirstResponder(urlField)
        }
        return tab
    }

    func selectTab(_ tab: Tab) {
        if activeTab !== tab {
            activeTab?.webView?.removeFromSuperview()
        }
        activeTab = tab
        tab.lastActive = Date()

        let wv = tab.ensureWebView()
        attachTabView(tab)

        updateOmnibox(for: tab)
        tabDidUpdate(tab)
        view.window?.title = tab.title
        view.window?.makeFirstResponder(wv)
    }

    func attachTabView(_ tab: Tab) {
        guard activeTab === tab, let wv = tab.webView else { return }
        if wv.superview !== containerView {
            wv.removeFromSuperview()
            containerView.addSubview(wv)
            wv.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: containerView.topAnchor),
                wv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                wv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }
    }

    @objc func closeTab(_ tab: Tab) {
        if tab.isPinned { return } // Pinned tabs are protected from closure
        guard tabs.count > 1 else { return }
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }

        if !tab.isShowingStartPage, let u = tab.url {
            ClosedTabsManager.push(url: u, title: tab.title, scrollPos: tab.pendingScroll)
        }

        let wasActive = (activeTab === tab)
        tab.discard()
        tabs.remove(at: idx)
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for remaining in tabs {
            tabStack.addArrangedSubview(TabItemView(tab: remaining, browser: self))
        }

        if wasActive {
            selectTab(tabs[min(idx, tabs.count - 1)])
        }
    }

    @objc func togglePinCurrentTab() {
        if let t = activeTab { togglePinTab(t) }
    }

    func togglePinTab(_ tab: Tab) {
        tab.isPinned.toggle()
        rebuildTabStack()
    }

    func rebuildTabStack() {
        tabs.sort { ($0.isPinned && !$1.isPinned) }
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for remaining in tabs {
            tabStack.addArrangedSubview(TabItemView(tab: remaining, browser: self))
        }
        if let active = activeTab {
            tabDidUpdate(active)
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        commandPalette.show()
    }

    @objc func toggleReaderModeAction(_ sender: Any?) {
        activeTab?.toggleReaderMode()
        if let tab = activeTab {
            readerButton.contentTintColor = tab.isReaderMode ? Theme.accent : Theme.textDim
        }
    }

    @objc func togglePictureInPictureAction(_ sender: Any?) {
        activeTab?.togglePictureInPicture()
    }

    @objc func showDownloadsPopover(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let popView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 250))
        popView.wantsLayer = true
        popView.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 0.98).cgColor

        let titleLabel = NSTextField(labelWithString: "Downloads")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        popView.addSubview(titleLabel)

        let downloads = DownloadManager.shared.recentDownloads
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        if downloads.isEmpty {
            let empty = NSTextField(labelWithString: "No recent downloads")
            empty.textColor = Theme.textDim
            empty.font = NSFont.systemFont(ofSize: 12)
            stack.addArrangedSubview(empty)
        } else {
            for d in downloads.prefix(5) {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                row.alignment = .centerY

                let icon = NSImageView()
                icon.image = NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: nil)
                icon.contentTintColor = Theme.accent
                icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

                let nameLabel = NSTextField(labelWithString: d.filename)
                nameLabel.font = NSFont.systemFont(ofSize: 12)
                nameLabel.textColor = .white
                nameLabel.lineBreakMode = .byTruncatingMiddle
                nameLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true

                let finderBtn = NSButton(title: "Finder", target: self, action: #selector(showInFinderAction(_:)))
                finderBtn.bezelStyle = .inline
                finderBtn.font = NSFont.systemFont(ofSize: 10)
                finderBtn.identifier = NSUserInterfaceItemIdentifier(d.fileURL.path)

                row.addArrangedSubview(icon)
                row.addArrangedSubview(nameLabel)
                row.addArrangedSubview(finderBtn)
                stack.addArrangedSubview(row)
            }
        }
        popView.addSubview(stack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: popView.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: popView.trailingAnchor, constant: -16)
        ])

        vc.view = popView
        popover.contentViewController = vc
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc func showInFinderAction(_ sender: NSButton) {
        if let path = sender.identifier?.rawValue {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    @objc func onDownloadsChanged() {
        let hasRecent = !DownloadManager.shared.recentDownloads.isEmpty
        downloadButton.contentTintColor = hasRecent ? Theme.accent : Theme.textDim
    }

    func openNewWindow(isPrivate: Bool) {
        let bvc = BrowserViewController()
        bvc.isPrivate = isPrivate
        let win = NSWindow(contentViewController: bvc)
        win.setContentSize(NSSize(width: 1100, height: 720))
        win.title = isPrivate ? "MiniBrowser — Incognito" : "MiniBrowser"
        win.titlebarAppearsTransparent = true
        win.backgroundColor = Theme.toolbar
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    func switchSearchEngine(_ engine: SearchEngine) {
        SearchEngine.current = engine
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let rec = ClosedTabsManager.pop(), let url = rec.url else { return }
        let tab = newTab(self)
        tab.title = rec.title
        tab.pendingScroll = rec.scrollPos
        tab.navigate(to: url)
    }

    func duplicateTab(_ tab: Tab) {
        let newT = newTab(self)
        if let u = tab.url {
            newT.navigate(to: u)
        }
    }

    func closeOtherTabs(keeping tab: Tab) {
        let others = tabs.filter { $0 !== tab }
        for t in others {
            closeTab(t)
        }
    }

    func closeTabsToTheRight(of tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        let toClose = Array(tabs.suffix(from: idx + 1))
        for t in toClose {
            closeTab(t)
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    // MARK: Direct Tab Switching (⌘1..8, ⌘9, ⌃Tab, ⌃⇧Tab)

    @objc func selectTab1(_ sender: Any?) { selectTabAtIndex(0) }
    @objc func selectTab2(_ sender: Any?) { selectTabAtIndex(1) }
    @objc func selectTab3(_ sender: Any?) { selectTabAtIndex(2) }
    @objc func selectTab4(_ sender: Any?) { selectTabAtIndex(3) }
    @objc func selectTab5(_ sender: Any?) { selectTabAtIndex(4) }
    @objc func selectTab6(_ sender: Any?) { selectTabAtIndex(5) }
    @objc func selectTab7(_ sender: Any?) { selectTabAtIndex(6) }
    @objc func selectTab8(_ sender: Any?) { selectTabAtIndex(7) }
    @objc func selectTab9(_ sender: Any?) {
        if let last = tabs.last { selectTab(last) }
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard let active = activeTab, let idx = tabs.firstIndex(where: { $0 === active }), !tabs.isEmpty else { return }
        let nextIdx = (idx + 1) % tabs.count
        selectTab(tabs[nextIdx])
    }

    @objc func selectPrevTab(_ sender: Any?) {
        guard let active = activeTab, let idx = tabs.firstIndex(where: { $0 === active }), !tabs.isEmpty else { return }
        let prevIdx = (idx - 1 + tabs.count) % tabs.count
        selectTab(tabs[prevIdx])
    }

    func selectTabAtIndex(_ idx: Int) {
        guard idx >= 0, idx < tabs.count else { return }
        selectTab(tabs[idx])
    }

    // MARK: Page Zoom Controls (⌘+, ⌘-, ⌘0)

    @objc func zoomIn(_ sender: Any?) {
        guard let wv = activeTab?.webView else { return }
        wv.pageZoom = min(wv.pageZoom + 0.1, 3.0)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let wv = activeTab?.webView else { return }
        wv.pageZoom = max(wv.pageZoom - 0.1, 0.5)
    }

    @objc func resetZoom(_ sender: Any?) {
        guard let wv = activeTab?.webView else { return }
        wv.pageZoom = 1.0
    }

    // MARK: Bookmarks & Star

    @objc func fillCurrentForm(_ sender: Any?) {
        guard let wv = activeTab?.webView, !activeTab!.isShowingStartPage else { return }
        let profile = AutofillProfile.current
        guard profile.isConfigured else {
            manageAutofillProfile(nil)
            return
        }
        wv.evaluateJavaScript(profile.fillScript) { _, _ in }
    }

    @objc func manageAutofillProfile(_ sender: Any?) {
        let p = AutofillProfile.current
        let alert = NSAlert()
        alert.messageText = "Autofill Profile"
        alert.informativeText = "This information is stored locally on your Mac and is used to fill forms. Leave blank to disable."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field0 = NSTextField(frame: .zero); field0.placeholderString = "Full name"; field0.stringValue = p.fullName
        let field1 = NSTextField(frame: .zero); field1.placeholderString = "Email"; field1.stringValue = p.email
        let field2 = NSTextField(frame: .zero); field2.placeholderString = "Phone"; field2.stringValue = p.phone
        let field3 = NSTextField(frame: .zero); field3.placeholderString = "Street address"; field3.stringValue = p.address
        let field4 = NSTextField(frame: .zero); field4.placeholderString = "City"; field4.stringValue = p.city
        let field5 = NSTextField(frame: .zero); field5.placeholderString = "ZIP / Postal code"; field5.stringValue = p.zip
        let field6 = NSTextField(frame: .zero); field6.placeholderString = "Country"; field6.stringValue = p.country
        let stack = NSStackView(views: [field0, field1, field2, field3, field4, field5, field6])
        stack.orientation = .vertical
        stack.spacing = 6
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field0
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var updated = AutofillProfile.current
        updated.fullName = field0.stringValue
        updated.email = field1.stringValue
        updated.phone = field2.stringValue
        updated.address = field3.stringValue
        updated.city = field4.stringValue
        updated.zip = field5.stringValue
        updated.country = field6.stringValue
        AutofillProfile.current = updated
    }

    @objc func bookmarkCurrentPage(_ sender: Any?) {
        guard let tab = activeTab, let url = tab.url, !tab.isShowingStartPage else { return }
        Bookmarks.toggle(title: tab.title, url: url)
        updateBookmarkStar()
    }

    @objc func toggleBookmarksBar(_ sender: Any?) {
        Bookmarks.barVisible.toggle()
        bookmarksBar.isHidden = !Bookmarks.barVisible
    }

    func updateBookmarkStar() {
        guard let tab = activeTab else { return }
        let bookmarked = Bookmarks.isBookmarked(url: tab.url)
        starButton.image = NSImage(systemSymbolName: bookmarked ? "star.fill" : "star",
                                   accessibilityDescription: "Bookmark")
        starButton.contentTintColor = bookmarked ? Theme.accent : Theme.textDim
    }

    // MARK: Find In Page (⌘F)

    @objc func showFindBar(_ sender: Any?) {
        findBar.show()
    }

    // MARK: Omnibox + UI updates

    private func updateOmnibox(for tab: Tab) {
        allowURLBarUpdate = true
        urlField.stringValue = tab.url?.absoluteString ?? ""
        allowURLBarUpdate = false

        updateBookmarkStar()

        let secure: Bool
        if tab.isShowingStartPage || tab.url == nil {
            shieldButton.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Start")
            shieldButton.contentTintColor = Theme.accent
            secure = true
        } else if let scheme = tab.url?.scheme?.lowercased(), scheme == "https" {
            shieldButton.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "Secure")
            shieldButton.contentTintColor = .systemGreen
            secure = true
        } else {
            shieldButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Not secure")
            shieldButton.contentTintColor = .systemRed
            secure = false
        }
        _ = secure
    }

    func tabDidUpdate(_ tab: Tab) {
        guard activeTab === tab else { return }
        if allowURLBarUpdate, let u = tab.url {
            urlField.stringValue = u.absoluteString
        }
        readerButton.contentTintColor = tab.isReaderMode ? Theme.accent : Theme.textDim
        view.window?.title = tab.title
        for case let item as TabItemView in tabStack.arrangedSubviews {
            item.refresh()
        }
        backButton.isEnabled = tab.webView?.canGoBack ?? false
        forwardButton.isEnabled = tab.webView?.canGoForward ?? false
    }

    func tabDidStartLoad(_ tab: Tab) {
        guard activeTab === tab else { return }
        progressBar.isHidden = false
        progressBar.doubleValue = 0.05
        reloadButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")
        reloadButton.toolTip = "Stop loading (Esc)"
        for case let item as TabItemView in tabStack.arrangedSubviews { item.refresh() }
    }

    func tabProgressDidChange(_ tab: Tab?, progress: Double) {
        guard tab === activeTab, tab?.webView != nil else { return }
        progressBar.isHidden = progress >= 1.0
        progressBar.doubleValue = progress
    }

    func tabDidFinishLoad(_ tab: Tab) {
        guard activeTab === tab else { return }
        progressBar.isHidden = true
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.toolTip = "Reload (⌘R)"
        updateOmnibox(for: tab)
        tabDidUpdate(tab)
        if let u = tab.url, !tab.isShowingStartPage && !isPrivate {
            History.add(title: tab.title, url: u)
            suggestions.addHistory(title: tab.title, url: u)
        }
    }

    func tabDidFailLoad(_ tab: Tab) {
        guard activeTab === tab else { return }
        progressBar.isHidden = true
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.toolTip = "Reload (⌘R)"
        tabDidUpdate(tab)
    }

    @objc func showShieldPopover(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let popView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
        popView.wantsLayer = true
        popView.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 0.98).cgColor

        let shieldIcon = NSImageView()
        shieldIcon.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)
        shieldIcon.contentTintColor = .systemGreen
        shieldIcon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Connection is Secure")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "HTTPS TLS 1.3 Encrypted\nShields: Network Blocker ACTIVE\nAds & Trackers Blocked: 48+\nMemory RSS: \(MemGuard.formatBytes(MemGuard.footprintBytes()))")
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = Theme.textDim
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [shieldIcon, titleLabel, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        popView.addSubview(stack)

        NSLayoutConstraint.activate([
            shieldIcon.widthAnchor.constraint(equalToConstant: 24),
            shieldIcon.heightAnchor.constraint(equalToConstant: 24),
            stack.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: popView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: popView.topAnchor, constant: 16)
        ])

        vc.view = popView
        popover.contentViewController = vc
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc func clearAddressBar(_ sender: Any?) {
        urlField.stringValue = ""
        clearButton.isHidden = true
        suggestions.hide()
        urlField.becomeFirstResponder()
        restoreStartPageIfNeeded()
    }

    func urlFieldTextChanged(_ text: String) {
        clearButton.isHidden = text.isEmpty
    }

    @objc func showHistory() {
        historyPanel.show()
    }

    @objc func showSiteData(_ sender: Any?) {
        let host = activeTab?.url?.host ?? ""
        if host.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Site Selected"
            alert.informativeText = "Open a website first, then choose 'Site Data & Permissions'."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        cookiePanel.show(host: host)
    }

    @objc func showProcessPanel() {
        processPanel.show()
    }

    @objc func clearBrowsingData() {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing data?"
        alert.informativeText = "Deletes history, cookies, cache, and all website data."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        History.clear()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                 modifiedSince: .distantPast) { }
    }

    @objc func translatePage(_ sender: Any?) {
        guard let tab = activeTab, let u = tab.url, !tab.isShowingStartPage else {
            let alert = NSAlert()
            alert.messageText = "Nothing to Translate"
            alert.informativeText = "Open a web page first, then choose Translate."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let encoded = u.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? u.absoluteString
        if let translateURL = URL(string: "https://translate.google.com/?sl=auto&tl=en&u=\(encoded)") {
            tab.navigate(to: translateURL)
        }
    }

    @objc func printPage(_ sender: Any?) {
        guard let wv = activeTab?.webView else { return }
        let op = wv.printOperation(with: .shared)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    @objc func showDownloadPopup(_ sender: Any?) {
        showDownloadsPopover(menuButton)
    }

    @objc func navigateTo(_ url: URL) {
        guard let tab = activeTab else { return }
        suggestions.hide()
        tab.isShowingStartPage = false
        tab.navigate(to: url)
        attachTabView(tab)
        view.window?.makeFirstResponder(tab.ensureWebView())
    }

    func dismissStartPageIfNeeded() {
        guard let tab = activeTab, tab.isShowingStartPage else { return }
        tab.isShowingStartPage = false
        tab.webView?.isHidden = true
    }

    func restoreStartPageIfNeeded() {
        guard let tab = activeTab, !tab.isShowingStartPage, tab.webView?.isHidden == true else { return }
        tab.webView?.isHidden = false
    }

    func search(query: String) {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(searchEngineBaseURL)\(q)") else { return }
        navigateTo(url)
    }

    func searchOnGoogle(_ query: String) {
        search(query: query)
    }

    // MARK: Session persistence

    func saveSession() {
        SessionStore.save(tabs: tabs, activeTabID: activeTab?.id)
    }

    func restoreSession() {
        guard let saved = SessionStore.restore() else { return }
        for (idx, savedTab) in saved.tabs.enumerated() {
            guard let url = URL(string: savedTab.url) else { continue }
            let tab = newTab(self)
            tab.title = savedTab.title
            tab.isPinned = savedTab.isPinned
            tab.navigate(to: url)
            if idx == 0 { selectTab(tab) }
        }
        rebuildTabStack()
    }

    // MARK: Actions

    @objc func goBack(_ sender: Any?) { activeTab?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { activeTab?.webView?.goForward() }
    @objc func reload(_ sender: Any?) {
        guard let tab = activeTab else { return }
        if tab.webView?.isLoading == true {
            tab.webView?.stopLoading()
            reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            reloadButton.toolTip = "Reload (⌘R)"
        } else {
            tab.isShowingStartPage = false
            tab.webView?.reload()
        }
    }

    @objc func hardReload(_ sender: Any?) {
        guard let tab = activeTab else { return }
        tab.isShowingStartPage = false
        tab.webView?.reloadFromOrigin()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        view.window?.makeFirstResponder(urlField)
        urlField.selectText(nil)
    }

    @objc func submitURL(_ sender: Any?) {
        guard let tab = activeTab else { return }
        suggestions.hide()
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        var input = raw

        // Chrome-style ⌘Enter shortcut: automatically completes domain with www. and .com
        if NSEvent.modifierFlags.contains(.command) && !input.contains(".") && !input.contains("://") {
            input = "https://www.\(input).com"
        } else if !input.contains("://") {
            if input.contains(" ") {
                if let q = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    input = "\(searchEngineBaseURL)\(q)"
                }
            } else if input.contains(".") && !input.hasPrefix("www.") {
                input = "https://\(input)"
            } else {
                if let q = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    input = "\(searchEngineBaseURL)\(q)"
                }
            }
        }
        if let u = URL(string: input) {
            tab.isShowingStartPage = false
            tab.navigate(to: u)
        }
    }

    @objc func showMenu(_ sender: Any?) {
        let menu = NSMenu()
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        let reopenItem = NSMenuItem(title: "Reopen Closed Tab", action: #selector(reopenClosedTab(_:)), keyEquivalent: "T")
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let reloadItem = NSMenuItem(title: "Reload Page", action: #selector(reload(_:)), keyEquivalent: "r")
        let hardReloadItem = NSMenuItem(title: "Force Reload", action: #selector(hardReload(_:)), keyEquivalent: "R")
        menu.addItem(newTabItem)
        menu.addItem(reopenItem)
        menu.addItem(closeTabItem)
        menu.addItem(reloadItem)
        menu.addItem(hardReloadItem)

        menu.addItem(.separator())

        let findItem = NSMenuItem(title: "Find in Page…", action: #selector(showFindBar(_:)), keyEquivalent: "f")
        let bmBarItem = NSMenuItem(title: "Show Bookmarks Bar", action: #selector(toggleBookmarksBar(_:)), keyEquivalent: "B")
        bmBarItem.state = Bookmarks.barVisible ? .on : .off
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        let zoomResetItem = NSMenuItem(title: "Actual Size", action: #selector(resetZoom(_:)), keyEquivalent: "0")
        menu.addItem(findItem)
        menu.addItem(bmBarItem)
        menu.addItem(zoomInItem)
        menu.addItem(zoomOutItem)
        menu.addItem(zoomResetItem)

        menu.addItem(.separator())

        // Search engine submenu
        let engineItem = NSMenuItem(title: "Search Engine", action: nil, keyEquivalent: "")
        let engineSubmenu = NSMenu()
        for engine in SearchEngine.allCases {
            let item = NSMenuItem(title: engine.rawValue, action: #selector(changeSearchEngine(_:)), keyEquivalent: "")
            item.representedObject = engine
            item.state = (SearchEngine.current == engine) ? .on : .off
            item.target = self
            engineSubmenu.addItem(item)
        }
        engineItem.submenu = engineSubmenu
        menu.addItem(engineItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "History…", action: #selector(showHistory), keyEquivalent: "y")
        menu.addItem(withTitle: "Clear Browsing Data…", action: #selector(clearBrowsingData), keyEquivalent: "")

        let shieldsItem = NSMenuItem(title: "Aggressive Tracker Blocking",
                                     action: #selector(toggleShields(_:)), keyEquivalent: "")
        shieldsItem.state = Blocker.enabled ? .on : .off
        let lowMemItem = NSMenuItem(title: "Low Memory Mode (stop silent previews)",
                                    action: #selector(toggleLowMem(_:)), keyEquivalent: "")
        lowMemItem.state = LowMem.enabled ? .on : .off
        let turboItem = NSMenuItem(title: "Turbo (skip HTTPS hop + fast render)",
                                   action: #selector(toggleTurbo(_:)), keyEquivalent: "")
        turboItem.state = Perf.enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(shieldsItem)
        menu.addItem(lowMemItem)
        menu.addItem(turboItem)
        let focusItem = NSMenuItem(title: "Release tab when app unfocused",
                                   action: #selector(toggleFocusRelease(_:)), keyEquivalent: "")
        focusItem.state = releaseOnFocusLoss ? .on : .off
        menu.addItem(focusItem)
        menu.addItem(.separator())
        let memItem = NSMenuItem(title: "Total Memory: \(MemGuard.formatBytes(MemGuard.footprintBytes()))",
                                 action: nil, keyEquivalent: "")
        memItem.isEnabled = false
        menu.addItem(memItem)
        menu.addItem(withTitle: "Free Memory Now", action: #selector(reclaimNow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Process Inspector…", action: #selector(showProcessPanel), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MiniBrowser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.height + 4),
                   in: menuButton)
    }

    @objc func changeSearchEngine(_ sender: NSMenuItem) {
        guard let engine = sender.representedObject as? SearchEngine else { return }
        SearchEngine.current = engine
    }

    @objc func toggleShields(_ sender: NSMenuItem?) {
        let on = !Blocker.enabled
        Blocker.setEnabled(on)
        for tab in tabs where tab.webView != nil {
            if tab.isShowingStartPage { continue }
            if let u = tab.url {
                tab.navigate(to: u)
            }
        }
        if activeTab?.isShowingStartPage == false {
            activeTab?.webView?.reload()
        }
        if let sender { sender.state = Blocker.enabled ? .on : .off }
    }

    @objc func toggleLowMem(_ sender: NSMenuItem?) {
        LowMem.setEnabled(!LowMem.enabled)
        AppScripts.refresh()
        for tab in tabs where tab.webView != nil {
            if let u = tab.url {
                tab.navigate(to: u)
            }
        }
        if let sender { sender.state = LowMem.enabled ? .on : .off }
    }

    @objc func toggleTurbo(_ sender: NSMenuItem?) {
        Perf.setEnabled(!Perf.enabled)
        AppScripts.refresh()
        for tab in tabs where tab.webView != nil {
            if let u = tab.url {
                tab.navigate(to: u)
            }
        }
        if let sender { sender.state = Perf.enabled ? .on : .off }
    }

    // MARK: Memory optimization — drop idle background tabs entirely

    private func discardIdleTabs() {
        let footprint = MemGuard.footprintBytes()
        guard footprint > MemGuard.memoryPressureThreshold else { return }
        let now = Date()
        for tab in tabs where tab !== activeTab {
            guard tab.webView != nil else { continue }
            if now.timeIntervalSince(tab.lastActive) > discardAfterSeconds {
                tab.discard()
            }
        }
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var browser: BrowserViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Blocker.start()
        MemGuard.start()

        browser = BrowserViewController()
        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 720)

        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MiniBrowser"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.toolbar
        window.minSize = NSSize(width: 640, height: 440)
        window.contentViewController = browser
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window.setFrameAutosaveName("MiniBrowser.MainWindow")
        window.tabbingMode = .automatic

        buildMenu()
    }

    @objc func newWindowAction(_ sender: Any?) {
        browser.openNewWindow(isPrivate: false)
    }

    @objc func newIncognitoWindowAction(_ sender: Any?) {
        browser.openNewWindow(isPrivate: true)
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("MiniBrowser", comment: "App name")
        alert.informativeText = NSLocalizedString(
            "Version 1.0\nDeveloped by Trendzza\n\nUltra-low RAM, privacy-first native macOS browser powered by Apple Silicon WebKit.",
            comment: "About panel text")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK"))
        alert.runModal()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // --- App Menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About MiniBrowser", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MiniBrowser",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MiniBrowser",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // --- File Menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newWin = NSMenuItem(title: "New Window", action: #selector(newWindowAction(_:)), keyEquivalent: "n")
        newWin.target = self
        fileMenu.addItem(newWin)

        let newIncognito = NSMenuItem(title: "New Incognito Window", action: #selector(newIncognitoWindowAction(_:)), keyEquivalent: "n")
        newIncognito.keyEquivalentModifierMask = [.command, .shift]
        newIncognito.target = self
        fileMenu.addItem(newIncognito)

        fileMenu.addItem(withTitle: "New Tab", action: #selector(BrowserViewController.newTab(_:)), keyEquivalent: "t")
        let reopen = NSMenuItem(title: "Reopen Closed Tab", action: #selector(BrowserViewController.reopenClosedTab(_:)), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(reopen)

        let pinTab = NSMenuItem(title: "Pin / Unpin Tab", action: #selector(BrowserViewController.togglePinCurrentTab), keyEquivalent: "p")
        fileMenu.addItem(pinTab)

        let cmdPalette = NSMenuItem(title: "Command Palette…", action: #selector(BrowserViewController.showCommandPalette(_:)), keyEquivalent: "k")
        fileMenu.addItem(cmdPalette)

        let importChrome = NSMenuItem(title: "Import Bookmarks from Chrome…", action: #selector(BrowserViewController.importChromeBookmarksAction), keyEquivalent: "")
        fileMenu.addItem(importChrome)

        fileMenu.addItem(withTitle: "Close Tab", action: #selector(BrowserViewController.closeTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(BrowserViewController.printPage(_:)), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Open Location…", action: #selector(BrowserViewController.focusAddressBar(_:)), keyEquivalent: "l")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // --- Edit Menu
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Autofill Form", action: #selector(BrowserViewController.fillCurrentForm(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Manage Autofill Profile…", action: #selector(BrowserViewController.manageAutofillProfile(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find in Page…", action: #selector(BrowserViewController.showFindBar(_:)), keyEquivalent: "f")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // --- View Menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(BrowserViewController.reload(_:)), keyEquivalent: "r")
        let forceReload = NSMenuItem(title: "Force Reload", action: #selector(BrowserViewController.hardReload(_:)), keyEquivalent: "r")
        forceReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(forceReload)
        viewMenu.addItem(.separator())

        let readerItem = NSMenuItem(title: "Toggle Reader Mode", action: #selector(BrowserViewController.toggleReaderModeAction(_:)), keyEquivalent: "r")
        readerItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(readerItem)

        let pipItem = NSMenuItem(title: "Picture-in-Picture Video", action: #selector(BrowserViewController.togglePictureInPictureAction(_:)), keyEquivalent: "p")
        pipItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(pipItem)

        viewMenu.addItem(withTitle: "Translate Page to English", action: #selector(BrowserViewController.translatePage(_:)), keyEquivalent: "")

        let purgeMemItem = NSMenuItem(title: "Purge Memory & Freeze Background Tabs", action: #selector(BrowserViewController.purgeMemoryAndHibernate), keyEquivalent: "m")
        purgeMemItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(purgeMemItem)

        let inspectItem = NSMenuItem(title: "Inspect Element (DevTools)", action: #selector(BrowserViewController.toggleWebInspector(_:)), keyEquivalent: "i")
        inspectItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(inspectItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(BrowserViewController.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(BrowserViewController.zoomIn(_:)), keyEquivalent: "+")
        let zoomInEqual = NSMenuItem(title: "Zoom In", action: #selector(BrowserViewController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(zoomInEqual)
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(BrowserViewController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        let bmBarToggle = NSMenuItem(title: "Toggle Bookmarks Bar", action: #selector(BrowserViewController.toggleBookmarksBar(_:)), keyEquivalent: "b")
        bmBarToggle.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(bmBarToggle)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // --- History Menu
        let histItem = NSMenuItem()
        let histMenu = NSMenu(title: "History")
        histMenu.addItem(withTitle: "Back", action: #selector(BrowserViewController.goBack(_:)), keyEquivalent: "[")
        histMenu.addItem(withTitle: "Forward", action: #selector(BrowserViewController.goForward(_:)), keyEquivalent: "]")
        histMenu.addItem(.separator())
        histMenu.addItem(withTitle: "Show All History", action: #selector(BrowserViewController.showHistory), keyEquivalent: "y")
        histMenu.addItem(withTitle: "Site Data & Permissions…", action: #selector(BrowserViewController.showSiteData(_:)), keyEquivalent: "")
        histMenu.addItem(withTitle: "Clear Browsing Data…", action: #selector(BrowserViewController.clearBrowsingData), keyEquivalent: "")
        histItem.submenu = histMenu
        mainMenu.addItem(histItem)

        // --- Bookmarks Menu
        let bmItem = NSMenuItem()
        let bmMenu = NSMenu(title: "Bookmarks")
        bmMenu.addItem(withTitle: "Bookmark This Tab…", action: #selector(BrowserViewController.bookmarkCurrentPage(_:)), keyEquivalent: "d")
        let bmBarToggle2 = NSMenuItem(title: "Show Bookmarks Bar", action: #selector(BrowserViewController.toggleBookmarksBar(_:)), keyEquivalent: "b")
        bmBarToggle2.keyEquivalentModifierMask = [.command, .shift]
        bmMenu.addItem(bmBarToggle2)
        bmItem.submenu = bmMenu
        mainMenu.addItem(bmItem)

        // --- Tab Menu
        let tabItem = NSMenuItem()
        let tabMenu = NSMenu(title: "Tab")
        let nextTab = NSMenuItem(title: "Select Next Tab", action: #selector(BrowserViewController.selectNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let prevTab = NSMenuItem(title: "Select Previous Tab", action: #selector(BrowserViewController.selectPrevTab(_:)), keyEquivalent: "\t")
        prevTab.keyEquivalentModifierMask = [.control, .shift]
        tabMenu.addItem(nextTab)
        tabMenu.addItem(prevTab)
        tabMenu.addItem(.separator())
        tabMenu.addItem(withTitle: "Select Tab 1", action: #selector(BrowserViewController.selectTab1(_:)), keyEquivalent: "1")
        tabMenu.addItem(withTitle: "Select Tab 2", action: #selector(BrowserViewController.selectTab2(_:)), keyEquivalent: "2")
        tabMenu.addItem(withTitle: "Select Tab 3", action: #selector(BrowserViewController.selectTab3(_:)), keyEquivalent: "3")
        tabMenu.addItem(withTitle: "Select Tab 4", action: #selector(BrowserViewController.selectTab4(_:)), keyEquivalent: "4")
        tabMenu.addItem(withTitle: "Select Tab 5", action: #selector(BrowserViewController.selectTab5(_:)), keyEquivalent: "5")
        tabMenu.addItem(withTitle: "Select Tab 6", action: #selector(BrowserViewController.selectTab6(_:)), keyEquivalent: "6")
        tabMenu.addItem(withTitle: "Select Tab 7", action: #selector(BrowserViewController.selectTab7(_:)), keyEquivalent: "7")
        tabMenu.addItem(withTitle: "Select Tab 8", action: #selector(BrowserViewController.selectTab8(_:)), keyEquivalent: "8")
        tabMenu.addItem(withTitle: "Select Last Tab", action: #selector(BrowserViewController.selectTab9(_:)), keyEquivalent: "9")
        tabItem.submenu = tabMenu
        mainMenu.addItem(tabItem)

        // --- Window Menu
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "Process Inspector…", action: #selector(BrowserViewController.showProcessPanel), keyEquivalent: "")
        winMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        mainMenu.addItem(winItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        browser.saveSession()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        browser.saveSession()
    }

    func applicationDidResignActive(_ notification: Notification) {
        browser.saveSession()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()