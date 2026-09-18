import XCTest

final class RefereeLinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp(useMock: Bool = true, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (useMock ? ["--mock"] : []) + arguments
        app.launch()
        return app
    }

    @MainActor
    func testPageStartsWithAccessibleStatusSections() throws {
        let app = launchApp()

        let connectionStatus = app.descendants(matching: .any)
            .matching(identifier: "gimbal.connectionStatus")
            .firstMatch
        let metrics = app.descendants(matching: .any)
            .matching(identifier: "camera.metrics")
            .firstMatch
        let synchronization = app.descendants(matching: .any)
            .matching(identifier: "sync.status")
            .firstMatch
        let cameraPreview = app.descendants(matching: .any)
            .matching(identifier: "camera.preview")
            .firstMatch

        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(metrics.exists)
        XCTAssertTrue(synchronization.exists)
        XCTAssertTrue(cameraPreview.exists)
    }

    @MainActor
    func testMockConnectionUpdatesIdentityAndMetrics() throws {
        let app = launchApp()

        let identity = app.staticTexts.element(
            matching: NSPredicate(format: "label CONTAINS %@", "RefereeLink Mock Stand")
        )
        XCTAssertTrue(identity.waitForExistence(timeout: 5))

        let hardwareModel = app.staticTexts.element(
            matching: NSPredicate(format: "label CONTAINS %@", "Mock Tracking Stand")
        )
        XCTAssertTrue(hardwareModel.exists)
        let cameraMetrics = app.descendants(matching: .any)
            .matching(identifier: "camera.metrics")
            .firstMatch
        XCTAssertTrue(cameraMetrics.exists)
        XCTAssertTrue(
            app.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "iPhone Core Motion")
            ).exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "camera.motionStatus")
                .firstMatch
                .exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "camera.motionSampleCount")
                .firstMatch
                .exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "sync.status")
                .firstMatch
                .exists
        )
    }

    @MainActor
    func testErrorStateDoesNotCrash() throws {
        let app = launchApp(arguments: ["--mock-camera-denied", "--mock-dock-error"])

        let error = app.descendants(matching: .any)
            .matching(identifier: "capture.error")
            .firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    @MainActor
    func testCameraMotionErrorStateDoesNotCrash() throws {
        let app = launchApp(arguments: ["--mock-camera-motion-error"])

        let motionStatus = app.descendants(matching: .any)
            .matching(identifier: "camera.motionStatus")
            .firstMatch
        XCTAssertTrue(motionStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "相机姿态错误")
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    @MainActor
    func testCameraMotionStaleStateIsAccessible() throws {
        let app = launchApp(arguments: ["--mock-camera-motion-stale"])

        XCTAssertTrue(
            app.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "相机姿态数据已过期")
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "camera.motionSampleCount")
                .firstMatch
                .exists
        )
    }

    @MainActor
    func testPhysicalSmokeStatusSectionsStart() throws {
        let app = launchApp(useMock: false)

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "gimbal.connectionStatus")
                .firstMatch
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "camera.metrics")
                .firstMatch
                .exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "sync.status")
                .firstMatch
                .exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "camera.preview")
                .firstMatch
                .exists
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            _ = launchApp()
        }
    }
}
