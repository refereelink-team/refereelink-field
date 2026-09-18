import Foundation
import os

protocol DockKitSource: AnyObject, Sendable {
    var snapshots: AsyncStream<GimbalSnapshot> { get }
    func start() async
    func stop() async
}

#if canImport(DockKit)
import DockKit
import Spatial

actor NativeDockKitSource: DockKitSource {
    nonisolated let snapshots: AsyncStream<GimbalSnapshot>

    private let continuation: AsyncStream<GimbalSnapshot>.Continuation
    private let logger = Logger(
        subsystem: "io.github.refereelink-team.RefereeLink",
        category: "DockKit"
    )
    private var stateTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var activeAccessory: DockAccessory?
    private var activeAccessoryIdentifier: UUID?
    private var motionGeneration = UUID()
    private var motionRetryCount = 0
    private var motionSampleCount = 0
    private var hasStarted = false

    init() {
        var continuation: AsyncStream<GimbalSnapshot>.Continuation?
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation!
    }

    func start() async {
        guard !hasStarted else { return }

        hasStarted = true
        motionRetryCount = 0
        motionSampleCount = 0
        logger.info("DockKit source started")
        emitConsole("source started")
        continuation.yield(.waiting)

        stateTask = Task { [weak self] in
            do {
                let changes = try DockAccessoryManager.shared.accessoryStateChanges
                for await change in changes {
                    guard !Task.isCancelled else { break }
                    await self?.handle(change)
                }

                guard !Task.isCancelled else { return }
                await self?.handleStateStreamEnded()
            } catch {
                guard !Task.isCancelled else { return }
                await self?.handleStateStreamFailed(error)
            }
        }
    }

    func stop() async {
        logger.info("DockKit source stopping")
        hasStarted = false
        stateTask?.cancel()
        invalidateMotionStream()
        stateTask = nil
        activeAccessory = nil
        activeAccessoryIdentifier = nil
        motionRetryCount = 0
        motionSampleCount = 0
    }

    private func handle(_ change: DockAccessory.StateChange) async {
        guard hasStarted else { return }

        invalidateMotionStream()
        motionRetryCount = 0
        motionSampleCount = 0

        let accessoryDescription = change.accessory.map(describeAccessory) ?? "none"
        logger.info("Accessory state change: state=\(String(describing: change.state), privacy: .public), accessory=\(accessoryDescription, privacy: .public)")
        emitConsole("accessory state change: state=\(String(describing: change.state)), accessory=\(accessoryDescription)")

        guard let accessory = change.accessory else {
            activeAccessory = nil
            activeAccessoryIdentifier = nil
            publish(
                GimbalSnapshot(
                    identifier: nil,
                    accessoryName: nil,
                    hardwareModel: nil,
                    firmwareVersion: nil,
                    connectionState: .unsupported,
                    pitch: nil,
                    yaw: nil,
                    roll: nil,
                    pitchAngularVelocity: nil,
                    yawAngularVelocity: nil,
                    rollAngularVelocity: nil,
                    timestamp: nil,
                    errorMessage: "DockKit reported a state change without an accessory.",
                    motionStreamStatus: .ended,
                    motionSampleCount: 0
                )
            )
            return
        }

        switch change.state {
        case .docked:
            activeAccessory = accessory
            activeAccessoryIdentifier = accessory.identifier.uuid
            logger.info("Accessory docked: \(self.describeAccessory(accessory), privacy: .public)")
            publish(identitySnapshot(for: accessory, state: .docked, status: .waitingForFirstSample))

            var trackingEnabled = true
            do {
                try await DockAccessoryManager.shared.setSystemTrackingEnabled(true)
                logger.info("System tracking enabled: true")
                emitConsole("system tracking enabled: true")
            } catch {
                trackingEnabled = false
                let detail = describe(error)
                logger.error("System tracking enabled: false, error=\(detail, privacy: .public)")
                emitConsole("system tracking enabled: false, error=\(detail)")
                publish(
                    identitySnapshot(
                        for: accessory,
                        state: .docked,
                        status: .failed(detail),
                        error: detail
                    )
                )
            }

            guard trackingEnabled,
                  hasStarted,
                  isCurrent(accessory: accessory, generation: motionGeneration) else {
                return
            }
            startMotionStream(for: accessory)

        case .undocked:
            activeAccessory = nil
            activeAccessoryIdentifier = nil
            logger.info("Accessory undocked: \(self.describeAccessory(accessory), privacy: .public)")
            publish(identitySnapshot(for: accessory, state: .undocked, status: .ended))

        @unknown default:
            activeAccessory = nil
            activeAccessoryIdentifier = nil
            let message = "DockKit reported an unknown accessory state."
            logger.error("\(message, privacy: .public)")
            publish(
                identitySnapshot(
                    for: accessory,
                    state: .failed,
                    status: .failed(message),
                    error: message
                )
            )
        }
    }

    private func startMotionStream(for accessory: DockAccessory) {
        invalidateMotionStream()
        let generation = UUID()
        motionGeneration = generation
        logger.info("Creating motionStates consumer: generation=\(generation.uuidString, privacy: .public)")
        emitConsole("creating motionStates consumer: generation=\(generation.uuidString)")
        publish(
            identitySnapshot(
                for: accessory,
                state: .docked,
                status: .waitingForFirstSample
            )
        )

        motionTask = Task { [weak self] in
            await self?.consumeMotionStream(for: accessory, generation: generation)
        }
    }

    private func consumeMotionStream(
        for accessory: DockAccessory,
        generation: UUID
    ) async {
        while !Task.isCancelled {
            guard hasStarted, isCurrent(accessory: accessory, generation: generation) else {
                logger.debug("Motion consumer stopped because accessory generation is no longer current")
                return
            }

            do {
                logger.info("Opening motionStates sequence: attempt=\(self.motionRetryCount + 1)")
                emitConsole("opening motionStates sequence: attempt=\(self.motionRetryCount + 1)")
                let states = try accessory.motionStates

                for await motion in states {
                    guard !Task.isCancelled else {
                        logger.info("MotionStates consumer cancelled")
                        return
                    }
                    guard hasStarted, isCurrent(accessory: accessory, generation: generation) else {
                        logger.debug("Ignoring late MotionState from an inactive accessory generation")
                        return
                    }

                    motionSampleCount += 1
                    let motionError = motion.error.map(describe)
                    let status: MotionStreamStatus = motionError.map(MotionStreamStatus.failed) ?? .streaming
                    logger.debug(
                        "MotionState sample=\(self.motionSampleCount), timestamp=\(motion.timestamp, privacy: .public), position=(\(motion.angularPositions.x), \(motion.angularPositions.y), \(motion.angularPositions.z)), velocity=(\(motion.angularVelocities.x), \(motion.angularVelocities.y), \(motion.angularVelocities.z)), error=\(motionError ?? "none", privacy: .public)"
                    )
                    if motionSampleCount == 1 {
                        logger.info("First MotionState received: timestamp=\(motion.timestamp, privacy: .public)")
                        emitConsole("first MotionState received: timestamp=\(motion.timestamp)")
                    }
                    publish(
                        motion,
                        from: accessory,
                        status: status,
                        error: motionError,
                        sampleCount: motionSampleCount
                    )
                }

                guard !Task.isCancelled else {
                    logger.info("MotionStates sequence ended after cancellation")
                    return
                }
                guard hasStarted, isCurrent(accessory: accessory, generation: generation) else {
                    return
                }
                await retryAfterMotionTermination(
                    for: accessory,
                    generation: generation,
                    error: nil
                )
            } catch is CancellationError {
                logger.info("MotionStates consumer cancelled by task")
                emitConsole("motionStates consumer cancelled")
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard hasStarted, isCurrent(accessory: accessory, generation: generation) else {
                    return
                }
                await retryAfterMotionTermination(
                    for: accessory,
                    generation: generation,
                    error: error
                )
            }
        }
    }

    private func retryAfterMotionTermination(
        for accessory: DockAccessory,
        generation: UUID,
        error: Error?
    ) async {
        let maximumMotionRetries = 3
        let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]
        let detail = error.map(describe)
        let status: MotionStreamStatus = detail.map(MotionStreamStatus.failed) ?? .ended
        let statusName = detail == nil ? "ended" : "failed"
        logger.info(
            "MotionStates sequence \(statusName, privacy: .public): retry=\(self.motionRetryCount), error=\(detail ?? "none", privacy: .public), accessoryDocked=\(self.activeAccessoryIdentifier == accessory.identifier.uuid)"
        )
        emitConsole("motionStates sequence \(statusName): retry=\(motionRetryCount), error=\(detail ?? "none"), accessoryDocked=\(activeAccessoryIdentifier == accessory.identifier.uuid)")
        publish(
            identitySnapshot(
                for: accessory,
                state: .docked,
                status: status,
                error: detail
            )
        )

        guard hasStarted, isCurrent(accessory: accessory, generation: generation) else {
            return
        }
        guard motionRetryCount < maximumMotionRetries else {
            logger.info("MotionStates retry limit reached: \(maximumMotionRetries)")
            return
        }

        let delay = retryDelays[motionRetryCount]
        motionRetryCount += 1
        logger.info("Scheduling MotionStates retry \(self.motionRetryCount)/\(maximumMotionRetries) after \(delay / 1_000_000_000)s")

        do {
            try await Task.sleep(nanoseconds: delay)
        } catch {
            logger.info("MotionStates retry cancelled")
            return
        }

        guard !Task.isCancelled, hasStarted, isCurrent(accessory: accessory, generation: generation) else {
            return
        }

        publish(
            identitySnapshot(
                for: accessory,
                state: .docked,
                status: .waitingForFirstSample
            )
        )
    }

    private func handleStateStreamEnded() {
        guard hasStarted else { return }
        let message = "DockKit accessory state stream ended."
        logger.error("\(message, privacy: .public)")
        emitConsole("accessory state stream ended")
        invalidateMotionStream()
        publish(.failed(message))
    }

    private func handleStateStreamFailed(_ error: Error) {
        guard hasStarted else { return }
        let detail = describe(error)
        logger.error("DockKit accessory state stream failed: \(detail, privacy: .public)")
        emitConsole("accessory state stream failed: \(detail)")
        invalidateMotionStream()
        publish(.failed(detail))
    }

    private func invalidateMotionStream() {
        motionGeneration = UUID()
        motionTask?.cancel()
        motionTask = nil
    }

    private func isCurrent(accessory: DockAccessory, generation: UUID) -> Bool {
        activeAccessoryIdentifier == accessory.identifier.uuid && motionGeneration == generation
    }

    private func publish(
        _ motion: DockAccessory.MotionState,
        from accessory: DockAccessory,
        status: MotionStreamStatus,
        error: String?,
        sampleCount: Int
    ) {
        continuation.yield(
            GimbalSnapshot(
                identifier: accessory.identifier.uuid,
                accessoryName: accessory.identifier.name,
                hardwareModel: accessory.hardwareModel,
                firmwareVersion: accessory.firmwareVersion,
                connectionState: .docked,
                pitch: motion.angularPositions.x,
                yaw: motion.angularPositions.y,
                roll: motion.angularPositions.z,
                pitchAngularVelocity: motion.angularVelocities.x,
                yawAngularVelocity: motion.angularVelocities.y,
                rollAngularVelocity: motion.angularVelocities.z,
                timestamp: Date(timeIntervalSince1970: motion.timestamp),
                errorMessage: error,
                motionStreamStatus: status,
                motionSampleCount: sampleCount
            )
        )
    }

    private func publish(_ snapshot: GimbalSnapshot) {
        continuation.yield(snapshot)
    }

    private func identitySnapshot(
        for accessory: DockAccessory,
        state: GimbalConnectionState,
        status: MotionStreamStatus,
        error: String? = nil
    ) -> GimbalSnapshot {
        GimbalSnapshot(
            identifier: accessory.identifier.uuid,
            accessoryName: accessory.identifier.name,
            hardwareModel: accessory.hardwareModel,
            firmwareVersion: accessory.firmwareVersion,
            connectionState: state,
            pitch: nil,
            yaw: nil,
            roll: nil,
            pitchAngularVelocity: nil,
            yawAngularVelocity: nil,
            rollAngularVelocity: nil,
            timestamp: nil,
            errorMessage: error,
            motionStreamStatus: status,
            motionSampleCount: motionSampleCount
        )
    }

    private func describeAccessory(_ accessory: DockAccessory) -> String {
        "uuid=\(accessory.identifier.uuid.uuidString), name=\(String(describing: accessory.identifier.name)), model=\(String(describing: accessory.hardwareModel)), firmware=\(String(describing: accessory.firmwareVersion))"
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "type=\(String(reflecting: type(of: error))); domain=\(nsError.domain); code=\(nsError.code); message=\(error.localizedDescription)"
    }

    private func emitConsole(_ message: String) {
        print("[RefereeLink.DockKit] \(message)")
    }
}
#else
actor NativeDockKitSource: DockKitSource {
    nonisolated let snapshots = AsyncStream<GimbalSnapshot> { _ in }

    func start() async {}
    func stop() async {}
}
#endif

nonisolated enum MockDockKitScenario: Sendable {
    case live
    case noSample
    case normalEnd
    case streamError
    case reconnect
    case stale
    case error
}

actor MockDockKitSource: DockKitSource {
    nonisolated let snapshots: AsyncStream<GimbalSnapshot>

    private let continuation: AsyncStream<GimbalSnapshot>.Continuation
    private let scenario: MockDockKitScenario
    private var simulationTask: Task<Void, Never>?
    private var hasStarted = false

    init(scenario: MockDockKitScenario = .live) {
        self.scenario = scenario
        var continuation: AsyncStream<GimbalSnapshot>.Continuation?
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(16)) {
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

    func emitUndocked() {
        continuation.yield(undockedSnapshot())
    }

    private func runScenario() async {
        guard hasStarted, !Task.isCancelled else { return }

        switch scenario {
        case .error:
            publish(.failed("Mock DockKit connection failed."))
        case .noSample:
            publish(connectedSnapshot())
        case .streamError:
            publish(connectedSnapshot())
            publish(streamErrorSnapshot())
        case .normalEnd:
            publish(connectedSnapshot())
            publish(motionSnapshot(step: 1))
            publish(endedSnapshot(sampleCount: 1))
        case .stale:
            publish(connectedSnapshot())
            publish(motionSnapshot(step: 1, timestamp: Date(timeIntervalSinceNow: -2)))
        case .reconnect:
            publish(connectedSnapshot())
            publish(motionSnapshot(step: 1))
            publish(undockedSnapshot())
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard hasStarted, !Task.isCancelled else { return }
            publish(connectedSnapshot())
            publish(motionSnapshot(step: 1))
        case .live:
            publish(connectedSnapshot())
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard hasStarted, !Task.isCancelled else { break }
                step += 1
                publish(motionSnapshot(step: step))
            }
        }
    }

    private func connectedSnapshot() -> GimbalSnapshot {
        GimbalSnapshot(
            identifier: mockIdentifier,
            accessoryName: "RefereeLink Mock Stand",
            hardwareModel: "Mock Tracking Stand",
            firmwareVersion: "mock-1.0",
            connectionState: .docked,
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
    }

    private func undockedSnapshot() -> GimbalSnapshot {
        GimbalSnapshot(
            identifier: mockIdentifier,
            accessoryName: "RefereeLink Mock Stand",
            hardwareModel: "Mock Tracking Stand",
            firmwareVersion: "mock-1.0",
            connectionState: .undocked,
            pitch: nil,
            yaw: nil,
            roll: nil,
            pitchAngularVelocity: nil,
            yawAngularVelocity: nil,
            rollAngularVelocity: nil,
            timestamp: nil,
            errorMessage: nil,
            motionStreamStatus: .ended,
            motionSampleCount: 0
        )
    }

    private func motionSnapshot(
        step: Int,
        timestamp: Date = Date()
    ) -> GimbalSnapshot {
        let phase = Double(step) / 10
        return GimbalSnapshot(
            identifier: mockIdentifier,
            accessoryName: "RefereeLink Mock Stand",
            hardwareModel: "Mock Tracking Stand",
            firmwareVersion: "mock-1.0",
            connectionState: .docked,
            pitch: sin(phase) * 0.2,
            yaw: cos(phase) * 0.35,
            roll: sin(phase * 0.5) * 0.05,
            pitchAngularVelocity: cos(phase) * 0.2,
            yawAngularVelocity: -sin(phase) * 0.35,
            rollAngularVelocity: cos(phase * 0.5) * 0.025,
            timestamp: timestamp,
            errorMessage: nil,
            motionStreamStatus: .streaming,
            motionSampleCount: step
        )
    }

    private func endedSnapshot(sampleCount: Int) -> GimbalSnapshot {
        GimbalSnapshot(
            identifier: mockIdentifier,
            accessoryName: "RefereeLink Mock Stand",
            hardwareModel: "Mock Tracking Stand",
            firmwareVersion: "mock-1.0",
            connectionState: .docked,
            pitch: nil,
            yaw: nil,
            roll: nil,
            pitchAngularVelocity: nil,
            yawAngularVelocity: nil,
            rollAngularVelocity: nil,
            timestamp: nil,
            errorMessage: nil,
            motionStreamStatus: .ended,
            motionSampleCount: sampleCount
        )
    }

    private func streamErrorSnapshot() -> GimbalSnapshot {
        let message = "Mock motion stream error."
        return GimbalSnapshot(
            identifier: mockIdentifier,
            accessoryName: "RefereeLink Mock Stand",
            hardwareModel: "Mock Tracking Stand",
            firmwareVersion: "mock-1.0",
            connectionState: .docked,
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

    private func publish(_ snapshot: GimbalSnapshot) {
        continuation.yield(snapshot)
    }

    private var mockIdentifier: UUID {
        UUID(uuidString: "7E728D42-30A3-4430-9D1D-EA774A3A7B12")!
    }
}

enum CaptureSourceFactory {
    static func makeDockKitSource() -> any DockKitSource {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--mock") || arguments.contains(where: { $0.hasPrefix("--mock-dock-") }) {
            if arguments.contains("--mock-dock-no-sample") {
                return MockDockKitSource(scenario: .noSample)
            }
            if arguments.contains("--mock-dock-ended") {
                return MockDockKitSource(scenario: .normalEnd)
            }
            if arguments.contains("--mock-dock-error") {
                return MockDockKitSource(scenario: .streamError)
            }
            if arguments.contains("--mock-dock-reconnect") {
                return MockDockKitSource(scenario: .reconnect)
            }
            if arguments.contains("--mock-dock-stale") {
                return MockDockKitSource(scenario: .stale)
            }
            return MockDockKitSource()
        }

        #if canImport(DockKit)
        return NativeDockKitSource()
        #else
        return MockDockKitSource()
        #endif
    }
}
