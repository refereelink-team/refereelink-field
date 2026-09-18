import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class LiveCaptureModel {
    private(set) var liveState: LiveCaptureState
    private(set) var cameraSession: AVCaptureSession?
    let shouldAutoStart: Bool

    @ObservationIgnored private let dockKitSource: any DockKitSource
    @ObservationIgnored private let cameraSource: any CameraCaptureSource
    @ObservationIgnored private let cameraMotionSource: any CameraMotionSource
    @ObservationIgnored private let coordinator: SyncCoordinator
    @ObservationIgnored private var stateObservationTask: Task<Void, Never>?
    @ObservationIgnored private var dockObservationTask: Task<Void, Never>?
    @ObservationIgnored private var videoObservationTask: Task<Void, Never>?
    @ObservationIgnored private var cameraMotionObservationTask: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var cameraState: CameraCaptureState
    @ObservationIgnored private var currentError: String?
    @ObservationIgnored private var lastPublishedAt = Date.distantPast

    init(
        dockKitSource: (any DockKitSource)? = nil,
        cameraSource: (any CameraCaptureSource)? = nil,
        cameraMotionSource: (any CameraMotionSource)? = nil,
        coordinator: SyncCoordinator = SyncCoordinator(),
        initialState: LiveCaptureState = .initial,
        autoStart: Bool = true
    ) {
        self.dockKitSource = dockKitSource ?? CaptureSourceFactory.makeDockKitSource()
        self.cameraSource = cameraSource ?? CaptureSourceFactory.makeCameraSource()
        self.cameraMotionSource = cameraMotionSource ?? CaptureSourceFactory.makeCameraMotionSource()
        self.coordinator = coordinator
        self.liveState = initialState
        self.shouldAutoStart = autoStart
        self.cameraState = initialState.cameraState
        self.currentError = initialState.currentError
        self.cameraSession = self.cameraSource.session
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
        isRunning = false

        stateObservationTask?.cancel()
        dockObservationTask?.cancel()
        videoObservationTask?.cancel()
        cameraMotionObservationTask?.cancel()
        stateObservationTask = nil
        dockObservationTask = nil
        videoObservationTask = nil
        cameraMotionObservationTask = nil

        cameraSession = nil
        cameraState = .idle
        publishImmediately()

        await cameraSource.stop()
        await cameraMotionSource.stop()
        await dockKitSource.stop()
        await coordinator.stop()
    }

    private func receive(gimbal snapshot: GimbalSnapshot) {
        guard isRunning else { return }
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
        Task { [weak self] in
            guard let self, self.isRunning else { return }
            await self.coordinator.submit(cameraMotion: snapshot)
        }
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
