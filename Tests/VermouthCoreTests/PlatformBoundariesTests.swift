import Foundation
import XCTest
@testable import VermouthCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Swift 6 Thread-Safe Test Helpers

private final class PlatformTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

private struct StubHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    let error: (any Error)?

    init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        chunks: [Data] = [],
        error: (any Error)? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
        self.error = error
    }
}

private final class StubURLProtocolRouter: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubHTTPResponse

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func register(for url: URL, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[url.absoluteString] = handler
    }

    func unregister(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: url.absoluteString)
    }

    func handler(for url: URL?) -> Handler? {
        guard let key = url?.absoluteString else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handlers[key]
    }
}

/// Deterministic offline `URLProtocol` stub for `LiveHTTPFetcher` tests (zero live network access).
private final class StubURLProtocol: URLProtocol {
    private static let router = StubURLProtocolRouter()

    static func register(for url: URL, handler: @escaping StubURLProtocolRouter.Handler) {
        router.register(for: url, handler: handler)
    }

    static func unregister(for url: URL) {
        router.unregister(for: url)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        router.handler(for: request.url) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let handler = Self.router.handler(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let stub = handler(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - PlatformBoundariesTests

final class PlatformBoundariesTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try createTempDirectory(prefix: "vermouth-platform-test")
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func makeStubbedURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    // MARK: - LiveCommandRunner Real Subprocess Tests (L-009)

    func testLiveCommandRunnerDrainsOver200KBConcurrentlyWithoutPipeDeadlock() async throws {
        // L-009: Emit >200KB interleaved simultaneously to BOTH stdout and stderr (3500 x 82 = 287KB each,
        // >4x macOS 64KB pipe buffer) to prove concurrent pipe draining prevents deadlock and `.exited(0)` is strictly last.
        let pad = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let lineCount = 3500
        let script = """
        pad="\(pad)"
        i=0
        while [ "$i" -lt \(lineCount) ]; do
          printf "OUT-%04d-%s\\n" "$i" "$pad"
          printf "ERR-%04d-%s\\n" "$i" "$pad" >&2
          i=$((i + 1))
        done
        """

        let runner = LiveCommandRunner()
        let request = CommandRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            environment: [:],
            inheritEnvironment: true
        )

        var chunks: [ProcessStreamChunk] = []
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var exitCodes: [Int32] = []

        for try await chunk in runner.stream(request) {
            chunks.append(chunk)
            switch chunk {
            case let .stdout(line):
                stdoutLines.append(line)
            case let .stderr(line):
                stderrLines.append(line)
            case let .exited(code):
                exitCodes.append(code)
            }
        }

        XCTAssertEqual(exitCodes, [0], "Exactly one .exited(0) chunk must be emitted")
        XCTAssertEqual(chunks.last, .exited(0), ".exited(0) must be strictly the final stream chunk")

        XCTAssertEqual(stdoutLines.count, lineCount)
        XCTAssertEqual(stderrLines.count, lineCount)
        XCTAssertEqual(stdoutLines.first, "OUT-0000-\(pad)")
        XCTAssertEqual(stdoutLines.last, "OUT-3499-\(pad)")
        XCTAssertEqual(stderrLines.first, "ERR-0000-\(pad)")
        XCTAssertEqual(stderrLines.last, "ERR-3499-\(pad)")

        let totalStdoutBytes = stdoutLines.reduce(0) { $0 + $1.utf8.count + 1 }
        let totalStderrBytes = stderrLines.reduce(0) { $0 + $1.utf8.count + 1 }
        XCTAssertGreaterThan(totalStdoutBytes, 200_000)
        XCTAssertGreaterThan(totalStderrBytes, 200_000)
    }

    func testLiveCommandRunnerFlushesTrailingPartialLineBeforeExited() async throws {
        // L-009: Trailing line without '\n' must be flushed before `.exited(42)` is delivered.
        let runner = LiveCommandRunner()
        let request = CommandRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'win-crlf\\r\\n'; printf 'partial-out'; printf 'final-crash-line' >&2; exit 42"],
            environment: [:],
            inheritEnvironment: true
        )

        var chunks: [ProcessStreamChunk] = []
        for try await chunk in runner.stream(request) {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.last, .exited(42))
        let exitIndex = try XCTUnwrap(chunks.firstIndex(of: .exited(42)))
        XCTAssertEqual(exitIndex, chunks.count - 1)

        let crashIndex = try XCTUnwrap(chunks.firstIndex(of: .stderr("final-crash-line")))
        XCTAssertLessThan(crashIndex, exitIndex, "Trailing stderr line must arrive strictly before .exited(42)")

        XCTAssertTrue(chunks.contains(.stdout("win-crlf")), "CRLF trailing '\\r' should be stripped")
        XCTAssertTrue(chunks.contains(.stdout("partial-out")))
    }

    func testLiveCommandRunnerDecodesInvalidUTF8LossilyWithoutCrash() async throws {
        // L-009: Invalid UTF-8 bytes (e.g., GBK/Shift-JIS or raw 0xFF/0xFE) must decode lossily without crashing.
        let runner = LiveCommandRunner()
        let request = CommandRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '\\377\\376hello\\n'; printf '\\200\\201stderr-tail' >&2"],
            environment: [:],
            inheritEnvironment: true
        )

        let result = try await runner.run(request)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("hello"), "Decoded stdout should retain ASCII payload: \(result.stdout)")
        XCTAssertTrue(result.stdout.contains("\u{FFFD}"), "Invalid UTF-8 bytes should map to replacement character")
        XCTAssertTrue(result.stderr.contains("stderr-tail"))
        XCTAssertTrue(result.stderr.contains("\u{FFFD}"))
    }

    func testLiveCommandRunnerEnvironmentInheritanceToggleAndWorkingDirectory() async throws {
        let runner = LiveCommandRunner()

        // 1. inheritEnvironment == true preserves parent env (e.g. PATH/HOME) and applies overrides
        let inheritedReq = CommandRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'PATH_NONEMPTY=%s\\nCUSTOM=%s\\nPWD=%s\\n' \"$([ -n \"$PATH\" ] && echo yes || echo no)\" \"$VERMOUTH_CUSTOM\" \"$(/bin/pwd)\""],
            environment: ["VERMOUTH_CUSTOM": "inherited-ok"],
            inheritEnvironment: true,
            workingDirectory: tempRoot.path
        )
        let inheritedResult = try await runner.run(inheritedReq)
        XCTAssertEqual(inheritedResult.exitCode, 0)
        let inheritedLines = inheritedResult.stdout.split(separator: "\n").map(String.init)
        XCTAssertTrue(inheritedLines.contains("PATH_NONEMPTY=yes"))
        XCTAssertTrue(inheritedLines.contains("CUSTOM=inherited-ok"))
        let expectedResolvedPwd = tempRoot.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(inheritedLines.contains("PWD=\(expectedResolvedPwd)"))

        // 2. inheritEnvironment == false isolates environment strictly to request.environment (HOME must be absent)
        let isolatedReq = CommandRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'HOME=%s\\nONLY=%s\\n' \"${HOME:-}\" \"${VERMOUTH_ONLY:-}\""],
            environment: ["VERMOUTH_ONLY": "strict-isolated"],
            inheritEnvironment: false
        )
        let isolatedResult = try await runner.run(isolatedReq)
        XCTAssertEqual(isolatedResult.exitCode, 0)
        XCTAssertEqual(isolatedResult.stdout, "HOME=\nONLY=strict-isolated")
    }

    func testLiveCommandRunnerCancellationTerminatesChildPromptly() async throws {
        let runner = LiveCommandRunner()
        // Use `exec /bin/sleep 30` so SIGTERM to the spawned PID terminates sleep directly with zero orphan holding pipes.
        let request = CommandRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo \"PID:$$\"; exec /bin/sleep 30"],
            environment: [:],
            inheritEnvironment: true
        )

        let (readyStream, readyContinuation) = AsyncStream<pid_t>.makeStream()
        let startTime = Date()

        let consumerTask = Task<Void, Error> {
            defer { readyContinuation.finish() }
            for try await chunk in runner.stream(request) {
                if case let .stdout(line) = chunk,
                   line.hasPrefix("PID:"),
                   let pid = pid_t(line.dropFirst(4))
                {
                    readyContinuation.yield(pid)
                    readyContinuation.finish()
                }
            }
        }

        var iterator = readyStream.makeAsyncIterator()
        let maybeChildPID = await iterator.next()
        let childPID = try XCTUnwrap(maybeChildPID, "Child process did not emit startup PID")

        consumerTask.cancel()
        _ = try? await consumerTask.value

        // Wait briefly for OS reaping and confirm child process actually terminated (no leak).
        let deadline = Date().addingTimeInterval(2.5)
        while Self.isProcessAlive(childPID), Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsed, 3.0, "Cancelling consumer task must terminate child promptly")
        XCTAssertFalse(Self.isProcessAlive(childPID), "Child process \(childPID) must be terminated after cancellation")
    }

    func testLiveCommandRunnerSpawnFailureThrowsVermouthErrorCleanly() async {
        let runner = LiveCommandRunner()
        let missingExecutable = tempRoot.appendingPathComponent("nonexistent-executable-\(UUID().uuidString)").path
        let request = CommandRequest(executablePath: missingExecutable)

        do {
            _ = try await runner.run(request)
            XCTFail("Expected VermouthError.ioError when spawning missing executable")
        } catch let error as VermouthError {
            guard case .ioError(let operation, let path, _) = error else {
                XCTFail("Expected VermouthError.ioError, got \(error)")
                return
            }
            XCTAssertEqual(operation, "spawnProcess")
            XCTAssertEqual(path, missingExecutable)
        } catch {
            XCTFail("Expected VermouthError, got \(error)")
        }
    }

    // MARK: - LiveSystemProber Tests

    func testLiveSystemProberHostMetadataAndFindExecutable() throws {
        let prober = LiveSystemProber(commandRunner: MockCommandRunner())

        let arch = prober.hostArchitecture()
        #if arch(arm64)
        XCTAssertEqual(arch, .arm64)
        #elseif arch(x86_64)
        XCTAssertEqual(arch, .x86_64)
        #endif

        let osVersion = prober.operatingSystemVersion()
        XCTAssertGreaterThan(osVersion.major, 0)
        XCTAssertFalse(osVersion.displayString.isEmpty)
        #if os(macOS)
        XCTAssertTrue(osVersion.isAtLeast(major: 14, minor: 0))
        XCTAssertTrue(osVersion.displayString.hasPrefix("macOS "))
        #endif

        // Build two search directories where dir1 has a `+x` DIRECTORY with the same name (trap!)
        // and a non-executable regular file, while dir2 has the real executable regular file.
        let dir1 = tempRoot.appendingPathComponent("search-dir-1", isDirectory: true)
        let dir2 = tempRoot.appendingPathComponent("search-dir-2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        let directoryTrap = dir1.appendingPathComponent("wine-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTrap, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directoryTrap.path)

        let nonExecFile = dir1.appendingPathComponent("plain-data", isDirectory: false)
        try Data("not executable".utf8).write(to: nonExecFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecFile.path)

        let realExecutable = dir2.appendingPathComponent("wine-tool", isDirectory: false)
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: realExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realExecutable.path)

        // Must skip the +x directory trap in dir1 and locate the real executable file in dir2
        XCTAssertEqual(
            prober.findExecutable(named: "wine-tool", searchPaths: [dir1.path, dir2.path]),
            realExecutable.standardizedFileURL.path
        )
        XCTAssertNil(prober.findExecutable(named: "plain-data", searchPaths: [dir1.path, dir2.path]))
        XCTAssertEqual(
            prober.findExecutable(named: realExecutable.path, searchPaths: []),
            realExecutable.standardizedFileURL.path
        )
        XCTAssertNil(prober.findExecutable(named: directoryTrap.path, searchPaths: []))
        XCTAssertNil(prober.findExecutable(named: "   ", searchPaths: [dir2.path]))
    }

    func testLiveSystemProberBlocksBroadRecursiveQuarantineTargetsBeforeInvokingXattr() async {
        // L-006: Broad directories (home, ~/Downloads, /, /Applications, etc.) MUST fail before ever running xattr.
        let mockRunner = MockCommandRunner()
        let prober = LiveSystemProber(commandRunner: mockRunner)

        let forbiddenTargets = [
            NSHomeDirectory(),
            "~",
            "~/Downloads",
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Downloads").path,
            "/",
            "/Applications",
            "/System",
            "/tmp",
            "",
        ]

        for target in forbiddenTargets {
            do {
                try await prober.removeQuarantine(path: target, recursive: true)
                XCTFail("Expected L-006 guard to reject recursive removeQuarantine on \(target.debugDescription)")
            } catch let error as VermouthError {
                guard case .ioError(let operation, _, _) = error else {
                    XCTFail("Expected VermouthError.ioError for \(target.debugDescription), got \(error)")
                    return
                }
                XCTAssertEqual(operation, "removeQuarantine")
            } catch {
                XCTFail("Expected VermouthError for \(target.debugDescription), got \(error)")
            }
        }

        XCTAssertTrue(
            mockRunner.recordedRequests.isEmpty,
            "L-006 guard must reject forbidden recursive paths BEFORE ever invoking xattr"
        )
    }

    func testLiveSystemProberTargetedRemoveQuarantineAndIdempotentNoSuchXattr() async throws {
        let targetFile = tempRoot.appendingPathComponent("installer.exe", isDirectory: false)
        try Data("MZ".utf8).write(to: targetFile)

        // 1. Targeted non-recursive removal succeeds
        let mockRunner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 0, stdout: "", stderr: "")
        )
        let prober = LiveSystemProber(commandRunner: mockRunner)
        try await prober.removeQuarantine(path: targetFile.path, recursive: false)

        #if os(macOS)
        XCTAssertEqual(mockRunner.recordedRequests.count, 1)
        XCTAssertEqual(mockRunner.recordedRequests[0].executablePath, "/usr/bin/xattr")
        XCTAssertEqual(
            mockRunner.recordedRequests[0].arguments,
            ["-d", "com.apple.quarantine", targetFile.standardizedFileURL.path]
        )

        // 2. Idempotent success when xattr reports "No such xattr"
        mockRunner.setDefaultResult(
            CommandResult(
                exitCode: 1,
                stdout: "",
                stderr: "xattr: \(targetFile.path): No such xattr: com.apple.quarantine"
            )
        )
        try await prober.removeQuarantine(path: targetFile.path, recursive: false)

        // 3. Non-zero exit with real failure (e.g. permission error) throws commandExecutionFailed
        mockRunner.setDefaultResult(
            CommandResult(exitCode: 1, stdout: "", stderr: "xattr: Operation not permitted")
        )
        do {
            try await prober.removeQuarantine(path: targetFile.path, recursive: false)
            XCTFail("Expected VermouthError.commandExecutionFailed on non-zero xattr error")
        } catch let error as VermouthError {
            guard case .commandExecutionFailed(let executable, let exitCode, let stderr) = error else {
                XCTFail("Expected commandExecutionFailed, got \(error)")
                return
            }
            XCTAssertEqual(executable, "/usr/bin/xattr")
            XCTAssertEqual(exitCode, 1)
            XCTAssertTrue(stderr.contains("Operation not permitted"))
        }

        // 4. Safe narrow recursive target (specific bottle directory) invokes `xattr -dr`
        let safeBottleDir = tempRoot.appendingPathComponent("bottle-123", isDirectory: true)
        try FileManager.default.createDirectory(at: safeBottleDir, withIntermediateDirectories: true)
        mockRunner.resetRecordedRequests()
        mockRunner.setDefaultResult(CommandResult(exitCode: 0, stdout: "", stderr: ""))
        try await prober.removeQuarantine(path: safeBottleDir.path, recursive: true)
        XCTAssertEqual(
            mockRunner.recordedRequests.first?.arguments,
            ["-dr", "com.apple.quarantine", safeBottleDir.standardizedFileURL.path]
        )

        // 5. isQuarantined checks xattr -p exit code
        mockRunner.setDefaultResult(CommandResult(exitCode: 0, stdout: "0081;...", stderr: ""))
        let quarantinedTrue = await prober.isQuarantined(path: targetFile.path)
        XCTAssertTrue(quarantinedTrue)
        mockRunner.setDefaultResult(CommandResult(exitCode: 1, stdout: "", stderr: "No such xattr"))
        let quarantinedFalse = await prober.isQuarantined(path: targetFile.path)
        XCTAssertFalse(quarantinedFalse)
        #endif
    }

    // MARK: - LiveHTTPFetcher Offline Deterministic Tests (StubURLProtocol)

    func testLiveHTTPFetcherDataSendsHeadersAndHandles404() async throws {
        let session = makeStubbedURLSession()
        defer { session.invalidateAndCancel() }
        let fetcher = LiveHTTPFetcher(session: session)

        // 1. 200 OK with User-Agent + custom headers verification
        let okURL = try XCTUnwrap(URL(string: "https://vermouth.test/\(UUID().uuidString)/releases.json"))
        let expectedPayload = Data(#"{"tag_name":"v0.80"}"#.utf8)
        let capturedHeaders = PlatformTestBox<[String: String]>([:])

        StubURLProtocol.register(for: okURL) { request in
            capturedHeaders.withLock { $0 = request.allHTTPHeaderFields ?? [:] }
            return StubHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [expectedPayload]
            )
        }
        defer { StubURLProtocol.unregister(for: okURL) }

        let received = try await fetcher.data(
            from: okURL,
            headers: [
                "Accept": "application/vnd.github+json",
                "X-Vermouth-Test": "offline-stub",
            ]
        )
        XCTAssertEqual(received, expectedPayload)

        let headers = capturedHeaders.withLock { $0 }
        XCTAssertEqual(headers["User-Agent"], "Vermouth/0.1.0")
        XCTAssertEqual(headers["Accept"], "application/vnd.github+json")
        XCTAssertEqual(headers["X-Vermouth-Test"], "offline-stub")

        // 2. HTTP 404 throws VermouthError.networkRequestFailed(statusCode: 404)
        let missingURL = try XCTUnwrap(URL(string: "https://vermouth.test/\(UUID().uuidString)/not-found"))
        StubURLProtocol.register(for: missingURL) { _ in
            StubHTTPResponse(statusCode: 404, chunks: [Data("Not Found".utf8)])
        }
        defer { StubURLProtocol.unregister(for: missingURL) }

        do {
            _ = try await fetcher.data(from: missingURL, headers: [:])
            XCTFail("Expected VermouthError.networkRequestFailed for HTTP 404")
        } catch let error as VermouthError {
            guard case .networkRequestFailed(let urlString, let statusCode, _) = error else {
                XCTFail("Expected VermouthError.networkRequestFailed, got \(error)")
                return
            }
            XCTAssertEqual(urlString, missingURL.absoluteString)
            XCTAssertEqual(statusCode, 404)
        }
    }

    func testLiveHTTPFetcherDownloadReportsProgressWritesAtomicallyAndPreservesFileOnHTTP500() async throws {
        let session = makeStubbedURLSession()
        defer { session.invalidateAndCancel() }
        let fetcher = LiveHTTPFetcher(session: session)

        // 1. Multi-chunk 200 download with incremental progress callbacks and atomic destination write
        let chunk1 = Data(repeating: 0x41, count: 16_384)
        let chunk2 = Data(repeating: 0x42, count: 16_384)
        let chunk3 = Data(repeating: 0x43, count: 8_192)
        let fullPayload = chunk1 + chunk2 + chunk3
        let totalBytes = fullPayload.count

        let downloadURL = try XCTUnwrap(URL(string: "https://vermouth.test/\(UUID().uuidString)/dxmt.tar.gz"))
        StubURLProtocol.register(for: downloadURL) { _ in
            StubHTTPResponse(
                statusCode: 200,
                headers: ["Content-Length": "\(totalBytes)"],
                chunks: [chunk1, chunk2, chunk3]
            )
        }
        defer { StubURLProtocol.unregister(for: downloadURL) }

        let destinationDir = tempRoot.appendingPathComponent("downloads", isDirectory: true)
        let destinationURL = destinationDir.appendingPathComponent("dxmt-v0.80.tar.gz", isDirectory: false)
        let recordedProgress = PlatformTestBox<[DownloadProgress]>([])

        try await fetcher.download(from: downloadURL, to: destinationURL) { update in
            recordedProgress.withLock { $0.append(update) }
        }

        XCTAssertEqual(try Data(contentsOf: destinationURL), fullPayload)

        let updates = recordedProgress.withLock { $0 }
        XCTAssertFalse(updates.isEmpty, "Download must invoke progress callback at least once")
        let finalProgress = try XCTUnwrap(updates.last)
        XCTAssertEqual(finalProgress.bytesWritten, Int64(totalBytes))
        XCTAssertEqual(finalProgress.totalBytesExpected, Int64(totalBytes))
        XCTAssertEqual(finalProgress.fractionCompleted, 1.0)
        // Bytes written across callbacks must be monotonically non-decreasing
        for idx in 1..<updates.count {
            XCTAssertGreaterThanOrEqual(updates[idx].bytesWritten, updates[idx - 1].bytesWritten)
        }

        // Ensure no stray hidden `.download.*` temp files remain in destination directory
        let dirEntries = try FileManager.default.contentsOfDirectory(atPath: destinationDir.path)
        XCTAssertEqual(dirEntries, ["dxmt-v0.80.tar.gz"])

        // 2. HTTP 500 error must throw networkRequestFailed(statusCode: 500) and leave existing file untouched
        let errorURL = try XCTUnwrap(URL(string: "https://vermouth.test/\(UUID().uuidString)/server-error.tar.gz"))
        StubURLProtocol.register(for: errorURL) { _ in
            let body = Data("Internal Server Error".utf8)
            return StubHTTPResponse(
                statusCode: 500,
                headers: ["Content-Length": "\(body.count)"],
                chunks: [body]
            )
        }
        defer { StubURLProtocol.unregister(for: errorURL) }

        let protectedFile = destinationDir.appendingPathComponent("protected-existing.tar.gz", isDirectory: false)
        let sentinelData = Data("VALID-PREEXISTING-ARCHIVE".utf8)
        try sentinelData.write(to: protectedFile)

        do {
            try await fetcher.download(from: errorURL, to: protectedFile, progress: nil)
            XCTFail("Expected VermouthError.networkRequestFailed for HTTP 500")
        } catch let error as VermouthError {
            guard case .networkRequestFailed(let urlString, let statusCode, _) = error else {
                XCTFail("Expected VermouthError.networkRequestFailed, got \(error)")
                return
            }
            XCTAssertEqual(urlString, errorURL.absoluteString)
            XCTAssertEqual(statusCode, 500)
        }

        XCTAssertEqual(
            try Data(contentsOf: protectedFile),
            sentinelData,
            "Failed HTTP 500 download must never overwrite or corrupt an existing destination file"
        )
        let postErrorEntries = try FileManager.default.contentsOfDirectory(atPath: destinationDir.path).sorted()
        XCTAssertEqual(postErrorEntries, ["dxmt-v0.80.tar.gz", "protected-existing.tar.gz"])
    }
}
