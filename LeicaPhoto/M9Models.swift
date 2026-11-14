import CoreML
import Foundation

/// Native Core ML execution of the three neural networks recovered from the APK.
/// Tensor layout and normalization belong to M9Pipeline; no color approximation
/// or replacement network is selected here.
final class M9Models: @unchecked Sendable {
    static let shared = M9Models()

    enum ModelError: LocalizedError {
        case unknownModel(String)
        case missingModel(String)
        case invalidInput(String, [Int], MLMultiArrayDataType)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .unknownModel(let name):
                return "未知的 M9 模型：\(name)"
            case .missingModel(let name):
                return "安装包缺少 M9 \(name) 模型，请重新安装完整版本。"
            case .invalidInput(let name, let shape, let type):
                return "M9 \(name) 输入格式不正确：\(shape)，类型 \(type.rawValue)"
            case .invalidOutput(let name):
                return "M9 \(name) 未返回有效图像。"
            }
        }
    }

    private let lock = NSLock()
    private var loaded: [String: MLModel] = [:]

    static func inputShape(for name: String) throws -> [Int] {
        switch name {
        case "low", "high": return [1, 4, 864, 1120]
        case "colorfix": return [1, 6, 544, 544]
        default: throw ModelError.unknownModel(name)
        }
    }

    func predict(_ name: String, input: MLMultiArray) throws -> MLMultiArray {
        let expected = try Self.inputShape(for: name)
        let shape = input.shape.map(\.intValue)
        guard shape == expected, input.dataType == .float32 else {
            throw ModelError.invalidInput(name, shape, input.dataType)
        }
        let model = try load(name)
        let features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
        let result = try model.prediction(from: features)
        guard let output = result.featureValue(for: "output")?.multiArrayValue,
              output.shape.map(\.intValue) == [1, 3, expected[2], expected[3]] else {
            throw ModelError.invalidOutput(name)
        }
        return output
    }

    /// Frees Core ML model caches when the editor closes or receives a memory warning.
    func releaseCachedModels() {
        lock.lock()
        loaded.removeAll()
        lock.unlock()
    }

    private func load(_ name: String) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loaded[name] { return existing }
        let resource = "M9_" + name
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let modelURL: URL
        if let compiled = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") {
            modelURL = compiled
        } else if let package = Bundle.main.url(forResource: resource, withExtension: "mlpackage") {
            modelURL = try MLModel.compileModel(at: package)
        } else {
            throw ModelError.missingModel(name)
        }
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        loaded[name] = model
        return model
    }
}
