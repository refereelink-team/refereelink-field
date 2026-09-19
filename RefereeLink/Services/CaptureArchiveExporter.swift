import Foundation
import ZIPFoundation

enum CaptureArchiveExportError: LocalizedError, Equatable {
    case sourceMissing
    case archiveCreationFailed

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "The capture archive is no longer available."
        case .archiveCreationFailed:
            return "The capture ZIP could not be created."
        }
    }
}

nonisolated final class CaptureArchiveExporter: @unchecked Sendable {
    private let fileManager = FileManager.default

    func export(_ descriptor: CaptureArchiveDescriptor) async throws -> URL {
        try await Task.detached(priority: .utility) { [fileManager] in
            guard fileManager.fileExists(atPath: descriptor.url.path) else {
                throw CaptureArchiveExportError.sourceMissing
            }

            let zipURL = descriptor.url
                .deletingLastPathComponent()
                .appendingPathComponent("\(descriptor.id.uuidString).zip")
            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }

            do {
                let archive = try Archive(url: zipURL, accessMode: .create)
                let entries = try fileManager.subpathsOfDirectory(atPath: descriptor.url.path)
                    .filter { relativePath in
                        var isDirectory: ObjCBool = false
                        let path = descriptor.url.appendingPathComponent(relativePath).path
                        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                    }
                    .sorted()

                for relativePath in entries {
                    let compression: CompressionMethod = relativePath.hasPrefix("video/") ? .none : .deflate
                    try archive.addEntry(
                        with: relativePath,
                        relativeTo: descriptor.url,
                        compressionMethod: compression
                    )
                }
                return zipURL
            } catch {
                try? fileManager.removeItem(at: zipURL)
                throw error
            }
        }.value
    }
}
