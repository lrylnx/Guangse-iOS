import Foundation
import CoreImage

@main
struct ShareShortcutCheck {
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let run = root.appendingPathComponent("share-shortcut/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }
        let suite = "Guangse.ShareCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(PhotoSettingsStore.load(from: defaults) == EditorSettings(), "fresh install has predictable M9D preset")
        var preset = EditorSettings()
        preset.aiStrength = 0.42; preset.filterID = "leica_m9"; preset.filterStrength = 0.72
        preset.autoScene = false; preset.lux = 650; preset.cct = 7000; preset.zoom = 3.2; preset.parameters = false
        for mode in M9AIMode.allCases {
            preset.mode = mode
            PhotoSettingsStore.save(preset, to: defaults)
            check(PhotoSettingsStore.load(from: UserDefaults(suiteName: suite)!) == preset, "M9/M9D mode and all effect parameters survive a new defaults instance")
        }
        defaults.set(Data([0, 1, 2]), forKey: PhotoSettingsStore.key)
        check(PhotoSettingsStore.load(from: defaults) == EditorSettings(), "invalid preset data falls back without crashing")
        let file = run.appendingPathComponent("original.jpg")
        let image = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 480, y: 320), "inputColor0": CIColor(red: 0.1, green: 0.3, blue: 0.7), "inputColor1": CIColor(red: 0.9, green: 0.6, blue: 0.2)])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 480, height: 320))
        try PhotoExport.writeJPEG(image, to: file, context: FilterEngine.context, quality: 1)
        let bytes = try Data(contentsOf: file)
        let inputs = [bytes, Data([1, 2, 3]), bytes]
        var received: [PhotoSource] = []
        var events: [Double] = []
        let intake = try await SharedPhotoIntake.receive(count: inputs.count, directory: run, load: { inputs[$0] }, didRead: { source, thumbnail in
            check(max(thumbnail.width, thumbnail.height) <= 160, "small thumbnail is separate from source")
            received.append(source)
        }, progress: { fraction, _ in events.append(fraction) })
        check(intake.sources.count == 2 && intake.unreadable == [1], "bad shared item does not drop later valid items")
        check(received == intake.sources && Set(received.map(\.id)).count == 2, "valid photos are delivered once, in order, with independent identities")
        for source in received {
            check(try Data(contentsOf: source.url) == bytes, "share intake preserves exact input JPEG bytes")
            let original = try FilterEngine.source(Data(contentsOf: source.url))
            check(original.extent == image.extent, "480px source is not replaced by 160px thumbnail")
        }
        check(events.last == 1 && zip(events, events.dropFirst()).allSatisfy { $0 <= $1 }, "intake progress is monotonic and reaches completion")
        let beforeCancel = try FileManager.default.contentsOfDirectory(atPath: run.path).count
        do {
            _ = try await SharedPhotoIntake.receive(count: 1, directory: run, load: { _ in throw CancellationError() }, didRead: { _, _ in fatalError("cancelled input delivered") }, progress: { _, _ in })
            fatalError("cancelled intake succeeded")
        } catch is CancellationError { }
        check(try FileManager.default.contentsOfDirectory(atPath: run.path).count == beforeCancel, "cancelled input leaves no partial file and retains completed sources")
        let processor = PhotoProcessor(directory: run)
        let settings = EditorSettings()
        let quick = try await processor.export(received[0], settings: settings) { _, _ in }
        let album = try await processor.export(PhotoSource(id: UUID(), url: file), settings: settings) { _, _ in }
        let a = try FilterEngine.source(Data(contentsOf: quick))
        let b = try FilterEngine.source(Data(contentsOf: album))
        check(a.extent == image.extent && a.extent == b.extent, "share and album outputs retain identical M9D source dimensions")
        check(M9Pipeline.rgba(a) == M9Pipeline.rgba(b), "shared photo plus same preset gives pixel-identical full PNG to album import")
        await processor.clear()
        print("ALL SHARE INTAKE / PRESET / PIPELINE CHECKS PASSED")
    }
}
