import Foundation

/// Wine 容器初始化、启动计划构建、流式运行、日志落盘与 `wineserver` 控制实现。
///
/// 严格遵循：
/// - **L-003**：所有子进程（含 `wineboot`、`regedit`、`wineserver` 与预注入终端）统一保持一致的同步环境变量，
///   且 `killWineServer` 对“无运行中 wineserver”的退出状态视为安全 no-op。
/// - **L-009 / L-014 / L-016**：流式输出使用 `VermouthJSON.currentTimestamp()` 并实时落盘，
///   命令执行严格校验 `exitCode == 0`。
public final class WineRunner: WineRunning, Sendable {
    public let paths: VermouthPaths
    private let commandRunner: any CommandRunning
    private let systemProber: any SystemProbing
    private let environmentBuilder: EnvironmentBuilder

    public init(
        paths: VermouthPaths,
        commandRunner: any CommandRunning,
        systemProber: any SystemProbing
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.systemProber = systemProber
        self.environmentBuilder = EnvironmentBuilder(paths: paths, systemProber: systemProber)
    }

    // MARK: - WineRunning

    public func ensurePrefixInitialized(bottle: Bottle, engine: WineEngine) async throws {
        let fileManager = FileManager.default
        let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true).standardizedFileURL
        let systemRegURL = prefixURL.appendingPathComponent("system.reg", isDirectory: false)
        let driveCURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)

        var regIsDir: ObjCBool = false
        let hasSystemReg = fileManager.fileExists(atPath: systemRegURL.path, isDirectory: &regIsDir) && !regIsDir.boolValue
        var driveCIsDir: ObjCBool = false
        let hasDriveC = fileManager.fileExists(atPath: driveCURL.path, isDirectory: &driveCIsDir) && driveCIsDir.boolValue

        if hasSystemReg && hasDriveC {
            return
        }

        do {
            try fileManager.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        } catch {
            throw VermouthError.ioError(
                operation: "createDirectory",
                path: prefixURL.path,
                underlyingDescription: error.localizedDescription
            )
        }

        let plan = try await environmentBuilder.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: .builtinTool(.wineboot, extraArguments: ["--init"]),
            graphicsPackage: nil,
            extraArgs: [],
            debugChannelsOverride: nil
        )

        let request = CommandRequest(
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            environment: plan.environment,
            inheritEnvironment: true,
            workingDirectory: prefixURL.path
        )

        let result: CommandResult
        do {
            result = try await commandRunner.run(request)
        } catch {
            throw VermouthError.prefixInitializationFailed(
                bottleName: bottle.name,
                reason: "执行 wineboot --init 失败: \(error.localizedDescription)"
            )
        }

        // L-016: 严格校验退出码
        guard result.exitCode == 0 else {
            let stderrText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderrText.isEmpty ? stdoutText : stderrText
            throw VermouthError.prefixInitializationFailed(
                bottleName: bottle.name,
                reason: "wineboot --init 返回非零退出码 \(result.exitCode)\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }
    }

    public func buildLaunchPlan(
        bottle: Bottle,
        engine: WineEngine,
        target: LaunchTarget,
        graphicsPackage: GraphicsLayerPackage?,
        extraArgs: [String] = [],
        debugChannelsOverride: String? = nil
    ) async throws -> LaunchPlan {
        try await environmentBuilder.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: target,
            graphicsPackage: graphicsPackage,
            extraArgs: extraArgs,
            debugChannelsOverride: debugChannelsOverride
        )
    }

    public func buildInteractiveTerminalScript(
        bottle: Bottle,
        engine: WineEngine,
        graphicsPackage: GraphicsLayerPackage?
    ) throws -> String {
        try environmentBuilder.buildInteractiveTerminalScript(
            bottle: bottle,
            engine: engine,
            graphicsPackage: graphicsPackage
        )
    }

    public func launch(_ plan: LaunchPlan) -> LaunchSession {
        let runner = self.commandRunner
        let stream = AsyncThrowingStream<LogLine, Error> { continuation in
            let task = Task {
                var logHandle = Self.prepareLogFile(at: plan.logFilePath, plan: plan)
                defer {
                    try? logHandle?.close()
                }

                let request = CommandRequest(
                    executablePath: plan.executablePath,
                    arguments: plan.arguments,
                    environment: plan.environment,
                    inheritEnvironment: true,
                    workingDirectory: plan.workingDirectory
                )

                do {
                    for try await chunk in runner.stream(request) {
                        let timestamp = VermouthJSON.currentTimestamp()
                        switch chunk {
                        case let .stdout(text):
                            Self.appendLogLine(handle: logHandle, streamLabel: "stdout", text: text)
                            continuation.yield(
                                LogLine(
                                    timestamp: timestamp,
                                    stream: .stdout,
                                    text: text
                                )
                            )

                        case let .stderr(text):
                            Self.appendLogLine(handle: logHandle, streamLabel: "stderr", text: text)
                            continuation.yield(
                                LogLine(
                                    timestamp: timestamp,
                                    stream: .stderr,
                                    text: text
                                )
                            )

                        case let .exited(code):
                            let message = "Process exited with code \(code)"
                            Self.appendLogLine(handle: logHandle, streamLabel: "system", text: message)
                            continuation.yield(
                                LogLine(
                                    timestamp: timestamp,
                                    stream: .system,
                                    text: message,
                                    exitCode: code
                                )
                            )
                        }
                    }
                    try? logHandle?.close()
                    logHandle = nil
                    continuation.finish()
                } catch {
                    Self.appendLogLine(
                        handle: logHandle,
                        streamLabel: "error",
                        text: error.localizedDescription
                    )
                    try? logHandle?.close()
                    logHandle = nil
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return LaunchSession(
            plan: plan,
            logFilePath: plan.logFilePath,
            stream: stream
        )
    }

    public func killWineServer(for bottle: Bottle, engine: WineEngine, force: Bool = false) async throws {
        try await WineServerControl.kill(
            bottle: bottle,
            engine: engine,
            force: force,
            commandRunner: commandRunner
        )
    }

    public func applyBottleRegistrySettings(bottle: Bottle, engine: WineEngine) async throws {
        try await ensurePrefixInitialized(bottle: bottle, engine: engine)

        let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true).standardizedFileURL
        let tempDirURL = prefixURL
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("windows", isDirectory: true)
            .appendingPathComponent("temp", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
        } catch {
            throw VermouthError.ioError(
                operation: "createDirectory",
                path: tempDirURL.path,
                underlyingDescription: error.localizedDescription
            )
        }

        let regFileURL = tempDirURL.appendingPathComponent(
            "vermouth-settings-\(UUID().uuidString).reg",
            isDirectory: false
        )
        let windowsRegPath = ShellQuoting.toWindowsPath(
            unixPath: regFileURL.path,
            prefixPath: bottle.prefixPath
        )

        let plan = try await environmentBuilder.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: .builtinTool(.regedit, extraArguments: ["/S", windowsRegPath]),
            graphicsPackage: nil,
            extraArgs: [],
            debugChannelsOverride: nil
        )

        try await RegistryPatcher.apply(
            bottle: bottle,
            engine: engine,
            launchPlan: plan,
            regFileURL: regFileURL,
            commandRunner: commandRunner
        )
    }

    // MARK: - Log File Helpers

    private static func prepareLogFile(at path: String, plan: LaunchPlan) -> FileHandle? {
        let logURL = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        let parentDir = logURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let header = [
            "=== Vermouth Launch Log ===",
            "Timestamp: \(formatISO8601(VermouthJSON.currentTimestamp()))",
            "Bottle ID: \(plan.bottleID.uuidString)",
            "Engine: \(plan.engine.name) (\(plan.engine.version))",
            "Working Directory: \(plan.workingDirectory)",
            "Command: \(plan.shellCommandPreview)",
            "===========================",
            "",
        ].joined(separator: "\n")

        guard fileManager.createFile(atPath: logURL.path, contents: Data(header.utf8)) else {
            return nil
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return nil
        }
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func appendLogLine(handle: FileHandle?, streamLabel: String, text: String) {
        guard let handle else { return }
        let line = "[\(streamLabel)] \(text)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private static func formatISO8601(_ date: Date) -> String {
        if let data = try? VermouthJSON.encode(date) {
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return "\(date.timeIntervalSince1970)"
    }
}

// MARK: - Shared WineServer Termination Helper (L-003)

internal enum WineServerControl: Sendable {
    static func kill(
        bottle: Bottle,
        engine: WineEngine,
        force: Bool,
        commandRunner: any CommandRunning
    ) async throws {
        var env = EnvironmentBuilder.syncEnvironment(for: bottle.config.syncMode)
        env["WINEPREFIX"] = bottle.prefixPath
        let engineBinDir = URL(fileURLWithPath: engine.rootPath, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .standardizedFileURL
            .path
        env["PATH"] = "\(engineBinDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let request = CommandRequest(
            executablePath: engine.wineserverPath,
            arguments: [force ? "-k9" : "-k"],
            environment: env,
            inheritEnvironment: true,
            workingDirectory: nil
        )

        let result = try await commandRunner.run(request)
        if result.exitCode == 0 {
            return
        }

        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedLower = (trimmedStderr + "\n" + result.stdout).lowercased()

        let isNoRunningServer = combinedLower.contains("no server")
            || combinedLower.contains("cannot connect")
            || combinedLower.contains("no wineserver")
            || combinedLower.contains("no such process")
            || combinedLower.contains("not running")
            || (result.exitCode == 1 && trimmedStderr.isEmpty)

        if isNoRunningServer {
            // L-003: 容器无运行中的 wineserver 时返回非零退出码视为安全 no-op
            return
        }

        throw VermouthError.commandExecutionFailed(
            executable: engine.wineserverPath,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }
}
