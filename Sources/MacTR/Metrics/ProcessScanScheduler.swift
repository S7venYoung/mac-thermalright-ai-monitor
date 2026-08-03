import Foundation

/// Adaptive pacing for the expensive filesystem/process-backed scans.
/// Fast CPU and display metrics continue to refresh normally; only the larger
/// AgentUsage scan is gated here.
final class ProcessScanScheduler: @unchecked Sendable {
    static let shared = ProcessScanScheduler()
    private let lock = NSLock()
    private let ladder: [TimeInterval] = [2, 5, 15, 60]
    private var rung = 3
    private var lastScan = Date.distantPast

    func shouldScan(saturated: Bool, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if saturated { rung = 0 }
        let interval = ladder[min(rung, ladder.count - 1)]
        guard now.timeIntervalSince(lastScan) >= interval else { return false }
        lastScan = now
        if !saturated { rung = min(rung + 1, ladder.count - 1) }
        return true
    }
}
