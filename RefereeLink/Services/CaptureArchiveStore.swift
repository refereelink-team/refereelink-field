import Foundation

nonisolated final class CaptureArchiveStore: @unchecked Sendable {
    private let fileManager = FileManager.default

    func list() -> [CaptureArchiveDescriptor] {
        guard let root = try? CaptureArchiveRecorder.archiveRoot(),
              let names = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.compactMap { url in
            guard url.pathExtension == "rlcapture",
                  let manifestData = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(CaptureSessionManifest.self, from: manifestData) else {
                return nil
            }
            return CaptureArchiveDescriptor(
                id: manifest.sessionId,
                url: url,
                createdAt: manifest.startedAt,
                sizeBytes: directorySize(url),
                lifecycle: manifest.lifecycle
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return enumerator.reduce(into: Int64(0)) { total, item in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }
}
