import AVFoundation
import CryptoKit
import Foundation
import os

struct CaptureArchiveDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    let createdAt: Date
    let sizeBytes: Int64
    let lifecycle: CaptureSessionLifecycle
}

nonisolated final class CaptureArchiveRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.refereelink.capture-recorder")
    private let logger = Logger(
        subsystem: "io.github.refereelink-team.RefereeLink",
        category: "CaptureRecorder"
    )
    private let fileManager = FileManager.default
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var framesFile: FileHandle?
    private var motionFile: FileHandle?
    private var dockFile: FileHandle?
    private var eventsFile: FileHandle?
    private var sessionId: UUID?
    private var deviceId: UUID
    private var mode: CaptureSessionMode = .offline
    private var archiveURL: URL?
    private var manifest: CaptureSessionManifest?
    private var hasStartedWriter = false
    private var firstPresentationTime: CMTime?
    private var lastFrame: CapturedFrameMetadata?
    private var stopped = false

    init(deviceId: UUID = CaptureArchiveRecorder.loadOrCreateDeviceId()) {
        self.deviceId = deviceId
    }

    func start(mode: CaptureSessionMode) throws -> UUID {
        try sync {
            guard sessionId == nil else { throw CaptureArchiveError.alreadyRecording }

            let id = UUID()
            let root = try Self.archiveRoot().appendingPathComponent("\(id.uuidString).rlcapture", isDirectory: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("video"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("metadata"), withIntermediateDirectories: true)

            self.sessionId = id
            self.mode = mode
            self.archiveURL = root
            self.stopped = false
            self.manifest = .initial(
                sessionId: id,
                deviceId: deviceId,
                mode: mode,
                startedAt: Date(),
                clockAnchors: [CaptureClock.nowAnchor()]
            )
            let metadataFiles = [
                root.appendingPathComponent("metadata/frames.ndjson"),
                root.appendingPathComponent("metadata/motion.ndjson"),
                root.appendingPathComponent("metadata/dock.ndjson"),
                root.appendingPathComponent("metadata/events.ndjson")
            ]
            for fileURL in metadataFiles {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CaptureArchiveError.fileCreationFailed(fileURL.path)
                }
            }
            framesFile = try FileHandle(forWritingTo: metadataFiles[0])
            motionFile = try FileHandle(forWritingTo: metadataFiles[1])
            dockFile = try FileHandle(forWritingTo: metadataFiles[2])
            eventsFile = try FileHandle(forWritingTo: metadataFiles[3])
            try writeManifest(lifecycle: .recording)
            logger.info("Capture archive started: session=\(id.uuidString, privacy: .public), mode=\(mode.rawValue, privacy: .public)")
            return id
        }
    }

    func append(_ sample: CameraFrameSample, metadata: CapturedFrameMetadata) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.sessionId == metadata.sessionId else { return }
            do {
                try self.configureWriterIfNeeded(sample.sampleBuffer)
                guard let writerInput = self.writerInput, writerInput.isReadyForMoreMediaData else {
                    self.writeEvent(["type": "recording_backpressure", "frame_id": metadata.frameId])
                    self.finishWithError("The local video writer could not keep up with the camera.")
                    return
                }
                if writerInput.append(sample.sampleBuffer) {
                    self.lastFrame = metadata
                    self.writeJSON(metadata, to: self.framesFile)
                } else {
                    self.finishWithError(self.writer?.error?.localizedDescription ?? "The local video writer rejected a frame.")
                }
            } catch {
                self.finishWithError(error.localizedDescription)
            }
        }
    }

    func appendMotion(_ sample: CameraMotionSample) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.writeJSON(sample, to: self.motionFile)
        }
    }

    func appendDock(_ event: DockDiagnosticEvent) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.writeJSON(event, to: self.dockFile)
        }
    }

    func stop(lifecycle: CaptureSessionLifecycle = .stopped) async -> CaptureArchiveDescriptor? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let sessionId = self.sessionId else {
                    continuation.resume(returning: nil)
                    return
                }
                self.stopped = true
                self.writerInput?.markAsFinished()
                let writer = self.writer
                let finish: () -> Void = {
                    self.closeFiles()
                    let descriptor = self.finalizeManifest(sessionId: sessionId, lifecycle: lifecycle)
                    self.writer = nil
                    self.writerInput = nil
                    self.sessionId = nil
                    self.archiveURL = nil
                    self.manifest = nil
                    self.hasStartedWriter = false
                    self.firstPresentationTime = nil
                    self.lastFrame = nil
                    continuation.resume(returning: descriptor)
                }
                guard let writer, writer.status == .writing else {
                    finish()
                    return
                }
                writer.finishWriting(completionHandler: finish)
            }
        }
    }

    func isRecording() -> Bool {
        queue.sync { sessionId != nil && !stopped }
    }

    private func configureWriterIfNeeded(_ sampleBuffer: CMSampleBuffer) throws {
        guard !hasStartedWriter else { return }
        guard let sessionId, let archiveURL else { throw CaptureArchiveError.notRecording }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw CaptureArchiveError.invalidVideoFormat
        }

        let outputURL = archiveURL.appendingPathComponent("video/video.mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1280,
                AVVideoHeightKey: 720,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureArchiveError.writerConfigurationFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw CaptureArchiveError.writerConfigurationFailed
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: pts)
        self.writer = writer
        self.writerInput = input
        self.firstPresentationTime = pts
        self.hasStartedWriter = true
        logger.info("Video writer started: session=\(sessionId.uuidString, privacy: .public), sourceSize=\(dimensions.width, privacy: .public)x\(dimensions.height, privacy: .public)")
    }

    private func finishWithError(_ message: String) {
        logger.error("Capture archive failed: \(message, privacy: .public)")
        writeEvent(["type": "capture_failed", "message": message])
        stopped = true
        writerInput?.markAsFinished()
    }

    private func finalizeManifest(sessionId: UUID, lifecycle: CaptureSessionLifecycle) -> CaptureArchiveDescriptor? {
        guard let archiveURL else { return nil }
        let files = (try? fileManager.subpathsOfDirectory(atPath: archiveURL.path)) ?? []
        var hashes: [String: String] = [:]
        for relativePath in files {
            let url = archiveURL.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: url.path), let hash = try? Self.sha256(url: url) else { continue }
            hashes[relativePath] = hash
        }

        var finalManifest = manifest ?? .initial(
            sessionId: sessionId,
            deviceId: deviceId,
            mode: mode,
            startedAt: Date(),
            clockAnchors: [CaptureClock.nowAnchor()]
        )
        finalManifest = CaptureSessionManifest(
            schemaVersion: finalManifest.schemaVersion,
            sessionId: finalManifest.sessionId,
            deviceId: finalManifest.deviceId,
            mode: finalManifest.mode,
            lifecycle: lifecycle,
            startedAt: finalManifest.startedAt,
            stoppedAt: Date(),
            videoRelativePath: finalManifest.videoRelativePath,
            metadataRelativePaths: finalManifest.metadataRelativePaths,
            clockAnchors: finalManifest.clockAnchors,
            videoWidth: lastFrame?.width ?? 1280,
            videoHeight: lastFrame?.height ?? 720,
            videoFrameRate: 30,
            videoBitrate: 4_000_000,
            sha256: hashes,
            notes: lastFrame == nil ? ["No video frame was accepted before the session stopped."] : []
        )
        manifest = finalManifest
        try? writeManifest(lifecycle: lifecycle)
        let size = (try? fileManager.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return CaptureArchiveDescriptor(id: sessionId, url: archiveURL, createdAt: finalManifest.startedAt, sizeBytes: size, lifecycle: lifecycle)
    }

    private func writeManifest(lifecycle: CaptureSessionLifecycle) throws {
        guard let archiveURL, var manifest else { return }
        if manifest.lifecycle != lifecycle {
            manifest = CaptureSessionManifest(
                schemaVersion: manifest.schemaVersion,
                sessionId: manifest.sessionId,
                deviceId: manifest.deviceId,
                mode: manifest.mode,
                lifecycle: lifecycle,
                startedAt: manifest.startedAt,
                stoppedAt: lifecycle == .recording ? nil : Date(),
                videoRelativePath: manifest.videoRelativePath,
                metadataRelativePaths: manifest.metadataRelativePaths,
                clockAnchors: manifest.clockAnchors,
                videoWidth: manifest.videoWidth,
                videoHeight: manifest.videoHeight,
                videoFrameRate: manifest.videoFrameRate,
                videoBitrate: manifest.videoBitrate,
                sha256: manifest.sha256,
                notes: manifest.notes
            )
            self.manifest = manifest
        }
        let data = try JSONEncoder.refereeLink.encode(manifest)
        try data.write(to: archiveURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func writeEvent(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let eventsFile else { return }
        eventsFile.write(data)
        eventsFile.write(Data([0x0A]))
    }

    private func writeJSON<T: Encodable>(_ object: T, to file: FileHandle?) {
        guard let file, let data = try? JSONEncoder.refereeLink.encode(object) else { return }
        file.write(data)
        file.write(Data([0x0A]))
    }

    private func closeFiles() {
        [framesFile, motionFile, dockFile, eventsFile].forEach { try? $0?.close() }
        framesFile = nil
        motionFile = nil
        dockFile = nil
        eventsFile = nil
    }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }

    static func archiveRoot() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("CaptureArchives", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try? excluded.setResourceValues(values)
        return root
    }

    static func loadOrCreateDeviceId() -> UUID {
        let key = "RefereeLink.deviceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    private static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        try handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum CaptureArchiveError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case invalidVideoFormat
    case writerConfigurationFailed
    case fileCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A capture session is already recording."
        case .notRecording: return "No capture session is recording."
        case .invalidVideoFormat: return "The camera returned an invalid video format."
        case .writerConfigurationFailed: return "The local video writer could not be configured."
        case let .fileCreationFailed(path): return "The capture metadata file could not be created: \(path)"
        }
    }
}

extension JSONEncoder {
    nonisolated static let refereeLink: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
