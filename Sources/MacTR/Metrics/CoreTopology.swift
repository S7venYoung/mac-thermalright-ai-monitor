import Darwin
import Foundation
import IOKit

enum CoreType: Sendable, Equatable { case efficiency, performance }

/// Maps logical CPU indexes to their actual E/P cluster using IODeviceTree.
/// This avoids assuming that a perflevel count is also an array offset.
enum CoreTopology {
    static let types: [CoreType] = detect()
    static var eCoreIndices: [Int] { types.indices.filter { types[$0] == .efficiency } }
    static var pCoreIndices: [Int] { types.indices.filter { types[$0] == .performance } }
    static var pCoreCount: Int { pCoreIndices.count }
    static func displayRows() -> [(index: Int, label: String, isEfficiency: Bool)] {
        var rows: [(Int, String, Bool)] = []
        for (n, i) in eCoreIndices.enumerated() { rows.append((i, "E\(n + 1)", true)) }
        for (n, i) in pCoreIndices.enumerated() { rows.append((i, "P\(n + 1)", false)) }
        return rows.map { (index: $0.0, label: $0.1, isEfficiency: $0.2) }
    }
    private static func detect() -> [CoreType] {
        if let value = fromDeviceTree() { return value }
        let total = sysctlInt("hw.logicalcpu") ?? 1
        let perf = sysctlInt("hw.perflevel0.logicalcpu") ?? total
        return Array(repeating: .efficiency, count: max(total - perf, 0)) +
               Array(repeating: .performance, count: min(perf, total))
    }
    private static func fromDeviceTree() -> [CoreType]? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var map: [Int: CoreType] = [:]
        var child = IOIteratorNext(iterator)
        while child != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let type = clusterType(dict["cluster-type"]),
               let id = intValue(dict["logical-cpu-id"]) { map[id] = type }
            IOObjectRelease(child); child = IOIteratorNext(iterator)
        }
        guard let maxID = map.keys.max(), map.count == maxID + 1,
              map.count == (sysctlInt("hw.logicalcpu") ?? map.count) else { return nil }
        return (0...maxID).compactMap { map[$0] }
    }
    private static func clusterType(_ value: Any?) -> CoreType? {
        let text = value is Data ? String(decoding: value as! Data, as: UTF8.self) : value as? String
        guard let c = text?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).first else { return nil }
        return c == "E" || c == "e" ? .efficiency : (c == "P" || c == "p" ? .performance : nil)
    }
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data, !data.isEmpty { return data.prefix(8).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        return nil
    }
    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}
