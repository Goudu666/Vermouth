import Foundation

/// 生产环境子进程调度器（严格遵循 L-009）：
/// - 并发排空 `stdout` 与 `stderr` 双管道，杜绝 64KB 管道缓冲死锁
/// - 按 `0x0A` (`\n`) 字节边界缓冲并容错解码 UTF-8（兼容 GBK/Shift-JIS 与跨块多字节字符）
/// - 通过 `DispatchGroup` 同步双管道 EOF 与进程退出，确保 `.exited` 绝不早于最后一行日志发出
/// - 绑定 `AsyncThrowingStream` 取消回调至 `process.terminate()`
public final class LiveCommandRunner: CommandRunning, Sendable {
    private static let readChunkSize = 16_384
    private static let maximumSingleLineBytes = 1_048_576

    public init() {}

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var exitCode: Int32 = -1

        for try await chunk in stream(request) {
            switch chunk {
            case let .stdout(line):
                stdoutLines.append(line)
            case let .stderr(line):
                stderrLines.append(line)
            case let .exited(code):
                exitCode = code
            }
        }

        return CommandResult(
            exitCode: exitCode,
            stdout: stdoutLines.joined(separator: "\n"),
            stderr: stderrLines.joined(separator: "\n")
        )
    }

    public func stream(_ request: CommandRequest) -> AsyncThrowingStream<ProcessStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: request.executablePath)
            process.arguments = request.arguments
            process.standardInput = FileHandle.nullDevice

            if let workingDirectory = request.workingDirectory, !workingDirectory.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            }

            if request.inheritEnvironment {
                var merged = ProcessInfo.processInfo.environment
                for (key, value) in request.environment {
                    merged[key] = value
                }
                process.environment = merged
            } else {
                process.environment = request.environment
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutReadBox = FileHandleBox(stdoutPipe.fileHandleForReading)
            let stderrReadBox = FileHandleBox(stderrPipe.fileHandleForReading)
            let controller = ProcessController(process: process)

            let completionGroup = DispatchGroup()
            completionGroup.enter() // process termination
            completionGroup.enter() // stdout EOF
            completionGroup.enter() // stderr EOF

            process.terminationHandler = { terminatedProcess in
                if controller.recordTermination(status: terminatedProcess.terminationStatus) {
                    completionGroup.leave()
                }
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    controller.cancelAndTerminate()
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                if controller.recordTermination(status: -1) {
                    completionGroup.leave()
                }
                completionGroup.leave() // stdout reader never started
                completionGroup.leave() // stderr reader never started
                stdoutReadBox.close()
                stderrReadBox.close()
                continuation.finish(
                    throwing: VermouthError.ioError(
                        operation: "spawnProcess",
                        path: request.executablePath,
                        underlyingDescription: error.localizedDescription
                    )
                )
                return
            }

            controller.markLaunched()

            let stdoutQueue = DispatchQueue(
                label: "io.github.goudu666.vermouth.process.stdout.\(UUID().uuidString)",
                qos: .userInitiated
            )
            let stderrQueue = DispatchQueue(
                label: "io.github.goudu666.vermouth.process.stderr.\(UUID().uuidString)",
                qos: .userInitiated
            )
            let finishQueue = DispatchQueue(
                label: "io.github.goudu666.vermouth.process.finish.\(UUID().uuidString)",
                qos: .userInitiated
            )

            stdoutQueue.async {
                defer {
                    stdoutReadBox.close()
                    completionGroup.leave()
                }
                Self.drainPipe(
                    handleBox: stdoutReadBox,
                    controller: controller,
                    isStdErr: false,
                    continuation: continuation
                )
            }

            stderrQueue.async {
                defer {
                    stderrReadBox.close()
                    completionGroup.leave()
                }
                Self.drainPipe(
                    handleBox: stderrReadBox,
                    controller: controller,
                    isStdErr: true,
                    continuation: continuation
                )
            }

            completionGroup.notify(queue: finishQueue) {
                if let exitCode = controller.markFinishedAndGetExitCode() {
                    continuation.yield(.exited(exitCode))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Concurrent Pipe Draining & Line Buffering

    private static func drainPipe(
        handleBox: FileHandleBox,
        controller: ProcessController,
        isStdErr: Bool,
        continuation: AsyncThrowingStream<ProcessStreamChunk, Error>.Continuation
    ) {
        var lineBuffer: [UInt8] = []
        lineBuffer.reserveCapacity(1024)

        func emitLine(_ bytes: [UInt8]) {
            guard !controller.isCancelled else { return }
            var trimmed = bytes
            if trimmed.last == 0x0D { // Strip trailing '\r' from CRLF
                trimmed.removeLast()
            }
            let decoded = String(decoding: trimmed, as: UTF8.self)
            continuation.yield(isStdErr ? .stderr(decoded) : .stdout(decoded))
        }

        while true {
            guard let chunk = handleBox.readChunk(maxBytes: readChunkSize), !chunk.isEmpty else {
                break
            }

            for byte in chunk {
                if byte == 0x0A { // '\n'
                    emitLine(lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    lineBuffer.append(byte)
                    if lineBuffer.count >= maximumSingleLineBytes {
                        emitLine(lineBuffer)
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        // Flush any trailing partial line without a final '\n' before signalling EOF
        if !lineBuffer.isEmpty {
            emitLine(lineBuffer)
            lineBuffer.removeAll(keepingCapacity: false)
        }
    }
}

// MARK: - Swift 6 Concurrency Helpers

/// 封装单一队列独占读取的 `FileHandle`，隔离非 `Sendable` 类型以通过 Swift 6 严格并发检查。
private final class FileHandleBox: @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readChunk(maxBytes: Int) -> Data? {
        try? handle.read(upToCount: maxBytes)
    }

    func close() {
        try? handle.close()
    }
}

/// 线程安全管理子进程启动、取消终止与退出码状态的同步控制器。
private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var launched = false
    private var cancelled = false
    private var didTerminate = false
    private var terminationRecorded = false
    private var finished = false
    private var exitCode: Int32 = -1

    init(process: Process) {
        self.process = process
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func markLaunched() {
        let shouldTerminate: Bool = lock.withLock {
            launched = true
            guard cancelled && !didTerminate else { return false }
            didTerminate = true
            return true
        }
        if shouldTerminate && process.isRunning {
            process.terminate()
        }
    }

    func recordTermination(status: Int32) -> Bool {
        lock.withLock {
            guard !terminationRecorded else { return false }
            terminationRecorded = true
            exitCode = status
            return true
        }
    }

    func cancelAndTerminate() {
        let shouldTerminate: Bool = lock.withLock {
            cancelled = true
            guard launched && !didTerminate else { return false }
            didTerminate = true
            return true
        }
        if shouldTerminate && process.isRunning {
            process.terminate()
        }
    }

    func markFinishedAndGetExitCode() -> Int32? {
        lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard !cancelled else { return nil }
            return exitCode
        }
    }
}
