import Foundation

/// 可注入的 Wine 引擎候选探测根路径配置（测试时可显式传入以隔离宿主机 `/Applications`）。
public struct EngineCandidateRoot: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let rootPath: String
    public let source: EngineSource
    /// 检查 `com.apple.quarantine` 时优先检查的路径（例如 `.app` 根目录）；默认与 `rootPath` 相同。
    public let quarantineCheckPath: String

    public init(
        id: String,
        displayName: String,
        rootPath: String,
        source: EngineSource,
        quarantineCheckPath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.source = source
        self.quarantineCheckPath = quarantineCheckPath ?? rootPath
    }
}

/// 持久化在 `engines.json` 中的用户自定义登记引擎条目。
public struct CustomEngineEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var rootPath: String

    public init(id: String, name: String, rootPath: String) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
    }
}

/// `engines.json` 持久化配置结构。
public struct EnginesConfigFile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var defaultEngineID: String?
    public var customEngines: [CustomEngineEntry]

    public init(
        schemaVersion: Int = EnginesConfigFile.currentSchemaVersion,
        defaultEngineID: String? = nil,
        customEngines: [CustomEngineEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.defaultEngineID = defaultEngineID
        self.customEngines = customEngines
    }
}

/// 并发安全的 `engines.json` 读写隔离 Actor，避免在 `async` 上下文中使用 `NSLock`。
private actor EngineConfigStore {
    private let configURL: URL

    init(configURL: URL) {
        self.configURL = configURL
    }

    func load() throws -> EnginesConfigFile {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return EnginesConfigFile()
        }
        let config = try VermouthJSON.read(EnginesConfigFile.self, from: configURL)
        guard config.schemaVersion <= EnginesConfigFile.currentSchemaVersion else {
            throw VermouthError.unsupportedSchemaVersion(
                found: config.schemaVersion,
                supported: EnginesConfigFile.currentSchemaVersion,
                path: configURL.path
            )
        }
        return config
    }

    func save(_ config: EnginesConfigFile) throws {
        try VermouthJSON.writeAtomically(config, to: configURL)
    }
}

/// Wine 引擎发现、确定性只读能力探测、自定义登记与环境预检核心实现（遵循 L-004 / L-005 / L-006）。
public final class EngineManager: EngineManaging, Sendable {
    private static let binaryScanChunkSize = 65_536
    private static let binaryScanMaxBytes = 32 * 1024 * 1024

    private static let markerWineDLLPathPrepend = Array("WINEDLLPATH_PREPEND".utf8)
    private static let markerWineMSync = Array("WINEMSYNC".utf8)

    private let paths: VermouthPaths
    private let commandRunner: any CommandRunning
    private let systemProber: any SystemProbing
    private let injectedCandidateRoots: [EngineCandidateRoot]?
    private let configStore: EngineConfigStore

    public init(
        paths: VermouthPaths,
        commandRunner: any CommandRunning,
        systemProber: any SystemProbing,
        candidateRoots: [EngineCandidateRoot]? = nil
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.systemProber = systemProber
        self.injectedCandidateRoots = candidateRoots
        self.configStore = EngineConfigStore(configURL: paths.enginesConfigURL)
    }

    /// 标准 macOS 多来源 Wine 引擎探测候选列表（L-004）。
    public static func defaultMacOSCandidateRoots() -> [EngineCandidateRoot] {
        [
            EngineCandidateRoot(
                id: "app-wine-stable",
                displayName: "Wine Stable",
                rootPath: "/Applications/Wine Stable.app/Contents/Resources/wine",
                source: .homebrewCask,
                quarantineCheckPath: "/Applications/Wine Stable.app"
            ),
            EngineCandidateRoot(
                id: "app-wine-staging",
                displayName: "Wine Staging",
                rootPath: "/Applications/Wine Staging.app/Contents/Resources/wine",
                source: .homebrewCask,
                quarantineCheckPath: "/Applications/Wine Staging.app"
            ),
            EngineCandidateRoot(
                id: "app-wine-devel",
                displayName: "Wine Devel",
                rootPath: "/Applications/Wine Devel.app/Contents/Resources/wine",
                source: .homebrewCask,
                quarantineCheckPath: "/Applications/Wine Devel.app"
            ),
            EngineCandidateRoot(
                id: "app-wine-crossover",
                displayName: "Wine Crossover",
                rootPath: "/Applications/Wine Crossover.app/Contents/Resources/wine",
                source: .homebrewCask,
                quarantineCheckPath: "/Applications/Wine Crossover.app"
            ),
            EngineCandidateRoot(
                id: "app-crossover",
                displayName: "CrossOver",
                rootPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver",
                source: .applicationBundle,
                quarantineCheckPath: "/Applications/CrossOver.app"
            ),
            EngineCandidateRoot(
                id: "homebrew-arm64",
                displayName: "Homebrew Wine",
                rootPath: "/opt/homebrew",
                source: .homebrewCask
            ),
            EngineCandidateRoot(
                id: "homebrew-x86_64",
                displayName: "Homebrew Wine (Intel)",
                rootPath: "/usr/local",
                source: .homebrewCask
            ),
        ]
    }

    // MARK: - EngineManaging

    public func runPreflight() async -> PreflightReport {
        let architecture = systemProber.hostArchitecture()
        let osVersion = systemProber.operatingSystemVersion()
        let rosetta2Ready = await systemProber.isRosetta2Installed()
        let homebrewPath = systemProber.findExecutable(
            named: "brew",
            searchPaths: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
        let winetricksPath = systemProber.findExecutable(
            named: "winetricks",
            searchPaths: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
        let discoveredEngines = (try? await listEngines()) ?? []

        var items: [PreflightCheckItem] = []

        // 1. Host Architecture
        switch architecture {
        case .arm64:
            items.append(
                PreflightCheckItem(
                    id: "host-architecture",
                    title: "处理器架构",
                    status: .pass,
                    detail: "Apple Silicon (arm64)"
                )
            )
        case .x86_64:
            items.append(
                PreflightCheckItem(
                    id: "host-architecture",
                    title: "处理器架构",
                    status: .warning,
                    detail: "Intel Mac (x86_64) — Vermouth 优先针对 Apple Silicon 优化"
                )
            )
        case .unknown:
            items.append(
                PreflightCheckItem(
                    id: "host-architecture",
                    title: "处理器架构",
                    status: .warning,
                    detail: "未能识别宿主机处理器架构"
                )
            )
        }

        // 2. macOS Version (>= 14.0)
        if osVersion.isAtLeast(major: 14, minor: 0) {
            items.append(
                PreflightCheckItem(
                    id: "os-version",
                    title: "操作系统版本",
                    status: .pass,
                    detail: "\(osVersion.displayString)（满足 macOS 14.0+ 要求）"
                )
            )
        } else {
            items.append(
                PreflightCheckItem(
                    id: "os-version",
                    title: "操作系统版本",
                    status: .fail,
                    detail: "\(osVersion.displayString)（需要 macOS 14.0 Sonoma 或更高版本）"
                )
            )
        }

        // 3. Rosetta 2
        if architecture == .arm64 {
            if rosetta2Ready {
                items.append(
                    PreflightCheckItem(
                        id: "rosetta2",
                        title: "Rosetta 2",
                        status: .pass,
                        detail: "Rosetta 2 已安装就绪"
                    )
                )
            } else {
                items.append(
                    PreflightCheckItem(
                        id: "rosetta2",
                        title: "Rosetta 2",
                        status: .fail,
                        detail: "Apple Silicon 运行 x86/x86_64 Windows 程序需要安装 Rosetta 2",
                        remediationCommand: "softwareupdate --install-rosetta --agree-to-license"
                    )
                )
            }
        } else {
            items.append(
                PreflightCheckItem(
                    id: "rosetta2",
                    title: "Rosetta 2",
                    status: .pass,
                    detail: "非 Apple Silicon 架构，无需 Rosetta 2"
                )
            )
        }

        // 4. Homebrew
        if let homebrewPath {
            items.append(
                PreflightCheckItem(
                    id: "homebrew",
                    title: "Homebrew",
                    status: .pass,
                    detail: "已检测到 Homebrew: \(homebrewPath)"
                )
            )
        } else {
            items.append(
                PreflightCheckItem(
                    id: "homebrew",
                    title: "Homebrew",
                    status: .warning,
                    detail: "未检测到 Homebrew（可选，推荐用于安装开源 Wine 引擎）",
                    remediationCommand: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
                )
            )
        }

        // 5. Winetricks (optional)
        if let winetricksPath {
            items.append(
                PreflightCheckItem(
                    id: "winetricks",
                    title: "Winetricks",
                    status: .pass,
                    detail: "已检测到 winetricks: \(winetricksPath)"
                )
            )
        } else {
            items.append(
                PreflightCheckItem(
                    id: "winetricks",
                    title: "Winetricks",
                    status: .warning,
                    detail: "未检测到 winetricks（可选，用于补充 VC++ / DirectX 等常见 Windows 运行库）",
                    remediationCommand: "brew install winetricks"
                )
            )
        }

        // 6. Wine Engines
        if discoveredEngines.isEmpty {
            items.append(
                PreflightCheckItem(
                    id: "wine-engines",
                    title: "Wine 引擎",
                    status: .fail,
                    detail: "未检测到可用的 Wine 引擎。推荐通过 Homebrew 安装 Wine Stable (WoW64)，也支持登记已安装的 Wine Crossover.app / CrossOver 或自定义 Wine 目录。",
                    remediationCommand: "brew install --cask --no-quarantine gcenx/wine/wine-stable"
                )
            )
        } else {
            let names = discoveredEngines.map(\.name).joined(separator: "、")
            let allQuarantined = discoveredEngines.allSatisfy(\.isQuarantined)
            if allQuarantined, let firstEngine = discoveredEngines.first {
                let escapedPath = ShellQuoting.posixEscape(firstEngine.rootPath)
                items.append(
                    PreflightCheckItem(
                        id: "wine-engines",
                        title: "Wine 引擎",
                        status: .warning,
                        detail: "已检测到 \(discoveredEngines.count) 套 Wine 引擎（\(names)），但带有 macOS 隔离属性 (com.apple.quarantine)，可能被 Gatekeeper 拦截。",
                        remediationCommand: "xattr -dr com.apple.quarantine \(escapedPath)"
                    )
                )
            } else {
                items.append(
                    PreflightCheckItem(
                        id: "wine-engines",
                        title: "Wine 引擎",
                        status: .pass,
                        detail: "已检测到 \(discoveredEngines.count) 套可用 Wine 引擎：\(names)"
                    )
                )
            }
        }

        let isReadyToLaunch = (architecture == .arm64 ? rosetta2Ready : true) && !discoveredEngines.isEmpty

        return PreflightReport(
            checkedAt: Date(),
            architecture: architecture,
            osVersion: osVersion,
            rosetta2Ready: rosetta2Ready,
            homebrewPath: homebrewPath,
            winetricksPath: winetricksPath,
            discoveredEngines: discoveredEngines,
            items: items,
            isReadyToLaunch: isReadyToLaunch
        )
    }

    public func listEngines() async throws -> [WineEngine] {
        let config = try await configStore.load()
        var candidates: [EngineCandidateRoot] = []

        if let injectedCandidateRoots {
            candidates.append(contentsOf: injectedCandidateRoots)
        } else {
            candidates.append(contentsOf: Self.defaultMacOSCandidateRoots())
        }

        // 扫描应用托管目录 $VERMOUTH_HOME/Engines/*
        candidates.append(contentsOf: managedCandidateRoots())

        var results: [WineEngine] = []
        var seenIDs = Set<String>()
        var seenRoots = Set<String>()

        for candidate in candidates {
            if let engine = await inspectCandidateIfValid(candidate) {
                if seenIDs.insert(engine.id).inserted && seenRoots.insert(engine.rootPath).inserted {
                    results.append(engine)
                }
            }
        }

        // 加载用户通过 registerCustomEngine 登记的自定义引擎
        for custom in config.customEngines {
            let candidate = EngineCandidateRoot(
                id: custom.id,
                displayName: custom.name,
                rootPath: custom.rootPath,
                source: .custom
            )
            if let engine = await inspectCandidateIfValid(candidate) {
                if seenIDs.insert(engine.id).inserted {
                    seenRoots.insert(engine.rootPath)
                    results.append(engine)
                }
            }
        }

        return results
    }

    public func registerCustomEngine(name: String, rootPath: String) async throws -> WineEngine {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw VermouthError.invalidEngineRoot(
                path: rootPath,
                reason: "引擎名称不能为空"
            )
        }

        let resolvedRoot = resolveEffectiveEngineRoot(rootPath)
        var config = try await configStore.load()

        if let existing = config.customEngines.first(where: {
            resolveEffectiveEngineRoot($0.rootPath) == resolvedRoot
        }) {
            throw VermouthError.engineAlreadyRegistered(id: existing.id)
        }

        let engineID = "custom-\(UUID().uuidString.lowercased())"
        let candidate = EngineCandidateRoot(
            id: engineID,
            displayName: trimmedName,
            rootPath: resolvedRoot,
            source: .custom,
            quarantineCheckPath: URL(fileURLWithPath: rootPath).standardizedFileURL.path
        )

        let engine = try await inspectCandidateStrict(candidate)

        config.customEngines.append(
            CustomEngineEntry(id: engine.id, name: trimmedName, rootPath: engine.rootPath)
        )
        try await configStore.save(config)
        return engine
    }

    public func unregisterCustomEngine(id: String) async throws {
        var config = try await configStore.load()
        if let index = config.customEngines.firstIndex(where: { $0.id == id }) {
            config.customEngines.remove(at: index)
            if config.defaultEngineID == id {
                config.defaultEngineID = nil
            }
            try await configStore.save(config)
            return
        }

        let allEngines = try await listEngines()
        if allEngines.contains(where: { $0.id == id }) {
            throw VermouthError.cannotUnregisterDiscoveredEngine(id: id)
        }
        throw VermouthError.engineNotFound(id: id)
    }

    public func defaultEngine() async throws -> WineEngine? {
        let engines = try await listEngines()
        guard !engines.isEmpty else { return nil }

        let config = try await configStore.load()
        if let preferredID = config.defaultEngineID,
           let matched = engines.first(where: { $0.id == preferredID })
        {
            return matched
        }
        return engines.first
    }

    public func setDefaultEngine(id: String) async throws {
        let engines = try await listEngines()
        guard engines.contains(where: { $0.id == id }) else {
            throw VermouthError.engineNotFound(id: id)
        }
        var config = try await configStore.load()
        config.defaultEngineID = id
        try await configStore.save(config)
    }

    // MARK: - Private Discovery & Capability Inspection

    private func managedCandidateRoots() -> [EngineCandidateRoot] {
        let enginesDir = paths.baseDirectory.appendingPathComponent("Engines", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: enginesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .compactMap { entry -> EngineCandidateRoot? in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { return nil }
                let folderName = entry.lastPathComponent
                let safeID = folderName
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                return EngineCandidateRoot(
                    id: "managed-\(safeID)",
                    displayName: folderName,
                    rootPath: entry.path,
                    source: .managed
                )
            }
    }

    private func inspectCandidateIfValid(_ candidate: EngineCandidateRoot) async -> WineEngine? {
        try? await inspectCandidateStrict(candidate)
    }

    private func inspectCandidateStrict(_ candidate: EngineCandidateRoot) async throws -> WineEngine {
        let effectiveRoot = resolveEffectiveEngineRoot(candidate.rootPath)
        let rootURL = URL(fileURLWithPath: effectiveRoot, isDirectory: true)

        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let wineURL = binURL.appendingPathComponent("wine", isDirectory: false)
        let wine64URL = binURL.appendingPathComponent("wine64", isDirectory: false)
        let wine32on64URL = binURL.appendingPathComponent("wine32on64", isDirectory: false)
        let wineserverURL = binURL.appendingPathComponent("wineserver", isDirectory: false)

        let hasWine = isRegularFile(atPath: wineURL.path)
        let hasWine64 = isRegularFile(atPath: wine64URL.path)
        let hasWine32on64 = isRegularFile(atPath: wine32on64URL.path)
        let hasWineserver = isRegularFile(atPath: wineserverURL.path)

        guard hasWine || hasWine64 else {
            throw VermouthError.invalidEngineRoot(
                path: candidate.rootPath,
                reason: "未在 bin/ 下找到 wine 或 wine64 可执行文件"
            )
        }

        guard hasWineserver else {
            throw VermouthError.invalidEngineRoot(
                path: candidate.rootPath,
                reason: "未在 bin/ 下找到 wineserver 可执行文件"
            )
        }

        // L-004: 优先采用 bin/wine（同时兼容新 WoW64 单二进制与传统双二进制），缺失时回退 bin/wine64
        let wineBinaryPath = hasWine ? wineURL.path : wine64URL.path
        let version = await probeWineVersion(wineBinaryPath: wineBinaryPath)
        let majorVersion = Self.parseMajorVersion(from: version)

        let hasI386Windows = isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/i386-windows").path)
            || isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/i386-windows").path)
        let hasI386Unix = isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/i386-unix").path)
            || isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/i386-unix").path)
        let hasX64Windows = isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/x86_64-windows").path)
            || isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/x86_64-windows").path)
        let hasX64Unix = isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/x86_64-unix").path)
            || isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/x86_64-unix").path)

        let isNewWoW64 = hasI386Windows && (
            (majorVersion ?? 0) >= 9
                || (!hasWine64 && hasWine && (hasX64Windows || hasX64Unix))
        )
        let supports32Bit = isNewWoW64 || hasI386Unix || hasWine32on64 || (hasWine && hasI386Windows)
        let supports64Bit = hasX64Windows || hasX64Unix || hasWine64

        let binaryProbePaths = [
            rootURL.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so").path,
            rootURL.appendingPathComponent("lib64/wine/x86_64-unix/ntdll.so").path,
            wineserverURL.path,
        ]
        let foundMarkers = Self.scanFilesForMarkers(
            paths: binaryProbePaths,
            markers: [Self.markerWineDLLPathPrepend, Self.markerWineMSync]
        )

        let capabilities = EngineCapabilities(
            supports32Bit: supports32Bit,
            supports64Bit: supports64Bit,
            isNewWoW64: isNewWoW64,
            supportsMSync: foundMarkers.contains(1),
            supportsWineDLLPathPrepend: foundMarkers.contains(0)
        )

        var quarantined = await systemProber.isQuarantined(path: candidate.quarantineCheckPath)
        if !quarantined && candidate.quarantineCheckPath != wineBinaryPath {
            quarantined = await systemProber.isQuarantined(path: wineBinaryPath)
        }

        let formattedName: String
        if candidate.source == .custom {
            formattedName = candidate.displayName
        } else {
            formattedName = Self.formatDiscoveredName(
                baseName: candidate.displayName,
                version: version,
                isNewWoW64: isNewWoW64
            )
        }

        return WineEngine(
            id: candidate.id,
            name: formattedName,
            rootPath: effectiveRoot,
            wineBinaryPath: wineBinaryPath,
            wineserverPath: wineserverURL.path,
            version: version,
            source: candidate.source,
            capabilities: capabilities,
            isQuarantined: quarantined
        )
    }

    private func resolveEffectiveEngineRoot(_ rawPath: String) -> String {
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let directBin = URL(fileURLWithPath: standardized).appendingPathComponent("bin")
        if isRegularFile(atPath: directBin.appendingPathComponent("wine").path)
            || isRegularFile(atPath: directBin.appendingPathComponent("wine64").path)
        {
            return standardized
        }

        let nestedCandidates = [
            "Contents/Resources/wine",
            "Contents/SharedSupport/CrossOver",
        ]
        for relative in nestedCandidates {
            let nestedRoot = URL(fileURLWithPath: standardized)
                .appendingPathComponent(relative, isDirectory: true)
                .standardizedFileURL.path
            let nestedBin = URL(fileURLWithPath: nestedRoot).appendingPathComponent("bin")
            if isRegularFile(atPath: nestedBin.appendingPathComponent("wine").path)
                || isRegularFile(atPath: nestedBin.appendingPathComponent("wine64").path)
            {
                return nestedRoot
            }
        }
        return standardized
    }

    private func probeWineVersion(wineBinaryPath: String) async -> String {
        let request = CommandRequest(
            executablePath: wineBinaryPath,
            arguments: ["--version"],
            environment: [:],
            inheritEnvironment: true
        )
        guard let result = try? await commandRunner.run(request) else {
            return "unknown"
        }
        let stdoutLine = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let stdoutLine {
            return stdoutLine
        }
        let stderrLine = result.stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return stderrLine ?? "unknown"
    }

    private static func formatDiscoveredName(
        baseName: String,
        version: String,
        isNewWoW64: Bool
    ) -> String {
        var components = [baseName]
        if version != "unknown" {
            let cleanedVersion = version
                .replacingOccurrences(of: "wine-", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedVersion.isEmpty {
                components.append(cleanedVersion)
            }
        }
        let joined = components.joined(separator: " ")
        return isNewWoW64 ? "\(joined) (WoW64)" : joined
    }

    /// 从 `wine --version` 输出（如 `"wine-11.0"`、`"wine-9.0 (Staging)"`）提取主版本号。
    internal static func parseMajorVersion(from versionString: String) -> Int? {
        let lowercased = versionString.lowercased()
        let searchSlice: Substring
        if let range = lowercased.range(of: "wine-") {
            searchSlice = lowercased[range.upperBound...]
        } else {
            searchSlice = lowercased[...]
        }

        var digits = ""
        for char in searchSlice {
            if char.isASCII && char.isNumber {
                digits.append(char)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    /// 对指定二进制文件执行有限范围分块只读字节扫描，检测 ASCII 符号标记（支持跨 64KB 边界匹配）。
    internal static func scanFilesForMarkers(paths: [String], markers: [[UInt8]]) -> Set<Int> {
        var found = Set<Int>()
        guard !markers.isEmpty else { return found }
        let maxMarkerLength = markers.map(\.count).max() ?? 0
        guard maxMarkerLength > 0 else { return found }

        for path in paths {
            if found.count == markers.count {
                break
            }
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                continue
            }
            defer {
                try? handle.close()
            }

            var totalBytesRead = 0
            var overlap: [UInt8] = []

            while totalBytesRead < binaryScanMaxBytes && found.count < markers.count {
                let remainingAllowance = binaryScanMaxBytes - totalBytesRead
                let readSize = min(binaryScanChunkSize, remainingAllowance)
                guard let chunk = try? handle.read(upToCount: readSize), !chunk.isEmpty else {
                    break
                }
                totalBytesRead += chunk.count

                var window: [UInt8] = []
                window.reserveCapacity(overlap.count + chunk.count)
                window.append(contentsOf: overlap)
                window.append(contentsOf: chunk)

                for (index, marker) in markers.enumerated() where !found.contains(index) {
                    if containsSubsequence(window, needle: marker) {
                        found.insert(index)
                    }
                }

                let overlapLength = min(maxMarkerLength - 1, window.count)
                if overlapLength > 0 {
                    overlap = Array(window[(window.count - overlapLength)...])
                } else {
                    overlap.removeAll(keepingCapacity: true)
                }
            }
        }

        return found
    }

    private static func containsSubsequence(_ haystack: [UInt8], needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let firstByte = needle[0]
        let lastStart = haystack.count - needle.count
        var index = 0
        while index <= lastStart {
            if haystack[index] == firstByte {
                var matched = true
                for offset in 1..<needle.count {
                    if haystack[index + offset] != needle[offset] {
                        matched = false
                        break
                    }
                }
                if matched {
                    return true
                }
            }
            index += 1
        }
        return false
    }

    private func isRegularFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    private func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
