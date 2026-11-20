import Foundation

/// 规则化 Wine 运行日志崩溃诊断引擎（遵循 PRD §4.1E、L-003、L-006、L-009）：
/// 实时识别缺 DLL、Quarantine 隔离、32/64 位架构不匹配、图形转译层初始化失败、
/// MSync/ESync 服务端冲突、缺少 Rosetta 2 与中文字体缺失，并附带类型化 `DiagnosticQuickFix`。
public final class CrashDiagnoser: CrashDiagnosing, Sendable {
    public init() {}

    public func diagnose(
        logs: [String],
        preflightWarnings: [DiagnosticFinding] = []
    ) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        var seenIDs = Set<String>()

        for warning in preflightWarnings {
            if seenIDs.insert(warning.id).inserted {
                findings.append(warning)
            }
        }

        for entry in logs {
            for rawLine in entry.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                for finding in diagnoseLine(line) {
                    if seenIDs.insert(finding.id).inserted {
                        findings.append(finding)
                    }
                }
            }
        }

        return findings
    }

    public func diagnoseLine(_ line: String) -> [DiagnosticFinding] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 已知无害的报错（如 Steam 可选探测工具缺 SDL2.dll）不生成诊断
        if KnownBenignLogLines.match(trimmed) != nil {
            return []
        }

        var matches: [DiagnosticFinding] = []

        if let finding = matchMissingDLL(trimmed) {
            matches.append(finding)
        }
        if let finding = matchQuarantineBlocked(trimmed) {
            matches.append(finding)
        }
        if let finding = matchRosettaMissing(trimmed) {
            matches.append(finding)
        }
        if let finding = matchArchitectureMismatch(trimmed) {
            matches.append(finding)
        }
        if let finding = matchDXVKAdapterMismatch(trimmed) {
            matches.append(finding)
        } else if let finding = matchGraphicsInitFailed(trimmed) {
            matches.append(finding)
        }
        if let finding = matchSyncMismatch(trimmed) {
            matches.append(finding)
        }
        if let finding = matchFontOrLocale(trimmed) {
            matches.append(finding)
        }

        return matches
    }

    // MARK: - Rule 1: Missing DLL

    private func matchMissingDLL(_ line: String) -> DiagnosticFinding? {
        let patterns = [
            #"(?i)err:module:import_dll\s+Library\s+([^\s("']+\.dll)"#,
            #"(?i)err:module:LdrInitializeThunk\s+"([^"]+\.dll)"\s+failed to initialize"#,
            #"(?i)([^\s/:"']+\.dll)[^:\n]*:\s*cannot open shared object file"#,
            #"(?i)cannot open shared object file[^\n]*?([^\s/:"']+\.dll)"#,
        ]

        guard let rawDLL = firstCapture(in: line, patterns: patterns) else {
            return nil
        }

        let dllName = rawDLL.lowercased()
        let runtimeInfo = Self.runtimeHint(forDLL: dllName)

        let suggestion: String
        let quickFix: DiagnosticQuickFix?
        if let runtimeInfo {
            suggestion = "建议为当前容器安装 \(runtimeInfo.displayName) 运行库（可通过 winetricks 安装 `\(runtimeInfo.winetricksVerb)`），或确认该 DLL 是否应随软件目录附带。"
            quickFix = .copyCommand(
                label: "复制 winetricks 安装命令 (\(runtimeInfo.winetricksVerb))",
                command: "winetricks -q \(runtimeInfo.winetricksVerb)"
            )
        } else {
            suggestion = "请确认缺失的 \(dllName) 是否应位于程序同级目录或容器 `drive_c/windows/system32` 中，或检查是否需要配置 DLL 覆写。"
            quickFix = nil
        }

        return DiagnosticFinding(
            id: "missing-dll-\(dllName)",
            category: .missingDLL,
            severity: .error,
            title: "缺少 Windows 动态链接库：\(dllName)",
            explanation: "程序启动或初始化阶段无法加载 \(dllName)，通常因为容器缺少对应的 Windows 运行库或程序附带组件。",
            suggestion: suggestion,
            matchedLine: line,
            missingDLLName: dllName,
            recommendedRuntime: runtimeInfo?.displayName,
            quickFix: quickFix
        )
    }

    // MARK: - Rule 2: Quarantine / Gatekeeper Blocked

    private func matchQuarantineBlocked(_ line: String) -> DiagnosticFinding? {
        let isQuarantineError =
            matches(line, pattern: #"(?i)com\.apple\.quarantine"#)
            || matches(line, pattern: #"(?i)code signature invalid"#)
            || matches(line, pattern: #"(?i)Library Validation"#)
            || (matches(line, pattern: #"(?i)Operation not permitted"#)
                && matches(line, pattern: #"(?i)(\.exe|\.dll|\.so|\.dylib|\.app|\bwine\b)"#))

        guard isQuarantineError else { return nil }

        let extractedPath = firstCapture(
            in: line,
            patterns: [
                #"((?:/Applications|/Users|/Volumes|/opt|/tmp|/var)[^:\n'"]*?\.app)(?=/|[:\s'"]|$)"#,
                #"((?:/Applications|/Users|/Volumes|/opt|/tmp|/var)[^:\n'"]*?\.(?:exe|dll|msi|so|dylib))(?=\b|[:\s'"]|$)"#,
                #"((?:/Applications|/Users|/Volumes|/opt|/tmp|/var)[^\s:'"]+)"#,
            ]
        )

        let safeExtractedPath: String?
        if let candidate = extractedPath?.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}>\"'")),
           !Self.isForbiddenBroadQuarantinePath(candidate)
        {
            safeExtractedPath = candidate
        } else {
            safeExtractedPath = nil
        }

        let quickFix: DiagnosticQuickFix?
        let id: String
        let suggestion: String

        if let safeExtractedPath {
            let isAppBundle = safeExtractedPath.lowercased().hasSuffix(".app")
            id = "quarantine-blocked-\(safeExtractedPath.lowercased())"
            quickFix = .removeQuarantine(path: safeExtractedPath, recursive: isAppBundle)
            suggestion = "请解除路径 \(safeExtractedPath) 的 macOS 隔离属性（com.apple.quarantine）后重试启动。"
        } else {
            id = "quarantine-blocked"
            quickFix = nil
            suggestion = "请检查目标 `.exe`、Mod DLL 或 Wine 引擎 `.app` 是否带有 macOS 隔离属性（com.apple.quarantine），并在界面中针对单个文件或引擎目录手动解除隔离。"
        }

        return DiagnosticFinding(
            id: id,
            category: .quarantineBlocked,
            severity: .error,
            title: "macOS 隔离属性或签名拦截（Gatekeeper）",
            explanation: "浏览器下载的 Windows 程序、插件或 Wine 引擎带有 `com.apple.quarantine` 属性或被系统签名策略阻止执行。",
            suggestion: suggestion,
            matchedLine: line,
            quickFix: quickFix
        )
    }

    // MARK: - Rule 3: Architecture Mismatch

    private func matchArchitectureMismatch(_ line: String) -> DiagnosticFinding? {
        // Avoid double-classifying Rosetta 2 `arch: posix_spawnp: ... Bad CPU type in executable`
        if matches(line, pattern: #"(?i)arch:\s*posix_spawnp:"#) {
            return nil
        }

        let isArchMismatch =
            matches(line, pattern: #"(?i)Bad EXE format for"#)
            || matches(line, pattern: #"(?i)err:module:process_init[^\n]*32-bit"#)
            || matches(line, pattern: #"(?i)wine:\s*could not load[^\n]*Bad CPU type"#)
            || matches(line, pattern: #"(?i)wrong architecture"#)

        guard isArchMismatch else { return nil }

        return DiagnosticFinding(
            id: "architecture-mismatch",
            category: .architectureMismatch,
            severity: .error,
            title: "32 位 / 64 位程序架构与当前引擎不匹配",
            explanation: "当前选用的 Wine 引擎无法加载该目标程序的 CPU 架构（典型为用纯 64 位引擎启动了 32 位 x86 Windows 程序）。",
            suggestion: "请为该容器切换支持 32 位 WoW64 的 Wine 引擎（例如 Wine Stable 11+ WoW64 或 Wine Crossover），切勿在新 WoW64 引擎上手动设置 WINEARCH=win32。",
            matchedLine: line,
            quickFix: .select32BitCapableEngine
        )
    }

    // MARK: - Rule 4: Graphics Stack Initialization Failed

    private func matchGraphicsInitFailed(_ line: String) -> DiagnosticFinding? {
        let isGraphicsFailure =
            matches(line, pattern: #"(?i)winemetal[^\n]*(err|fail|fatal|cannot|unable|abort|not found|missing)"#)
            || matches(line, pattern: #"(?i)(err:|fatal|failed)[^\n]*winemetal"#)
            || matches(line, pattern: #"(?i)\bdxmt\b[^\n]*(fatal|assert|fail|error|panic)"#)
            || matches(line, pattern: #"(?i)vkCreateInstance\s+failed"#)
            || matches(line, pattern: #"(?i)Failed to initialize DXVK"#)
            || matches(line, pattern: #"(?i)err:vulkan:"#)
            || matches(line, pattern: #"(?i)err:d3d:wined3d_adapter_init"#)
            || matches(line, pattern: #"(?i)Required Vulkan extension"#)

        guard isGraphicsFailure else { return nil }

        return DiagnosticFinding(
            id: "graphics-init-failed",
            category: .graphicsInitFailed,
            severity: .error,
            title: "DirectX / Metal / Vulkan 图形转译层初始化失败",
            explanation: "图形后端（DXMT、DXVK-macOS 或 WineD3D）未能成功初始化渲染设备，可能因为图形包与引擎不匹配、缺少 Vulkan/Metal 扩展或旧版 DX9 程序误选 DXMT/DXVK。",
            suggestion: "建议先一键切换回内置 `WineD3D` 验证程序能否启动，或确认 DXMT builtin 包已搭配支持 `WINEDLLPATH_PREPEND` 的 Wine 引擎且未设置冲突的 `=n,b` DLL 覆写。",
            matchedLine: line,
            quickFix: .switchGraphicsBackend(.wined3d)
        )
    }

    // MARK: - Rule 4b: DXVK d3d11 Running on Wine's Builtin dxgi

    private func matchDXVKAdapterMismatch(_ line: String) -> DiagnosticFinding? {
        guard matches(line, pattern: #"(?i)Adapter is not a DXVK adapter"#) else { return nil }

        return DiagnosticFinding(
            id: "dxvk-adapter-mismatch",
            category: .graphicsInitFailed,
            severity: .error,
            title: "DXVK 的 d3d11 与 Wine 内置 dxgi 混用",
            explanation: "DXVK 的 d3d11 只能使用 DXVK 自己的 dxgi 适配器。当前容器部署的 DXVK 包不含 dxgi.dll（如 Gcenx 的 -repack 包），实际加载的是 Wine 内置 dxgi，D3D11 设备创建失败。",
            suggestion: "请改用包含 dxgi.dll 的 DXVK 包，或切换回 WineD3D。",
            matchedLine: line,
            quickFix: .switchGraphicsBackend(.wined3d)
        )
    }

    // MARK: - Rule 5: MSync / ESync Wineserver Mismatch (L-003)

    private func matchSyncMismatch(_ line: String) -> DiagnosticFinding? {
        let isSyncError =
            matches(line, pattern: #"(?i)msync_init"#)
            || matches(line, pattern: #"(?i)esync_init"#)
            || matches(line, pattern: #"(?i)wineserver[^\n]*version mismatch"#)
            || matches(line, pattern: #"(?i)version mismatch[^\n]*wineserver"#)
            || matches(line, pattern: #"(?i)protocol version mismatch"#)

        guard isSyncError else { return nil }

        return DiagnosticFinding(
            id: "sync-mismatch",
            category: .syncMismatch,
            severity: .error,
            title: "Wineserver 同步模式或协议版本冲突（MSync / ESync）",
            explanation: "同一容器（WINEPREFIX）中已有后台 `wineserver` 以不同的同步模式（MSync/ESync）或不同 Wine 引擎版本运行，导致新进程接入失败。",
            suggestion: "请先一键终止当前容器残留的 `wineserver` 进程，再重新启动程序。",
            matchedLine: line,
            quickFix: .killWineServer
        )
    }

    // MARK: - Rule 6: Missing Rosetta 2

    private func matchRosettaMissing(_ line: String) -> DiagnosticFinding? {
        let isRosettaError =
            matches(line, pattern: #"(?i)arch:\s*posix_spawnp:[^\n]*Bad CPU type in executable"#)
            || matches(line, pattern: #"(?i)rosetta error:"#)

        guard isRosettaError else { return nil }

        return DiagnosticFinding(
            id: "rosetta-missing",
            category: .rosettaMissing,
            severity: .error,
            title: "缺少 Rosetta 2 转译组件",
            explanation: "Apple Silicon Mac 运行 x86_64/x86 Wine 与 Windows 程序依赖 macOS 内置的 Rosetta 2。",
            suggestion: "请在终端运行 `softwareupdate --install-rosetta --agree-to-license` 完成 Rosetta 2 安装后重试。",
            matchedLine: line,
            quickFix: .copyCommand(
                label: "安装 Rosetta 2",
                command: "softwareupdate --install-rosetta --agree-to-license"
            )
        )
    }

    // MARK: - Rule 7: Font / CJK Mojibake Hint

    private func matchFontOrLocale(_ line: String) -> DiagnosticFinding? {
        let isFontIssue =
            matches(line, pattern: #"(?i)err:font:"#)
            || matches(line, pattern: #"(?i)cannot find font"#)

        guard isFontIssue else { return nil }

        return DiagnosticFinding(
            id: "font-or-locale",
            category: .fontOrLocale,
            severity: .warning,
            title: "检测到字体缺失或字符集警告",
            explanation: "Wine 报告缺少部分字体映射，可能导致中文界面或对话框显示方块乱码。",
            suggestion: "建议一键开启当前容器的「中文环境与字体映射补全」并重新应用注册表配置。",
            matchedLine: line,
            quickFix: .enableChineseLocalization
        )
    }

    // MARK: - DLL Runtime Lookup Table

    private struct RuntimeHint: Sendable {
        let displayName: String
        let winetricksVerb: String
    }

    private static func runtimeHint(forDLL dllName: String) -> RuntimeHint? {
        let lower = dllName.lowercased()
        if lower.hasPrefix("vcruntime140")
            || lower.hasPrefix("msvcp140")
            || lower.hasPrefix("concrt140")
            || lower.hasPrefix("ucrtbase")
            || lower.hasPrefix("api-ms-win-crt")
        {
            return RuntimeHint(displayName: "vcrun2022", winetricksVerb: "vcrun2022")
        }
        if lower.hasPrefix("msvcr120") || lower.hasPrefix("msvcp120") {
            return RuntimeHint(displayName: "vcrun2013", winetricksVerb: "vcrun2013")
        }
        if lower.hasPrefix("msvcr110") || lower.hasPrefix("msvcp110") {
            return RuntimeHint(displayName: "vcrun2012", winetricksVerb: "vcrun2012")
        }
        if lower.hasPrefix("msvcr100") || lower.hasPrefix("msvcp100") {
            return RuntimeHint(displayName: "vcrun2010", winetricksVerb: "vcrun2010")
        }
        if lower.hasPrefix("d3dx9_")
            || lower.hasPrefix("xinput1_")
            || lower.hasPrefix("x3daudio")
            || lower.hasPrefix("xactengine")
        {
            return RuntimeHint(displayName: "d3dx9 / directx9", winetricksVerb: "d3dx9")
        }
        if lower.hasPrefix("d3dcompiler_47") {
            return RuntimeHint(displayName: "d3dcompiler_47", winetricksVerb: "d3dcompiler_47")
        }
        if lower.hasPrefix("d3dcompiler_43") {
            return RuntimeHint(displayName: "d3dcompiler_43", winetricksVerb: "d3dcompiler_43")
        }
        if lower == "mscoree.dll" {
            return RuntimeHint(displayName: "dotnet / wine-mono", winetricksVerb: "dotnet48")
        }
        if lower == "mfplat.dll" || lower == "mfreadwrite.dll" || lower == "mf.dll" {
            return RuntimeHint(displayName: "mf (Media Foundation)", winetricksVerb: "mf")
        }
        return nil
    }

    private static func isForbiddenBroadQuarantinePath(_ rawPath: String) -> Bool {
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let broadPaths: Set<String> = [
            "/",
            "/Applications",
            "/Users",
            "/Volumes",
            "/opt",
            "/tmp",
            "/var",
            "/System",
            "/Library",
        ]
        if broadPaths.contains(standardized) {
            return true
        }
        // Reject /Users/<name> and /Users/<name>/Downloads|Desktop|Documents directly
        let components = standardized.split(separator: "/")
        if components.count == 2 && components[0] == "Users" {
            return true
        }
        if components.count == 3 && components[0] == "Users" {
            let sub = components[2].lowercased()
            if sub == "downloads" || sub == "desktop" || sub == "documents" || sub == "library" || sub == "applications" {
                return true
            }
        }
        return false
    }

    // MARK: - Regex Helpers

    private func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let nsRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: nsRange) != nil
    }

    private func firstCapture(in text: String, patterns: [String]) -> String? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if let match = regex.firstMatch(in: text, range: fullRange),
               match.numberOfRanges >= 2
            {
                let range = match.range(at: 1)
                if range.location != NSNotFound {
                    let captured = nsText.substring(with: range)
                    if !captured.isEmpty {
                        return captured
                    }
                }
            }
        }
        return nil
    }
}
