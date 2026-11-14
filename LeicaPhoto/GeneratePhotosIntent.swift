import AppIntents
import UniformTypeIdentifiers

struct GeneratePhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "一键生成并保存到相册"
    static var description = IntentDescription("接收相册分享的照片，按光色最近使用的 AI 和滤镜设置生成 PNG 并自动保存到相册。处理时打开光色以保留完整画质。", categoryName: "照片处理")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "照片", supportedTypeIdentifiers: ["public.image"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var photos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("生成 \(\.$photos) 并保存到相册")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let inputs = photos
        _ = try await PhotoEditorModel.shared.generateSharedPhotos(count: inputs.count) { index in
            // Only materialize one input at a time; don't decode, resize, or
            // re-encode the shared file before handing it to the normal pipeline.
            await Task.detached(priority: .userInitiated) { inputs[index].data }.value
        }
        return .result()
    }
}

struct GuangseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GeneratePhotosIntent(),
                    phrases: ["用\(.applicationName)生成照片"],
                    shortTitle: "一键生成照片", systemImageName: "camera.filters")
    }
    static var shortcutTileColor: ShortcutTileColor { .orange }
}
