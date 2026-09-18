import Foundation

actor SyncCoordinator {
    nonisolated static let defaultStaleAfter: TimeInterval = 0.75

    nonisolated let states: AsyncStream<LiveCaptureState>
    private let continuation: AsyncStream<LiveCaptureState>.Continuation
    private let staleAfter: TimeInterval
    private var latestGimbal: GimbalSnapshot?
    private var latestVideoFrame: VideoFrameTick?
    private var latestCameraMotion: CameraMotionSnapshot?
    private var clockTask: Task<Void, Never>?

    init(staleAfter: TimeInterval = SyncCoordinator.defaultStaleAfter) {
        self.staleAfter = staleAfter

        var continuation: AsyncStream<LiveCaptureState>.Continuation?
        states = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation!
    }

    func start() {
        guard clockTask == nil else { return }

        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { break }
                await self?.emit()
            }
        }
    }

    func stop() {
        clockTask?.cancel()
        clockTask = nil
    }

    func reset() {
        latestGimbal = nil
        latestVideoFrame = nil
        latestCameraMotion = nil
        continuation.yield(.initial)
    }

    func submit(gimbal snapshot: GimbalSnapshot) {
        latestGimbal = snapshot
        emit()
    }

    func submit(video tick: VideoFrameTick) {
        latestVideoFrame = tick
        emit()
    }

    func submit(cameraMotion snapshot: CameraMotionSnapshot) {
        latestCameraMotion = snapshot
        emit()
    }

    private func emit() {
        let now = Date()
        var state = LiveCaptureState.initial
        state.gimbal = latestGimbal ?? .waiting
        state.latestVideoFrame = latestVideoFrame
        state.latestCameraMotion = latestCameraMotion ?? .waiting

        if let video = latestVideoFrame {
            state.videoAge = max(0, now.timeIntervalSince(video.receivedAt))
        }

        if let cameraMotion = latestCameraMotion,
           cameraMotion.hasSample,
           let cameraMotionDate = cameraMotion.timestamp {
            state.cameraMotionAge = max(0, now.timeIntervalSince(cameraMotionDate))
        }

        if let video = latestVideoFrame,
           let cameraMotion = latestCameraMotion,
           cameraMotion.hasSample,
           let cameraMotionDate = cameraMotion.timestamp {
            state.cameraMotionSyncDelta = abs(video.receivedAt.timeIntervalSince(cameraMotionDate))
        }

        state.isStale = [state.videoAge, state.cameraMotionAge]
            .compactMap { $0 }
            .contains { $0 > staleAfter }

        state.currentError = latestCameraMotion?.errorMessage ?? latestGimbal?.errorMessage
        continuation.yield(state)
    }
}
