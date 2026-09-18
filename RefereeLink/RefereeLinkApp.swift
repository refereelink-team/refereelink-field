import SwiftUI

@main
@MainActor
struct RefereeLinkApp: App {
    @State private var model = LiveCaptureModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
