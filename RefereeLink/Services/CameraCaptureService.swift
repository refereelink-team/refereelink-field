import AVFoundation
import Foundation
import os

enum CameraCaptureError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case noCamera
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera permission was denied."
        case .noCamera:
            return "No iPhone camera is available."
        case let .configurationFailed(message):
            return message
        }
    }
}

protocol CameraCaptureSource: AnyObject, Sendable {
    var session: AVCaptureSession? { get }
    var frameTicks: AsyncStream<VideoFrameTick> { get }
    var frameSamples: AsyncStream<CameraFrameSample> { get }
    func start() async throws
    func stop() async
}

nonisolated final class CameraFrameSample: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let tick: VideoFrameTick

    init(sampleBuffer: CMSampleBuffer, tick: VideoFrameTick) {
        self.sampleBuffer = sampleBuffer
        self.tick = tick
    }
}

nonisolated final class NativeCameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, CameraCaptureSource, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    var session: AVCaptureSession? {
        captureSession
    }
    let frameTicks: AsyncStream<VideoFrameTick>
    private let continuation: AsyncStream<VideoFrameTick>.Continuation
    let frameSamples: AsyncStream<CameraFrameSample>
    private let sampleContinuation: AsyncStream<CameraFrameSample>.Continuation
    private let sessionQueue = DispatchQueue(label: "io.github.refereelink.camera-session")
    private let callbackQueue = DispatchQueue(label: "io.github.refereelink.camera-frames")
    private let logger = Logger(
        subsystem: "io.github.refereelink-team.RefereeLink",
        category: "CameraCapture"
    )
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isConfigured = false
    private var sequence = 0
    private var droppedFrameCount = 0

    override init() {
        var continuation: AsyncStream<VideoFrameTick>.Continuation?
        frameTicks = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation!
        var sampleContinuation: AsyncStream<CameraFrameSample>.Continuation?
        frameSamples = AsyncStream(bufferingPolicy: .bufferingNewest(4)) {
            sampleContinuation = $0
        }
        self.sampleContinuation = sampleContinuation!
        super.init()
    }

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            throw CameraCaptureError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.callbackQueue)
                    self.captureSession.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.captureSession.stopRunning()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        sequence += 1
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if sequence == 1 {
            logger.info(
                "First camera video frame: size=\(dimensions.width, privacy: .public)x\(dimensions.height, privacy: .public), presentationTimestamp=\(presentationTimestamp.seconds, privacy: .public)."
            )
        } else if sequence.isMultiple(of: 60) {
            logger.info(
                "Camera video frame count=\(self.sequence, privacy: .public), dropped=\(self.droppedFrameCount, privacy: .public)."
            )
        }

        let tick = VideoFrameTick(
                sequence: sequence,
                presentationTimestamp: presentationTimestamp.isNumeric ? presentationTimestamp.seconds : nil,
                receivedAt: Date(),
                frameWidth: Int(dimensions.width),
                frameHeight: Int(dimensions.height),
                droppedFrameCount: droppedFrameCount,
                presentationTimestampValue: presentationTimestamp.isNumeric ? presentationTimestamp.value : nil,
                presentationTimestampScale: presentationTimestamp.isNumeric ? presentationTimestamp.timescale : nil,
                captureTimeUs: presentationTimestamp.isNumeric ? Int64(presentationTimestamp.seconds * 1_000_000) : nil
            )
        continuation.yield(tick)
        sampleContinuation.yield(CameraFrameSample(sampleBuffer: sampleBuffer, tick: tick))
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrameCount += 1
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) ?? AVCaptureDevice.default(for: .video) else {
            throw CameraCaptureError.noCamera
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else {
                throw CameraCaptureError.configurationFailed("The camera input could not be added.")
            }
            captureSession.addInput(input)

            guard captureSession.canAddOutput(videoOutput) else {
                throw CameraCaptureError.configurationFailed("The camera video output could not be added.")
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
            captureSession.addOutput(videoOutput)
            captureSession.commitConfiguration()
            isConfigured = true
        } catch {
            captureSession.commitConfiguration()
            throw error
        }
    }
}

nonisolated enum MockCameraScenario: Sendable {
    case live
    case stale
    case denied
}

actor MockCameraCaptureService: CameraCaptureSource {
    nonisolated let session: AVCaptureSession? = nil
    nonisolated let frameTicks: AsyncStream<VideoFrameTick>
    nonisolated let frameSamples: AsyncStream<CameraFrameSample>
    private let continuation: AsyncStream<VideoFrameTick>.Continuation
    private let sampleContinuation: AsyncStream<CameraFrameSample>.Continuation
    private let scenario: MockCameraScenario
    private var simulationTask: Task<Void, Never>?
    private var hasStarted = false

    init(scenario: MockCameraScenario = .live) {
        self.scenario = scenario
        var continuation: AsyncStream<VideoFrameTick>.Continuation?
        frameTicks = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation!
        var sampleContinuation: AsyncStream<CameraFrameSample>.Continuation?
        frameSamples = AsyncStream(bufferingPolicy: .bufferingNewest(4)) {
            sampleContinuation = $0
        }
        self.sampleContinuation = sampleContinuation!
    }

    func start() async throws {
        guard !hasStarted else { return }
        hasStarted = true

        switch scenario {
        case .denied:
            hasStarted = false
            throw CameraCaptureError.permissionDenied
        case .stale:
            let tick = VideoFrameTick(
                    sequence: 1,
                    presentationTimestamp: 0,
                    receivedAt: Date(),
                    frameWidth: 1280,
                    frameHeight: 720,
                    droppedFrameCount: 0
                )
            continuation.yield(tick)
            if let sample = Self.makeSampleBuffer(timestamp: 0) {
                sampleContinuation.yield(CameraFrameSample(sampleBuffer: sample, tick: tick))
            }
        case .live:
            simulationTask = Task { [weak self] in
                var sequence = 0
                var timestamp: TimeInterval = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled, let self else { return }
                    sequence += 1
                    timestamp += 0.1
                    await self.publish(
                        VideoFrameTick(
                            sequence: sequence,
                            presentationTimestamp: timestamp,
                            receivedAt: Date(),
                            frameWidth: 1280,
                            frameHeight: 720,
                            droppedFrameCount: 0
                        ),
                        timestamp: timestamp
                    )
                }
            }
        }
    }

    func stop() async {
        simulationTask?.cancel()
        simulationTask = nil
        hasStarted = false
    }

    private func publish(_ tick: VideoFrameTick, timestamp: TimeInterval) {
        continuation.yield(tick)
        if let sample = Self.makeSampleBuffer(timestamp: timestamp) {
            sampleContinuation.yield(CameraFrameSample(sampleBuffer: sample, tick: tick))
        }
    }

    nonisolated private static func makeSampleBuffer(timestamp: TimeInterval) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            1280,
            720,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess,
        let pixelBuffer else { return nil }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

extension CaptureSourceFactory {
    static func makeCameraSource() -> any CameraCaptureSource {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--mock") || arguments.contains(where: { $0.hasPrefix("--mock-camera-") }) {
            if arguments.contains("--mock-camera-denied") {
                return MockCameraCaptureService(scenario: .denied)
            }
            if arguments.contains("--mock-camera-stale") {
                return MockCameraCaptureService(scenario: .stale)
            }
            return MockCameraCaptureService()
        }

        #if targetEnvironment(simulator)
        return MockCameraCaptureService()
        #else
        return NativeCameraCaptureService()
        #endif
    }
}
