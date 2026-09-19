import Foundation

nonisolated enum GimbalConnectionState: Equatable, Sendable {
    case waiting
    case docked
    case undocked
    case unsupported
    case failed
}

nonisolated enum CameraCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case ready
    case running
    case denied
    case failed
}

nonisolated enum MotionStreamStatus: Equatable, Sendable {
    case waitingForFirstSample
    case streaming
    case ended
    case failed(String)

    var hasReceivedSample: Bool {
        if case .streaming = self {
            return true
        }
        return false
    }

    var errorMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

nonisolated enum CameraMotionReferenceFrame: String, Equatable, Sendable {
    case xArbitraryZVertical

    var displayName: String {
        switch self {
        case .xArbitraryZVertical:
            return "启动相对坐标"
        }
    }
}

nonisolated enum CameraMotionStatus: Equatable, Sendable {
    case waitingForFirstSample
    case streaming
    case unavailable
    case failed(String)

    var hasReceivedSample: Bool {
        if case .streaming = self {
            return true
        }
        return false
    }

    var errorMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

nonisolated enum CameraMotionTimestamp {
    static func date(
        from sourceTimestamp: TimeInterval,
        now: Date,
        systemUptime: TimeInterval
    ) -> Date {
        now.addingTimeInterval(sourceTimestamp - systemUptime)
    }
}

nonisolated struct CameraMotionSnapshot: Equatable, Sendable {
    let pitch: Double?
    let yaw: Double?
    let roll: Double?
    let rotationRateX: Double?
    let rotationRateY: Double?
    let rotationRateZ: Double?
    let sourceTimestamp: TimeInterval?
    let timestamp: Date?
    let sampleCount: Int
    let status: CameraMotionStatus
    let referenceFrame: CameraMotionReferenceFrame
    let errorMessage: String?
    let quaternionX: Double?
    let quaternionY: Double?
    let quaternionZ: Double?
    let quaternionW: Double?
    let gravityX: Double?
    let gravityY: Double?
    let gravityZ: Double?
    let userAccelerationX: Double?
    let userAccelerationY: Double?
    let userAccelerationZ: Double?

    init(
        pitch: Double?,
        yaw: Double?,
        roll: Double?,
        rotationRateX: Double?,
        rotationRateY: Double?,
        rotationRateZ: Double?,
        sourceTimestamp: TimeInterval?,
        timestamp: Date?,
        sampleCount: Int,
        status: CameraMotionStatus,
        referenceFrame: CameraMotionReferenceFrame,
        errorMessage: String?,
        quaternionX: Double? = nil,
        quaternionY: Double? = nil,
        quaternionZ: Double? = nil,
        quaternionW: Double? = nil,
        gravityX: Double? = nil,
        gravityY: Double? = nil,
        gravityZ: Double? = nil,
        userAccelerationX: Double? = nil,
        userAccelerationY: Double? = nil,
        userAccelerationZ: Double? = nil
    ) {
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
        self.sourceTimestamp = sourceTimestamp
        self.timestamp = timestamp
        self.sampleCount = sampleCount
        self.status = status
        self.referenceFrame = referenceFrame
        self.errorMessage = errorMessage
        self.quaternionX = quaternionX
        self.quaternionY = quaternionY
        self.quaternionZ = quaternionZ
        self.quaternionW = quaternionW
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.userAccelerationX = userAccelerationX
        self.userAccelerationY = userAccelerationY
        self.userAccelerationZ = userAccelerationZ
    }

    static let waiting = CameraMotionSnapshot(
        pitch: nil,
        yaw: nil,
        roll: nil,
        rotationRateX: nil,
        rotationRateY: nil,
        rotationRateZ: nil,
        sourceTimestamp: nil,
        timestamp: nil,
        sampleCount: 0,
        status: .waitingForFirstSample,
        referenceFrame: .xArbitraryZVertical,
        errorMessage: nil,
        quaternionX: nil,
        quaternionY: nil,
        quaternionZ: nil,
        quaternionW: nil,
        gravityX: nil,
        gravityY: nil,
        gravityZ: nil,
        userAccelerationX: nil,
        userAccelerationY: nil,
        userAccelerationZ: nil
    )

    static let unavailable = CameraMotionSnapshot(
        pitch: nil,
        yaw: nil,
        roll: nil,
        rotationRateX: nil,
        rotationRateY: nil,
        rotationRateZ: nil,
        sourceTimestamp: nil,
        timestamp: nil,
        sampleCount: 0,
        status: .unavailable,
        referenceFrame: .xArbitraryZVertical,
        errorMessage: nil,
        quaternionX: nil,
        quaternionY: nil,
        quaternionZ: nil,
        quaternionW: nil,
        gravityX: nil,
        gravityY: nil,
        gravityZ: nil,
        userAccelerationX: nil,
        userAccelerationY: nil,
        userAccelerationZ: nil
    )

    static func failed(_ message: String) -> CameraMotionSnapshot {
        CameraMotionSnapshot(
            pitch: nil,
            yaw: nil,
            roll: nil,
            rotationRateX: nil,
            rotationRateY: nil,
            rotationRateZ: nil,
            sourceTimestamp: nil,
            timestamp: nil,
            sampleCount: 0,
            status: .failed(message),
            referenceFrame: .xArbitraryZVertical,
            errorMessage: message,
            quaternionX: nil,
            quaternionY: nil,
            quaternionZ: nil,
            quaternionW: nil,
            gravityX: nil,
            gravityY: nil,
            gravityZ: nil,
            userAccelerationX: nil,
            userAccelerationY: nil,
            userAccelerationZ: nil
        )
    }

    var hasSample: Bool {
        sampleCount > 0
            && timestamp != nil
            && sourceTimestamp != nil
            && status.hasReceivedSample
    }
}

nonisolated struct GimbalSnapshot: Equatable, Sendable {
    let identifier: UUID?
    let accessoryName: String?
    let hardwareModel: String?
    let firmwareVersion: String?
    let connectionState: GimbalConnectionState
    let pitch: Double?
    let yaw: Double?
    let roll: Double?
    let pitchAngularVelocity: Double?
    let yawAngularVelocity: Double?
    let rollAngularVelocity: Double?
    let timestamp: Date?
    let errorMessage: String?
    let motionStreamStatus: MotionStreamStatus
    let motionSampleCount: Int

    init(
        identifier: UUID?,
        accessoryName: String?,
        hardwareModel: String?,
        firmwareVersion: String?,
        connectionState: GimbalConnectionState,
        pitch: Double?,
        yaw: Double?,
        roll: Double?,
        pitchAngularVelocity: Double?,
        yawAngularVelocity: Double?,
        rollAngularVelocity: Double?,
        timestamp: Date?,
        errorMessage: String?,
        motionStreamStatus: MotionStreamStatus = .waitingForFirstSample,
        motionSampleCount: Int = 0
    ) {
        self.identifier = identifier
        self.accessoryName = accessoryName
        self.hardwareModel = hardwareModel
        self.firmwareVersion = firmwareVersion
        self.connectionState = connectionState
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
        self.pitchAngularVelocity = pitchAngularVelocity
        self.yawAngularVelocity = yawAngularVelocity
        self.rollAngularVelocity = rollAngularVelocity
        self.timestamp = timestamp
        self.errorMessage = errorMessage
        self.motionStreamStatus = motionStreamStatus
        self.motionSampleCount = motionSampleCount
    }

    static let waiting = GimbalSnapshot(
        identifier: nil,
        accessoryName: nil,
        hardwareModel: nil,
        firmwareVersion: nil,
        connectionState: .waiting,
        pitch: nil,
        yaw: nil,
        roll: nil,
        pitchAngularVelocity: nil,
        yawAngularVelocity: nil,
        rollAngularVelocity: nil,
        timestamp: nil,
        errorMessage: nil,
        motionStreamStatus: .waitingForFirstSample,
        motionSampleCount: 0
    )

    static func failed(_ message: String) -> GimbalSnapshot {
        GimbalSnapshot(
            identifier: nil,
            accessoryName: nil,
            hardwareModel: nil,
            firmwareVersion: nil,
            connectionState: .failed,
            pitch: nil,
            yaw: nil,
            roll: nil,
            pitchAngularVelocity: nil,
            yawAngularVelocity: nil,
            rollAngularVelocity: nil,
            timestamp: nil,
            errorMessage: message,
            motionStreamStatus: .failed(message),
            motionSampleCount: 0
        )
    }

    var isConnected: Bool {
        connectionState == .docked
    }

    var hasMotionSample: Bool {
        motionSampleCount > 0 && timestamp != nil && motionStreamStatus.hasReceivedSample
    }
}

nonisolated struct VideoFrameTick: Equatable, Sendable {
    let sequence: Int
    let presentationTimestamp: TimeInterval?
    let receivedAt: Date
    let frameWidth: Int
    let frameHeight: Int
    let droppedFrameCount: Int
    let presentationTimestampValue: Int64?
    let presentationTimestampScale: Int32?
    let captureTimeUs: Int64?

    init(
        sequence: Int,
        presentationTimestamp: TimeInterval?,
        receivedAt: Date,
        frameWidth: Int,
        frameHeight: Int,
        droppedFrameCount: Int,
        presentationTimestampValue: Int64? = nil,
        presentationTimestampScale: Int32? = nil,
        captureTimeUs: Int64? = nil
    ) {
        self.sequence = sequence
        self.presentationTimestamp = presentationTimestamp
        self.receivedAt = receivedAt
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.droppedFrameCount = droppedFrameCount
        self.presentationTimestampValue = presentationTimestampValue
        self.presentationTimestampScale = presentationTimestampScale
        self.captureTimeUs = captureTimeUs
    }
}

nonisolated struct LiveCaptureState: Equatable, Sendable {
    var cameraState: CameraCaptureState
    var gimbal: GimbalSnapshot
    var latestVideoFrame: VideoFrameTick?
    var latestCameraMotion: CameraMotionSnapshot?
    var cameraMotionSyncDelta: TimeInterval?
    var videoAge: TimeInterval?
    var cameraMotionAge: TimeInterval?
    var isStale: Bool
    var currentError: String?

    static let initial = LiveCaptureState(
        cameraState: .idle,
        gimbal: .waiting,
        latestVideoFrame: nil,
        latestCameraMotion: .waiting,
        cameraMotionSyncDelta: nil,
        videoAge: nil,
        cameraMotionAge: nil,
        isStale: false,
        currentError: nil
    )

    var isVideoStale: Bool {
        guard let videoAge else { return false }
        return videoAge > SyncCoordinator.defaultStaleAfter
    }

    var isCameraMotionStale: Bool {
        guard let cameraMotionAge else { return false }
        return cameraMotionAge > SyncCoordinator.defaultStaleAfter
    }

    var cameraMotionStatus: CameraMotionStatus {
        latestCameraMotion?.status ?? .waitingForFirstSample
    }
}
