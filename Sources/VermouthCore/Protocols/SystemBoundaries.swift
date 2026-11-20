import Foundation

/// 子进程流式输出事件。
public enum ProcessStreamChunk: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(Int32)
}

/// 子进程调度请求参数。
public struct CommandRequest: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]
    /// 当 `inheritEnvironment == true` 时合并覆盖当前进程环境；为 `false` 时仅使用此字典
    public let environment: [String: String]
    public let inheritEnvironment: Bool
    public let workingDirectory: String?

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        inheritEnvironment: Bool = true,
        workingDirectory: String? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.inheritEnvironment = inheritEnvironment
        self.workingDirectory = workingDirectory
    }
}

/// 子进程执行汇总结果。
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 抽象子进程调度（生产实现 `LiveCommandRunner` 须并发排空 stdout/stderr 并在 EOF 同步后再发 `.exited`，符合 L-009）。
public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<ProcessStreamChunk, Error>
}

/// 抽象宿主机只读环境探测与 macOS Quarantine 属性操作（符合 L-006）。
public protocol SystemProbing: Sendable {
    func hostArchitecture() -> HostArchitecture
    func operatingSystemVersion() -> OSVersionInfo
    func isRosetta2Installed() async -> Bool
    func findExecutable(named: String, searchPaths: [String]) -> String?
    func isQuarantined(path: String) async -> Bool
    func removeQuarantine(path: String, recursive: Bool) async throws
}

/// 抽象网络数据拉取与带进度下载（生产实现需通过 `#if canImport(FoundationNetworking)` 兼容双端）。
public protocol HTTPFetching: Sendable {
    func data(from url: URL, headers: [String: String]) async throws -> Data
    func download(
        from url: URL,
        to destination: URL,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws
}

public extension HTTPFetching {
    func data(from url: URL) async throws -> Data {
        try await data(from: url, headers: [:])
    }
}
