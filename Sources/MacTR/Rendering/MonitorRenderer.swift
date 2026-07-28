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
    private let keyStatsCollector = KeyStatsCollector()

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

    // User-selected fixed middle panel
    private let panelLock = NSLock()
    private var middleLeft: MiddleSlot = .codex
    private var middleCenter: MiddleSlot = .disk
    private var middleRight: MiddleSlot = .network

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?

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
        // KeyStats is a background accumulator. Keep it running for the whole
        // app session so opening its panel later shows the complete day rather
        // than only activity recorded while the panel was visible.
        keyStatsCollector.start(requestPermission: true)
        // First pass: prime CPU ticks (deltas will be zero)
        let cpu0 = collector.collectCPU()
        let mem = collector.collectMemory()
        let temp = collector.collectTemperature()
        let agents = agentCollector.collect()
        let sys = collector.collectSystem()
        let disk = collector.collectDisk()
        let diskIO = collector.collectDiskIO()
        let network = collector.collectNetwork()
        let keyStats = keyStatsCollector.collect()
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
        keyStatsCollector.stop()
    }

    func setMiddleSlots(left: MiddleSlot, center: MiddleSlot, right: MiddleSlot) {
        panelLock.lock()
        middleLeft = left
        middleCenter = center
        middleRight = right
        panelLock.unlock()
    }

    private func selectedMiddleSlots() -> (MiddleSlot, MiddleSlot, MiddleSlot) {
        panelLock.lock()
        defer { panelLock.unlock() }
        return (middleLeft, middleCenter, middleRight)
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
        while metricsRunning {
            // Fast metrics every tick
            let cpu = collector.collectCPU()
            let mem = collector.collectMemory()
            let keyStats = keyStatsCollector.collect()
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
        Draw.gradientBackground(ctx)
        renderCPU(ctx, cpu: cpu, temp: temp, agentsBusy: true)
        let slots = selectedMiddleSlots()
        renderMiddleSlots(ctx, left: slots.0, center: slots.1,
                          right: slots.2, agents: agents,
                          disk: disk, diskIO: diskIO, network: network,
                          tokenUsage: tokenUsage, keyStats: .demo)
        renderMemory(ctx, mem: mem, sys: sys, agentsBusy: true)
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
        if demoMode {
            (cpu, mem, temp, sys, agents, disk, diskIO, network, tokenUsage) = demoData()
            keyStats = .demo
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

        // Reset transform and clear for new frame
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Background
        Draw.gradientBackground(ctx)

        // Panels
        let slots = selectedMiddleSlots()
        let codexVisible =
            slots.0 == .codex || slots.1 == .codex || slots.2 == .codex
        let claudeVisible =
            slots.0 == .claude || slots.1 == .claude || slots.2 == .claude
        let agentsBusy =
            (codexVisible && (agents.codex.isWorking || agents.codex.needsAttention))
            || (claudeVisible && (agents.claude.isWorking || agents.claude.needsAttention))
        renderCPU(ctx, cpu: cpu, temp: temp, agentsBusy: agentsBusy)

        renderMiddleSlots(ctx, left: slots.0, center: slots.1,
                          right: slots.2, agents: agents,
                          disk: disk, diskIO: diskIO, network: network,
                          tokenUsage: tokenUsage, keyStats: keyStats)

        renderMemory(ctx, mem: mem, sys: sys, agentsBusy: agentsBusy)

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
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

        let pCoreCount = cpu.pCoreCount
        let eCoreCount = coreCount - pCoreCount

        // Reorder: E-cores first, then P-cores
        for row in 0..<coreCount {
            let by = startY + row * spacing
            if by + Int(fontSize) > bottomLimit { break }

            let coreIndex: Int
            let isECore: Bool
            let label: String
            if row < eCoreCount {
                // E-core rows first
                coreIndex = pCoreCount + row
                isECore = true
                label = "E\(row + 1)"
            } else {
                // P-core rows after
                coreIndex = row - eCoreCount
                isECore = false
                label = "P\(row - eCoreCount + 1)"
            }

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
                              agentsBusy: Bool) {
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

        // Bottom: a Bongo Cat tapping the divider "table", then the clock below it.
        // (Swap monitoring removed — this space now shows the date/time.)
        let ph = Layout.panelHeight
        let dividerY = py + ph - 116
        let cx0 = x + 16
        let cw = pw - 32
        Draw.line(ctx, from: CGPoint(x: cx0, y: dividerY),
                  to: CGPoint(x: cx0 + cw, y: dividerY), color: Color.border)

        // Bongo cat sits on the left, tapping the divider when an agent is busy
        let t = Date().timeIntervalSince1970
        let tapPhase = Int(t * 5) % 2 == 0
        drawBongoCat(ctx, cx: x + 96, baseY: dividerY, tapping: agentsBusy, phase: tapPhase)

        // Right of the cat: date, weekday, uptime, processes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let ix = x + 190
        formatter.dateFormat = "yyyy-MM-dd"
        Draw.text(ctx, formatter.string(from: Date()), x: ix, y: py + ph - 196,
                  font: Fonts.system(22, weight: .semibold), color: Color.textW)
        formatter.dateFormat = "EEEE"
        Draw.text(ctx, formatter.string(from: Date()), x: ix, y: py + ph - 170,
                  font: Fonts.system(16), color: Color.textS)

        let iw = pw - (ix - x) - 16
        func stat(_ label: String, _ value: String, _ sy: Int) {
            Draw.text(ctx, label, x: ix, y: sy, font: Fonts.system(15), color: Color.textL)
            let vf = Fonts.system(15, weight: .medium)
            let vw = (value as NSString).size(withAttributes: [.font: vf]).width
            Draw.text(ctx, value, x: Int(CGFloat(ix + iw) - vw), y: sy, font: vf, color: Color.textS)
        }
        if let sys {
            let h = sys.uptimeSeconds / 3600, m = (sys.uptimeSeconds % 3600) / 60
            let up = h >= 24 ? "\(h / 24)d \(h % 24)h" : "\(h)h \(m)m"
            stat("Uptime", up, py + ph - 142)
            stat("Procs", "\(sys.processCount)", py + ph - 120)
        }

        // Clock — big, centered across the full panel width, below the divider
        formatter.dateFormat = "HH:mm:ss"
        Draw.centeredText(ctx, formatter.string(from: Date()),
                          cx: x + pw / 2, y: dividerY + 30,
                          font: Fonts.system(66, weight: .medium), color: Color.textW)
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
                                   keyStats: KeyStatsSnapshot) {
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
                network: network, tokenUsage: tokenUsage, keyStats: keyStats)
        }
    }

    private func middleSlotAccent(_ slot: MiddleSlot) -> CGColor {
        switch slot {
        case .codex, .disk, .keyStats:
            return Color.cyan
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
                                  keyStats: KeyStatsSnapshot) {
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
        case .keyStats:
            renderKeyStatsColumn(ctx, x: x, w: w, py: py, ph: ph,
                                 stats: keyStats)
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

    private func renderKeyStatsColumn(_ ctx: CGContext, x: Int, w: Int,
                                      py: Int, ph: Int,
                                      stats: KeyStatsSnapshot) {
        Draw.text(ctx, "KEY STATS", x: x, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.cyan)

        guard stats.available else {
            Draw.centeredText(ctx, "Allow MacTR Input Monitoring",
                              cx: x + w / 2, y: py + ph / 2 - 16,
                              font: Fonts.system(20), color: Color.textD)
            Draw.centeredText(ctx, "Then restart MacTR",
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

    private func renderAgentColumn(_ ctx: CGContext, x: Int, w: Int, py: Int,
                                   name: String, accent: CGColor, usage: AgentUsage) {
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
        ctx.setFillColor(accent.copy(alpha: bgAlpha) ?? accent)
        ctx.addPath(bgPath)
        ctx.fillPath()
        if usage.needsAttention {
            ctx.setStrokeColor(accent.copy(alpha: blinkOn ? 0.9 : 0.25) ?? accent)
            ctx.setLineWidth(2)
            ctx.addPath(bgPath)
            ctx.strokePath()
        } else if usage.isWorking {
            // Faint breathing border to reinforce the "alive/working" feel
            ctx.setStrokeColor(accent.copy(alpha: 0.12 + 0.28 * breath) ?? accent)
            ctx.setLineWidth(1.5)
            ctx.addPath(bgPath)
            ctx.strokePath()
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
