// AppState.swift — App-wide state management
//
// USB I/O runs entirely on a background queue. Only UI state updates
// dispatch to @MainActor. This prevents USB timeouts from blocking
// the main thread (which causes macOS rainbow spinner + keyboard freeze).

import AppKit
import Foundation
import Observation

// MARK: - Display Set

extension Notification.Name {
    static let deviceStateChanged = Notification.Name("deviceStateChanged")
}

enum DisplaySet: String, CaseIterable, Identifiable, Sendable {
    case systemMonitor = "System Monitor"

    var id: String { rawValue }
    var displayName: String { "系统监控" }
}

enum MiddleSlot: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case disk = "Disk"
    case network = "Network"
    case tokenUsage = "Token Usage"
    case keyStats = "KeyStats"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .disk: "磁盘"
        case .network: "网络"
        case .tokenUsage: "Token 用量"
        case .keyStats: "键鼠统计"
        }
    }
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {

    // Connection (UI-facing)
    var isConnected = false
    var deviceInfo: DeviceInfo?
    var statusMessage = "未连接"

    // Display
    var currentSet: DisplaySet = .systemMonitor
    var brightness: Int = 5
    var refreshInterval: Double = 0.5
    var rotateDisplay: Bool = false
    var middleLeft: MiddleSlot =
        MiddleSlot(rawValue: UserDefaults.standard.string(
            forKey: "middleLeftSlot") ?? "") ?? .codex
    var middleCenter: MiddleSlot =
        MiddleSlot(rawValue: UserDefaults.standard.string(
            forKey: "middleCenterSlot") ?? "") ?? .disk
    var middleRight: MiddleSlot =
        MiddleSlot(rawValue: UserDefaults.standard.string(
            forKey: "middleRightSlot") ?? "") ?? .network

    // Metrics (for menu bar display)
    var frameCount = 0
    var lastFrameSize = 0

    // MARK: - Internal

    private var engine: DisplayEngine?

    // MARK: - Lifecycle

    func start() {
        let eng = DisplayEngine { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                let prev = self.isConnected
                self.isConnected = status.connected
                self.deviceInfo = status.deviceInfo ?? self.deviceInfo
                self.statusMessage = status.message
                self.frameCount = status.frameCount
                self.lastFrameSize = status.lastFrameSize

                // Log state changes + post notification for UI refresh
                if status.connected != prev {
                    log("[*] LCD \(status.connected ? "connected" : "disconnected")")
                    NotificationCenter.default.post(name: .deviceStateChanged, object: nil)
                }
            }
        }
        engine = eng
        eng.start(set: currentSet, middleLeft: middleLeft,
                  middleCenter: middleCenter, middleRight: middleRight,
                  brightness: brightness,
                  interval: refreshInterval, rotate: rotateDisplay)
    }

    func stop() {
        engine?.stop()
        engine = nil
        isConnected = false
        statusMessage = "已停止"
    }

    func connect() {
        engine?.reconnect()
    }

    func disconnect() {
        engine?.stop()
        isConnected = false
        statusMessage = "未连接"
        frameCount = 0
    }

    /// Called when user changes display set, brightness, or interval
    func applySettings() {
        UserDefaults.standard.set(middleLeft.rawValue, forKey: "middleLeftSlot")
        UserDefaults.standard.set(middleCenter.rawValue, forKey: "middleCenterSlot")
        UserDefaults.standard.set(middleRight.rawValue, forKey: "middleRightSlot")
        engine?.updateSettings(set: currentSet, middleLeft: middleLeft,
                               middleCenter: middleCenter, middleRight: middleRight,
                               brightness: brightness, interval: refreshInterval,
                               rotate: rotateDisplay)
    }

    /// Latest rendered frame for the on-Mac preview window
    func currentFrame() -> CGImage? {
        engine?.currentFrame()
    }
}

// MARK: - Engine Status

struct EngineStatus: Sendable {
    let connected: Bool
    let deviceInfo: DeviceInfo?
    let message: String
    let frameCount: Int
    let lastFrameSize: Int
}

// MARK: - Display Engine (runs entirely off main thread)

final class DisplayEngine: @unchecked Sendable {

    private let statusCallback: @Sendable (EngineStatus) -> Void
    private let usbQueue = DispatchQueue(label: "com.thermalvision.usb")
    private var device: USBDevice?
    private var hotplug: USBHotplug?
    private var running = false
    private var frameCount = 0
    private var lastFrameSize = 0

    // Settings (atomically accessed)
    private var currentSet: DisplaySet = .systemMonitor
    private var middleLeft: MiddleSlot = .codex
    private var middleCenter: MiddleSlot = .disk
    private var middleRight: MiddleSlot = .network
    private var brightness: Int = 5
    private var interval: Double = 0.5
    private var rotateDisplay: Bool = false

    // Renderers
    private let monitorRenderer = MonitorRenderer()

    init(statusCallback: @escaping @Sendable (EngineStatus) -> Void) {
        self.statusCallback = statusCallback
    }

    func start(set: DisplaySet, middleLeft: MiddleSlot,
               middleCenter: MiddleSlot, middleRight: MiddleSlot,
               brightness: Int, interval: Double, rotate: Bool) {
        self.currentSet = set
        self.middleLeft = middleLeft
        self.middleCenter = middleCenter
        self.middleRight = middleRight
        self.brightness = brightness
        self.interval = interval
        self.rotateDisplay = rotate
        monitorRenderer.setMiddleSlots(
            left: middleLeft, center: middleCenter, right: middleRight)

        usbQueue.async { [weak self] in
            guard let self else { return }
            // Start background metrics collection (primes before returning)
            self.monitorRenderer.startMetrics()
            self.setupHotplug()
            self.connectAndRun()
        }
    }

    func stop() {
        running = false
        monitorRenderer.stopMetrics()
        usbQueue.async { [weak self] in
            self?.hotplug?.stop()
            self?.hotplug = nil
            self?.device?.close()
            self?.device = nil
        }
    }

    func reconnect() {
        usbQueue.async { [weak self] in
            self?.connectAndRun()
        }
    }

    /// Latest rendered frame for the on-Mac preview window (used while the LCD
    /// is disconnected). Thread-safe: render() serializes internally.
    func currentFrame() -> CGImage? {
        monitorRenderer.render()
    }

    func updateSettings(set: DisplaySet, middleLeft: MiddleSlot,
                        middleCenter: MiddleSlot, middleRight: MiddleSlot,
                        brightness: Int,
                        interval: Double, rotate: Bool) {
        log("[Engine] Settings updated: set=\(set.rawValue), middle=\(middleLeft.rawValue)+\(middleCenter.rawValue)+\(middleRight.rawValue), brightness=\(brightness), interval=\(interval), rotate=\(rotate)")
        self.currentSet = set
        self.middleLeft = middleLeft
        self.middleCenter = middleCenter
        self.middleRight = middleRight
        self.brightness = brightness
        self.interval = interval
        self.rotateDisplay = rotate
        monitorRenderer.setMiddleSlots(
            left: middleLeft, center: middleCenter, right: middleRight)
    }

    // MARK: - Private (all on usbQueue)

    private func connectAndRun() {
        guard !running else { return }

        // Ensure metrics collection is running (may have been stopped on disconnect/sleep)
        monitorRenderer.startMetrics()

        // Close existing connection
        device?.close()
        device = nil
        frameCount = 0

        postStatus(connected: false, message: "正在连接…")

        let dev = USBDevice()
        do {
            try dev.open()
        } catch USBError.deviceNotFound {
            postStatus(connected: false, message: "未找到设备")
            return
        } catch USBError.deviceBusy {
            postStatus(connected: false, message: "设备被占用（可能是 Chrome）")
            return
        } catch {
            postStatus(connected: false, message: "错误：\(error)")
            return
        }

        do {
            let info = try LYProtocol.handshake(device: dev)
            device = dev
            postStatus(connected: true, deviceInfo: info,
                       message: "已连接（\(info.width)×\(info.height)）")
            runFrameLoop(device: dev, info: info)
        } catch {
            dev.close()
            postStatus(connected: false, message: "握手失败")
        }
    }

    private func runFrameLoop(device: USBDevice, info: DeviceInfo) {
        running = true
        // Metrics already collecting in background via startMetrics()

        var nextDeadline = DispatchTime.now()

        while running {
            // Adaptive frame rate: the device sustains ~19fps, but the dashboard's
            // data only changes every ~2s. Run fast (15fps) ONLY while a column is
            // animating (agent working → breathing, or done → blinking); otherwise
            // idle at the configured interval to save CPU/power on this always-on app.
            let animating = (currentSet == .systemMonitor) && monitorRenderer.wantsHighFrameRate()
            let frameInterval = animating ? (1.0 / 15.0) : interval
            nextDeadline = nextDeadline + .milliseconds(Int(frameInterval * 1000))

            // autoreleasepool forces CG raster data / CGImage release each frame
            // Without this, Core Graphics caches hundreds of 3.6MB images → GB leak
            autoreleasepool {
                let set = currentSet
                let bright = brightness
                let rotate = rotateDisplay

                let jpeg: Data?

                switch set {
                case .systemMonitor:
                    if let image = monitorRenderer.render() {
                        jpeg = JPEGEncoder.encode(image, brightness: bright, rotate: rotate)
                    } else {
                        jpeg = nil
                    }
                }

                if let jpeg {
                    do {
                        try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                        frameCount += 1
                        lastFrameSize = jpeg.count
                        if frameCount == 1 {
                            log("[OK] Active! ~\(jpeg.count / 1024)KB/frame")
                        }
                        postStatus(connected: true, deviceInfo: nil,
                                   message: "运行中")
                    } catch {
                        log("[ERROR] Frame send failed: \(error)")
                        running = false
                        self.device?.close()
                        self.device = nil
                        postStatus(connected: false, message: "连接已断开（发送错误）")

                        log("[Engine] Will retry connection in 5s...")
                        Thread.sleep(forTimeInterval: 5)
                        connectAndRun()
                        return
                    }
                }
            }  // autoreleasepool

            // Sleep only the remaining time until next deadline
            // If work took longer than interval, send next frame immediately
            let now = DispatchTime.now()
            if nextDeadline > now {
                Thread.sleep(forTimeInterval: Double(nextDeadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
            } else {
                // Work exceeded interval — reset deadline to avoid cascading catch-up
                nextDeadline = now
            }
        }
    }

    private func setupHotplug() {
        let hp = USBHotplug()

        hp.onConnect = { [weak self] in
            guard let self else { return }
            self.usbQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.running else { return }
                log("[Hotplug] Attempting reconnect...")
                self.monitorRenderer.startMetrics()
                self.connectAndRun()
            }
        }

        hp.onDisconnect = { [weak self] in
            guard let self else { return }
            log("[Hotplug] Device removed")
            self.running = false
            // Metrics keep collecting — the on-Mac preview window takes over
            // rendering while the LCD is away
            self.usbQueue.async { [weak self] in
                self?.device?.close()
                self?.device = nil
                self?.postStatus(connected: false, message: "连接已断开（设备已拔出）")
            }
        }

        hp.start()
        hotplug = hp

        // Watch for macOS wake from sleep — USB needs reconnect after sleep
        // MUST register on main thread for NSWorkspace notifications to fire
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NSWorkspace.shared.notificationCenter

            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                log("[Wake] macOS woke from sleep — reconnecting in 3s...")
                self.usbQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.running = false
                    self.device?.close()
                    self.device = nil
                    log("[Wake] Attempting reconnect...")
                    self.connectAndRun()
                }
            }

            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if !self.running {
                    log("[Wake] Screens woke — reconnecting in 2s...")
                    self.usbQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, !self.running else { return }
                        self.connectAndRun()
                    }
                }
            }
        }
    }

    private func postStatus(
        connected: Bool, deviceInfo: DeviceInfo? = nil, message: String
    ) {
        let status = EngineStatus(
            connected: connected,
            deviceInfo: deviceInfo,
            message: message,
            frameCount: frameCount,
            lastFrameSize: lastFrameSize)
        statusCallback(status)
    }
}
