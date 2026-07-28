import Foundation

struct DailyWeatherForecast: Sendable {
    let day: String
    let condition: String
    let icon: String
    let highTemperature: Double
    let lowTemperature: Double
}

struct WeatherSnapshot: Sendable {
    let available: Bool
    let city: String
    let temperature: Double
    let apparentTemperature: Double
    let humidity: Int
    let windSpeed: Double
    let condition: String
    let icon: String
    let airQuality: String
    let rainForecast: String
    let daily: [DailyWeatherForecast]

    static let unavailable = WeatherSnapshot(
        available: false, city: "", temperature: 0,
        apparentTemperature: 0, humidity: 0, windSpeed: 0,
        condition: "", icon: "", airQuality: "",
        rainForecast: "", daily: [])
}

private struct CaiyunResponse: Decodable {
    struct Result: Decodable {
        struct Realtime: Decodable {
            struct Wind: Decodable {
                let speed: Double
            }
            struct AirQuality: Decodable {
                struct AQI: Decodable {
                    let chn: Int
                }
                let aqi: AQI
            }
            let temperature: Double
            let humidity: Double
            let skycon: String
            let wind: Wind
            let apparent_temperature: Double
            let air_quality: AirQuality?
        }
        struct Daily: Decodable {
            struct Temperature: Decodable {
                let date: String
                let max: Double
                let min: Double
            }
            struct Skycon: Decodable {
                let date: String
                let value: String
            }
            let temperature: [Temperature]
            let skycon: [Skycon]
        }
        struct Minutely: Decodable {
            let description: String?
        }
        let realtime: Realtime
        let daily: Daily?
        let minutely: Minutely?
        let forecast_keypoint: String?
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
            URLQueryItem(name: "dailysteps", value: "7"),
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

        let realtime = result.realtime
        let skyconByDate = Dictionary(
            uniqueKeysWithValues:
                (result.daily?.skycon ?? []).map { ($0.date, $0.value) })
        let daily = (result.daily?.temperature ?? []).prefix(7).map { item in
            let skycon = skyconByDate[item.date] ?? realtime.skycon
            return DailyWeatherForecast(
                day: Self.dayName(item.date),
                condition: Self.conditionName(skycon),
                icon: Self.conditionIcon(skycon),
                highTemperature: item.max,
                lowTemperature: item.min)
        }
        let todaySkycon = result.daily?.skycon.first?.value
        let displaySkycon =
            Self.isAirQualitySkycon(realtime.skycon)
                ? (todaySkycon ?? realtime.skycon)
                : realtime.skycon
        let snapshot = WeatherSnapshot(
            available: true,
            city: city.isEmpty ? "当前位置" : city,
            temperature: realtime.temperature,
            apparentTemperature: realtime.apparent_temperature,
            humidity: Int((realtime.humidity * 100).rounded()),
            windSpeed: realtime.wind.speed,
            condition: Self.conditionName(displaySkycon),
            icon: Self.conditionIcon(displaySkycon),
            airQuality: Self.airQualityName(
                realtime.air_quality?.aqi.chn),
            rainForecast:
                result.minutely?.description
                    ?? result.forecast_keypoint
                    ?? "暂无降雨预测",
            daily: daily)
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

    private static func conditionIcon(_ code: String) -> String {
        switch code {
        case "CLEAR_DAY": "☀︎"
        case "CLEAR_NIGHT": "☾"
        case "PARTLY_CLOUDY_DAY": "⛅︎"
        case "PARTLY_CLOUDY_NIGHT": "☁︎"
        case "CLOUDY": "☁︎"
        case "LIGHT_RAIN": "🌦"
        case "MODERATE_RAIN", "HEAVY_RAIN", "STORM_RAIN": "☂︎"
        case "LIGHT_SNOW", "MODERATE_SNOW", "HEAVY_SNOW", "STORM_SNOW": "❄︎"
        case "LIGHT_HAZE", "MODERATE_HAZE", "HEAVY_HAZE", "FOG": "≋"
        case "DUST", "SAND", "WIND": "≋"
        default: "•"
        }
    }

    private static func isAirQualitySkycon(_ code: String) -> Bool {
        code == "LIGHT_HAZE"
            || code == "MODERATE_HAZE"
            || code == "HEAVY_HAZE"
    }

    private static func airQualityName(_ aqi: Int?) -> String {
        guard let aqi else { return "" }
        switch aqi {
        case ...50: return "空气优"
        case ...100: return "空气良"
        case ...150: return "空气轻度污染"
        case ...200: return "空气中度污染"
        case ...300: return "空气重度污染"
        default: return "空气严重污染"
        }
    }

    private static func dayName(_ value: String) -> String {
        let datePart = String(value.prefix(10))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: datePart) else {
            return datePart
        }
        let weekday = Calendar.current.component(.weekday, from: date)
        return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][
            weekday - 1]
    }
}
