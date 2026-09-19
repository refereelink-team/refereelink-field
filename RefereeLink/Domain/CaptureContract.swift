import Foundation

nonisolated enum CaptureSessionMode: String, Codable, CaseIterable, Sendable {
    case offline
    case realtime
}

nonisolated enum CaptureSessionLifecycle: String, Codable, Sendable {
    case prepared
    case recording
    case stopped
    case interrupted
    case failed
}

nonisolated enum TransportConnectionState: String, Codable, Sendable {
    case disabled
    case connecting
    case connected
    case reconnecting
    case failed
}

nonisolated struct CaptureClockAnchor: Codable, Equatable, Sendable {
    let wallClockUnixUs: Int64
    let systemUptimeUs: Int64
    let hostTimeUs: Int64?
    let uncertaintyUs: Int64
}

nonisolated struct CameraConfigurationSnapshot: Codable, Equatable, Sendable {
    let id: String
    let observedTimeUs: Int64
    let width: Int
    let height: Int
    let nominalFrameRate: Double
    let pixelFormat: String
    let cameraPosition: String
    let lensDescription: String
    let exposureDurationSeconds: Double?
    let iso: Double?
    let lensPosition: Double?
    let zoomFactor: Double?
    let stabilization: String
    let videoOrientation: String
}

nonisolated struct CameraMotionSample: Codable, Equatable, Sendable {
    let sampleId: Int
    let tUs: Int64
    let sourceTimestamp: Double?
    let pitch: Double?
    let yaw: Double?
    let roll: Double?
    let quaternionX: Double?
    let quaternionY: Double?
    let quaternionZ: Double?
    let quaternionW: Double?
    let rotationRateX: Double?
    let rotationRateY: Double?
    let rotationRateZ: Double?
    let gravityX: Double?
    let gravityY: Double?
    let gravityZ: Double?
    let userAccelerationX: Double?
    let userAccelerationY: Double?
    let userAccelerationZ: Double?
    let referenceFrame: String
    let status: String
    let error: String?
}

nonisolated struct CapturedFrameMetadata: Codable, Equatable, Sendable {
    let sessionId: UUID
    let streamEpoch: Int
    let frameId: Int
    let tUs: Int64
    let captureUnixUs: Int64
    let presentationTimestampValue: Int64?
    let presentationTimestampScale: Int32?
    let width: Int
    let height: Int
    let droppedFrameCount: Int
    let cameraConfigurationId: String
    let cameraMotionSampleId: Int?
    let cameraMotionAgeUs: Int64?
    let poseMissingReason: String?
}

nonisolated struct DockDiagnosticEvent: Codable, Equatable, Sendable {
    let sessionId: UUID
    let tUs: Int64
    let identifier: UUID?
    let accessoryName: String?
    let hardwareModel: String?
    let firmwareVersion: String?
    let connectionState: String
    let motionStreamStatus: String
    let motionSampleCount: Int
    let error: String?
}

nonisolated struct TransportStatus: Codable, Equatable, Sendable {
    let state: TransportConnectionState
    let streamEpoch: Int
    let sentFrameCount: Int
    let sentMotionCount: Int
    let droppedFrameCount: Int
    let lastError: String?
}

nonisolated struct CaptureSessionManifest: Codable, Equatable, Sendable {
    let schemaVersion: String
    let sessionId: UUID
    let deviceId: UUID
    let mode: CaptureSessionMode
    let lifecycle: CaptureSessionLifecycle
    let startedAt: Date
    let stoppedAt: Date?
    let videoRelativePath: String?
    let metadataRelativePaths: [String]
    let clockAnchors: [CaptureClockAnchor]
    let videoWidth: Int
    let videoHeight: Int
    let videoFrameRate: Double
    let videoBitrate: Int
    let sha256: [String: String]
    let notes: [String]

    static func initial(
        sessionId: UUID,
        deviceId: UUID,
        mode: CaptureSessionMode,
        startedAt: Date,
        clockAnchors: [CaptureClockAnchor]
    ) -> CaptureSessionManifest {
        CaptureSessionManifest(
            schemaVersion: "1.0",
            sessionId: sessionId,
            deviceId: deviceId,
            mode: mode,
            lifecycle: .recording,
            startedAt: startedAt,
            stoppedAt: nil,
            videoRelativePath: "video/video.mp4",
            metadataRelativePaths: [
                "metadata/frames.ndjson",
                "metadata/motion.ndjson",
                "metadata/dock.ndjson",
                "metadata/events.ndjson"
            ],
            clockAnchors: clockAnchors,
            videoWidth: 1280,
            videoHeight: 720,
            videoFrameRate: 30,
            videoBitrate: 4_000_000,
            sha256: [:],
            notes: []
        )
    }
}

nonisolated enum CaptureClock {
    static func nowAnchor() -> CaptureClockAnchor {
        let wall = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        return CaptureClockAnchor(
            wallClockUnixUs: Int64(wall * 1_000_000),
            systemUptimeUs: Int64(uptime * 1_000_000),
            hostTimeUs: nil,
            uncertaintyUs: 1_000
        )
    }

    static func sessionTimeUs(sourceTimestamp: TimeInterval, anchor: CaptureClockAnchor) -> Int64 {
        Int64(sourceTimestamp * 1_000_000) - anchor.systemUptimeUs
    }

    static func unixDate(from sourceTimestamp: TimeInterval, anchor: CaptureClockAnchor) -> Date {
        Date(timeIntervalSince1970: Double(anchor.wallClockUnixUs) / 1_000_000 +
             sourceTimestamp - Double(anchor.systemUptimeUs) / 1_000_000)
    }
}
