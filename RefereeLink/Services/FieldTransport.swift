import AVFoundation
import CryptoKit
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
    func activateLiveEpoch(_ streamEpoch: Int) async
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
    private var reconnectTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingItems: [[String: Any]] = []
    private var clientSequence = 0
    private var activeLiveEpoch: Int?
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
            request.httpBody = try FieldWire.encoder.encode(body)
            let (_, registrationResponse) = try await URLSession.shared.data(for: request)
            try validate(response: registrationResponse)

            let webSocketURL = try makeWebSocketURL(from: baseURL, sessionId: sessionId)
            var webSocketRequest = URLRequest(url: webSocketURL)
            addAuthorization(to: &webSocketRequest)
            let task = URLSession.shared.webSocketTask(with: webSocketRequest)
            socket = task
            task.resume()
            clientSequence = 0
            try await sendJSON([
                "type": "hello",
                "schema_version": FieldWire.schemaVersion,
                "session_id": sessionId.uuidString,
                "device_id": CaptureArchiveRecorder.deviceId.uuidString,
                "client_sequence": clientSequence
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
        if let activeLiveEpoch, let sessionId {
            await releaseLive(sessionId: sessionId, epoch: activeLiveEpoch)
        }
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingItems.removeAll()
        activeLiveEpoch = nil
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
            let allocation = try FieldWire.decoder.decode(LiveTransportAllocation.self, from: data)
            activeLiveEpoch = allocation.streamEpoch
            return allocation
        } catch {
            logger.error("Live video allocation failed: \(error.localizedDescription, privacy: .public)")
            updateStatus(state: .failed, error: error.localizedDescription)
            return nil
        }
    }

    func activateLiveEpoch(_ streamEpoch: Int) async {
        guard activeLiveEpoch == streamEpoch else { return }

        // Items produced while the SRT connection was being negotiated belong
        // to no encoded epoch. Do not relabel them under the new epoch when a
        // delayed flush task wakes up.
        flushTask?.cancel()
        flushTask = nil
        pendingItems.removeAll(keepingCapacity: true)

        status = TransportStatus(
            state: status.state,
            streamEpoch: streamEpoch,
            sentFrameCount: status.sentFrameCount,
            sentMotionCount: status.sentMotionCount,
            droppedFrameCount: status.droppedFrameCount,
            lastError: nil
        )
        statusContinuation.yield(status)
    }

    func send(frame: CapturedFrameMetadata) async {
        await enqueueTelemetry(type: "frame", payload: frame)
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
        await enqueueTelemetry(type: "camera_motion", payload: motion)
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
        await enqueueTelemetry(type: "dock", payload: dock)
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
        let data = try Data(contentsOf: file)
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            forHTTPHeaderField: "Content-SHA256"
        )
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

    private func enqueueTelemetry<T: Encodable>(type: String, payload: T) async {
        guard socket != nil else { return }
        do {
            var item: [String: Any] = ["type": type]
            let payloadObject = try FieldWire.jsonObject(payload)
            if let fields = payloadObject as? [String: Any] {
                item.merge(fields) { _, new in new }
            } else {
                item["payload"] = payloadObject
            }
            guard pendingItems.count < 256 else {
                updateStatus(state: .reconnecting, error: "实时参数队列已满")
                return
            }
            pendingItems.append(item)
            if flushTask == nil {
                flushTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.flushTelemetry()
                }
            }
        } catch {
            updateStatus(state: .reconnecting, error: error.localizedDescription)
        }
    }

    private func flushTelemetry() async {
        defer { flushTask = nil }
        guard let sessionId, socket != nil, !pendingItems.isEmpty else { return }
        let items = pendingItems
        pendingItems.removeAll(keepingCapacity: true)
        clientSequence += 1
        do {
            try await sendJSON([
                "type": "telemetry_batch",
                "schema_version": FieldWire.schemaVersion,
                "session_id": sessionId.uuidString,
                "stream_epoch": status.streamEpoch,
                "client_sequence": clientSequence,
                "items": items
            ])
            // A single transient send failure must not leave the UI stuck in
            // “reconnecting” after the same socket has recovered and accepted
            // subsequent telemetry.
            markConnectedIfSocketAlive()
        } catch {
            updateStatus(state: .reconnecting, error: error.localizedDescription)
            scheduleReconnect()
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
                let message = try await socket.receive()
                switch message {
                case .string(let string):
                    if let data = string.data(using: .utf8) { handleServerMessage(data) }
                case .data(let data):
                    handleServerMessage(data)
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                updateStatus(state: .reconnecting, error: error.localizedDescription)
                scheduleReconnect()
                return
            }
        }
    }

    private func handleServerMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "hello_ack", "telemetry_ack":
            markConnectedIfSocketAlive()
            return
        case "error":
            updateStatus(state: .reconnecting, error: object["detail"] as? String ?? "后端拒绝了实时参数")
        default:
            return
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let configuration, let sessionId else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.reconnectSocket(configuration: configuration, sessionId: sessionId)
        }
    }

    private func reconnectSocket(configuration: FieldEndpointConfiguration, sessionId: UUID) async {
        defer { reconnectTask = nil }
        guard let baseURL = configuration.baseURL, !Task.isCancelled else { return }
        do {
            let webSocketURL = try makeWebSocketURL(from: baseURL, sessionId: sessionId)
            var request = URLRequest(url: webSocketURL)
            addAuthorization(to: &request)
            let task = URLSession.shared.webSocketTask(with: request)
            socket = task
            task.resume()
            try await sendJSON([
                "type": "hello",
                "schema_version": FieldWire.schemaVersion,
                "session_id": sessionId.uuidString,
                "device_id": CaptureArchiveRecorder.deviceId.uuidString,
                "client_sequence": clientSequence
            ])
            receiveTask?.cancel()
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
            updateStatus(state: .connected, error: nil)
        } catch {
            updateStatus(state: .reconnecting, error: error.localizedDescription)
            scheduleReconnect()
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

    private func releaseLive(sessionId: UUID, epoch: Int) async {
        guard let baseURL = configuration?.baseURL else { return }
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                "api/v1/field/sessions/\(sessionId.uuidString)/live/\(epoch)"
            )
        )
        request.httpMethod = "DELETE"
        addAuthorization(to: &request)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try validate(response: response)
        } catch {
            logger.error(
                "live epoch release failed epoch=\(epoch) error=\(String(reflecting: error), privacy: .public)"
            )
        }
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

    private func markConnectedIfSocketAlive() {
        guard socket != nil, status.state == .reconnecting else { return }
        updateStatus(state: .connected, error: nil)
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
    private let logger = Logger(
        subsystem: "io.github.refereelink-team.RefereeLink",
        category: "SRTVideo"
    )
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
            URLQueryItem(name: "passphrase", value: allocation.streamToken),
            URLQueryItem(name: "streamid", value: streamId)
        ]
        guard let url = components.url else { throw FieldTransportError.invalidEndpoint }
        logger.info(
            "connecting host=\(allocation.srtHost, privacy: .public) port=\(allocation.srtPort) epoch=\(allocation.streamEpoch)"
        )
        do {
            try await connection.connect(url)
            let isConnected = await connection.connected
            logger.info("connected epoch=\(allocation.streamEpoch) isConnected=\(isConnected)")
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
            logger.info("publishing video epoch=\(allocation.streamEpoch)")
            self.connection = connection
            self.stream = stream
        } catch {
            logger.error("connect failed epoch=\(allocation.streamEpoch) error=\(String(reflecting: error), privacy: .public)")
            await connection.close()
            throw error
        }
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
        let arguments = ProcessInfo.processInfo.arguments
        if let baseURLString = argumentValue("--field-endpoint", in: arguments),
           let bearerToken = argumentValue("--field-token", in: arguments),
           !baseURLString.isEmpty,
           !bearerToken.isEmpty {
            return FieldEndpointConfiguration(
                baseURLString: baseURLString,
                bearerToken: bearerToken,
                deviceName: argumentValue("--field-device-name", in: arguments) ?? "iPhone"
            )
        }
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(FieldEndpointConfiguration.self, from: data),
              configuration.baseURL != nil else {
            return nil
        }
        return configuration
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    func save() {
        guard let data = try? JSONEncoder.refereeLink.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
