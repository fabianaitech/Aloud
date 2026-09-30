// RemoteVoice.swift — the Mac side of Remote Voice, as the menu sees it.
//
// The daemon owns Remote Voice (engine/remote.py): its settings, the paired
// devices and the authenticated service the phone talks to. This only reads
// its status and flips its switches, over the daemon's loopback control port —
// the same place everything else in the menu goes.

import AppKit
import Foundation

struct RemoteStatus: Decodable {
    struct Device: Decodable {
        let id: String
        let name: String
        let connected: Bool
        let last_seen: Double?
    }
    struct Session: Decodable {
        let session_id: String
        let project: String
        let title: String?
        let entrypoint: String
        let state: String
        let can_reply: Bool
    }
    struct Tailscale: Decodable {
        let installed: Bool
        let running: Bool
        let dns_name: String?
        let serve_url: String?
        let serve_command: String
    }
    struct Pairing: Decodable {
        let code: String
        let expires_in: Int
    }
    let enabled: Bool
    let destination: String
    let port: Int
    let listening: Bool
    let devices: [Device]
    let sessions: [Session]
    let tailscale: Tailscale
    let pairing: Pairing?
}

final class RemoteVoiceController {
    private(set) var status: RemoteStatus?
    var onChange: () -> Void = {}

    private let base: URL
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // Status shells out to `tailscale status`, which can take a moment.
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c)
    }()

    init(port: Int) {
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    func refresh() {
        session.dataTask(with: base.appendingPathComponent("rv/status")) { [weak self] data, _, _ in
            let s = data.flatMap { try? JSONDecoder().decode(RemoteStatus.self, from: $0) }
            DispatchQueue.main.async {
                self?.status = s
                self?.onChange()
            }
        }.resume()
    }

    /// POST to a /rv route; `done` gets the decoded JSON object, or nil.
    func post(_ route: String, _ body: [String: Any] = [:],
              done: (([String: Any]?) -> Void)? = nil) {
        var req = URLRequest(url: base.appendingPathComponent("rv/\(route)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { [weak self] data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                done?(obj)
                self?.refresh()
            }
        }.resume()
    }

    /// One line for the top of the submenu: is a phone going to hear anything?
    var summary: String {
        guard let s = status else { return "Remote Voice — engine not running" }
        guard s.enabled else { return "Off" }
        guard s.listening else { return "On, but not listening — see the engine log" }
        guard s.tailscale.running else { return "On — Tailscale is not running" }
        guard s.tailscale.serve_url != nil else { return "On — Tailscale Serve not set up" }
        let connected = s.devices.filter(\.connected).count
        if s.devices.isEmpty { return "On — no iPhone paired yet" }
        return connected > 0 ? "On — \(connected) iPhone connected" : "On — iPhone not connected"
    }
}

extension AppDelegate {
    func remoteVoiceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Remote Voice", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let s = remote.status

        let head = NSMenuItem(title: remote.summary, action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)

        let toggle = NSMenuItem(title: "Remote Voice Enabled", action: #selector(toggleRemoteVoice),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = (s?.enabled ?? false) ? .on : .off
        toggle.isEnabled = s != nil
        toggle.toolTip = "Send Claude's spoken responses to your iPhone, and take spoken replies back."
        sub.addItem(toggle)

        sub.addItem(.separator())
        let playHead = NSMenuItem(title: "Play Responses On", action: nil, keyEquivalent: "")
        playHead.isEnabled = false
        sub.addItem(playHead)
        for (id, title) in [("mac", "Mac"), ("iphone", "iPhone"), ("both", "Mac and iPhone")] {
            let m = NSMenuItem(title: title, action: #selector(setRemoteDestination(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = id
            m.indentationLevel = 1
            m.state = (s?.destination == id) ? .on : .off
            m.isEnabled = s?.enabled ?? false
            sub.addItem(m)
        }

        sub.addItem(.separator())
        let ts = s?.tailscale
        let tsLine: String
        if ts == nil || ts?.installed == false {
            tsLine = "Tailscale: not installed"
        } else if ts?.running == false {
            tsLine = "Tailscale: not running"
        } else if let url = ts?.serve_url {
            tsLine = "Reachable at \(url)"
        } else {
            tsLine = "Tailscale Serve: not set up"
        }
        let tsItem = NSMenuItem(title: tsLine, action: nil, keyEquivalent: "")
        tsItem.isEnabled = false
        sub.addItem(tsItem)
        // Share on the tailnet — or stop — without a terminal. Tailscale keeps
        // the setting, so this is normally a one-time click per Mac.
        if ts?.running == true {
            let shared = ts?.serve_url != nil
            let serve = NSMenuItem(title: shared ? "Stop Sharing on Tailnet" : "Share on Tailnet",
                                   action: #selector(toggleServe), keyEquivalent: "")
            serve.target = self
            serve.representedObject = !shared
            serve.toolTip = shared
                ? "Stop Tailscale Serve for Aloud. The iPhone can't reach the Mac until it's shared again."
                : "Make Aloud reachable from your own devices on your tailnet (Tailscale Serve, HTTPS). Not public."
            sub.addItem(serve)
        }

        sub.addItem(.separator())
        let pairItem = NSMenuItem(title: "Pair iPhone…", action: #selector(pairIPhone), keyEquivalent: "")
        pairItem.target = self
        pairItem.isEnabled = s?.enabled ?? false
        sub.addItem(pairItem)
        for d in s?.devices ?? [] {
            let m = NSMenuItem(title: "\(d.name) — \(d.connected ? "connected" : "not connected")",
                               action: nil, keyEquivalent: "")
            let dm = NSMenu()
            let remove = NSMenuItem(title: "Remove This Device", action: #selector(removeDevice(_:)),
                                    keyEquivalent: "")
            remove.target = self
            remove.representedObject = d.id
            dm.addItem(remove)
            m.submenu = dm
            m.indentationLevel = 1
            sub.addItem(m)
        }

        if let sessions = s?.sessions, s?.enabled == true {
            sub.addItem(.separator())
            let n = sessions.filter(\.can_reply).count
            let h = NSMenuItem(title: n == 1 ? "1 Claude session can take replies"
                                             : "\(n) Claude sessions can take replies",
                               action: nil, keyEquivalent: "")
            h.isEnabled = false
            sub.addItem(h)
        }

        item.submenu = sub
        return item
    }

    @objc func toggleRemoteVoice() {
        remote.post("config", ["enabled": !(remote.status?.enabled ?? false)])
    }

    @objc func setRemoteDestination(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        remote.post("config", ["destination": id])
    }

    @objc func toggleServe(_ sender: NSMenuItem) {
        let on = sender.representedObject as? Bool ?? true
        remote.post("serve", ["on": on]) { [weak self] obj in
            if let link = obj?["consent_url"] as? String, let url = URL(string: link) {
                // First time on this tailnet: Tailscale wants a yes in the browser,
                // and finishes by itself once it has one.
                NSWorkspace.shared.open(url)
            } else if obj?["ok"] as? Bool == false {
                let alert = NSAlert()
                alert.messageText = on ? "Couldn't share on your tailnet" : "Couldn't stop sharing"
                alert.informativeText = (obj?["error"] as? String) ?? "Tailscale didn't say why."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            // Tailscale may still be applying it; look again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.remote.refresh() }
        }
    }

    @objc func removeDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        remote.post("revoke", ["id": id])
    }

    /// Start pairing and show the one-time code. The phone needs the address
    /// and the code; the code is good for five minutes and one device.
    @objc func pairIPhone() {
        remote.post("pair") { [weak self] obj in
            guard let self, let code = obj?["code"] as? String else { return }
            let url = self.remote.status?.tailscale.serve_url
            let alert = NSAlert()
            alert.messageText = "Pair your iPhone"
            let spaced = code.prefix(3) + " " + code.suffix(3)
            var text = "In the Aloud app on your iPhone, enter:\n\n"
            if let url {
                text += "Server:  \(url)\n"
            } else {
                text += "Server:  (share Aloud on your tailnet first: "
                    + "Remote Voice → Share on Tailnet)\n"
            }
            text += "Code:  \(spaced)\n\nThe code works once, for the next five minutes."
            alert.informativeText = text
            alert.addButton(withTitle: "Done")
            if url != nil { alert.addButton(withTitle: "Copy Server Address") }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn, let url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
    }
}
