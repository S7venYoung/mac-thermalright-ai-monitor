import Foundation

struct WeatherSnapshot: Sendable {
    let available: Bool
    let city: String
    let temperature: Double
    let apparentTemperature: Double
    let humidity: Int
    let windSpeed: Double
    let condition: String
    let highTemperature: Double?
    let lowTemperature: Double?

    static let unavailable = WeatherSnapshot(
        available: false, city: "", temperature: 0,
        apparentTemperature: 0, humidity: 0, windSpeed: 0,
        condition: "", highTemperature: nil, lowTemperature: nil)
}

private struct CaiyunResponse: Decodable {
    struct Result: Decodable {
        struct Realtime: Decodable {
            struct Wind: Decodable {
                let speed: Double
            }
            let temperature: Double
            let humidity: Double
            let skycon: String
            let wind: Wind
            let apparent_temperature: Double
        }
        struct Daily: Decodable {
            struct Temperature: Decodable {
                let max: Double
                let min: Double
            }
            let temperature: [Temperature]?
        }
        let realtime: Realtime
        let daily: Daily?
    }
    let status: String
    let result: Result?
}

private final class WeatherResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func store(_ value: Data?) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

final class WeatherCollector: @unchecked Sendable {
    private var cacheKey = ""
    private var cachedSnapshot = WeatherSnapshot.unavailable
    private var cachedAt = Date.distantPast

    func collect(
        token rawToken: String, longitude: Double, latitude: Double,
        city rawCity: String
    ) -> WeatherSnapshot {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = rawCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              (-180...180).contains(longitude),
              (-90...90).contains(latitude)
        else { return .unavailable }

        let key = "\(token)|\(longitude)|\(latitude)"
        if key == cacheKey, Date().timeIntervalSince(cachedAt) < 600 {
            return cachedSnapshot
        }

        let safeToken = token.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? token
        var components = URLComponents(
            string: "https://api.caiyunapp.com/v2.6/\(safeToken)/\(longitude),\(latitude)/weather")
        components?.queryItems = [
            URLQueryItem(name: "lang", value: "zh_CN"),
            URLQueryItem(name: "unit", value: "metric"),
            URLQueryItem(name: "dailysteps", value: "1"),
            URLQueryItem(name: "hourlysteps", value: "24"),
        ]
        guard let url = components?.url,
              let data = request(url),
              let response = try? JSONDecoder().decode(
                CaiyunResponse.self, from: data),
              response.status == "ok",
              let result = response.result
        else {
            return key == cacheKey ? cachedSnapshot : .unavailable
        }

        let daily = result.daily?.temperature?.first
        let realtime = result.realtime
        let snapshot = WeatherSnapshot(
            available: true,
            city: city.isEmpty ? "当前位置" : city,
            temperature: realtime.temperature,
            apparentTemperature: realtime.apparent_temperature,
            humidity: Int((realtime.humidity * 100).rounded()),
            windSpeed: realtime.wind.speed,
            condition: Self.conditionName(realtime.skycon),
            highTemperature: daily?.max,
            lowTemperature: daily?.min)
        cacheKey = key
        cachedSnapshot = snapshot
        cachedAt = Date()
        return snapshot
    }

    private func request(_ url: URL) -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        let box = WeatherResponseBox()
        session.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.store((200..<300).contains(status) ? data : nil)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 7)
        session.invalidateAndCancel()
        return box.load()
    }

    private static func conditionName(_ code: String) -> String {
        switch code {
        case "CLEAR_DAY": "晴"
        case "CLEAR_NIGHT": "晴夜"
        case "PARTLY_CLOUDY_DAY", "PARTLY_CLOUDY_NIGHT": "多云"
        case "CLOUDY": "阴"
        case "LIGHT_HAZE", "MODERATE_HAZE", "HEAVY_HAZE": "雾霾"
        case "LIGHT_RAIN": "小雨"
        case "MODERATE_RAIN": "中雨"
        case "HEAVY_RAIN", "STORM_RAIN": "大雨"
        case "FOG": "雾"
        case "LIGHT_SNOW": "小雪"
        case "MODERATE_SNOW": "中雪"
        case "HEAVY_SNOW", "STORM_SNOW": "大雪"
        case "DUST", "SAND": "沙尘"
        case "WIND": "大风"
        default: code
        }
    }
}
