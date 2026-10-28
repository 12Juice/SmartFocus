import Cocoa
import CoreGraphics
import Darwin
import ServiceManagement

// MARK: - SkyLight WindowServer 事件流（私有 API，AltTab/yabai 同款机制）
// Event ids are reverse-engineered values, verified live by AltTab on macOS 26
// and shared with yabai's implementation; stable from 10.10 through 26.5.
typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

/// Per-connection notification callback:
/// (event id, payload, payload length, context, connection id)
typealias CGSConnectionNotifyProc = @convention(c) (
    _ event: UInt32, _ data: UnsafeMutableRawPointer?, _ dataLength: Int,
    _ context: UnsafeMutableRawPointer?, _ cid: CGSConnectionID) -> Void

private func slsSymbol<T>(_ name: String) -> T? {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

/// The SLS* symbols live in the SkyLight private framework and are not
/// re-exported by any public one, and a CLI swiftc build cannot link SkyLight
/// from the SDK — resolve them at runtime via dlopen/dlsym (AltTab's recipe).
/// Nil if a future macOS drops them: the app degrades to timer-driven checks
/// instead of crashing.
enum SkyLight {
    /// Opt the connection into per-window notifications. REPLACES the
    /// connection's watch list — it does not add to it; always pass the full
    /// set (a delta call silences every previously watched window, measured
    /// by AltTab on macOS 26). There is no unsubscribe symbol; dropping a wid
    /// from the next call is the only way out.
    static let requestNotificationsForWindows: (@convention(c) (
        _ cid: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>,
        _ windowCount: Int32) -> CGError)? = slsSymbol("SLSRequestNotificationsForWindows")

    static let registerConnectionNotifyProc: (@convention(c) (
        _ cid: CGSConnectionID, _ proc: CGSConnectionNotifyProc,
        _ event: UInt32, _ context: UnsafeMutableRawPointer?) -> CGError)? =
        slsSymbol("SLSRegisterConnectionNotifyProc")

    // Batched window query (one IPC for a whole wid set; the iterator getters
    // read the local snapshot). See WindowServerTap.pruneIfNeeded.
    static let windowQueryWindows: (@convention(c) (
        _ cid: CGSConnectionID, _ windows: CFArray, _ options: Int32) -> Unmanaged<CFTypeRef>)? =
        slsSymbol("SLSWindowQueryWindows")

    static let windowQueryResultCopyWindows: (@convention(c) (
        _ query: CFTypeRef) -> Unmanaged<CFTypeRef>)? =
        slsSymbol("SLSWindowQueryResultCopyWindows")

    static let windowIteratorAdvance: (@convention(c) (_ iterator: CFTypeRef) -> Bool)? =
        slsSymbol("SLSWindowIteratorAdvance")

    static let windowIteratorGetWindowID: (@convention(c) (_ iterator: CFTypeRef) -> CGWindowID)? =
        slsSymbol("SLSWindowIteratorGetWindowID")

    /// Window ids (of `wids`) the WindowServer still lists — minimized and
    /// other-Space windows included, which an on-screen snapshot cannot see.
    /// Runs one batched IPC; blocks while the WindowServer is busy (measured
    /// ~27ms during a Space transition), so callers must run it off-main.
    static func existingWindowIDs(_ wids: [CGWindowID]) -> Set<CGWindowID>? {
        guard let query = windowQueryWindows,
              let copyResult = windowQueryResultCopyWindows,
              let advance = windowIteratorAdvance,
              let getWindowID = windowIteratorGetWindowID,
              !wids.isEmpty else { return nil }
        let result = query(CGSMainConnectionID(), wids as CFArray, 0).takeRetainedValue()
        let iterator = copyResult(result).takeRetainedValue()
        var ids = Set<CGWindowID>()
        ids.reserveCapacity(wids.count)
        while advance(iterator) {
            ids.insert(getWindowID(iterator))
        }
        return ids
    }
}

/// The WindowServer notifications SmartFocus acts on (raw ids, see above).
enum WSNotification: UInt32, CaseIterable {
    case windowCreated = 811
    case windowDestroyed = 804
    case windowFocused = 808
    case windowOrderedIn = 815
    case windowOrderedOut = 816
    case spaceCurrentChanged = 1329
    case activeSpaceChanged = 1401
}

/// Bridges the WindowServer notify-proc stream into main-queue callbacks.
/// The C callback fires on whichever thread snarfs the WindowServer datagram
/// (often _NSEventThread) with a payload pointer valid only for that call, so
/// it extracts the integers synchronously and hops to main itself. Do NOT call
/// SLSConnectionDispatchNotificationsToMainQueueIfNotMainThread on this shared
/// connection: it displaces AppKit's own coordinated-notification routing and
/// crashes its main-thread-only handlers (lesson from AltTab).
final class WindowServerTap {
    static private(set) var shared: WindowServerTap?

    var onEvent: ((WSNotification, CGWindowID) -> Void)?

    private let cid = CGSMainConnectionID()
    /// Per-window events (destroy/focus/order) only arrive for subscribed
    /// windows. Grows without snapshot-based pruning: the on-screen snapshot
    /// cannot see other-Space windows, so pruning by snapshot would deafen us
    /// to them. `pruneIfNeeded` reconciles against an all-window query instead;
    /// only a confirmed destroy (804) removes a wid immediately.
    private var subscribed = Set<CGWindowID>()
    /// Subscribe time per wid: wids younger than 30s are exempt from pruning —
    /// a window created a beat ago may not appear in the query result yet.
    private var subscribedAt = [CGWindowID: Date]()
    /// Prunes run at most once per 60s; written on main only.
    private var lastPruneAt = Date.distantPast
    /// The all-window query blocks while the WindowServer is busy — never main.
    private let pruneQueue = DispatchQueue(label: "com.baikong.smartfocus.prune", qos: .utility)
    private var requestPending = false

    /// Non-capturing C callback (required by @convention(c)); reaches the
    /// instance through the static singleton.
    private let notifyProc: CGSConnectionNotifyProc = { event, data, len, _, _ in
        var wid: CGWindowID = 0
        if let data, len >= 4 { memcpy(&wid, data, 4) }
        guard let n = WSNotification(rawValue: event) else { return }
        DispatchQueue.main.async {
            WindowServerTap.shared?.deliver(n, wid)
        }
    }

    /// True once the notify procs are registered; the app checks this to pick
    /// its fallback cadence (fast timer when the tap is unavailable).
    private(set) var isActive = false

    func start() {
        WindowServerTap.shared = self
        guard let register = SkyLight.registerConnectionNotifyProc else {
            log("⚠️ SkyLight 符号不可用，事件流降级为兜底轮询", level: .error)
            return
        }
        for n in WSNotification.allCases {
            _ = register(cid, notifyProc, n.rawValue, nil)
        }
        isActive = true
        log("🔌 WindowServer 事件流已接入 (cid: \(cid))")
    }

    private func deliver(_ n: WSNotification, _ wid: CGWindowID) {
        if n == .windowDestroyed {
            subscribed.remove(wid)
            subscribedAt.removeValue(forKey: wid)
            scheduleRequest()
        }
        onEvent?(n, wid)
    }

    /// Bulk subscribe from a window snapshot; coalesced to one request per
    /// main-runloop tick so a scan adds many windows with one call.
    func subscribe(_ wids: Set<CGWindowID>) {
        let fresh = wids.subtracting(subscribed)
        guard !fresh.isEmpty else { return }
        subscribed.formUnion(fresh)
        let now = Date()
        for wid in fresh { subscribedAt[wid] = now }
        scheduleRequest()
    }

    func subscribe(_ wid: CGWindowID) {
        guard subscribed.insert(wid).inserted else { return }
        subscribedAt[wid] = Date()
        scheduleRequest()
    }

    /// Periodically drop wids the WindowServer no longer lists. Apps that
    /// retain their CGWindow close without a 804, and blind 811 subscriptions
    /// add transient animation windows — without pruning the watch list is the
    /// session's HISTORY, not its current windows. The all-window query sees
    /// minimized and other-Space windows, so it is the only safe source.
    /// Entry from the check queue; state lives on main, only the query runs
    /// off-main.
    func pruneIfNeeded() {
        guard isActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  Date().timeIntervalSince(self.lastPruneAt) >= 60 else { return }
            self.lastPruneAt = Date()
            let now = Date()
            let candidates = Set(self.subscribedAt.filter { _, at in
                now.timeIntervalSince(at) >= 30
            }.keys)
            guard !candidates.isEmpty else { return }
            self.pruneQueue.async { [weak self] in
                guard let existing = SkyLight.existingWindowIDs(Array(candidates)) else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.applyPrune(candidates: candidates, existing: existing)
                }
            }
        }
    }

    private func applyPrune(candidates: Set<CGWindowID>, existing: Set<CGWindowID>) {
        let stale = candidates.subtracting(existing)
        guard !stale.isEmpty else { return }
        for wid in stale {
            subscribed.remove(wid)
            subscribedAt.removeValue(forKey: wid)
        }
        log("🧹 修剪 \(stale.count) 个失效窗口订阅（剩 \(subscribed.count)）")
        scheduleRequest()
    }

    private func scheduleRequest() {
        guard !requestPending else { return }
        requestPending = true
        DispatchQueue.main.async { [weak self] in
            self?.requestPending = false
            self?.requestNotifications()
        }
    }

    private func requestNotifications() {
        guard let request = SkyLight.requestNotificationsForWindows else { return }
        var list = Array(subscribed)
        guard !list.isEmpty else { return }
        _ = request(cid, &list, Int32(list.count))
    }
}

// MARK: - 全局日志函数 (替代 print)
enum LogLevel {
    case debug
    case error
}

/// 统一日志输出入口：error 始终输出，debug 仅在调试模式开启时输出
func log(_ message: String, level: LogLevel = .debug) {
    LogRedirector.shared.write(message + "\n", level: level)
}

// MARK: - 配置管理
struct Config: Codable {
    // Bundle ids are the primary match key; WindowServer stays as a name
    // because it is a root process NSRunningApplication cannot resolve.
    static let defaultBlacklist: Set<String> = ["com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow", "WindowServer"]

    /// Deprecated: unused since detection became WindowServer-event-driven
    /// (5s fixed fallback timer). Kept so older config files still decode.
    var pollInterval: Double = 0.2
    var blacklist: Set<String> = Config.defaultBlacklist
    var debugLogging: Bool = false

    static let defaultConfig = Config()

    init() {}

    /// Tolerate missing keys so configs written by older versions still load
    /// (a plain synthesized decode would fail and silently fall back to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 0.2
        blacklist = try c.decodeIfPresent(Set<String>.self, forKey: .blacklist) ?? Config.defaultBlacklist
        debugLogging = try c.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? false
    }
    
    static let configURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".smartfocus/config.json")
    }()
    
    /// 确保配置目录和文件存在，若不存在则创建默认配置
    static func ensureConfigFile() {
        let fm = FileManager.default
        let dirURL = configURL.deletingLastPathComponent()
        
        if !fm.fileExists(atPath: dirURL.path) {
            do {
                try fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                log("⚠️ 无法创建配置目录: \(error.localizedDescription)", level: .error)
                return
            }
        }
        
        if !fm.fileExists(atPath: configURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(defaultConfig) {
                do {
                    try data.write(to: configURL)
                    log("📝 已自动生成默认配置文件: ~/.smartfocus/config.json")
                } catch {
                    log("⚠️ 无法写入默认配置文件: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }
    
    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return defaultConfig
        }
        return config
    }
}

// MARK: - 黑名单匹配器
/// Matches blacklist entries against apps. Bundle ids are the primary key:
/// unlike localizedName ("Finder" vs "访达"), they are stable across locales
/// and app rename events. Name matching stays as a fallback — for entries
/// written as display names, and for system processes (WindowServer) that
/// NSRunningApplication cannot see. The window list exposes only owner
/// name/PID, so bundle-id entries are resolved to a PID set up front and
/// re-resolved whenever apps launch or terminate (PIDs are not stable).
struct BlacklistMatcher {
    private let entries: Set<String>
    private let pids: Set<pid_t>

    init(entries: Set<String>) {
        self.entries = entries
        var resolved = Set<pid_t>()
        for entry in entries where entry.contains(".") {
            // Dotted entries look like bundle ids; resolve their running
            // processes once here so the window scan can match by PID.
            resolved.formUnion(
                NSRunningApplication.runningApplications(withBundleIdentifier: entry).map(\.processIdentifier)
            )
        }
        self.pids = resolved
    }

    func matches(_ app: NSRunningApplication) -> Bool {
        matches(name: app.localizedName,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier)
    }

    func matches(name: String?, pid: pid_t? = nil, bundleIdentifier: String? = nil) -> Bool {
        if let bundleIdentifier, entries.contains(bundleIdentifier) { return true }
        if let name, !name.isEmpty, entries.contains(name) { return true }
        if let pid, pids.contains(pid) { return true }
        return false
    }
}

// MARK: - 主窗口控制器
/// The app's main control panel: status line, quick toggles/actions, and the
/// embedded log console (replaces the old standalone console window). A real
/// window keeps the app reachable from Dock/Spotlight even when the user
/// hides the menu bar. All UI actions delegate back to the app object so the
/// menu bar items and window controls share one code path.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    // DateFormatter is expensive to create; share one instance instead of
    // building a fresh formatter per log line (debug bursts log at 20 Hz).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    // Rolling cap on the log buffer: unbounded textStorage growth leaks
    // memory over long sessions. When exceeded, drop the oldest half,
    // cutting at a line boundary.
    private var logChars = 0
    private let maxLogChars = 200_000

    private var statusLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var debugSwitch: NSSwitch!
    private var loginSwitch: NSSwitch!
    private var logTextView: NSTextView!

    var onToggleDebugLogging: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onReloadConfig: (() -> Void)?
    var onOpenConfigFile: (() -> Void)?
    var onClearLog: (() -> Void)?
    var onQuit: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            // No .miniaturizable: without a Dock icon a minimized window has
            // nowhere to go and would be unreachable (reopen sees a window
            // and skips showing)
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "SmartFocus"
        window.minSize = NSSize(width: 440, height: 440)
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        statusLabel = NSTextField(labelWithString: "● 运行中")
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .systemGreen

        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor

        debugSwitch = NSSwitch()
        debugSwitch.target = self
        debugSwitch.action = #selector(switchChanged(_:))

        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(switchChanged(_:))

        let reloadButton = button("重载配置", id: "reload")
        let configButton = button("打开配置文件", id: "openConfig")
        let clearButton = button("清空", id: "clearLog")
        let quitButton = button("退出应用", id: "quit")
        // Destructive action: own row, red label. Bordered push buttons
        // ignore contentTintColor for the title; an attributed title tints.
        quitButton.attributedTitle = NSAttributedString(
            string: "退出应用",
            attributes: [.foregroundColor: NSColor.systemRed]
        )

        logTextView = NSTextView()
        logTextView.isEditable = false
        logTextView.isRichText = false
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textColor = .labelColor
        logTextView.backgroundColor = .textBackgroundColor

        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .lineBorder
        logScroll.documentView = logTextView
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        // Document view follows the clip view; Auto Layout governs the
        // scroll view itself (same recipe the old console used).
        logTextView.frame = logScroll.contentView.bounds
        logTextView.autoresizingMask = [.width, .height]

        let buttons = NSStackView(views: [reloadButton, configButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(statusLabel)
        controls.addArrangedSubview(infoLabel)
        controls.addArrangedSubview(makeSeparator())
        controls.addArrangedSubview(makeRow("调试日志", control: debugSwitch))
        controls.addArrangedSubview(makeRow("开机自启动", control: loginSwitch))
        controls.addArrangedSubview(makeSeparator())
        controls.addArrangedSubview(buttons)

        // Log section: the header row hugs its scroll view (same margins,
        // tight spacing) so 日志/清空 read as part of the log, while the
        // status/toggle/button rows above stay their own section
        let logHeader = makeRow("日志", control: clearButton)
        let logSection = NSStackView()
        logSection.orientation = .vertical
        logSection.spacing = 4
        logSection.translatesAutoresizingMaskIntoConstraints = false
        logSection.addArrangedSubview(logHeader)
        logSection.addArrangedSubview(logScroll)
        logHeader.widthAnchor.constraint(equalTo: logSection.widthAnchor).isActive = true

        // Quit as a detached footer row at the very bottom, visually apart
        // from the config controls
        let quitRow = NSStackView()
        quitRow.orientation = .horizontal
        let quitSpacer = NSView()
        quitSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        quitRow.addArrangedSubview(quitSpacer)
        quitRow.addArrangedSubview(quitButton)

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.spacing = 12
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(controls)
        outer.addArrangedSubview(logSection)
        outer.addArrangedSubview(quitRow)
        quitRow.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        contentView.addSubview(outer)

        // Stretch every section to the panel width; the log takes the rest.
        controls.arrangedSubviews.forEach {
            $0.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            outer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            outer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            outer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    private func button(_ title: String, id: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(buttonClicked(_:)))
        b.bezelStyle = .rounded
        b.identifier = NSUserInterfaceItemIdentifier(id)
        return b
    }

    private func makeRow(_ title: String, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(label)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        return row
    }

    private func makeSeparator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        if sender === debugSwitch {
            onToggleDebugLogging?()
        } else if sender === loginSwitch {
            onToggleLaunchAtLogin?()
        }
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "reload": onReloadConfig?()
        case "openConfig": onOpenConfigFile?()
        case "clearLog": onClearLog?()
        case "quit": onQuit?()
        default: break
        }
    }

    /// Sync the panel with app state; call after any config change.
    func refresh(blacklistCount: Int,
                 version: String, debugEnabled: Bool, launchAtLogin: Bool?) {
        statusLabel.stringValue = "● 运行中"
        infoLabel.stringValue = "事件驱动 · 黑名单 \(blacklistCount) 项 · v\(version)"
        debugSwitch.state = debugEnabled ? .on : .off
        if let launchAtLogin {
            loginSwitch.isEnabled = true
            loginSwitch.state = launchAtLogin ? .on : .off
        } else {
            loginSwitch.isEnabled = false
        }
    }

    func appendLog(_ message: String, isError: Bool = false) {
        let logLine = "[\(Self.timeFormatter.string(from: Date()))] \(message)\n"

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let storage = self.logTextView.textStorage else { return }
            let attributes: [NSAttributedString.Key: Any] = isError ? [.foregroundColor: NSColor.systemRed] : [:]
            storage.append(NSAttributedString(string: logLine, attributes: attributes))
            self.logChars += logLine.count
            if self.logChars > self.maxLogChars, storage.length > self.maxLogChars / 2 {
                let cut = self.logChars - self.maxLogChars / 2
                let full = storage.string
                if let start = full.index(full.startIndex, offsetBy: cut, limitedBy: full.endIndex),
                   let newline = full[start...].firstIndex(of: "\n") {
                    let len = full.distance(from: full.startIndex, to: newline) + 1
                    storage.replaceCharacters(in: NSRange(location: 0, length: len), with: "")
                    self.logChars -= len
                }
            }
            self.logTextView.scrollRangeToVisible(NSRange(location: self.logTextView.string.count, length: 0))
        }
    }

    func clearLog() {
        DispatchQueue.main.async { [weak self] in
            self?.logTextView.string = ""
            self?.logChars = 0
        }
    }
}

// MARK: - 日志重定向器
class LogRedirector {
    static let shared = LogRedirector()
    var console: MainWindowController?
    var debugEnabled = false

    func write(_ string: String, level: LogLevel) {
        guard level == .error || debugEnabled else { return }
        // 保持 stderr 输出，确保 Xcode / 终端调试器可见
        fputs(string, stderr)
        // 同步更新到主窗口日志区
        console?.appendLog(string.trimmingCharacters(in: .newlines), isError: level == .error)
    }
}

// MARK: - 菜单栏应用主体
class SmartFocusApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWC = MainWindowController()
    
    private var topID: CGWindowID = 0
    private var menuBarIcon: NSImage?
    private let ownPID = getpid()
    private var config = Config.load()
    private var blacklistMatcher = BlacklistMatcher(entries: [])
    private let wsTap = WindowServerTap()
    /// Slow self-heal only: catches missed WindowServer events, keeps the
    /// permission watchdog alive at idle, re-syncs per-window subscriptions.
    /// Never the detection path.
    private var fallbackTimer: Timer?
    private var isChecking = false
    private var interventionCooldownUntil = Date.distantPast
    // Consecutive activation failures for one target (window ID, or 0 for the
    // Finder fallback): after 3 strikes we give up and let the anchor roll
    // forward, so a permanently rejected activate() cannot retry forever.
    // The budget is per disappearance episode (identified by the vanished
    // anchor window): a fresh event must not inherit a stale strike count.
    private var focusFailures = 0
    private var focusFailureTarget: CGWindowID?
    private var focusFailureAnchor: CGWindowID = 0
    private let checkQueue = DispatchQueue(label: "com.baikong.smartfocus.check", qos: .userInteractive)
    private var configWatcher: DispatchSourceFileSystemObject?
    // True right after persistConfig's own write: lets the watcher skip the
    // self-triggered reload/log (but still re-arm, since the atomic save
    // replaces the watched inode).
    private var suppressNextConfigEvent = false
    private var statusMenuItem: NSMenuItem!

    // A LaunchServices launch (Spotlight / Finder / `open`) delivers an
    // 'oapp' Apple event; a login-item launch is a bare launchd spawn with
    // no pending event. Read in applicationWillFinishLaunching — the event
    // is consumed by the time didFinishLaunching runs.
    private var launchedByUserAction = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedByUserAction = NSAppleEventManager.shared().currentAppleEvent != nil
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        LogRedirector.shared.console = mainWC

        Config.ensureConfigFile()
        config = Config.load()
        blacklistMatcher = BlacklistMatcher(entries: config.blacklist)
        LogRedirector.shared.debugEnabled = config.debugLogging

        setupMenuBar()
        setupMainMenu()
        setupWorkspaceObservers()
        setupWindowServerTap()
        startFallbackTimer()
        watchConfig()

        // Window actions share the menu items' selectors so there is one
        // code path per action.
        mainWC.onToggleDebugLogging = { [weak self] in self?.toggleDebugLogging() }
        mainWC.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        mainWC.onReloadConfig = { [weak self] in self?.reloadConfig() }
        mainWC.onOpenConfigFile = { [weak self] in self?.openConfigFile() }
        mainWC.onClearLog = { [weak self] in self?.clearLog() }
        mainWC.onQuit = { [weak self] in self?.quitApp() }
        refreshMainStatus()
        tick() // immediate first check: sets the initial anchor and subscriptions
        if launchedByUserAction {
            showMainWindow()
            log("⚡️ SmartFocus 已启动")
        } else {
            // Login-item launch: stay hidden; Spotlight / menu bar bring
            // the window up on demand
            log("⚡️ SmartFocus 已随登录启动（后台静默运行）")
        }
    }

    /// Spotlight/Dock activation of an already-running app lands here; bring
    /// the panel back up so "open SmartFocus" always has a visible effect.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // 👇 修复图标加载与模板适配
        if let button = statusItem.button {
            var icon: NSImage?
            
            // 优先尝试加载 SF Symbol (macOS 11+)
            if #available(macOS 11.0, *) {
                icon = NSImage(systemSymbolName: "cursorarrow.click.badge.clock", accessibilityDescription: "SmartFocus")
            }
            
            // 兜底方案：如果 SF Symbol 不可用或加载失败，使用 Unicode 字符绘制
            if icon == nil {
                let fallbackString = "⚡️"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.labelColor
                ]
                let size = fallbackString.size(withAttributes: attributes)
                icon = NSImage(size: size, flipped: false) { rect in
                    fallbackString.draw(in: rect, withAttributes: attributes)
                    return true
                }
            }
            
            // ⚠️ 关键：设置为模板图像，自动适配深浅色模式
            icon?.isTemplate = true
            menuBarIcon = icon
            button.image = icon
        }
        
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "✅ 运行中 | 事件驱动", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        // No key equivalents: ⌘C/⌘Q etc. must never be hijacked from the active
        // app while our window or menu has focus. Everything else lives in the
        // main window; the bar menu stays minimal.
        menu.addItem(NSMenuItem(title: "🪟 打开主窗口", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "🔄 重载配置", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "📝 打开配置文件", action: #selector(openConfigFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "❌ 退出 SmartFocus", action: #selector(quitApp), keyEquivalent: ""))
        
        statusItem.menu = menu
    }
    
    @objc private func showMainWindow() {
        mainWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Without a mainMenu, standard edit commands (⌘C/⌘A) never dispatch inside
    /// accessory (LSUIElement) apps — a minimal Edit menu fixes text selection
    /// in the console. It only takes effect while our own window is key, so it
    /// cannot hijack shortcuts from other apps (the accessory policy keeps the
    /// menu bar itself hidden).
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
    
    @objc private func clearLog() {
        mainWC.clearLog()
        log("🗑️ 日志已清空")
    }

    /// Push app state into the main window's status line / switches.
    private func refreshMainStatus() {
        var launchAtLogin: Bool?
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        mainWC.refresh(blacklistCount: config.blacklist.count,
                       version: version,
                       debugEnabled: config.debugLogging,
                       launchAtLogin: launchAtLogin)
    }
    
    @objc private func reloadConfig() {
        applyConfig()
        log("🔄 手动重载配置成功 | 黑名单: \(config.blacklist.count)项")
    }

    @objc private func toggleDebugLogging() {
        persistConfig { $0.debugLogging.toggle() }
        applyDebugState()
        refreshMainStatus()
        log("🐞 调试日志已\(config.debugLogging ? "开启" : "关闭")")
    }

    /// (Re)load config from disk and propagate it to the timer / debug state / menu
    private func applyConfig() {
        config = Config.load()
        blacklistMatcher = BlacklistMatcher(entries: config.blacklist)
        applyDebugState()
        refreshMainStatus()
    }

    private func applyDebugState() {
        LogRedirector.shared.debugEnabled = config.debugLogging
    }

    // MARK: - Launch at login

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            log("🚀 开机自启动已\(service.status == .enabled ? "开启" : "关闭")")
        } catch {
            log("⚠️ 开机自启动设置失败: \(error.localizedDescription)", level: .error)
        }
        updateLaunchAtLoginState()
    }

    private func updateLaunchAtLoginState() {
        // The menu no longer mirrors this; the main window switch is the UI.
        refreshMainStatus()
    }

    /// Merge a field mutation into the on-disk config before writing. Writing
    /// the in-memory copy directly would clobber external edits made since
    /// the last reload; loading first keeps them. Our own write sets the
    /// suppress flag so the watcher doesn't echo a redundant reload.
    private func persistConfig(mutating: (inout Config) -> Void) {
        var merged = Config.load()
        mutating(&merged)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(merged) {
            do {
                suppressNextConfigEvent = true
                try data.write(to: Config.configURL)
                config = merged
            } catch {
                suppressNextConfigEvent = false
                log("⚠️ 无法写入配置文件: \(error.localizedDescription)", level: .error)
            }
        }
    }
    
    @objc private func openConfigFile() {
        // Self-heal in case the file was deleted while the app is running
        Config.ensureConfigFile()
        NSWorkspace.shared.open(Config.configURL)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateStatusText() {
        statusMenuItem.title = "✅ 运行中 | 事件驱动 | 黑名单: \(config.blacklist.count)项"
    }

    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        // Fast fallback cadence when the WindowServer tap is unavailable
        let interval: TimeInterval = wsTap.isActive ? 5 : 0.2
        fallbackTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common mode keeps the fallback timer alive during menu tracking / window dragging
        RunLoop.main.add(fallbackTimer!, forMode: .common)
        updateStatusText()
    }

    // MARK: - Event-driven focus correction
    /// WindowServer events (window create/destroy/order/focus, Space switches)
    /// drive detection at the exact moment things change — no polling on the
    /// hot path. NSWorkspace still covers what the WindowServer cannot see
    /// (hide is an AppKit state) and acts as a redundant trigger.
    private func setupWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        [NSWorkspace.didHideApplicationNotification,
         NSWorkspace.didDeactivateApplicationNotification,
         NSWorkspace.didTerminateApplicationNotification,
         NSWorkspace.didLaunchApplicationNotification,
         NSWorkspace.didActivateApplicationNotification].forEach {
            nc.addObserver(self, selector: #selector(handleWorkspaceEvent(_:)), name: $0, object: nil)
        }
    }

    private func setupWindowServerTap() {
        wsTap.onEvent = { [weak self] notification, wid in
            self?.handleWindowServerEvent(notification, wid: wid)
        }
        wsTap.start()
    }

    private func handleWindowServerEvent(_ n: WSNotification, wid: CGWindowID) {
        switch n {
        case .windowCreated:
            // Subscribe blind — the layer is unknown until the next snapshot;
            // a non-layer-0 window's events are ignored by the anchor check.
            wsTap.subscribe(wid)
            tick()
        case .windowDestroyed, .windowOrderedOut:
            // Close (804) / minimize or order-out (816) of the tracked window:
            // check immediately, then once more after the system's own focus
            // fallback had time to land (or not).
            if wid == topID {
                tick()
                schedulePostCooldownCheck(after: 0.25)
            }
        case .windowFocused:
            // A fresh window focus is a deliberate choice (user click, cmd-tab,
            // or our own intervention): stand down briefly, then re-check.
            interventionCooldownUntil = Date().addingTimeInterval(0.2)
            schedulePostCooldownCheck(after: 0.2)
            tick()
        case .windowOrderedIn:
            // A window reappearing (un-minimize) can change the z-order candidate
            tick()
        case .spaceCurrentChanged, .activeSpaceChanged:
            // Space-switch animation rewrites the on-screen window list
            // wholesale while target windows have not landed yet; wait it out.
            interventionCooldownUntil = Date().addingTimeInterval(0.5)
            schedulePostCooldownCheck(after: 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tick()
            }
        }
    }

    @objc private func handleWorkspaceEvent(_ note: Notification) {
        switch note.name {
        case NSWorkspace.didActivateApplicationNotification:
            // A fresh activation means the user/system just chose an app
            // (AltTab landing, window deminimize): never fight it. But an
            // activation landing on a BLACKLISTED app is a failed fallback,
            // not a user choice — that is exactly when we must stay armed.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               !blacklistMatcher.matches(app) {
                // 200ms: switcher landings settle well within that; longer
                // cooldowns delay close-triggered interventions too much
                interventionCooldownUntil = Date().addingTimeInterval(0.2)
                schedulePostCooldownCheck(after: 0.2)
            }
            tick()
        default:
            // App set changed: re-resolve bundle-id entries to fresh PIDs (a
            // relaunched blacklisted app gets a new PID; a stale one could be
            // reused by an unrelated process).
            if note.name == NSWorkspace.didLaunchApplicationNotification ||
               note.name == NSWorkspace.didTerminateApplicationNotification {
                blacklistMatcher = BlacklistMatcher(entries: config.blacklist)
            }
            // didDeactivate fires on every ordinary app switch; a short delay lets
            // the system's own focus settling finish first. It can stay short
            // because the "accept the system's fallback" check prevents fighting.
            let delay: TimeInterval = note.name == NSWorkspace.didDeactivateApplicationNotification ? 0.05 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tick()
            }
        }
    }

    /// The burst may burn out entirely inside the cooldown window; fire one
    /// check the moment the cooldown expires so intervention doesn't have to
    /// wait for the next fallback-poll tick.
    private func schedulePostCooldownCheck(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.tick()
        }
    }

    private func watchConfig() {
        configWatcher?.cancel()
        configWatcher = nil

        let path = Config.configURL.path
        var fd = open(path, O_EVTONLY)
        if fd < 0 {
            // File was deleted outright: recreate defaults and try again
            // so hot-reload survives instead of silently dying
            Config.ensureConfigFile()
            fd = open(path, O_EVTONLY)
        }
        guard fd >= 0 else {
            log("⚠️ 无法监听配置文件，热重载已禁用", level: .error)
            return
        }

        // .delete/.rename cover atomic saves (editors write a temp file and
        // rename over the original): the old fd then points at an unlinked
        // inode and must be re-armed on the new one, or watch dies silently.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )

        // 确保 source 取消时关闭文件描述符，防止 fd 泄漏
        source.setCancelHandler {
            close(fd)
        }

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = self.configWatcher?.data ?? []
            if self.suppressNextConfigEvent {
                self.suppressNextConfigEvent = false
            } else {
                self.applyConfig()
                log("🔄 自动检测到配置变更并已应用")
            }
            if event.contains(.delete) || event.contains(.rename) {
                self.watchConfig()
            }
        }
        source.resume()
        configWatcher = source
    }

    /// CGWindowListCopyWindowInfo is a synchronous XPC round-trip; running it on
    /// the main thread during bursts caused visible stutter on app switches.
    /// Snapshot + parse off-main, then settle the result (topID/activate) on main.
    /// `isChecking` (main-thread only) guarantees no overlapping checks, so the
    /// off-main read of topID below cannot race with the main-thread write.
    ///
    /// Intervention policy (minimal interference): macOS already falls back to
    /// the most-recently-used app when a window closes. If that fallback landed
    /// on a usable app, accept it — activating our own z-order candidate on top
    /// produces a visible double-switch that feels like stutter. Only step in
    /// when the system's fallback failed (focus vacuum / landed on a
    /// blacklisted app).
    private func tick() {
        guard !isChecking else { return }
        isChecking = true
        let blacklist = blacklistMatcher // value copy, safe to read off-main
        checkQueue.async { [weak self] in
            guard let self = self else { return }
            let list = self.snapshot()
            self.wsTap.pruneIfNeeded()
            let cur = list.flatMap { self.firstUsable(in: $0, blacklist: blacklist) }
            let previousID = self.topID
            let previousStillOnScreen = list.map { self.contains($0, previousID) } ?? true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                defer { self.isChecking = false }

                guard let list = list else { return }
                // Re-align the per-window subscription with reality; the
                // snapshot is the only source of current layer-0 window ids.
                wsTap.subscribe(layer0WindowIDs(in: list))
                guard cur?.windowNumber != previousID else { return }

                let nextID = cur?.windowNumber ?? 0
                // Consume the anchor (update topID) only on paths that RESOLVED
                // the disappearance. The cooldown path keeps the old anchor:
                // consuming the "window disappeared" evidence while unhandled
                // makes the post-cooldown check see cur == topID and
                // short-circuit forever — the vacuum never gets fixed.
                var keepPreviousAnchor = false
                defer {
                    if !keepPreviousAnchor { self.topID = nextID }
                }

                guard previousID != 0, !previousStillOnScreen else { return }

                // The tracked window just disappeared (close event)
                if self.systemSettledOnUsableApp(blacklist: blacklist, windowList: list) {
                    log("✅ 系统已自行回落焦点，跳过干预")
                    return
                }
                // Cooldown is the only switcher guard we need: it covers exactly
                // the "user just chose an app / space is animating" transients.
                // Outside a cooldown, an unusable frontmost after a window
                // disappearance is a real vacuum — act immediately.
                if Date() < self.interventionCooldownUntil {
                    keepPreviousAnchor = true
                    log("🧊 冷却期，暂不干预（保留消失锚点，冷却后重判）")
                    return
                }
                // No qualifying window remains anywhere: land on Finder (the
                // Desktop), matching where the system's own hide-fallback ends
                // up — Finder can hold focus with zero windows. Skip when
                // Finder is already frontmost (we're on the Desktop already).
                guard let info = cur else {
                    if let front = NSWorkspace.shared.frontmostApplication,
                       front.bundleIdentifier == "com.apple.finder" {
                        log("🏠 已在访达/桌面")
                        return
                    }
                    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                       finder.activate() {
                        resetFocusFailures()
                        log("🏠 无可用窗口，回落到访达/桌面")
                    } else if shouldRetryActivation(target: 0, anchor: previousID) {
                        keepPreviousAnchor = true
                    } else {
                        log("⚠️ 回落访达连续失败，放弃并重置锚点", level: .error)
                    }
                    return
                }
                if self.doFocus(info) {
                    resetFocusFailures()
                    log("🎯 焦点切换 -> \(info.name) (PID: \(info.pid))")
                } else if shouldRetryActivation(target: info.windowNumber, anchor: previousID) {
                    // Keep the disappearance evidence so the next tick retries;
                    // consuming it here would short-circuit forever (cur == topID).
                    keepPreviousAnchor = true
                } else {
                    log("⚠️ 激活 \(info.name) 连续失败，放弃并重置锚点", level: .error)
                }
            }
        }
    }

    /// True when the system's own focus fallback landed on an app we consider
    /// usable: not blacklisted, AND it still owns a visible window. The window
    /// check is essential — apps like Chrome/VS Code stay frontmost with zero
    /// windows after their last window closes, which is exactly the focus
    /// vacuum this tool exists to fix. Ourselves: settled only while our own
    /// window is on screen — the user is deliberately in our panel, and a
    /// background window closing behind it is not a vacuum to fix.
    private func systemSettledOnUsableApp(blacklist: BlacklistMatcher, windowList: [[String: Any]]) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if front.processIdentifier == ownPID {
            return appHasVisibleWindow(pid: ownPID, in: windowList)
        }
        guard !blacklist.matches(front),
              appHasVisibleWindow(pid: front.processIdentifier, in: windowList)
        else { return false }
        return true
    }

    private func appHasVisibleWindow(pid: pid_t, in list: [[String: Any]]) -> Bool {
        list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// Flip the menu bar icon (reserved for future states); logs on
    /// transitions so bursts don't spam the console.

    private func snapshot() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    /// Layer-0 (normal app window) ids from an on-screen snapshot — the set of
    /// windows worth receiving per-window WindowServer events for.
    private func layer0WindowIDs(in list: [[String: Any]]) -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for w in list {
            if (w[kCGWindowLayer as String] as? Int) == 0,
               let id = w[kCGWindowNumber as String] as? CGWindowID {
                ids.insert(id)
            }
        }
        return ids
    }

    private func contains(_ list: [[String: Any]], _ id: CGWindowID) -> Bool {
        list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    private func firstUsable(in list: [[String: Any]], blacklist: BlacklistMatcher) -> (windowNumber: CGWindowID, pid: pid_t, name: String)? {
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  // TCC strips owner NAMES without Screen Recording but leaves
                  // the list itself (pids, layer, bounds) intact — so resolve the
                  // app from the pid and skip anything NSRunningApplication
                  // cannot see (root/system processes: no activate() possible
                  // anyway). Side effect: no Screen Recording permission needed.
                  let app = NSRunningApplication(processIdentifier: pid),
                  !blacklist.matches(name: app.localizedName, pid: pid, bundleIdentifier: app.bundleIdentifier),
                  // Skip tiny floating panels/widgets (BetterDisplay HUDs, status
                  // panels...): they are layer-0 windows but worthless as a
                  // focus-restore target — landing on one feels like nothing happened
                  let frame = w[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
                  frame.width >= 120, frame.height >= 120
            else { continue }
            return (id, pid, app.localizedName ?? "PID \(pid)")
        }
        return nil
    }

    /// Reset the activation-failure streak (any successful intervention, or a
    /// target change, starts a fresh count).
    private func resetFocusFailures() {
        focusFailures = 0
        focusFailureTarget = nil
    }

    /// Count one failure for `target`; true while the caller should keep the
    /// anchor and retry, false once the same target has failed 3 times within
    /// the current episode (identified by `anchor`, the vanished window).
    private func shouldRetryActivation(target: CGWindowID, anchor: CGWindowID) -> Bool {
        if focusFailureAnchor != anchor {
            focusFailureAnchor = anchor
            focusFailures = 0
        }
        if focusFailureTarget == target {
            focusFailures += 1
        } else {
            focusFailureTarget = target
            focusFailures = 1
        }
        return focusFailures < 3
    }

    private func doFocus(_ info: (windowNumber: CGWindowID, pid: pid_t, name: String)) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: info.pid) else {
            log("⚠️ 目标进程不存在 (PID: \(info.pid))", level: .error)
            return false
        }
        // Before macOS 14, a bare activate() often lost to the system's own focus
        // fallback (visible double-switches); macOS 14+ deprecated the flag and
        // changed activate() semantics, where it has no effect anyway.
        var ok: Bool
        if #available(macOS 14.0, *) {
            ok = app.activate()
            if !ok {
                // macOS 14+ focus-stealing protection rejects activate() from a
                // background app. Briefly taking activation ourselves turns the
                // call into a frontmost handoff, which the system allows; the
                // deprecated ignoringOtherApps variant is still honored here.
                NSApp.activate(ignoringOtherApps: true)
                ok = app.activate()
            }
        } else {
            ok = app.activate(options: [.activateIgnoringOtherApps])
        }
        if !ok {
            log("⚠️ activate(\(info.name)) 被系统拒绝", level: .error)
        }
        return ok
    }
}

// MARK: - 启动入口
let app = NSApplication.shared
let delegate = SmartFocusApp()
app.delegate = delegate
// Accessory agent: no Dock icon. The window is reachable via Spotlight /
// menu bar; ✕ only closes the window — quit is the app's own button only.
app.setActivationPolicy(.accessory)
app.run()