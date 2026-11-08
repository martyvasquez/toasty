import Foundation

/// Finds the speech models bundled in Contents/Resources/SpeechModels.
/// They are fetched at build time by scripts/fetch-speech-models.sh (pinned
/// revision + sha256); Toasty never downloads anything at runtime.
///
/// The full checksum is verified by the fetch script; here only the size is
/// checked (hashing 730 MB at every launch would cost seconds).
nonisolated enum SpeechModels {
    enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case wrongSize(String, expected: Int, found: Int)

        var description: String {
            switch self {
            case .missing(let file): "The speech model \(file) is missing from the app."
            case .wrongSize(let file, let expected, let found):
                "The speech model \(file) is damaged (\(found) bytes, expected \(expected))."
            }
        }
    }

    /// The app's bundled models folder.
    static var bundledFolder: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent(DictationConfig.modelsFolder, isDirectory: true)
    }

    static func url(for model: DictationConfig.BundledModel, in folder: URL = bundledFolder) throws -> URL {
        let url = folder.appendingPathComponent(model.file)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            throw Failure.missing(model.file)
        }
        guard size == model.bytes else { throw Failure.wrongSize(model.file, expected: model.bytes, found: size) }
        return url
    }
}
