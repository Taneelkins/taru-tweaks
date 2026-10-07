import SwiftUI
import AppKit

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class VaultController: ObservableObject {
    static let shared = VaultController()
    @Published var query = ""
    @Published var selected = 0
    @Published var suggested: [VaultItem] = []
    @Published var remember = true
    @Published var message = ""
    var target: FillTarget?
    private var panel: KeyPanel?
    private var monitor: Any?
    let vault = Vault.shared

    func keyDefaults() -> [(UInt32, String, UInt64, Int64)] {[
        (301, "vault.k.fill", 0x140000, 37),
        (302, "vault.k.pick", 0x1C0000, 37),
        (303, "vault.k.totp", 0x140000, 31)
    ]}

    func registerKeys() {
        for (id, k, m, key) in keyDefaults() {
            let d = UserDefaults.standard
            let mask = (d.object(forKey: k + ".mask") as? NSNumber)?.uint64Value ?? m
            let code = (d.object(forKey: k + ".key") as? NSNumber)?.int64Value ?? key
            HotKeys.shared.set(id, mask: mask, key: code, enabled: d.object(forKey: "vault.enabled") as? Bool ?? true) { [weak self] in
                switch id { case 301: self?.fill(); case 302: self?.pick(); default: self?.typeTOTP() }
            }
        }
    }

    var results: [VaultItem] {
        let base = query.isEmpty ? (suggested + vault.items.filter { !suggested.contains($0) }) : vault.items
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter { $0.name.lowercased().contains(q) || $0.username.lowercased().contains(q) || $0.uris.contains { $0.lowercased().contains(q) } }
    }

    func fill() {
        guard let t = Vault.currentTarget() else { return }
        target = t
        vault.unlock { [weak self] ok in
            guard let self, ok else { self?.toast(self?.vault.lastError ?? "Locked"); return }
            let m = self.vault.matches(for: t)
            if m.count == 1 || self.vault.mappings[t.bundleID] != nil, let item = m.first { self.perform(item, mode: "login") }
            else { self.suggested = m; self.showPicker() }
        }
    }

    func pick() {
        guard let t = Vault.currentTarget() else { return }
        target = t
        vault.unlock { [weak self] ok in
            guard let self, ok else { self?.toast(self?.vault.lastError ?? "Locked"); return }
            self.suggested = self.vault.matches(for: t)
            self.showPicker()
        }
    }

    func typeTOTP() {
        guard let t = Vault.currentTarget() else { return }
        target = t
        vault.unlock { [weak self] ok in
            guard let self, ok else { return }
            let m = self.vault.matches(for: t).filter(\.hasTOTP)
            if let item = m.first { self.perform(item, mode: "totp") } else { self.suggested = m; self.showPicker() }
        }
    }

    func perform(_ item: VaultItem, mode: String) {
        hidePicker()
        guard let t = target else { return }
        if remember && !t.bundleID.isEmpty && mode == "login" { vault.mappings[t.bundleID] = item.id }
        NSRunningApplication(processIdentifier: t.pid)?.activate()
        let enter = vault.pressEnter
        if mode == "totp" {
            vault.totp(item) { code in
                guard let code else { self.toast("No 2FA code for \(item.name)"); return }
                DispatchQueue.global(qos: .userInteractive).async { Typer.waitForModifiersReleased(); Typer.type(code); if enter { Typer.key(36) } }
            }
            return
        }
        if mode == "copy-totp" {
            vault.totp(item) { code in if let code { self.copy(code, "2FA code copied") } }
            return
        }
        if mode == "copy" { copy(item.password, "Password copied for 45 seconds"); return }
        DispatchQueue.global(qos: .userInteractive).async {
            Typer.waitForModifiersReleased()
            usleep(150_000)
            if mode == "login" && !item.username.isEmpty { Typer.type(item.username); Typer.key(48) }
            Typer.type(item.password)
            if enter { Typer.key(36) }
        }
    }

    func copy(_ s: String, _ msg: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(s, forType: .string)
        let change = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { if pb.changeCount == change { pb.clearContents() } }
        toast(msg)
    }

    func toast(_ s: String) { message = s; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.message == s { self.message = "" } } }

    func showPicker() {
        query = ""; selected = 0
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.contentView = NSHostingView(rootView: VaultPicker())
            panel = p
        }
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel?.setFrameOrigin(NSPoint(x: f.midX - 280, y: f.midY - 120))
        panel?.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel?.isVisible == true else { return e }
            let r = self.results
            switch e.keyCode {
            case 53: self.hidePicker(); return nil
            case 125: self.selected = min(self.selected + 1, max(0, r.count - 1)); return nil
            case 126: self.selected = max(0, self.selected - 1); return nil
            case 36:
                guard r.indices.contains(self.selected) else { return nil }
                let mode = e.modifierFlags.contains(.option) ? "password" : (e.modifierFlags.contains(.command) ? "copy" : "login")
                self.perform(r[self.selected], mode: mode); return nil
            default:
                if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "t", r.indices.contains(self.selected) { self.perform(r[self.selected], mode: "copy-totp"); return nil }
                return e
            }
        }
    }

    func hidePicker() {
        panel?.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

struct VaultPicker: View {
    @ObservedObject var c = VaultController.shared
    @ObservedObject var theme = Theme.shared
    @FocusState var focused: Bool

    var body: some View {
        let r = c.results
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(theme.accent)
                TextField("Search your vault", text: $c.query).textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                    .onChange(of: c.query) { _, _ in c.selected = 0 }
                Text(c.target.map { "→ \($0.appName)" } ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash)
            }
            Rectangle().fill(Palette.rule).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if c.query.isEmpty && !c.suggested.isEmpty {
                            Text("MATCHES FOR \(c.target?.appName.uppercased() ?? "")").font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(theme.accent).padding(.vertical, 4)
                        }
                        ForEach(Array(r.prefix(60).enumerated()), id: \.element.id) { i, item in
                            HStack(spacing: 10) {
                                Text(String(item.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .frame(width: 28, height: 28).foregroundStyle(i == c.selected ? Color.black : theme.accent).background(i == c.selected ? theme.accent : Color.black)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.bone).lineLimit(1)
                                    Text(item.username.isEmpty ? (item.uris.first ?? "") : item.username).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
                                }
                                Spacer()
                                if item.hasTOTP { Text("2FA").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash).padding(.horizontal, 4).overlay(Rectangle().stroke(Palette.rule)) }
                            }
                            .padding(6).background(i == c.selected ? theme.accent.opacity(0.14) : .clear).contentShape(Rectangle()).id(i)
                            .onTapGesture { c.selected = i; c.perform(item, mode: "login") }
                        }
                        if r.isEmpty { Text(c.vault.items.isEmpty ? "Vault is empty or still loading" : "No logins match").font(.system(size: 12)).foregroundStyle(Palette.ash).padding(8) }
                    }
                }
                .onChange(of: c.selected) { _, v in proxy.scrollTo(v, anchor: .center) }
            }
            HStack {
                Toggle("Remember for \(c.target?.appName ?? "this app")", isOn: $c.remember).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Text("↩ FILL · ⌥↩ PASSWORD · ⌘↩ COPY · ⌘T 2FA · ESC").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.ash)
            }
        }
        .padding(16).frame(width: 560, height: 420)
        .background(Color(red: 0.03, green: 0.012, blue: 0.012).opacity(0.96))
        .overlay(Rectangle().stroke(theme.accent.opacity(0.6)))
        .tint(theme.accent).preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}

struct VaultSettings: View {
    @ObservedObject var v = Vault.shared
    @ObservedObject var c = VaultController.shared
    @ObservedObject var theme = Theme.shared
    @State var email = ""
    @State var password = ""
    @State var code = ""
    @State var method = 0
    @State var needsCode = false
    @State var remember = true
    @State var note = ""
    @State var newPassword = ""

    func key(_ k: String, _ m: UInt64, _ code: Int64) -> some View {
        let d = UserDefaults.standard
        return KeyRecorder(mask: Binding(get: { (d.object(forKey: k + ".mask") as? NSNumber)?.uint64Value ?? m }, set: { d.set($0, forKey: k + ".mask"); c.registerKeys() }),
                           key: Binding(get: { (d.object(forKey: k + ".key") as? NSNumber)?.int64Value ?? code }, set: { d.set($0, forKey: k + ".key"); c.registerKeys() }))
    }

    var statusText: String {
        switch v.status {
        case "no-cli": return "Bitwarden CLI not installed"
        case "unauthenticated": return "Not signed in"
        case "locked": return "Signed in as \(v.email) · locked"
        case "unlocked": return "Signed in as \(v.email) · unlocked\(v.unlockedUntil.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? "")"
        default: return v.status
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Bitwarden Bridge", subtitle: "Fill logins from your Bitwarden vault into any app. Your master password stays in your Mac's Keychain and is released only after Touch ID.")
            SettingRow(title: "Vault", detail: statusText) {
                HStack {
                    if v.status == "unlocked" { TweakButton(title: "Lock") { v.lock() } }
                    else if v.status == "locked" { TweakButton(title: "Unlock") { v.unlock { _ in } } }
                    TweakButton(title: "Refresh") { v.refreshStatus() }
                }
            }
            if !v.lastError.isEmpty { Text(v.lastError).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.accent).padding(.vertical, 6) }
            if v.status == "unauthenticated" {
                SectionLabel(text: "Sign in")
                SettingRow(title: "Server", detail: "Leave empty for bitwarden.com. EU: https://vault.bitwarden.eu") {
                    HStack { TextField("https://vault.bitwarden.com", text: $v.server).textFieldStyle(.roundedBorder).frame(width: 240); TweakButton(title: "Set") { v.setServer(v.server) { note = $0 } } }
                }
                SettingRow(title: "Email") { TextField("you@example.com", text: $email).textFieldStyle(.roundedBorder).frame(width: 260) }
                SettingRow(title: "Master password") { SecureField("", text: $password).textFieldStyle(.roundedBorder).frame(width: 260) }
                if needsCode {
                    SettingRow(title: "Two-step code") {
                        HStack {
                            Picker("", selection: $method) { Text("Authenticator").tag(0); Text("Email").tag(1); Text("YubiKey").tag(3) }.labelsHidden().frame(width: 130)
                            TextField("123456", text: $code).textFieldStyle(.roundedBorder).frame(width: 120)
                        }
                    }
                }
                SettingRow(title: "Remember with Touch ID", detail: "Stores the master password in your Keychain so the vault unlocks with Touch ID") { Switch(on: $remember) }
                HStack(spacing: 10) {
                    TweakButton(title: v.busy ? "Signing in…" : "Sign in") {
                        v.login(email: email, password: password, method: needsCode ? method : nil, code: code, remember: remember) { err in
                            if let err {
                                if err.lowercased().contains("two-step") || err.lowercased().contains("code") { needsCode = true; note = "Enter your two-step code and sign in again" } else { note = err }
                            } else { password = ""; code = ""; note = "Signed in" }
                        }
                    }
                    TweakButton(title: "Sign in using Terminal") { v.signInInTerminal() }
                    Text(note).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash)
                }.padding(.top, 12)
            } else if v.status != "no-cli" {
                SectionLabel(text: "Touch ID unlock")
                SettingRow(title: "Master password in Keychain", detail: v.hasStoredPassword ? "Saved · Touch ID required to use it" : "Not saved: the shortcuts can't unlock the vault yet") {
                    if v.hasStoredPassword { TweakButton(title: "Forget") { v.forgetPassword() } }
                    else { HStack { SecureField("Master password", text: $newPassword).textFieldStyle(.roundedBorder).frame(width: 200); TweakButton(title: "Save") { v.savePassword(newPassword); newPassword = "" } } }
                }
                SettingRow(title: "Lock after", detail: "\(v.lockMinutes) minutes, and whenever the Mac sleeps or locks") { Stepper("", value: $v.lockMinutes, in: 1...240, step: 5).labelsHidden() }
            }
            SectionLabel(text: "Shortcuts")
            SettingRow(title: "Fill the login for this app", detail: "Types username, Tab, password. Asks once if several logins match.") { key("vault.k.fill", 0x140000, 37) }
            SettingRow(title: "Choose a login", detail: "Search the whole vault") { key("vault.k.pick", 0x1C0000, 37) }
            SettingRow(title: "Type the 2FA code") { key("vault.k.totp", 0x140000, 31) }
            SettingRow(title: "Press Return after filling") { Switch(on: $v.pressEnter) }
            SectionLabel(text: "Remembered apps")
            if v.mappings.isEmpty { Text("When you pick a login for an app, it's remembered here.").font(.system(size: 12)).foregroundStyle(Palette.ash) }
            ForEach(v.mappings.sorted { $0.key < $1.key }, id: \.key) { m in
                SettingRow(title: NSWorkspace.shared.urlForApplication(withBundleIdentifier: m.key).map { FileManager.default.displayName(atPath: $0.path) } ?? m.key,
                           detail: v.items.first { $0.id == m.value }?.name ?? (v.unlocked ? "login removed" : "unlock to see the login")) {
                    TweakButton(title: "Forget") { v.mappings[m.key] = nil }
                }
            }
        }
        .onAppear { v.refreshStatus() }
    }
}
