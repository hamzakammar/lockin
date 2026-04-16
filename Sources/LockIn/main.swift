import Foundation
import AppKit
import UserNotifications

// ─────────────────────────────────────────────
// MARK: - Config
// ─────────────────────────────────────────────

struct Config {
    // Fill these in or set as env vars
    static var apiKey: String = ProcessInfo.processInfo.environment["LOCKIN_API_KEY"] ?? "YOUR_SENTIENCE_API_KEY"
    static var pollIntervalSeconds: Double = 150  // 2.5 min
    static var procrastinationThreshold: Int = 2  // consecutive bad polls before first alert
    static var escalationThreshold: Int = 5       // consecutive bad polls before escalation

    // Focus session — set via menubar or env var
    // Format: ISO8601, e.g. "2025-04-16T16:00:00"
    static var focusDeadline: Date? = {
        guard let s = ProcessInfo.processInfo.environment["LOCKIN_DEADLINE"] else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f.date(from: s)
    }()

    // Apps / keywords that count as procrastination
    static let procrastinationKeywords: [String] = [
        "instagram", "tiktok", "reddit", "twitter", "x.com",
        "linkedin", "snapchat", "facebook", "twitch",
        "netflix", "hulu", "disney+", "apple tv",
        "youtube shorts", "reels", "for you page",
        "trending", "explore page", "fyp"
    ]

    // YouTube educational keywords — presence of these = NOT procrastination even on YouTube
    static let educationalKeywords: [String] = [
        "tutorial", "lecture", "course", "how to", "learn", "study",
        "explained", "introduction to", "programming", "coding",
        "math", "physics", "chemistry", "engineering", "mit",
        "stanford", "khan academy", "3blue1brown", "crash course",
        "computerphile", "sentdex", "freecodecamp", "cs50",
        "homework", "assignment", "project", "exam prep"
    ]

    // Log file path
    static let logPath: String = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Logs/LockIn/procrastination.log")
}

// ─────────────────────────────────────────────
// MARK: - Sentience API
// ─────────────────────────────────────────────

struct Memory: Decodable {
    let content: String
    let timestamp: String?
    let source: String?
    let id: String?
}

struct MemoriesResponse: Decodable {
    let memories: [Memory]?
    // API might return array directly or wrapped
}

enum APIError: Error {
    case invalidURL, httpError(Int), decodingError, authError
}

actor SentienceAPI {
    private let baseURL = "https://audiosummarizer-production.up.railway.app"

    func fetchRecentScreenshots(minutes: Int = 5) async throws -> [Memory] {
        let end = Date()
        let start = end.addingTimeInterval(TimeInterval(-minutes * 60))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)

        guard var components = URLComponents(string: "\(baseURL)/v1/memories") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "start", value: startStr),
            URLQueryItem(name: "end", value: endStr)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.authError
            }
            if http.statusCode != 200 {
                throw APIError.httpError(http.statusCode)
            }
        }

        // Try array first, then wrapped object
        if let memories = try? JSONDecoder().decode([Memory].self, from: data) {
            return memories.filter { $0.source == "screenshot" || $0.source == nil }
        }
        if let wrapped = try? JSONDecoder().decode(MemoriesResponse.self, from: data) {
            return (wrapped.memories ?? []).filter { $0.source == "screenshot" || $0.source == nil }
        }

        // Maybe it's {"memories": [...]} with different shape - try raw JSON
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = json["memories"] as? [[String: Any]] {
            return arr.compactMap { dict in
                guard let content = dict["content"] as? String else { return nil }
                return Memory(
                    content: content,
                    timestamp: dict["timestamp"] as? String,
                    source: dict["source"] as? String,
                    id: dict["id"] as? String
                )
            }
        }

        return []
    }
}

// ─────────────────────────────────────────────
// MARK: - Procrastination Detector
// ─────────────────────────────────────────────

struct DetectionResult {
    let isProcrastinating: Bool
    let detectedApp: String?
    let confidence: Double  // 0-1
}

struct Detector {
    func analyze(memories: [Memory]) -> DetectionResult {
        guard !memories.isEmpty else {
            return DetectionResult(isProcrastinating: false, detectedApp: nil, confidence: 0)
        }

        // Analyze the most recent memories (last 5 minutes)
        let combinedContent = memories.map { $0.content.lowercased() }.joined(separator: " ")

        // Check for procrastination keywords
        var detectedApp: String? = nil
        var maxScore = 0.0

        for keyword in Config.procrastinationKeywords {
            if combinedContent.contains(keyword) {
                // Check if this is YouTube + educational
                if isYouTube(keyword: keyword) {
                    let isEducational = Config.educationalKeywords.contains { combinedContent.contains($0) }
                    if isEducational { continue }  // educational YouTube — skip
                }
                // Score based on how many memories mention it
                let count = memories.filter { $0.content.lowercased().contains(keyword) }.count
                let score = Double(count) / Double(memories.count)
                if score > maxScore {
                    maxScore = score
                    detectedApp = canonicalName(keyword: keyword)
                }
            }
        }

        return DetectionResult(
            isProcrastinating: maxScore > 0,
            detectedApp: detectedApp,
            confidence: maxScore
        )
    }

    private func isYouTube(keyword: String) -> Bool {
        return keyword.contains("youtube") && !keyword.contains("shorts")
    }

    private func canonicalName(keyword: String) -> String {
        let map: [String: String] = [
            "instagram": "Instagram",
            "tiktok": "TikTok",
            "reddit": "Reddit",
            "twitter": "Twitter/X",
            "x.com": "Twitter/X",
            "linkedin": "LinkedIn",
            "snapchat": "Snapchat",
            "facebook": "Facebook",
            "twitch": "Twitch",
            "netflix": "Netflix",
            "hulu": "Hulu",
            "disney+": "Disney+",
            "apple tv": "Apple TV",
            "youtube shorts": "YouTube Shorts",
        ]
        return map[keyword] ?? keyword.capitalized
    }
}

// ─────────────────────────────────────────────
// MARK: - Logger
// ─────────────────────────────────────────────

actor Logger {
    private let path: String

    init(path: String) {
        self.path = path
        // Create directory if needed
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        print(line, terminator: "")
    }
}

// ─────────────────────────────────────────────
// MARK: - Notification Manager
// ─────────────────────────────────────────────

actor NotificationManager {
    private var lastNotificationTime: Date = .distantPast
    private let minInterval: TimeInterval = 60  // don't spam more than once per minute

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func send(title: String, body: String, sound: Bool = true) async {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationTime) >= minInterval else { return }
        lastNotificationTime = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func sendEscalated(title: String, body: String) async {
        lastNotificationTime = .distantPast  // bypass rate limit for escalation
        await send(title: title, body: body, sound: true)
    }
}

// ─────────────────────────────────────────────
// MARK: - State Machine
// ─────────────────────────────────────────────

enum MonitorState {
    case focused
    case procrastinating(consecutiveCount: Int, firstDetectedAt: Date, app: String)
    case paused
}

// ─────────────────────────────────────────────
// MARK: - Main Monitor Engine
// ─────────────────────────────────────────────

@MainActor
class LockInMonitor: NSObject {
    private let api = SentienceAPI()
    private let detector = Detector()
    private let logger = Logger(path: Config.logPath)
    private let notifications = NotificationManager()

    private var state: MonitorState = .focused
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var paused = false
    private var focusDeadline: Date? = Config.focusDeadline

    // Menu items that need updating
    private var pauseMenuItem: NSMenuItem?
    private var deadlineMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?

    // ── Setup ──

    func start() async {
        await notifications.requestPermission()
        setupMenuBar()
        scheduleTimer()
        await logger.log("LockIn started. Poll interval: \(Int(Config.pollIntervalSeconds))s")
    }

    // ── Menu Bar ──

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(procrastinating: false)

        let menu = NSMenu()

        // Status line
        let statusItem = NSMenuItem(title: "Status: Focused 🟢", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        self.statusMenuItem = statusItem
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Focus session deadline
        let deadlineItem = NSMenuItem(title: deadlineMenuTitle(), action: #selector(setDeadline), keyEquivalent: "")
        deadlineItem.target = self
        self.deadlineMenuItem = deadlineItem
        menu.addItem(deadlineItem)

        menu.addItem(.separator())

        // Pause toggle
        let pauseItem = NSMenuItem(title: "Pause Monitoring", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        self.pauseMenuItem = pauseItem
        menu.addItem(pauseItem)

        // Open log
        let logItem = NSMenuItem(title: "Open Log…", action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit LockIn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    private func updateStatusIcon(procrastinating: Bool) {
        if let button = statusItem?.button {
            button.title = procrastinating ? "🔴" : "🟢"
        }
    }

    private func deadlineMenuTitle() -> String {
        guard let d = focusDeadline else { return "Set Focus Deadline…" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let remaining = d.timeIntervalSinceNow
        if remaining <= 0 { return "Deadline passed" }
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        return "Deadline: \(f.string(from: d)) (\(hours)h \(mins)m)"
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseMenuItem?.title = paused ? "Resume Monitoring" : "Pause Monitoring"
        statusMenuItem?.title = paused ? "Status: Paused ⏸️" : "Status: Focused 🟢"
        updateStatusIcon(procrastinating: false)
        Task { await logger.log(paused ? "Monitoring paused" : "Monitoring resumed") }
    }

    @objc private func setDeadline() {
        // Simple dialog to set deadline time
        let alert = NSAlert()
        alert.messageText = "Set Focus Deadline"
        alert.informativeText = "Enter deadline time (e.g. 16:00 for 4pm today):"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "HH:MM"
        if let d = focusDeadline {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            input.stringValue = f.string(from: d)
        }
        alert.accessoryView = input
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            if let time = f.date(from: input.stringValue) {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: time)
                components.hour = timeComponents.hour
                components.minute = timeComponents.minute
                focusDeadline = Calendar.current.date(from: components)
                deadlineMenuItem?.title = deadlineMenuTitle()
                Task { await logger.log("Deadline set to \(input.stringValue)") }
            }
        } else if response == .alertSecondButtonReturn {
            focusDeadline = nil
            deadlineMenuItem?.title = "Set Focus Deadline…"
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.logPath))
    }

    // ── Poll Loop ──

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: Config.pollIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.poll() }
        }
        // Also run immediately after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s startup delay
            await poll()
        }
    }

    private func poll() async {
        guard !paused else { return }

        do {
            let memories = try await api.fetchRecentScreenshots(minutes: 5)
            await logger.log("Fetched \(memories.count) memories")

            guard !memories.isEmpty else {
                // No recent screenshots — assume focused
                await handleFocused()
                return
            }

            let result = detector.analyze(memories: memories)

            if result.isProcrastinating, let app = result.detectedApp {
                await handleProcrastination(app: app)
            } else {
                await handleFocused()
            }
        } catch APIError.authError {
            await logger.log("ERROR: Invalid API key. Check LOCKIN_API_KEY.")
        } catch {
            await logger.log("Poll error: \(error)")
        }
    }

    private func handleProcrastination(app: String) async {
        switch state {
        case .focused:
            // First detection — start counting
            state = .procrastinating(consecutiveCount: 1, firstDetectedAt: Date(), app: app)
            await logger.log("Procrastination detected: \(app) (count: 1)")

        case .procrastinating(let count, let firstDetectedAt, _):
            let newCount = count + 1
            state = .procrastinating(consecutiveCount: newCount, firstDetectedAt: firstDetectedAt, app: app)
            await logger.log("Procrastination continuing: \(app) (count: \(newCount))")

            let minutesWasted = Int(Date().timeIntervalSince(firstDetectedAt) / 60)

            if newCount == Config.procrastinationThreshold {
                // First notification
                let body = countdownSuffix(base: "You've been on \(app) for ~\(minutesWasted) min. Lock in.")
                await notifications.send(title: "🔴 Lock In", body: body)
                updateStatusIcon(procrastinating: true)
                statusMenuItem?.title = "Status: Procrastinating 🔴"
                await logger.log("NOTIFICATION sent (level 1): \(app)")

            } else if newCount > Config.procrastinationThreshold && (newCount - Config.procrastinationThreshold) % 2 == 0 {
                // Escalation every 2 polls after threshold
                let level = (newCount - Config.procrastinationThreshold) / 2 + 1
                let messages = escalationMessages(app: app, minutes: minutesWasted, level: level)
                await notifications.sendEscalated(title: messages.title, body: messages.body)
                await logger.log("NOTIFICATION sent (level \(level)): \(app)")
            }

        case .paused:
            break
        }
    }

    private func handleFocused() async {
        switch state {
        case .procrastinating(let count, _, let app) where count >= Config.procrastinationThreshold:
            // Was procrastinating, now back on track — send positive notification
            await notifications.send(title: "✅ Back on Track", body: "Stopped \(app). Keep going.")
            updateStatusIcon(procrastinating: false)
            statusMenuItem?.title = "Status: Focused 🟢"
            state = .focused
            await logger.log("Back on track (was on \(app))")

        case .procrastinating:
            // Was detected but below threshold — just silently reset
            state = .focused
            await logger.log("Procrastination cleared (below threshold)")

        case .focused:
            break

        case .paused:
            break
        }

        // Update deadline display
        deadlineMenuItem?.title = deadlineMenuTitle()
    }

    // ── Notification Helpers ──

    private func countdownSuffix(base: String) -> String {
        guard let deadline = focusDeadline else { return base }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return base + " Deadline already passed!" }
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        return base + " (\(hours)h \(mins)m until deadline)"
    }

    private func escalationMessages(app: String, minutes: Int, level: Int) -> (title: String, body: String) {
        let deadlinePart: String
        if let deadline = focusDeadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                let hours = Int(remaining) / 3600
                let mins = (Int(remaining) % 3600) / 60
                deadlinePart = " \(hours)h \(mins)m left."
            } else {
                deadlinePart = " DEADLINE PASSED."
            }
        } else {
            deadlinePart = ""
        }

        switch level {
        case 1:
            return (
                title: "⚠️ Still on \(app)?",
                body: "You've wasted \(minutes) minutes.\(deadlinePart) Get back to work."
            )
        case 2:
            return (
                title: "🚨 \(minutes) MINUTES GONE",
                body: "\(app) is costing you.\(deadlinePart) Close it. Now."
            )
        default:
            return (
                title: "🔥 \(minutes) MINUTES. LOCK IN.",
                body: "Every minute on \(app) is a minute you don't have.\(deadlinePart)"
            )
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - App Entry Point
// ─────────────────────────────────────────────

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var monitor: LockInMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon
        NSApp.setActivationPolicy(.accessory)

        monitor = LockInMonitor()
        Task {
            await monitor?.start()
        }
    }
}

// Bootstrap — @MainActor ensures this runs on the main actor
@MainActor
func launchApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

launchApp()
