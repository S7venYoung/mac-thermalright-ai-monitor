// MonitorRenderer.swift — System Monitor 3-panel dashboard
//
// Set 1: CPU | AI AGENTS (triple width) | MEMORY
// The AGENTS panel shows each agent's current activity (top) and today's
// token usage + quota (bottom), sourced from local session transcripts.

import AppKit
import CoreGraphics
import Foundation

final class MonitorRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = SystemMetricsCollector()
    private let agentCollector = AgentUsageCollector()
    private let keyStatsReader = KeyStatsReader()
    private let weatherCollector = WeatherCollector()
    private let calendarCollector = CalendarCollector()
    private let jdStatsCollector = JDStatsCollector()
    private let mihomoCollector = MihomoCollector()
    private let codexTokenCollector = CodexTokenCollector()

    // Background metrics collection — decoupled from frame loop for consistent refresh
    private let metricsQueue = DispatchQueue(label: "com.thermalvision.metrics")
    private var metricsRunning = false
    private let lock = NSLock()

    // Cached snapshots (written by metricsQueue, read by render thread)
    private var _cpu: CPUSnapshot?
    private var _mem: MemorySnapshot?
    private var _temp: TemperatureSnapshot?
    private var _agents: AgentsSnapshot?
    private var _sys: SystemSnapshot?
    private var _disk: DiskSnapshot?
    private var _diskIO: DiskIOSnapshot?
    private var _network: NetworkSnapshot?
    private var _keyStats: KeyStatsSnapshot?
    private var _weather: WeatherSnapshot?
    private var _calendar: CalendarSnapshot = .empty
    private var _jdStats: JDStatsSnapshot = .unavailable
    private var _mihomo: MihomoSnapshot = .unavailable
    private var _codexToken: CodexTokenSnapshot = .loading
    private var weatherRefreshRequested = true
    private var calendarRefreshRequested = true
    private var jdStatsRefreshRequested = true
    private var mihomoRefreshRequested = true

    // User-selected fixed middle panel
    private let panelLock = NSLock()
    private var displayTheme: DisplayTheme = .classic
    private var middleLeft: MiddleSlot = .codex
    private var middleCenter: MiddleSlot = .disk
    private var middleRight: MiddleSlot = .network
    private var middleLeftCarousel = false
    private var middleCenterCarousel = false
    private var middleRightCarousel = false
    private var middleLeftRotation: Set<MiddleSlot> = [.codex, .disk]
    private var middleCenterRotation: Set<MiddleSlot> = [
        .disk, .weather, .calendar,
    ]
    private var middleRightRotation: Set<MiddleSlot> = [.network, .keyStats]
    private var middleCarouselInterval: Double = 15
    private var appleWatchModules: [AppleWatchModule] = [
        .token, .jdAlliance, .calendar, .weather, .network, .clock,
    ]
    private var appleWatchCarousels = Array(
        repeating: false, count: AppleWatchPosition.allCases.count)
    private var appleWatchRotations: [Set<AppleWatchModule>] = [
        [.token], [.jdAlliance], [.calendar],
        [.weather], [.network], [.clock],
    ]
    private var weatherCity = "上海"
    private var caiyunToken = ""
    private var weatherLongitude = 121.4737
    private var weatherLatitude = 31.2304
    private var calendarSubscriptionURL = ""
    private var jdStatsURL = ""
    private var jdStatsToken = ""
    private var mihomoURL = "http://192.168.5.25:9091"
    private var mihomoSecret = ""

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?
    private var memoryNetworkDownload: [Double] = []
    private var memoryNetworkUpload: [Double] = []

    // Test mode (--test-flash): force both columns into the flashing state until
    // this deadline, to preview the alert visuals without waiting for a real event
    private var testFlashUntil: Date?

    func enableTestFlash(seconds: TimeInterval) {
        testFlashUntil = Date().addingTimeInterval(seconds)
        log("[Metrics] Test flash enabled for \(Int(seconds))s")
    }

    private func withAttention(_ u: AgentUsage) -> AgentUsage {
        AgentUsage(available: u.available,
                   todayInputTokens: u.todayInputTokens,
                   todayOutputTokens: u.todayOutputTokens,
                   secondsSinceActive: u.secondsSinceActive,
                   project: u.project, activity: u.activity,
                   quotaUsedPercent: u.quotaUsedPercent,
                   quotaResetsAt: u.quotaResetsAt,
                   needsAttention: true)
    }

    /// Start background metrics collection. Call before first render().
    /// Primes all metrics synchronously, then starts async collection loop.
    /// Safe to call multiple times — returns immediately if already running.
    func startMetrics() {
        lock.lock()
        guard !metricsRunning else { lock.unlock(); return }
        metricsRunning = true
        lock.unlock()
        log("[Metrics] Starting collection...")
        // First pass: prime CPU ticks (deltas will be zero)
        let cpu0 = collector.collectCPU()
        let mem = collector.collectMemory()
        let temp = collector.collectTemperature()
        let agents = agentCollector.collect()
        let sys = collector.collectSystem()
        let disk = collector.collectDisk()
        let diskIO = collector.collectDiskIO()
        let network = collector.collectNetwork()
        let keyStats = keyStatsReader.collect()
        lock.lock()
        _cpu = cpu0; _mem = mem
        _temp = temp; _agents = agents; _sys = sys
        _disk = disk; _diskIO = diskIO; _network = network
        _keyStats = keyStats
        lock.unlock()

        // Second pass: get real CPU deltas
        Thread.sleep(forTimeInterval: 0.3)
        let cpu1 = collector.collectCPU()
        lock.lock()
        _cpu = cpu1
        lock.unlock()

        // Start async collection loop
        metricsQueue.async { [weak self] in self?.metricsLoop() }
    }

    func stopMetrics() {
        log("[Metrics] Stopping collection")
        metricsRunning = false
        codexTokenCollector.stop()
    }

    func setMiddleSlots(
        left: MiddleSlot, center: MiddleSlot, right: MiddleSlot,
        leftCarousel: Bool = false, centerCarousel: Bool = false,
        rightCarousel: Bool = false,
        leftRotation: Set<MiddleSlot> = [.codex, .disk],
        centerRotation: Set<MiddleSlot> = [.disk, .weather, .calendar],
        rightRotation: Set<MiddleSlot> = [.network, .keyStats],
        carouselInterval: Double = 15
    ) {
        panelLock.lock()
        middleLeft = left
        middleCenter = center
        middleRight = right
        middleLeftCarousel = leftCarousel
        middleCenterCarousel = centerCarousel
        middleRightCarousel = rightCarousel
        middleLeftRotation = leftRotation
        middleCenterRotation = centerRotation
        middleRightRotation = rightRotation
        middleCarouselInterval = max(5, carouselInterval)
        panelLock.unlock()
    }

    func setDisplayTheme(_ theme: DisplayTheme) {
        panelLock.lock()
        displayTheme = theme
        panelLock.unlock()
    }

    func setAppleWatchLayout(
        modules: [AppleWatchModule], carousels: [Bool],
        rotations: [Set<AppleWatchModule>], carouselInterval: Double
    ) {
        panelLock.lock()
        if modules.count == AppleWatchPosition.allCases.count {
            appleWatchModules = modules
        }
        if carousels.count == AppleWatchPosition.allCases.count {
            appleWatchCarousels = carousels
        }
        if rotations.count == AppleWatchPosition.allCases.count {
            appleWatchRotations = rotations
        }
        middleCarouselInterval = max(5, carouselInterval)
        panelLock.unlock()
    }

    private func selectedAppleWatchModules() -> [AppleWatchModule] {
        panelLock.lock()
        defer { panelLock.unlock() }
        return AppleWatchPosition.allCases.map { position in
            let index = position.rawValue
            guard appleWatchCarousels[index] else {
                return appleWatchModules[index]
            }
            let choices = AppleWatchModule.allCases.filter(
                appleWatchRotations[index].contains)
            guard !choices.isEmpty else { return appleWatchModules[index] }
            let step = Int(Date().timeIntervalSince1970 / middleCarouselInterval)
            return choices[(step + index) % choices.count]
        }
    }

    private func selectedDisplayTheme() -> DisplayTheme {
        panelLock.lock()
        defer { panelLock.unlock() }
        return displayTheme
    }

    func setWeatherConfig(
        city: String, token: String, longitude: Double, latitude: Double
    ) {
        panelLock.lock()
        weatherCity = city
        caiyunToken = token
        weatherLongitude = longitude
        weatherLatitude = latitude
        panelLock.unlock()
        lock.lock()
        _weather = nil
        weatherRefreshRequested = true
        lock.unlock()
    }

    func setCalendarSubscription(urlString: String) {
        panelLock.lock()
        calendarSubscriptionURL = urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panelLock.unlock()
        lock.lock()
        _calendar = .empty
        calendarRefreshRequested = true
        lock.unlock()
    }

    func setJDStatsConfig(urlString: String, token: String) {
        panelLock.lock()
        jdStatsURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        jdStatsToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        panelLock.unlock()
        jdStatsCollector.invalidate()
        lock.lock()
        _jdStats = .unavailable
        jdStatsRefreshRequested = true
        lock.unlock()
    }

    func setMihomoConfig(urlString: String, secret: String) {
        panelLock.lock()
        mihomoURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        mihomoSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        panelLock.unlock()
        lock.lock()
        _mihomo = .unavailable
        mihomoRefreshRequested = true
        lock.unlock()
    }

    private func selectedMihomoConfig() -> (url: String, secret: String) {
        panelLock.lock()
        defer { panelLock.unlock() }
        return (mihomoURL, mihomoSecret)
    }

    private func currentMihomoSnapshot() -> MihomoSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return _mihomo
    }

    private func selectedMiddleSlots() -> (MiddleSlot, MiddleSlot, MiddleSlot) {
        panelLock.lock()
        defer { panelLock.unlock() }
        let step = Int(Date().timeIntervalSince1970 / middleCarouselInterval)
        func slot(
            _ fixed: MiddleSlot, enabled: Bool, choices: Set<MiddleSlot>
        ) -> MiddleSlot {
            guard enabled else { return fixed }
            let ordered = MiddleSlot.allCases.filter(choices.contains)
            guard !ordered.isEmpty else { return fixed }
            return ordered[step % ordered.count]
        }
        return (
            slot(
                middleLeft, enabled: middleLeftCarousel,
                choices: middleLeftRotation),
            slot(
                middleCenter, enabled: middleCenterCarousel,
                choices: middleCenterRotation),
            slot(
                middleRight, enabled: middleRightCarousel,
                choices: middleRightRotation))
    }

    private func selectedCalendarURL() -> String {
        panelLock.lock()
        defer { panelLock.unlock() }
        return calendarSubscriptionURL
    }

    private func selectedWeatherConfig() -> (
        city: String, token: String, longitude: Double, latitude: Double
    ) {
        panelLock.lock()
        defer { panelLock.unlock() }
        return (
            weatherCity, caiyunToken, weatherLongitude, weatherLatitude)
    }

    private func selectedJDStatsConfig() -> (url: String, token: String) {
        panelLock.lock()
        defer { panelLock.unlock() }
        return (jdStatsURL, jdStatsToken)
    }

    private func isWeatherVisible() -> Bool {
        let slots = selectedMiddleSlots()
        return slots.0 == .weather
            || slots.1 == .weather
            || slots.2 == .weather
    }

    /// True when a column has a live animation (breathing while working, or the
    /// done/waiting blink) — the frame loop uses this to raise the LCD frame rate
    /// only while something is actually moving, and idle low otherwise.
    func wantsHighFrameRate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Heavy CPU → Pikachu crackles with electricity, worth animating smoothly
        if let c = _cpu, c.total > 55 { return true }
        guard let a = _agents else { return false }
        let slots = selectedMiddleSlots()
        let codexVisible =
            slots.0 == .codex || slots.1 == .codex || slots.2 == .codex
        let claudeVisible =
            slots.0 == .claude || slots.1 == .claude || slots.2 == .claude
        return (codexVisible && (a.codex.isWorking || a.codex.needsAttention))
            || (claudeVisible && (a.claude.isWorking || a.claude.needsAttention))
    }

    private func metricsLoop() {
        log("[Metrics] Loop started on metricsQueue")
        var slowTick = 0
        var weatherTick = 1200
        var calendarTick = 7200
        var jdStatsTick = 600
        var mihomoTick = 20
        while metricsRunning {
            codexTokenCollector.refreshIfNeeded { [weak self] snapshot in
                guard let self else { return }
                self.lock.lock()
                self._codexToken = snapshot
                self.lock.unlock()
            }

            // Fast metrics every tick
            let cpu = collector.collectCPU()
            let mem = collector.collectMemory()
            let keyStats = keyStatsReader.collect()
            lock.lock()
            _cpu = cpu; _mem = mem; _keyStats = keyStats
            lock.unlock()

            // Slow metrics every 4th tick (~2s)
            slowTick += 1
            if slowTick >= 4 {
                let temp = collector.collectTemperature()
                let agents = agentCollector.collect()
                let disk = collector.collectDisk()
                let diskIO = collector.collectDiskIO()
                let network = collector.collectNetwork()
                let sys = collector.collectSystem()
                lock.lock()
                _temp = temp; _agents = agents; _sys = sys
                _disk = disk; _diskIO = diskIO; _network = network
                lock.unlock()
                slowTick = 0
            }

            weatherTick += 1
            lock.lock()
            let refreshWeather = weatherRefreshRequested
            lock.unlock()
            if isWeatherVisible(),
               weatherTick >= 1200 || refreshWeather {
                let config = selectedWeatherConfig()
                let weather = weatherCollector.collect(
                    token: config.token, longitude: config.longitude,
                    latitude: config.latitude, city: config.city)
                lock.lock()
                _weather = weather
                weatherRefreshRequested = false
                lock.unlock()
                weatherTick = 0
            }

            calendarTick += 1
            lock.lock()
            let refreshCalendar = calendarRefreshRequested
            lock.unlock()
            let visibleSlots = selectedMiddleSlots()
            let calendarVisible = visibleSlots.0 == .calendar
                || visibleSlots.1 == .calendar
                || visibleSlots.2 == .calendar
            if calendarVisible,
               calendarTick >= 7200 || refreshCalendar {
                let snapshot = calendarCollector.collect(
                    urlString: selectedCalendarURL())
                lock.lock()
                _calendar = snapshot
                calendarRefreshRequested = false
                lock.unlock()
                calendarTick = 0
            }

            jdStatsTick += 1
            lock.lock()
            let refreshJDStats = jdStatsRefreshRequested
            lock.unlock()
            let jdStatsVisible = visibleSlots.0 == .jdAlliance
                || visibleSlots.1 == .jdAlliance
                || visibleSlots.2 == .jdAlliance
            if jdStatsVisible,
               jdStatsTick >= 600 || refreshJDStats {
                let config = selectedJDStatsConfig()
                let snapshot = jdStatsCollector.collect(
                    urlString: config.url, token: config.token)
                lock.lock()
                _jdStats = snapshot
                jdStatsRefreshRequested = false
                lock.unlock()
                jdStatsTick = 0
            }

            mihomoTick += 1
            lock.lock()
            let refreshMihomo = mihomoRefreshRequested
            lock.unlock()
            if mihomoTick >= 20 || refreshMihomo {
                let config = selectedMihomoConfig()
                let snapshot = mihomoCollector.collect(
                    baseURL: config.url, secret: config.secret)
                lock.lock()
                _mihomo = snapshot
                mihomoRefreshRequested = false
                lock.unlock()
                mihomoTick = 0
            }

            Thread.sleep(forTimeInterval: 0.5)
        }
        log("[Metrics] Loop exited (metricsRunning=false)")
    }

    // Demo mode: drive the display with polished fake data (for screenshots / photos
    // and open-source showcase). Set before render(); the frame loop keeps its normal
    // memory-safe path (reusable context + autoreleasepool) and animations stay live.
    var demoMode = false

    /// Deterministic showcase data. CPU cores gently wave over time so the demo looks
    /// alive on the LCD; everything else is fixed so it reads clearly in a photo.
    private func demoData() -> (CPUSnapshot, MemorySnapshot, TemperatureSnapshot,
                                SystemSnapshot, AgentsSnapshot,
                                DiskSnapshot, DiskIOSnapshot, NetworkSnapshot,
                                TokenUsageSnapshot) {
        let tt = Date().timeIntervalSince1970
        let cores: [Double] = (0..<10).map { i in
            let wave: Double = sin(tt * 1.3 + Double(i) * 0.9)
            return 25.0 + 55.0 * (0.5 + 0.5 * wave)
        }
        let total: Double = cores.reduce(0.0, +) / 10.0
        let cpu = CPUSnapshot(perCore: cores, total: total,
                              loadAvg: (3.5, 4.2, 3.8), pCoreCount: 8)
        let gb: UInt64 = 1024 * 1024 * 1024
        let mem = MemorySnapshot(
            total: 32 * gb, active: 9 * gb, wired: 3 * gb,
            compressed: 2 * gb, available: 18 * gb,
            swapUsed: 512 * 1024 * 1024, swapTotal: 4 * gb,
            swapInPerSec: 0, swapOutPerSec: 0, swapAvailable: true, pressure: 1)
        let temp = TemperatureSnapshot(cpuTemp: 52, gpuTemp: 45, thermalState: 0)
        let sys = SystemSnapshot(uptimeSeconds: 27 * 3600 + 3 * 60, processCount: 612)
        let agents = AgentsSnapshot(
            claude: AgentUsage(available: true,
                               todayInputTokens: 48_300_000, todayOutputTokens: 512_000,
                               secondsSinceActive: 3, project: "MacTR",
                               activity: """
                               已完成 AI Agents 面板的三项优化，改动集中在两个文件：

                               | 文件 | 改动 |
                               |---|---|
                               | Collector | 解析消息与待办 |
                               | Renderer | 表格化排版 |
                               """,
                               isWorking: true,
                               stepCurrent: 3, stepTotal: 4,
                               stepText: "渲染 Claude 消息表格"),
            codex: AgentUsage(available: true,
                              todayInputTokens: 60_100_000, todayOutputTokens: 375_000,
                              secondsSinceActive: 6, project: "web-service",
                              activity: """
                              已完成部署，四个服务全部推送到 `main`：

                              | 服务 | 提交 | 文件 |
                              |---|---|---:|
                              | `api-gateway` | `a4872c56` | 24 |
                              | `auth-service` | `4d6934de` | 10 |
                              | `web-client` | `9b0e17aa` | 32 |
                              | `job-worker` | `ac02bea6` | 88 |
                              """,
                              quotaUsedPercent: 57,
                              quotaResetsAt: Date().addingTimeInterval(3600 * 24 * 6),
                              isWorking: true,
                              stepCurrent: 4, stepTotal: 6,
                              stepText: "部署到预发环境并跑冒烟测试"))
        let disk = DiskSnapshot(totalGB: 512, usedGB: 256, freeGB: 256)
        let diskIO = DiskIOSnapshot(readBytesPerSec: 125_829_120, writeBytesPerSec: 83_886_080)
        let network = NetworkSnapshot(rxBytesPerSec: 15_728_640, txBytesPerSec: 3_932_160)
        let tokenEntry = TokenUsageEntry(
            model: "deepseek-v4-flash-free", provider: "opencode", client: "opencode",
            input: 69_297, output: 10_016, cacheRead: 2_598_656,
            cacheWrite: 0, reasoning: 11_895, messageCount: 53, cost: 0.0)
        let tokenUsage = TokenUsageSnapshot(
            entries: [tokenEntry],
            totalInput: 69_297, totalOutput: 10_016,
            totalCacheRead: 2_598_656, totalCacheWrite: 0,
            totalMessages: 53, totalCost: 0.0, processingTimeMs: 1925)
        return (cpu, mem, temp, sys, agents, disk, diskIO, network, tokenUsage)
    }

    /// Render one demo frame with the showcase data (for --snapshot).
    func renderSimulated(coreCount: Int) -> CGImage? {
        let (cpu, mem, temp, sys, agents, disk, diskIO, network, tokenUsage) = demoData()
        let w = Layout.width, h = Layout.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let slots = selectedMiddleSlots()
        if selectedDisplayTheme() == .appleWatch {
            renderAppleWatchTheme(
                ctx, slots: slots, cpu: cpu, mem: mem, temp: temp, sys: sys,
                agents: agents, disk: disk, diskIO: diskIO, network: network,
                tokenUsage: tokenUsage, keyStats: .demo, weather: .unavailable,
                calendarSnapshot: .empty, jdStats: .unavailable,
                codexToken: .demo)
        } else {
            Draw.gradientBackground(ctx)
            renderCPU(ctx, cpu: cpu, temp: temp, agentsBusy: true)
            renderMiddleSlots(ctx, left: slots.0, center: slots.1,
                              right: slots.2, agents: agents,
                              disk: disk, diskIO: diskIO, network: network,
                              tokenUsage: tokenUsage, keyStats: .demo,
                              weather: .unavailable, jdStats: .unavailable,
                              codexToken: .demo)
            renderMemory(ctx, mem: mem, sys: sys, network: network, agentsBusy: true)
        }
        return ctx.makeImage()
    }

    // Serializes render() callers — the USB frame loop and the on-Mac preview
    // window can both render around a connect/disconnect transition, and they
    // share reusableCtx + sparkline history
    private let renderMutex = NSLock()

    func render() -> CGImage? {
        renderMutex.lock()
        defer { renderMutex.unlock() }

        let cpu: CPUSnapshot, mem: MemorySnapshot, temp: TemperatureSnapshot
        let sys: SystemSnapshot?
        var agents: AgentsSnapshot
        let disk: DiskSnapshot, diskIO: DiskIOSnapshot, network: NetworkSnapshot
        let tokenUsage: TokenUsageSnapshot
        let keyStats: KeyStatsSnapshot
        let weather: WeatherSnapshot
        let calendarSnapshot: CalendarSnapshot
        let jdStats: JDStatsSnapshot
        let codexToken: CodexTokenSnapshot
        if demoMode {
            (cpu, mem, temp, sys, agents, disk, diskIO, network, tokenUsage) = demoData()
            keyStats = .demo
            weather = .unavailable
            calendarSnapshot = .empty
            jdStats = .unavailable
            codexToken = .demo
        } else {
            // Read cached metrics (never blocks — uses latest available values)
            lock.lock()
            guard let c = _cpu, let m = _mem, let tp = _temp, let a = _agents else {
                lock.unlock(); return nil
            }
            cpu = c; mem = m; temp = tp; agents = a; sys = _sys
            disk = _disk ?? DiskSnapshot(totalGB: 0, usedGB: 0, freeGB: 0)
            diskIO = _diskIO ?? DiskIOSnapshot(readBytesPerSec: 0, writeBytesPerSec: 0)
            network = _network ?? NetworkSnapshot(rxBytesPerSec: 0, txBytesPerSec: 0)
            tokenUsage = TokenUsageSnapshot(
                entries: [], totalInput: 0, totalOutput: 0,
                totalCacheRead: 0, totalCacheWrite: 0,
                totalMessages: 0, totalCost: 0, processingTimeMs: 0)
            keyStats = _keyStats ?? .unavailable
            weather = _weather ?? .unavailable
            calendarSnapshot = _calendar
            jdStats = _jdStats
            codexToken = _codexToken
            lock.unlock()
        }

        if let until = testFlashUntil, Date() < until {
            agents = AgentsSnapshot(claude: withAttention(agents.claude),
                                    codex: withAttention(agents.codex))
        }

        // Reuse CGContext to prevent CG raster data memory growth
        let w = Layout.width
        let h = Layout.height
        if reusableCtx == nil {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            reusableCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = reusableCtx else { return nil }

        // The frame is already rendered at the LCD's native 1920x480 size.
        // Avoid implicit filtering so integer-aligned text and borders remain
        // crisp when the bitmap is handed to the JPEG encoder.
        ctx.interpolationQuality = .none

        // Reset transform and clear for new frame
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let slots = selectedMiddleSlots()
        let codexVisible =
            slots.0 == .codex || slots.1 == .codex || slots.2 == .codex
        let claudeVisible =
            slots.0 == .claude || slots.1 == .claude || slots.2 == .claude
        let agentsBusy =
            (codexVisible && (agents.codex.isWorking || agents.codex.needsAttention))
            || (claudeVisible && (agents.claude.isWorking || agents.claude.needsAttention))
        if selectedDisplayTheme() == .appleWatch {
            renderAppleWatchTheme(
                ctx, slots: slots, cpu: cpu, mem: mem, temp: temp, sys: sys,
                agents: agents, disk: disk, diskIO: diskIO, network: network,
                tokenUsage: tokenUsage, keyStats: keyStats, weather: weather,
                calendarSnapshot: calendarSnapshot, jdStats: jdStats,
                codexToken: codexToken)
        } else {
            Draw.gradientBackground(ctx)
            renderCPU(ctx, cpu: cpu, temp: temp, agentsBusy: agentsBusy)
            renderMiddleSlots(ctx, left: slots.0, center: slots.1,
                              right: slots.2, agents: agents,
                              disk: disk, diskIO: diskIO, network: network,
                              tokenUsage: tokenUsage, keyStats: keyStats,
                              weather: weather, calendarSnapshot: calendarSnapshot,
                              jdStats: jdStats, codexToken: codexToken)
            renderMemory(ctx, mem: mem, sys: sys, network: network, agentsBusy: agentsBusy)
        }

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    private func renderAppleWatchTheme(
        _ ctx: CGContext, slots: (MiddleSlot, MiddleSlot, MiddleSlot),
        cpu: CPUSnapshot, mem: MemorySnapshot, temp: TemperatureSnapshot,
        sys: SystemSnapshot?, agents: AgentsSnapshot, disk: DiskSnapshot,
        diskIO: DiskIOSnapshot, network: NetworkSnapshot,
        tokenUsage: TokenUsageSnapshot, keyStats: KeyStatsSnapshot,
        weather: WeatherSnapshot, calendarSnapshot: CalendarSnapshot,
        jdStats: JDStatsSnapshot, codexToken: CodexTokenSnapshot
    ) {
        let modules = selectedAppleWatchModules()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height))

        let py = 14
        let ph = 452
        let systemX = 14
        let systemW = 344
        let heroX = 372
        let heroW = 716
        let dashboardX = 1106
        let dashboardW = 800

        drawAppleWatchSection(
            ctx, x: systemX, y: py, w: systemW, h: ph)
        renderAppleWatchSystem(
            ctx, x: systemX, w: systemW, py: py,
            cpu: cpu, mem: mem, temp: temp)

        renderAppleWatchHero(
            ctx, module: modules[0], x: heroX, w: heroW, py: py, ph: ph,
            agents: agents, disk: disk, diskIO: diskIO, network: network,
            keyStats: keyStats, weather: weather,
            calendarSnapshot: calendarSnapshot, jdStats: jdStats,
            codexToken: codexToken)
        renderAppleWatchDashboard(
            ctx, x: dashboardX, w: dashboardW, py: py, ph: ph,
            modules: Array(modules[1...5]), agents: agents,
            disk: disk, diskIO: diskIO, keyStats: keyStats,
            jdStats: jdStats, calendarSnapshot: calendarSnapshot,
            weather: weather, network: network)

        if let sys {
            let hours = sys.uptimeSeconds / 3600
            let uptime = hours >= 24
                ? "\(hours / 24)d \(hours % 24)h"
                : "\(hours)h \((sys.uptimeSeconds % 3600) / 60)m"
            drawRightAligned(
                ctx, uptime, rightX: systemX + systemW - 20,
                y: py + ph - 31, font: Fonts.system(14), color: Color.textL)
        }
    }

    private func drawAppleWatchSection(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int
    ) {
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path = CGPath(
            roundedRect: rect, cornerWidth: 36, cornerHeight: 36,
            transform: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(
            red: 44/255, green: 44/255, blue: 46/255, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func renderAppleWatchComplication(
        _ ctx: CGContext, slot: MiddleSlot, panelX: Int, panelW: Int,
        py: Int, ph: Int, agents: AgentsSnapshot, disk: DiskSnapshot,
        diskIO: DiskIOSnapshot, network: NetworkSnapshot,
        tokenUsage: TokenUsageSnapshot, keyStats: KeyStatsSnapshot,
        weather: WeatherSnapshot, calendarSnapshot: CalendarSnapshot,
        jdStats: JDStatsSnapshot, codexToken: CodexTokenSnapshot
    ) {
        drawAppleWatchSection(
            ctx, x: panelX, y: py, w: panelW, h: ph)
        renderMiddleSlot(
            ctx, slot: slot, x: panelX + 20, w: panelW - 40,
            py: py, ph: ph, agents: agents, disk: disk, diskIO: diskIO,
            network: network, tokenUsage: tokenUsage, keyStats: keyStats,
            weather: weather, calendarSnapshot: calendarSnapshot,
            jdStats: jdStats, codexToken: codexToken)
    }

    private struct AppleWatchModuleSummary {
        let title: String
        let accent: CGColor
        let primary: String
        let primaryLabel: String
        let rows: [(String, String)]
        let footer: String
    }

    private func appleWatchSummary(
        slot: MiddleSlot, agents: AgentsSnapshot, disk: DiskSnapshot,
        diskIO: DiskIOSnapshot, network: NetworkSnapshot,
        keyStats: KeyStatsSnapshot, weather: WeatherSnapshot,
        calendarSnapshot: CalendarSnapshot, jdStats: JDStatsSnapshot
    ) -> AppleWatchModuleSummary {
        switch slot {
        case .codex, .claude:
            let usage = slot == .codex ? agents.codex : agents.claude
            let name = slot == .codex ? "CODEX" : "CLAUDE"
            return AppleWatchModuleSummary(
                title: name, accent: slot == .codex ? Color.cyan : Color.claude,
                primary: formatTokensCN(usage.todayTotalTokens),
                primaryLabel: "今日 Token",
                rows: [
                    ("输入", formatTokensCN(usage.todayInputTokens)),
                    ("输出", formatTokensCN(usage.todayOutputTokens)),
                    ("状态", usage.isWorking ? "工作中" : "空闲"),
                ],
                footer: usage.project ?? usage.activity ?? "暂无活动")
        case .disk:
            return AppleWatchModuleSummary(
                title: "磁盘", accent: Color.cyan,
                primary: String(format: "%.0f%%", disk.percent),
                primaryLabel: "已使用",
                rows: [
                    ("已用", String(format: "%.1f GB", disk.usedGB)),
                    ("可用", String(format: "%.1f GB", disk.freeGB)),
                    ("读取", String(format: "%.1f MB/s", diskIO.readBytesPerSec / 1_048_576)),
                ],
                footer: String(format: "写入 %.1f MB/s", diskIO.writeBytesPerSec / 1_048_576))
        case .network:
            return AppleWatchModuleSummary(
                title: "网络", accent: Color.purple,
                primary: formatRate(network.rxBytesPerSec),
                primaryLabel: "下载 MB/KB 每秒",
                rows: [
                    ("下载", formatRate(network.rxBytesPerSec)),
                    ("上传", formatRate(network.txBytesPerSec)),
                    ("状态", "实时"),
                ],
                footer: "网络吞吐量")
        case .weather:
            return AppleWatchModuleSummary(
                title: "天气", accent: Color.cyan,
                primary: weather.available
                    ? "\(Int(weather.temperature.rounded()))°" : "--",
                primaryLabel: weather.available ? weather.city : "未配置",
                rows: [
                    ("天气", weather.condition),
                    ("空气", weather.airQuality),
                    ("湿度", "\(weather.humidity)%"),
                ],
                footer: weather.rainForecast)
        case .keyStats:
            return AppleWatchModuleSummary(
                title: "键鼠统计", accent: Color.cyan,
                primary: compactNumber(keyStats.keyPresses),
                primaryLabel: "今日按键",
                rows: [
                    ("点击", compactNumber(keyStats.totalClicks)),
                    ("移动", String(format: "%.1f m", keyStats.mouseDistanceMeters)),
                    ("滚动", String(format: "%.1f kPx", keyStats.scrollDistancePixels / 1000)),
                ],
                footer: "峰值 KPS \(keyStats.peakKPS) · CPS \(keyStats.peakCPS)")
        case .calendar:
            let now = Date()
            let calendar = Calendar.current
            let upcoming = calendarSnapshot.events.filter {
                $0.date >= calendar.startOfDay(for: now)
            }
            func eventLabel(_ event: CalendarEvent?) -> String {
                guard let event else { return "暂无近期日程" }
                let values = calendar.dateComponents(
                    [.month, .day], from: event.date)
                return "\(values.month ?? 0)/\(values.day ?? 0) \(event.title)"
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy 年 M 月"
            return AppleWatchModuleSummary(
                title: "日历", accent: Color.cyan,
                primary: "\(calendar.component(.day, from: now))",
                primaryLabel: formatter.string(from: now),
                rows: [
                    ("星期", {
                        let f = DateFormatter()
                        f.locale = Locale(identifier: "zh_CN")
                        f.dateFormat = "EEEE"
                        return f.string(from: now)
                    }()),
                    ("日程", "\(calendarSnapshot.events.count) 项"),
                    ("订阅日历", eventLabel(upcoming.first)),
                ],
                footer: eventLabel(upcoming.dropFirst().first))
        case .jdAlliance:
            return AppleWatchModuleSummary(
                title: "京东联盟", accent: Color.orange,
                primary: jdStats.available ? "\(jdStats.day.orders)" : "--",
                primaryLabel: "今日成单",
                rows: [
                    ("今日佣金", formatJDMoney(jdStats.day.estimatedCommission)),
                    ("本周佣金", formatJDMoney(jdStats.week.estimatedCommission)),
                    ("本月佣金", formatJDMoney(jdStats.month.estimatedCommission)),
                ],
                footer: jdStats.available
                    ? "本月 \(jdStats.month.orders) 单"
                    : jdStats.errorMessage)
        case .token:
            return AppleWatchModuleSummary(
                title: "CODEX TOKEN", accent: Color.cyan,
                primary: formatTokensCN(agents.codex.todayTotalTokens),
                primaryLabel: "今日 Token",
                rows: [
                    ("输入", formatTokensCN(agents.codex.todayInputTokens)),
                    ("输出", formatTokensCN(agents.codex.todayOutputTokens)),
                    ("状态", "额度监控"),
                ],
                footer: "切换到主卡可查看额度和活跃度")
        case .mihomo:
            let snapshot = currentMihomoSnapshot()
            return AppleWatchModuleSummary(
                title: "N1 代理",
                accent: snapshot.available ? Color.green : Color.red,
                primary: snapshot.available
                    ? "\(snapshot.activeConnections)" : "--",
                primaryLabel: snapshot.available ? "活动连接" : "离线",
                rows: [
                    ("默认", snapshot.defaultNode),
                    ("OpenAI", snapshot.openAINode),
                    ("内存", formatMihomoBytes(snapshot.memoryBytes)),
                ],
                footer: snapshot.available
                    ? "\(snapshot.mode.uppercased()) · \(snapshot.version)"
                    : snapshot.errorMessage)
        }
    }

    private func renderAppleWatchHero(
        _ ctx: CGContext, module: AppleWatchModule,
        x: Int, w: Int, py: Int, ph: Int,
        agents: AgentsSnapshot, disk: DiskSnapshot, diskIO: DiskIOSnapshot,
        network: NetworkSnapshot, keyStats: KeyStatsSnapshot,
        weather: WeatherSnapshot, calendarSnapshot: CalendarSnapshot,
        jdStats: JDStatsSnapshot, codexToken: CodexTokenSnapshot
    ) {
        if module == .clock {
            drawAppleWatchSection(ctx, x: x, y: py, w: w, h: ph)
            drawAppleWatchClockCard(
                ctx, x: x + 24, y: py + 24, w: w - 48, h: ph - 48)
            return
        }
        if module == .mihomo {
            drawAppleWatchSection(ctx, x: x, y: py, w: w, h: ph)
            drawAppleWatchMihomoCard(
                ctx, x: x + 24, y: py + 24, w: w - 48, h: ph - 48,
                snapshot: currentMihomoSnapshot())
            return
        }
        guard let slot = module.middleSlot else { return }
        if slot == .token {
            renderAppleWatchTokenHero(
                ctx, x: x, w: w, py: py, ph: ph,
                stats: codexToken, liveUsage: agents.codex)
            return
        }
        if slot == .codex || slot == .claude {
            let usage = slot == .codex ? agents.codex : agents.claude
            let name = slot == .codex ? "CODEX" : "CLAUDE"
            let accent = slot == .codex ? Color.cyan : Color.claude
            drawAppleWatchSection(ctx, x: x, y: py, w: w, h: ph)
            renderAgentColumn(
                ctx, x: x + 28, w: w - 56, py: py,
                name: name, accent: accent, usage: usage,
                drawsTintedBackground: false)
            return
        }
        let summary = appleWatchSummary(
            slot: slot, agents: agents, disk: disk, diskIO: diskIO,
            network: network, keyStats: keyStats, weather: weather,
            calendarSnapshot: calendarSnapshot, jdStats: jdStats)
        drawAppleWatchSection(ctx, x: x, y: py, w: w, h: ph)
        let left = x + 28
        let right = x + w - 28
        Draw.text(
            ctx, summary.title.uppercased(), x: left, y: py + 17,
            font: Fonts.system(19, weight: .bold), color: summary.accent)
        Draw.text(
            ctx, summary.primaryLabel, x: left, y: py + 69,
            font: Fonts.system(19, weight: .semibold), color: Color.textS)
        Draw.text(
            ctx, summary.primary, x: left, y: py + 102,
            font: Fonts.system(68, weight: .bold), color: Color.textW)
        Draw.bar(
            ctx, x: left, y: py + 205, w: w - 56, h: 10,
            percent: heroProgress(slot: slot, summary: summary),
            color: summary.accent)

        let gap = 12
        let cardW = (w - 56 - gap * 2) / 3
        for (index, row) in summary.rows.prefix(3).enumerated() {
            drawAppleWatchValueCard(
                ctx, x: left + index * (cardW + gap), y: py + 246,
                w: cardW, title: row.0, value: row.1)
        }
        Draw.line(
            ctx, from: CGPoint(x: left, y: py + 344),
            to: CGPoint(x: right, y: py + 344), color: Color.border)
        Draw.text(
            ctx,
            truncate(summary.footer, font: Fonts.system(18), maxW: CGFloat(w - 56)),
            x: left, y: py + 374,
            font: Fonts.system(18, weight: .medium), color: Color.textS)
    }

    private func heroProgress(
        slot: MiddleSlot, summary: AppleWatchModuleSummary
    ) -> Double {
        switch slot {
        case .disk:
            return Double(summary.primary.replacingOccurrences(
                of: "%", with: "")) ?? 0
        case .weather:
            return 65
        case .keyStats:
            return 72
        case .jdAlliance:
            return 58
        case .calendar:
            return 50
        case .network:
            return 40
        case .codex, .claude:
            return 70
        case .token:
            return 0
        case .mihomo:
            return 65
        }
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// Draw the small, hardware-inspired agent status light used by the
    /// Codex Token card.  The color follows the same state model as the
    /// existing agent renderer: blue while working, amber when attention is
    /// needed, and green when the agent is idle/ready.
    private func drawCodexStatusLED(
        _ ctx: CGContext, x: Int, y: Int, usage: AgentUsage
    ) {
        let color: CGColor
        if usage.needsAttention {
            // Official Codex Micro palette: waiting for approval = yellow.
            color = Color.orange
        } else if usage.isWorking {
            // Thinking / running = blue.
            color = Color.blue
        } else if !usage.available {
            // No session/error data available.
            color = Color.red
        } else {
            // Completed / idle-ready.
            color = Color.textW
        }
        // Large enough to read at LCD distance and visually balance the title.
        let radius: CGFloat = 9
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(
            x: CGFloat(x) - radius, y: CGFloat(y) - radius,
            width: radius * 2, height: radius * 2))
    }

    private func renderAppleWatchTokenHero(
        _ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
        stats: CodexTokenSnapshot, liveUsage: AgentUsage
    ) {
        drawAppleWatchSection(ctx, x: x, y: py, w: w, h: ph)
        let left = x + 28
        let right = x + w - 28
        Draw.text(
            ctx, "CODEX TOKEN", x: left, y: py + 17,
            font: Fonts.system(19, weight: .bold), color: Color.cyan)
        // Align the LED's visual center with the CODEX TOKEN title, not its
        // baseline, so it reads as part of the same header row.
        drawCodexStatusLED(ctx, x: right - 12, y: py + 27, usage: liveUsage)
        drawRightAligned(
            ctx, "已更新", rightX: right, y: py + 18,
            font: Fonts.system(14, weight: .semibold), color: Color.green)

        guard stats.available else {
            Draw.centeredText(
                ctx, stats.errorMessage, cx: x + w / 2, y: py + ph / 2,
                font: Fonts.system(18), color: Color.textL)
            return
        }

        let today = max(stats.todayTokens, liveUsage.todayTotalTokens)
        Draw.text(
            ctx, "今日", x: left, y: py + 69,
            font: Fonts.system(20, weight: .semibold), color: Color.textS)
        Draw.text(
            ctx, formatTokensCN(today), x: left, y: py + 101,
            font: Fonts.system(72, weight: .bold), color: Color.textW)
        drawRightAligned(
            ctx, "IN \(formatTokensCN(liveUsage.todayInputTokens))",
            rightX: right, y: py + 91,
            font: Fonts.system(18, weight: .semibold), color: Color.textS)
        drawRightAligned(
            ctx, "OUT \(formatTokensCN(liveUsage.todayOutputTokens))",
            rightX: right, y: py + 124,
            font: Fonts.system(18, weight: .semibold), color: Color.textS)

        if let quota = stats.secondary ?? stats.primary {
            let remaining = quota.remainingPercent ?? 0
            let quotaColor: CGColor = remaining > 50
                ? Color.green : (remaining > 20 ? Color.orange : Color.red)
            Draw.text(
                ctx, String(format: "本周额度剩余 %.0f%%", remaining),
                x: left, y: py + 194,
                font: Fonts.system(19, weight: .semibold), color: quotaColor)
            if let reset = quota.resetsAt {
                drawRightAligned(
                    ctx, codexResetText(reset), rightX: right, y: py + 196,
                    font: Fonts.system(15), color: Color.textL)
            }
            Draw.bar(
                ctx, x: left, y: py + 225, w: w - 56, h: 12,
                percent: remaining, color: Color.blue)
        }

        Draw.text(
            ctx, "18 周活跃度", x: left, y: py + 259,
            font: Fonts.system(16, weight: .semibold), color: Color.textL)
        drawRightAligned(
            ctx,
            stats.resetCreditsAvailable.map { "可重置 \($0) 次" } ?? "可重置 --",
            rightX: right, y: py + 259,
            font: Fonts.system(15, weight: .semibold), color: Color.orange)
        renderAppleWatchHeatStrip(
            ctx, x: left, y: py + 293, w: w - 56,
            dailyTokens: stats.dailyTokens, todayTokens: today)

        let gap = 12
        let cardW = (w - 56 - gap) / 2
        drawAppleWatchValueCard(
            ctx, x: left, y: py + 344, w: cardW,
            title: "累计 TOKEN",
            value: formatCodexTokenCN(stats.lifetimeTokens))
        drawAppleWatchValueCard(
            ctx, x: left + cardW + gap, y: py + 344, w: cardW,
            title: "单日峰值",
            value: formatCodexTokenCN(stats.peakDailyTokens))
    }

    private func renderAppleWatchHeatStrip(
        _ ctx: CGContext, x: Int, y: Int, w: Int,
        dailyTokens: [String: UInt64], todayTokens: UInt64
    ) {
        let count = 32
        let gap = 5
        let cell = max(7, (w - gap * (count - 1)) / count)
        let values = dailyTokens.values.sorted()
        let peak = max(UInt64(1), max(values.last ?? 0, todayTokens))
        for index in 0..<count {
            let source = values.isEmpty
                ? UInt64((index % 6) * 10)
                : values[index * values.count / count]
            let ratio = sqrt(Double(source) / Double(peak))
            let color = source == 0
                ? Color.barBG
                : (Color.cyan.copy(
                    alpha: CGFloat(0.25 + ratio * 0.75)) ?? Color.cyan)
            let rect = CGRect(
                x: x + index * (cell + gap), y: y,
                width: cell, height: 16)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(
                roundedRect: rect, cornerWidth: 4, cornerHeight: 4,
                transform: nil))
            ctx.fillPath()
        }
    }

    private func drawAppleWatchValueCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int,
        title: String, value: String
    ) {
        let rect = CGRect(x: x, y: y, width: w, height: 74)
        ctx.setFillColor(CGColor(
            red: 28/255, green: 28/255, blue: 30/255, alpha: 1))
        ctx.addPath(CGPath(
            roundedRect: rect, cornerWidth: 22, cornerHeight: 22,
            transform: nil))
        ctx.fillPath()
        Draw.text(
            ctx, title, x: x + 17, y: y + 13,
            font: Fonts.system(14, weight: .medium), color: Color.textL)
        drawRightAligned(
            ctx, value, rightX: x + w - 17, y: y + 30,
            font: Fonts.system(28, weight: .bold), color: Color.textW)
    }

    private func renderAppleWatchDashboard(
        _ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
        modules: [AppleWatchModule], agents: AgentsSnapshot,
        disk: DiskSnapshot, diskIO: DiskIOSnapshot,
        keyStats: KeyStatsSnapshot,
        jdStats: JDStatsSnapshot, calendarSnapshot: CalendarSnapshot,
        weather: WeatherSnapshot, network: NetworkSnapshot
    ) {
        drawAppleWatchSection(ctx, x: x, y: py, w: w, h: ph)
        let inset = 20
        let gap = 14
        let topH = 190
        let bottomY = py + 226
        let bottomH = 204
        let halfW = (w - inset * 2 - gap) / 2

        drawAppleWatchCompactModule(
            ctx, module: modules[0], x: x + inset, y: py + 20,
            w: halfW, h: topH, agents: agents, disk: disk, diskIO: diskIO,
            network: network, keyStats: keyStats, weather: weather,
            calendarSnapshot: calendarSnapshot, jdStats: jdStats)
        drawAppleWatchCompactModule(
            ctx, module: modules[1], x: x + inset + halfW + gap, y: py + 20,
            w: halfW, h: topH, agents: agents, disk: disk, diskIO: diskIO,
            network: network, keyStats: keyStats, weather: weather,
            calendarSnapshot: calendarSnapshot, jdStats: jdStats)

        let thirdW = (w - inset * 2 - gap * 2) / 3
        for index in 0..<3 {
            drawAppleWatchCompactModule(
                ctx, module: modules[index + 2],
                x: x + inset + (thirdW + gap) * index, y: bottomY,
                w: thirdW, h: bottomH, agents: agents, disk: disk,
                diskIO: diskIO, network: network, keyStats: keyStats,
                weather: weather, calendarSnapshot: calendarSnapshot,
                jdStats: jdStats)
        }
    }

    private func drawAppleWatchCompactModule(
        _ ctx: CGContext, module: AppleWatchModule,
        x: Int, y: Int, w: Int, h: Int,
        agents: AgentsSnapshot, disk: DiskSnapshot, diskIO: DiskIOSnapshot,
        network: NetworkSnapshot, keyStats: KeyStatsSnapshot,
        weather: WeatherSnapshot, calendarSnapshot: CalendarSnapshot,
        jdStats: JDStatsSnapshot
    ) {
        if module == .weather {
            drawAppleWatchWeatherCard(
                ctx, x: x, y: y, w: w, h: h, weather: weather)
            return
        }
        if module == .network {
            drawAppleWatchNetworkCard(
                ctx, x: x, y: y, w: w, h: h, network: network)
            return
        }
        if module == .clock {
            drawAppleWatchClockCard(ctx, x: x, y: y, w: w, h: h)
            return
        }
        if module == .jdAlliance {
            drawAppleWatchJDCard(
                ctx, x: x, y: y, w: w, h: h, stats: jdStats)
            return
        }
        if module == .mihomo {
            drawAppleWatchMihomoCard(
                ctx, x: x, y: y, w: w, h: h,
                snapshot: currentMihomoSnapshot())
            return
        }
        guard let slot = module.middleSlot else { return }
        let summary = appleWatchSummary(
            slot: slot, agents: agents, disk: disk, diskIO: diskIO,
            network: network, keyStats: keyStats, weather: weather,
            calendarSnapshot: calendarSnapshot, jdStats: jdStats)
        fillAppleWatchCard(ctx, x: x, y: y, w: w, h: h)
        Draw.text(
            ctx, summary.title, x: x + 20, y: y + 16,
            font: Fonts.system(17, weight: .bold), color: summary.accent)
        Draw.text(
            ctx, summary.primary, x: x + 20, y: y + 50,
            font: Fonts.system(45, weight: .bold), color: Color.textW)
        if slot == .jdAlliance {
            let valueFont = Fonts.system(45, weight: .bold)
            let valueWidth = (summary.primary as NSString).size(
                withAttributes: [.font: valueFont]).width
            Draw.text(
                ctx, "单", x: Int(CGFloat(x + 25) + valueWidth), y: y + 77,
                font: Fonts.system(15), color: Color.textL)
        }
        drawRightAligned(
            ctx,
            slot == .jdAlliance
                ? "今日销售 \(formatJDMoney(jdStats.day.estimatedSales))"
                : summary.primaryLabel,
            rightX: x + w - 20, y: y + 24,
            font: Fonts.system(14), color: Color.textL)
        if let first = summary.rows.first {
            Draw.text(
                ctx, "\(first.0) \(first.1)", x: x + 20, y: y + 116,
                font: Fonts.system(15, weight: .semibold), color: Color.cyan)
        }
        if summary.rows.count > 1 {
            let second = summary.rows[1]
            drawRightAligned(
                ctx, "\(second.0) \(second.1)", rightX: x + w - 20,
                y: y + 116, font: Fonts.system(15, weight: .semibold),
                color: Color.green)
        }
        if summary.rows.count > 2 {
            let third = summary.rows[2]
            Draw.text(
                ctx,
                slot == .calendar ? third.1 : "\(third.0) \(third.1)",
                x: x + 20, y: y + 146,
                font: Fonts.system(14, weight: .semibold),
                color: summary.accent)
        }
        let footerFont = Fonts.system(14, weight: .semibold)
        Draw.text(
            ctx,
            truncate(summary.footer, font: footerFont, maxW: CGFloat(w - 40)),
            x: x + 20, y: y + 170,
            font: footerFont,
            color: summary.accent)
    }

    private func fillAppleWatchCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int
    ) {
        let path = CGPath(
            roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(
            red: 44/255, green: 44/255, blue: 46/255, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawAppleWatchJDCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        stats: JDStatsSnapshot
    ) {
        fillAppleWatchCard(ctx, x: x, y: y, w: w, h: h)
        Draw.text(
            ctx, "京东联盟", x: x + 20, y: y + 16,
            font: Fonts.system(17, weight: .bold), color: Color.orange)
        guard stats.available else {
            Draw.centeredText(
                ctx, "暂无数据", cx: x + w / 2, y: y + 82,
                font: Fonts.system(18), color: Color.textL)
            return
        }

        let leftX = x + 20
        let rightX = x + w / 2 + 10
        let rightEdge = x + w - 20

        Draw.text(
            ctx, "今日单量", x: leftX, y: y + 45,
            font: Fonts.system(14, weight: .semibold), color: Color.textL)
        let orderText = "\(stats.day.orders)"
        let orderFont = Fonts.system(34, weight: .bold)
        Draw.text(
            ctx, orderText, x: leftX, y: y + 65,
            font: orderFont, color: Color.textW)
        let orderWidth = (orderText as NSString).size(
            withAttributes: [.font: orderFont]).width
        Draw.text(
            ctx, "单", x: Int(CGFloat(leftX + 6) + orderWidth), y: y + 82,
            font: Fonts.system(14), color: Color.textL)

        Draw.text(
            ctx, "今日佣金", x: rightX, y: y + 45,
            font: Fonts.system(14, weight: .semibold), color: Color.textL)
        Draw.text(
            ctx, formatJDMoney(stats.day.estimatedCommission),
            x: rightX, y: y + 68,
            font: Fonts.system(25, weight: .bold), color: Color.green)

        Draw.line(
            ctx, from: CGPoint(x: leftX, y: y + 108),
            to: CGPoint(x: rightEdge, y: y + 108), color: Color.border)

        func periodRow(
            _ label: String, _ period: JDPeriodStats, _ rowY: Int
        ) {
            Draw.text(
                ctx, "\(label)销售 \(formatJDMoney(period.estimatedSales))",
                x: leftX, y: rowY,
                font: Fonts.system(14, weight: .semibold), color: Color.cyan)
            Draw.text(
                ctx, "\(label)佣金 \(formatJDMoney(period.estimatedCommission))",
                x: rightX, y: rowY,
                font: Fonts.system(14, weight: .semibold), color: Color.green)
        }

        periodRow("本周", stats.week, y + 117)
        periodRow("本月", stats.month, y + 143)
        periodRow("本年", stats.year, y + 169)
    }

    private func drawAppleWatchCalendarCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        snapshot: CalendarSnapshot
    ) {
        fillAppleWatchCard(ctx, x: x, y: y, w: w, h: h)
        let calendar = Calendar.current
        let now = Date()
        let day = calendar.component(.day, from: now)
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "zh_CN")
        weekday.dateFormat = "EEEE"
        let month = DateFormatter()
        month.locale = Locale(identifier: "zh_CN")
        month.dateFormat = "yyyy 年 M 月"
        Draw.text(
            ctx, "日历", x: x + 20, y: y + 16,
            font: Fonts.system(17, weight: .bold), color: Color.cyan)
        drawRightAligned(
            ctx, "今天", rightX: x + w - 20, y: y + 17,
            font: Fonts.system(15, weight: .semibold), color: Color.green)
        Draw.text(
            ctx, "\(day)", x: x + 20, y: y + 49,
            font: Fonts.system(53, weight: .bold), color: Color.textW)
        Draw.text(
            ctx, weekday.string(from: now), x: x + 90, y: y + 66,
            font: Fonts.system(21, weight: .semibold), color: Color.textW)
        Draw.text(
            ctx, month.string(from: now), x: x + 90, y: y + 96,
            font: Fonts.system(15), color: Color.textL)
        Draw.line(
            ctx, from: CGPoint(x: x + 20, y: y + 137),
            to: CGPoint(x: x + w - 20, y: y + 137), color: Color.border)
        let upcoming = snapshot.events.first { $0.date >= calendar.startOfDay(for: now) }
        Draw.text(
            ctx, upcoming?.title ?? "暂无近期日程",
            x: x + 20, y: y + 154,
            font: Fonts.system(15), color: Color.green)
    }

    private func drawAppleWatchWeatherCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        weather: WeatherSnapshot
    ) {
        fillAppleWatchCard(ctx, x: x, y: y, w: w, h: h)
        Draw.text(
            ctx, "天气", x: x + 18, y: y + 16,
            font: Fonts.system(17, weight: .bold), color: Color.cyan)
        guard weather.available else {
            Draw.centeredText(
                ctx, "未配置", cx: x + w / 2, y: y + 90,
                font: Fonts.system(18), color: Color.textL)
            return
        }
        Draw.text(
            ctx, "\(Int(weather.temperature.rounded()))°",
            x: x + 18, y: y + 54,
            font: Fonts.system(48, weight: .bold), color: Color.textW)
        drawRightAligned(
            ctx, weather.icon, rightX: x + w - 4, y: y + 8,
            font: Fonts.system(112), color: Color.orange)
        Draw.text(
            ctx, "\(weather.condition) · \(weather.airQuality)",
            x: x + 18, y: y + 118,
            font: Fonts.system(16, weight: .semibold), color: Color.cyan)
        Draw.text(
            ctx,
            truncate(
                weather.rainForecast,
                font: Fonts.system(16, weight: .semibold),
                maxW: CGFloat(w - 36)),
            x: x + 18, y: y + 157,
            font: Fonts.system(16, weight: .semibold), color: Color.cyan)
    }

    private func drawAppleWatchNetworkCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        network: NetworkSnapshot
    ) {
        fillAppleWatchCard(ctx, x: x, y: y, w: w, h: h)
        Draw.text(
            ctx, "网络", x: x + 18, y: y + 16,
            font: Fonts.system(17, weight: .bold), color: Color.purple)
        Draw.text(
            ctx, "↓ 下载", x: x + 18, y: y + 64,
            font: Fonts.system(16, weight: .semibold), color: Color.green)
        drawRightAligned(
            ctx, formatRateWithUnit(network.rxBytesPerSec),
            rightX: x + w - 18, y: y + 54,
            font: Fonts.system(26, weight: .bold), color: Color.textW)
        Draw.text(
            ctx, "↑ 上传", x: x + 18, y: y + 130,
            font: Fonts.system(16, weight: .semibold), color: Color.orange)
        drawRightAligned(
            ctx, formatRateWithUnit(network.txBytesPerSec),
            rightX: x + w - 18, y: y + 120,
            font: Fonts.system(26, weight: .bold), color: Color.textW)
    }

    private func drawAppleWatchMihomoCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        snapshot: MihomoSnapshot
    ) {
        fillAppleWatchCard(ctx, x: x, y: y, w: w, h: h)
        Draw.text(
            ctx, "N1 代理", x: x + 18, y: y + 16,
            font: Fonts.system(17, weight: .bold), color: Color.cyan)
        drawRightAligned(
            ctx, snapshot.available ? "● 在线" : "● 离线",
            rightX: x + w - 18, y: y + 17,
            font: Fonts.system(14, weight: .semibold),
            color: snapshot.available ? Color.green : Color.red)

        guard snapshot.available else {
            Draw.centeredText(
                ctx, snapshot.errorMessage, cx: x + w / 2, y: y + h / 2 - 10,
                font: Fonts.system(16, weight: .medium), color: Color.textL)
            return
        }

        let large = h > 250
        let left = x + 18
        let right = x + w - 18
        Draw.text(
            ctx, "默认节点", x: left, y: y + 49,
            font: Fonts.system(14, weight: .semibold), color: Color.textL)
        Draw.text(
            ctx,
            truncate(
                snapshot.defaultNode,
                font: Fonts.system(large ? 42 : 25, weight: .bold),
                maxW: CGFloat(w - 36)),
            x: left, y: y + 70,
            font: Fonts.system(large ? 42 : 25, weight: .bold),
            color: Color.textW)

        let openAIY = large ? y + 133 : y + 105
        Draw.text(
            ctx, "OpenAI \(snapshot.openAINode)", x: left, y: openAIY,
            font: Fonts.system(large ? 20 : 14, weight: .semibold),
            color: Color.green)
        let dividerY = large ? y + 174 : y + 130
        Draw.line(
            ctx, from: CGPoint(x: left, y: dividerY),
            to: CGPoint(x: right, y: dividerY), color: Color.border)

        if large {
            drawAppleWatchValueCard(
                ctx, x: left, y: y + 202, w: (w - 48) / 3,
                title: "活动连接", value: "\(snapshot.activeConnections)")
            drawAppleWatchValueCard(
                ctx, x: left + (w - 48) / 3 + 6, y: y + 202,
                w: (w - 48) / 3, title: "累计下载",
                value: formatMihomoBytes(snapshot.downloadTotal))
            drawAppleWatchValueCard(
                ctx, x: left + ((w - 48) / 3 + 6) * 2, y: y + 202,
                w: (w - 48) / 3, title: "累计上传",
                value: formatMihomoBytes(snapshot.uploadTotal))
            Draw.text(
                ctx,
                "规则模式 \(snapshot.mode.uppercased()) · 内存 \(formatMihomoBytes(snapshot.memoryBytes)) · \(snapshot.version)",
                x: left, y: y + h - 42,
                font: Fonts.system(16, weight: .semibold), color: Color.cyan)
        } else {
            Draw.text(
                ctx, "连接 \(snapshot.activeConnections)",
                x: left, y: y + 141,
                font: Fonts.system(14, weight: .semibold), color: Color.cyan)
            drawRightAligned(
                ctx, "内存 \(formatMihomoBytes(snapshot.memoryBytes))",
                rightX: right, y: y + 141,
                font: Fonts.system(14, weight: .semibold), color: Color.purple)
            Draw.text(
                ctx, "↓ \(formatMihomoBytes(snapshot.downloadTotal))",
                x: left, y: y + 168,
                font: Fonts.system(14, weight: .semibold), color: Color.green)
            drawRightAligned(
                ctx, "↑ \(formatMihomoBytes(snapshot.uploadTotal))",
                rightX: right, y: y + 168,
                font: Fonts.system(14, weight: .semibold), color: Color.orange)
        }
    }

    private func formatMihomoBytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_099_511_627_776 {
            return String(format: "%.1f TB", value / 1_099_511_627_776)
        }
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB", value / 1_073_741_824)
        }
        if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576)
        }
        return String(format: "%.0f KB", value / 1024)
    }

    private func drawAppleWatchClockCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int
    ) {
        fillAppleWatchCard(ctx, x: x, y: y, w: w, h: h)
        Draw.text(
            ctx, "时间", x: x + 18, y: y + 16,
            font: Fonts.system(17, weight: .bold), color: Color.green)

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        let hour = formatter.string(from: now)
        formatter.dateFormat = "mm"
        let minute = formatter.string(from: now)

        let sideInset = max(16, w / 14)
        let clockY = y + 48
        let clockH = min(max(115, h - 68), 220)
        let centerGap = max(24, w / 10)
        let tileW = (w - sideInset * 2 - centerGap) / 2
        let digitFont = Fonts.system(
            CGFloat(min(112, max(72, clockH * 68 / 100))),
            weight: .bold)

        func condensedCenteredText(
            _ value: String, cx: Int, textY: Int
        ) {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(cx), y: 0)
            ctx.scaleBy(x: 0.70, y: 1)
            Draw.centeredText(
                ctx, value, cx: 0, y: textY,
                font: digitFont, color: Color.textW)
            ctx.restoreGState()
        }

        func flipTile(_ value: String, _ tileX: Int) {
            let rect = CGRect(
                x: tileX, y: clockY, width: tileW, height: clockH)
            let path = CGPath(
                roundedRect: rect, cornerWidth: 18, cornerHeight: 18,
                transform: nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(CGColor(
                red: 58/255, green: 58/255, blue: 62/255, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.addPath(path)
            ctx.strokePath()
            Draw.line(
                ctx,
                from: CGPoint(x: tileX + 8, y: clockY + clockH / 2),
                to: CGPoint(x: tileX + tileW - 8, y: clockY + clockH / 2),
                color: Color.border)
            condensedCenteredText(
                value, cx: tileX + tileW / 2,
                textY: clockY + clockH / 2 - Int(digitFont.pointSize / 2))
        }

        let leftTileX = x + sideInset
        let rightTileX = leftTileX + tileW + centerGap
        flipTile(hour, leftTileX)
        flipTile(minute, rightTileX)
        Draw.centeredText(
            ctx, ":", cx: x + w / 2,
            y: clockY + clockH / 2 - 25,
            font: Fonts.system(42, weight: .bold), color: Color.green)
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.1f", bytesPerSecond / 1024)
    }

    private func formatRateWithUnit(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(
                format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.1f KB/s", bytesPerSecond / 1024)
    }

    private func renderAppleWatchSystem(
        _ ctx: CGContext, x: Int, w: Int, py: Int,
        cpu: CPUSnapshot, mem: MemorySnapshot, temp: TemperatureSnapshot
    ) {
        Draw.text(
            ctx, "SYSTEM", x: x + 22, y: py + 17,
            font: Fonts.system(22, weight: .bold), color: Color.cyan)

        let cx = x + w / 2
        let cy = py + 164
        let cpuPercent = max(0, min(100, cpu.total))
        let memPercent = max(0, min(100, mem.percent))
        let cpuTemperature = temp.cpuTemp ?? 0
        // Temperature is not a percentage. Map the useful 40–100°C range to
        // the ring so a normal 60°C reading does not look like 60% danger.
        let temperatureProgress = max(
            0, min(100, (cpuTemperature - 40) / 60 * 100))
        drawAppleWatchRing(
            ctx, cx: cx, cy: cy, radius: 105,
            // Standard convention: bright foreground arc on a dark background.
            percent: temperatureProgress, color: Color.red,
            background: Color.redD)
        drawAppleWatchRing(
            ctx, cx: cx, cy: cy, radius: 79,
            percent: memPercent, color: Color.green,
            background: Color.greenD)
        drawAppleWatchRing(
            ctx, cx: cx, cy: cy, radius: 53,
            percent: cpuPercent,
            color: Color.cyan, background: Color.cyanD)
        Draw.centeredText(
            ctx, "\(Int(cpuPercent.rounded()))",
            cx: cx, y: cy - 35,
            font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(
            ctx, "CPU %",
            cx: cx, y: cy + 18,
            font: Fonts.system(16, weight: .semibold), color: Color.textL)

        let cardY = py + 300
        let gap = 12
        let cardW = (w - 44 - gap) / 2
        drawAppleWatchMetricCard(
            ctx, x: x + 22, y: cardY, w: cardW,
            title: "温度", value: "\(Int(cpuTemperature.rounded()))°",
            detail: "系统负载", color: Color.red)
        drawAppleWatchMetricCard(
            ctx, x: x + 22 + cardW + gap, y: cardY, w: cardW,
            title: "内存", value: "\(Int(memPercent.rounded()))%",
            detail: String(
                format: "可用 %.1fG",
                Double(mem.available) / 1_073_741_824),
            color: Color.green)
    }

    private func drawAppleWatchRing(
        _ ctx: CGContext, cx: Int, cy: Int, radius: Int,
        percent: Double, color: CGColor, background: CGColor
    ) {
        let width: CGFloat = 15
        let rect = CGRect(
            x: cx - radius, y: cy - radius,
            width: radius * 2, height: radius * 2)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(background)
        ctx.strokeEllipse(in: rect)
        ctx.setStrokeColor(color)
        ctx.addArc(
            center: CGPoint(x: cx, y: cy), radius: CGFloat(radius),
            startAngle: -.pi / 2,
            endAngle: -.pi / 2 + CGFloat(percent / 100) * .pi * 2,
            clockwise: false)
        ctx.strokePath()
    }

    private func drawAppleWatchMetricCard(
        _ ctx: CGContext, x: Int, y: Int, w: Int,
        title: String, value: String, detail: String, color: CGColor
    ) {
        let rect = CGRect(x: x, y: y, width: w, height: 112)
        let path = CGPath(
            roundedRect: rect, cornerWidth: 24, cornerHeight: 24,
            transform: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(
            red: 44/255, green: 44/255, blue: 46/255, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()
        Draw.text(
            ctx, title, x: x + 15, y: y + 13,
            font: Fonts.system(16, weight: .semibold), color: color)
        Draw.text(
            ctx, value, x: x + 15, y: y + 39,
            font: Fonts.system(34, weight: .bold), color: Color.textW)
        Draw.text(
            ctx, detail, x: x + 15, y: y + 84,
            font: Fonts.system(13), color: Color.textL)
    }

    // MARK: - CPU Panel

    private func renderCPU(_ ctx: CGContext, cpu: CPUSnapshot, temp: TemperatureSnapshot,
                           agentsBusy: Bool) {
        let x = Layout.panelX(0)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.blue)
        Draw.text(ctx, "CPU", x: x + 20, y: py + 14, font: Fonts.system(24, weight: .bold), color: Color.blue)
        // Arc gauge
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: cpu.total,
                      color: Color.forPercent(cpu.total),
                      colorDark: Color.forPercentDark(cpu.total), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", cpu.total),
                          cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Per-core bars — E-cores first, then P-cores, shifted down half a row
        let barX = x + 194
        let barW = pw - 218
        let coreCount = cpu.perCore.count
        let bottomLimit = py + ph - 96
        let fontSize: CGFloat = coreCount > 16 ? 12 : (coreCount > 10 ? 14 : 16)
        let barH = coreCount > 16 ? 8 : (coreCount > 10 ? 10 : 10)
        let spacing = min(36, (bottomLimit - py - 18) / max(coreCount, 1))
        let startY = py + 18 + spacing / 2  // shifted down half a row

        let topologyRows = CoreTopology.displayRows()

        // Display E-cores first, then P-cores, while reading the actual logical
        // CPU index supplied by the device-tree topology.
        for row in 0..<coreCount {
            let by = startY + row * spacing
            if by + Int(fontSize) > bottomLimit { break }

            let mapped = row < topologyRows.count
                ? topologyRows[row]
                : (index: row, label: "C\(row + 1)", isEfficiency: true)
            let coreIndex = mapped.index
            let isECore = mapped.isEfficiency
            let label = mapped.label

            let pct = coreIndex < cpu.perCore.count ? cpu.perCore[coreIndex] : 0
            let barColor = isECore ? Color.cyan : Color.forPercent(pct)

            Draw.text(ctx, label, x: barX, y: by,
                      font: Fonts.system(fontSize), color: isECore ? Color.cyan : Color.textD)
            Draw.bar(ctx, x: barX + 28, y: by + 4, w: barW - 78, h: barH,
                     percent: pct, color: barColor)
            Draw.text(ctx, String(format: "%.0f%%", pct),
                      x: barX + barW - 46, y: by,
                      font: Fonts.system(fontSize), color: Color.textS)
        }

        // Pikachu in the left space below the gauge — its electricity scales with
        // CPU load (the machine's "power draw"). While an AI agent is working it
        // hops and turns to face left/right, like it's cheering the machine on.
        if let pika = PikachuAsset.image {
            let t = Date().timeIntervalSince1970
            let size: CGFloat = 132
            var rect = CGRect(x: CGFloat(x + 100) - size / 2, y: CGFloat(py + 210),
                              width: size, height: size)
            var flip = false
            if agentsBusy {
                let hop = CGFloat(abs(sin(t * .pi * 2)) * 9)   // ~2 hops/sec
                rect.origin.y -= hop                            // up (flipped coords)
                flip = Int(t * 2) % 4 >= 2                       // turn every ~1s
            }
            drawElectricity(ctx, around: rect, intensity: cpu.total, t: t)
            drawImageUpright(ctx, pika, in: rect, flipX: flip)
        }

        // Temp + Load — large, spanning the full panel width at the bottom.
        // Label on the left, value right-aligned to the panel edge.
        let rightEdge = CGFloat(x + pw - 18)
        let tempY = py + ph - 78
        if let cpuTemp = temp.cpuTemp {
            let tempColor = cpuTemp > 65 ? Color.red : (cpuTemp > 50 ? Color.orange : Color.green)
            Draw.text(ctx, "Temp", x: x + 18, y: tempY + 8,
                      font: Fonts.system(26, weight: .medium), color: Color.textL)
            let vStr = String(format: "%.0f°C", cpuTemp)
            let vFont = Fonts.system(42, weight: .bold)
            let vW = (vStr as NSString).size(withAttributes: [.font: vFont]).width
            Draw.text(ctx, vStr, x: Int(rightEdge - vW), y: tempY,
                      font: vFont, color: tempColor)
        }
        let loadY = py + ph - 34
        let (l1, l5, l15) = cpu.loadAvg
        Draw.text(ctx, "Load", x: x + 18, y: loadY,
                  font: Fonts.system(22, weight: .medium), color: Color.textL)
        let lStr = String(format: "%.1f / %.1f / %.1f", l1, l5, l15)
        let lFont = Fonts.system(26, weight: .medium)
        let lW = (lStr as NSString).size(withAttributes: [.font: lFont]).width
        Draw.text(ctx, lStr, x: Int(rightEdge - lW), y: loadY,
                  font: lFont, color: Color.textS)
    }

    /// Yellow lightning crackling around Pikachu — more/brighter bolts as `intensity`
    /// (CPU %) rises. Flickers with `t` so it animates while the frame rate is high.
    private func drawElectricity(_ ctx: CGContext, around rect: CGRect,
                                 intensity: Double, t: Double) {
        let level = min(max(intensity / 100, 0), 1)
        let yellow = CGColor(red: 1.0, green: 0.9, blue: 0.15, alpha: 1)
        let bolts = 2 + Int(level * 6)             // 2…8 bolts
        ctx.setStrokeColor(yellow); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for i in 0..<bolts {
            // Twinkle: each bolt blinks on/off on its own phase
            if (Int(t * 14) + i * 5) % 3 == 0 { continue }
            let ang = Double(i) / Double(bolts) * 2 * .pi + t * 0.7
            let ax = rect.midX + CGFloat(cos(ang)) * rect.width * 0.44
            let ay = rect.midY + CGFloat(sin(ang)) * rect.height * 0.42
            // Jagged 3-segment bolt pointing outward from the anchor
            let len = CGFloat(9 + level * 15)
            let dx = CGFloat(cos(ang)), dy = CGFloat(sin(ang))
            let nx = -dy, ny = dx                  // perpendicular for the zigzag
            ctx.setLineWidth(1.6 + CGFloat(level) * 1.2)
            let jag = 4 + level * 3
            ctx.move(to: CGPoint(x: ax, y: ay))
            ctx.addLine(to: CGPoint(x: ax + dx * len * 0.4 + nx * CGFloat(jag),
                                    y: ay + dy * len * 0.4 + ny * CGFloat(jag)))
            ctx.addLine(to: CGPoint(x: ax + dx * len * 0.7 - nx * CGFloat(jag),
                                    y: ay + dy * len * 0.7 - ny * CGFloat(jag)))
            ctx.addLine(to: CGPoint(x: ax + dx * len, y: ay + dy * len))
            ctx.strokePath()
        }
    }

    // MARK: - Memory Panel

    private func renderMemory(_ ctx: CGContext, mem: MemorySnapshot, sys: SystemSnapshot?,
                              network: NetworkSnapshot, agentsBusy: Bool) {
        let x = Layout.panelX(4)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let totalGB = Double(mem.total) / (1024 * 1024 * 1024)
        let pct = mem.percent

        Draw.panel(ctx, x: x, y: py, w: pw, h: Layout.panelHeight, accent: Color.green)
        Draw.text(ctx, "MEMORY", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.green)
        Draw.text(ctx, String(format: "%.0f GB", totalGB), x: x + pw - 75, y: py + 16,
                  font: Fonts.system(18), color: Color.textD)

        // Arc gauge — length = used% (utilization gauge), COLOR = macOS memory pressure.
        // A Mac using RAM as cache (high used%, low pressure) is healthy → stays green.
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: pct,
                      color: Color.forPressure(mem.pressure),
                      colorDark: Color.forPressureDark(mem.pressure), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", pct), cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Breakdown
        let rx = x + 194
        let rw = pw - 218
        var ry = py + 48

        Draw.text(ctx, "Breakdown", x: rx, y: ry,
                  font: Fonts.system(18), color: Color.textL)
        ry += 28

        let activeGB = Double(mem.active) / (1024 * 1024 * 1024)
        let wiredGB = Double(mem.wired) / (1024 * 1024 * 1024)
        let compressedGB = Double(mem.compressed) / (1024 * 1024 * 1024)
        let availGB = Double(mem.available) / (1024 * 1024 * 1024)

        let items: [(String, Double, CGColor)] = [
            ("Active", activeGB, Color.green),
            ("Wired", wiredGB, Color.orange),
            ("Compressed", compressedGB, Color.purple),
            ("Available", availGB, Color.cyan),
        ]
        for (label, val, color) in items {
            Draw.text(ctx, label, x: rx, y: ry,
                      font: Fonts.system(17), color: Color.textL)
            let valStr = String(format: "%.1fG", val)
            let valFont = Fonts.system(17)
            let valW = (valStr as NSString).size(withAttributes: [.font: valFont]).width
            Draw.text(ctx, valStr, x: Int(CGFloat(rx + rw) - valW), y: ry,
                      font: valFont, color: Color.textS)
            Draw.bar(ctx, x: rx, y: ry + 24, w: rw, h: 10,
                     percent: val / totalGB * 100, color: color)
            ry += 48
        }

        // Bottom: network throughput and a compact history chart, matching the
        // original MacTR memory card. The clock/date area is intentionally omitted.
        let ph = Layout.panelHeight
        let dividerY = py + ph - 116
        let cx0 = x + 16
        let cw = pw - 32
        Draw.line(ctx, from: CGPoint(x: cx0, y: dividerY),
                  to: CGPoint(x: cx0 + cw, y: dividerY), color: Color.border)

        let dl = Double(network.rxBytesPerSec) / 1_000_000
        let ul = Double(network.txBytesPerSec) / 1_000_000
        memoryNetworkDownload.append(dl); memoryNetworkUpload.append(ul)
        if memoryNetworkDownload.count > 28 { memoryNetworkDownload.removeFirst() }
        if memoryNetworkUpload.count > 28 { memoryNetworkUpload.removeFirst() }
        let labelY = dividerY + 8
        // Restore BongoCat to its original left-side footer position.
        let tapPhase = Int(Date().timeIntervalSince1970 * 5) % 2 == 0
        drawBongoCat(ctx, cx: x + 96, baseY: dividerY,
                     tapping: agentsBusy, phase: tapPhase)
        // The network section fills the complete width below the cat.
        let networkX = x + 16
        let networkW = pw - 32
        Draw.text(ctx, "Network", x: networkX, y: labelY,
                  font: Fonts.system(15, weight: .semibold), color: Color.textL)
        Draw.text(ctx, String(format: "↓ %.1f MB/s", dl), x: networkX, y: labelY + 17,
                  font: Fonts.system(14, weight: .semibold), color: Color.cyan)
        drawRightAligned(ctx, String(format: "↑ %.1f MB/s", ul), rightX: x + pw - 16,
                         y: labelY + 17, font: Fonts.system(14, weight: .semibold), color: Color.orange)
        let chart = CGRect(x: CGFloat(networkX), y: CGFloat(py + ph - 42),
                           width: CGFloat(networkW), height: 22)
        let peak = max(1.0, (memoryNetworkDownload + memoryNetworkUpload).max() ?? 1)
        let count = max(memoryNetworkDownload.count, 1)
        let barW = max(2, Int(chart.width) / count - 2)
        for i in 0..<memoryNetworkDownload.count {
            let bx = Int(chart.minX) + i * (barW + 2)
            let dh = Int(CGFloat(memoryNetworkDownload[i] / peak) * chart.height)
            let uh = Int(CGFloat(memoryNetworkUpload[i] / peak) * chart.height)
            ctx.setFillColor(Color.cyan)
            ctx.fill(CGRect(x: bx, y: Int(chart.maxY) - dh,
                            width: barW, height: max(1, dh)))
            ctx.setFillColor(Color.orange)
            ctx.fill(CGRect(x: bx, y: Int(chart.maxY) - dh - uh,
                            width: barW, height: max(1, uh)))
        }
    }

    // MARK: - Bongo Cat (real line-art sprite, kuroni/bongocat-osu)

    /// Draw the classic Bongo Cat: the real line-art head sprite peeking over a desk,
    /// with a keyboard and two pink paws that slap it (`baseY` is the desk line). When
    /// `tapping`, the paws alternate; otherwise they rest and a "z" floats up.
    private func drawBongoCat(_ ctx: CGContext, cx: Int, baseY: Int, tapping: Bool, phase: Bool) {
        let dark = CGColor(red: 30/255, green: 34/255, blue: 48/255, alpha: 1)
        let pink = CGColor(red: 244/255, green: 150/255, blue: 174/255, alpha: 1)
        let kbTop = CGColor(red: 210/255, green: 216/255, blue: 230/255, alpha: 1)
        let cxD = CGFloat(cx), b = CGFloat(baseY)

        // --- Keyboard on the desk ---
        let kbW: CGFloat = 152, kbH: CGFloat = 15
        let kbX = cxD - kbW / 2, kbY = b - kbH
        let kbPath = CGPath(roundedRect: CGRect(x: kbX, y: kbY, width: kbW, height: kbH),
                            cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(kbTop); ctx.addPath(kbPath); ctx.fillPath()
        ctx.setStrokeColor(dark); ctx.setLineWidth(1.5); ctx.addPath(kbPath); ctx.strokePath()
        ctx.setLineWidth(1)
        var kx = kbX + 13
        while kx < kbX + kbW - 6 {
            ctx.move(to: CGPoint(x: kx, y: kbY + 2)); ctx.addLine(to: CGPoint(x: kx, y: kbY + kbH - 2))
            kx += 13
        }
        ctx.strokePath()

        // --- Cat head sprite, chin just above the keyboard ---
        if let cat = BongoCatAsset.image {
            let cw: CGFloat = 148
            let ch = cw * CGFloat(cat.height) / CGFloat(cat.width)
            let rect = CGRect(x: cxD - cw / 2, y: kbY - 4 - ch, width: cw, height: ch)
            drawImageUpright(ctx, cat, in: rect)
        }

        // --- Pink paws resting on / slapping the keyboard, outlined to match line art ---
        let pawRX: CGFloat = 13, pawRY: CGFloat = 10
        let downY = kbY + 2, upY = kbY - 14         // down = on keys, up = lifted to tap
        let lY = tapping ? (phase ? upY : downY) : downY
        let rY = tapping ? (phase ? downY : upY) : downY
        for (px, py2) in [(cxD - 34, lY), (cxD + 34, rY)] {
            let r = CGRect(x: px - pawRX, y: py2 - pawRY, width: pawRX * 2, height: pawRY * 2)
            ctx.setFillColor(pink); ctx.fillEllipse(in: r)
            ctx.setStrokeColor(dark); ctx.setLineWidth(2); ctx.strokeEllipse(in: r)
        }

        // Zzz when dozing
        if !tapping {
            Draw.text(ctx, "z", x: Int(cxD) + 60, y: Int(kbY) - 74,
                      font: Fonts.system(16, weight: .bold), color: Color.textL)
            Draw.text(ctx, "z", x: Int(cxD) + 72, y: Int(kbY) - 88,
                      font: Fonts.system(12, weight: .bold), color: Color.textD)
        }
    }

    /// Draw a CGImage upright inside `rect` within the flipped (y-down) context.
    /// `flipX` mirrors it horizontally (for facing left/right).
    private func drawImageUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect,
                                 flipX: Bool = false) {
        ctx.saveGState()
        if flipX {
            ctx.translateBy(x: rect.maxX, y: rect.minY + rect.height)
            ctx.scaleBy(x: -1, y: -1)
        } else {
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - Disk & Network Panel (triple width, split layout)

    /// Merged DISK + NETWORK panel — two columns like the AI AGENTS layout.
    /// Left column: disk usage gauge + capacity bars + read/write I/O.
    /// Right column: network download / upload.
    private func renderDiskNetwork(_ ctx: CGContext, disk: DiskSnapshot,
                                    diskIO: DiskIOSnapshot, network: NetworkSnapshot) {
        let x = Layout.panelX(1)
        let pw = Layout.panelWidth * 3 + Layout.gap * 2
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.cyan)
        Draw.text(ctx, "DISK · NETWORK", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.cyan)

        // Vertical divider between columns
        let midX = x + pw / 2
        Draw.line(ctx, from: CGPoint(x: midX, y: py + 52),
                  to: CGPoint(x: midX, y: py + ph - 14), color: Color.border)

        let colW = pw / 2 - 40

        // --- Left column: DISK ---
        renderDiskColumn(ctx, x: x + 22, w: colW, py: py, ph: ph,
                         disk: disk, diskIO: diskIO)

        // --- Right column: NETWORK ---
        renderNetworkColumn(ctx, x: midX + 18, w: colW, py: py, ph: ph,
                            network: network)
    }

    private func renderDiskColumn(_ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
                                   disk: DiskSnapshot, diskIO: DiskIOSnapshot) {
        let capFont = Fonts.system(16)

        // Column title + total capacity
        Draw.text(ctx, "DISK", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.cyan)
        let totalStr = String(format: "Total: %.0f GB", disk.totalGB)
        let totalW = (totalStr as NSString).size(withAttributes: [.font: capFont]).width
        Draw.text(ctx, totalStr, x: Int(CGFloat(x + w) - totalW), y: py + 56,
                  font: capFont, color: Color.textS)

        // Arc gauge — used %
        let gcx = x + 78
        let gcy = py + 180
        let pct = disk.percent
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 56,
                      percent: pct,
                      color: Color.forPercent(pct),
                      colorDark: Color.forPercentDark(pct), thickness: 12)
        Draw.centeredText(ctx, String(format: "%.0f", pct), cx: gcx, y: gcy - 26,
                          font: Fonts.system(42, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 22,
                          font: Fonts.system(18), color: Color.textS)

        // Used / Free capacity bars — right of gauge
        let capX = x + 165
        let capBarW = w - 175
        let usedPct = disk.totalGB > 0 ? disk.usedGB / disk.totalGB * 100 : 0
        let usedColor = Color.forPercent(usedPct)
        Draw.text(ctx, "Used", x: capX, y: py + 125,
                  font: Fonts.system(16), color: Color.textL)
        let usedValStr = String(format: "%.0f GB", disk.usedGB)
        let usedValW = (usedValStr as NSString).size(withAttributes: [.font: capFont]).width
        Draw.text(ctx, usedValStr,
                  x: Int(CGFloat(capX + capBarW) - usedValW), y: py + 125,
                  font: capFont, color: usedColor)
        Draw.bar(ctx, x: capX, y: py + 148, w: capBarW, h: 9,
                 percent: usedPct, color: usedColor)

        let freePct = disk.totalGB > 0 ? disk.freeGB / disk.totalGB * 100 : 0
        Draw.text(ctx, "Free", x: capX, y: py + 180,
                  font: Fonts.system(16), color: Color.textL)
        let freeValStr = String(format: "%.0f GB", disk.freeGB)
        let freeValW = (freeValStr as NSString).size(withAttributes: [.font: capFont]).width
        Draw.text(ctx, freeValStr,
                  x: Int(CGFloat(capX + capBarW) - freeValW), y: py + 180,
                  font: capFont, color: Color.cyan)
        Draw.bar(ctx, x: capX, y: py + 203, w: capBarW, h: 9,
                 percent: freePct, color: Color.cyan)

        // Read / Write I/O — bottom of column
        let ioY = py + 270
        let halfW = (w - 20) / 2
        let readMB = diskIO.readBytesPerSec / 1_048_576
        let writeMB = diskIO.writeBytesPerSec / 1_048_576

        Draw.text(ctx, "↓ Read", x: x, y: ioY,
                  font: Fonts.system(18), color: Color.green)
        Draw.text(ctx, String(format: "%.1f MB/s", readMB),
                  x: x, y: ioY + 28,
                  font: Fonts.system(30, weight: .bold), color: Color.textW)
        Draw.bar(ctx, x: x, y: ioY + 68, w: halfW, h: 10,
                 percent: min(readMB / 500 * 100, 100), color: Color.green)

        let writeX = x + halfW + 20
        Draw.text(ctx, "↑ Write", x: writeX, y: ioY,
                  font: Fonts.system(18), color: Color.orange)
        Draw.text(ctx, String(format: "%.1f MB/s", writeMB),
                  x: writeX, y: ioY + 28,
                  font: Fonts.system(30, weight: .bold), color: Color.textW)
        Draw.bar(ctx, x: writeX, y: ioY + 68, w: halfW, h: 10,
                 percent: min(writeMB / 500 * 100, 100), color: Color.orange)
    }

    private func renderNetworkColumn(_ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
                                      network: NetworkSnapshot) {
        Draw.text(ctx, "NETWORK", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.magenta)

        let dlKB = network.rxBytesPerSec / 1024
        let ulKB = network.txBytesPerSec / 1024

        // Download — top half
        Draw.text(ctx, "↓ Download", x: x, y: py + 100,
                  font: Fonts.system(20), color: Color.green)
        Draw.text(ctx, String(format: "%.1f", dlKB),
                  x: x, y: py + 130,
                  font: Fonts.system(64, weight: .bold), color: Color.textW)
        Draw.text(ctx, "KB/s", x: x, y: py + 200,
                  font: Fonts.system(20), color: Color.textS)
        Draw.bar(ctx, x: x, y: py + 230, w: w, h: 10,
                 percent: min(dlKB / 256_000 * 100, 100), color: Color.green)

        // Upload — bottom half
        Draw.text(ctx, "↑ Upload", x: x, y: py + 275,
                  font: Fonts.system(20), color: Color.orange)
        Draw.text(ctx, String(format: "%.1f", ulKB),
                  x: x, y: py + 305,
                  font: Fonts.system(64, weight: .bold), color: Color.textW)
        Draw.text(ctx, "KB/s", x: x, y: py + 375,
                  font: Fonts.system(20), color: Color.textS)
        Draw.bar(ctx, x: x, y: py + 405, w: w, h: 10,
                 percent: min(ulKB / 256_000 * 100, 100), color: Color.orange)
    }

    // MARK: - Token Usage Panel (triple width)

    private func formatCount(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1_000_000 { return String(format: v / 1_000_000 < 100 ? "%.1fM" : "%.0fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: v / 1_000 < 100 ? "%.0fK" : "%.0fK", v / 1_000) }
        return "\(n)"
    }

    private func formatCost(_ c: Double) -> String {
        String(format: "$%.2f", c)
    }

    private let tokenCols: [(label: String, width: Int, align: TokenColAlign)] = [
        ("#", 30, .center), ("Model", 300, .left), ("Provider", 120, .left), ("Client", 120, .left),
        ("Input", 95, .right), ("Output", 95, .right), ("Cache R", 105, .right), ("Total", 95, .right), ("Cost", 88, .right),
    ]
    private var tokenColTotalWidth: Int { tokenCols.reduce(0) { $0 + $1.width } }

    private enum TokenColAlign { case left, center, right }

    private func renderTokenUsage(_ ctx: CGContext, tokenUsage: TokenUsageSnapshot) {
        let x = Layout.panelX(1)
        let pw = Layout.panelWidth * 3 + Layout.gap * 2
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.claude)
        Draw.text(ctx, "TOKEN USAGE", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.claude)

        if tokenUsage.processingTimeMs > 0 {
            let ptStr = "\(tokenUsage.processingTimeMs)ms"
            let ptFont = Fonts.system(16)
            let ptW = (ptStr as NSString).size(withAttributes: [.font: ptFont]).width
            Draw.text(ctx, ptStr, x: Int(CGFloat(x + pw - 18) - ptW), y: py + 18,
                      font: ptFont, color: Color.textD)
        }

        if tokenUsage.isEmpty {
            Draw.centeredText(ctx, "No token data",
                              cx: x + pw / 2, y: py + ph / 2 - 20,
                              font: Fonts.system(22), color: Color.textD)
            return
        }

        // Column header row
        let hdrY = py + 58
        let rowTopY = hdrY - 6
        let rowH = 32
        let headerBG = CGPath(roundedRect: CGRect(x: CGFloat(x + 16), y: CGFloat(rowTopY),
                                                   width: CGFloat(pw - 32), height: CGFloat(rowH)),
                              cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.setFillColor(Color.border.copy(alpha: 0.55) ?? Color.border)
        ctx.addPath(headerBG)
        ctx.fillPath()

        let cellFont = Fonts.system(15, weight: .semibold)
        let baseX = x + 22
        for (ci, col) in tokenCols.enumerated() {
            let colX = baseX + tokenCols.prefix(ci).reduce(0) { $0 + $1.width }
            let tx = alignedX(text: col.label, colX: colX, width: col.width, align: col.align, font: cellFont)
            Draw.text(ctx, col.label, x: tx, y: hdrY, font: cellFont, color: Color.textW)
        }

        // Data rows
        let dataFont = Fonts.system(15)
        let contentTop = hdrY + rowH + 6
        let summaryH = 54
        let maxRows = max(1, (ph - contentTop - summaryH - py) / rowH)

        for (i, entry) in tokenUsage.entries.prefix(maxRows).enumerated() {
            let totalTokens = entry.input + entry.output + entry.cacheRead
            let ry = contentTop + i * rowH

            // subtle alternating row background
            if i % 2 == 1 {
                let stripe = CGRect(x: CGFloat(x + 16), y: CGFloat(ry - 5),
                                    width: CGFloat(pw - 32), height: CGFloat(rowH))
                ctx.setFillColor(Color.border.copy(alpha: 0.25) ?? Color.border)
                ctx.fill(stripe)
            }

            let vals: [String] = [
                "\(i + 1)",
                truncate(entry.model, font: dataFont, maxW: CGFloat(tokenCols[1].width - 10)),
                truncate(entry.provider, font: dataFont, maxW: CGFloat(tokenCols[2].width - 10)),
                truncate(entry.client, font: dataFont, maxW: CGFloat(tokenCols[3].width - 10)),
                formatCount(entry.input),
                formatCount(entry.output),
                formatCount(entry.cacheRead),
                formatCount(totalTokens),
                formatCost(entry.cost),
            ]

            for (ci, val) in vals.enumerated() {
                let col = tokenCols[ci]
                let colX = baseX + tokenCols.prefix(ci).reduce(0) { $0 + $1.width }
                let tx = alignedX(text: val, colX: colX, width: col.width, align: col.align, font: dataFont)
                let color: CGColor = ci == 0 ? Color.textL : Color.textW
                Draw.text(ctx, val, x: tx, y: ry, font: dataFont, color: color)
            }
        }

        // Summary bar
        let sumY = py + ph - 44
        Draw.line(ctx, from: CGPoint(x: x + 16, y: sumY - 10),
                  to: CGPoint(x: x + pw - 16, y: sumY - 10), color: Color.border)

        let sumItems: [(label: String, value: String, accent: Bool)] = [
            ("In", formatCount(tokenUsage.totalInput), false),
            ("Out", formatCount(tokenUsage.totalOutput), false),
            ("Cache", formatCount(tokenUsage.totalCacheRead), false),
            ("Msgs", "\(tokenUsage.totalMessages)", false),
            ("Cost", formatCost(tokenUsage.totalCost), true),
        ]
        let sumLabelFont = Fonts.system(16, weight: .medium)
        let sumValueFont = Fonts.system(16, weight: .semibold)
        var sx = x + 22
        let maxSX = x + pw - 22
        let minGap = 28
        for item in sumItems {
            let labelW = ("\(item.label):" as NSString).size(withAttributes: [.font: sumLabelFont]).width
            let valueW = (item.value as NSString).size(withAttributes: [.font: sumValueFont]).width
            let totalW = Int(labelW + 4 + valueW) + minGap
            guard sx + totalW <= maxSX else { break }

            Draw.text(ctx, "\(item.label):", x: sx, y: sumY, font: sumLabelFont, color: Color.textS)
            Draw.text(ctx, item.value, x: sx + Int(labelW) + 4, y: sumY,
                      font: sumValueFont, color: item.accent ? Color.claude : Color.textW)
            sx += totalW
        }
    }

    private func alignedX(text: String, colX: Int, width: Int, align: TokenColAlign, font: NSFont) -> Int {
        let tw = (text as NSString).size(withAttributes: [.font: font]).width
        switch align {
        case .left:   return colX
        case .center: return colX + (width - Int(tw)) / 2
        case .right:  return colX + width - Int(tw) - 6
        }
    }

    // MARK: - AI Agents Panel (triple width)

    private func renderMiddleSlots(_ ctx: CGContext, left: MiddleSlot,
                                   center: MiddleSlot, right: MiddleSlot,
                                   agents: AgentsSnapshot,
                                   disk: DiskSnapshot, diskIO: DiskIOSnapshot,
                                   network: NetworkSnapshot,
                                   tokenUsage: TokenUsageSnapshot,
                                   keyStats: KeyStatsSnapshot,
                                   weather: WeatherSnapshot,
                                   calendarSnapshot: CalendarSnapshot = .empty,
                                   jdStats: JDStatsSnapshot = .unavailable,
                                   codexToken: CodexTokenSnapshot = .loading) {
        let py = Layout.panelY
        let ph = Layout.panelHeight

        let slots = [left, center, right]
        for (offset, slot) in slots.enumerated() {
            let panelX = Layout.panelX(offset + 1)
            Draw.panel(ctx, x: panelX, y: py, w: Layout.panelWidth, h: ph,
                       accent: middleSlotAccent(slot))
            renderMiddleSlot(
                ctx, slot: slot, x: panelX + 20, w: Layout.panelWidth - 40,
                py: py, ph: ph, agents: agents, disk: disk, diskIO: diskIO,
                network: network, tokenUsage: tokenUsage, keyStats: keyStats,
                weather: weather, calendarSnapshot: calendarSnapshot,
                jdStats: jdStats, codexToken: codexToken)
        }
    }

    private func middleSlotAccent(_ slot: MiddleSlot) -> CGColor {
        switch slot {
        case .codex, .disk, .keyStats, .weather, .calendar, .token, .mihomo:
            return Color.cyan
        case .jdAlliance:
            return Color.orange
        case .claude:
            return Color.claude
        case .network:
            return Color.magenta
        }
    }

    private func renderMiddleSlot(_ ctx: CGContext, slot: MiddleSlot,
                                  x: Int, w: Int, py: Int, ph: Int,
                                  agents: AgentsSnapshot, disk: DiskSnapshot,
                                  diskIO: DiskIOSnapshot, network: NetworkSnapshot,
                                  tokenUsage: TokenUsageSnapshot,
                                  keyStats: KeyStatsSnapshot,
                                  weather: WeatherSnapshot,
                                  calendarSnapshot: CalendarSnapshot,
                                  jdStats: JDStatsSnapshot,
                                  codexToken: CodexTokenSnapshot) {
        switch slot {
        case .codex:
            renderAgentColumn(ctx, x: x, w: w, py: py,
                              name: "CODEX", accent: Color.cyan,
                              usage: agents.codex)
        case .claude:
            renderAgentColumn(ctx, x: x, w: w, py: py,
                              name: "CLAUDE", accent: Color.claude,
                              usage: agents.claude)
        case .disk:
            renderDiskColumn(ctx, x: x, w: w, py: py, ph: ph,
                             disk: disk, diskIO: diskIO)
        case .network:
            renderNetworkColumn(ctx, x: x, w: w, py: py, ph: ph,
                                network: network)
        case .weather:
            renderWeatherColumn(
                ctx, x: x, w: w, py: py, ph: ph, weather: weather)
        case .keyStats:
            renderKeyStatsColumn(ctx, x: x, w: w, py: py, ph: ph,
                                 stats: keyStats)
        case .calendar:
            renderCalendarColumn(
                ctx, x: x, w: w, py: py, ph: ph,
                snapshot: calendarSnapshot)
        case .jdAlliance:
            renderJDAllianceColumn(
                ctx, x: x, w: w, py: py, ph: ph, stats: jdStats)
        case .token:
            renderCodexTokenColumn(
                ctx, x: x, w: w, py: py, ph: ph, stats: codexToken,
                liveUsage: agents.codex)
        case .mihomo:
            renderMihomoColumn(
                ctx, x: x, w: w, py: py, ph: ph,
                snapshot: currentMihomoSnapshot())
        }
    }

    private func renderMihomoColumn(
        _ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
        snapshot: MihomoSnapshot
    ) {
        let right = x + w
        Draw.text(
            ctx, "N1 PROXY", x: x, y: py + 14,
            font: Fonts.system(24, weight: .bold), color: Color.cyan)
        drawRightAligned(
            ctx, snapshot.available ? "● 在线" : "● 离线",
            rightX: right, y: py + 18,
            font: Fonts.system(16, weight: .semibold),
            color: snapshot.available ? Color.green : Color.red)

        guard snapshot.available else {
            Draw.centeredText(
                ctx,
                truncate(
                    snapshot.errorMessage, font: Fonts.system(17),
                    maxW: CGFloat(w)),
                cx: x + w / 2, y: py + ph / 2 - 12,
                font: Fonts.system(17), color: Color.textL)
            return
        }

        Draw.text(
            ctx, "\(snapshot.activeConnections)", x: x, y: py + 58,
            font: Fonts.system(58, weight: .bold), color: Color.textW)
        Draw.text(
            ctx, "活动连接", x: x, y: py + 124,
            font: Fonts.system(17, weight: .semibold), color: Color.textL)
        drawRightAligned(
            ctx, formatMihomoBytes(snapshot.memoryBytes),
            rightX: right, y: py + 75,
            font: Fonts.system(26, weight: .bold), color: Color.green)
        drawRightAligned(
            ctx, "内存占用", rightX: right, y: py + 114,
            font: Fonts.system(15), color: Color.textL)

        Draw.line(
            ctx, from: CGPoint(x: x, y: py + 158),
            to: CGPoint(x: right, y: py + 158), color: Color.border)
        let nodeFont = Fonts.system(18, weight: .semibold)
        var nodeY = py + 181
        var nodes: [(String, String, CGColor)] = [
            ("默认节点", snapshot.defaultNode, Color.cyan),
            ("OpenAI", snapshot.openAINode, Color.green),
        ]
        for name in snapshot.ruleNodes where nodes.count < 5 {
            if name != "Default" && name != "OpenAI" {
                nodes.append((name, snapshot.ruleNodeValues[name] ?? "", Color.cyan))
            }
        }
        for (label, value, color) in nodes {
            Draw.text(ctx, label, x: x, y: nodeY,
                      font: Fonts.system(16), color: Color.textL)
            if !value.isEmpty {
                drawRightAligned(ctx,
                    truncate(value, font: nodeFont, maxW: CGFloat(w - 105)),
                    rightX: right, y: nodeY - 3,
                    font: nodeFont, color: color)
            }
            nodeY += 32
        }

        Draw.line(
            ctx, from: CGPoint(x: x, y: py + ph - 118),
            to: CGPoint(x: right, y: py + ph - 118), color: Color.border)
        Draw.text(
            ctx, "↓ \(formatMihomoBytes(snapshot.downloadTotal))",
            x: x, y: py + ph - 92,
            font: Fonts.system(20, weight: .semibold), color: Color.green)
        drawRightAligned(
            ctx, "↑ \(formatMihomoBytes(snapshot.uploadTotal))",
            rightX: right, y: py + ph - 92,
            font: Fonts.system(20, weight: .semibold), color: Color.orange)
        Draw.text(
            ctx, "累计流量", x: x, y: py + ph - 53,
            font: Fonts.system(15), color: Color.textL)
        drawRightAligned(
            ctx,
            "\(snapshot.mode.uppercased()) · \(snapshot.version)",
            rightX: right, y: py + ph - 53,
            font: Fonts.system(15), color: Color.textL)
    }

    private func renderCodexTokenColumn(
        _ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
        stats: CodexTokenSnapshot, liveUsage: AgentUsage
    ) {
        Draw.text(
            ctx, "CODEX TOKEN", x: x, y: py + 14,
            font: Fonts.system(24, weight: .bold), color: Color.cyan)

        // Compact simulated Codex Micro indicator.  Keep this deliberately
        // visual-only: the LCD shows a single LED and no extra label.
        drawCodexStatusLED(ctx, x: x + w - 12, y: py + 27, usage: liveUsage)

        guard stats.available else {
            Draw.centeredText(
                ctx, stats.errorMessage,
                cx: x + w / 2, y: py + ph / 2 - 10,
                font: Fonts.system(18), color: Color.textD)
            return
        }

        let todayTokens = max(stats.todayTokens, liveUsage.todayTotalTokens)
        Draw.text(
            ctx, "今日 Token", x: x, y: py + 55,
            font: Fonts.system(18, weight: .medium), color: Color.textL)
        Draw.text(
            ctx, formatTokensCN(todayTokens), x: x, y: py + 79,
            font: Fonts.system(48, weight: .bold), color: Color.textW)

        let ioFont = Fonts.system(17, weight: .semibold)
        let ioRows: [(String, UInt64)] = [
            ("In", liveUsage.todayInputTokens),
            ("Out", liveUsage.todayOutputTokens),
        ]
        for (index, row) in ioRows.enumerated() {
            let value = formatTokensCN(row.1)
            drawRightAligned(
                ctx, "\(row.0)  \(value)", rightX: x + w,
                y: py + 57 + index * 27,
                font: ioFont, color: Color.textL)
        }

        if let weeklyWindow = stats.secondary ?? stats.primary {
            let remaining = weeklyWindow.remainingPercent ?? 0
            let quotaColor: CGColor = remaining > 50
                ? Color.green : (remaining > 20 ? Color.orange : Color.red)
            Draw.text(
                ctx, String(format: "剩余额度 %.0f%%", remaining),
                x: x, y: py + 133,
                font: Fonts.system(18, weight: .semibold), color: quotaColor)
            if let reset = weeklyWindow.resetsAt {
                drawRightAligned(
                    ctx, codexResetText(reset), rightX: x + w, y: py + 135,
                    font: Fonts.system(14), color: Color.textL)
            }
            Draw.bar(
                ctx, x: x, y: py + 161, w: w, h: 9,
                percent: remaining, color: quotaColor)
        }

        let cards: [(String, String)] = [
            (formatCodexTokenCN(stats.lifetimeTokens), "累计 Token"),
            (formatCodexTokenCN(stats.peakDailyTokens), "峰值 Token"),
        ]
        let cardW = w / 2
        for (index, card) in cards.enumerated() {
            let centerX = x + index * cardW + cardW / 2
            Draw.centeredText(
                ctx, card.0, cx: centerX, y: py + 196,
                font: Fonts.system(25, weight: .semibold), color: Color.textW)
            Draw.centeredText(
                ctx, card.1, cx: centerX, y: py + 226,
                font: Fonts.system(15), color: Color.textL)
            if index > 0 {
                Draw.line(
                    ctx,
                    from: CGPoint(x: x + index * cardW, y: py + 194),
                    to: CGPoint(x: x + index * cardW, y: py + 242),
                    color: Color.border)
            }
        }

        Draw.line(
            ctx, from: CGPoint(x: x, y: py + 254),
            to: CGPoint(x: x + w, y: py + 254), color: Color.border)
        Draw.text(
            ctx, "TOKEN 活动 · 近 18 周", x: x, y: py + 272,
            font: Fonts.system(16, weight: .semibold), color: Color.textL)
        drawRightAligned(
            ctx,
            stats.resetCreditsAvailable.map { "可重置 \($0) 次" } ?? "可重置 --",
            rightX: x + w, y: py + 273,
            font: Fonts.system(15, weight: .semibold), color: Color.orange)
        renderCodexHeatmap(
            ctx, x: x, y: py + 307, w: w,
            dailyTokens: stats.dailyTokens, todayTokens: todayTokens)
    }

    private func renderCodexQuotaRow(
        _ ctx: CGContext, x: Int, w: Int, y: Int,
        window: CodexQuotaWindowSnapshot, labelOverride: String? = nil
    ) {
        let remaining = window.remainingPercent
        let percentText = remaining.map { String(format: "%.0f%%", $0) } ?? "--"
        let color: CGColor
        if let remaining {
            color = remaining > 50
                ? Color.green : (remaining > 20 ? Color.orange : Color.red)
        } else {
            color = Color.textD
        }
        Draw.text(
            ctx, labelOverride ?? window.label, x: x, y: y,
            font: Fonts.system(17, weight: .semibold), color: Color.textW)
        Draw.text(
            ctx, percentText, x: x + 83, y: y,
            font: Fonts.system(17, weight: .bold), color: color)
        if let reset = window.resetsAt {
            drawRightAligned(
                ctx, codexResetText(reset), rightX: x + w, y: y + 1,
                font: Fonts.system(14), color: Color.textL)
        }
        renderSegmentedQuotaBar(
            ctx, x: x, y: y + 31, w: w,
            percent: remaining ?? 0, color: color)
    }

    private func renderSegmentedQuotaBar(
        _ ctx: CGContext, x: Int, y: Int, w: Int,
        percent: Double, color: CGColor
    ) {
        let count = 20
        let gap = 3
        let segmentW = max(2, (w - gap * (count - 1)) / count)
        let filled = Int((max(0, min(100, percent)) / 100 * Double(count)).rounded())
        for index in 0..<count {
            let rect = CGRect(
                x: x + index * (segmentW + gap), y: y,
                width: segmentW, height: 10)
            ctx.setFillColor(index < filled ? color : Color.barBG)
            ctx.addPath(
                CGPath(
                    roundedRect: rect, cornerWidth: 3, cornerHeight: 3,
                    transform: nil))
            ctx.fillPath()
        }
    }

    private func renderCodexHeatmap(
        _ ctx: CGContext, x: Int, y: Int, w: Int,
        dailyTokens: [String: UInt64], todayTokens: UInt64
    ) {
        let columns = 18
        let rows = 7
        let gap = 3
        let cell = min(15, (w - gap * (columns - 1)) / columns)
        let gridWidth = columns * cell + (columns - 1) * gap
        let startX = x + max(0, (w - gridWidth) / 2)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        let firstDay = calendar.date(
            byAdding: .day,
            value: -(columns - 1) * rows - weekday,
            to: today) ?? today
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var values = dailyTokens
        values[formatter.string(from: today)] = max(
            values[formatter.string(from: today)] ?? 0, todayTokens)
        let peak = max(UInt64(1), values.values.max() ?? 1)

        for column in 0..<columns {
            for row in 0..<rows {
                guard let date = calendar.date(
                    byAdding: .day, value: column * rows + row,
                    to: firstDay), date <= today else { continue }
                let value = values[formatter.string(from: date)] ?? 0
                let color: CGColor
                if value == 0 {
                    color = Color.barBG
                } else {
                    let ratio = sqrt(Double(value) / Double(peak))
                    color = Color.cyan.copy(
                        alpha: CGFloat(0.22 + ratio * 0.78)) ?? Color.cyan
                }
                let rect = CGRect(
                    x: startX + column * (cell + gap),
                    y: y + row * (cell + gap),
                    width: cell, height: cell)
                ctx.setFillColor(color)
                ctx.addPath(
                    CGPath(
                        roundedRect: rect, cornerWidth: 3, cornerHeight: 3,
                        transform: nil))
                ctx.fillPath()
            }
        }
    }

    private func drawRightAligned(
        _ ctx: CGContext, _ text: String, rightX: Int, y: Int,
        font: NSFont, color: CGColor
    ) {
        let width = (text as NSString).size(
            withAttributes: [.font: font]).width
        Draw.text(
            ctx, text, x: Int(CGFloat(rightX) - width), y: y,
            font: font, color: color)
    }

    private func codexResetText(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds >= 86400 {
            return "\(seconds / 86400)天\(seconds % 86400 / 3600)小时后"
        }
        if seconds >= 3600 {
            return "\(seconds / 3600)小时\(seconds % 3600 / 60)分后"
        }
        return "\(max(1, seconds / 60))分钟后"
    }

    private func formatCodexTokenCount(_ value: UInt64) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.2fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func formatCodexTokenCN(_ value: UInt64) -> String {
        if value >= 100_000_000 {
            return String(format: "%.2f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        return "\(value)"
    }

    private func formatCodexDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600)时\(seconds % 3600 / 60)分"
        }
        if seconds >= 60 {
            return "\(seconds / 60)分\(seconds % 60)秒"
        }
        return "\(seconds)秒"
    }

    private func renderJDAllianceColumn(
        _ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
        stats: JDStatsSnapshot
    ) {
        Draw.text(ctx, "JD ALLIANCE", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.orange)

        guard stats.available else {
            Draw.centeredText(
                ctx, stats.errorMessage,
                cx: x + w / 2, y: py + ph / 2 - 10,
                font: Fonts.system(17), color: Color.textD)
            return
        }

        let periods: [(String, JDPeriodStats)] = [
            ("今日", stats.day),
            ("本周", stats.week),
            ("本月", stats.month),
            ("本年", stats.year),
        ]
        let labelFont = Fonts.system(17, weight: .semibold)
        let valueFont = Fonts.system(20, weight: .bold)
        let startY = py + 75
        let rowH = 91
        for (index, item) in periods.enumerated() {
            let y = startY + index * rowH
            Draw.text(
                ctx, item.0, x: x, y: y,
                font: labelFont, color: index == 0 ? Color.orange : Color.textL)
            let orderText = "\(item.1.orders) 单"
            let orderWidth = (orderText as NSString).size(
                withAttributes: [.font: valueFont]).width
            Draw.text(
                ctx, orderText,
                x: Int(CGFloat(x + w) - orderWidth), y: y - 2,
                font: valueFont, color: Color.textW)

            Draw.text(
                ctx, "销售 \(formatJDMoney(item.1.estimatedSales))",
                x: x, y: y + 31, font: Fonts.system(16), color: Color.cyan)
            let feeText = "佣金 \(formatJDMoney(item.1.estimatedCommission))"
            let feeFont = Fonts.system(16, weight: .semibold)
            let feeWidth = (feeText as NSString).size(
                withAttributes: [.font: feeFont]).width
            Draw.text(
                ctx, feeText,
                x: Int(CGFloat(x + w) - feeWidth), y: y + 31,
                font: feeFont, color: Color.green)
            if index < periods.count - 1 {
                Draw.line(
                    ctx, from: CGPoint(x: x, y: y + 66),
                    to: CGPoint(x: x + w, y: y + 66), color: Color.border)
            }
        }

        Draw.text(
            ctx, "结算后自动更新实际金额",
            x: x, y: py + ph - 31,
            font: Fonts.system(14), color: Color.textD)
    }

    private func formatJDMoney(_ value: Double) -> String {
        if abs(value) >= 10_000 {
            return String(format: "¥%.1f万", value / 10_000)
        }
        return String(format: "¥%.2f", value)
    }

    private func renderCalendarColumn(
        _ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
        snapshot: CalendarSnapshot
    ) {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents(
            [.year, .month, .day, .weekday], from: now)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let today = components.day ?? 0

        Draw.text(ctx, "CALENDAR", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.cyan)
        Draw.text(ctx, "\(year) 年 \(month) 月", x: x, y: py + 58,
                  font: Fonts.system(31, weight: .bold), color: Color.textW)
        Draw.text(ctx, "今天 · \(today) 日", x: x, y: py + 101,
                  font: Fonts.system(18, weight: .medium), color: Color.green)

        guard let monthStart = calendar.date(
            from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
        else { return }

        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let cellW = w / 7
        let headerY = py + 143
        for (column, label) in weekdays.enumerated() {
            Draw.centeredText(
                ctx, label, cx: x + column * cellW + cellW / 2, y: headerY,
                font: Fonts.system(17, weight: .semibold),
                color: column == 0 || column == 6 ? Color.orange : Color.textL)
        }
        Draw.line(
            ctx, from: CGPoint(x: x, y: py + 173),
            to: CGPoint(x: x + w, y: py + 173), color: Color.border)

        let firstWeekday =
            calendar.component(.weekday, from: monthStart) - 1
        let eventDays = Set(snapshot.events.compactMap { event -> Int? in
            let values = calendar.dateComponents([.year, .month, .day], from: event.date)
            return values.year == year && values.month == month ? values.day : nil
        })
        let rowH = 34
        for day in dayRange {
            let index = firstWeekday + day - 1
            let column = index % 7
            let row = index / 7
            let centerX = x + column * cellW + cellW / 2
            let cellY = py + 184 + row * rowH

            if day == today {
                ctx.setFillColor(Color.cyanD)
                ctx.fillEllipse(
                    in: CGRect(
                        x: centerX - 17, y: cellY - 4,
                        width: 34, height: 34))
            }
            Draw.centeredText(
                ctx, "\(day)", cx: centerX, y: cellY,
                font: Fonts.system(
                    19, weight: day == today ? .bold : .medium),
                color: day == today
                    ? Color.cyan
                    : (column == 0 || column == 6 ? Color.orange : Color.textW))
            if eventDays.contains(day) && day != today {
                ctx.setFillColor(Color.green)
                ctx.fillEllipse(
                    in: CGRect(
                        x: centerX - 2, y: cellY + 25,
                        width: 4, height: 4))
            }
        }

        let upcoming = snapshot.events.filter {
            calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: now)
        }.prefix(2)
        var eventY = py + 396
        if !snapshot.subscriptionConfigured {
            Draw.text(
                ctx, "可在设置中添加节假日 .ics 订阅",
                x: x, y: eventY, font: Fonts.system(15), color: Color.textL)
        }
        for event in upcoming {
            let dc = calendar.dateComponents([.month, .day], from: event.date)
            let label = "\(dc.month ?? 0)/\(dc.day ?? 0)  \(event.title)"
            Draw.text(
                ctx, truncate(label, font: Fonts.system(16), maxW: CGFloat(w)),
                x: x, y: eventY, font: Fonts.system(16), color: Color.green)
            eventY += 25
        }
    }

    private func renderTokenColumn(_ ctx: CGContext, x: Int, w: Int,
                                   py: Int, ph: Int,
                                   tokenUsage: TokenUsageSnapshot) {
        Draw.text(ctx, "TOKEN USAGE", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.claude)

        if tokenUsage.isEmpty {
            Draw.centeredText(ctx, "No token data",
                              cx: x + w / 2, y: py + ph / 2,
                              font: Fonts.system(20), color: Color.textD)
            return
        }

        let total = tokenUsage.totalInput + tokenUsage.totalOutput
            + tokenUsage.totalCacheRead
        Draw.text(ctx, "Today", x: x, y: py + 98,
                  font: Fonts.system(18), color: Color.textL)
        Draw.text(ctx, formatCount(total), x: x, y: py + 126,
                  font: Fonts.system(54, weight: .bold), color: Color.textW)

        let rows: [(String, String, CGColor)] = [
            ("Input", formatCount(tokenUsage.totalInput), Color.cyan),
            ("Output", formatCount(tokenUsage.totalOutput), Color.green),
            ("Cache", formatCount(tokenUsage.totalCacheRead), Color.purple),
            ("Messages", "\(tokenUsage.totalMessages)", Color.textW),
            ("Cost", formatCost(tokenUsage.totalCost), Color.claude),
        ]
        var y = py + 215
        for row in rows {
            Draw.text(ctx, row.0, x: x, y: y,
                      font: Fonts.system(19), color: Color.textL)
            let valueFont = Fonts.system(24, weight: .semibold)
            let valueW = (row.1 as NSString).size(
                withAttributes: [.font: valueFont]).width
            Draw.text(ctx, row.1, x: Int(CGFloat(x + w) - valueW), y: y - 3,
                      font: valueFont, color: row.2)
            y += 45
        }
    }

    private func renderWeatherColumn(
        _ ctx: CGContext, x: Int, w: Int, py: Int, ph: Int,
        weather: WeatherSnapshot
    ) {
        Draw.text(ctx, "WEATHER", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.cyan)

        guard weather.available else {
            Draw.centeredText(ctx, "请在设置中填写彩云天气 Token",
                              cx: x + w / 2, y: py + ph / 2 - 10,
                              font: Fonts.system(18), color: Color.textD)
            return
        }

        Draw.text(ctx, weather.city, x: x, y: py + 62,
                  font: Fonts.system(18, weight: .medium), color: Color.textL)
        Draw.text(ctx, String(format: "%.0f°", weather.temperature),
                  x: x, y: py + 90,
                  font: Fonts.system(58, weight: .bold), color: Color.textW)
        Draw.text(ctx, weather.icon, x: x + w - 88, y: py + 78,
                  font: Fonts.system(72), color: Color.orange)
        let conditionLine = weather.airQuality.isEmpty
            ? weather.condition
            : "\(weather.condition) · \(weather.airQuality)"
        Draw.text(ctx, conditionLine, x: x, y: py + 158,
                  font: Fonts.system(24, weight: .semibold), color: Color.cyan)
        Draw.text(
            ctx,
            String(
                format: "体感 %.0f°   湿度 %d%%   风 %.1f",
                weather.apparentTemperature, weather.humidity,
                weather.windSpeed),
            x: x, y: py + 194,
            font: Fonts.system(16), color: Color.textL)

        let rainFont = Fonts.system(15, weight: .medium)
        Draw.text(
            ctx,
            truncate(
                "降雨：\(weather.rainForecast)",
                font: rainFont, maxW: CGFloat(w)),
            x: x, y: py + 222, font: rainFont, color: Color.green)

        var rowY = py + 252
        for (index, forecast) in weather.daily.prefix(7).enumerated() {
            let day = index == 0 ? "今天" : forecast.day
            Draw.text(ctx, day, x: x, y: rowY,
                      font: Fonts.system(17, weight: .medium),
                      color: index == 0 ? Color.cyan : Color.textL)
            Draw.text(ctx, forecast.icon, x: x + 78, y: rowY - 3,
                      font: Fonts.system(24), color: Color.orange)
            let temperatures = String(
                format: "%.0f° / %.0f°",
                forecast.highTemperature, forecast.lowTemperature)
            let temperatureFont = Fonts.system(18, weight: .semibold)
            let temperatureWidth = (temperatures as NSString).size(
                withAttributes: [.font: temperatureFont]).width
            Draw.text(
                ctx, temperatures,
                x: Int(CGFloat(x + w) - temperatureWidth), y: rowY,
                font: temperatureFont, color: Color.textW)
            rowY += 30
        }
    }

    private func renderKeyStatsColumn(_ ctx: CGContext, x: Int, w: Int,
                                      py: Int, ph: Int,
                                      stats: KeyStatsSnapshot) {
        Draw.text(ctx, "KEY STATS", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.cyan)

        guard stats.available else {
            Draw.centeredText(ctx, "请先运行 keyStats",
                              cx: x + w / 2, y: py + ph / 2 - 16,
                              font: Fonts.system(20), color: Color.textD)
            Draw.centeredText(ctx, "MacTR 将自动读取今日统计",
                              cx: x + w / 2, y: py + ph / 2 + 18,
                              font: Fonts.system(16), color: Color.textL)
            return
        }

        Draw.text(ctx, "⌨  Key Presses", x: x, y: py + 78,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, formatCompact(stats.keyPresses), x: x, y: py + 108,
                  font: Fonts.system(54, weight: .bold), color: Color.textW)

        let clickX = x + w / 2 + 10
        Draw.text(ctx, "●  Clicks", x: clickX, y: py + 78,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, formatCompact(stats.totalClicks),
                  x: clickX, y: py + 108,
                  font: Fonts.system(54, weight: .bold), color: Color.green)

        Draw.line(ctx, from: CGPoint(x: x, y: py + 184),
                  to: CGPoint(x: x + w, y: py + 184), color: Color.border)

        let distance = formatDistance(stats.mouseDistanceMeters)
        let scroll = formatScroll(stats.scrollDistancePixels)
        let rows: [(String, String, CGColor)] = [
            ("Mouse movement", distance, Color.cyan),
            ("Scroll", scroll, Color.purple),
            ("Left / Right", "\(formatCompact(stats.leftClicks)) / \(formatCompact(stats.rightClicks))", Color.textW),
            ("Peak KPS", "\(stats.peakKPS)", Color.orange),
            ("Peak CPS", "\(stats.peakCPS)", Color.green),
        ]

        var y = py + 215
        for row in rows {
            Draw.text(ctx, row.0, x: x, y: y,
                      font: Fonts.system(18), color: Color.textL)
            let valueFont = Fonts.system(22, weight: .semibold)
            let valueW = (row.1 as NSString).size(
                withAttributes: [.font: valueFont]).width
            Draw.text(ctx, row.1, x: Int(CGFloat(x + w) - valueW), y: y - 2,
                      font: valueFont, color: row.2)
            y += 43
        }
    }

    private func formatCompact(_ value: Int) -> String {
        let n = Double(max(0, value))
        if n >= 1_000_000 {
            return String(format: n < 10_000_000 ? "%.2fM" : "%.1fM",
                          n / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: n < 100_000 ? "%.1fK" : "%.0fK",
                          n / 1_000)
        }
        return "\(value)"
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.2f km", meters / 1_000)
        }
        if meters >= 1 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.0f cm", meters * 100)
    }

    private func formatScroll(_ pixels: Double) -> String {
        if pixels >= 1_000_000 {
            return String(format: "%.2f MPx", pixels / 1_000_000)
        }
        if pixels >= 1_000 {
            return String(format: "%.1f kPx", pixels / 1_000)
        }
        return String(format: "%.0f px", pixels)
    }

    private func renderAgents(_ ctx: CGContext, agents: AgentsSnapshot) {
        let x = Layout.panelX(1)
        let pw = Layout.panelWidth * 3 + Layout.gap * 2
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.purple)
        Draw.text(ctx, "AI AGENTS", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.purple)

        // Vertical divider between columns
        let midX = x + pw / 2
        Draw.line(ctx, from: CGPoint(x: midX, y: py + 52),
                  to: CGPoint(x: midX, y: py + ph - 14), color: Color.border)

        let colW = pw / 2 - 40
        renderAgentColumn(ctx, x: x + 22, w: colW, py: py,
                          name: "CLAUDE", accent: Color.claude, usage: agents.claude)
        renderAgentColumn(ctx, x: midX + 18, w: colW, py: py,
                          name: "CODEX", accent: Color.cyan, usage: agents.codex)
    }

    private func renderAgentColumn(
        _ ctx: CGContext, x: Int, w: Int, py: Int,
        name: String, accent: CGColor, usage: AgentUsage,
        drawsTintedBackground: Bool = true
    ) {
        let ph = Layout.panelHeight

        // Column background — three states, agent-tinted:
        //   needsAttention (done / waiting) → hard on/off blink (high-contrast alert)
        //   isWorking      (running a turn)  → slow, gentle breathing (~5s period)
        //   idle                            → static tint
        // render() runs every 0.5s, smooth enough for both sin() and the blink.
        let bgRect = CGRect(x: CGFloat(x - 12), y: CGFloat(py + 42),
                            width: CGFloat(w + 24), height: CGFloat(ph - 56))
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 12, cornerHeight: 12,
                            transform: nil)
        let base: CGFloat = name == "CLAUDE" ? 0.09 : 0.08
        let t = Date().timeIntervalSince1970
        let blinkOn = Int(t * 2) % 2 == 0
        // Linear triangle breathing (0→1→0 over 5s). A constant per-frame delta reads
        // far smoother than cosine easing at the display's low frame rate — no stutter
        // where the cosine flattens near its peaks/troughs.
        let phase = t.truncatingRemainder(dividingBy: 5) / 5        // 0..1
        let breath = CGFloat(phase < 0.5 ? phase * 2 : (1 - phase) * 2)
        var bgAlpha = base
        if usage.needsAttention {
            bgAlpha = blinkOn ? 0.36 : 0.10
        } else if usage.isWorking {
            bgAlpha = base + 0.13 * breath
        }
        if drawsTintedBackground {
            ctx.setFillColor(accent.copy(alpha: bgAlpha) ?? accent)
            ctx.addPath(bgPath)
            ctx.fillPath()
            if usage.needsAttention {
                ctx.setStrokeColor(
                    accent.copy(alpha: blinkOn ? 0.9 : 0.25) ?? accent)
                ctx.setLineWidth(2)
                ctx.addPath(bgPath)
                ctx.strokePath()
            } else if usage.isWorking {
                // Faint breathing border to reinforce the "alive/working" feel
                ctx.setStrokeColor(
                    accent.copy(alpha: 0.12 + 0.28 * breath) ?? accent)
                ctx.setLineWidth(1.5)
                ctx.addPath(bgPath)
                ctx.strokePath()
            }
        }

        // Header: name + activity indicator (right-aligned "● now" / "12m ago")
        Draw.text(ctx, name, x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: accent)
        let active = (usage.secondsSinceActive ?? Int.max) < 90
        let agoStr: String
        if !usage.available {
            agoStr = "not found"
        } else if let s = usage.secondsSinceActive {
            agoStr = active ? "now"
                : (s < 3600 ? "\(s / 60)m ago"
                   : (s < 86400 ? "\(s / 3600)h ago" : "\(s / 86400)d ago"))
        } else {
            agoStr = "no session"
        }
        let agoFont = Fonts.system(17, weight: .medium)
        let agoColor = active ? Color.green : Color.textD
        let agoW = (agoStr as NSString).size(withAttributes: [.font: agoFont]).width
        Draw.text(ctx, agoStr, x: Int(CGFloat(x + w) - agoW), y: py + 20,
                  font: agoFont, color: agoColor)
        let dotR: CGFloat = 5
        ctx.setFillColor(agoColor)
        ctx.fillEllipse(in: CGRect(x: CGFloat(x + w) - agoW - dotR * 2 - 8,
                                   y: CGFloat(py + 20) + 10 - dotR,
                                   width: dotR * 2, height: dotR * 2))

        // Current session — TOP. Project (+ step badge), plan progress, live activity.
        var y = py + 90
        if let project = usage.project {
            // Step badge "步骤 4/6" right-aligned on the project line, when a plan exists
            var projMaxW = CGFloat(w)
            if let cur = usage.stepCurrent, let total = usage.stepTotal {
                let badge = "步骤 \(cur)/\(total)"
                let bFont = Fonts.system(18, weight: .semibold)
                let bW = (badge as NSString).size(withAttributes: [.font: bFont]).width
                Draw.text(ctx, badge, x: Int(CGFloat(x + w) - bW), y: y + 4,
                          font: bFont, color: accent)
                projMaxW = CGFloat(w) - bW - 16
            }
            Draw.text(ctx, truncate(project, font: Fonts.system(26, weight: .semibold),
                                    maxW: projMaxW),
                      x: x, y: y, font: Fonts.system(26, weight: .semibold), color: Color.textW)
            y += 38
        }

        // Plan progress — compact segmented bar (the badge conveys N/M; no text line,
        // so the message below gets the room)
        if let cur = usage.stepCurrent, let total = usage.stepTotal, total > 0 {
            drawStepBar(ctx, x: x, y: y, w: w, current: cur, total: total, accent: accent)
            y += 20
        }

        // Latest message — what the agent last said (never the commands it ran).
        // Markdown tables/lists are laid out structurally; plain text just wraps.
        let actText = usage.activity ?? (usage.available ? "空闲" : "—")
        let msgBottom = py + ph - 140   // token divider sits here
        renderMessage(ctx, text: actText, x: x, y: y, w: w, bottom: msgBottom, accent: accent)

        // Token usage — large, anchored near the bottom of the column
        let tokY = py + ph - 126
        Draw.line(ctx, from: CGPoint(x: x, y: tokY - 12),
                  to: CGPoint(x: x + w, y: tokY - 12), color: Color.border)
        Draw.text(ctx, "今日 Token", x: x, y: tokY,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, formatTokensCN(usage.todayTotalTokens), x: x, y: tokY + 24,
                  font: Fonts.system(46, weight: .bold), color: Color.textW)

        // In / Out — right-aligned, level with the label + big number
        let ioFont = Fonts.system(20, weight: .medium)
        let ioRows: [(String, UInt64)] = [
            ("In", usage.todayInputTokens),
            ("Out", usage.todayOutputTokens),
        ]
        for (i, row) in ioRows.enumerated() {
            let ry = tokY + 6 + i * 30
            let valStr = formatTokensCN(row.1)
            let valW = (valStr as NSString).size(withAttributes: [.font: ioFont]).width
            Draw.text(ctx, valStr, x: Int(CGFloat(x + w) - valW), y: ry,
                      font: ioFont, color: Color.textS)
            let labelW = (row.0 as NSString).size(withAttributes: [.font: ioFont]).width
            Draw.text(ctx, row.0, x: Int(CGFloat(x + w) - valW - labelW - 10), y: ry,
                      font: ioFont, color: Color.textL)
        }

        // Quota (Codex): remaining percentage + reset countdown + bar
        if let used = usage.quotaUsedPercent {
            let remaining = max(0, 100 - used)
            let qColor: CGColor = remaining > 50 ? Color.green
                : (remaining > 20 ? Color.orange : Color.red)
            let qy = tokY + 78
            Draw.text(ctx, String(format: "剩余额度 %.0f%%", remaining), x: x, y: qy,
                      font: Fonts.system(21, weight: .medium), color: qColor)
            if let resets = usage.quotaResetsAt {
                let secs = max(0, Int(resets.timeIntervalSinceNow))
                let resetStr = secs >= 86400 ? "\(secs / 86400)天后重置"
                    : (secs >= 3600 ? "\(secs / 3600)小时后重置" : "\(max(secs / 60, 1))分钟后重置")
                let rFont = Fonts.system(17)
                let rW = (resetStr as NSString).size(withAttributes: [.font: rFont]).width
                Draw.text(ctx, resetStr, x: Int(CGFloat(x + w) - rW), y: qy + 3,
                          font: rFont, color: Color.textD)
            }
            Draw.bar(ctx, x: x, y: qy + 28, w: w, h: 8,
                     percent: remaining, color: qColor)
        }
    }

    /// Segmented plan-progress bar: completed steps solid, current bright, pending dim.
    private func drawStepBar(_ ctx: CGContext, x: Int, y: Int, w: Int,
                             current: Int, total: Int, accent: CGColor) {
        guard total > 0 else { return }
        let gap = 4
        let segW = (w - gap * (total - 1)) / total
        guard segW > 0 else { return }
        for i in 0..<total {
            let sx = x + i * (segW + gap)
            let color: CGColor
            if i < current - 1 {          // completed
                color = accent.copy(alpha: 0.5) ?? accent
            } else if i == current - 1 {  // current
                color = accent
            } else {                      // pending
                color = Color.barBG
            }
            let rect = CGRect(x: CGFloat(sx), y: CGFloat(y), width: CGFloat(segW), height: 7)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
        }
    }

    /// 中文数量格式："33.99万"、"1.02亿"。1万以下显示原始数字。
    private func formatTokensCN(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1e8 {
            let y = v / 1e8
            return String(format: y < 100 ? "%.2f亿" : "%.1f亿", y)
        }
        if v >= 1e4 {
            let w = v / 1e4
            return String(format: w < 100 ? "%.2f万" : (w < 1000 ? "%.1f万" : "%.0f万"), w)
        }
        return "\(n)"
    }

    // MARK: - Agent message layout (markdown-aware)

    /// Render an agent message top-down within [y, bottom): markdown tables become
    /// aligned grids, `- ` bullets and prose wrap. Stops when vertical space runs out.
    private func renderMessage(_ ctx: CGContext, text: String, x: Int, y: Int, w: Int,
                               bottom: Int, accent: CGColor) {
        let proseFont = Fonts.system(19)
        let lineH = 26
        var cy = y
        let raw = text.components(separatedBy: "\n")
        var i = 0
        while i < raw.count && cy + 20 <= bottom {
            let line = raw[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }

            if isTableLine(line) {
                // Consume the contiguous run of table rows and render as a grid
                var block: [String] = []
                while i < raw.count && isTableLine(raw[i].trimmingCharacters(in: .whitespaces)) {
                    block.append(raw[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                cy = renderTable(ctx, rows: block, x: x, y: cy, w: w, bottom: bottom, accent: accent)
            } else {
                // Prose / bullet — wrap, but cap each block so a table below still fits
                let remaining = (bottom - cy) / lineH
                guard remaining > 0 else { break }
                let wrapped = wrap(stripMarkdown(line), font: proseFont,
                                   maxW: CGFloat(w), maxLines: min(2, remaining))
                for wl in wrapped {
                    if cy + lineH > bottom { break }
                    Draw.text(ctx, wl, x: x, y: cy, font: proseFont, color: Color.textS)
                    cy += lineH
                }
                i += 1
            }
        }
    }

    private func isTableLine(_ s: String) -> Bool {
        s.hasPrefix("|") && s.filter { $0 == "|" }.count >= 2
    }

    /// A markdown separator cell like `---`, `:--`, `--:`, `:-:`.
    private func isSeparatorCell(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" } && s.contains("-")
    }

    private func stripMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
    }

    /// Render markdown table rows as an aligned grid. Returns the new y below it.
    private func renderTable(_ ctx: CGContext, rows rawRows: [String], x: Int, y: Int,
                             w: Int, bottom: Int, accent: CGColor) -> Int {
        // Parse into cell rows, dropping the separator row and empty edge cells
        var rows: [[String]] = []
        for line in rawRows {
            var cells = line.components(separatedBy: "|").map {
                stripMarkdown($0.trimmingCharacters(in: .whitespaces))
            }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            if cells.allSatisfy({ isSeparatorCell($0) }) { continue }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return y }

        let cols = rows.map(\.count).max() ?? 1
        let rowH = 24
        let colGap = 8
        let colW = (w - colGap * (cols - 1)) / max(cols, 1)
        guard colW > 20 else { return y }
        let cellFont = Fonts.system(16)
        let headFont = Fonts.system(16, weight: .semibold)

        var cy = y + 2
        for (ri, row) in rows.enumerated() {
            if cy + rowH > bottom { break }
            for ci in 0..<cols {
                let cell = ci < row.count ? row[ci] : ""
                if cell.isEmpty { continue }
                let cx = x + ci * (colW + colGap)
                let font = ri == 0 ? headFont : cellFont
                let color = ri == 0 ? accent : Color.textS
                Draw.text(ctx, truncate(cell, font: font, maxW: CGFloat(colW)),
                          x: cx, y: cy, font: font, color: color)
            }
            cy += rowH
            if ri == 0 {  // underline under the header row
                Draw.line(ctx, from: CGPoint(x: x, y: cy - 4),
                          to: CGPoint(x: x + w, y: cy - 4), color: Color.border)
            }
        }
        return cy + 4
    }

    /// Truncate a single line with "…" to fit maxW.
    private func truncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= maxW { return s }
        var t = s
        while !t.isEmpty {
            t.removeLast()
            if ((t + "…") as NSString).size(withAttributes: attrs).width <= maxW {
                return t + "…"
            }
        }
        return "…"
    }

    /// Greedy character wrap (activity text may be CJK — no word boundaries).
    private func wrap(_ s: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        guard maxLines >= 1 else { return [] }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var lines: [String] = []
        var current = ""
        for ch in s {
            let candidate = current + String(ch)
            if (candidate as NSString).size(withAttributes: attrs).width > maxW {
                // Reached the last allowed line → fold the whole remainder into it
                if lines.count == maxLines - 1 {
                    let rest = String(s[s.index(s.startIndex, offsetBy: lines.joined().count)...])
                    lines.append(truncate(rest, font: font, maxW: maxW))
                    return lines
                }
                lines.append(current)
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

}
