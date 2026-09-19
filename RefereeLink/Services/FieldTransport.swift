import AVFoundation
import Foundation
import os

nonisolated struct FieldEndpointConfiguration: Codable, Equatable, Sendable {
    var baseURLString: String
    var bearerToken: String
    var deviceName: String

    var baseURL: URL? { URL(string: baseURLString) }

    static let empty = FieldEndpointConfiguration(
        baseURLString: "",
        bearerToken: "",
        deviceName: "iPhone"
    )
}

nonisolated struct LiveTransportAllocation: Codable, Equatable, Sendable {
    let sessionId: UUID
    let streamEpoch: Int
    let srtHost: String
    let srtPort: Int
    let streamToken: String
    let latencyMs: Int
    let profile: String
}

protocol FieldTransport: AnyObject, Sendable {
    var statuses: AsyncStream<TransportStatus> { get }
    func connect(configuration: FieldEndpointConfiguration, sessionId: UUID) async
    func allocateLive(sessionId: UUID) async -> LiveTransportAllocation?
    func disconnect() async
    func send(frame: CapturedFrameMetadata) async
    func send(motion: CameraMotionSample) async
    func send(dock: DockDiagnosticEvent) async
    func send(sample: CameraFrameSample) async
    func upload(file: URL, artifactId: String, sessionId: UUID) async throws
}

protocol RealtimeVideoTransport: AnyObject, Sendable {
    func connect(allocation: LiveTransportAllocation) async throws
    func append(_ sample: CMSampleBuffer) async
    func disconnect() async
}

actor URLSessionFieldTransport: FieldTransport {
    nonisolated let statuses: AsyncStream<TransportStatus>
    private let statusContinuation: AsyncStream<TransportStatus>.Continuation
    private let logger = Logger(
        subsystem: "io.github.refereelink-team.RefereeLink",
        category: "FieldTransport"
    )
    private var configuration: FieldEndpointConfiguration?
    private var sessionId: UUID?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var status = TransportStatus(
        state: .disabled,
        streamEpoch: 0,
        sentFrameCount: 0,
        sentMotionCount: 0,
        droppedFrameCount: 0,
        lastError: nil
    )

    init() {
        var continuation: AsyncStream<TransportStatus>.Continuation?
        statuses = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        statusContinuation = continuation!
    }

    func connect(configuration: FieldEndpointConfiguration, sessionId: UUID) async {
        guard let baseURL = configuration.baseURL else {
            updateStatus(state: .failed, error: "后端地址无效")
            return
        }
        self.configuration = configuration
        self.sessionId = sessionId
        updateStatus(state: .connecting, error: nil)

        do {
            var capabilitiesRequest = URLRequest(
                url: baseURL.appendingPathComponent("api/v1/field/capabilities")
            )
            capabilitiesRequest.httpMethod = "GET"
            addAuthorization(to: &capabilitiesRequest)
            let (_, capabilitiesResponse) = try await URLSession.shared.data(for: capabilitiesRequest)
            try validate(response: capabilitiesResponse)

            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/field/sessions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            addAuthorization(to: &request)
            let body = FieldSessionRegistration(
                schemaVersion: "1.0",
                sessionId: sessionId,
                deviceId: CaptureArchiveRecorder.deviceId,
                deviceName: configuration.deviceName,
                capabilities: ["srt", "wss", "offline_archive", "core_motion"]
            )
            request.httpBody = try JSONEncoder.refereeLink.encode(body)
            let (_, registrationResponse) = try await URLSession.shared.data(for: request)
            try validate(response: registrationResponse)

            let webSocketURL = try makeWebSocketURL(from: baseURL, sessionId: sessionId)
            var webSocketRequest = URLRequest(url: webSocketURL)
            addAuthorization(to: &webSocketRequest)
            let task = URLSession.shared.webSocketTask(with: webSocketRequest)
            socket = task
            task.resume()
            try await sendJSON([
                "type": "hello",
                "schema_version": "1.0",
                "session_id": sessionId.uuidString,
                "device_id": CaptureArchiveRecorder.deviceId.uuidString
            ])
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            updateStatus(state: .connected, error: nil)
        } catch {
            logger.error("Field transport connection failed: \(error.localizedDescription, privacy: .public)")
            updateStatus(state: .failed, error: error.localizedDescription)
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        updateStatus(state: .disabled, error: nil)
    }

    func allocateLive(sessionId: UUID) async -> LiveTransportAllocation? {
        guard let configuration, let baseURL = configuration.baseURL else {
            updateStatus(state: .failed, error: FieldTransportError.notConfigured.localizedDescription)
            return nil
        }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/field/sessions/\(sessionId.uuidString)/live"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            addAuthorization(to: &request)
            let body = try JSONSerialization.data(withJSONObject: ["profile": "720p30", "latency_ms": 200])
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response)
            let allocation = try JSONDecoder().decode(LiveTransportAllocation.self, from: data)
            status = TransportStatus(
                state: status.state,
                streamEpoch: allocation.streamEpoch,
                sentFrameCount: status.sentFrameCount,
                sentMotionCount: status.sentMotionCount,
                droppedFrameCount: status.droppedFrameCount,
                lastError: nil
            )
            statusContinuation.yield(status)
            return allocation
        } catch {
            logger.error("Live video allocation failed: \(error.localizedDescription, privacy: .public)")
            updateStatus(state: .failed, error: error.localizedDescription)
            return nil
        }
    }

    func send(frame: CapturedFrameMetadata) async {
        await sendTelemetry(type: "frame_batch", payload: frame)
        status = TransportStatus(
            state: status.state,
            streamEpoch: status.streamEpoch,
            sentFrameCount: status.sentFrameCount + 1,
            sentMotionCount: status.sentMotionCount,
            droppedFrameCount: status.droppedFrameCount,
            lastError: status.lastError
        )
        statusContinuation.yield(status)
    }

    func send(motion: CameraMotionSample) async {
        await sendTelemetry(type: "motion_batch", payload: motion)
        status = TransportStatus(
            state: status.state,
            streamEpoch: status.streamEpoch,
            sentFrameCount: status.sentFrameCount,
            sentMotionCount: status.sentMotionCount + 1,
            droppedFrameCount: status.droppedFrameCount,
            lastError: status.lastError
        )
        statusContinuation.yield(status)
    }

    func send(dock: DockDiagnosticEvent) async {
        await sendTelemetry(type: "dock_state", payload: dock)
    }

    func send(sample: CameraFrameSample) async {
        // The video encoder/SRT writer is intentionally injected separately. This
        // method is the bounded hand-off point used by the session coordinator.
        _ = sample
    }

    func upload(file: URL, artifactId: String, sessionId: UUID) async throws {
        guard let configuration, let baseURL = configuration.baseURL else {
            throw FieldTransportError.notConfigured
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/field/sessions/\(sessionId.uuidString)/artifacts/\(artifactId)"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        addAuthorization(to: &request)
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try validate(response: response)
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw FieldTransportError.serverRejected(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
    }

    private func sendTelemetry<T: Encodable>(type: String, payload: T) async {
        guard socket != nil else { return }
        do {
            let payloadData = try JSONEncoder.refereeLink.encode(payload)
            let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
            try await sendJSON([
                "type": type,
                "session_id": sessionId?.uuidString ?? "",
                "payload": payloadObject
            ])
        } catch {
            updateStatus(state: .reconnecting, error: error.localizedDescription)
        }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else { throw FieldTransportError.invalidMessage }
        try await socket?.send(.string(string))
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                _ = try await socket.receive()
            } catch {
                guard !Task.isCancelled else { return }
                updateStatus(state: .reconnecting, error: error.localizedDescription)
                return
            }
        }
    }

    private func makeWebSocketURL(from baseURL: URL, sessionId: UUID) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FieldTransportError.invalidEndpoint
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/v1/field/sessions/\(sessionId.uuidString)"
        guard let url = components.url else { throw FieldTransportError.invalidEndpoint }
        return url
    }

    private func addAuthorization(to request: inout URLRequest) {
        guard let token = configuration?.bearerToken, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func updateStatus(state: TransportConnectionState, error: String?) {
        status = TransportStatus(
            state: state,
            streamEpoch: status.streamEpoch,
            sentFrameCount: status.sentFrameCount,
            sentMotionCount: status.sentMotionCount,
            droppedFrameCount: status.droppedFrameCount,
            lastError: error
        )
        statusContinuation.yield(status)
    }
}

nonisolated struct FieldSessionRegistration: Codable, Sendable {
    let schemaVersion: String
    let sessionId: UUID
    let deviceId: UUID
    let deviceName: String
    let capabilities: [String]
}

enum FieldTransportError: LocalizedError {
    case invalidEndpoint
    case invalidMessage
    case notConfigured
    case srtUnavailable
    case serverRejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "后端地址无效"
        case .invalidMessage: return "实时参数消息无法编码"
        case .notConfigured: return "尚未配置后端连接"
        case .srtUnavailable: return "当前构建未包含 SRT 实时视频传输模块"
        case let .serverRejected(statusCode): return "后端拒绝了请求（HTTP \(statusCode)）"
        }
    }
}

#if canImport(SRTHaishinKit)
import HaishinKit
import SRTHaishinKit

actor NativeSRTVideoTransport: RealtimeVideoTransport {
    private var connection: SRTConnection?
    private var stream: SRTStream?
    private var pendingSamples: [CMSampleBuffer] = []
    private var isDraining = false

    func connect(allocation: LiveTransportAllocation) async throws {
        let connection = SRTConnection()
        let streamId = "refereelink/\(allocation.sessionId.uuidString)/\(allocation.streamEpoch)/\(allocation.streamToken)"
        var components = URLComponents()
        components.scheme = "srt"
        components.host = allocation.srtHost
        components.port = allocation.srtPort
        components.queryItems = [
            URLQueryItem(name: "mode", value: "caller"),
            URLQueryItem(name: "transtype", value: "live"),
            URLQueryItem(name: "latency", value: String(allocation.latencyMs)),
            URLQueryItem(name: "tlpktdrop", value: "1"),
            URLQueryItem(name: "payloadsize", value: "1128"),
            URLQueryItem(name: "streamid", value: streamId)
        ]
        guard let url = components.url else { throw FieldTransportError.invalidEndpoint }
        try await connection.connect(url)
        let stream = SRTStream(connection: connection)
        try await stream.setVideoSettings(
            VideoCodecSettings(
                videoSize: CGSize(width: 1280, height: 720),
                bitRate: 1_500_000,
                profileLevel: kVTProfileLevel_H264_Baseline_3_1 as String,
                maxKeyFrameIntervalDuration: 1,
                allowFrameReordering: false,
                isLowLatencyRateControlEnabled: true,
                expectedFrameRate: 30
            )
        )
        await stream.setExpectedMedias([.video])
        await stream.publish()
        self.connection = connection
        self.stream = stream
    }

    func append(_ sample: CMSampleBuffer) async {
        guard pendingSamples.count < 4 else { return }
        pendingSamples.append(sample)
        guard !isDraining else { return }
        isDraining = true
        while !pendingSamples.isEmpty {
            let next = pendingSamples.removeFirst()
            await stream?.append(next)
        }
        isDraining = false
    }

    func disconnect() async {
        await stream?.close()
        await connection?.close()
        stream = nil
        connection = nil
        pendingSamples.removeAll()
    }
}
#else
actor NativeSRTVideoTransport: RealtimeVideoTransport {
    func connect(allocation: LiveTransportAllocation) async throws {
        _ = allocation
        throw FieldTransportError.srtUnavailable
    }

    func append(_ sample: CMSampleBuffer) async { _ = sample }
    func disconnect() async {}
}
#endif

extension CaptureArchiveRecorder {
    nonisolated(unsafe) static var deviceId: UUID { loadOrCreateDeviceId() }
}

extension FieldEndpointConfiguration {
    private static let storageKey = "RefereeLink.fieldEndpoint"

    static func load() -> FieldEndpointConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(FieldEndpointConfiguration.self, from: data),
              configuration.baseURL != nil else {
            return nil
        }
        return configuration
    }

    func save() {
        guard let data = try? JSONEncoder.refereeLink.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
