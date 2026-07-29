import Foundation

struct CodexQuotaWindowSnapshot: Sendable {
    let label: String
    let remainingPercent: Double?
    let resetsAt: Date?
}

struct CodexTokenSnapshot: Sendable {
    let available: Bool
    let todayTokens: UInt64
    let lifetimeTokens: UInt64
    let peakDailyTokens: UInt64
    let longestRunningTurnSeconds: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let dailyTokens: [String: UInt64]
    let resetCreditsAvailable: Int?
    let primary: CodexQuotaWindowSnapshot?
    let secondary: CodexQuotaWindowSnapshot?
    let errorMessage: String

    static let loading = CodexTokenSnapshot(
        available: false, todayTokens: 0, lifetimeTokens: 0,
        peakDailyTokens: 0, longestRunningTurnSeconds: 0,
        currentStreakDays: 0, longestStreakDays: 0, dailyTokens: [:],
        resetCreditsAvailable: nil,
        primary: nil, secondary: nil,
        errorMessage: "正在读取 Codex 用量…")

    static let demo = CodexTokenSnapshot(
        available: true, todayTokens: 12_800_000,
        lifetimeTokens: 388_600_000, peakDailyTokens: 31_500_000,
        longestRunningTurnSeconds: 37 * 60 + 28,
        currentStreakDays: 2, longestStreakDays: 6,
        dailyTokens: [
            "2026-07-21": 11_600_000, "2026-07-22": 3_700_000,
            "2026-07-23": 61_100_000, "2026-07-27": 6_700_000,
            "2026-07-28": 118_200_000, "2026-07-29": 12_800_000,
        ],
        resetCreditsAvailable: 2,
        primary: CodexQuotaWindowSnapshot(
            label: "5h", remainingPercent: 82,
            resetsAt: Date().addingTimeInterval(2.5 * 3600)),
        secondary: CodexQuotaWindowSnapshot(
            label: "7d", remainingPercent: 37,
            resetsAt: Date().addingTimeInterval(4.2 * 86400)),
        errorMessage: "")
}

/// Reads authoritative quota and usage data from the local Codex app-server.
/// The refresh runs on its own queue and keeps one app-server process alive, so
/// the LCD render and system-metrics queues never wait for subprocess I/O.
final class CodexTokenCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thermalvision.codex-token")
    private let stateLock = NSLock()
    private var refreshing = false
    private var nextRefresh = Date.distantPast
    private var client: CodexAppServerClient?
    private let refreshInterval: TimeInterval = 60

    func refreshIfNeeded(
        completion: @escaping @Sendable (CodexTokenSnapshot) -> Void
    ) {
        stateLock.lock()
        guard !refreshing, Date() >= nextRefresh else {
            stateLock.unlock()
            return
        }
        refreshing = true
        nextRefresh = Date().addingTimeInterval(refreshInterval)
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.fetch()
            self.stateLock.lock()
            self.refreshing = false
            self.stateLock.unlock()
            completion(snapshot)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.client?.close()
            self?.client = nil
        }
    }

    private func fetch() -> CodexTokenSnapshot {
        do {
            let activeClient: CodexAppServerClient
            if let client, client.isRunning {
                activeClient = client
            } else {
                client?.close()
                let created = try CodexAppServerClient()
                try created.initialize()
                client = created
                activeClient = created
            }

            let rateResult = try? activeClient.request(
                method: "account/rateLimits/read")
            let usageResult = try? activeClient.request(
                method: "account/usage/read")

            guard rateResult != nil || usageResult != nil else {
                throw CodexTokenError.noUsageData
            }
            return Self.snapshot(rateResult: rateResult, usageResult: usageResult)
        } catch CodexTokenError.executableNotFound {
            return unavailable("未找到 Codex CLI")
        } catch CodexTokenError.notLoggedIn {
            return unavailable("请先登录 Codex")
        } catch {
            client?.close()
            client = nil
            return unavailable("Codex 用量暂不可用")
        }
    }

    private func unavailable(_ message: String) -> CodexTokenSnapshot {
        CodexTokenSnapshot(
            available: false, todayTokens: 0, lifetimeTokens: 0,
            peakDailyTokens: 0, longestRunningTurnSeconds: 0,
            currentStreakDays: 0, longestStreakDays: 0, dailyTokens: [:],
            resetCreditsAvailable: nil,
            primary: nil, secondary: nil,
            errorMessage: message)
    }

    private static func snapshot(
        rateResult: [String: Any]?, usageResult: [String: Any]?
    ) -> CodexTokenSnapshot {
        let rateLimits = rateResult?["rateLimits"] as? [String: Any]
        let byID = rateResult?["rateLimitsByLimitId"] as? [String: Any]
        let codexLimit = (byID?["codex"] as? [String: Any]) ?? rateLimits
        let resetCredits = rateResult?["rateLimitResetCredits"]
            as? [String: Any]

        let primary = quotaWindow(
            codexLimit?["primary"] as? [String: Any], fallback: "额度")
        let secondary = quotaWindow(
            codexLimit?["secondary"] as? [String: Any], fallback: "额度")

        let summary = usageResult?["summary"] as? [String: Any]
        let buckets = usageResult?["dailyUsageBuckets"] as? [[String: Any]] ?? []
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = dayFormatter.string(from: Date())
        let today = buckets
            .filter { $0["startDate"] as? String == todayKey }
            .reduce(UInt64(0)) { $0 + uint($1["tokens"]) }
        let dailyTokens = buckets.reduce(into: [String: UInt64]()) {
            result, bucket in
            guard let date = bucket["startDate"] as? String else { return }
            result[date, default: 0] += uint(bucket["tokens"])
        }

        return CodexTokenSnapshot(
            available: true,
            todayTokens: today,
            lifetimeTokens: uint(summary?["lifetimeTokens"]),
            peakDailyTokens: uint(summary?["peakDailyTokens"]),
            longestRunningTurnSeconds:
                (summary?["longestRunningTurnSec"] as? NSNumber)?.intValue ?? 0,
            currentStreakDays:
                (summary?["currentStreakDays"] as? NSNumber)?.intValue ?? 0,
            longestStreakDays:
                (summary?["longestStreakDays"] as? NSNumber)?.intValue ?? 0,
            dailyTokens: dailyTokens,
            resetCreditsAvailable:
                (resetCredits?["availableCount"] as? NSNumber)?.intValue,
            primary: primary,
            secondary: secondary,
            errorMessage: "")
    }

    private static func quotaWindow(
        _ value: [String: Any]?, fallback: String
    ) -> CodexQuotaWindowSnapshot? {
        guard let value else { return nil }
        let duration = (value["windowDurationMins"] as? NSNumber)?.intValue
        let label: String
        if let duration, duration > 0, duration.isMultiple(of: 1440) {
            label = "\(duration / 1440)d"
        } else if let duration, duration > 0, duration.isMultiple(of: 60) {
            label = "\(duration / 60)h"
        } else if let duration, duration > 0 {
            label = "\(duration)m"
        } else {
            label = fallback
        }
        let used = (value["usedPercent"] as? NSNumber)?.doubleValue
        let remaining = used.map { max(0, min(100, 100 - $0)) }
        let resetTimestamp = (value["resetsAt"] as? NSNumber)?.doubleValue
        return CodexQuotaWindowSnapshot(
            label: label, remainingPercent: remaining,
            resetsAt: resetTimestamp.map { Date(timeIntervalSince1970: $0) })
    }

    private static func uint(_ value: Any?) -> UInt64 {
        if let n = value as? NSNumber { return n.uint64Value }
        if let s = value as? String { return UInt64(s) ?? 0 }
        return 0
    }
}

private enum CodexTokenError: Error {
    case executableNotFound
    case notLoggedIn
    case serverUnavailable
    case invalidResponse
    case requestTimeout
    case noUsageData
}

/// Minimal JSON-line client for `codex app-server --listen stdio://`.
private final class CodexAppServerClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private var receiveBuffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 1

    var isRunning: Bool { process.isRunning }

    init() throws {
        guard let executable = Self.findCodexExecutable() else {
            throw CodexTokenError.executableNotFound
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = Self.environment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        do {
            try process.run()
        } catch {
            close()
            throw CodexTokenError.serverUnavailable
        }
    }

    func initialize() throws {
        _ = try request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "mactr",
                    "title": "MacTR",
                    "version": "1.0",
                ],
            ])
        try notify(method: "initialized")
        let account = try request(
            method: "account/read", params: ["refreshToken": false])
        guard account["account"] is [String: Any] else {
            throw CodexTokenError.notLoggedIn
        }
    }

    func request(
        method: String, params: [String: Any]? = nil
    ) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try write(message)

        let deadline = Date().addingTimeInterval(6)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, process.isRunning, Date() < deadline {
            condition.wait(until: deadline)
        }
        guard let response = responses.removeValue(forKey: id) else {
            throw CodexTokenError.requestTimeout
        }
        if response["error"] != nil {
            throw CodexTokenError.serverUnavailable
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CodexTokenError.invalidResponse
        }
        return result
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    private func notify(
        method: String, params: [String: Any]? = nil
    ) throws {
        var message: [String: Any] = ["method": method]
        if let params { message["params"] = params }
        try write(message)
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexTokenError.serverUnavailable
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            condition.lock()
            condition.broadcast()
            condition.unlock()
            return
        }
        condition.lock()
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let response = object as? [String: Any],
                  let id = (response["id"] as? NSNumber)?.intValue
            else { continue }
            responses[id] = response
        }
        condition.broadcast()
        condition.unlock()
    }

    private static func findCodexExecutable() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.volta/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.local/bin",
            "\(home)/.volta/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = Array(Set(existing + additions)).joined(separator: ":")
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        return env
    }
}
