import SwiftUI

struct CaptureControlsView: View {
    let mode: CaptureSessionMode?
    let archive: CaptureArchiveDescriptor?
    let archiveExportURL: URL?
    let transportStatus: TransportStatus
    let startOffline: () -> Void
    let startRealtime: () -> Void
    let stop: () -> Void
    let exportArchive: () -> Void
    let showSessions: () -> Void
    let showBackendSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("采集会话", systemImage: mode == nil ? "record.circle" : "record.circle.fill")
                .font(.headline)

            if let mode {
                HStack {
                    Text(mode == .offline ? "离线录制中" : "实时录制中")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Circle().fill(.red).frame(width: 10, height: 10).accessibilityHidden(true)
                }
                if mode == .realtime {
                    LabeledContent("实时参数", value: transportTitle)
                        .accessibilityIdentifier("capture.transportStatus")
                }
                Button("停止并保存会话", action: stop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("capture.stop")
            } else {
                Text("预览运行中，选择一种采集模式")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("离线采集", action: startOffline)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("capture.startOffline")
                    Button("实时采集", action: startRealtime)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("capture.startRealtime")
                }
                Button("配置后端", action: showBackendSettings)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("capture.backendSettings")
                Button("历史会话", action: showSessions)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("capture.sessions")
            }

            if archive != nil {
                HStack {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Group {
                        if let archiveExportURL {
                            ShareLink(item: archiveExportURL) {
                                Label("分享 ZIP", systemImage: "square.and.arrow.up")
                            }
                        } else {
                            Button("生成 ZIP", action: exportArchive)
                        }
                    }
                    .accessibilityIdentifier("capture.export")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.controls")
    }

    private var transportTitle: String {
        switch transportStatus.state {
        case .disabled: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reconnecting: return "重连中"
        case .failed: return "连接错误"
        }
    }
}

struct CaptureSessionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var archives: [CaptureArchiveDescriptor] = []
    @State private var exportedURLs: [UUID: URL] = [:]
    private let store = CaptureArchiveStore()
    private let exporter = CaptureArchiveExporter()

    var body: some View {
        NavigationStack {
            List {
                if archives.isEmpty {
                    ContentUnavailableView(
                        "暂无采集会话",
                        systemImage: "archivebox",
                        description: Text("停止一次离线或实时采集后，会话会出现在这里。")
                    )
                } else {
                    ForEach(archives) { archive in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(archive.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.headline)
                            LabeledContent("模式", value: archive.lifecycle == .interrupted ? "已中断" : "已保存")
                            LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: archive.sizeBytes, countStyle: .file))
                            HStack {
                                if let exportedURL = exportedURLs[archive.id] {
                                    ShareLink(item: exportedURL) {
                                        Label("分享 ZIP", systemImage: "square.and.arrow.up")
                                    }
                                } else {
                                    Button("生成 ZIP") {
                                        Task {
                                            if let url = try? await exporter.export(archive) {
                                                exportedURLs[archive.id] = url
                                            }
                                        }
                                    }
                                }
                                Spacer()
                                Button("删除", role: .destructive) {
                                    try? FileManager.default.removeItem(at: archive.url)
                                    archives = store.list()
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("capture.session.\(archive.id.uuidString)")
                    }
                }
            }
            .navigationTitle("历史会话")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { archives = store.list() }
        }
    }
}

struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var token: String
    @State private var deviceName: String
    let onSave: (FieldEndpointConfiguration) -> Void

    init(onSave: @escaping (FieldEndpointConfiguration) -> Void) {
        let configuration = FieldEndpointConfiguration.load() ?? .empty
        _baseURL = State(initialValue: configuration.baseURLString)
        _token = State(initialValue: configuration.bearerToken)
        _deviceName = State(initialValue: configuration.deviceName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tailnet 后端") {
                    TextField("HTTPS 地址", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("设备 Token", text: $token)
                    TextField("设备名称", text: $deviceName)
                }
                Section {
                    Text("第一版只连接同一 Tailnet 内的后端。实时视频使用 SRT，参数使用 WSS。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("后端配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(FieldEndpointConfiguration(baseURLString: baseURL, bearerToken: token, deviceName: deviceName))
                        dismiss()
                    }
                    .disabled(URL(string: baseURL) == nil)
                }
            }
        }
    }
}

struct ConnectionStatusView: View {
    let snapshot: GimbalSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DockKit 云台", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)

            HStack {
                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }

            LabeledContent("名称", value: snapshot.accessoryName ?? "—")
            LabeledContent("型号", value: snapshot.hardwareModel ?? "—")
            LabeledContent("固件", value: snapshot.firmwareVersion ?? "—")
            LabeledContent("DockKit运动流", value: motionStatusTitle)
                .accessibilityIdentifier("gimbal.motionStreamStatus")
            LabeledContent("DockKit样本数", value: String(snapshot.motionSampleCount))
                .accessibilityIdentifier("gimbal.motionSampleCount")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gimbal.connectionStatus")
    }

    private var statusTitle: String {
        switch snapshot.connectionState {
        case .waiting:
            return "等待连接"
        case .docked:
            return "已连接"
        case .undocked:
            return "已断开"
        case .unsupported:
            return "不可用"
        case .failed:
            return "连接错误"
        }
    }

    private var statusColor: Color {
        switch snapshot.connectionState {
        case .docked:
            return .green
        case .failed, .unsupported:
            return .red
        default:
            return .yellow
        }
    }

    private var motionStatusTitle: String {
        switch snapshot.motionStreamStatus {
        case .waitingForFirstSample:
            return "等待首帧"
        case .streaming:
            return "采集中"
        case .ended:
            return "已结束"
        case .failed:
            return "错误"
        }
    }
}

struct CameraMotionMetricsView: View {
    let snapshot: CameraMotionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("相机姿态", systemImage: "rotate.3d")
                .font(.headline)

            LabeledContent("数据源", value: "iPhone Core Motion")
            LabeledContent("参照系", value: snapshot.referenceFrame.displayName)

            Text("姿态角（弧度）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            MetricRow(label: "Pitch", value: formatted(snapshot.pitch))
            MetricRow(label: "Yaw", value: formatted(snapshot.yaw))
            MetricRow(label: "Roll", value: formatted(snapshot.roll))

            Text("设备轴角速度（弧度/秒）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            MetricRow(label: "X", value: formatted(snapshot.rotationRateX))
            MetricRow(label: "Y", value: formatted(snapshot.rotationRateY))
            MetricRow(label: "Z", value: formatted(snapshot.rotationRateZ))

            LabeledContent("相机姿态流", value: motionStatusTitle)
                .accessibilityIdentifier("camera.motionStatus")
            LabeledContent("样本数", value: String(snapshot.sampleCount))
                .accessibilityIdentifier("camera.motionSampleCount")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.metrics")
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }

    private var motionStatusTitle: String {
        switch snapshot.status {
        case .waitingForFirstSample:
            return "等待首帧"
        case .streaming:
            return "采集中"
        case .unavailable:
            return "不可用"
        case .failed:
            return "错误"
        }
    }
}

struct SynchronizationStatusView: View {
    let state: LiveCaptureState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("实时同步", systemImage: "arrow.left.arrow.right")
                .font(.headline)

            Text(syncTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(syncColor)

            MetricRow(label: "视频接收时间", value: dateText(state.latestVideoFrame?.receivedAt))
            MetricRow(label: "相机姿态时间", value: dateText(state.latestCameraMotion?.timestamp))
            MetricRow(label: "视频 / 相机姿态时间差", value: durationText(state.cameraMotionSyncDelta))
            MetricRow(label: "视频数据 age", value: durationText(state.videoAge))
            MetricRow(label: "相机姿态数据 age", value: durationText(state.cameraMotionAge))

            if let tick = state.latestVideoFrame {
                MetricRow(
                    label: "帧 / 尺寸",
                    value: "\(tick.sequence) / \(tick.frameWidth)×\(tick.frameHeight)"
                )
                MetricRow(
                    label: "丢帧",
                    value: String(tick.droppedFrameCount)
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.status")
    }

    private var syncTitle: String {
        if !state.gimbal.isConnected {
            switch state.gimbal.connectionState {
            case .waiting:
                return "等待云台连接"
            case .undocked:
                return "云台已断开"
            case .unsupported:
                return "DockKit 不可用"
            case .failed:
                return "DockKit 连接错误"
            case .docked:
                break
            }
        }
        if state.latestCameraMotion?.hasSample != true {
            switch state.cameraMotionStatus {
            case .waitingForFirstSample, .streaming:
                return "等待首个相机姿态样本"
            case .unavailable:
                return "相机姿态不可用"
            case .failed:
                return "相机姿态错误"
            }
        }
        if state.isVideoStale && state.isCameraMotionStale {
            return "视频与相机姿态数据已过期"
        }
        if state.isVideoStale {
            return "视频数据已过期"
        }
        if state.isCameraMotionStale {
            return "相机姿态数据已过期"
        }
        if state.latestVideoFrame == nil {
            return "等待视频帧"
        }
        if state.latestCameraMotion?.timestamp == nil {
            return "等待相机姿态时间"
        }
        return "最新状态已对齐"
    }

    private var syncColor: Color {
        if state.cameraMotionStatus.errorMessage != nil {
            return .red
        }
        if state.latestCameraMotion?.hasSample != true {
            return .yellow
        }
        return state.isStale ? .orange : .green
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "—" }
        return String(format: "%.3f s", duration)
    }
}

struct CaptureErrorView: View {
    let message: String?

    var body: some View {
        if let message {
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capture.error")
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}
