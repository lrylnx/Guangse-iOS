import Foundation
import CoreImage

func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var renders = 0
    private var stages: [String] = []
    func render() { lock.lock(); renders += 1; lock.unlock() }
    func progress(_ text: String) { lock.lock(); stages.append(text); lock.unlock() }
    func snapshot() -> (Int, [String]) { lock.lock(); defer { lock.unlock() }; return (renders, stages) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = root.appendingPathComponent("mode-cache/\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("source.png")
let image = CIImage(color: CIColor(red: 0.25, green: 0.4, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 67, height: 43))
try PhotoExport.writePNG(image, to: file, context: FilterEngine.context)
let source = PhotoSource(id: UUID(), url: file)
let processor = PhotoProcessor(directory: directory)
let done = DispatchSemaphore(value: 0)
Task.detached {
    do {
        var full = EditorSettings(); full.mode = .full
        var distill = full; distill.mode = .distill
        let memory = PreviewMemoryCache()
        var initial: [PreviewKey: CGImage] = [:]
        for settings in [full, distill] {
            let preview = try await processor.preview(source, settings: settings, original: false) { _, _ in }
            let key = PreviewKey(source: source, settings: settings, original: false)
            initial[key] = preview; memory.insert(preview, for: key)
        }
        let cached = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("ai-") }
        check(cached.count == 2, "M9 and M9D retain separate full-resolution AI files")
        for settings in [full, distill, full, distill] {
            let key = PreviewKey(source: source, settings: settings, original: false)
            check(memory.image(for: key) === initial[key], "returning to either mode uses exact ready memory preview")
        }
        memory.removeAll()
        for settings in [full, distill, full, distill] {
            let events = Events()
            let preview = try await processor.preview(source, settings: settings, original: false, willRender: { events.render() }) { _, text in events.progress(text) }
            check(events.snapshot().0 == 0 && events.snapshot().1.isEmpty, "after memory eviction either mode loads disk preview without generation/progress")
            let key = PreviewKey(source: source, settings: settings, original: false)
            check(M9Pipeline.rgba(CIImage(cgImage: preview)) == M9Pipeline.rgba(CIImage(cgImage: initial[key]!)), "each mode preserves its original preview pixels")
            let exportEvents = Events()
            let output = try await processor.export(source, settings: settings) { _, text in exportEvents.progress(text) }
            check(exportEvents.snapshot().1.contains("读取已生成效果"), "saving either mode reuses full-resolution AI without another inference")
            try FileManager.default.removeItem(at: output)
        }
        var changed = full; changed.cct = 6200; changed.autoScene = false
        let replacement = try FilterEngine.cgImage(image)
        memory.insert(replacement, for: PreviewKey(source: source, settings: changed, original: false))
        check(memory.image(for: PreviewKey(source: source, settings: distill, original: false)) == nil, "explicit memory release cleared previous entries")
        memory.insert(initial[PreviewKey(source: source, settings: distill, original: false)]!, for: PreviewKey(source: source, settings: distill, original: false))
        memory.insert(replacement, for: PreviewKey(source: source, settings: full, original: false))
        check(memory.image(for: PreviewKey(source: source, settings: distill, original: false)) != nil, "changing M9 settings cannot evict M9D memory preview")
        await processor.remove(source.id)
        check(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix("ai-") && !$0.hasPrefix("preview-") }, "remove clears both modes and their previews")
        try FileManager.default.removeItem(at: directory)
        print("ALL M9 / M9D MODE CACHE REGRESSION CHECKS PASSED")
    } catch { print("FAIL \(error)"); exit(1) }
    done.signal()
}
done.wait()
