import CoreML
import Foundation

/// The APK's `donor120/m9_distill.onnx` network, used by Android style 770.
final class M9DistillModel: @unchecked Sendable {
    static let shared = M9DistillModel()

    enum ModelError: LocalizedError {
        case missingModel
        case invalidInput
        case invalidOutput
        var errorDescription: String? {
            switch self {
            case .missingModel: return "安装包缺少 M9D 模型，请重新安装完整版本。"
            case .invalidInput: return "M9D 图像输入尺寸或数据类型不正确。"
            case .invalidOutput: return "M9D 未返回有效图像。"
            }
        }
    }

    private let lock = NSLock()
    private var loaded: MLModel?

    /// Inputs use RGB NCHW float32 in [0,1]. Native tiling adds a 96-pixel halo
    /// and forms lowres by rounded 2x2 reduction in the byte domain.
    func predict(lowres: MLMultiArray, full: MLMultiArray) throws -> MLMultiArray {
        let f = full.shape.map(\.intValue)
        let l = lowres.shape.map(\.intValue)
        guard full.dataType == .float32, lowres.dataType == .float32,
              f.count == 4, l.count == 4, f[0] == 1, f[1] == 3,
              f[2] >= 16, f[2] <= 1216, f[3] >= 16, f[3] <= 1216,
              f[2].isMultiple(of: 2), f[3].isMultiple(of: 2),
              l == [1, 3, f[2] / 2, f[3] / 2] else {
            throw ModelError.invalidInput
        }
        let model = try load()
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "lowres": MLFeatureValue(multiArray: lowres),
            "full": MLFeatureValue(multiArray: full)
        ])
        let result = try model.prediction(from: provider)
        guard let output = result.featureValue(for: "out")?.multiArrayValue,
              output.shape.map(\.intValue) == f else {
            throw ModelError.invalidOutput
        }
        return output
    }

    func releaseCachedModel() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    private func load() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let url: URL
        if let compiled = Bundle.main.url(forResource: "M9_distill", withExtension: "mlmodelc") {
            url = compiled
        } else if let package = Bundle.main.url(forResource: "M9_distill", withExtension: "mlpackage") {
            url = try MLModel.compileModel(at: package)
        } else {
            throw ModelError.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        loaded = model
        return model
    }
}
