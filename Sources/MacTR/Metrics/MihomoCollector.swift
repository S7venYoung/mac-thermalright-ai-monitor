import Foundation

struct MihomoSnapshot: Sendable {
    let available: Bool
    let version: String
    let mode: String
    let activeConnections: Int
    let downloadTotal: Int64
    let uploadTotal: Int64
    let memoryBytes: Int64
    let defaultNode: String
    let openAINode: String
    let errorMessage: String

    static let unavailable = MihomoSnapshot(
        available: false, version: "", mode: "",
        activeConnections: 0, downloadTotal: 0, uploadTotal: 0,
        memoryBytes: 0, defaultNode: "", openAINode: "",
        errorMessage: "未配置 Mihomo")
}

private final class MihomoResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var error: String?

    func store(data: Data?, error: String?) {
        lock.lock()
        self.data = data
        self.error = error
        lock.unlock()
    }

    func load() -> (Data?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, error)
    }
}

final class MihomoCollector: @unchecked Sendable {
    func collect(baseURL: String, secret: String) -> MihomoSnapshot {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = URL(string: value),
              ["http", "https"].contains(root.scheme?.lowercased() ?? "")
        else { return .unavailable }

        do {
            let connections = try requestJSON(
                root: root, path: "connections", secret: secret)
            let proxies = try requestJSON(
                root: root, path: "proxies", secret: secret)
            let configs = try requestJSON(
                root: root, path: "configs", secret: secret)
            let version = try? requestJSON(
                root: root, path: "version", secret: secret)

            let connectionList = connections["connections"] as? [[String: Any]]
            let proxyMap = proxies["proxies"] as? [String: Any]
            return MihomoSnapshot(
                available: true,
                version: version?["version"] as? String ?? "",
                mode: configs["mode"] as? String ?? "rule",
                activeConnections: connectionList?.count ?? 0,
                downloadTotal: Self.int64(connections["downloadTotal"]),
                uploadTotal: Self.int64(connections["uploadTotal"]),
                memoryBytes: Self.int64(connections["memory"]),
                defaultNode: Self.selectedNode("Default", in: proxyMap),
                openAINode: Self.selectedNode("OpenAI", in: proxyMap),
                errorMessage: "")
        } catch {
            return MihomoSnapshot(
                available: false, version: "", mode: "",
                activeConnections: 0, downloadTotal: 0, uploadTotal: 0,
                memoryBytes: 0, defaultNode: "", openAINode: "",
                errorMessage: error.localizedDescription)
        }
    }

    private func requestJSON(
        root: URL, path: String, secret: String
    ) throws -> [String: Any] {
        let url = root.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let box = MihomoResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let message: String?
            if let error {
                message = error.localizedDescription
            } else if status != 200 {
                message = status == 401 ? "密钥错误" : "HTTP \(status ?? 0)"
            } else {
                message = nil
            }
            box.store(data: data, error: message)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)

        let (data, message) = box.load()
        if let message {
            throw NSError(
                domain: "MihomoCollector", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let data,
              let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw NSError(
                domain: "MihomoCollector", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "响应格式错误"])
        }
        return json
    }

    private static func selectedNode(
        _ name: String, in proxies: [String: Any]?
    ) -> String {
        guard let item = proxies?[name] as? [String: Any] else {
            return "未知"
        }
        return item["now"] as? String ?? "未知"
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return 0
    }
}
