import Foundation
import os

protocol CameraMotionSource: AnyObject, Sendable {
    var snapshots: AsyncStream<CameraMotionSnapshot> { get }
    func start() async
    func stop() async
}

#if canImport(CoreMotion)
import CoreMotion

actor NativeCameraMotionSource: CameraMotionSource {
    nonisolated let snapshots: AsyncStream<CameraMotionSnapshot>

    private let continuation: AsyncStream<CameraMotionSnapshot>.Continuation
    private let logger = Logger(
        subsystem: "io.github.refereelink-team.RefereeLink",
        category: "CameraMotion"
    )
    private let motionManager = CMMotionManager()
    private let callbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.refereelink.camera-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var hasStarted = false
    private var sampleCount = 0
    private var clockAnchor = CaptureClock.nowAnchor()

    init() {
        var continuation: AsyncStream<CameraMotionSnapshot>.Continuation?
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation!
    }

    func start() async {
        guard !hasStarted else { return }

        hasStarted = true
        sampleCount = 0
        clockAnchor = CaptureClock.nowAnchor()
        logger.info("Camera motion source starting at 60 Hz with xArbitraryZVertical.")
        continuation.yield(.waiting)

        guard motionManager.isDeviceMotionAvailable else {
            hasStarted = false
            logger.error("Core Motion device motion is unavailable.")
            continuation.yield(.unavailable)
            return
        }

        let referenceFrame = CMAttitudeReferenceFrame.xArbitraryZVertical
        guard CMMotionManager.availableAttitudeReferenceFrames().contains(referenceFrame) else {
            let message = "The xArbitraryZVertical reference frame is unavailable."
            hasStarted = false
            logger.error("\(message, privacy: .public)")
            continuation.yield(.failed(message))
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        let anchor = clockAnchor
        motionManager.startDeviceMotionUpdates(
            using: referenceFrame,
            to: callbackQueue
        ) { [weak self] motion, error in
            let sample = motion.map { motion in
                RawCameraMotionSample(
                    pitch: motion.attitude.pitch,
                    yaw: motion.attitude.yaw,
                    roll: motion.attitude.roll,
                    rotationRateX: motion.rotationRate.x,
                    rotationRateY: motion.rotationRate.y,
                    rotationRateZ: motion.rotationRate.z,
                    sourceTimestamp: motion.timestamp,
                    timestamp: CaptureClock.unixDate(from: motion.timestamp, anchor: anchor),
                    quaternionX: motion.attitude.quaternion.x,
                    quaternionY: motion.attitude.quaternion.y,
                    quaternionZ: motion.attitude.quaternion.z,
                    quaternionW: motion.attitude.quaternion.w,
                    gravityX: motion.gravity.x,
                    gravityY: motion.gravity.y,
                    gravityZ: motion.gravity.z,
                    userAccelerationX: motion.userAcceleration.x,
                    userAccelerationY: motion.userAcceleration.y,
                    userAccelerationZ: motion.userAcceleration.z
                )
            }
            let errorMessage = error.map(Self.describe)

            Task {
                await self?.receive(sample: sample, errorMessage: errorMessage)
            }
        }
        logger.info("Core Motion device-motion updates started.")
    }

    func stop() async {
        guard hasStarted else { return }
        hasStarted = false
        motionManager.stopDeviceMotionUpdates()
        logger.info("Core Motion device-motion updates stopped after \(self.sampleCount, privacy: .public) samples.")
    }

    private func receive(
        sample: RawCameraMotionSample?,
        errorMessage: String?
    ) {
        guard hasStarted else { return }

        if let errorMessage {
            hasStarted = false
            motionManager.stopDeviceMotionUpdates()
            logger.error("Core Motion callback failed: \(errorMessage, privacy: .public)")
            continuation.yield(.failed(errorMessage))
            return
        }

        guard let sample else {
            hasStarted = false
            motionManager.stopDeviceMotionUpdates()
            logger.error("Core Motion callback returned no device-motion sample.")
            continuation.yield(.failed("Core Motion returned no device-motion sample."))
            return
        }

        sampleCount += 1
        if sampleCount == 1 {
            logger.info(
                "First Core Motion sample: timestamp=\(sample.sourceTimestamp, privacy: .public), pitch=\(sample.pitch, privacy: .public), yaw=\(sample.yaw, privacy: .public), roll=\(sample.roll, privacy: .public), rateXYZ=(\(sample.rotationRateX, privacy: .public), \(sample.rotationRateY, privacy: .public), \(sample.rotationRateZ, privacy: .public))."
            )
        } else if sampleCount.isMultiple(of: 60) {
            logger.info(
                "Core Motion sample count=\(self.sampleCount, privacy: .public), timestamp=\(sample.sourceTimestamp, privacy: .public), pitch=\(sample.pitch, privacy: .public), yaw=\(sample.yaw, privacy: .public), roll=\(sample.roll, privacy: .public), rateXYZ=(\(sample.rotationRateX, privacy: .public), \(sample.rotationRateY, privacy: .public), \(sample.rotationRateZ, privacy: .public))."
            )
        }
        continuation.yield(
            CameraMotionSnapshot(
                pitch: sample.pitch,
                yaw: sample.yaw,
                roll: sample.roll,
                rotationRateX: sample.rotationRateX,
                rotationRateY: sample.rotationRateY,
                rotationRateZ: sample.rotationRateZ,
                sourceTimestamp: sample.sourceTimestamp,
                timestamp: sample.timestamp,
                sampleCount: sampleCount,
                status: .streaming,
                referenceFrame: .xArbitraryZVertical,
                errorMessage: nil,
                quaternionX: sample.quaternionX,
                quaternionY: sample.quaternionY,
                quaternionZ: sample.quaternionZ,
                quaternionW: sample.quaternionW,
                gravityX: sample.gravityX,
                gravityY: sample.gravityY,
                gravityZ: sample.gravityZ,
                userAccelerationX: sample.userAccelerationX,
                userAccelerationY: sample.userAccelerationY,
                userAccelerationZ: sample.userAccelerationZ
            )
        )
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "type=\(String(reflecting: type(of: error))); domain=\(nsError.domain); code=\(nsError.code); message=\(error.localizedDescription)"
    }

    private struct RawCameraMotionSample: Sendable {
        let pitch: Double
        let yaw: Double
        let roll: Double
        let rotationRateX: Double
        let rotationRateY: Double
        let rotationRateZ: Double
        let sourceTimestamp: TimeInterval
        let timestamp: Date
        let quaternionX: Double
        let quaternionY: Double
        let quaternionZ: Double
        let quaternionW: Double
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let userAccelerationX: Double
        let userAccelerationY: Double
        let userAccelerationZ: Double
    }
}
#else
actor NativeCameraMotionSource: CameraMotionSource {
    nonisolated let snapshots: AsyncStream<CameraMotionSnapshot> = AsyncStream { _ in }

    func start() async {}
    func stop() async {}
}
#endif

nonisolated enum MockCameraMotionScenario: Sendable {
    case live
    case stale
    case unavailable
    case error
}

actor MockCameraMotionSource: CameraMotionSource {
    nonisolated let snapshots: AsyncStream<CameraMotionSnapshot>

    private let continuation: AsyncStream<CameraMotionSnapshot>.Continuation
    private let scenario: MockCameraMotionScenario
    private var simulationTask: Task<Void, Never>?
    private var hasStarted = false

    init(scenario: MockCameraMotionScenario = .live) {
        self.scenario = scenario
        var continuation: AsyncStream<CameraMotionSnapshot>.Continuation?
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation!
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        continuation.yield(.waiting)

        simulationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.runScenario()
        }
    }

    func stop() async {
        simulationTask?.cancel()
        simulationTask = nil
        hasStarted = false
    }

    private func runScenario() async {
        guard hasStarted, !Task.isCancelled else { return }

        switch scenario {
        case .live:
            var step = 0
            while hasStarted, !Task.isCancelled {
                step += 1
                publishMotion(step: step)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        case .stale:
            publishMotion(step: 1, timestamp: Date(timeIntervalSinceNow: -2))
        case .unavailable:
            continuation.yield(.unavailable)
        case .error:
            continuation.yield(.failed("Mock Core Motion failed."))
        }
    }

    private func publishMotion(step: Int, timestamp: Date = Date()) {
        let sourceTimestamp = 1_700_000_000 + Double(step) / 10.0
        let cycle = step % 40
        let offset = Double(cycle <= 20 ? cycle : 40 - cycle) / 100.0
        continuation.yield(
            CameraMotionSnapshot(
                pitch: 0.1 + offset,
                yaw: -0.2 + offset * 2,
                roll: 0.03 + offset * 0.5,
                rotationRateX: 0.01,
                rotationRateY: -0.02,
                rotationRateZ: 0.03,
                sourceTimestamp: sourceTimestamp,
                timestamp: timestamp,
                sampleCount: step,
                status: .streaming,
                referenceFrame: .xArbitraryZVertical,
                errorMessage: nil
            )
        )
    }
}

extension CaptureSourceFactory {
    static func makeCameraMotionSource() -> any CameraMotionSource {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--mock") || arguments.contains(where: { $0.hasPrefix("--mock-camera-motion-") }) {
            if arguments.contains("--mock-camera-motion-stale") {
                return MockCameraMotionSource(scenario: .stale)
            }
            if arguments.contains("--mock-camera-motion-unavailable") {
                return MockCameraMotionSource(scenario: .unavailable)
            }
            if arguments.contains("--mock-camera-motion-error") {
                return MockCameraMotionSource(scenario: .error)
            }
            return MockCameraMotionSource()
        }

        #if targetEnvironment(simulator)
        return MockCameraMotionSource()
        #else
        return NativeCameraMotionSource()
        #endif
    }
}
