#if DEBUG
import CryptoKit
import Foundation

/// Contract-level receiver used by Simulator tests. It deliberately does not
/// contain inference or production networking; it validates the same join and
/// artifact rules expected from the backend receiver.
struct TestJoinedFrame: Equatable, Sendable {
    let frame: CapturedFrameMetadata
    let motion: CameraMotionSample?
    let missingReason: String?
}

actor TestFieldReceiver {
    enum Failure: Error, Equatable {
        case injected
        case hashMismatch
        case lengthMismatch
    }

    private let maximumMotionAgeUs: Int64
    private var latestMotion: CameraMotionSample?
    private var injectedFailure: Failure?

    init(maximumMotionAgeUs: Int64 = 50_000) {
        self.maximumMotionAgeUs = maximumMotionAgeUs
    }

    func inject(_ failure: Failure?) {
        injectedFailure = failure
    }

    func ingest(motion: CameraMotionSample) throws {
        if let injectedFailure { throw injectedFailure }
        latestMotion = motion
    }

    func ingest(frame: CapturedFrameMetadata) throws -> TestJoinedFrame {
        if let injectedFailure { throw injectedFailure }

        guard let motion = latestMotion, motion.tUs <= frame.tUs else {
            return TestJoinedFrame(
                frame: frame,
                motion: nil,
                missingReason: frame.poseMissingReason ?? "no_motion_sample_at_or_before_frame"
            )
        }

        let age = frame.tUs - motion.tUs
        guard age <= maximumMotionAgeUs else {
            return TestJoinedFrame(
                frame: frame,
                motion: nil,
                missingReason: frame.poseMissingReason ?? "motion_sample_older_than_50ms"
            )
        }

        return TestJoinedFrame(frame: frame, motion: motion, missingReason: nil)
    }

    func validateArtifact(fileURL: URL, byteCount: Int64, sha256: String) throws {
        if let injectedFailure { throw injectedFailure }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actualByteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualByteCount == byteCount else { throw Failure.lengthMismatch }

        let handle = try FileHandle(forReadingFrom: fileURL)
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        try handle.close()
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == sha256.lowercased() else { throw Failure.hashMismatch }
    }
}
#endif
