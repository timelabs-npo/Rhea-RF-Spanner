import SwiftUI

@main
@MainActor
struct RheaRFSpannerApp: App {
    @StateObject private var model = ExperimentModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ExperimentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear { model.setAppActive(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    model.setAppActive(phase == .active)
                }
        }
    }
}
