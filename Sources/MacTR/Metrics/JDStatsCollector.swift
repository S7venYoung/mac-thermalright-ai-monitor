import Foundation

struct JDPeriodStats: Decodable, Sendable {
    let orders: Int
    let items: Int
    let returnedItems: Int
    let estimatedSales: Double
    let estimatedCommission: Double
    let actualSales: Double
    let actualCommission: Double

    static let zero = JDPeriodStats(
        orders: 0, items: 0, returnedItems: 0,
        estimatedSales: 0, estimatedCommission: 0,
        actualSales: 0, actualCommission: 0)
}

struct JDStatsSnapshot: Sendable {
    let available: Bool
    let day: JDPeriodStats
    let week: JDPeriodStats
    let month: JDPeriodStats
    let year: JDPeriodStats
    let generatedAt: String
    let errorMessage: String

    static let unavailable = JDStatsSnapshot(
        available: false, day: .zero, week: .zero,
        month: .zero, year: .zero, generatedAt: "",
        errorMessage: "请在设置中填写统计接口和访问令牌")
}

private struct JDStatsResponse: Decodable {
    struct Periods: Decodable {
        let day: JDPeriodStats
        let week: JDPeriodStats
        let month: JDPeriodStats
        let year: JDPeriodStats
    }

    let generatedAt: String
    let periods: Periods
}

private final class JDStatsResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var status = 0

    func store(data: Data?, status: Int) {
        lock.lock()
        self.data = data
        self.status = status
        lock.unlock()
    }

    func load() -> (Data?, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (data, status)
    }
}

final class JDStatsCollector: @unchecked Sendable {
    private var cacheKey = ""
    private var cachedSnapshot = JDStatsSnapshot.unavailable
    private var cachedAt = Date.distantPast

    func invalidate() {
        cachedAt = .distantPast
    }

    func collect(urlString rawURL: String, token rawToken: String)
        -> JDStatsSnapshot {
        let urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString),
              url.scheme == "https", !token.isEmpty
        else { return .unavailable }

        let key = "\(urlString)|\(token)"
        if key == cacheKey, Date().timeIntervalSince(cachedAt) < 300 {
            return cachedSnapshot
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        let box = JDStatsResponseBox()
        session.dataTask(with: request) { data, response, _ in
            box.store(
                data: data,
                status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 11)
        session.invalidateAndCancel()

        let (data, status) = box.load()
        guard (200..<300).contains(status), let data,
              let response = try? JSONDecoder().decode(
                JDStatsResponse.self, from: data)
        else {
            if key == cacheKey, cachedSnapshot.available {
                return cachedSnapshot
            }
            let message = status == 401
                ? "访问令牌无效"
                : "暂时无法连接京东统计服务"
            return JDStatsSnapshot(
                available: false, day: .zero, week: .zero,
                month: .zero, year: .zero, generatedAt: "",
                errorMessage: message)
        }

        let snapshot = JDStatsSnapshot(
            available: true,
            day: response.periods.day,
            week: response.periods.week,
            month: response.periods.month,
            year: response.periods.year,
            generatedAt: response.generatedAt,
            errorMessage: "")
        cacheKey = key
        cachedSnapshot = snapshot
        cachedAt = Date()
        return snapshot
    }
}
