import Foundation

struct CalendarEvent: Sendable {
    let date: Date
    let title: String
}

struct CalendarSnapshot: Sendable {
    let events: [CalendarEvent]
    let subscriptionConfigured: Bool

    static let empty = CalendarSnapshot(
        events: [], subscriptionConfigured: false)
}

private final class CalendarResponseBox: @unchecked Sendable {
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

final class CalendarCollector: @unchecked Sendable {
    func collect(urlString: String) -> CalendarSnapshot {
        var value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("webcal://") {
            value = "https://" + String(value.dropFirst("webcal://".count))
        }
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            return .empty
        }

        let semaphore = DispatchSemaphore(value: 0)
        let response = CalendarResponseBox()
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadRevalidatingCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            response.store(data)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 16)

        let data = response.load()
        guard let data, let text = String(data: data, encoding: .utf8) else {
            return CalendarSnapshot(events: [], subscriptionConfigured: true)
        }
        return CalendarSnapshot(
            events: Self.parseICS(text), subscriptionConfigured: true)
    }

    private static func parseICS(_ text: String) -> [CalendarEvent] {
        let normalized = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\r", with: "")
        var events: [CalendarEvent] = []
        var dateValue: String?
        var title: String?
        var insideEvent = false

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if value == "BEGIN:VEVENT" {
                insideEvent = true
                dateValue = nil
                title = nil
            } else if value == "END:VEVENT" {
                if insideEvent, let dateValue, let title,
                   let date = parseDate(dateValue) {
                    events.append(CalendarEvent(
                        date: date,
                        title: unescape(title)))
                }
                insideEvent = false
            } else if insideEvent, value.hasPrefix("DTSTART") {
                dateValue = value.split(separator: ":", maxSplits: 1)
                    .last.map(String.init)
            } else if insideEvent, value.hasPrefix("SUMMARY:") {
                title = String(value.dropFirst("SUMMARY:".count))
            }
        }
        return events.sorted { $0.date < $1.date }
    }

    private static func parseDate(_ value: String) -> Date? {
        let digits = String(value.prefix(8))
        guard digits.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: digits)
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
