import Foundation
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
}
