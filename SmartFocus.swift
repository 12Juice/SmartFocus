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
    static let defaultBlacklist: Set<String> = ["Finder", "Dock", "SystemUIServer", "WindowServer", "loginwindow"]

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

// MARK: - 控制台窗口管理器
class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "SmartFocus Console"
        window.minSize = NSSize(width: 400, height: 200)
        window.isReleasedWhenClosed = false 
        
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        scrollView = NSScrollView(frame: contentView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        
        textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width, .height]
        
        scrollView.documentView = textView
        contentView.addSubview(scrollView)
    }
    
    func appendLog(_ message: String, isError: Bool = false) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)\n"

        DispatchQueue.main.async { [weak self] in
            let attributes: [NSAttributedString.Key: Any] = isError ? [.foregroundColor: NSColor.systemRed] : [:]
            self?.textView.textStorage?.append(NSAttributedString(string: logLine, attributes: attributes))
            self?.textView.scrollRangeToVisible(NSRange(location: self?.textView.string.count ?? 0, length: 0))
        }
    }
    
    func clearLog() {
        DispatchQueue.main.async { [weak self] in
            self?.textView.string = ""
        }
    }
}

// MARK: - 日志重定向器
class LogRedirector {
    static let shared = LogRedirector()
    var console: ConsoleWindowController?
    var debugEnabled = false

    func write(_ string: String, level: LogLevel) {
        guard level == .error || debugEnabled else { return }
        // 保持 stderr 输出，确保 Xcode / 终端调试器可见
        fputs(string, stderr)
        // 同步更新到 App UI 控制台
        console?.appendLog(string.trimmingCharacters(in: .newlines), isError: level == .error)
    }
}

// MARK: - 菜单栏应用主体
class SmartFocusApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var consoleWC = ConsoleWindowController()
    
    private var topID: CGWindowID = 0
    private var screenPermissionLost = false
    private var menuBarIcon: NSImage?
    private let ownPID = getpid()
    private var config = Config.load()
    private var timer: Timer?
    private var burstTimer: Timer?
    private var burstRemaining = 0
    private var isChecking = false
    private let checkQueue = DispatchQueue(label: "com.baikong.smartfocus.check", qos: .userInteractive)
    private var configWatcher: DispatchSourceFileSystemObject?
    private var statusMenuItem: NSMenuItem!
    private var debugLogMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        LogRedirector.shared.console = consoleWC
        
        Config.ensureConfigFile()
        config = Config.load()
        LogRedirector.shared.debugEnabled = config.debugLogging
        
        setupMenuBar()
        setupWorkspaceObservers()
        startTimer()
        watchConfig()
        tick() // immediate first check: surfaces a missing screen-recording permission right away
        log("⚡️ SmartFocus 已启动，控制台就绪")
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
        menu.addItem(NSMenuItem(title: "🖥️ 打开控制台", action: #selector(showConsole), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "🗑️ 清空控制台", action: #selector(clearConsole), keyEquivalent: "k"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "🔄 重载配置", action: #selector(reloadConfig), keyEquivalent: "r"))
        debugLogMenuItem = NSMenuItem(title: "🐞 调试日志", action: #selector(toggleDebugLogging), keyEquivalent: "d")
        debugLogMenuItem.state = config.debugLogging ? .on : .off
        menu.addItem(debugLogMenuItem)
        launchAtLoginMenuItem = NSMenuItem(title: "🚀 开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "l")
        menu.addItem(launchAtLoginMenuItem)
        updateLaunchAtLoginState()
        menu.addItem(NSMenuItem(title: "📝 打开配置文件", action: #selector(openConfigFile), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "❌ 退出 SmartFocus", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc private func showConsole() {
        consoleWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func clearConsole() {
        consoleWC.clearLog()
        log("🗑️ 控制台已清空")
    }
    
    @objc private func reloadConfig() {
        applyConfig()
        log("🔄 手动重载配置成功 | 黑名单: \(config.blacklist.count)项")
    }

    @objc private func toggleDebugLogging() {
        config.debugLogging.toggle()
        persistConfig()
        applyDebugState()
        log("🐞 调试日志已\(config.debugLogging ? "开启" : "关闭")")
    }

    /// (Re)load config from disk and propagate it to the timer / debug state / menu
    private func applyConfig() {
        config = Config.load()
        startTimer()
        applyDebugState()
    }

    private func applyDebugState() {
        LogRedirector.shared.debugEnabled = config.debugLogging
        debugLogMenuItem?.state = config.debugLogging ? .on : .off
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
        guard #available(macOS 13.0, *) else {
            launchAtLoginMenuItem.isHidden = true
            return
        }
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func persistConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            do {
                try data.write(to: Config.configURL)
            } catch {
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
         NSWorkspace.didTerminateApplicationNotification].forEach {
            nc.addObserver(self, selector: #selector(handleWorkspaceEvent(_:)), name: $0, object: nil)
        }
    }

    @objc private func handleWorkspaceEvent(_ note: Notification) {
        // didDeactivate fires on every ordinary app switch; a short delay lets the
        // system's own focus settling finish first. It can stay short because the
        // "accept the system's fallback" check inside tick prevents fighting it.
        let delay: TimeInterval = note.name == NSWorkspace.didDeactivateApplicationNotification ? 0.05 : 0
        startBurst(initialDelay: delay)
    }

    /// A single debounced check loses the race against close animations and
    /// delayed app termination. Instead, on any workspace event we open a
    /// 500ms high-frequency detection window (50ms x 10 ticks) that keeps
    /// watching until the window list settles; event storms (rapid Cmd+W)
    /// extend the window. Idle CPU cost stays at the fallback timer's level.
    private func startBurst(initialDelay: TimeInterval = 0) {
        burstRemaining = 10
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
            self.applyConfig()
            log("🔄 自动检测到配置变更并已应用")
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
        let blacklist = config.blacklist // value copy, safe to read off-main
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
                defer { self.topID = nextID }

                guard previousID != 0, !previousStillOnScreen else { return }

                // The tracked window just disappeared (close event)
                if self.systemSettledOnUsableApp(blacklist: blacklist, windowList: list) {
                    log("✅ 系统已自行回落焦点，跳过干预")
                    return
                }
                if let info = cur {
                    self.doFocus(info)
                    log("🎯 焦点切换 -> \(info.name) (PID: \(info.pid))")
                }
            }
        }
    }

    /// True when the system's own focus fallback landed on an app we consider
    /// usable: not us, not blacklisted, AND it still owns a visible window.
    /// The window check is essential — apps like Chrome/VS Code stay frontmost
    /// with zero windows after their last window closes, which is exactly the
    /// focus vacuum this tool exists to fix.
    private func systemSettledOnUsableApp(blacklist: Set<String>, windowList: [[String: Any]]) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ownPID,
              let name = front.localizedName,
              !blacklist.contains(name),
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

    private func firstUsable(in list: [[String: Any]], blacklist: Set<String>) -> (windowNumber: CGWindowID, pid: pid_t, name: String)? {
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let name = w[kCGWindowOwnerName as String] as? String, !name.isEmpty,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  !blacklist.contains(name)
            else { continue }
            return (id, pid, name)
        }
        return nil
    }

    private func doFocus(_ info: (windowNumber: CGWindowID, pid: pid_t, name: String)) {
        guard let app = NSRunningApplication(processIdentifier: info.pid) else { return }
        // Before macOS 14, a bare activate() often lost to the system's own focus
        // fallback (visible double-switches); macOS 14+ deprecated the flag and
        // changed activate() semantics, where it has no effect anyway.
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

// MARK: - 启动入口
let app = NSApplication.shared
let delegate = SmartFocusApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()