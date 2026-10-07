import Foundation
import AppKit

struct StartupItem: Identifiable, Equatable {
    var id: String { kind + ":" + key }
    let kind: String
    let key: String
    let name: String
    let path: String
    var enabled: Bool
    let editable: Bool
}

final class StartupStore: ObservableObject {
    static let shared = StartupStore()
    @Published var items: [StartupItem] = []
    private let disabledLogin = "taskmanager.disabledLoginItems"

    func shell(_ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var out: [StartupItem] = []
            let names = shell(["/usr/bin/osascript", "-e", "tell application \"System Events\" to get the name of every login item"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let paths = shell(["/usr/bin/osascript", "-e", "tell application \"System Events\" to get the path of every login item"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let n = names.components(separatedBy: ", "), p = paths.components(separatedBy: ", ")
            for (i, name) in n.enumerated() where !name.isEmpty {
                out.append(StartupItem(kind: "login", key: name, name: name, path: i < p.count ? p[i] : "", enabled: true, editable: true))
            }
            for (name, path) in (UserDefaults.standard.dictionary(forKey: disabledLogin) as? [String: String]) ?? [:] where !n.contains(name) {
                out.append(StartupItem(kind: "login", key: name, name: name, path: path, enabled: false, editable: true))
            }
            let uid = getuid()
            let disabledText = shell(["/bin/launchctl", "print-disabled", "gui/\(uid)"])
            for (dir, kind, editable) in [(NSHomeDirectory() + "/Library/LaunchAgents", "agent", true), ("/Library/LaunchAgents", "system agent", false), ("/Library/LaunchDaemons", "daemon", false)] {
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
                    let full = dir + "/" + f
                    guard let d = NSDictionary(contentsOfFile: full) as? [String: Any], let label = d["Label"] as? String else { continue }
                    let prog = (d["Program"] as? String) ?? ((d["ProgramArguments"] as? [String])?.first ?? "")
                    let off = disabledText.contains("\"\(label)\" => disabled") || (d["Disabled"] as? Bool ?? false)
                    out.append(StartupItem(kind: kind, key: label, name: label, path: prog.isEmpty ? full : prog, enabled: !off, editable: editable))
                }
            }
            DispatchQueue.main.async { self.items = out }
        }
    }

    func set(_ item: StartupItem, enabled: Bool) {
        DispatchQueue.global().async { [self] in
            if item.kind == "login" {
                var disabled = (UserDefaults.standard.dictionary(forKey: disabledLogin) as? [String: String]) ?? [:]
                if enabled {
                    _ = shell(["/usr/bin/osascript", "-e", "tell application \"System Events\" to make login item at end with properties {path:\"\(item.path)\", hidden:true}"])
                    disabled[item.name] = nil
                } else {
                    _ = shell(["/usr/bin/osascript", "-e", "tell application \"System Events\" to delete (every login item whose name is \"\(item.name)\")"])
                    disabled[item.name] = item.path
                }
                UserDefaults.standard.set(disabled, forKey: disabledLogin)
            } else if item.kind == "agent" {
                let uid = getuid()
                let plist = NSHomeDirectory() + "/Library/LaunchAgents/" + ((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents"))?.first { (NSDictionary(contentsOfFile: NSHomeDirectory() + "/Library/LaunchAgents/" + $0)?["Label"] as? String) == item.key } ?? "")
                if enabled {
                    _ = shell(["/bin/launchctl", "enable", "gui/\(uid)/\(item.key)"])
                    _ = shell(["/bin/launchctl", "bootstrap", "gui/\(uid)", plist])
                } else {
                    _ = shell(["/bin/launchctl", "bootout", "gui/\(uid)/\(item.key)"])
                    _ = shell(["/bin/launchctl", "disable", "gui/\(uid)/\(item.key)"])
                }
            }
            DispatchQueue.main.async { self.reload() }
        }
    }
}
