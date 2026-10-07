import AppKit
import LocalAuthentication
import Security

struct VaultItem: Identifiable, Equatable {
    let id: String
    let name: String
    let username: String
    let password: String
    let hasTOTP: Bool
    let uris: [String]
    let notes: String
    static func == (a: VaultItem, b: VaultItem) -> Bool { a.id == b.id }
}

struct FillTarget {
    let bundleID: String
    let appName: String
    let windowTitle: String
    let pid: pid_t
}

enum Keychain {
    static let service = "com.taru.tweaks.vault"
    static func save(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

final class Vault: ObservableObject {
    static let shared = Vault()
    @Published var cliInstalled = false
    @Published var status = "checking"
    @Published var email = ""
    @Published var items: [VaultItem] = []
    @Published var unlockedUntil: Date?
    @Published var lastError = ""
    @Published var busy = false
    @Published var hasStoredPassword = Keychain.load("master") != nil
    @Published var mappings: [String: String] = UserDefaults.standard.dictionary(forKey: "vault.mappings") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(mappings, forKey: "vault.mappings") }
    }
    @Published var lockMinutes: Int = UserDefaults.standard.object(forKey: "vault.lockMinutes") as? Int ?? 15 { didSet { UserDefaults.standard.set(lockMinutes, forKey: "vault.lockMinutes") } }
    @Published var pressEnter: Bool = UserDefaults.standard.bool(forKey: "vault.enter") { didSet { UserDefaults.standard.set(pressEnter, forKey: "vault.enter") } }
    @Published var server: String = UserDefaults.standard.string(forKey: "vault.server") ?? "" { didSet { UserDefaults.standard.set(server, forKey: "vault.server") } }

    private var session: String?
    private var lockTimer: Timer?
    let bw = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"].first { FileManager.default.isExecutableFile(atPath: $0) }

    init() {
        refreshStatus()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.lock() }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.lock() }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.lock() }
    }

    var unlocked: Bool { session != nil && (unlockedUntil ?? .distantPast) > Date() }

    @discardableResult
    func run(_ args: [String], env: [String: String] = [:], input: String? = nil) -> (Int32, String, String) {
        guard let bw else { return (127, "", "Bitwarden CLI not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bw)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        e["BW_NOINTERACTION"] = "true"
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        do { try p.run() } catch { return (1, "", error.localizedDescription) }
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: o, encoding: .utf8) ?? "", String(data: r, encoding: .utf8) ?? "")
    }

    func refreshStatus() {
        cliInstalled = bw != nil
        guard cliInstalled else { status = "no-cli"; return }
        DispatchQueue.global().async {
            let (_, out, _) = self.run(["status"])
            let j = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            DispatchQueue.main.async {
                let s = j?["status"] as? String ?? "unknown"
                self.status = self.session != nil && s == "locked" ? "unlocked" : s
                self.email = j?["userEmail"] as? String ?? self.email
            }
        }
    }

    func setServer(_ url: String, done: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            let r = self.run(["config", "server", url.isEmpty ? "https://vault.bitwarden.com" : url])
            DispatchQueue.main.async { done(r.0 == 0 ? "Server set" : r.2) }
        }
    }

    func login(email: String, password: String, method: Int?, code: String, remember: Bool, done: @escaping (String?) -> Void) {
        busy = true
        DispatchQueue.global().async {
            var args = ["login", email, "--passwordenv", "TT_BW_PASS", "--raw"]
            if let method, !code.isEmpty { args += ["--method", "\(method)", "--code", code] }
            let r = self.run(args, env: ["TT_BW_PASS": password])
            DispatchQueue.main.async {
                self.busy = false
                if r.0 == 0, !r.1.isEmpty {
                    self.session = r.1.trimmingCharacters(in: .whitespacesAndNewlines)
                    if remember { Keychain.save(password, account: "master"); self.hasStoredPassword = true }
                    self.armLock(); self.status = "unlocked"; self.loadItems()
                    done(nil)
                } else {
                    let msg = (r.2 + r.1).trimmingCharacters(in: .whitespacesAndNewlines)
                    done(msg.isEmpty ? "Sign-in failed" : msg)
                }
                self.refreshStatus()
            }
        }
    }

    @Published var awaitingCode = false
    @Published var codePrompt = ""
    private var loginProc: Process?
    private var loginIn: FileHandle?
    private var loginOut = ""

    func startLogin(email: String, password: String, method: Int?, remember: Bool, done: @escaping (String?) -> Void) {
        guard let bw else { done("Bitwarden CLI not installed"); return }
        cancelLogin()
        busy = true; awaitingCode = false; loginOut = ""; lastError = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        var args = ["-q", "/dev/null", bw, "login", email, "--passwordenv", "TT_BW_PASS", "--raw"]
        if let method { args += ["--method", "\(method)"] }
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; e["TT_BW_PASS"] = password; e["TERM"] = "dumb"; e["NO_COLOR"] = "1"
        e.removeValue(forKey: "BW_NOINTERACTION")
        p.environment = e
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        loginIn = inp.fileHandleForWriting
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(data: h.availableData, encoding: .utf8) ?? ""
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loginOut += chunk
                let clean = self.loginOut.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                let lower = clean.lowercased()
                if !self.awaitingCode && (lower.contains("code:") || lower.contains("verification code") || lower.contains("otp")) {
                    self.awaitingCode = true
                    self.codePrompt = lower.contains("new device") ? "Enter the new-device code Bitwarden just emailed you" : "Enter your two-step code"
                    self.busy = false
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.loginOut += rest
                let clean = self.loginOut.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                let lines = clean.components(separatedBy: CharacterSet.newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                self.busy = false; self.awaitingCode = false; self.loginProc = nil; self.loginIn = nil
                if proc.terminationStatus == 0, let last = lines.last, !last.contains(" "), last.count > 40 {
                    self.session = last
                    if remember { Keychain.save(password, account: "master"); self.hasStoredPassword = true }
                    self.armLock(); self.status = "unlocked"; self.loadItems(); done(nil)
                } else {
                    let msg = lines.filter { !$0.lowercased().contains("code:") && !$0.lowercased().contains("password") }.last ?? "Sign-in failed"
                    done(msg)
                }
                self.loginOut = ""
                self.refreshStatus()
            }
        }
        do { try p.run(); loginProc = p } catch { busy = false; done(error.localizedDescription) }
    }

    func submitCode(_ code: String) {
        guard let h = loginIn else { return }
        h.write(Data((code.trimmingCharacters(in: .whitespaces) + "\n").utf8))
        awaitingCode = false; busy = true
    }

    func cancelLogin() {
        loginProc?.terminate(); loginProc = nil; loginIn = nil; awaitingCode = false; busy = false
    }

    func signInInTerminal() {
        let script = "tell application \"Terminal\" to do script \"/opt/homebrew/bin/bw login\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func savePassword(_ pw: String) { Keychain.save(pw, account: "master"); hasStoredPassword = true }
    func forgetPassword() { Keychain.delete("master"); hasStoredPassword = false }

    func authenticate(_ reason: String, done: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: reason) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    func unlock(done: @escaping (Bool) -> Void) {
        if unlocked { armLock(); done(true); return }
        guard let pw = Keychain.load("master") else { lastError = "Save your master password in Settings → Bitwarden Bridge first"; done(false); return }
        authenticate("unlock your Bitwarden vault") { ok in
            guard ok else { done(false); return }
            self.busy = true
            DispatchQueue.global().async {
                let r = self.run(["unlock", "--passwordenv", "TT_BW_PASS", "--raw"], env: ["TT_BW_PASS": pw])
                DispatchQueue.main.async {
                    self.busy = false
                    guard r.0 == 0, !r.1.isEmpty else { self.lastError = r.2.isEmpty ? "Unlock failed" : r.2; done(false); return }
                    self.session = r.1.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.armLock(); self.status = "unlocked"
                    self.loadItems { done(true) }
                }
            }
        }
    }

    func armLock() {
        unlockedUntil = Date().addingTimeInterval(Double(max(1, lockMinutes)) * 60)
        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: Double(max(1, lockMinutes)) * 60, repeats: false) { [weak self] _ in self?.lock() }
    }

    func lock() {
        guard session != nil else { return }
        let s = session
        session = nil; items = []; unlockedUntil = nil
        DispatchQueue.global().async { _ = self.run(["lock"], env: ["BW_SESSION": s ?? ""]) }
        status = "locked"
    }

    func loadItems(sync: Bool = true, done: (() -> Void)? = nil) {
        guard let s = session else { done?(); return }
        DispatchQueue.global().async {
            if sync { _ = self.run(["sync"], env: ["BW_SESSION": s]) }
            let r = self.run(["list", "items"], env: ["BW_SESSION": s])
            let arr = (try? JSONSerialization.jsonObject(with: Data(r.1.utf8))) as? [[String: Any]] ?? []
            let parsed: [VaultItem] = arr.compactMap { i in
                guard (i["type"] as? Int) == 1, let id = i["id"] as? String, let login = i["login"] as? [String: Any] else { return nil }
                let uris = (login["uris"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
                return VaultItem(id: id, name: i["name"] as? String ?? "", username: login["username"] as? String ?? "", password: login["password"] as? String ?? "",
                                 hasTOTP: !((login["totp"] as? String) ?? "").isEmpty, uris: uris, notes: "")
            }
            DispatchQueue.main.async { self.items = parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }; done?() }
        }
    }

    func totp(_ item: VaultItem, done: @escaping (String?) -> Void) {
        guard let s = session else { done(nil); return }
        DispatchQueue.global().async {
            let r = self.run(["get", "totp", item.id], env: ["BW_SESSION": s])
            DispatchQueue.main.async { done(r.0 == 0 ? r.1.trimmingCharacters(in: .whitespacesAndNewlines) : nil) }
        }
    }

    func host(_ s: String) -> String {
        var h = s.lowercased()
        for p in ["https://", "http://", "androidapp://", "iosapp://", "macapp://", "www."] { if h.hasPrefix(p) { h.removeFirst(p.count) } }
        return h.components(separatedBy: "/").first ?? h
    }

    func matches(for t: FillTarget) -> [VaultItem] {
        if let id = mappings[t.bundleID], let item = items.first(where: { $0.id == id }) { return [item] }
        let app = t.appName.lowercased()
        let bundle = t.bundleID.lowercased()
        let title = t.windowTitle.lowercased()
        let words = Set(bundle.split(separator: ".").map(String.init) + [app]).filter { $0.count > 2 && !["com", "app", "www", "net", "org", "inc", "desktop", "macos"].contains($0) }
        var scored: [(VaultItem, Int)] = []
        for i in items {
            var score = 0
            let n = i.name.lowercased()
            for u in i.uris {
                let h = host(u)
                if h == bundle { score += 100 }
                if !title.isEmpty && title.contains(h) { score += 60 }
                if words.contains(where: { h.contains($0) }) { score += 40 }
            }
            if n == app { score += 50 } else if words.contains(where: { n.contains($0) }) { score += 25 }
            if !title.isEmpty && n.count > 3 && title.contains(n) { score += 30 }
            if score > 0 { scored.append((i, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func currentTarget() -> FillTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.3)
        var title = ""
        if let w: AXUIElement = ax(el, kAXFocusedWindowAttribute), let t: String = ax(w, kAXTitleAttribute) { title = t }
        return FillTarget(bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "", windowTitle: title, pid: app.processIdentifier)
    }
}

enum Typer {
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text.utf16 {
            var c = ch
            if let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true), let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                d.flags = []; u.flags = []
                d.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                u.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                d.post(tap: .cgSessionEventTap); u.post(tap: .cgSessionEventTap)
            }
            usleep(6000)
        }
    }
    static func key(_ code: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cgSessionEventTap)
        usleep(30000)
    }
    static func waitForModifiersReleased() {
        var tries = 0
        while CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) != [] && tries < 100 { usleep(20000); tries += 1 }
        usleep(60000)
    }
}
