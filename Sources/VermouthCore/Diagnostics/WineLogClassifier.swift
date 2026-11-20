import Foundation

/// Wine 日志行级别（按严重程度从高到低）。
public enum WineLogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case error
    case warning
    case fixme
    case trace
    case info

    private var rank: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .fixme: 2
        case .trace: 3
        case .info: 4
        }
    }

    public static func < (lhs: WineLogLevel, rhs: WineLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// 单行 Wine 日志的分类结果。
public struct WineLogClassification: Equatable, Sendable {
    public let level: WineLogLevel
    /// Wine 调试通道（如 `module`、`d3d`、`ole`），非标准格式时为 `nil`。
    public let channel: String?
    /// 去掉 `pid:level:channel:` 前缀后的正文；非标准格式时为原文。
    public let message: String

    public init(level: WineLogLevel, channel: String?, message: String) {
        self.level = level
        self.channel = channel
        self.message = message
    }
}

/// 识别 Wine / MoltenVK / DXVK / DXMT 日志的级别与通道，供控制台着色与级别筛选使用。
///
/// 支持格式：
/// - `0024:err:module:import_dll ...`（标准 `WINEDEBUG` 输出）
/// - `1234.567:0024:warn:d3d:...`（开启 `+timestamp` 时）
/// - `err:ole:...`（无线程号的旧格式）
/// - `[mvk-error] ...` / `[mvk-warn] ...`（MoltenVK）、`err:` / `warn:` 开头的 DXVK / DXMT 行
/// - `wine: Unhandled page fault ...` / `Unhandled exception` 等致命信息
public enum WineLogClassifier: Sendable {
    private static let levelTokens: [String: WineLogLevel] = [
        "err": .error,
        "warn": .warning,
        "fixme": .fixme,
        "trace": .trace,
    ]

    public static func classify(_ line: String) -> WineLogClassification {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let parsed = parseWineDebugLine(trimmed) {
            return parsed
        }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("[mvk-error]") || lowered.hasPrefix("[mvk-critical]") {
            return WineLogClassification(level: .error, channel: "moltenvk", message: trimmed)
        }
        if lowered.hasPrefix("[mvk-warn]") {
            return WineLogClassification(level: .warning, channel: "moltenvk", message: trimmed)
        }
        let fatalMarkers = ["unhandled page fault", "unhandled exception", "wine: could not load", "segmentation fault", "fatal error"]
        if fatalMarkers.contains(where: { lowered.contains($0) }) {
            return WineLogClassification(level: .error, channel: nil, message: trimmed)
        }
        return WineLogClassification(level: .info, channel: nil, message: line)
    }

    /// 解析 `[timestamp:][pid:]level:channel:message`。
    private static func parseWineDebugLine(_ line: String) -> WineLogClassification? {
        var parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        // 去掉可选的 `+timestamp`（形如 1234.567）与线程号（十六进制，通常 4 位）
        if let first = parts.first, isTimestamp(first), parts.count > 1 {
            parts.removeFirst()
        }
        if let first = parts.first, isThreadID(first), parts.count > 1 {
            parts.removeFirst()
        }
        guard parts.count >= 3, let level = levelTokens[parts[0]] else {
            return nil
        }
        let channel = parts[1]
        guard !channel.isEmpty, channel.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        let message = parts.dropFirst(2).joined(separator: ":")
        return WineLogClassification(level: level, channel: channel, message: message)
    }

    private static func isTimestamp(_ token: String) -> Bool {
        token.contains(".") && token.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func isThreadID(_ token: String) -> Bool {
        token.count >= 3 && token.count <= 8 && token.allSatisfy(\.isHexDigit)
    }
}
