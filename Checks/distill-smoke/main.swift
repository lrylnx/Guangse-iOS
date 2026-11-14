import Foundation
import CoreImage
import CoreML

// Local macOS verification of the style-770 (M9D) path that now ships in the app.
// Uses the same non-UI sources as the iOS target. Resources are read from
// Bundle.main, so this must run from inside a .app bundle.

func require(_ test: Bool, _ message: String) {
    precondition(test, "FAIL " + message)
    print("PASS " + message)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sampleURL = URL(fileURLWithPath: CommandLine.arguments[2])

// 1. Tile offsets must reproduce "min(i*core, length-core)" including the
//    overwrite-last-overlap rule from the Android TilePixels code.
require(M9DistillPipeline.offsets(length: 1000, core: 1024) == [0], "offset single tile when length <= core")
require(M9DistillPipeline.offsets(length: 2048, core: 1024) == [0, 1024], "offset exact halves")
require(M9DistillPipeline.offsets(length: 3000, core: 1024) == [0, 1024, 1976], "offset overlapping tail")
require(M9DistillPipeline.offsets(length: 1200, core: 800) == [0, 400], "offset non-square width")

// 2. Byte rounding: ties away from zero on non-negative values, clamped.
require(M9DistillPipeline.encode(0) == 0 && M9DistillPipeline.encode(1) == 255, "encode clamps")
require(M9DistillPipeline.encode(127.5 / 255) == 128, "encode rounds .5 up")
require(M9DistillPipeline.encode(-1) == 0 && M9DistillPipeline.encode(2) == 255, "encode out-of-range")
require(M9DistillPipeline.encode(.nan) == 0, "encode rejects NaN")

// 3. Full photo through the real model + fixed 200/5500/1 post.
let sourceData = try Data(contentsOf: sampleURL)
let image = try FilterEngine.source(sourceData, maxDimension: 640)
let start = Date()
let output = try M9DistillPipeline.process(image) { fraction, stage in
    if stage.hasPrefix("M9D 风格处理") { print(String(format: "%.0f%% %@", fraction * 100, stage)) }
}
require(output.extent == image.extent, "output keeps source dimensions")
let bytes = M9Pipeline.rgba(output)
require(bytes.count == Int(image.extent.width * image.extent.height) * 4, "output byte count")
require(bytes.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 }, "output alpha opaque")
require(bytes != M9Pipeline.rgba(image), "model plus post actually changed pixels")
print(String(format: "640 long edge took %.1f s", Date().timeIntervalSince(start)))

// 4. The post stage must be exactly the snapshot tables at the wrapper's fixed
//    values, so the documented approximation cannot silently drift.
let styled = try M9DistillPipeline.styled(image) { _,_ in }
let post = try M9DistillPost.apply(styled)
let w = Int(styled.extent.width), h = Int(styled.extent.height)
let explicit = M9Pipeline.image(try M9Parameters.apply(M9Pipeline.rgba(styled), width: w, height: h,
                                                     lux: M9DistillPost.lux, cct: M9DistillPost.cct, zoom: M9DistillPost.zoom),
                               width: w, height: h)
require(M9Pipeline.rgba(post) == M9Pipeline.rgba(explicit), "post uses fixed 200/5500/1 tables")

// 5. Determinism: the same input must produce the same bytes twice.
let again = try M9DistillPipeline.process(image) { _,_ in }
require(M9Pipeline.rgba(again) == bytes, "deterministic across runs")

// 6. Multi-tile rectangle exercises the offset/overwrite path with two cores.
let wide = FilterEngine.normalized(image.transformed(by: CGAffineTransform(scaleX: 1200 / image.extent.width,
                                                                          y: 800 / image.extent.height)))
let wideOutput = try M9DistillPipeline.process(wide) { _,_ in }
require(wideOutput.extent.width == 1200 && wideOutput.extent.height == 800, "1200x800 two-tile geometry")
let wideBytes = M9Pipeline.rgba(wideOutput)
require(wideBytes != M9Pipeline.rgba(wide), "two-tile run changed pixels")

// 7. Cancellation must surface as CancellationError, not a partial image.
//    Mid-run cancellation uses the same Task.checkCancellation() points; a
//    pre-cancelled task verifies propagation without a timing race.
let task = Task { () -> CIImage in
    try M9DistillPipeline.process(image) { _,_ in }
}
task.cancel()
var cancelled = false
do { _ = try await task.value } catch is CancellationError { cancelled = true } catch { print("unexpected " + error.localizedDescription) }
require(cancelled, "cancellation propagates")

try PhotoExport.writeJPEG(post, to: root.appendingPathComponent("distill-v3-smoke.jpg"), context: FilterEngine.context, sourceData: sourceData)
print("ALL 770 SMOKE CHECKS PASSED")
