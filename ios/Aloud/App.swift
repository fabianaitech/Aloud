// App.swift — the entry point: pair first, then the main screen.

import SwiftUI
import UIKit

@main
struct AloudApp: App {
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
            if p == .active { model.becameActive() }
            if p == .background { model.enteredBackground() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("accent") private var accent = Accent.indigo.rawValue

    var body: some View {
        Group {
            if model.connection == .notPaired {
                PairView()
            } else {
                MainView()
            }
        }
        .tint(.aloud)
        // The accent is read while drawing; a new one redraws everything.
        .id(accent)
        // …and the watch wears it too.
        .onChange(of: accent) { _, _ in model.watch.publish() }
    }
}

