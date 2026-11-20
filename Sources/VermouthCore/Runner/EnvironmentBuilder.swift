import Foundation

/// 单一真相的 Wine 环境变量与不可变 `LaunchPlan` 构建器。
///
/// 所有容器内子进程启动（`.exe` / `.msi` / `winecfg` / `regedit` / `cmd` / `wineboot`）与
/// 预注入交互终端脚本均必须经由此构建器生成，确保同步模式与图形层环境变量完全一致（L-003）。
public struct EnvironmentBuilder: Sendable {
    public let paths: VermouthPaths
    private let systemProber: any SystemProbing

    public init(paths: VermouthPaths, systemProber: any SystemProbing) {
        self.paths = paths
        self.systemProber = systemProber
    }

    // MARK: - LaunchPlan

    public func buildLaunchPlan(
        bottle: Bottle,
        engine: WineEngine,
        target: LaunchTarget,
        graphicsPackage: GraphicsLayerPackage?,
        extraArgs: [String] = [],
        debugChannelsOverride: String? = nil
    ) async throws -> LaunchPlan {
        let appEntry: AppEntry?
        if case let .appEntry(entry) = target {
            appEntry = entry
        } else {
            appEntry = nil
        }

        let envBuild = buildEnvironment(
            bottle: bottle,
            engine: engine,
            graphicsPackage: graphicsPackage,
            appDllOverrides: appEntry?.dllOverrides ?? [],
            appEnvironmentOverrides: appEntry?.environmentOverrides ?? [:],
            debugChannelsOverride: debugChannelsOverride
        )

        var warnings = envBuild.warnings
        let environment = envBuild.environment

        if engine.isQuarantined {
            let quarantineTarget = enclosingAppBundlePath(for: engine.rootPath) ?? engine.rootPath
            warnings.append(
                DiagnosticFinding(
                    id: "quarantine-engine-\(engine.id)",
                    category: .quarantineBlocked,
                    severity: .warning,
                    title: "Wine 引擎带有 macOS 隔离属性（com.apple.quarantine）",
                    explanation: "引擎 \"\(engine.name)\"（\(quarantineTarget)）存在 com.apple.quarantine 扩展属性，可能被 macOS Gatekeeper 静默拦截导致启动失败。",
                    suggestion: "建议仅对该引擎目录执行一次解除隔离属性操作后重新启动。",
                    quickFix: .removeQuarantine(path: quarantineTarget, recursive: true)
                )
            )
        }

        let arguments: [String]
        let workingDirectory: String
        let targetSlug: String

        switch target {
        case let .executable(path, explicitWorkingDirectory):
            let resolvedPath = resolveTargetPath(path, prefixPath: bottle.prefixPath)
            let targetWarnings = await inspectTarget(
                resolvedPath: resolvedPath,
                engine: engine,
                skipPEInspection: false
            )
            warnings.append(contentsOf: targetWarnings)
            arguments = [resolvedPath] + extraArgs
            workingDirectory = resolveWorkingDirectory(
                explicit: explicitWorkingDirectory,
                fallbackExecutablePath: resolvedPath,
                prefixPath: bottle.prefixPath
            )
            targetSlug = sanitizeLogSlug(
                URL(fileURLWithPath: resolvedPath).deletingPathExtension().lastPathComponent
            )

        case let .appEntry(app):
            let resolvedPath = resolveTargetPath(app.executablePath, prefixPath: bottle.prefixPath)
            let targetWarnings = await inspectTarget(
                resolvedPath: resolvedPath,
                engine: engine,
                skipPEInspection: false
            )
            warnings.append(contentsOf: targetWarnings)
            arguments = [resolvedPath] + app.arguments + extraArgs
            workingDirectory = resolveWorkingDirectory(
                explicit: app.workingDirectory,
                fallbackExecutablePath: resolvedPath,
                prefixPath: bottle.prefixPath
            )
            targetSlug = sanitizeLogSlug(app.name)

        case let .installer(path):
            let resolvedPath = resolveTargetPath(path, prefixPath: bottle.prefixPath)
            let isMSI = resolvedPath.lowercased().hasSuffix(".msi")
            // L-009: .msi 不是 PE 文件，必须跳过 PEInspector 并转换为 Windows 路径传给 msiexec /i
            let targetWarnings = await inspectTarget(
                resolvedPath: resolvedPath,
                engine: engine,
                skipPEInspection: isMSI
            )
            warnings.append(contentsOf: targetWarnings)

            if isMSI {
                let windowsPath = ShellQuoting.toWindowsPath(
                    unixPath: resolvedPath,
                    prefixPath: bottle.prefixPath
                )
                arguments = ["msiexec", "/i", windowsPath] + extraArgs
            } else {
                arguments = [resolvedPath] + extraArgs
            }
            workingDirectory = resolveWorkingDirectory(
                explicit: nil,
                fallbackExecutablePath: resolvedPath,
                prefixPath: bottle.prefixPath
            )
            targetSlug = sanitizeLogSlug(
                URL(fileURLWithPath: resolvedPath).deletingPathExtension().lastPathComponent
            )

        case let .builtinTool(tool, toolExtraArguments):
            arguments = [tool.rawValue] + toolExtraArguments + extraArgs
            workingDirectory = resolveWorkingDirectory(
                explicit: nil,
                fallbackExecutablePath: nil,
                prefixPath: bottle.prefixPath
            )
            targetSlug = sanitizeLogSlug(tool.rawValue)
        }

        let logFileName = "\(Self.formatLogTimestamp(VermouthJSON.currentTimestamp()))-\(targetSlug).log"
        let logFilePath = paths
            .bottleLogsDirectory(id: bottle.id)
            .appendingPathComponent(logFileName, isDirectory: false)
            .path

        let shellCommandPreview = ShellQuoting.formatCommand(
            environment: environment,
            executable: engine.wineBinaryPath,
            arguments: arguments
        )

        return LaunchPlan(
            bottleID: bottle.id,
            engine: engine,
            executablePath: engine.wineBinaryPath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            warnings: warnings,
            logFilePath: logFilePath,
            shellCommandPreview: shellCommandPreview
        )
    }

    // MARK: - Interactive Terminal Script

    /// 生成与 `LaunchPlan` 同源的 POSIX 交互式终端预注入脚本（L-003、L-015）。
    public func buildInteractiveTerminalScript(
        bottle: Bottle,
        engine: WineEngine,
        graphicsPackage: GraphicsLayerPackage?
    ) throws -> String {
        let envBuild = buildEnvironment(
            bottle: bottle,
            engine: engine,
            graphicsPackage: graphicsPackage,
            appDllOverrides: [],
            appEnvironmentOverrides: [:],
            debugChannelsOverride: nil
        )

        let safeBottleName = sanitizeSingleLineComment(bottle.name)
        let safeEngineName = sanitizeSingleLineComment(engine.name)
        let safeEngineVersion = sanitizeSingleLineComment(engine.version)

        var lines: [String] = [
            "#!/usr/bin/env bash",
            "# Vermouth Interactive Wine Environment",
            "# Bottle: \(safeBottleName) (\(bottle.id.uuidString))",
            "# Engine: \(safeEngineName) (\(safeEngineVersion))",
            "# Graphics: \(bottle.config.graphicsBackend.rawValue) | Sync: \(bottle.config.syncMode.rawValue)",
            "",
        ]

        // L-015: 仅允许合法 POSIX 环境变量标识符进入 export 语句，防命令注入
        for key in envBuild.environment.keys.sorted() {
            guard ShellQuoting.isValidPOSIXIdentifier(key),
                  let value = envBuild.environment[key]
            else {
                continue
            }
            lines.append("export \(key)=\(Self.singleQuote(value))")
        }

        let driveCPath = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
            .standardizedFileURL
            .path
        let prefixPath = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .standardizedFileURL
            .path

        lines.append("")
        lines.append("if [ -d \(Self.singleQuote(driveCPath)) ]; then")
        lines.append("    cd \(Self.singleQuote(driveCPath))")
        lines.append("elif [ -d \(Self.singleQuote(prefixPath)) ]; then")
        lines.append("    cd \(Self.singleQuote(prefixPath))")
        lines.append("fi")
        lines.append("")

        let banner = "Vermouth shell ready: \(safeBottleName) [engine=\(safeEngineName), backend=\(bottle.config.graphicsBackend.rawValue), sync=\(bottle.config.syncMode.rawValue)]"
        lines.append("printf '%s\\n' \(Self.singleQuote(banner))")

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Unified Environment Assembly

    internal struct EnvironmentBuildResult: Sendable {
        let environment: [String: String]
        let warnings: [DiagnosticFinding]
    }

    internal func buildEnvironment(
        bottle: Bottle,
        engine: WineEngine,
        graphicsPackage: GraphicsLayerPackage?,
        appDllOverrides: [DllOverride],
        appEnvironmentOverrides: [String: String],
        debugChannelsOverride: String?
    ) -> EnvironmentBuildResult {
        var env: [String: String] = [:]
        var warnings: [DiagnosticFinding] = []

        // 1. 基础容器与引擎路径
        env["WINEPREFIX"] = bottle.prefixPath
        let engineBinDir = URL(fileURLWithPath: engine.rootPath, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .standardizedFileURL
            .path
        env["PATH"] = "\(engineBinDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // 2. 同步模式（L-003: 显式写全 WINEMSYNC / WINEESYNC，杜绝 msync_init 冲突）
        let syncEnv = Self.syncEnvironment(for: bottle.config.syncMode)
        for (key, value) in syncEnv {
            env[key] = value
        }

        // 3. 显示与性能叠加
        if bottle.config.display.metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }

        // 4. 中文 Locale 补全
        if bottle.config.locale.chineseLocalizationEnabled {
            let trimmedLocale = bottle.config.locale.lcAll.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveLocale = trimmedLocale.isEmpty ? "zh_CN.UTF-8" : trimmedLocale
            env["LC_ALL"] = effectiveLocale
            env["LANG"] = effectiveLocale
        }

        // 5. WINEDEBUG 调试通道合成
        if let debugValue = Self.resolveWineDebug(
            base: bottle.config.wineDebugChannels,
            override: debugChannelsOverride
        ) {
            env["WINEDEBUG"] = debugValue
        }

        // 6. 图形转译层 WINEDLLPATH_PREPEND（L-001）
        if bottle.config.graphicsBackend != .wined3d,
           let pkg = graphicsPackage,
           pkg.format == .wineBuiltin
        {
            if engine.capabilities.supportsWineDLLPathPrepend {
                env["WINEDLLPATH_PREPEND"] = pkg.installPath
            } else {
                warnings.append(
                    DiagnosticFinding(
                        id: "graphics-missing-winedllpath-prepend-\(pkg.id)",
                        category: .graphicsInitFailed,
                        severity: .error,
                        title: "Wine 引擎不支持 WINEDLLPATH_PREPEND",
                        explanation: "图形包 \(pkg.id) 为 wineBuiltin 格式，必须通过 WINEDLLPATH_PREPEND 加载，但引擎 \"\(engine.name)\" 未检测到该能力。",
                        suggestion: "请切换支持 WINEDLLPATH_PREPEND 的 Wine 引擎，或将容器图形后端切换为 DXVK (nativeDLLs) / WineD3D。",
                        quickFix: .switchGraphicsBackend(.wined3d)
                    )
                )
            }
        }

        // 7. WINEDLLOVERRIDES（L-001 / L-002 / L-011）
        let overrideResolution = DllOverrideFormatter.resolve(
            graphicsBackend: bottle.config.graphicsBackend,
            graphicsPackage: graphicsPackage,
            bottleOverrides: bottle.config.dllOverrides,
            appOverrides: appDllOverrides
        )
        warnings.append(contentsOf: overrideResolution.warnings)
        if !overrideResolution.formattedValue.isEmpty {
            env["WINEDLLOVERRIDES"] = overrideResolution.formattedValue
        }

        // 8. 合并用户自定义环境变量（容器级 → 单程序级），并强制执行 L-004 WoW64 保护
        var mergedUserEnv: [String: String] = [:]
        for (key, value) in bottle.config.environmentVariables {
            mergedUserEnv[key] = value
        }
        for (key, value) in appEnvironmentOverrides {
            mergedUserEnv[key] = value
        }

        for key in mergedUserEnv.keys.sorted() {
            guard !key.isEmpty,
                  !key.contains("="),
                  !key.contains("\0"),
                  let value = mergedUserEnv[key]
            else {
                continue
            }

            // L-004: 新 WoW64 单二进制引擎禁止设置 WINEARCH=win32
            if engine.capabilities.isNewWoW64,
               key == "WINEARCH",
               value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "win32"
            {
                warnings.append(
                    DiagnosticFinding(
                        id: "wow64-ignored-winearch-win32",
                        category: .architectureMismatch,
                        severity: .warning,
                        title: "已忽略新 WoW64 引擎上的 WINEARCH=win32",
                        explanation: "引擎 \"\(engine.name)\" 为新 WoW64 单二进制模式，原生同时支持 32 位与 64 位程序；手动设置 WINEARCH=win32 会破坏 WoW64 容器初始化。",
                        suggestion: "建议从容器或程序环境变量中移除 WINEARCH=win32。"
                    )
                )
                continue
            }

            env[key] = value
        }

        return EnvironmentBuildResult(environment: env, warnings: warnings)
    }

    internal static func syncEnvironment(for syncMode: SyncMode) -> [String: String] {
        switch syncMode {
        case .msync:
            return ["WINEMSYNC": "1", "WINEESYNC": "0"]
        case .esync:
            return ["WINEMSYNC": "0", "WINEESYNC": "1"]
        case .none:
            return ["WINEMSYNC": "0", "WINEESYNC": "0"]
        }
    }

    // MARK: - Target Inspection & Helpers

    private func inspectTarget(
        resolvedPath: String,
        engine: WineEngine,
        skipPEInspection: Bool
    ) async -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []

        if await systemProber.isQuarantined(path: resolvedPath) {
            findings.append(
                DiagnosticFinding(
                    id: "quarantine-target-\(resolvedPath)",
                    category: .quarantineBlocked,
                    severity: .warning,
                    title: "目标文件带有 macOS 隔离属性（com.apple.quarantine）",
                    explanation: "文件 \(resolvedPath) 存在 com.apple.quarantine 扩展属性，可能被 macOS Gatekeeper 阻止执行或加载。",
                    suggestion: "建议仅对该文件解除隔离属性后再运行。",
                    quickFix: .removeQuarantine(path: resolvedPath, recursive: false)
                )
            )
        }

        if !skipPEInspection {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir),
               !isDir.boolValue,
               let inspection = try? PEInspector.inspect(fileAtPath: resolvedPath)
            {
                if inspection.architecture == .x86_32 && !engine.capabilities.supports32Bit {
                    findings.append(
                        DiagnosticFinding(
                            id: "arch-mismatch-x86_32-\(engine.id)",
                            category: .architectureMismatch,
                            severity: .warning,
                            title: "32 位 Windows 程序与当前纯 64 位 Wine 引擎不兼容",
                            explanation: "目标程序 \(resolvedPath) 为 32 位 x86 PE 可执行文件，但当前引擎 \"\(engine.name)\" 不支持运行 32 位程序。",
                            suggestion: "请切换为支持 WoW64 / 32 位的 Wine 引擎（如 Wine Stable 11+ 或 Wine Crossover）。",
                            quickFix: .select32BitCapableEngine
                        )
                    )
                }
            }
        }

        return findings
    }

    private func resolveTargetPath(_ rawPath: String, prefixPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(suffix)
                .standardizedFileURL
                .path
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
    }

    private func resolveWorkingDirectory(
        explicit: String?,
        fallbackExecutablePath: String?,
        prefixPath: String
    ) -> String {
        if let explicit {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return resolveTargetPath(trimmed, prefixPath: prefixPath)
            }
        }
        if let fallbackExecutablePath {
            return URL(fileURLWithPath: fallbackExecutablePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
        }
        return URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
            .standardizedFileURL
            .path
    }

    private func enclosingAppBundlePath(for rawPath: String) -> String? {
        var current = URL(fileURLWithPath: rawPath).standardizedFileURL
        while current.path != "/" && !current.path.isEmpty {
            if current.pathExtension.lowercased() == "app" {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }

    private static func resolveWineDebug(base: String, override: String?) -> String? {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawOverride = override else {
            return trimmedBase.isEmpty ? nil : trimmedBase
        }
        let trimmedOverride = rawOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOverride.isEmpty else {
            return trimmedBase.isEmpty ? nil : trimmedBase
        }

        let startsWithSign = trimmedOverride.hasPrefix("+") || trimmedOverride.hasPrefix("-")
        if startsWithSign && !containsAllReset(trimmedOverride) && !trimmedBase.isEmpty {
            return "\(trimmedBase),\(trimmedOverride)"
        }
        return trimmedOverride
    }

    private static func containsAllReset(_ channelSpec: String) -> Bool {
        for rawToken in channelSpec.split(separator: ",") {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if token == "all"
                || token == "-all"
                || token == "+all"
                || token.hasSuffix("+all")
                || token.hasSuffix("-all")
            {
                return true
            }
        }
        return false
    }

    private static func singleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func sanitizeSingleLineComment(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeLogSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(trimmed.unicodeScalars.count)
        var lastWasDash = false

        for scalar in trimmed.unicodeScalars {
            let val = scalar.value
            let isAlnum = (0x30...0x39).contains(val)
                || (0x41...0x5A).contains(val)
                || (0x61...0x7A).contains(val)
            if isAlnum || scalar == "_" {
                scalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                scalars.append("-")
                lastWasDash = true
            }
        }

        var slug = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        if slug.count > 48 {
            slug = String(slug.prefix(48))
        }
        return slug.isEmpty ? "wine" : slug
    }

    private static func formatLogTimestamp(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
        var wholeSeconds = totalMs / 1000
        var remainderMs = totalMs % 1000
        if remainderMs < 0 {
            remainderMs += 1000
            wholeSeconds -= 1
        }
        let wholeDate = Date(timeIntervalSince1970: Double(wholeSeconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wholeDate)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1,
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0,
            Int(remainderMs)
        )
    }
}
