# Testing

## Scope

The iOS target covers camera preview, Core Motion camera pose, DockKit diagnostics, offline capture, archive export, and the field transport seams. Watch communication and production backend integration are outside this test scope.

## Automated tests

The shared test plan is `RefereeLink.xctestplan`. It includes `RefereeLinkTests` and `RefereeLinkUITests`; Watch tests are intentionally excluded from the iOS plan.

Simulator validation completed on iOS 27.0:

- 28 tests passed, 0 failed.
- Mock camera, Core Motion, DockKit, synchronization, archive, transport, error, stale, and accessibility cases are covered.
- UI tests verify startup, Mock capture controls, error states, stale states, and physical smoke identifiers.

Run the test plan from Xcode with the `RefereeLink` scheme, or use the equivalent Xcode test action for the active iOS 27 simulator.

## Physical-device validation

The following tests were run without `--mock` on an iPhone 15 Pro running iOS 27.0:

| Test | Result |
| --- | --- |
| `testPhysicalSmokeStatusSectionsStart` | Passed |
| `testPhysicalOfflineCaptureStartsAndStops` | Passed |

The physical offline test starts a real capture session, waits for camera/Core Motion sampling, stops the session, and verifies that the saved session exposes the export action. A key runtime screenshot is available at [physical camera and Core Motion result](images/physical-running-camera-core-motion.png).

The device run confirmed:

- iPhone camera preview is producing live frames.
- Core Motion produces non-empty attitude and angular-rate values.
- Offline capture can start, stop, and produce an exportable session.

The device run did not confirm DockKit motion samples: the accessory section remained in “waiting for connection” with zero DockKit samples. Real-time WSS/SRT transport was not tested because no production backend endpoint was configured.

## Evidence policy

Long-lived repository assets are limited to this summary and one representative screenshot. Raw XCTest bundles, transient logs, repeated screenshots, lock-screen captures, and large recordings remain local or belong in an external artifact store.
