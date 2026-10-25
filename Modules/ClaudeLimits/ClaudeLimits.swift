import AppKit
import SwiftUI

// Claude plan limits (session + week) for the Taru Bar. Asks Claude Code itself over its stream-json
// control channel, the same numbers as /usage, so no token ever passes through here and Claude
// handles its own sign-in. No prompt, model call, tool or MCP server runs. Idea from Vorssaint.
final class ClaudeLimits: ObservableObject {
    static let shared = ClaudeLimits()

    struct Limit: Identifiable, Equatable {
        let id: String
        let name: String
        let percent: Double
        let resets: Date?
        let severity: String
    }

    @Published private(set) var limits: [Limit] = []
    @Published private(set) var updated: Date?
    @Published private(set) var status = ""
    @Published private(set) var checking = false

    var session: Limit? { limits.first { $0.id == "session" } }
    var week: Limit? { limits.first { $0.id == "weekly_all" } }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "claude-limits", qos: .utility)

    func start() {
        guard timer == nil else { return }
        // cheap tick, only spawns Claude Code when the reading is stale: 10 min while Claude works, 30 when quiet (each check costs ~1-2 s of CPU)
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshIfStale() }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshIfStale(maxAge: TimeInterval? = nil) {
        let age = updated.map { Date().timeIntervalSince($0) } ?? .infinity
        let limit = maxAge ?? (Awake.shared.claudeBusy ? 600 : 1800)
        if age >= limit { refresh() }
    }

    func refresh() {
        guard !checking else { return }
        guard let exe = Self.executable() else { status = "Claude Code not found"; return }
        checking = true
        queue.async { [weak self] in
            let result = Self.ask(exe)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                switch result {
                case let .success(l): self.limits = l; self.updated = Date(); self.status = ""
                case let .failure(why): self.status = why.message
                }
                TaruBar.shared.place()
            }
        }
    }

    // MARK: Claude Code

    // newest copy the desktop app keeps (always current, and signed in), then the CLI installs
    static func executable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            for build in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(v).path)) ?? [] {
                let exe = root.appendingPathComponent("\(v)/\(build)/claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: exe.path) { return exe }
            }
        }
        return [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude")].first { fm.isExecutableFile(atPath: $0.path) }
    }

    enum Failure: Error {
        case outdated, signedOut, unreachable
        var message: String {
            switch self {
            case .outdated: "Claude Code is too old to report limits"
            case .signedOut: "Sign in to Claude Code to see limits"
            case .unreachable: "Couldn't reach Claude, will retry"
            }
        }
    }

    private static func ask(_ exe: URL) -> Result<[Limit], Failure> {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                       "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["DISABLE_AUTOUPDATER"] = "1"
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var buffer = Data(), answer: [String: Any]?
        let got = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { got.signal(); return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: nl); buffer.removeSubrange(...nl)
                guard answer == nil, let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      m["type"] as? String == "control_response", let r = m["response"] as? [String: Any],
                      r["request_id"] as? String == "usage" else { continue }
                answer = r
                got.signal()
            }
        }
        guard (try? p.run()) != nil else { return .failure(.unreachable) }
        for (id, sub) in [("init", "initialize"), ("usage", "get_usage")] {
            let req: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": sub, "skip_behaviors": true]]
            if let d = try? JSONSerialization.data(withJSONObject: req) { input.fileHandleForWriting.write(d + Data([0x0A])) }
        }
        _ = got.wait(timeout: .now() + 25)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if p.isRunning { p.terminate() }

        lock.lock(); let r = answer; lock.unlock()
        guard let r else { return .failure(.unreachable) }
        guard r["subtype"] as? String == "success" else {
            let e = (r["error"] as? String ?? "").lowercased()
            if e.contains("unsupported") { return .failure(.outdated) }
            return .failure(e.contains("auth") || e.contains("login") ? .signedOut : .unreachable)
        }
        let body = r["response"] as? [String: Any] ?? [:]
        guard body["rate_limits_available"] as? Bool == true, let rl = body["rate_limits"] as? [String: Any],
              let list = rl["limits"] as? [[String: Any]] else { return .failure(.signedOut) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let limits: [Limit] = list.compactMap { l in
            guard let kind = l["kind"] as? String, let pct = (l["percent"] as? NSNumber)?.doubleValue else { return nil }
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let name = switch kind {
            case "session": "Session"
            case "weekly_all": "This week"
            default: model.map { "\($0) this week" } ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            let when = (l["resets_at"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            return Limit(id: kind == "weekly_scoped" ? "weekly_\(model ?? "scoped")" : kind, name: name, percent: min(100, max(0, pct)), resets: when, severity: l["severity"] as? String ?? "normal")
        }
        return limits.isEmpty ? .failure(.unreachable) : .success(limits)
    }

    // MARK: Text

    static func resetText(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : (d.timeIntervalSinceNow < 6 * 86_400 ? "EEE h:mm a" : "MMM d")
        let left = d.timeIntervalSinceNow
        let rel = left < 3600 ? "\(max(1, Int(left / 60)))m" : left < 86_400 ? "\(Int(left / 3600))h \(Int(left.truncatingRemainder(dividingBy: 3600) / 60))m" : "\(Int(left / 86_400))d \(Int(left.truncatingRemainder(dividingBy: 86_400) / 3600))h"
        return "resets \(f.string(from: d)) · in \(rel)"
    }
}

// red once a limit is close, so a glance at the bar is enough
func limitColor(_ l: ClaudeLimits.Limit?) -> Color {
    guard let l else { return Palette.bone }
    return l.percent >= 80 || l.severity != "normal" ? Theme.shared.accent : Palette.bone
}

struct ClaudeReadout: View {
    @ObservedObject var limits = ClaudeLimits.shared
    var body: some View {
        Text("CLAUDE").foregroundStyle(Palette.ash).font(.system(size: 9.5, weight: .bold, design: .monospaced))
        if let s = limits.session { Text("\(Int(s.percent))%").foregroundStyle(limitColor(s)) }
        if let w = limits.week {
            Text("WK").foregroundStyle(Palette.ash).font(.system(size: 9.5, weight: .bold, design: .monospaced))
            Text("\(Int(w.percent))%").foregroundStyle(limitColor(w))
        }
    }
}

struct ClaudePopup: View {
    @ObservedObject var limits = ClaudeLimits.shared
    @ObservedObject var theme = Theme.shared
    var body: some View {
        PopupCard(title: "Claude limits") {
            if limits.limits.isEmpty {
                Text(limits.status.isEmpty ? "Checking…" : limits.status).font(.system(size: 12)).foregroundStyle(Palette.ash)
            }
            ForEach(limits.limits) { l in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(l.name.uppercased()).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Palette.bone)
                        Spacer()
                        Text("\(Int(l.percent))%").font(.system(size: l.id == "session" ? 22 : 15, weight: .heavy, design: .monospaced)).foregroundStyle(l.percent >= 80 ? theme.accent : Palette.bone)
                    }
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Palette.rule)
                        GeometryReader { g in Rectangle().fill(theme.accent).frame(width: g.size.width * l.percent / 100).shadow(color: theme.accent.opacity(0.6), radius: 4) }
                    }
                    .frame(height: 5)
                    Text(ClaudeLimits.resetText(l.resets)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash)
                }
            }
            HStack {
                Text(limits.checking ? "checking…" : limits.updated.map { "updated \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))" } ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash)
                Spacer()
                TweakButton(title: "Refresh") { limits.refresh() }
            }
            if !limits.status.isEmpty && !limits.limits.isEmpty { Text(limits.status).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.accent) }
        }
        .onAppear { limits.refreshIfStale(maxAge: 60) }
    }
}
