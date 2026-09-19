import SwiftUI

struct ContentView: View {
    let model: LiveCaptureModel
    @State private var isShowingBackendSettings = false
    @State private var isShowingCaptureSessions = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                CameraPreviewView(session: model.cameraSession)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(.black)
                    .ignoresSafeArea()

                if model.cameraSession == nil || model.liveState.cameraState != .running {
                    CameraPlaceholderView(cameraState: model.liveState.cameraState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                        .ignoresSafeArea()
                }

                ScrollView {
                    VStack(spacing: 12) {
                        CaptureControlsView(
                            mode: model.captureMode,
                            archive: model.archiveDescriptor,
                            archiveExportURL: model.archiveExportURL,
                            transportStatus: model.transportStatus,
                            startOffline: { startCapture(.offline) },
                            startRealtime: { startCapture(.realtime) },
                            stop: stopCapture,
                            exportArchive: { exportArchive() },
                            showSessions: { isShowingCaptureSessions = true },
                            showBackendSettings: { isShowingBackendSettings = true }
                        )
                        ConnectionStatusView(snapshot: model.liveState.gimbal)
                        CameraMotionMetricsView(snapshot: model.liveState.latestCameraMotion ?? .waiting)
                        SynchronizationStatusView(state: model.liveState)

                        CaptureErrorView(
                            message: model.liveState.currentError
                                ?? model.liveState.gimbal.errorMessage
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .safeAreaPadding(.top, 12)
            }
        }
        .background(.black)
        .task {
            if model.shouldAutoStart {
                await model.start()
                if model.shouldAutoStartRealtime {
                    await model.startCapture(mode: .realtime)
                }
            }
        }
        .onDisappear {
            Task {
                await model.stop()
            }
        }
        .sheet(isPresented: $isShowingBackendSettings) {
            BackendSettingsView { configuration in
                model.configureEndpoint(configuration)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isShowingCaptureSessions) {
            CaptureSessionsView()
        }
    }

    private func startCapture(_ mode: CaptureSessionMode) {
        Task { await model.startCapture(mode: mode) }
    }

    private func stopCapture() {
        Task { await model.stopCapture() }
    }

    private func exportArchive() {
        Task { await model.exportArchive() }
    }
}

private let previewGimbal = GimbalSnapshot(
    identifier: UUID(uuidString: "7E728D42-30A3-4430-9D1D-EA774A3A7B12"),
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

private let previewCameraMotion = CameraMotionSnapshot(
    pitch: 0.120,
    yaw: -0.240,
    roll: 0.030,
    rotationRateX: 0.010,
    rotationRateY: -0.020,
    rotationRateZ: 0.005,
    sourceTimestamp: 1_700_000_004.2,
    timestamp: Date(),
    sampleCount: 42,
    status: .streaming,
    referenceFrame: .xArbitraryZVertical,
    errorMessage: nil
)

private let previewTick = VideoFrameTick(
    sequence: 42,
    presentationTimestamp: 4.2,
    receivedAt: Date(),
    frameWidth: 1280,
    frameHeight: 720,
    droppedFrameCount: 1
)

private let previewRunningState = LiveCaptureState(
    cameraState: .running,
    gimbal: previewGimbal,
    latestVideoFrame: previewTick,
    latestCameraMotion: previewCameraMotion,
    cameraMotionSyncDelta: 0.012,
    videoAge: 0.04,
    cameraMotionAge: 0.03,
    isStale: false,
    currentError: nil
)

private let previewVideoStaleState = LiveCaptureState(
    cameraState: .running,
    gimbal: previewGimbal,
    latestVideoFrame: previewTick,
    latestCameraMotion: previewCameraMotion,
    cameraMotionSyncDelta: 0.220,
    videoAge: 1.2,
    cameraMotionAge: 0.2,
    isStale: true,
    currentError: nil
)

private let previewCameraMotionStaleState = LiveCaptureState(
    cameraState: .running,
    gimbal: previewGimbal,
    latestVideoFrame: previewTick,
    latestCameraMotion: CameraMotionSnapshot(
        pitch: previewCameraMotion.pitch,
        yaw: previewCameraMotion.yaw,
        roll: previewCameraMotion.roll,
        rotationRateX: previewCameraMotion.rotationRateX,
        rotationRateY: previewCameraMotion.rotationRateY,
        rotationRateZ: previewCameraMotion.rotationRateZ,
        sourceTimestamp: previewCameraMotion.sourceTimestamp,
        timestamp: Date(timeIntervalSinceNow: -1.2),
        sampleCount: previewCameraMotion.sampleCount,
        status: .streaming,
        referenceFrame: .xArbitraryZVertical,
        errorMessage: nil
    ),
    cameraMotionSyncDelta: 1.2,
    videoAge: 0.1,
    cameraMotionAge: 1.2,
    isStale: true,
    currentError: nil
)

private let previewErrorState = LiveCaptureState(
    cameraState: .denied,
    gimbal: .failed("Mock DockKit connection failed."),
    latestVideoFrame: nil,
    latestCameraMotion: .failed("Mock Core Motion failed."),
    cameraMotionSyncDelta: nil,
    videoAge: nil,
    cameraMotionAge: nil,
    isStale: false,
    currentError: "Camera permission was denied."
)

#Preview("初始等待") {
    ContentView(model: .preview(.initial))
}

#Preview("云台等待") {
    ContentView(
        model: .preview(
            LiveCaptureState(
                cameraState: .running,
                gimbal: .waiting,
                latestVideoFrame: nil,
                latestCameraMotion: .waiting,
                cameraMotionSyncDelta: nil,
                videoAge: nil,
                cameraMotionAge: nil,
                isStale: false,
                currentError: nil
            )
        )
    )
}

#Preview("等待首个相机姿态") {
    ContentView(
        model: .preview(
            LiveCaptureState(
                cameraState: .running,
                gimbal: previewGimbal,
                latestVideoFrame: previewTick,
                latestCameraMotion: .waiting,
                cameraMotionSyncDelta: nil,
                videoAge: 0.04,
                cameraMotionAge: nil,
                isStale: false,
                currentError: nil
            )
        )
    )
}

#Preview("相机姿态运行") {
    ContentView(model: .preview(previewRunningState))
}

#Preview("视频 stale") {
    ContentView(model: .preview(previewVideoStaleState))
}

#Preview("相机姿态 stale") {
    ContentView(model: .preview(previewCameraMotionStaleState))
}

#Preview("相机姿态不可用") {
    ContentView(
        model: .preview(
            LiveCaptureState(
                cameraState: .running,
                gimbal: previewGimbal,
                latestVideoFrame: previewTick,
                latestCameraMotion: .unavailable,
                cameraMotionSyncDelta: nil,
                videoAge: 0.04,
                cameraMotionAge: nil,
                isStale: false,
                currentError: nil
            )
        )
    )
}

#Preview("错误") {
    ContentView(model: .preview(previewErrorState))
}
