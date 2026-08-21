// AloudApp.swift — process entry point. A menubar-only app: no windows, no
// SwiftUI App lifecycle, just an NSApplication in .accessory mode owning one
// status item.

import AppKit

@main
enum AloudApp {
    // A strong reference the delegate lives on for the process lifetime.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
