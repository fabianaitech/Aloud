// App.swift — the entry point: pair first, then the main screen.

import SwiftUI
import UIKit

@main
struct AloudRemoteApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.player)
                .environmentObject(model.recorder)
                .onAppear {
                    model.start()
                    #if DEBUG
                    model.runDebugLaunchArguments()
                    #endif
                }
        }
        .onChange(of: phase) { _, p in
            // Foreground is the supported mode: listen while open, and pick up
            // exactly where we left off when opened again.
            if p == .active { model.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.connection == .notPaired {
            PairView()
        } else {
            MainView()
        }
    }
}

