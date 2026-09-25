import Cocoa
import CoreGraphics
import ServiceManagement

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
              var config = try? JSONDecoder().decode(Config.self, from: data) else {
            return defaultConfig
        }
        // Enforce a floor: real-time reaction is handled by workspace events,
        // the timer is only a fallback, so ultra-small intervals are pointless.
        config.pollInterval = max(config.pollInterval, 0.1)
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
    private var permissionButton: NSButton!
    private var infoLabel: NSTextField!
    private var debugSwitch: NSSwitch!
    private var loginSwitch: NSSwitch!
    private var logTextView: NSTextView!

    var onToggleDebugLogging: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onReloadConfig: (() -> Void)?
    var onOpenConfigFile: (() -> Void)?
    var onOpenPermissionSettings: (() -> Void)?
    var onClearLog: (() -> Void)?
    var onQuit: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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

        // Only relevant while the permission is actually lost; refresh()
        // toggles visibility next to the status line.
        permissionButton = NSButton(title: "屏幕录制权限设置", target: self, action: #selector(buttonClicked(_:)))
        permissionButton.bezelStyle = .rounded
        permissionButton.identifier = NSUserInterfaceItemIdentifier("permission")
        permissionButton.controlSize = .small
        permissionButton.isHidden = true

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
        let quitButton = button("退出", id: "quit")
        // Destructive action: own row, red label. Bordered push buttons
        // ignore contentTintColor for the title; an attributed title tints.
        quitButton.attributedTitle = NSAttributedString(
            string: "退出",
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

        // Status line with the permission-recovery button to its right,
        // shown only while the permission is lost
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(permissionButton)

        let buttons = NSStackView(views: [reloadButton, configButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(statusRow)
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
        case "permission": onOpenPermissionSettings?()
        case "clearLog": onClearLog?()
        case "quit": onQuit?()
        default: break
        }
    }

    /// Sync the panel with app state; call after any config/permission change.
    func refresh(permissionLost: Bool, pollInterval: Double, blacklistCount: Int,
                 version: String, debugEnabled: Bool, launchAtLogin: Bool?) {
        statusLabel.stringValue = permissionLost ? "⚠️ 屏幕录制权限已失效" : "● 运行中"
        statusLabel.textColor = permissionLost ? .systemRed : .systemGreen
        // The recovery button only exists while recovery is needed
        permissionButton.isHidden = !permissionLost
        infoLabel.stringValue = "间隔 \(pollInterval)s · 黑名单 \(blacklistCount) 项 · v\(version)"
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
    private var screenPermissionLost = false
    private var menuBarIcon: NSImage?
    private let ownPID = getpid()
    private var config = Config.load()
    private var blacklistMatcher = BlacklistMatcher(entries: [])
    private var timer: Timer?
    private var burstTimer: Timer?
    private var burstRemaining = 0
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

    func applicationDidFinishLaunching(_ n: Notification) {
        LogRedirector.shared.console = mainWC

        Config.ensureConfigFile()
        config = Config.load()
        blacklistMatcher = BlacklistMatcher(entries: config.blacklist)
        LogRedirector.shared.debugEnabled = config.debugLogging

        setupMenuBar()
        setupMainMenu()
        setupWorkspaceObservers()
        startTimer()
        watchConfig()

        // Window actions share the menu items' selectors so there is one
        // code path per action.
        mainWC.onToggleDebugLogging = { [weak self] in self?.toggleDebugLogging() }
        mainWC.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        mainWC.onReloadConfig = { [weak self] in self?.reloadConfig() }
        mainWC.onOpenConfigFile = { [weak self] in self?.openConfigFile() }
        mainWC.onOpenPermissionSettings = { [weak self] in self?.openScreenRecordingSettings() }
        mainWC.onClearLog = { [weak self] in self?.clearLog() }
        mainWC.onQuit = { [weak self] in self?.quitApp() }
        refreshMainStatus()

        tick() // immediate first check: surfaces a missing screen-recording permission right away
        showMainWindow()
        log("⚡️ SmartFocus 已启动")
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
        statusMenuItem = NSMenuItem(title: "✅ 运行中 | 间隔: \(config.pollInterval)s", action: nil, keyEquivalent: "")
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
        mainWC.refresh(permissionLost: screenPermissionLost,
                        pollInterval: config.pollInterval,
                        blacklistCount: config.blacklist.count,
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
        startTimer()
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

    /// Deep-link to the Screen Recording pane: the tool is dead without that
    /// permission, so recovery should be one click from the menu bar.
    @objc private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        if !NSWorkspace.shared.open(url) {
            log("⚠️ 无法打开系统设置的屏幕录制页", level: .error)
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateStatusText() {
        statusMenuItem.title = screenPermissionLost
            ? "⚠️ 屏幕录制权限已失效，焦点切换停摆"
            : "✅ 运行中 | 间隔: \(config.pollInterval)s | 黑名单: \(config.blacklist.count)项"
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer(timeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common mode keeps the fallback timer alive during menu tracking / window dragging
        RunLoop.main.add(timer!, forMode: .common)
        updateStatusText()
    }

    // MARK: - Event-driven focus correction
    /// Workspace events drive the real-time checks; the timer is only a fallback,
    /// so the polling interval can stay low-frequency without visible latency.
    private func setupWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        [NSWorkspace.didHideApplicationNotification,
         NSWorkspace.didDeactivateApplicationNotification,
         NSWorkspace.didTerminateApplicationNotification,
         NSWorkspace.didLaunchApplicationNotification,
         NSWorkspace.didActivateApplicationNotification,
         NSWorkspace.activeSpaceDidChangeNotification].forEach {
            nc.addObserver(self, selector: #selector(handleWorkspaceEvent(_:)), name: $0, object: nil)
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
            startBurst()
        case NSWorkspace.activeSpaceDidChangeNotification:
            // Space-switch animation rewrites the on-screen window list
            // wholesale while target windows have not landed yet; wait it out.
            interventionCooldownUntil = Date().addingTimeInterval(0.5)
            schedulePostCooldownCheck(after: 0.5)
            startBurst(initialDelay: 0.3)
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
            startBurst(initialDelay: delay)
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

    /// A single debounced check loses the race against close animations and
    /// delayed app termination. Instead, on any workspace event we open an
    /// 800ms high-frequency detection window (50ms x 16 ticks) that keeps
    /// watching until the window list settles; event storms (rapid Cmd+W)
    /// extend the window. Idle CPU cost stays at the fallback timer's level.
    private func startBurst(initialDelay: TimeInterval = 0) {
        burstRemaining = 16
        guard burstTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.tick()
            self.burstRemaining -= 1
            if self.burstRemaining <= 0 {
                t.invalidate()
                self.burstTimer = nil
            }
        }
        if initialDelay > 0 {
            timer.fireDate = Date().addingTimeInterval(initialDelay)
        }
        burstTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
            let cur = list.flatMap { self.firstUsable(in: $0, blacklist: blacklist) }
            let previousID = self.topID
            let previousStillOnScreen = list.map { self.contains($0, previousID) } ?? true
            // Screen-recording permission lost: the list still comes back, but
            // every owner name is stripped (system windows always carry names
            // when permission is granted, so all-empty cannot be a false alarm)
            let permissionLost = list.map { l in
                !l.isEmpty && l.allSatisfy { (($0[kCGWindowOwnerName as String] as? String) ?? "").isEmpty }
            } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                defer { self.isChecking = false }

                if permissionLost != self.screenPermissionLost {
                    self.setPermissionWarning(permissionLost)
                }

                guard let list = list else { return }
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

    /// Flip the menu bar into (out of) the permission-lost state; logs only on
    /// state transitions so bursts don't spam the console.
    private func setPermissionWarning(_ lost: Bool) {
        screenPermissionLost = lost
        if let button = statusItem.button {
            if lost {
                button.image = nil
                button.title = "⚠️"
            } else {
                button.title = ""
                button.image = menuBarIcon
            }
        }
        updateStatusText()
        refreshMainStatus()
        if lost {
            log("⚠️ 屏幕录制权限已失效，窗口名不可读，焦点切换已停摆。请到 系统设置 → 隐私与安全性 → 屏幕录制 重新授权", level: .error)
        } else {
            log("✅ 屏幕录制权限已恢复")
        }
    }

    private func snapshot() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    private func contains(_ list: [[String: Any]], _ id: CGWindowID) -> Bool {
        list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    private func firstUsable(in list: [[String: Any]], blacklist: BlacklistMatcher) -> (windowNumber: CGWindowID, pid: pid_t, name: String)? {
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let name = w[kCGWindowOwnerName as String] as? String, !name.isEmpty,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  !blacklist.matches(name: name, pid: pid),
                  // Skip tiny floating panels/widgets (BetterDisplay HUDs, status
                  // panels...): they are layer-0 windows but worthless as a
                  // focus-restore target — landing on one feels like nothing happened
                  let frame = w[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
                  frame.width >= 120, frame.height >= 120
            else { continue }
            return (id, pid, name)
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
// Regular app: Dock icon + main window (Spotlight/Dock reachable); the menu
// bar item stays as a secondary entry point for when the bar is visible.
app.setActivationPolicy(.regular)
app.run()