import Foundation

/// One preset shared by the editor and foreground App Intent in the same app.
/// A versioned key lets future migrations leave unknown data untouched.
enum PhotoSettingsStore {
    static let key = "Guangse.editorSettings.v1"
    static func load(from defaults: UserDefaults = .standard) -> EditorSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(EditorSettings.self, from: data) else { return EditorSettings() }
        return settings
    }
    static func save(_ settings: EditorSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
