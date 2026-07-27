import Foundation

struct TokenUsageEntry: Sendable {
    let model: String
    let provider: String
    let client: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int
    let messageCount: Int
    let cost: Double
}

struct TokenUsageSnapshot: Sendable {
    let entries: [TokenUsageEntry]
    let totalInput: Int
    let totalOutput: Int
    let totalCacheRead: Int
    let totalCacheWrite: Int
    let totalMessages: Int
    let totalCost: Double
    let processingTimeMs: Int
    var isEmpty: Bool { entries.isEmpty }
}

final class TokenUsageCollector: @unchecked Sendable {

    func collect() -> TokenUsageSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tokscale", "--today", "--json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return emptySnapshot() }

            return parse(json)
        } catch {
            return emptySnapshot()
        }
    }

    private func emptySnapshot() -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            entries: [],
            totalInput: 0, totalOutput: 0,
            totalCacheRead: 0, totalCacheWrite: 0,
            totalMessages: 0, totalCost: 0,
            processingTimeMs: 0)
    }

    private func parse(_ json: [String: Any]) -> TokenUsageSnapshot {
        let entries = (json["entries"] as? [[String: Any]])?.map { entry in
            TokenUsageEntry(
                model: entry["model"] as? String ?? "",
                provider: entry["provider"] as? String ?? "",
                client: entry["client"] as? String ?? "",
                input: entry["input"] as? Int ?? 0,
                output: entry["output"] as? Int ?? 0,
                cacheRead: entry["cacheRead"] as? Int ?? 0,
                cacheWrite: entry["cacheWrite"] as? Int ?? 0,
                reasoning: entry["reasoning"] as? Int ?? 0,
                messageCount: entry["messageCount"] as? Int ?? 0,
                cost: entry["cost"] as? Double ?? 0)
        } ?? []

        return TokenUsageSnapshot(
            entries: entries,
            totalInput: json["totalInput"] as? Int ?? 0,
            totalOutput: json["totalOutput"] as? Int ?? 0,
            totalCacheRead: json["totalCacheRead"] as? Int ?? 0,
            totalCacheWrite: json["totalCacheWrite"] as? Int ?? 0,
            totalMessages: json["totalMessages"] as? Int ?? 0,
            totalCost: json["totalCost"] as? Double ?? 0,
            processingTimeMs: json["processingTimeMs"] as? Int ?? 0)
    }
}
