import Foundation

/// One preset shared by the editor and foreground App Intent in the same app.
/// A versioned key lets future migrations leave unknown data untouched.
enum PhotoSettingsStore {
    static let key = "Guangse.editorSettings.v1"
    static func load(from defaults: UserDefaults = .standard) -> EditorSettings {
        guard let data = defaults.data(forKey: key),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return EditorSettings() }
        if object["preserveHDR"] == nil { object["preserveHDR"] = true }
        guard let migrated = try? JSONSerialization.data(withJSONObject: object),
              let settings = try? JSONDecoder().decode(EditorSettings.self, from: migrated) else { return EditorSettings() }
        return settings
    }
    static func save(_ settings: EditorSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
