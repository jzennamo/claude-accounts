// ClaudeUsage — menu bar view of Claude plan usage limits across several Claude Code accounts.
//
// Accounts: ~/.claude (= "default") plus every ~/.claude-accounts/<name> made by `claude-acct add`.
// Each account's OAuth token is read from the login keychain exactly where Claude Code keeps it
// ("Claude Code-credentials[-<sha256(dir)[:8]>]"); an expired token is refreshed and written back
// the same way the CLI does it. Tokens are never logged or shown.
//
//   ClaudeUsage            menu bar app
//   ClaudeUsage --dump     print every account's limits once and exit
import AppKit
import CryptoKit
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
let kcUser: String = {
    let u = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    return u.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil ? u : "claude-code-user"
}()
let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let supportDir = home + "/Library/Application Support/ClaudeUsage"

// MARK: accounts

struct Account {
    let name, dir, jsonPath, service: String
    var info: [String: Any] {
        guard let d = FileManager.default.contents(atPath: jsonPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j["oauthAccount"] as? [String: Any] ?? [:]
    }
    var email: String { info["emailAddress"] as? String ?? "not signed in" }
}

func discoverAccounts() -> [Account] {
    var out = [Account(name: "default", dir: home + "/.claude", jsonPath: home + "/.claude.json",
                       service: "Claude Code-credentials")]
    let root = home + "/.claude-accounts"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
    for n in names where !n.hasPrefix(".") {
        let dir = root + "/" + n
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        let h = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        out.append(Account(name: n, dir: dir, jsonPath: dir + "/.claude.json", service: "Claude Code-credentials-\(h)"))
    }
    return out
}

// MARK: keychain (via /usr/bin/security, which is what the CLI uses, so no access prompts)

@discardableResult
func run(_ exe: String, _ args: [String], stdin: String? = nil) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    let inp = Pipe(); if stdin != nil { p.standardInput = inp }
    do { try p.run() } catch { return (-1, "") }
    if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)); try? inp.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func readCreds(_ svc: String) -> [String: Any]? {
    let (rc, s) = run("/usr/bin/security", ["find-generic-password", "-a", kcUser, "-s", svc, "-w"])
    guard rc == 0, let d = s.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

func writeCreds(_ svc: String, _ doc: [String: Any]) -> Bool {
    guard let d = try? JSONSerialization.data(withJSONObject: doc) else { return false }
    let hex = d.map { String(format: "%02x", $0) }.joined()
    let cmd = "add-generic-password -U -a \"\(kcUser)\" -s \"\(svc)\" -X \"\(hex)\"\n"
    if cmd.count <= 4000 { return run("/usr/bin/security", ["-i"], stdin: cmd).0 == 0 }
    return run("/usr/bin/security", ["add-generic-password", "-U", "-a", kcUser, "-s", svc, "-X", hex]).0 == 0
}

// MARK: API

enum UsageError: LocalizedError {
    case notSignedIn, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "not signed in — claude-acct add <name>"
        case .http(let c, let m): return "HTTP \(c): \(m)"
        }
    }
}

func httpJSON(_ req: URLRequest) async throws -> [String: Any] {
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    guard (200..<300).contains(code) else {
        let msg = ((j["error"] as? [String: Any])?["message"] as? String) ?? (j["error_description"] as? String)
            ?? (j["error"] as? String) ?? String(decoding: data.prefix(120), as: UTF8.self)
        throw UsageError.http(code, msg)
    }
    return j
}

func oauth(_ svc: String) -> [String: Any]? { readCreds(svc)?["claudeAiOauth"] as? [String: Any] }

/// A valid access token for the account, refreshing (and saving) it if it has expired.
func accessToken(_ a: Account, force: Bool = false) async throws -> String {
    guard var doc = readCreds(a.service), var o = doc["claudeAiOauth"] as? [String: Any],
          let at = o["accessToken"] as? String else { throw UsageError.notSignedIn }
    let exp = (o["expiresAt"] as? NSNumber)?.doubleValue ?? 0
    if !force && exp / 1000 > Date().timeIntervalSince1970 + 120 { return at }
    guard let rt = o["refreshToken"] as? String else { throw UsageError.notSignedIn }

    var req = URLRequest(url: tokenURL); req.httpMethod = "POST"; req.timeoutInterval = 20
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject:
        ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID])
    let j: [String: Any]
    do { j = try await httpJSON(req) } catch {
        // Claude Code may have refreshed it meanwhile (rotating the refresh token): use its result.
        if let o2 = oauth(a.service), o2["refreshToken"] as? String != rt, let at2 = o2["accessToken"] as? String { return at2 }
        throw error
    }
    guard let newAT = j["access_token"] as? String else { throw UsageError.http(0, "no access_token in refresh reply") }
    // Don't clobber a refresh Claude Code wrote while ours was in flight.
    if let o2 = oauth(a.service), o2["refreshToken"] as? String != rt, let at2 = o2["accessToken"] as? String { return at2 }
    o["accessToken"] = newAT
    if let nrt = j["refresh_token"] as? String { o["refreshToken"] = nrt }
    let ttl = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
    o["expiresAt"] = Int64((Date().timeIntervalSince1970 + ttl) * 1000)
    if let rttl = (j["refresh_token_expires_in"] as? NSNumber)?.doubleValue {
        o["refreshTokenExpiresAt"] = Int64((Date().timeIntervalSince1970 + rttl) * 1000)
    }
    if let sc = j["scope"] as? String, !sc.isEmpty { o["scopes"] = sc.split(separator: " ").map(String.init) }
    doc["claudeAiOauth"] = o
    _ = writeCreds(a.service, doc)
    return newAT
}

struct Limit { let key, label: String; let pct: Double; let resets: Date? }
struct AccountUsage {
    let account: Account; var plan = ""; var limits: [Limit] = []; var extra: String?; var error: String?
    var ident: Ident?   // whose token this really is
    var email: String { ident?.email ?? account.email }
}

// Identity of a token, cached by token hash (shared with claude_acct_id.py). .claude.json's account can be
// rewritten by other Claude processes, so the token's own profile is the source of truth.
struct Ident: Codable { let tok: String; let email: String; let uuid: String }
let identPath = supportDir + "/identity.json"
func tokenHash(_ t: String) -> String { SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description }
func loadIdents() -> [String: Ident] {
    guard let d = FileManager.default.contents(atPath: identPath) else { return [:] }
    return (try? JSONDecoder().decode([String: Ident].self, from: d)) ?? [:]
}
func saveIdents(_ us: [AccountUsage]) {
    var all = loadIdents()
    for u in us { if let i = u.ident { all[u.account.service] = i } }
    try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(all) { try? d.write(to: URL(fileURLWithPath: identPath), options: .atomic) }
}
func identity(_ a: Account, _ token: String) async -> Ident? {
    let h = tokenHash(token)
    if let c = loadIdents()[a.service], c.tok == h { return c }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!); req.timeoutInterval = 15
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-usage-menu/1.0", forHTTPHeaderField: "User-Agent")
    guard let j = try? await httpJSON(req), let acc = j["account"] as? [String: Any],
          let u = acc["uuid"] as? String else { return nil }
    return Ident(tok: h, email: (acc["email"] as? String) ?? (acc["email_address"] as? String) ?? "", uuid: u)
}

let iso: (String) -> Date? = { s in
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]; return f.date(from: s)
}

func label(for key: String) -> String {
    switch key {
    case "five_hour": return "5-hour"
    case "seven_day": return "Weekly"
    case "seven_day_opus": return "Weekly Opus"
    case "seven_day_sonnet": return "Weekly Sonnet"
    case "seven_day_oauth_apps": return "Weekly apps"
    default: return key.replacingOccurrences(of: "seven_day", with: "weekly")
        .replacingOccurrences(of: "_", with: " ").capitalized
    }
}

func fetchUsage(_ a: Account) async -> AccountUsage {
    var u = AccountUsage(account: a)
    u.plan = (oauth(a.service)?["subscriptionType"] as? String) ?? ""
    do {
        var token = try await accessToken(a, force: ProcessInfo.processInfo.environment["CLAUDE_USAGE_FORCE_REFRESH"] == "1")
        var j: [String: Any] = [:]
        for attempt in 0..<2 {
            var req = URLRequest(url: usageURL); req.timeoutInterval = 20
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-usage-menu/1.0", forHTTPHeaderField: "User-Agent")
            do { j = try await httpJSON(req); break } catch UsageError.http(401, _) where attempt == 0 {
                token = try await accessToken(a, force: true)
            }
        }
        u.ident = await identity(a, token)
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        let keys = j.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        for k in keys {
            guard let v = j[k] as? [String: Any], let p = v["utilization"] as? NSNumber else { continue }
            u.limits.append(Limit(key: k, label: label(for: k), pct: p.doubleValue,
                                  resets: (v["resets_at"] as? String).flatMap(iso)))
        }
        if let e = j["extra_usage"] as? [String: Any], (e["is_enabled"] as? Bool) == true {
            let used = (e["used_credits"] as? NSNumber)?.doubleValue, lim = (e["monthly_limit"] as? NSNumber)?.doubleValue
            let scale = pow(10, (e["decimal_places"] as? NSNumber)?.doubleValue ?? 2)
            if let used, let lim, lim > 0 { u.extra = String(format: "Extra usage  $%.2f of $%.0f", used / scale, lim / scale) }
            else { u.extra = "Extra usage on" }
        }
        if u.limits.isEmpty && u.extra == nil { u.error = "no limits reported" }
    } catch { u.error = error.localizedDescription }
    return u
}

func fetchAll() async -> [AccountUsage] {
    await withTaskGroup(of: (Int, AccountUsage).self) { g in
        for (i, a) in discoverAccounts().enumerated() { g.addTask { (i, await fetchUsage(a)) } }
        var r: [(Int, AccountUsage)] = []; for await x in g { r.append(x) }
        let out = r.sorted { $0.0 < $1.0 }.map(\.1)
        saveIdents(out)
        return out
    }
}

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : (d.timeIntervalSinceNow < 6 * 86400 ? "EEE h:mm a" : "MMM d")
    return "resets " + f.string(from: d)
}

// MARK: menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    var usages: [AccountUsage] = []
    var updated: Date?
    var loading = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // New status items appear at the far left, which on a notched MacBook is behind the notch.
        // Start next to the clock instead; after a ⌘-drag macOS remembers wherever you put it.
        let posKey = "NSStatusItem Preferred Position ClaudeUsage"
        if UserDefaults.standard.object(forKey: posKey) == nil { UserDefaults.standard.set(280.0, forKey: posKey) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudeUsage"
        item.isVisible = true
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Claude usage")
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeading
        item.button?.title = " …"
        menu.delegate = self
        item.menu = menu
        rebuild()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuWillOpen(_ m: NSMenu) {
        rebuild()  // picks up the desktop app's current account
        if (updated.map { -$0.timeIntervalSinceNow > 60 }) ?? true { refresh() }
    }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            usages = await fetchAll(); updated = Date(); loading = false
            rebuild()
        }
    }

    static func color(_ p: Double) -> NSColor { p >= 90 ? .systemRed : p >= 75 ? .systemOrange : .labelColor }

    func rebuild() {
        // title: each account's binding limit — its highest % across 5-hour/weekly/model limits (in menu order)
        let fives = usages.map { $0.limits.map(\.pct).max() }
        let t = NSMutableAttributedString(string: " ")
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if usages.isEmpty { t.append(NSAttributedString(string: "…")) }
        for (i, p) in fives.prefix(4).enumerated() {
            if i > 0 { t.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])) }
            t.append(NSAttributedString(string: p.map { "\(Int($0.rounded()))" } ?? "–",
                                        attributes: [.foregroundColor: Self.color(p ?? 0)]))
        }
        if !usages.isEmpty { t.append(NSAttributedString(string: "%")) }
        t.addAttribute(.font, value: font, range: NSRange(location: 0, length: t.length))
        item.button?.attributedTitle = t

        menu.removeAllItems()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for u in usages {
            let plan = u.plan.isEmpty ? "" : "  ·  \(u.plan.capitalized)"
            let h = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            h.attributedTitle = NSAttributedString(string: "\(u.account.name) — \(u.email)\(plan)",
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            menu.addItem(h)
            for l in u.limits {
                let filled = max(0, min(10, Int((l.pct / 10).rounded())))
                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
                let s = NSMutableAttributedString(string: String(format: "  %@ %@ %3.0f%%  ", l.label.padding(toLength: 13, withPad: " ", startingAt: 0), bar, l.pct),
                                                  attributes: [.font: mono, .foregroundColor: Self.color(l.pct)])
                s.append(NSAttributedString(string: resetText(l.resets), attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: ""); mi.attributedTitle = s; menu.addItem(mi)
            }
            if let e = u.extra { menu.addItem(withTitle: "  " + e, action: nil, keyEquivalent: "") }
            if let e = u.error {
                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                mi.attributedTitle = NSAttributedString(string: "  ⚠︎ " + e, attributes: [.foregroundColor: NSColor.systemRed])
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }
        if usages.isEmpty { menu.addItem(withTitle: "Loading…", action: nil, keyEquivalent: ""); menu.addItem(.separator()) }

        // Desktop app account picker
        let profs = desktopProfiles()
        let cur = profs.first { $0.current }
        let desk = NSMenuItem(title: "Desktop app: \(cur?.name ?? "signed out")", action: nil, keyEquivalent: "")
        let dsub = NSMenu()
        for p in profs {
            let mi = NSMenuItem(title: p.name + (p.email.map { " — \($0)" } ?? "") + (p.unnamed ? "  (unnamed)" : ""), action: p.current ? nil : #selector(switchDesktop(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = p.name; mi.state = p.current ? .on : .off; dsub.addItem(mi)
        }
        if !profs.isEmpty { dsub.addItem(.separator()) }
        if cur != nil {
            let mi = NSMenuItem(title: "Rename current account…", action: #selector(nameDesktop), keyEquivalent: ""); mi.target = self; dsub.addItem(mi)
        }
        let nw = NSMenuItem(title: "Sign in another account…", action: #selector(newDesktop), keyEquivalent: ""); nw.target = self; dsub.addItem(nw)
        desk.submenu = dsub; menu.addItem(desk)

        // Claude in Chrome: one Chrome profile per account
        let chrome = NSMenuItem(title: "Claude in Chrome", action: nil, keyEquivalent: "")
        let csub = NSMenu()
        let cprofs = chromeProfiles()
        for p in cprofs {
            let mi = NSMenuItem(title: "\(p.name) — \(p.label)" + (p.extension ? "" : "  (extension not installed)"),
                                action: #selector(openChrome(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = p.name; csub.addItem(mi)
        }
        let missing = discoverAccounts().filter { a in !cprofs.contains { $0.name == a.name } }
        if !cprofs.isEmpty && !missing.isEmpty { csub.addItem(.separator()) }
        for a in missing {
            let email = usages.first { $0.account.name == a.name }?.email ?? a.email
            let mi = NSMenuItem(title: "Set up a Chrome profile for \(a.name)…", action: #selector(addChrome(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = [a.name, email]; csub.addItem(mi)
        }
        chrome.submenu = csub; menu.addItem(chrome)

        let open = NSMenuItem(title: "Open Claude Code as", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for a in discoverAccounts() {
            let email = usages.first { $0.account.name == a.name }?.email ?? a.email
            let mi = NSMenuItem(title: "\(a.name) — \(email)", action: #selector(openAs(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = a.name; sub.addItem(mi)
        }
        open.submenu = sub; menu.addItem(open)
        add("Add account…", #selector(addAccount))
        add("Sign in all my accounts…", #selector(setupAll))
        menu.addItem(.separator())
        add(loading ? "Refreshing…" : "Refresh now", #selector(refresh), "r")
        if let u = updated {
            let f = DateFormatter(); f.timeStyle = .short
            menu.addItem(withTitle: "Updated \(f.string(from: u))", action: nil, keyEquivalent: "")
        }
        let login = add("Launch at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add("Quit", #selector(NSApplication.terminate(_:)), "q").target = NSApp
    }

    @discardableResult
    func add(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key); mi.target = self; menu.addItem(mi); return mi
    }

    /// Run a shell line in a new Terminal window (via a .command file, so no Automation permission is needed).
    func terminal(_ line: String) {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let path = supportDir + "/run-\(UUID().uuidString.prefix(8)).command"
        let script = "#!/bin/bash -l\nrm -f \"$0\"\nexport PATH=\"$HOME/.local/bin:/opt/homebrew/bin:$PATH\"\n\(line)\n"
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func openAs(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String else { return }
        terminal("cd ~ && claude-acct \(n)")
    }

    /// Batch sign-in: asks for (or reads) the account list, then sets up each one — Chrome profile, Claude Code, desktop app.
    @objc func setupAll() {
        terminal("claude-acct setup --all; echo; read -p 'Press return to close.'")
    }

    // MARK: Claude in Chrome (claude-acct chrome …)

    struct ChromeProfile { let name: String; let label: String; let `extension`: Bool }

    func chromeProfiles() -> [ChromeProfile] {
        let (rc, s) = acct(["chrome", "list", "--json"])
        guard rc == 0, let d = s.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return rows.map { ChromeProfile(name: $0["name"] as? String ?? "?", label: $0["label"] as? String ?? "",
                                        extension: $0["extension"] as? Bool ?? false) }
    }

    @objc func openChrome(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String else { return }
        DispatchQueue.global().async { _ = self.acct(["chrome", "open", n]) }
    }

    @objc func addChrome(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String], v.count == 2 else { return }
        let email = v[1].contains("@") ? " '\(v[1])'" : ""
        terminal("claude-acct chrome add \(v[0])\(email); echo; read -p 'Press return to close.'")
    }

    @objc func addAccount() {
        let alert = NSAlert()
        alert.messageText = "Add a Claude account"
        alert.informativeText = "A short name and the account's e-mail. Sign-in opens in a private Chrome window, so your normal browser's claude.ai login isn't reused. You sign in once; after that it stays signed in."
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24)); field.placeholderString = "name, e.g. personal"
        let mail = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); mail.placeholderString = "e-mail, e.g. you@gmail.com"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54)); box.addSubview(field); box.addSubview(mail)
        field.nextKeyView = mail
        alert.accessoryView = box
        alert.addButton(withTitle: "Sign in"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = field.stringValue.trimmingCharacters(in: .whitespaces)
        let e = mail.stringValue.trimmingCharacters(in: .whitespaces)
        guard n.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, n != "default",
              e.isEmpty || e.range(of: "^[^\\s'\"@]+@[^\\s'\"@]+$", options: .regularExpression) != nil else { NSSound.beep(); return }
        terminal("claude-acct add \(n) \(e.isEmpty ? "" : "'\(e)'"); echo; read -p 'Press return to close.'")
    }

    // MARK: desktop app account switching (claude-acct desktop …)

    struct DesktopProfile { let name: String; let current: Bool; let unnamed: Bool; let email: String? }

    func acct(_ args: [String]) -> (Int32, String) {
        let exe = home + "/.local/bin/claude-acct"
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = home + "/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (-1, "can't run \(exe)") }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    func desktopProfiles() -> [DesktopProfile] {
        let (rc, s) = acct(["desktop", "list", "--json"])
        guard rc == 0, let d = s.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return rows.map { DesktopProfile(name: $0["name"] as? String ?? "?", current: $0["current"] as? Bool ?? false,
                                         unnamed: $0["unnamed"] as? Bool ?? false, email: $0["email"] as? String) }
    }

    func confirm(_ title: String, _ text: String, _ ok: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    func runDesktop(_ args: [String]) {
        item.button?.appearsDisabled = true
        DispatchQueue.global().async {
            let (rc, out) = self.acct(["desktop"] + args)
            DispatchQueue.main.async {
                self.item.button?.appearsDisabled = false
                self.rebuild()
                if rc != 0 {
                    let a = NSAlert(); a.messageText = "Couldn't switch the desktop app"; a.informativeText = out
                    NSApp.activate(ignoringOtherApps: true); a.runModal()
                }
            }
        }
    }

    static let quitWarning = "Claude will quit and reopen. Anything running in the desktop app (chats, Code sessions) stops; Code sessions can be resumed afterwards."

    @objc func switchDesktop(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String,
              confirm("Switch the desktop app to “\(n)”?", Self.quitWarning, "Switch") else { return }
        runDesktop(["switch", n])
    }

    @objc func newDesktop() {
        guard confirm("Sign in another account?",
                      Self.quitWarning + "\n\nThe current sign-in is saved first; Claude reopens signed out so you can sign in once with the other account.",
                      "Continue") else { return }
        runDesktop(["new"])
    }

    @objc func nameDesktop() {
        let a = NSAlert(); a.messageText = "Name the desktop app's current account"
        a.informativeText = "Shown in the switcher (letters, digits, . _ @ + -)."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); f.placeholderString = "e.g. work"
        a.accessoryView = f; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true); a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let (rc, out) = acct(["desktop", "name", f.stringValue.trimmingCharacters(in: .whitespaces)])
        if rc != 0 { let e = NSAlert(); e.messageText = "Couldn't rename"; e.informativeText = out; e.runModal() }
        rebuild()
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } } catch { NSSound.beep() }
        rebuild()
    }
}

@main
struct Main {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                for u in await fetchAll() {
                    print("\(u.account.name)\t\(u.email)\t\(u.plan)")
                    for l in u.limits {
                        print("  " + l.label.padding(toLength: 14, withPad: " ", startingAt: 0)
                              + String(format: "%5.1f%%  ", l.pct) + resetText(l.resets))
                    }
                    if let e = u.extra { print("  " + e) }
                    if let e = u.error { print("  ERROR " + e) }
                }
                done.signal()
            }
            done.wait()
            return
        }
        let app = NSApplication.shared
        let d = AppDelegate(); app.delegate = d
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(d) { app.run() }
    }
}
