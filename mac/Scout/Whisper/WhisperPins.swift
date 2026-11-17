import CryptoKit
import Foundation

nonisolated enum WhisperPins {
    struct File: Hashable, Sendable {
        var path: String
        var bytes: Int64
        var sha256: String
        var url: URL
    }

    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    static let tokenizerRevision = "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
    static let installName = "\(variant)@\(modelRevision.prefix(12))"
    static let displayName = "Whisper large-v3-turbo"
    static let engineName = "WhisperKit.large-v3-turbo"

    static let modelBase = "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/\(modelRevision)/\(variant)/"
    static let tokenizerBase = "https://huggingface.co/openai/whisper-large-v3-turbo/resolve/\(tokenizerRevision)/"

    static let files: [File] = modelFiles.map { pin(base: modelBase, $0) } + tokenizerFiles.map { pin(base: tokenizerBase, $0) }

    static let totalBytes: Int64 = files.reduce(0) { $0 + $1.bytes }

    private static func pin(base: String, _ entry: (String, Int64, String)) -> File {
        File(path: entry.0, bytes: entry.1, sha256: entry.2, url: URL(string: base + entry.0)!)
    }

    private static let modelFiles: [(String, Int64, String)] = [
        ("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "0dd9f529c744ed3c6be67f699588f7aadc4f366b5b7301dc31bd3f199944fbcc"),
        ("AudioEncoder.mlmodelc/coremldata.bin", 348, "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
        ("AudioEncoder.mlmodelc/metadata.json", 1_974, "2cd0538f90a012de3f07d38669026d527490eff1dcfd2479a81c48206a90f0a2"),
        ("AudioEncoder.mlmodelc/model.mil", 7_589_739, "ef5a252831e61bb91d6547fe1add3d0658895b518d47d70004322b40a2192668"),
        ("AudioEncoder.mlmodelc/weights/weight.bin", 421_968_768, "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
        ("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
        ("MelSpectrogram.mlmodelc/coremldata.bin", 329, "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a"),
        ("MelSpectrogram.mlmodelc/metadata.json", 1_850, "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
        ("MelSpectrogram.mlmodelc/model.mil", 10_143, "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
        ("MelSpectrogram.mlmodelc/weights/weight.bin", 373_376, "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
        ("TextDecoder.mlmodelc/analytics/coremldata.bin", 243, "4b5119bdc621c3c494f63846dc3ed43852e88826fc3b6345d42272d4b7e67724"),
        ("TextDecoder.mlmodelc/coremldata.bin", 633, "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd"),
        ("TextDecoder.mlmodelc/metadata.json", 4_924, "e3ce6d83884552ffcc2c34799e8e1211dcda59f1aaea5a79bf988c6cd16abbf0"),
        ("TextDecoder.mlmodelc/model.mil", 217_177, "ebaf8566f367b6465276c3ed57bb99063888fa955b67828585bf19db24c85f56"),
        ("TextDecoder.mlmodelc/weights/weight.bin", 203_199_860, "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
        ("TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", 243, "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1"),
        ("TextDecoderContextPrefill.mlmodelc/coremldata.bin", 380, "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e"),
        ("TextDecoderContextPrefill.mlmodelc/metadata.json", 2_240, "eb88dc350fa6748a8bc3fa5fb10958152c138752ebbbac1824d2f99b4c9fc068"),
        ("TextDecoderContextPrefill.mlmodelc/model.mil", 4_092, "990ff5052fd817e28ba7c34d9d06d324c69c7c0630b6eaac9cfdf08329dbcb34"),
        ("TextDecoderContextPrefill.mlmodelc/weights/weight.bin", 12_288_192, "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd"),
        ("config.json", 1_149, "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
        ("generation_config.json", 2_767, "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"),
    ]

    private static let tokenizerFiles: [(String, Int64, String)] = [
        ("tokenizer.json", 2_710_337, "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd"),
        ("tokenizer_config.json", 282_843, "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
    ]
}

nonisolated enum WhisperModelFiles {
    struct Mismatch: LocalizedError {
        var path: String
        var detail: String

        var errorDescription: String? { "\(path) \(detail)" }
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    static func isComplete(_ folder: URL) -> Bool {
        WhisperPins.files.allSatisfy { size(of: folder.appendingPathComponent($0.path)) == $0.bytes }
    }

    static func diskUsage(of folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func verify(_ file: WhisperPins.File, in folder: URL, progress: (Int64) -> Void = { _ in }) throws {
        let url = folder.appendingPathComponent(file.path)
        guard size(of: url) == file.bytes else {
            throw Mismatch(path: file.path, detail: "has \(size(of: url) ?? 0) bytes, expected \(file.bytes)")
        }
        let digest = try sha256(of: url, progress: progress)
        guard digest == file.sha256 else {
            NSLog("[scout-whisper] rejected %@: sha256 %@, expected %@", file.path, digest, file.sha256)
            throw Mismatch(path: file.path, detail: "failed its SHA-256 check")
        }
    }

    static func sha256(of url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            progress(Int64(chunk.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
