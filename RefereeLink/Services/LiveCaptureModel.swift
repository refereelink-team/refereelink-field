import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class LiveCaptureModel {
    private let logger = Logger(
        subsystem: "io.github.refereelink-team.RefereeLink",
        category: "LiveCapture"
    )
    private(set) var liveState: LiveCaptureState
    private(set) var cameraSession: AVCaptureSession?
    private(set) var captureMode: CaptureSessionMode?
    private(set) var archiveDescriptor: CaptureArchiveDescriptor?
    private(set) var archiveExportURL: URL?
    private(set) var transportStatus: TransportStatus
    let shouldAutoStart: Bool
    let shouldAutoStartRealtime: Bool
    let shouldUseWSSOnlyForFieldTest: Bool

    @ObservationIgnored private let dockKitSource: any DockKitSource
    @ObservationIgnored private let cameraSource: any CameraCaptureSource
    @ObservationIgnored private let cameraMotionSource: any CameraMotionSource
    @ObservationIgnored private let coordinator: SyncCoordinator
    @ObservationIgnored private let archiveRecorder: CaptureArchiveRecorder
    @ObservationIgnored private let archiveExporter: CaptureArchiveExporter
    @ObservationIgnored private let fieldTransport: any FieldTransport
    @ObservationIgnored private var realtimeVideoTransport: (any RealtimeVideoTransport)?
    @ObservationIgnored private var stateObservationTask: Task<Void, Never>?
    @ObservationIgnored private var dockObservationTask: Task<Void, Never>?
    @ObservationIgnored private var videoObservationTask: Task<Void, Never>?
    @ObservationIgnored private var cameraMotionObservationTask: Task<Void, Never>?
    @ObservationIgnored private var frameSampleObservationTask: Task<Void, Never>?
    @ObservationIgnored private var transportObservationTask: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var cameraState: CameraCaptureState
    @ObservationIgnored private var currentError: String?
    @ObservationIgnored private var lastPublishedAt = Date.distantPast
    @ObservationIgnored private var captureSessionId: UUID?
    @ObservationIgnored private var captureClockAnchor: CaptureClockAnchor?
    @ObservationIgnored private var activeStreamEpoch = 0
    @ObservationIgnored private var firstVideoTimeUs: Int64?
    @ObservationIgnored private var firstTransportPresentationTimestampValue: Int64?
    @ObservationIgnored private var latestMotionForRecording: CameraMotionSnapshot = .waiting
    @ObservationIgnored private var latestGimbalForRecording: GimbalSnapshot = .waiting

    init(
        dockKitSource: (any DockKitSource)? = nil,
        cameraSource: (any CameraCaptureSource)? = nil,
        cameraMotionSource: (any CameraMotionSource)? = nil,
        coordinator: SyncCoordinator = SyncCoordinator(),
        archiveRecorder: CaptureArchiveRecorder = CaptureArchiveRecorder(),
        archiveExporter: CaptureArchiveExporter = CaptureArchiveExporter(),
        fieldTransport: (any FieldTransport)? = nil,
        initialState: LiveCaptureState = .initial,
        autoStart: Bool = true
    ) {
        self.dockKitSource = dockKitSource ?? CaptureSourceFactory.makeDockKitSource()
        self.cameraSource = cameraSource ?? CaptureSourceFactory.makeCameraSource()
        self.cameraMotionSource = cameraMotionSource ?? CaptureSourceFactory.makeCameraMotionSource()
        self.coordinator = coordinator
        self.archiveRecorder = archiveRecorder
        self.archiveExporter = archiveExporter
        self.fieldTransport = fieldTransport ?? URLSessionFieldTransport()
        self.realtimeVideoTransport = nil
        self.liveState = initialState
        self.shouldAutoStart = autoStart
        self.shouldAutoStartRealtime = ProcessInfo.processInfo.arguments.contains("--auto-start-realtime")
        self.shouldUseWSSOnlyForFieldTest = ProcessInfo.processInfo.arguments.contains("--field-wss-only")
        self.cameraState = initialState.cameraState
        self.currentError = initialState.currentError
        self.cameraSession = self.cameraSource.session
        self.captureMode = nil
        self.archiveDescriptor = nil
        self.archiveExportURL = nil
        self.transportStatus = TransportStatus(
            state: .disabled,
            streamEpoch: 0,
            sentFrameCount: 0,
            sentMotionCount: 0,
            droppedFrameCount: 0,
            lastError: nil
        )
    }

    static func preview(_ state: LiveCaptureState) -> LiveCaptureModel {
        LiveCaptureModel(initialState: state, autoStart: false)
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        currentError = nil
        cameraState = .requestingPermission
        publishImmediately()

        let coordinatorStream = coordinator.states
        stateObservationTask = Task { [weak self] in
            for await state in coordinatorStream {
                guard !Task.isCancelled else { break }
                self?.applyCoordinatorState(state)
            }
        }

        let dockStream = dockKitSource.snapshots
        dockObservationTask = Task { [weak self] in
            for await snapshot in dockStream {
                guard !Task.isCancelled else { break }
                self?.receive(gimbal: snapshot)
            }
        }

        let videoStream = cameraSource.frameTicks
        videoObservationTask = Task { [weak self] in
            for await tick in videoStream {
                guard !Task.isCancelled else { break }
                self?.receive(video: tick)
            }
        }

        let cameraMotionStream = cameraMotionSource.snapshots
        cameraMotionObservationTask = Task { [weak self] in
            for await snapshot in cameraMotionStream {
                guard !Task.isCancelled else { break }
                self?.receive(cameraMotion: snapshot)
            }
        }

        let frameSampleStream = cameraSource.frameSamples
        frameSampleObservationTask = Task { [weak self] in
            for await sample in frameSampleStream {
                guard !Task.isCancelled else { break }
                self?.receive(sample: sample)
            }
        }

        let transportStatusStream = fieldTransport.statuses
        transportObservationTask = Task { [weak self] in
            for await status in transportStatusStream {
                guard !Task.isCancelled else { break }
                self?.transportStatus = status
            }
        }

        await coordinator.reset()
        await coordinator.start()

        do {
            try await cameraSource.start()
            guard isRunning, !Task.isCancelled else {
                await cameraSource.stop()
                return
            }
            cameraSession = cameraSource.session
            cameraState = .running
            publishImmediately()
        } catch is CancellationError {
            return
        } catch {
            cameraState = error is CameraCaptureError && (error as? CameraCaptureError) == .permissionDenied
                ? .denied
                : .failed
            currentError = error.localizedDescription
            publishImmediately()
        }

        guard isRunning, !Task.isCancelled else { return }
        await cameraMotionSource.start()
        guard isRunning, !Task.isCancelled else { return }
        await dockKitSource.start()
    }

    func stop() async {
        guard isRunning else { return }
        if captureMode != nil {
            await stopCapture()
        }
        isRunning = false

        stateObservationTask?.cancel()
        dockObservationTask?.cancel()
        videoObservationTask?.cancel()
        cameraMotionObservationTask?.cancel()
        frameSampleObservationTask?.cancel()
        transportObservationTask?.cancel()
        stateObservationTask = nil
        dockObservationTask = nil
        videoObservationTask = nil
        cameraMotionObservationTask = nil
        frameSampleObservationTask = nil
        transportObservationTask = nil

        cameraSession = nil
        cameraState = .idle
        publishImmediately()

        await cameraSource.stop()
        await cameraMotionSource.stop()
        await dockKitSource.stop()
        await coordinator.stop()
    }

    func startCapture(mode: CaptureSessionMode) async {
        guard captureMode == nil else { return }
        if !isRunning {
            await start()
        }
        guard isRunning else { return }
        do {
            captureSessionId = try archiveRecorder.start(mode: mode)
            captureClockAnchor = CaptureClock.nowAnchor()
            firstVideoTimeUs = nil
            firstTransportPresentationTimestampValue = nil
            activeStreamEpoch = 0
            captureMode = mode
            archiveDescriptor = nil
            archiveExportURL = nil

            if mode == .realtime,
               let configuration = FieldEndpointConfiguration.load() {
                await fieldTransport.connect(configuration: configuration, sessionId: captureSessionId!)
                if !shouldUseWSSOnlyForFieldTest,
                   let allocation = await fieldTransport.allocateLive(sessionId: captureSessionId!) {
                    let videoTransport = NativeSRTVideoTransport()
                    do {
                        try await videoTransport.connect(allocation: allocation)
                        await fieldTransport.activateLiveEpoch(allocation.streamEpoch)
                        activeStreamEpoch = allocation.streamEpoch
                        firstTransportPresentationTimestampValue = nil
                        realtimeVideoTransport = videoTransport
                    } catch {
                        logger.error("realtime video transport failed: \(String(reflecting: error), privacy: .public)")
                        currentError = "实时视频连接失败：\(error.localizedDescription)"
                        publishImmediately()
                    }
                }
            }
        } catch {
            currentError = error.localizedDescription
            publishImmediately()
        }
    }

    func stopCapture() async {
        guard captureMode != nil else { return }
        let descriptor = await archiveRecorder.stop()
        archiveDescriptor = descriptor
        archiveExportURL = nil
        captureSessionId = nil
        captureClockAnchor = nil
        firstVideoTimeUs = nil
        firstTransportPresentationTimestampValue = nil
        activeStreamEpoch = 0
        captureMode = nil
        await fieldTransport.disconnect()
        await realtimeVideoTransport?.disconnect()
        realtimeVideoTransport = nil
    }

    func exportArchive() async {
        guard let archiveDescriptor else { return }
        do {
            archiveExportURL = try await archiveExporter.export(archiveDescriptor)
        } catch {
            currentError = "采集包导出失败：\(error.localizedDescription)"
            publishImmediately()
        }
    }

    func configureEndpoint(_ configuration: FieldEndpointConfiguration) {
        configuration.save()
    }

    private func receive(gimbal snapshot: GimbalSnapshot) {
        guard isRunning else { return }
        latestGimbalForRecording = snapshot
        if let captureSessionId, let anchor = captureClockAnchor {
            let event = DockDiagnosticEvent(
                sessionId: captureSessionId,
                tUs: Int64(Date().timeIntervalSince1970 * 1_000_000) - anchor.wallClockUnixUs,
                identifier: snapshot.identifier,
                accessoryName: snapshot.accessoryName,
                hardwareModel: snapshot.hardwareModel,
                firmwareVersion: snapshot.firmwareVersion,
                connectionState: String(describing: snapshot.connectionState),
                motionStreamStatus: String(describing: snapshot.motionStreamStatus),
                motionSampleCount: snapshot.motionSampleCount,
                error: snapshot.errorMessage
            )
            archiveRecorder.appendDock(event)
            if captureMode == .realtime {
                Task { [fieldTransport] in await fieldTransport.send(dock: event) }
            }
        }
        Task { [weak self] in
            guard let self, self.isRunning else { return }
            await self.coordinator.submit(gimbal: snapshot)
        }
    }

    private func receive(video tick: VideoFrameTick) {
        guard isRunning else { return }
        Task { [weak self] in
            guard let self, self.isRunning else { return }
            await self.coordinator.submit(video: tick)
        }
    }

    private func receive(cameraMotion snapshot: CameraMotionSnapshot) {
        guard isRunning else { return }
        latestMotionForRecording = snapshot
        if let captureSessionId, let anchor = captureClockAnchor, snapshot.hasSample {
            let motion = makeMotionSample(snapshot, sessionId: captureSessionId, anchor: anchor)
            archiveRecorder.appendMotion(motion)
            if captureMode == .realtime {
                Task { [fieldTransport] in await fieldTransport.send(motion: motion) }
            }
        }
        Task { [weak self] in
            guard let self, self.isRunning else { return }
            await self.coordinator.submit(cameraMotion: snapshot)
        }
    }

    private func receive(sample: CameraFrameSample) {
        guard isRunning, let captureSessionId, let anchor = captureClockAnchor else { return }
        let tick = sample.tick
        if firstVideoTimeUs == nil {
            firstVideoTimeUs = tick.captureTimeUs
        }
        let sessionTimeUs = tick.captureTimeUs.map { $0 - (firstVideoTimeUs ?? $0) }
            ?? Int64(tick.receivedAt.timeIntervalSince1970 * 1_000_000) - anchor.wallClockUnixUs
        let shouldTrackTransportPTS = captureMode == .offline || activeStreamEpoch > 0
        if shouldTrackTransportPTS,
           firstTransportPresentationTimestampValue == nil,
           tick.presentationTimestampValue != nil,
           tick.presentationTimestampScale != nil {
            firstTransportPresentationTimestampValue = tick.presentationTimestampValue
        }
        let transportPts90k = CaptureClock.transportPTS90k(
            presentationTimestampValue: tick.presentationTimestampValue,
            presentationTimestampScale: tick.presentationTimestampScale,
            originValue: shouldTrackTransportPTS ? firstTransportPresentationTimestampValue : nil
        )
        let motionAgeUs: Int64?
        let motionSampleId: Int?
        let missingReason: String?
        if latestMotionForRecording.hasSample,
           let timestamp = latestMotionForRecording.timestamp {
            let age = tick.receivedAt.timeIntervalSince(timestamp)
            if age >= 0, age <= 0.05 {
                motionAgeUs = Int64(age * 1_000_000)
                motionSampleId = latestMotionForRecording.sampleCount
                missingReason = nil
            } else {
                motionAgeUs = nil
                motionSampleId = nil
                missingReason = age < 0 ? "future_motion_sample" : "motion_sample_older_than_50ms"
            }
        } else {
            motionAgeUs = nil
            motionSampleId = nil
            missingReason = "no_motion_sample"
        }
        let metadata = CapturedFrameMetadata(
            sessionId: captureSessionId,
            streamEpoch: activeStreamEpoch,
            frameId: tick.sequence,
            tUs: sessionTimeUs,
            captureUnixUs: Int64(tick.receivedAt.timeIntervalSince1970 * 1_000_000),
            presentationTimestampValue: tick.presentationTimestampValue,
            presentationTimestampScale: tick.presentationTimestampScale,
            transportPts90k: transportPts90k,
            width: tick.frameWidth,
            height: tick.frameHeight,
            droppedFrameCount: tick.droppedFrameCount,
            cameraConfigurationId: "default-720p30",
            cameraMotionSampleId: motionSampleId,
            cameraMotionAgeUs: motionAgeUs,
            poseMissingReason: missingReason
        )
        archiveRecorder.append(sample, metadata: metadata)
        Task { [fieldTransport] in
            await fieldTransport.send(frame: metadata)
            await fieldTransport.send(sample: sample)
        }
        if captureMode == .realtime, let realtimeVideoTransport {
            Task { [realtimeVideoTransport] in
                await realtimeVideoTransport.append(sample.sampleBuffer)
            }
        }
    }

    private func makeMotionSample(
        _ snapshot: CameraMotionSnapshot,
        sessionId: UUID,
        anchor: CaptureClockAnchor
    ) -> CameraMotionSample {
        CameraMotionSample(
            sampleId: snapshot.sampleCount,
            tUs: snapshot.sourceTimestamp.map { CaptureClock.sessionTimeUs(sourceTimestamp: $0, anchor: anchor) } ?? 0,
            sourceTimestamp: snapshot.sourceTimestamp,
            pitch: snapshot.pitch,
            yaw: snapshot.yaw,
            roll: snapshot.roll,
            quaternionX: snapshot.quaternionX,
            quaternionY: snapshot.quaternionY,
            quaternionZ: snapshot.quaternionZ,
            quaternionW: snapshot.quaternionW,
            rotationRateX: snapshot.rotationRateX,
            rotationRateY: snapshot.rotationRateY,
            rotationRateZ: snapshot.rotationRateZ,
            gravityX: snapshot.gravityX,
            gravityY: snapshot.gravityY,
            gravityZ: snapshot.gravityZ,
            userAccelerationX: snapshot.userAccelerationX,
            userAccelerationY: snapshot.userAccelerationY,
            userAccelerationZ: snapshot.userAccelerationZ,
            referenceFrame: snapshot.referenceFrame.rawValue,
            status: String(describing: snapshot.status),
            error: snapshot.errorMessage
        )
    }

    private func applyCoordinatorState(_ state: LiveCaptureState) {
        var next = state
        next.cameraState = cameraState
        next.currentError = currentError ?? state.currentError

        let now = Date()
        let shouldPublish = now.timeIntervalSince(lastPublishedAt) >= 0.1
            || next.gimbal.connectionState != liveState.gimbal.connectionState
            || next.gimbal.motionStreamStatus != liveState.gimbal.motionStreamStatus
            || next.cameraMotionStatus != liveState.cameraMotionStatus
            || next.currentError != liveState.currentError
            || next.cameraState != liveState.cameraState

        guard shouldPublish else { return }
        liveState = next
        lastPublishedAt = now
    }

    private func publishImmediately() {
        var next = liveState
        next.cameraState = cameraState
        next.currentError = currentError ?? liveState.gimbal.errorMessage
        liveState = next
        lastPublishedAt = Date()
    }
}
