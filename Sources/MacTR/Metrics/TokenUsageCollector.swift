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
