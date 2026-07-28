import ApplicationServices
import CoreGraphics
import Foundation

struct KeyStatsSnapshot: Codable, Sendable {
    let available: Bool
    let keyPresses: Int
    let leftClicks: Int
    let rightClicks: Int
    let otherClicks: Int
    let mouseDistanceMeters: Double
    let scrollDistancePixels: Double
    let peakKPS: Int
    let peakCPS: Int

    var totalClicks: Int {
        leftClicks + rightClicks + otherClicks
    }

    static let unavailable = KeyStatsSnapshot(
        available: false, keyPresses: 0, leftClicks: 0, rightClicks: 0,
        otherClicks: 0, mouseDistanceMeters: 0, scrollDistancePixels: 0,
        peakKPS: 0, peakCPS: 0)

    static let demo = KeyStatsSnapshot(
        available: true, keyPresses: 18_642, leftClicks: 3_281,
        rightClicks: 246, otherClicks: 92, mouseDistanceMeters: 1_284,
        scrollDistancePixels: 486_200, peakKPS: 12, peakCPS: 7)
}

private struct KeyStatsStoredState: Codable {
    let day: String
    var keyPresses: Int
    var leftClicks: Int
    var rightClicks: Int
    var otherClicks: Int
    var mouseDistanceMeters: Double
    var scrollDistancePixels: Double
    var peakKPS: Int
    var peakCPS: Int
}

private func keyStatsEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let collector = Unmanaged<KeyStatsCollector>
        .fromOpaque(userInfo).takeUnretainedValue()
    collector.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class KeyStatsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let eventQueue = DispatchQueue(
        label: "com.beret21.MacTR.keystats", qos: .utility)
    private let defaultsKey = "integratedKeyStats"
    private let metersPerPixel = 0.000264583

    private var state: KeyStatsStoredState
    private var nextRollover: Date
    private var recentKeys: [TimeInterval] = []
    private var recentClicks: [TimeInterval] = []
    private var lastPointer: CGPoint?
    private var eventTap: CFMachPort?
    private var eventRunLoop: CFRunLoop?
    private var starting = false
    private var tracking = false
    private var shouldTrack = false
    private var lastSaveAt: TimeInterval = 0

    init() {
        let today = Self.dayKey()
        nextRollover = Self.nextMidnight()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode(
                KeyStatsStoredState.self, from: data),
           stored.day == today {
            state = stored
        } else {
            state = Self.emptyState(day: today)
        }
    }

    func start(requestPermission: Bool) {
        lock.lock()
        shouldTrack = true
        guard !tracking, !starting else {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()

        if requestPermission {
            let options = [
                "AXTrustedCheckOptionPrompt": true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        eventQueue.async { [weak self] in
            self?.runEventTap()
        }
    }

    func stop() {
        lock.lock()
        shouldTrack = false
        rolloverIfNeeded()
        saveLocked(force: true)
        let runLoop = eventRunLoop
        tracking = false
        starting = false
        eventRunLoop = nil
        eventTap = nil
        lock.unlock()
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    func collect() -> KeyStatsSnapshot {
        lock.lock()
        rolloverIfNeeded()
        let current = state
        let isAvailable = tracking
        saveLocked()
        lock.unlock()

        return KeyStatsSnapshot(
            available: isAvailable,
            keyPresses: current.keyPresses,
            leftClicks: current.leftClicks,
            rightClicks: current.rightClicks,
            otherClicks: current.otherClicks,
            mouseDistanceMeters: current.mouseDistanceMeters,
            scrollDistancePixels: current.scrollDistancePixels,
            peakKPS: current.peakKPS,
            peakCPS: current.peakCPS)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        rolloverIfNeeded()

        switch type {
        case .keyDown:
            state.keyPresses += 1
            Self.updatePeak(
                now: now, timestamps: &recentKeys, peak: &state.peakKPS)
        case .leftMouseDown:
            state.leftClicks += 1
            Self.updatePeak(
                now: now, timestamps: &recentClicks, peak: &state.peakCPS)
        case .rightMouseDown:
            state.rightClicks += 1
            Self.updatePeak(
                now: now, timestamps: &recentClicks, peak: &state.peakCPS)
        case .otherMouseDown:
            state.otherClicks += 1
            Self.updatePeak(
                now: now, timestamps: &recentClicks, peak: &state.peakCPS)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged:
            let point = event.location
            if let previous = lastPointer {
                let pixels = hypot(
                    point.x - previous.x, point.y - previous.y)
                state.mouseDistanceMeters += Double(pixels) * metersPerPixel
            }
            lastPointer = point
        case .scrollWheel:
            let pixels = abs(event.getDoubleValueField(
                .scrollWheelEventPointDeltaAxis1))
            let fallback = abs(event.getDoubleValueField(
                .scrollWheelEventFixedPtDeltaAxis1))
            state.scrollDistancePixels += pixels > 0 ? pixels : fallback
        default:
            break
        }
    }

    private func runEventTap() {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyStatsEventCallback,
            userInfo: refcon),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        else {
            lock.lock()
            starting = false
            tracking = false
            let retry = shouldTrack
            lock.unlock()
            if retry {
                eventQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.retryEventTapIfNeeded()
                }
            }
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        lock.lock()
        eventTap = tap
        eventRunLoop = runLoop
        starting = false
        tracking = true
        lock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, source, .commonModes)

        lock.lock()
        eventTap = nil
        eventRunLoop = nil
        tracking = false
        starting = false
        let retry = shouldTrack
        lock.unlock()
        if retry {
            eventQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.retryEventTapIfNeeded()
            }
        }
    }

    private func retryEventTapIfNeeded() {
        lock.lock()
        guard shouldTrack, !tracking, !starting else {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()
        runEventTap()
    }

    private static func updatePeak(
        now: TimeInterval,
        timestamps: inout [TimeInterval],
        peak: inout Int
    ) {
        timestamps.append(now)
        let cutoff = now - 1
        timestamps.removeAll { $0 < cutoff }
        peak = max(peak, timestamps.count)
    }

    private func rolloverIfNeeded() {
        guard Date() >= nextRollover else { return }
        let today = Self.dayKey()
        if state.day != today {
            state = Self.emptyState(day: today)
            recentKeys.removeAll(keepingCapacity: true)
            recentClicks.removeAll(keepingCapacity: true)
            lastPointer = nil
        }
        nextRollover = Self.nextMidnight()
    }

    private func saveLocked(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastSaveAt >= 2 else { return }
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            lastSaveAt = now
        }
    }

    private static func emptyState(day: String) -> KeyStatsStoredState {
        KeyStatsStoredState(
            day: day, keyPresses: 0, leftClicks: 0, rightClicks: 0,
            otherClicks: 0, mouseDistanceMeters: 0, scrollDistancePixels: 0,
            peakKPS: 0, peakCPS: 0)
    }

    private static func dayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func nextMidnight() -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 1, to: today)
            ?? Date().addingTimeInterval(86_400)
    }
}
