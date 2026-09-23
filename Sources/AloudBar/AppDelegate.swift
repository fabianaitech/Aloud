// AppDelegate.swift — the whole app: one status item, one menu, and a poller.
//
// Aloud owns *playback*: engine, start/stop, pause, skip, speed, voice, and
// speaking the clipboard. It deliberately does NOT own "should Claude speak its
// replies" — that is a Claude preference and stays in Claude Island's gear menu.
// Both talk to the same daemon through control.sh, so neither can drift.
//
// Two engines, one daemon: Apple's built-in `say` (instant, nothing resident)
// and Kokoro (better voices, 1.2GB while warm). The daemon does the switching;
// this only presents it, with the trade-off written next to the choice.
//
// Speaking the *selection* is a macOS Service ("Speak with Aloud"), not a menu
// item here: reading another app's selection would need Accessibility permission
// and a synthetic ⌘C, and the Services menu already does it natively.

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var spinner: NSProgressIndicator?
    private let speech = SpeechController()

    /// Last polled daemon state; nil means the engine isn't running.
    private var status: SpeechStatus?
    private var daemonUp = false

    /// Set when *we* asked the engine to start, and held until the daemon answers.
    /// The supervisor takes a moment to bind its port, during which /state is simply
    /// unreachable — indistinguishable from "stopped" unless we remember asking.
    /// The deadline stops a failed start (no venv, port taken) spinning forever.
    private var startRequestedUntil: Date?
    private var renderTimer: Timer?
    private var waveTimer: Timer?
    private var wavePhase: CGFloat = 0

    private let speeds: [Double] = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    func applicationDidFinishLaunching(_ note: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = glyph(for: nil)
        item.button?.toolTip = "Aloud"
        let menu = NSMenu()
        menu.delegate = self          // rebuild on every open, so state is never stale
        // We decide what is enabled, from the polled daemon state. Left on (the
        // default), AppKit re-enables anything with a valid target/action and the
        // isEnabled below are silently ignored — Pause/Stop/Skip would look
        // available with nothing playing.
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        // The real macOS spinner, centred over the status item. It replaces the
        // glyph while the engine comes up rather than sitting beside it, so the
        // item keeps its width and nothing in the menu bar shifts.
        if let button = item.button {
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isIndeterminate = true
            spin.isDisplayedWhenStopped = false
            spin.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spin)
            NSLayoutConstraint.activate([
                spin.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spin.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                spin.widthAnchor.constraint(equalToConstant: 14),
                spin.heightAnchor.constraint(equalToConstant: 14),
            ])
            spinner = spin
        }

        speech.onState = { [weak self] s in
            guard let self else { return }
            let wasUp = self.daemonUp
            self.status = s
            self.daemonUp = (s != nil)
            // The daemon answered, so whatever we asked for has happened.
            if s != nil { self.startRequestedUntil = nil }
            // Apple's voice list lives in the daemon, so (re)fetch it whenever the
            // daemon appears — including after a restart, when ours is stale.
            if self.daemonUp && !wasUp { self.speech.refreshVoices() }
            self.render()
        }
        speech.start()
        speech.refreshVoices()
    }

    /// True while the engine is on its way up — either the supervisor is still
    /// binding its port, or it is up and the synth worker is loading.
    private var isStarting: Bool {
        if let until = startRequestedUntil, until > Date(), !daemonUp { return true }
        return status?.loading == true
    }

    /// Remember that we asked the engine to start, and drive the spinner from a
    /// local timer: until the daemon binds its port the poller sees no *change*
    /// (unreachable stays unreachable) and so never calls back — the spinner would
    /// otherwise never appear, and never time out if the start failed.
    private func beginStartRequest() {
        startRequestedUntil = Date().addingTimeInterval(120)
        renderTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.isStarting {
                self.renderTimer?.invalidate()
                self.renderTimer = nil
            }
            self.render()
        }
        RunLoop.main.add(t, forMode: .common)
        renderTimer = t
        render()
    }

    /// Point the status item at whatever the current state is: spinner while
    /// starting, glyph otherwise.
    private func render() {
        guard let button = statusItem?.button else { return }
        if isStarting {
            button.image = nil
            button.toolTip = daemonUp ? "Aloud — loading the voice model…"
                                      : "Aloud — starting the speech engine…"
            spinner?.startAnimation(nil)
        } else {
            spinner?.stopAnimation(nil)
            button.image = glyph(for: status)
            button.toolTip = "Aloud"
        }
        updateWaveAnimation()
    }

    func applicationWillTerminate(_ note: Notification) {
        speech.stop()
        waveTimer?.invalidate()
        renderTimer?.invalidate()
    }

    // MARK: - Status item glyph

    /// The menubar icon doubles as the status readout: you can tell at a glance
    /// whether the engine is down, idle, talking, or paused. It is the app icon's
    /// waveform in all four cases — the bars change, the mark doesn't.
    private func glyph(for s: SpeechStatus?) -> NSImage? {
        let image: NSImage
        let desc: String
        switch s {
        case .none:
            image = WaveformIcon.image(levels: WaveformIcon.offLevels, alpha: 0.45)
            desc = "Speech engine not running"
        case .some(let s) where s.paused:
            image = WaveformIcon.pausedImage()
            desc = "Speech paused"
        case .some(let s) where s.speaking:
            image = WaveformIcon.image(levels: WaveformIcon.speakingLevels(phase: wavePhase))
            desc = "Speaking"
        default:
            image = WaveformIcon.image(levels: WaveformIcon.idleLevels)
            desc = "Idle"
        }
        image.accessibilityDescription = desc
        return image
    }

    /// Run the bars as a level meter while speech is actually playing. Only then:
    /// a menu bar that moves when nothing is happening is just noise, and this is
    /// also the clearest possible "that sound is us".
    private func updateWaveAnimation() {
        let shouldAnimate = (status?.speaking == true) && !isStarting
        if shouldAnimate, waveTimer == nil {
            let t = Timer(timeInterval: 0.11, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.wavePhase += 0.35
                self.statusItem?.button?.image = self.glyph(for: self.status)
            }
            RunLoop.main.add(t, forMode: .common)
            waveTimer = t
        } else if !shouldAnimate, waveTimer != nil {
            waveTimer?.invalidate()
            waveTimer = nil
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard speech.isInstalled else {
            let missing = NSMenuItem(title: "Speech engine is not installed", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
            let hint = NSMenuItem(title: "Run ~/.aloud/setup.sh", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
            addQuit(to: menu)
            return
        }

        let speaking = status?.speaking ?? false
        let paused = status?.paused ?? false
        let queued = status?.queued ?? 0
        let busy = speaking || paused || queued > 0

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let clip = NSMenuItem(title: "Speak Clipboard",
                              action: #selector(speakClipboard), keyEquivalent: "")
        clip.target = self
        menu.addItem(clip)

        menu.addItem(.separator())

        let pause = NSMenuItem(title: paused ? "Resume" : "Pause",
                               action: #selector(pauseResume), keyEquivalent: "")
        pause.target = self
        pause.isEnabled = speaking || paused
        menu.addItem(pause)

        let stop = NSMenuItem(title: "Stop", action: #selector(stopSpeech), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = busy
        menu.addItem(stop)

        let skip = NSMenuItem(title: "Skip", action: #selector(skipSpeech), keyEquivalent: "")
        skip.target = self
        skip.isEnabled = busy
        menu.addItem(skip)

        menu.addItem(.separator())
        menu.addItem(engineMenuItem())
        menu.addItem(speedMenuItem())
        menu.addItem(voiceMenuItem())

        menu.addItem(.separator())
        if daemonUp {
            let restart = NSMenuItem(title: "Restart Engine", action: #selector(restartEngine), keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
            let stopEngine = NSMenuItem(title: "Stop Engine", action: #selector(stopEngine), keyEquivalent: "")
            stopEngine.target = self
            menu.addItem(stopEngine)
        } else {
            let start = NSMenuItem(title: isStarting ? "Starting Engine…" : "Start Engine",
                                   action: #selector(startEngine), keyEquivalent: "")
            start.target = self
            start.isEnabled = !isStarting   // one start at a time
            menu.addItem(start)
        }

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: "Selection Shortcut…",
                                  action: #selector(openServicesSettings), keyEquivalent: "")
        shortcut.target = self
        shortcut.toolTip = "Speaking the selected text is the \"Speak with Aloud\" Service. "
            + "Give it a keyboard shortcut in System Settings."
        menu.addItem(shortcut)

        addQuit(to: menu)
    }

    private func addQuit(to menu: NSMenu) {
        let quit = NSMenuItem(title: "Quit Aloud", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        guard let s = status else {
            return isStarting ? "Starting the engine…" : "Engine not running"
        }
        if s.loading == true { return "Loading the voice model…" }
        let tail = s.queued > 0 ? " — \(s.queued) queued" : ""
        if s.paused { return "Paused\(tail)" }
        if s.speaking { return "Speaking\(tail)" }
        // Distinguish "warm, will speak instantly" from "sleeping, will speak after
        // a short wake-up" — otherwise the first sentence after a quiet spell looks
        // like a hang rather than the memory saving it is.
        if s.loaded == false { return "Idle — model unloaded" }
        return "Idle — \(engine.title)"
    }

    private func speedMenuItem() -> NSMenuItem {
        let current = status?.speed ?? 1.0
        let item = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for spd in speeds {
            let s = NSMenuItem(title: String(format: "%.2gx", spd),
                               action: #selector(setSpeed(_:)), keyEquivalent: "")
            s.target = self
            s.representedObject = spd
            s.state = (abs(spd - current) < 0.01) ? .on : .off
            sub.addItem(s)
        }
        item.submenu = sub
        return item
    }

    /// Which engine the daemon is on. Defaults to Apple, matching the daemon.
    private var engine: Engine {
        Engine(rawValue: status?.engine ?? "") ?? .apple
    }

    private func engineMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for e in Engine.allCases {
            let m = NSMenuItem(title: e.title, action: #selector(setEngine(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = e.rawValue
            m.state = (e == engine) ? .on : .off
            m.toolTip = e.subtitle
            sub.addItem(m)
            // The trade-off belongs next to the choice, not in a README nobody
            // opens while deciding which one to click.
            let note = NSMenuItem(title: e.subtitle, action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.indentationLevel = 1
            sub.addItem(note)
        }
        item.submenu = sub
        return item
    }

    private func voiceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = status?.voice ?? ""

        func header(_ text: String) {
            let h = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            h.isEnabled = false
            sub.addItem(h)
        }
        func entry(_ v: EngineVoice, _ title: String, in menu: NSMenu) {
            let m = NSMenuItem(title: title, action: #selector(setVoice(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = v.key
            m.state = v.matches(current) ? .on : .off
            m.indentationLevel = 1
            menu.addItem(m)
        }

        switch engine {
        case .kokoro:
            let all = speech.kokoroVoices
            if all.isEmpty {
                let m = NSMenuItem(title: daemonUp ? "Loading voices…" : "Engine not running",
                                   action: nil, keyEquivalent: "")
                m.isEnabled = false
                sub.addItem(m)
                break
            }
            // Grouped by language, because in Kokoro the voice *is* the language
            // choice — `bf_emma` is British — and picking one restarts the worker
            // under that language. Nested submenus: 54 voices in one flat list is
            // a scroll, and only one language matters at a time.
            var seen: [String] = []
            for v in all where !seen.contains(v.lang) { seen.append(v.lang) }
            for code in seen {
                let group = all.filter { $0.lang == code }
                guard let first = group.first else { continue }
                var title = first.language ?? code
                // Say up front that this one needs something installed, rather
                // than letting the click fail and explaining afterwards.
                if let extra = first.extra { title += "  (needs \(extra))" }

                let langItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let langMenu = NSMenu()
                langMenu.autoenablesItems = false
                for gender in ["female", "male"] {
                    let voices = group.filter { $0.gender == gender }
                    if voices.isEmpty { continue }
                    let h = NSMenuItem(title: gender.capitalized, action: nil, keyEquivalent: "")
                    h.isEnabled = false
                    langMenu.addItem(h)
                    for v in voices {
                        let m = NSMenuItem(title: v.displayName,
                                           action: #selector(setVoice(_:)), keyEquivalent: "")
                        m.target = self
                        m.representedObject = v.name
                        m.state = (v.name == current) ? .on : .off
                        m.indentationLevel = 1
                        m.toolTip = v.extra.map { "Needs \($0) — see the README" }
                        langMenu.addItem(m)
                    }
                }
                langItem.submenu = langMenu
                // Tick the language containing the active voice, so the current
                // choice is visible without opening every submenu.
                langItem.state = group.contains { $0.name == current } ? .on : .off
                sub.addItem(langItem)
            }

        case .apple:
            let all = speech.appleVoices
            if all.isEmpty {
                let m = NSMenuItem(title: daemonUp ? "Loading voices…" : "Engine not running",
                                   action: nil, keyEquivalent: "")
                m.isEnabled = false
                sub.addItem(m)
                break
            }
            // English up front, every other language one level down. macOS
            // ships ~185 voices across every language it supports, which as one
            // list is unusable and mostly not what you want read to you — but a
            // voice someone went and downloaded should still be reachable.
            //
            // Siri first, then quality tiers: the default tier is the old
            // compact one and sounds it, so the good voices shouldn't be buried
            // under sixty of them.
            let tiers: [(String, (EngineVoice) -> Bool)] = [
                ("Siri", { $0.siri == true }),
                ("Premium", { $0.siri != true && $0.quality == "premium" }),
                ("Enhanced", { $0.siri != true && $0.quality == "enhanced" }),
                ("Standard", { $0.siri != true && ($0.quality ?? "default") == "default" }),
            ]
            func title(_ v: EngineVoice, among group: [EngineVoice]) -> String {
                // Siri's names repeat across accents ("Siri Voice 2" is American
                // and British), so say which one.
                guard v.siri == true, group.filter({ $0.name == v.name }).count > 1,
                      let region = Locale(identifier: v.lang).region?.identifier,
                      let regionName = Locale.current.localizedString(forRegionCode: region)
                else { return v.name }
                return "\(v.name) (\(regionName))"
            }

            let english = all.filter { $0.lang.hasPrefix("en") }
            for (label, test) in tiers {
                let group = english.filter(test)
                if group.isEmpty { continue }
                if sub.numberOfItems > 0 { sub.addItem(.separator()) }
                header(label)
                group.sorted { $0.name < $1.name }.forEach { entry($0, title($0, among: english), in: sub) }
            }

            let others = all.filter { !$0.lang.hasPrefix("en") }
            if !others.isEmpty {
                func languageName(_ code: String) -> String {
                    Locale.current.localizedString(forIdentifier: code) ?? code
                }
                let otherItem = NSMenuItem(title: "Other Languages", action: nil, keyEquivalent: "")
                let otherMenu = NSMenu()
                otherMenu.autoenablesItems = false
                let byLang = Dictionary(grouping: others, by: \.lang)
                for code in byLang.keys.sorted(by: { languageName($0) < languageName($1) }) {
                    let group = byLang[code] ?? []
                    let langItem = NSMenuItem(title: languageName(code), action: nil, keyEquivalent: "")
                    let langMenu = NSMenu()
                    langMenu.autoenablesItems = false
                    for (label, test) in tiers {
                        let tier = group.filter(test)
                        if tier.isEmpty { continue }
                        let h = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                        h.isEnabled = false
                        langMenu.addItem(h)
                        tier.sorted { $0.name < $1.name }.forEach { entry($0, title($0, among: group), in: langMenu) }
                    }
                    langItem.submenu = langMenu
                    // Tick the way to the active voice, so it can be found again.
                    langItem.state = group.contains { $0.matches(current) } ? .on : .off
                    otherMenu.addItem(langItem)
                }
                otherItem.submenu = otherMenu
                otherItem.state = others.contains { $0.matches(current) } ? .on : .off
                sub.addItem(.separator())
                sub.addItem(otherItem)
            }
            sub.addItem(.separator())
            let more = NSMenuItem(title: "Get More Voices…",
                                  action: #selector(openVoiceSettings), keyEquivalent: "")
            more.target = self
            more.toolTip = "Premium and Enhanced voices are downloaded in System Settings."
            sub.addItem(more)
        }
        item.submenu = sub
        return item
    }

    // MARK: - Actions (everything routes through control.sh)

    @objc private func speakClipboard() {
        // say.sh starts the engine on demand, so this is a start request too.
        if !daemonUp { beginStartRequest() }
        speech.control("clipboard")
    }
    @objc private func pauseResume() { speech.control((status?.paused ?? false) ? "resume" : "pause") }
    @objc private func stopSpeech() { speech.control("stop") }
    @objc private func skipSpeech() { speech.control("skip") }
    @objc private func startEngine() { beginStartRequest(); speech.control("start") }
    @objc private func restartEngine() { beginStartRequest(); speech.control("restart") }
    @objc private func stopEngine() {
        startRequestedUntil = nil     // cancel any pending start; we want it down
        speech.control("stop-engine")
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let spd = sender.representedObject as? Double else { return }
        speech.control(String(format: "%.2f", spd))
    }

    @objc private func setVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        speech.control("voice", id)
    }

    @objc private func setEngine(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        speech.control("engine", id)
        speech.refreshVoices()
    }

    /// Premium and Enhanced voices are a manual download; the compact ones macOS
    /// ships by default sound considerably worse, so point at where to get them.
    @objc private func openVoiceSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Toggle launch-at-login via SMAppService (macOS 13+). SMAppService itself is the
    /// source of truth — its `status` drives the checkmark, so we persist no duplicate flag.
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("[Aloud] Launch at login toggle failed: \(error.localizedDescription)")
        }
    }

    /// Speaking the selection is a Service; its shortcut is assigned in System Settings.
    @objc private func openServicesSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        if let url { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
