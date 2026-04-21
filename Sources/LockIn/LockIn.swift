import Foundation
import AppKit
import ServiceManagement

// ─────────────────────────────────────────────
// MARK: - Persistent Settings
// Stored in ~/.lockin/config, editable via Settings window
// ─────────────────────────────────────────────

class Settings: ObservableObject {
    static let shared = Settings()
    private let configPath = (NSHomeDirectory() as NSString).appendingPathComponent(".lockin/config")

    var apiKey: String        { get { val("LOCKIN_API_KEY") ?? "" }        set { set("LOCKIN_API_KEY", newValue) } }
    var pollInterval: Double  { get { Double(val("POLL_INTERVAL") ?? "") ?? 150 } set { set("POLL_INTERVAL", String(Int(newValue))) } }
    var threshold: Int        { get { Int(val("THRESHOLD") ?? "") ?? 1 }   set { set("THRESHOLD", String(newValue)) } }
    var logPath: String       { (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/LockIn/procrastination.log") }

    private var cache: [String: String] = [:]

    init() { reload() }

    func reload() {
        cache = [:]
        // Env vars take priority
        for (k, v) in ProcessInfo.processInfo.environment { cache[k] = v }
        // Then config file
        if let contents = try? String(contentsOfFile: configPath, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                if parts.count >= 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { cache[key] = value }
                }
            }
        }
    }

    func save() {
        try? FileManager.default.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let lines = cache
            .filter { !ProcessInfo.processInfo.environment.keys.contains($0.key) } // don't write env vars
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "\n")
        try? lines.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private func val(_ key: String) -> String? { cache[key] }
    private func set(_ key: String, _ value: String) { cache[key] = value; save() }
}

// ─────────────────────────────────────────────
// MARK: - Sentience API
// ─────────────────────────────────────────────

struct Memory: Decodable {
    let content: String
    let timestamp: String?
    let source: String?
    let id: String?

    var dedupKey: String {
        if let id = id, !id.isEmpty { return id }
        return String(content.hashValue)
    }
}

struct MemoriesResponse: Decodable { let memories: [Memory]? }

enum APIError: Error { case invalidURL, httpError(Int), authError }

actor SentienceAPI {
    private let baseURL = "https://audiosummarizer-production.up.railway.app"
    private var seenIds: Set<String> = []

    func fetchRecent() async throws -> (all: [Memory], fresh: [Memory]) {
        let end   = Date()
        let start = end.addingTimeInterval(-10 * 60)
        let fmt   = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        guard var comps = URLComponents(string: "\(baseURL)/v1/memories") else { throw APIError.invalidURL }
        comps.queryItems = [
            URLQueryItem(name: "start", value: fmt.string(from: start)),
            URLQueryItem(name: "end",   value: fmt.string(from: end)),
        ]
        guard let url = comps.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(Settings.shared.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw APIError.authError }
            if http.statusCode != 200 { throw APIError.httpError(http.statusCode) }
        }

        var all: [Memory] = []
        if let arr = try? JSONDecoder().decode([Memory].self, from: data) {
            all = arr
        } else if let wrapped = try? JSONDecoder().decode(MemoriesResponse.self, from: data) {
            all = wrapped.memories ?? []
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["memories"] as? [[String: Any]] {
            all = arr.compactMap {
                guard let c = $0["content"] as? String else { return nil }
                return Memory(content: c, timestamp: $0["timestamp"] as? String,
                              source: $0["source"] as? String, id: $0["id"] as? String)
            }
        }

        // fresh = new events for logging; all = full window for detection
        let fresh = all.filter { !seenIds.contains($0.dedupKey) }
        fresh.forEach { seenIds.insert($0.dedupKey) }
        if seenIds.count > 500 { seenIds = Set(seenIds.dropFirst(seenIds.count - 500)) }
        return (all: all, fresh: fresh)
    }

    func resetSeen() { seenIds = [] }
}

// ─────────────────────────────────────────────
// MARK: - Detector
// ─────────────────────────────────────────────

struct DetectionResult {
    let isProcrastinating: Bool
    let detectedApp: String
    let confidence: Double
}

struct Detector {
    func analyze(_ memories: [Memory]) -> DetectionResult {
        guard !memories.isEmpty else {
            return DetectionResult(isProcrastinating: false, detectedApp: "", confidence: 0)
        }

        let badCategories: Set<String> = ["entertainment", "social media", "social networking", "leisure"]
        var bad = 0
        var appName = ""

        for m in memories {
            guard let data = m.content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let category = (json["category"] as? String)?.lowercased() else { continue }

            guard badCategories.contains(where: { category.contains($0) }) else { continue }
            bad += 1

            // Extract content name from first action object
            if appName.isEmpty,
               let facts = json["facts"] as? [String: Any],
               let actions = facts["actions"] as? [[String: Any]],
               let obj = actions.first?["object"] as? String {
                appName = extractApp(from: obj.lowercased()) ?? obj
            }
        }

        return DetectionResult(
            isProcrastinating: bad > 0,
            detectedApp: appName.isEmpty ? "a distraction" : appName,
            confidence: Double(bad) / Double(memories.count)
        )
    }

    private func extractApp(from text: String) -> String? {
        let apps: [(String, String)] = [
            ("instagram","Instagram"), ("tiktok","TikTok"), ("reddit","Reddit"),
            ("twitter","Twitter"), ("x.com","Twitter/X"), ("linkedin","LinkedIn"),
            ("snapchat","Snapchat"), ("facebook","Facebook"), ("twitch","Twitch"),
            ("netflix","Netflix"), ("hulu","Hulu"), ("disney+","Disney+"),
            ("apple tv","Apple TV"), ("youtube shorts","YouTube Shorts"),
            ("youtube","YouTube"), ("spotify","Spotify"),
        ]
        for (k, v) in apps { if text.contains(k) { return v } }
        return nil
    }
}

// ─────────────────────────────────────────────
// MARK: - Logger
// ─────────────────────────────────────────────

actor Logger {
    private let path: String
    init(path: String) {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Notifications (osascript — no bundle needed)
// ─────────────────────────────────────────────

actor Notifier {
    private var lastSent: Date = .distantPast
    private let minGap: TimeInterval = 60

    func send(title: String, body: String, force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastSent) >= minGap else { return }
        lastSent = Date()
        fire(title: title, body: body)
    }

    private func fire(title: String, body: String) {
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let b = body.replacingOccurrences(of:  "\"", with: "'")
        let script = "display notification \"\(b)\" with title \"\(t)\" sound name \"Basso\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}

// NSSecureTextField blocks paste — subclass to allow it
class PasteableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// ─────────────────────────────────────────────

@MainActor
class SettingsWindowController: NSWindowController {
    private var apiKeyField: NSTextField!
    private var apiKeySecure: NSSecureTextField!
    private var showingKey = false
    private var pollSlider: NSSlider!
    private var pollLabel: NSTextField!
    private var thresholdStepper: NSStepper!
    private var thresholdLabel: NSTextField!
    private var statusLabel: NSTextField!
    private weak var monitor: LockInMonitor?

    init(monitor: LockInMonitor) {
        self.monitor = monitor
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.title = "LockIn Settings"
        w.center()
        super.init(window: w)
        buildUI()
    }
    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        var y: CGFloat = 230

        func label(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 160) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.frame = NSRect(x: x, y: y, width: w, height: 20)
            f.font = .systemFont(ofSize: 13)
            contentView.addSubview(f)
            return f
        }

        // ── API Key ──
        _ = label("Sentience API Key", x: 20, y: y)

        // Secure field (default, hidden)
        apiKeySecure = PasteableSecureTextField(frame: NSRect(x: 20, y: y - 26, width: 310, height: 22))
        apiKeySecure.placeholderString = "sent_..."
        apiKeySecure.stringValue = Settings.shared.apiKey
        apiKeySecure.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        contentView.addSubview(apiKeySecure)

        // Plain field (shown when toggled)
        apiKeyField = NSTextField(frame: NSRect(x: 20, y: y - 26, width: 310, height: 22))
        apiKeyField.placeholderString = "sent_..."
        apiKeyField.stringValue = Settings.shared.apiKey
        apiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        apiKeyField.isHidden = true
        contentView.addSubview(apiKeyField)

        // Show/Hide button
        let toggleBtn = NSButton(frame: NSRect(x: 336, y: y - 26, width: 28, height: 22))
        toggleBtn.title = "👁"
        toggleBtn.bezelStyle = .rounded
        toggleBtn.isBordered = true
        toggleBtn.target = self
        toggleBtn.action = #selector(toggleKeyVisibility)
        contentView.addSubview(toggleBtn)

        // Copy button
        let copyBtn = NSButton(frame: NSRect(x: 368, y: y - 26, width: 32, height: 22))
        copyBtn.title = "⎘"
        copyBtn.bezelStyle = .rounded
        copyBtn.toolTip = "Copy API key"
        copyBtn.target = self
        copyBtn.action = #selector(copyApiKey)
        contentView.addSubview(copyBtn)

        y -= 62

        // ── Poll Interval ──
        _ = label("Poll interval", x: 20, y: y)
        pollSlider = NSSlider(frame: NSRect(x: 20, y: y - 24, width: 300, height: 22))
        pollSlider.minValue = 60; pollSlider.maxValue = 600
        pollSlider.doubleValue = Settings.shared.pollInterval
        pollSlider.isContinuous = true
        pollSlider.target = self; pollSlider.action = #selector(pollSliderChanged)
        contentView.addSubview(pollSlider)
        pollLabel = label("", x: 330, y: y - 24, w: 70)
        updatePollLabel()
        y -= 56

        // ── Threshold ──
        _ = label("Alerts after N bad polls", x: 20, y: y)
        thresholdStepper = NSStepper(frame: NSRect(x: 220, y: y - 2, width: 40, height: 22))
        thresholdStepper.minValue = 1; thresholdStepper.maxValue = 10
        thresholdStepper.intValue = Int32(Settings.shared.threshold)
        thresholdStepper.target = self; thresholdStepper.action = #selector(thresholdChanged)
        contentView.addSubview(thresholdStepper)
        thresholdLabel = label("\(Settings.shared.threshold)", x: 268, y: y, w: 40)
        y -= 50

        // ── Status ──
        statusLabel = label("", x: 20, y: y, w: 380)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        // ── Buttons ──
        let save = NSButton(frame: NSRect(x: 310, y: 16, width: 90, height: 28))
        save.title = "Save"; save.bezelStyle = .rounded
        save.target = self; save.action = #selector(saveSettings)
        contentView.addSubview(save)

        let cancel = NSButton(frame: NSRect(x: 210, y: 16, width: 90, height: 28))
        cancel.title = "Cancel"; cancel.bezelStyle = .rounded
        cancel.target = self; cancel.action = #selector(cancelSettings)
        contentView.addSubview(cancel)
    }

    @objc private func pollSliderChanged() { updatePollLabel() }
    private func updatePollLabel() {
        let v = Int(pollSlider.doubleValue)
        pollLabel.stringValue = v < 60 ? "\(v)s" : "\(v/60)m \(v%60)s"
    }

    @objc private func thresholdChanged() {
        thresholdLabel.stringValue = "\(thresholdStepper.intValue)"
    }

    @objc private func toggleKeyVisibility() {
        showingKey.toggle()
        if showingKey {
            apiKeyField.stringValue = apiKeySecure.stringValue
            apiKeyField.isHidden = false
            apiKeySecure.isHidden = true
        } else {
            apiKeySecure.stringValue = apiKeyField.stringValue
            apiKeySecure.isHidden = false
            apiKeyField.isHidden = true
        }
    }

    @objc private func copyApiKey() {
        let key = showingKey ? apiKeyField.stringValue : apiKeySecure.stringValue
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        statusLabel.stringValue = "📋 Copied to clipboard"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func saveSettings() {
        let key = (showingKey ? apiKeyField.stringValue : apiKeySecure.stringValue)
            .trimmingCharacters(in: .whitespaces)
        if key.isEmpty {
            statusLabel.stringValue = "⚠️ API key cannot be empty"
            statusLabel.textColor = .systemRed
            return
        }
        Settings.shared.apiKey = key
        Settings.shared.pollInterval = pollSlider.doubleValue
        Settings.shared.threshold = Int(thresholdStepper.intValue)
        monitor?.applySettings()
        statusLabel.stringValue = "✅ Saved"
        statusLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.window?.close() }
    }

    @objc private func cancelSettings() { window?.close() }
}

// ─────────────────────────────────────────────
// MARK: - Monitor
// ─────────────────────────────────────────────

enum MonitorState {
    case focused
    case procrastinating(count: Int, since: Date, app: String)
    case paused
}

@MainActor
class LockInMonitor: NSObject {
    private let api       = SentienceAPI()
    private let detector  = Detector()
    private let logger    = Logger(path: Settings.shared.logPath)
    private let notifier  = Notifier()

    private var state: MonitorState = .focused
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var focusDeadline: Date?
    private var lastPollTime: Date?
    private var lastPollCount: Int = 0

    // Menu refs
    private var statusMenuItem: NSMenuItem?
    private var lastPollMenuItem: NSMenuItem?
    private var deadlineMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var settingsWindowController: SettingsWindowController?

    func start() async {
        setupMenuBar()
        scheduleTimer()
        await logger.log("LockIn started. Poll: \(Int(Settings.shared.pollInterval))s, threshold: \(Settings.shared.threshold)")
    }

    func applySettings() {
        timer?.invalidate()
        Task { await api.resetSeen() }
        scheduleTimer()
        Task { await logger.log("Settings updated. Poll: \(Int(Settings.shared.pollInterval))s") }
    }

    // ── Menubar ──

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.focused)

        let menu = NSMenu()

        // Header — app name + version
        let header = NSMenuItem(title: "LockIn", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "🔒 LockIn",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(header)

        // Status
        let statusItem = NSMenuItem(title: "Focused ✅", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.indentationLevel = 1
        self.statusMenuItem = statusItem
        menu.addItem(statusItem)

        // Last poll
        let pollItem = NSMenuItem(title: "Last poll: —", action: nil, keyEquivalent: "")
        pollItem.isEnabled = false
        pollItem.indentationLevel = 1
        pollItem.attributedTitle = NSAttributedString(
            string: "Last poll: —",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        self.lastPollMenuItem = pollItem
        menu.addItem(pollItem)

        menu.addItem(.separator())

        // Focus deadline
        let dl = NSMenuItem(title: "⏱ Set Focus Deadline…", action: #selector(setDeadline), keyEquivalent: "d")
        dl.target = self
        self.deadlineMenuItem = dl
        menu.addItem(dl)

        menu.addItem(.separator())

        // Pause
        let pause = NSMenuItem(title: "⏸ Pause Monitoring", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        self.pauseMenuItem = pause
        menu.addItem(pause)

        // Launch at login
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        // Settings
        let settings = NSMenuItem(title: "⚙️ Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Open log
        let log = NSMenuItem(title: "📋 Open Log…", action: #selector(openLog), keyEquivalent: "l")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit LockIn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        self.statusItem?.menu = menu
    }

    private enum IconState { case focused, procrastinating, paused }
    private func setIcon(_ s: IconState) {
        guard let btn = statusItem?.button else { return }
        switch s {
        case .focused:         btn.title = "🟢"; btn.toolTip = "LockIn — Focused"
        case .procrastinating: btn.title = "🔴"; btn.toolTip = "LockIn — Procrastinating"
        case .paused:          btn.title = "⏸️"; btn.toolTip = "LockIn — Paused"
        }
    }

    private func updateLastPollLabel() {
        guard let t = lastPollTime else { return }
        let fmt = DateFormatter()
        fmt.dateStyle = .none; fmt.timeStyle = .medium
        let attr = NSAttributedString(
            string: "Last poll: \(fmt.string(from: t)) · \(lastPollCount) new memories",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        lastPollMenuItem?.attributedTitle = attr
    }

    @objc private func togglePause() {
        if case .paused = state {
            state = .focused
            pauseMenuItem?.title = "⏸ Pause Monitoring"
            setIcon(.focused)
            statusMenuItem?.title = "Focused ✅"
            Task { await logger.log("Resumed") }
        } else {
            state = .paused
            pauseMenuItem?.title = "▶️ Resume Monitoring"
            setIcon(.paused)
            statusMenuItem?.title = "Paused ⏸️"
            Task { await logger.log("Paused") }
        }
    }

    @objc private func setDeadline() {
        let alert = NSAlert()
        alert.messageText = "Set Focus Deadline"
        alert.informativeText = "Time today (e.g. 16:00 for 4pm):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "HH:MM"
        if let d = focusDeadline {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            field.stringValue = f.string(from: d)
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal()
        if r == .alertFirstButtonReturn {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            if let t = f.date(from: field.stringValue) {
                var c = Calendar.current.dateComponents([.year,.month,.day], from: Date())
                let tc = Calendar.current.dateComponents([.hour,.minute], from: t)
                c.hour = tc.hour; c.minute = tc.minute
                focusDeadline = Calendar.current.date(from: c)
                updateDeadlineLabel()
                Task { await logger.log("Deadline set: \(field.stringValue)") }
            }
        } else if r == .alertSecondButtonReturn {
            focusDeadline = nil
            deadlineMenuItem?.title = "⏱ Set Focus Deadline…"
        }
    }

    private func updateDeadlineLabel() {
        guard let d = focusDeadline else { deadlineMenuItem?.title = "⏱ Set Focus Deadline…"; return }
        let rem = d.timeIntervalSinceNow
        guard rem > 0 else { deadlineMenuItem?.title = "⏱ Deadline passed"; return }
        let h = Int(rem)/3600, m = (Int(rem)%3600)/60
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .none
        deadlineMenuItem?.title = "⏱ \(fmt.string(from: d)) — \(h)h \(m)m left"
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                // Update checkmark
                if let menu = statusItem?.menu {
                    for item in menu.items where item.action == #selector(toggleLaunchAtLogin) {
                        item.state = isLaunchAtLoginEnabled() ? .on : .off
                    }
                }
            } catch {
                Task { await logger.log("Launch at login error: \(error)") }
            }
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(monitor: self)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Settings.shared.logPath))
    }

    // ── Poll Loop ──

    private func scheduleTimer() {
        timer?.invalidate()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await poll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Settings.shared.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.poll() }
        }
    }

    private func poll() async {
        if case .paused = state { return }

        do {
            let (allMemories, freshMemories) = try await api.fetchRecent()
            lastPollTime = Date()
            lastPollCount = freshMemories.count
            updateLastPollLabel()
            updateDeadlineLabel()
            await logger.log("Fetched \(freshMemories.count) new memories (\(allMemories.count) in window)")

            // Detect on full window — are we procrastinating RIGHT NOW?
            let result = detector.analyze(allMemories)
            if result.isProcrastinating {
                await handleProcrastination(app: result.detectedApp)
            } else {
                await handleFocused()
            }
        } catch APIError.authError {
            await logger.log("ERROR: Invalid API key — open Settings to update it")
            lastPollMenuItem?.attributedTitle = NSAttributedString(
                string: "⚠️ Invalid API key — open Settings",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemRed])
        } catch {
            await logger.log("Poll error: \(error)")
        }
    }

    private func handleProcrastination(app: String) async {
        switch state {
        case .focused:
            // First detection — start the count, flip icon immediately
            state = .procrastinating(count: 1, since: Date(), app: app)
            setIcon(.procrastinating)
            statusMenuItem?.title = "Procrastinating on \(app) 🔴"
            await logger.log("Procrastination detected: \(app) (1)")

        case .procrastinating(let n, let since, _):
            let newN = n + 1
            state = .procrastinating(count: newN, since: since, app: app)
            let mins = max(1, Int(Date().timeIntervalSince(since) / 60))
            let threshold = Settings.shared.threshold
            await logger.log("Procrastination: \(app) (\(newN)) ~\(mins)min")

            // First alert fires after `threshold` consecutive bad polls
            if newN == threshold {
                await notifier.send(title: "🔴 Lock In",
                                    body: countdownSuffix("You've been on \(app) for ~\(mins) min. Lock in."))
                await logger.log("ALERT L1: \(app)")
            } else if newN > threshold, (newN - threshold) % 2 == 0 {
                // Escalate every 2 polls after threshold
                let lvl = (newN - threshold) / 2 + 1
                let (t, b) = escalation(app: app, mins: mins, level: lvl)
                await notifier.send(title: t, body: b, force: true)
                await logger.log("ALERT L\(lvl): \(app)")
            }

        case .paused: break
        }
    }

    private func handleFocused() async {
        if case .procrastinating(let n, _, let app) = state, n >= Settings.shared.threshold {
            await notifier.send(title: "✅ Back on Track", body: "Stopped \(app). Keep going.")
            setIcon(.focused)
            statusMenuItem?.title = "Focused ✅"
            await logger.log("Back on track (was: \(app))")
        }
        if case .procrastinating = state { state = .focused }
    }

    private func countdownSuffix(_ base: String) -> String {
        guard let d = focusDeadline, d.timeIntervalSinceNow > 0 else { return base }
        let r = d.timeIntervalSinceNow
        return base + " (\(Int(r)/3600)h \((Int(r)%3600)/60)m left)"
    }

    private func escalation(app: String, mins: Int, level: Int) -> (String, String) {
        let dl: String = {
            guard let d = focusDeadline else { return "" }
            let r = d.timeIntervalSinceNow
            return r > 0 ? " \(Int(r)/3600)h \((Int(r)%3600)/60)m left." : " DEADLINE PASSED."
        }()
        switch level {
        case 1: return ("⚠️ Still on \(app)?",   "Wasted \(mins) min.\(dl) Get back to work.")
        case 2: return ("🚨 \(mins) MINUTES GONE", "\(app) is costing you.\(dl) Close it. Now.")
        default:return ("🔥 LOCK IN.",             "Every minute on \(app) is a minute you don't have.\(dl)")
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Entry Point
// ─────────────────────────────────────────────

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var monitor: LockInMonitor?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        monitor = LockInMonitor()
        Task { await monitor?.start() }
    }
}

@main
struct LockInApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
