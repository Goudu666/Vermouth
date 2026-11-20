import Foundation

/// Windows PE 文件目标架构。
public enum PEArchitecture: String, Codable, Equatable, CaseIterable, Sendable {
    case x86_32
    case x86_64
    case arm64
    case unknown
}

/// 纯 Swift PE 文件头只读探测结果。
public struct PEInspectionResult: Codable, Equatable, Sendable {
    public var path: String
    public var architecture: PEArchitecture
    public var isDLL: Bool
    public var subsystem: UInt16

    public init(
        path: String,
        architecture: PEArchitecture,
        isDLL: Bool,
        subsystem: UInt16
    ) {
        self.path = path
        self.architecture = architecture
        self.isDLL = isDLL
        self.subsystem = subsystem
    }
}

/// Wine 内置容器工具枚举。
public enum WineBuiltinTool: String, Codable, CaseIterable, Equatable, Sendable {
    case winecfg
    case regedit
    case cmd
    case wineboot
}

/// 启动目标抽象。
public enum LaunchTarget: Codable, Equatable, Sendable {
    case executable(path: String, workingDirectory: String?)
    case appEntry(AppEntry)
    /// 自动识别 `.msi`（转 `msiexec /i Z:\...` 或 `C:\...` 并跳过 PE 探测，符合 L-009）与 `.exe`
    case installer(path: String)
    case builtinTool(WineBuiltinTool, extraArguments: [String])
}

/// 实时流式运行日志行。
public struct LogLine: Codable, Equatable, Identifiable, Sendable {
    public enum Stream: String, Codable, Equatable, CaseIterable, Sendable {
        case stdout
        case stderr
        case system
    }

    public var id: UUID
    public var timestamp: Date
    public var stream: Stream
    public var text: String
    /// 仅在进程结束的系统事件行非 `nil`
    public var exitCode: Int32?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stream: Stream,
        text: String,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
        self.exitCode = exitCode
    }
}

/// 单一真相的不可变启动计划（UI 命令预览与实际子进程执行完全同源）。
public struct LaunchPlan: Codable, Equatable, Sendable {
    public var bottleID: UUID
    public var engine: WineEngine
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var warnings: [DiagnosticFinding]
    /// 落盘日志路径 `bottles/<UUID>/logs/<timestamp>-<target>.log`
    public var logFilePath: String
    /// POSIX 单引号安全转义后的可复现命令预览
    public var shellCommandPreview: String

    public init(
        bottleID: UUID,
        engine: WineEngine,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String,
        environment: [String: String] = [:],
        warnings: [DiagnosticFinding] = [],
        logFilePath: String,
        shellCommandPreview: String
    ) {
        self.bottleID = bottleID
        self.engine = engine
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.warnings = warnings
        self.logFilePath = logFilePath
        self.shellCommandPreview = shellCommandPreview
    }
}

/// 运行中的 Wine 启动会话句柄。
public struct LaunchSession: Sendable {
    public let plan: LaunchPlan
    public let logFilePath: String
    public let stream: AsyncThrowingStream<LogLine, Error>

    public init(
        plan: LaunchPlan,
        logFilePath: String,
        stream: AsyncThrowingStream<LogLine, Error>
    ) {
        self.plan = plan
        self.logFilePath = logFilePath
        self.stream = stream
    }
}

/// 从容器开始菜单/桌面 `.lnk` 或 `Program Files*` 自动扫描发现的可执行程序。
public struct DiscoveredExecutable: Codable, Equatable, Identifiable, Sendable {
    public enum DiscoverySource: String, Codable, Equatable, CaseIterable, Sendable {
        case startMenuShortcut
        case desktopShortcut
        case programFilesScan
    }

    public var id: String { executablePath.lowercased() }
    public var name: String
    /// 宿主机绝对路径
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var source: DiscoverySource
    public var architecture: PEArchitecture

    public init(
        name: String,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        source: DiscoverySource,
        architecture: PEArchitecture = .unknown
    ) {
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.source = source
        self.architecture = architecture
    }
}
