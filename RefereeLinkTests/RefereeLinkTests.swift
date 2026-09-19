import Foundation
import AVFoundation
import CryptoKit
import Testing
@testable import RefereeLink

@MainActor
struct RefereeLinkTests {
    @Test
    func dockKitAxesUsePitchYawRollInRadians() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = GimbalSnapshot(
            identifier: UUID(uuidString: "7E728D42-30A3-4430-9D1D-EA774A3A7B12"),
            accessoryName: "Test Stand",
            hardwareModel: "Test Model",
            firmwareVersion: "1.0",
            connectionState: .docked,
            pitch: 0.1,
            yaw: -0.2,
            roll: 0.3,
            pitchAngularVelocity: 0.01,
            yawAngularVelocity: -0.02,
            rollAngularVelocity: 0.03,
            timestamp: timestamp,
            errorMessage: nil,
            motionStreamStatus: .streaming,
            motionSampleCount: 1
        )

        #expect(snapshot.pitch == 0.1)
        #expect(snapshot.yaw == -0.2)
        #expect(snapshot.roll == 0.3)
        #expect(snapshot.pitchAngularVelocity == 0.01)
        #expect(snapshot.yawAngularVelocity == -0.02)
        #expect(snapshot.rollAngularVelocity == 0.03)
        #expect(snapshot.timestamp == timestamp)
    }

    @Test
    func connectionStatesRepresentReconnectTransitions() {
        let undocked = GimbalSnapshot(
            identifier: nil,
            accessoryName: nil,
            hardwareModel: nil,
            firmwareVersion: nil,
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

        #expect(GimbalSnapshot.waiting.connectionState == .waiting)
        #expect(undocked.connectionState == .undocked)
        #expect(GimbalSnapshot.failed("stream ended").connectionState == .failed)
        #expect(GimbalSnapshot.failed("stream ended").errorMessage == "stream ended")
        #expect(GimbalSnapshot.failed("stream ended").timestamp == nil)
        #expect(GimbalSnapshot.failed("stream ended").motionStreamStatus == .failed("stream ended"))
    }

    @Test
    func coordinatorMergesLatestVideoAndCameraMotionState() async {
        let coordinator = SyncCoordinator(staleAfter: 1)
        let stream = coordinator.states
        await coordinator.start()

        let motionDate = Date()
        let gimbal = GimbalSnapshot(
            identifier: UUID(uuidString: "7E728D42-30A3-4430-9D1D-EA774A3A7B12"),
            accessoryName: "Test Stand",
            hardwareModel: "Test Model",
            firmwareVersion: "1.0",
            connectionState: .docked,
            pitch: 0.1,
            yaw: 0.2,
            roll: 0.3,
            pitchAngularVelocity: 0,
            yawAngularVelocity: 0,
            rollAngularVelocity: 0,
            timestamp: nil,
            errorMessage: nil,
            motionStreamStatus: .streaming,
            motionSampleCount: 1
        )
        let motion = CameraMotionSnapshot(
            pitch: 0.1,
            yaw: 0.2,
            roll: 0.3,
            rotationRateX: 0,
            rotationRateY: 0,
            rotationRateZ: 0,
            sourceTimestamp: 1_700_000_000,
            timestamp: motionDate,
            sampleCount: 1,
            status: .streaming,
            referenceFrame: .xArbitraryZVertical,
            errorMessage: nil
        )
        let tick = VideoFrameTick(
            sequence: 8,
            presentationTimestamp: 0.8,
            receivedAt: motionDate.addingTimeInterval(0.04),
            frameWidth: 1280,
            frameHeight: 720,
            droppedFrameCount: 2
        )

        await coordinator.submit(gimbal: gimbal)
        await coordinator.submit(cameraMotion: motion)
        await coordinator.submit(video: tick)
        var iterator = stream.makeAsyncIterator()
        let state = await iterator.next()
        await coordinator.stop()

        #expect(state?.gimbal == gimbal)
        #expect(state?.latestCameraMotion == motion)
        #expect(state?.latestVideoFrame == tick)
        #expect(abs((state?.cameraMotionSyncDelta ?? 0) - 0.04) < 0.0001)
        #expect(state?.isStale == false)
    }

    @Test
    func coordinatorMarksOldDataAsStale() async {
        let coordinator = SyncCoordinator(staleAfter: 0.1)
        let stream = coordinator.states
        let oldDate = Date(timeIntervalSinceNow: -1)
        let tick = VideoFrameTick(
            sequence: 1,
            presentationTimestamp: 0,
            receivedAt: oldDate,
            frameWidth: 640,
            frameHeight: 480,
            droppedFrameCount: 0
        )
        let motion = CameraMotionSnapshot(
            pitch: 0,
            yaw: 0,
            roll: 0,
            rotationRateX: 0,
            rotationRateY: 0,
            rotationRateZ: 0,
            sourceTimestamp: 1_700_000_000,
            timestamp: oldDate,
            sampleCount: 1,
            status: .streaming,
            referenceFrame: .xArbitraryZVertical,
            errorMessage: nil
        )

        await coordinator.submit(cameraMotion: motion)
        await coordinator.submit(video: tick)
        var iterator = stream.makeAsyncIterator()
        let state = await iterator.next()

        #expect(state?.isStale == true)
        #expect(state?.videoAge ?? 0 > 0.1)
        #expect(state?.cameraMotionAge ?? 0 > 0.1)
    }

    @Test
    func coordinatorDoesNotAgeIdentityWithoutMotionState() async {
        let coordinator = SyncCoordinator(staleAfter: 0.1)
        let stream = coordinator.states
        let identity = GimbalSnapshot(
            identifier: UUID(uuidString: "7E728D42-30A3-4430-9D1D-EA774A3A7B12"),
            accessoryName: "Test Stand",
            hardwareModel: "Test Model",
            firmwareVersion: "1.0",
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

        await coordinator.submit(gimbal: identity)
        await coordinator.submit(
            video: VideoFrameTick(
                sequence: 1,
                presentationTimestamp: 0.1,
                receivedAt: Date(),
                frameWidth: 1280,
                frameHeight: 720,
                droppedFrameCount: 0
            )
        )
        var iterator = stream.makeAsyncIterator()
        let state = await iterator.next()

        #expect(state?.gimbal == identity)
        #expect(state?.latestCameraMotion?.hasSample == false)
        #expect(state?.videoAge != nil)
        #expect(state?.cameraMotionAge == nil)
        #expect(state?.cameraMotionSyncDelta == nil)
        #expect(state?.isStale == false)
    }

    @Test
    func cameraMotionMapsAttitudeRatesAndReferenceFrame() {
        let snapshot = CameraMotionSnapshot(
            pitch: 0.11,
            yaw: -0.22,
            roll: 0.33,
            rotationRateX: 0.01,
            rotationRateY: -0.02,
            rotationRateZ: 0.03,
            sourceTimestamp: 123.4,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sampleCount: 7,
            status: .streaming,
            referenceFrame: .xArbitraryZVertical,
            errorMessage: nil
        )

        #expect(snapshot.pitch == 0.11)
        #expect(snapshot.yaw == -0.22)
        #expect(snapshot.roll == 0.33)
        #expect(snapshot.rotationRateX == 0.01)
        #expect(snapshot.rotationRateY == -0.02)
        #expect(snapshot.rotationRateZ == 0.03)
        #expect(snapshot.referenceFrame == .xArbitraryZVertical)
        #expect(snapshot.hasSample)
    }

    @Test
    func cameraMotionTimestampConvertsUptimeToDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = CameraMotionTimestamp.date(
            from: 102.5,
            now: now,
            systemUptime: 100
        )

        #expect(date == Date(timeIntervalSince1970: 1_700_000_002.5))
    }

    @Test
    func mockCameraMotionProducesDeterministicSamples() async {
        let source = MockCameraMotionSource()
        var iterator = source.snapshots.makeAsyncIterator()

        await source.start()
        let waiting = await iterator.next()
        let first = await iterator.next()
        await source.stop()

        #expect(waiting == .waiting)
        #expect(first?.status == .streaming)
        #expect(first?.sampleCount == 1)
        #expect(first?.pitch == 0.11)
        #expect(abs((first?.yaw ?? 0) - (-0.18)) < 0.0001)
        #expect(first?.rotationRateZ == 0.03)
        #expect(first?.referenceFrame == .xArbitraryZVertical)
    }

    @Test
    func mockCameraMotionScenariosExposeUnavailableErrorAndStale() async {
        let unavailableSource = MockCameraMotionSource(scenario: .unavailable)
        var unavailableIterator = unavailableSource.snapshots.makeAsyncIterator()
        await unavailableSource.start()
        _ = await unavailableIterator.next()
        let unavailable = await unavailableIterator.next()
        await unavailableSource.stop()

        #expect(unavailable == .unavailable)

        let errorSource = MockCameraMotionSource(scenario: .error)
        var errorIterator = errorSource.snapshots.makeAsyncIterator()
        await errorSource.start()
        _ = await errorIterator.next()
        let error = await errorIterator.next()
        await errorSource.stop()

        #expect(error?.status == .failed("Mock Core Motion failed."))
        #expect(error?.errorMessage == "Mock Core Motion failed.")

        let staleSource = MockCameraMotionSource(scenario: .stale)
        var staleIterator = staleSource.snapshots.makeAsyncIterator()
        await staleSource.start()
        _ = await staleIterator.next()
        let stale = await staleIterator.next()
        await staleSource.stop()

        #expect(stale?.hasSample == true)
        #expect(stale?.timestamp ?? Date() < Date(timeIntervalSinceNow: -1))
    }

    @Test
    func mockDockKitProducesDeterministicConnectionAndMotion() async {
        let source = MockDockKitSource()
        var iterator = source.snapshots.makeAsyncIterator()

        await source.start()
        let waiting = await iterator.next()
        let connected = await iterator.next()
        let motion = await iterator.next()
        await source.stop()

        #expect(waiting == .waiting)
        #expect(connected?.identifier == UUID(uuidString: "7E728D42-30A3-4430-9D1D-EA774A3A7B12"))
        #expect(connected?.hardwareModel == "Mock Tracking Stand")
        #expect(connected?.connectionState == .docked)
        #expect(motion?.connectionState == .docked)
        #expect(motion?.pitch != connected?.pitch)
        #expect(connected?.motionStreamStatus == .waitingForFirstSample)
        #expect(motion?.motionStreamStatus == .streaming)
        #expect(motion?.motionSampleCount == 1)
        #expect(motion?.timestamp != nil)
    }

    @Test
    func mockDockKitNoSampleAndStreamTerminationAreObservable() async {
        let noSampleSource = MockDockKitSource(scenario: .noSample)
        var noSampleIterator = noSampleSource.snapshots.makeAsyncIterator()
        await noSampleSource.start()
        _ = await noSampleIterator.next()
        let noSample = await noSampleIterator.next()
        await noSampleSource.stop()

        #expect(noSample?.connectionState == .docked)
        #expect(noSample?.motionStreamStatus == .waitingForFirstSample)
        #expect(noSample?.timestamp == nil)
        #expect(noSample?.motionSampleCount == 0)

        let endedSource = MockDockKitSource(scenario: .normalEnd)
        var endedIterator = endedSource.snapshots.makeAsyncIterator()
        await endedSource.start()
        _ = await endedIterator.next()
        _ = await endedIterator.next()
        _ = await endedIterator.next()
        let ended = await endedIterator.next()
        await endedSource.stop()

        #expect(ended?.motionStreamStatus == .ended)
        #expect(ended?.motionSampleCount == 1)
        #expect(ended?.pitch == nil)
        #expect(ended?.timestamp == nil)
    }

    @Test
    func mockDockKitStreamErrorKeepsConnectionSeparateFromMotionFailure() async {
        let source = MockDockKitSource(scenario: .streamError)
        var iterator = source.snapshots.makeAsyncIterator()
        await source.start()
        _ = await iterator.next()
        let connected = await iterator.next()
        let failed = await iterator.next()
        await source.stop()

        #expect(connected?.connectionState == .docked)
        #expect(failed?.connectionState == .docked)
        #expect(failed?.motionStreamStatus == .failed("Mock motion stream error."))
        #expect(failed?.errorMessage == "Mock motion stream error.")
        #expect(failed?.timestamp == nil)
    }

    @Test
    func mockDockKitReconnectResetsSampleCountAndClearsOldMotion() async {
        let source = MockDockKitSource(scenario: .reconnect)
        var iterator = source.snapshots.makeAsyncIterator()
        await source.start()
        _ = await iterator.next()
        _ = await iterator.next()
        let firstMotion = await iterator.next()
        let undocked = await iterator.next()
        let reconnected = await iterator.next()
        let secondMotion = await iterator.next()
        await source.stop()

        #expect(firstMotion?.motionSampleCount == 1)
        #expect(undocked?.connectionState == .undocked)
        #expect(undocked?.pitch == nil)
        #expect(reconnected?.motionStreamStatus == .waitingForFirstSample)
        #expect(reconnected?.motionSampleCount == 0)
        #expect(secondMotion?.motionSampleCount == 1)
    }

    @Test
    func mockCameraProducesFramesWithPresentationTime() async throws {
        let source = MockCameraCaptureService()
        var iterator = source.frameTicks.makeAsyncIterator()

        try await source.start()
        let first = await iterator.next()
        let second = await iterator.next()
        await source.stop()

        #expect(first?.sequence == 1)
        #expect(first?.presentationTimestamp == 0.1)
        #expect(second?.sequence == 2)
        #expect(second?.frameWidth == 1280)
        #expect(second?.frameHeight == 720)
    }

    @Test
    func captureClockMapsSourceUptimeToSessionAndWallClock() {
        let anchor = CaptureClockAnchor(
            wallClockUnixUs: 1_700_000_000_000_000,
            systemUptimeUs: 42_000_000,
            hostTimeUs: nil,
            uncertaintyUs: 1_000
        )

        #expect(CaptureClock.sessionTimeUs(sourceTimestamp: 42.125, anchor: anchor) == 125_000)
        #expect(CaptureClock.unixDate(from: 42.125, anchor: anchor).timeIntervalSince1970 == 1_700_000_000.125)
    }

    @Test
    func transportPTSIsRelativeToTheEncodedStreamEpoch() {
        #expect(
            CaptureClock.transportPTS90k(
                presentationTimestampValue: 1_000,
                presentationTimestampScale: 1_000,
                originValue: 1_000
            ) == 0
        )
        #expect(
            CaptureClock.transportPTS90k(
                presentationTimestampValue: 1_033,
                presentationTimestampScale: 1_000,
                originValue: 1_000
            ) == 2_970
        )
        #expect(
            CaptureClock.transportPTS90k(
                presentationTimestampValue: 1_264_135_522_700,
                presentationTimestampScale: 10_000,
                originValue: 1_264_135_522_700
            ) == 0
        )
        #expect(
            CaptureClock.transportPTS90k(
                presentationTimestampValue: 1_000,
                presentationTimestampScale: 1_000,
                originValue: nil
            ) == nil
        )
    }

    @Test
    func fieldWirePreservesRelativeTransportPTSWithoutSynthesizingAbsolutePTS() throws {
        let frame = CapturedFrameMetadata(
            sessionId: UUID(),
            streamEpoch: 3,
            frameId: 1,
            tUs: 0,
            captureUnixUs: 1_700_000_000_000_000,
            presentationTimestampValue: 1_264_135_522_700,
            presentationTimestampScale: 10_000,
            transportPts90k: 0,
            width: 1280,
            height: 720,
            droppedFrameCount: 0,
            cameraConfigurationId: "default-720p30",
            cameraMotionSampleId: nil,
            cameraMotionAgeUs: nil,
            poseMissingReason: nil
        )

        let object = try FieldWire.jsonObject(frame) as! [String: Any]
        #expect((object["transport_pts90k"] as? NSNumber)?.int64Value == 0)
        #expect((object["presentation_timestamp_value"] as? NSNumber)?.int64Value == 1_264_135_522_700)
    }

    @Test
    func captureContractRoundTripsManifestAndMotionSample() throws {
        let sessionID = UUID(uuidString: "E2D2A4EA-C18A-42ED-B0AE-88F2FDCC7E50")!
        let manifest = CaptureSessionManifest.initial(
            sessionId: sessionID,
            deviceId: UUID(uuidString: "15F6CE86-97AA-4E93-A4E7-D6D2A6EF8324")!,
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            clockAnchors: []
        )
        let sample = CameraMotionSample(
            sampleId: 7,
            tUs: 123_000,
            sourceTimestamp: 42.123,
            pitch: 0.1,
            yaw: -0.2,
            roll: 0.3,
            quaternionX: 0,
            quaternionY: 0,
            quaternionZ: 0,
            quaternionW: 1,
            rotationRateX: 0.01,
            rotationRateY: -0.02,
            rotationRateZ: 0.03,
            gravityX: 0,
            gravityY: 0,
            gravityZ: -1,
            userAccelerationX: 0,
            userAccelerationY: 0,
            userAccelerationZ: 0,
            referenceFrame: "xArbitraryZVertical",
            status: "streaming",
            error: nil
        )

        let encoder = JSONEncoder.refereeLink
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedManifest = try decoder.decode(
            CaptureSessionManifest.self,
            from: encoder.encode(manifest)
        )
        let decodedSample = try decoder.decode(
            CameraMotionSample.self,
            from: encoder.encode(sample)
        )

        #expect(decodedManifest == manifest)
        #expect(decodedSample == sample)
        #expect(decodedSample.referenceFrame == "xArbitraryZVertical")
        #expect(decodedSample.rotationRateZ == 0.03)
    }

    @Test
    func fieldWireUsesSnakeCaseAndUnifiedTelemetryBatch() throws {
        let sample = CameraMotionSample(
            sampleId: 7,
            tUs: 123_000,
            sourceTimestamp: 42.123,
            pitch: 0.1,
            yaw: -0.2,
            roll: 0.3,
            quaternionX: 0,
            quaternionY: 0,
            quaternionZ: 0,
            quaternionW: 1,
            rotationRateX: 0.01,
            rotationRateY: -0.02,
            rotationRateZ: 0.03,
            gravityX: 0,
            gravityY: 0,
            gravityZ: -1,
            userAccelerationX: 0,
            userAccelerationY: 0,
            userAccelerationZ: 0,
            referenceFrame: "xArbitraryZVertical",
            status: "streaming",
            error: nil
        )
        let item = try FieldTelemetryItem(type: "camera_motion", payload: sample)
        let batch = FieldTelemetryBatch(
            type: "telemetry_batch",
            schemaVersion: "1.0",
            sessionId: UUID(),
            streamEpoch: 1,
            clientSequence: 3,
            items: [item]
        )
        let json = try String(decoding: FieldWire.encoder.encode(batch), as: UTF8.self)
        #expect(json.contains("telemetry_batch"))
        #expect(json.contains("client_sequence"))
        #expect(json.contains("sample_id"))
        #expect(!json.contains("sampleId"))
    }

    @Test
    func mockCameraProducesBoundedSampleBuffers() async throws {
        let source = MockCameraCaptureService()
        var iterator = source.frameSamples.makeAsyncIterator()

        try await source.start()
        let sample = await iterator.next()
        await source.stop()

        #expect(sample != nil)
        #expect(sample?.tick.frameWidth == 1280)
        #expect(sample?.tick.frameHeight == 720)
        #expect(sample.map { CMSampleBufferDataIsReady($0.sampleBuffer) } == true)
    }

    @Test
    func archiveExporterCreatesStandardZipWithoutMutatingSource() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RefereeLinkExport-\(UUID().uuidString).rlcapture", isDirectory: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("metadata"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data("frame\n".utf8).write(to: root.appendingPathComponent("metadata/frames.ndjson"))
        defer { try? fileManager.removeItem(at: root) }

        let descriptor = CaptureArchiveDescriptor(
            id: UUID(),
            url: root,
            createdAt: Date(),
            sizeBytes: 0,
            lifecycle: .stopped
        )
        let zipURL = try await CaptureArchiveExporter().export(descriptor)
        defer { try? fileManager.removeItem(at: zipURL) }

        #expect(fileManager.fileExists(atPath: zipURL.path))
        #expect((try? Data(contentsOf: zipURL).count) ?? 0 > 0)
        #expect(fileManager.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    }

    @Test
    func testFieldReceiverJoinsOnlyRecentMotionBeforeFrame() async throws {
        let receiver = TestFieldReceiver()
        let motion = CameraMotionSample(
            sampleId: 4,
            tUs: 100_000,
            sourceTimestamp: 42.1,
            pitch: 0.1,
            yaw: 0.2,
            roll: 0.3,
            quaternionX: 0,
            quaternionY: 0,
            quaternionZ: 0,
            quaternionW: 1,
            rotationRateX: 0,
            rotationRateY: 0,
            rotationRateZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: -1,
            userAccelerationX: 0,
            userAccelerationY: 0,
            userAccelerationZ: 0,
            referenceFrame: "xArbitraryZVertical",
            status: "streaming",
            error: nil
        )
        try await receiver.ingest(motion: motion)

        let frame = CapturedFrameMetadata(
            sessionId: UUID(),
            streamEpoch: 2,
            frameId: 9,
            tUs: 130_000,
            captureUnixUs: 1_700_000_000_130_000,
            presentationTimestampValue: 117_000,
            presentationTimestampScale: 90_000,
            width: 1280,
            height: 720,
            droppedFrameCount: 0,
            cameraConfigurationId: "default-720p30",
            cameraMotionSampleId: motion.sampleId,
            cameraMotionAgeUs: 30_000,
            poseMissingReason: nil
        )
        let joined = try await receiver.ingest(frame: frame)
        #expect(joined.motion == motion)
        #expect(joined.missingReason == nil)

        let staleFrame = CapturedFrameMetadata(
            sessionId: frame.sessionId,
            streamEpoch: frame.streamEpoch,
            frameId: frame.frameId + 1,
            tUs: 200_001,
            captureUnixUs: frame.captureUnixUs,
            presentationTimestampValue: frame.presentationTimestampValue,
            presentationTimestampScale: frame.presentationTimestampScale,
            width: frame.width,
            height: frame.height,
            droppedFrameCount: frame.droppedFrameCount,
            cameraConfigurationId: frame.cameraConfigurationId,
            cameraMotionSampleId: nil,
            cameraMotionAgeUs: nil,
            poseMissingReason: "motion_sample_older_than_50ms"
        )
        let missing = try await receiver.ingest(frame: staleFrame)
        #expect(missing.motion == nil)
        #expect(missing.missingReason == "motion_sample_older_than_50ms")
    }

    @Test
    func testFieldReceiverValidatesArtifactLengthAndHashAndSupportsFaultInjection() async throws {
        let receiver = TestFieldReceiver()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefereeLinkArtifact-\(UUID().uuidString).bin")
        let data = Data("field artifact\n".utf8)
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try await receiver.validateArtifact(
            fileURL: fileURL,
            byteCount: Int64(data.count),
            sha256: hash
        )
        await receiver.inject(.injected)
        await #expect(throws: TestFieldReceiver.Failure.injected) {
            try await receiver.validateArtifact(fileURL: fileURL, byteCount: Int64(data.count), sha256: hash)
        }
    }
}
