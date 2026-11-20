import Foundation
@testable import VermouthCore

// MARK: - Temp Directory Helpers

/// Creates an isolated temporary directory for a single test run.
func createTempDirectory(prefix: String = "vermouth-test") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Best-effort cleanup helper for temporary test directories.
func removeTempDirectory(_ url: URL?) {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Thread-Safe Synchronization Box

/// Synchronous lock wrapper safe to invoke from both sync and Swift 6 `async` contexts
/// without holding `NSLock` across suspension points.
private final class LockedBox<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ initialState: State) {
        self.state = initialState
    }

    func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

private enum MockOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(any Error)
}

// MARK: - MockCommandRunner

/// Thread-safe mock implementation of `CommandRunning` for deterministic unit tests.
final class MockCommandRunner: CommandRunning, Sendable {
    typealias RunHandler = @Sendable (CommandRequest) async throws -> CommandResult
    typealias StreamHandler = @Sendable (CommandRequest) -> AsyncThrowingStream<ProcessStreamChunk, Error>

    private struct State {
        var defaultResult: CommandResult
        var resultsByExecutable: [String: MockOutcome<CommandResult>]
        var streamOutcomesByExecutable: [String: MockOutcome<[ProcessStreamChunk]>]
        var runHandler: RunHandler?
        var streamHandler: StreamHandler?
        var recordedRequests: [CommandRequest]
    }

    private let box: LockedBox<State>

    init(
        defaultResult: CommandResult = CommandResult(exitCode: 0, stdout: "", stderr: ""),
        resultsByExecutable: [String: CommandResult] = [:],
        runHandler: RunHandler? = nil,
        streamChunksByExecutable: [String: [ProcessStreamChunk]] = [:],
        streamHandler: StreamHandler? = nil
    ) {
        let mappedResults = resultsByExecutable.mapValues { MockOutcome.success($0) }
        let mappedStreams = streamChunksByExecutable.mapValues { MockOutcome.success($0) }
        self.box = LockedBox(
            State(
                defaultResult: defaultResult,
                resultsByExecutable: mappedResults,
                streamOutcomesByExecutable: mappedStreams,
                runHandler: runHandler,
                streamHandler: streamHandler,
                recordedRequests: []
            )
        )
    }

    var recordedRequests: [CommandRequest] {
        box.withLock { $0.recordedRequests }
    }

    func resetRecordedRequests() {
        box.withLock { $0.recordedRequests.removeAll() }
    }

    func setDefaultResult(_ result: CommandResult) {
        box.withLock { $0.defaultResult = result }
    }

    func setResult(_ result: CommandResult, forExecutable executablePath: String) {
        box.withLock { $0.resultsByExecutable[executablePath] = .success(result) }
    }

    func setError(_ error: any Error, forExecutable executablePath: String) {
        box.withLock { $0.resultsByExecutable[executablePath] = .failure(error) }
    }

    func setRunHandler(_ handler: RunHandler?) {
        box.withLock { $0.runHandler = handler }
    }

    func setStreamChunks(_ chunks: [ProcessStreamChunk], forExecutable executablePath: String) {
        box.withLock { $0.streamOutcomesByExecutable[executablePath] = .success(chunks) }
    }

    func setStreamError(_ error: any Error, forExecutable executablePath: String) {
        box.withLock { $0.streamOutcomesByExecutable[executablePath] = .failure(error) }
    }

    func setStreamHandler(_ handler: StreamHandler?) {
        box.withLock { $0.streamHandler = handler }
    }

    // MARK: CommandRunning

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let (handler, outcome, defaultResult): (RunHandler?, MockOutcome<CommandResult>?, CommandResult) = box.withLock { state in
            state.recordedRequests.append(request)
            return (
                state.runHandler,
                state.resultsByExecutable[request.executablePath],
                state.defaultResult
            )
        }

        if let handler {
            return try await handler(request)
        }

        if let outcome {
            switch outcome {
            case let .success(result):
                return result
            case let .failure(error):
                throw error
            }
        }

        return defaultResult
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<ProcessStreamChunk, Error> {
        let (handler, streamOutcome, runOutcome, defaultResult): (
            StreamHandler?,
            MockOutcome<[ProcessStreamChunk]>?,
            MockOutcome<CommandResult>?,
            CommandResult
        ) = box.withLock { state in
            state.recordedRequests.append(request)
            return (
                state.streamHandler,
                state.streamOutcomesByExecutable[request.executablePath],
                state.resultsByExecutable[request.executablePath],
                state.defaultResult
            )
        }

        if let handler {
            return handler(request)
        }

        if let streamOutcome {
            return AsyncThrowingStream { continuation in
                switch streamOutcome {
                case let .success(chunks):
                    for chunk in chunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }
        }

        let synthesizedOutcome = runOutcome ?? .success(defaultResult)
        return AsyncThrowingStream { continuation in
            switch synthesizedOutcome {
            case let .success(result):
                if !result.stdout.isEmpty {
                    for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(.stdout(String(line)))
                    }
                }
                if !result.stderr.isEmpty {
                    for line in result.stderr.split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(.stderr(String(line)))
                    }
                }
                continuation.yield(.exited(result.exitCode))
                continuation.finish()
            case let .failure(error):
                continuation.finish(throwing: error)
            }
        }
    }
}

// MARK: - MockSystemProber

/// Records a single `removeQuarantine(path:recursive:)` call made to `MockSystemProber`.
struct QuarantineRemovalCall: Equatable, Sendable {
    let path: String
    let recursive: Bool
}

/// Thread-safe mock implementation of `SystemProbing` isolated from host OS state.
final class MockSystemProber: SystemProbing, Sendable {
    private struct State {
        var architecture: HostArchitecture
        var osVersion: OSVersionInfo
        var rosetta2Installed: Bool
        var executables: [String: String]
        var quarantinedPaths: Set<String>
        var removedQuarantineCalls: [QuarantineRemovalCall]
        var removeQuarantineError: (any Error)?
    }

    private let box: LockedBox<State>

    init(
        architecture: HostArchitecture = .arm64,
        osVersion: OSVersionInfo = OSVersionInfo(
            major: 15,
            minor: 0,
            patch: 0,
            displayString: "macOS 15.0.0"
        ),
        rosetta2Installed: Bool = true,
        executables: [String: String] = [
            "brew": "/opt/homebrew/bin/brew",
            "winetricks": "/opt/homebrew/bin/winetricks",
        ],
        quarantinedPaths: Set<String> = [],
        removeQuarantineError: (any Error)? = nil
    ) {
        let normalizedQuarantine = Set(quarantinedPaths.map(Self.normalizePath))
        self.box = LockedBox(
            State(
                architecture: architecture,
                osVersion: osVersion,
                rosetta2Installed: rosetta2Installed,
                executables: executables,
                quarantinedPaths: normalizedQuarantine,
                removedQuarantineCalls: [],
                removeQuarantineError: removeQuarantineError
            )
        )
    }

    var architecture: HostArchitecture {
        get { box.withLock { $0.architecture } }
        set { box.withLock { $0.architecture = newValue } }
    }

    var osVersion: OSVersionInfo {
        get { box.withLock { $0.osVersion } }
        set { box.withLock { $0.osVersion = newValue } }
    }

    var rosetta2Installed: Bool {
        get { box.withLock { $0.rosetta2Installed } }
        set { box.withLock { $0.rosetta2Installed = newValue } }
    }

    var executables: [String: String] {
        get { box.withLock { $0.executables } }
        set { box.withLock { $0.executables = newValue } }
    }

    var quarantinedPaths: Set<String> {
        get { box.withLock { $0.quarantinedPaths } }
        set { box.withLock { $0.quarantinedPaths = Set(newValue.map(Self.normalizePath)) } }
    }

    var removedQuarantinePaths: [String] {
        box.withLock { $0.removedQuarantineCalls.map(\.path) }
    }

    var removedQuarantineCalls: [QuarantineRemovalCall] {
        box.withLock { $0.removedQuarantineCalls }
    }

    func setRemoveQuarantineError(_ error: (any Error)?) {
        box.withLock { $0.removeQuarantineError = error }
    }

    // MARK: SystemProbing

    func hostArchitecture() -> HostArchitecture {
        box.withLock { $0.architecture }
    }

    func operatingSystemVersion() -> OSVersionInfo {
        box.withLock { $0.osVersion }
    }

    func isRosetta2Installed() async -> Bool {
        box.withLock { $0.rosetta2Installed }
    }

    func findExecutable(named: String, searchPaths: [String]) -> String? {
        box.withLock { state in
            state.executables[named]
        }
    }

    func isQuarantined(path: String) async -> Bool {
        let normalized = Self.normalizePath(path)
        return box.withLock { state in
            state.quarantinedPaths.contains(normalized) || state.quarantinedPaths.contains(path)
        }
    }

    func removeQuarantine(path: String, recursive: Bool) async throws {
        let normalized = Self.normalizePath(path)
        try box.withLock { state in
            if let error = state.removeQuarantineError {
                throw error
            }
            state.removedQuarantineCalls.append(
                QuarantineRemovalCall(path: path, recursive: recursive)
            )
            state.quarantinedPaths.remove(normalized)
            state.quarantinedPaths.remove(path)
            if recursive {
                let childPrefix = normalized.hasSuffix("/") ? normalized : "\(normalized)/"
                state.quarantinedPaths = state.quarantinedPaths.filter { !$0.hasPrefix(childPrefix) }
            }
        }
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

// MARK: - MockHTTPFetcher

/// Records a single `data(from:headers:)` request made to `MockHTTPFetcher`.
struct HTTPDataRequestRecord: Equatable, Sendable {
    let url: URL
    let headers: [String: String]
}

/// Records a single `download(from:to:progress:)` request made to `MockHTTPFetcher`.
struct HTTPDownloadRequestRecord: Equatable, Sendable {
    let url: URL
    let destination: URL
}

/// Thread-safe mock implementation of `HTTPFetching` for deterministic offline testing.
final class MockHTTPFetcher: HTTPFetching, Sendable {
    typealias DataHandler = @Sendable (URL, [String: String]) async throws -> Data
    typealias DownloadHandler = @Sendable (URL, URL, (@Sendable (DownloadProgress) -> Void)?) async throws -> Void

    private struct State {
        var responses: [URL: MockOutcome<Data>]
        var dataHandler: DataHandler?
        var downloadHandler: DownloadHandler?
        var recordedDataRequests: [HTTPDataRequestRecord]
        var recordedDownloadRequests: [HTTPDownloadRequestRecord]
    }

    private let box: LockedBox<State>

    init(
        responses: [URL: Data] = [:],
        dataHandler: DataHandler? = nil,
        downloadHandler: DownloadHandler? = nil
    ) {
        let mapped = responses.mapValues { MockOutcome.success($0) }
        self.box = LockedBox(
            State(
                responses: mapped,
                dataHandler: dataHandler,
                downloadHandler: downloadHandler,
                recordedDataRequests: [],
                recordedDownloadRequests: []
            )
        )
    }

    var recordedDataRequests: [HTTPDataRequestRecord] {
        box.withLock { $0.recordedDataRequests }
    }

    var recordedDownloadRequests: [HTTPDownloadRequestRecord] {
        box.withLock { $0.recordedDownloadRequests }
    }

    func stubData(_ data: Data, for url: URL) {
        box.withLock { $0.responses[url] = .success(data) }
    }

    func stubError(_ error: any Error, for url: URL) {
        box.withLock { $0.responses[url] = .failure(error) }
    }

    func setDataHandler(_ handler: DataHandler?) {
        box.withLock { $0.dataHandler = handler }
    }

    func setDownloadHandler(_ handler: DownloadHandler?) {
        box.withLock { $0.downloadHandler = handler }
    }

    func resetRecordedRequests() {
        box.withLock { state in
            state.recordedDataRequests.removeAll()
            state.recordedDownloadRequests.removeAll()
        }
    }

    // MARK: HTTPFetching

    func data(from url: URL, headers: [String: String]) async throws -> Data {
        let (handler, outcome): (DataHandler?, MockOutcome<Data>?) = box.withLock { state in
            state.recordedDataRequests.append(HTTPDataRequestRecord(url: url, headers: headers))
            return (state.dataHandler, state.responses[url])
        }

        if let handler {
            return try await handler(url, headers)
        }

        guard let outcome else {
            throw VermouthError.networkRequestFailed(
                url: url.absoluteString,
                statusCode: 404,
                reason: "No mock response registered for URL"
            )
        }

        switch outcome {
        case let .success(data):
            return data
        case let .failure(error):
            throw error
        }
    }

    func download(
        from url: URL,
        to destination: URL,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws {
        let (handler, outcome): (DownloadHandler?, MockOutcome<Data>?) = box.withLock { state in
            state.recordedDownloadRequests.append(
                HTTPDownloadRequestRecord(url: url, destination: destination)
            )
            return (state.downloadHandler, state.responses[url])
        }

        if let handler {
            try await handler(url, destination, progress)
            return
        }

        guard let outcome else {
            throw VermouthError.networkRequestFailed(
                url: url.absoluteString,
                statusCode: 404,
                reason: "No mock download registered for URL"
            )
        }

        switch outcome {
        case let .success(data):
            let parentDir = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            let count = Int64(data.count)
            progress?(DownloadProgress(bytesWritten: count, totalBytesExpected: count))
        case let .failure(error):
            throw error
        }
    }
}
