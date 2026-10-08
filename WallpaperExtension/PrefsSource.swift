import Foundation

/// Turns the app-written `phosphene-prefs.json` into `prefsLoaded` events: once at
/// launch and again on every `com.taru.tweaks.wallpaper.prefsChanged` notification.
enum PrefsSource {
    private static var prefsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phosphene-prefs.json")
    }

    static func start() {
        postCurrent()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in PrefsSource.postCurrent() },
            "com.taru.tweaks.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    private static func postCurrent() {
        guard let data = try? Data(contentsOf: prefsURL) else { return } // written on the app's first launch
        do {
            let prefs = try JSONDecoder().decode(PlaybackPrefs.self, from: data)
            PlaybackStore.post(.prefsLoaded(prefs))
        } catch {
            extensionLog("[Prefs] Failed to decode prefs: \(error)")
        }
    }
}
