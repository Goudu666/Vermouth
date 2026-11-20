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

    /// 在单个 Actor turn 内原子执行「读取 → 变更 → 落盘」，彻底消除并发 TOCTOU 窗口（B-4）。
    func mutate<T: Sendable>(
        _ body: @Sendable (inout EnginesConfigFile) throws -> T
    ) throws -> T {
        let original = try load()
        var updated = original
        let result = try body(&updated)
        if updated != original {
            try save(updated)
        }
        return result
    }
}

/// Wine 引擎发现、确定性只读能力探测、自定义登记与环境预检核心实现（遵循 L-004 / L-005 / L-006）。
public final class EngineManager: EngineManaging, Sendable {
    /// 推荐的 Wine 引擎安装命令。新版 Homebrew 已移除 `--no-quarantine`（L-019），
    /// 所以先正常安装，再对 cask 装出的 `Wine Stable.app` 去掉隔离属性。
    public static let recommendedWineInstallCommand =
        "brew install --cask gcenx/wine/wine-stable && xattr -dr com.apple.quarantine '/Applications/Wine Stable.app'"

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

    /// 标准 macOS 多来源 Wine 引擎探测候选列表（L-004，含 `/Applications` 与 `~/Applications`）。
    public static func defaultMacOSCandidateRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [EngineCandidateRoot] {
        let userApps = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        return [
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
                id: "user-app-wine-stable",
                displayName: "Wine Stable",
                rootPath: userApps.appendingPathComponent("Wine Stable.app/Contents/Resources/wine").path,
                source: .homebrewCask,
                quarantineCheckPath: userApps.appendingPathComponent("Wine Stable.app").path
            ),
            EngineCandidateRoot(
                id: "user-app-wine-staging",
                displayName: "Wine Staging",
                rootPath: userApps.appendingPathComponent("Wine Staging.app/Contents/Resources/wine").path,
                source: .homebrewCask,
                quarantineCheckPath: userApps.appendingPathComponent("Wine Staging.app").path
            ),
            EngineCandidateRoot(
                id: "user-app-wine-crossover",
                displayName: "Wine Crossover",
                rootPath: userApps.appendingPathComponent("Wine Crossover.app/Contents/Resources/wine").path,
                source: .homebrewCask,
                quarantineCheckPath: userApps.appendingPathComponent("Wine Crossover.app").path
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
                    remediationCommand: Self.recommendedWineInstallCommand
                )
            )
        } else {
            let names = discoveredEngines.map(\.name).joined(separator: "、")
            let quarantinedEngines = discoveredEngines.filter(\.isQuarantined)
            if !quarantinedEngines.isEmpty {
                var remediationTargets: [String] = []
                for engine in quarantinedEngines {
                    let target = Self.enclosingAppBundlePath(for: engine.rootPath) ?? engine.rootPath
                    let escaped = ShellQuoting.posixEscape(target)
                    if !remediationTargets.contains(escaped) {
                        remediationTargets.append(escaped)
                    }
                }
                let quarantinedNames = quarantinedEngines.map(\.name).joined(separator: "、")
                items.append(
                    PreflightCheckItem(
                        id: "wine-engines",
                        title: "Wine 引擎",
                        status: .warning,
                        detail: "已检测到 \(discoveredEngines.count) 套 Wine 引擎（\(names)），其中 \(quarantinedNames) 带有 macOS 隔离属性 (com.apple.quarantine)，可能被 Gatekeeper 拦截。",
                        remediationCommand: "xattr -dr com.apple.quarantine \(remediationTargets.joined(separator: " "))"
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

        let isReadyToLaunch = osVersion.isAtLeast(major: 14, minor: 0)
            && (architecture == .arm64 ? rosetta2Ready : true)
            && !discoveredEngines.isEmpty

        return PreflightReport(
            checkedAt: VermouthJSON.currentTimestamp(),
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
                let canonicalRoot = Self.canonicalPath(engine.rootPath)
                if seenIDs.insert(engine.id).inserted && seenRoots.insert(canonicalRoot).inserted {
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
                let canonicalRoot = Self.canonicalPath(engine.rootPath)
                if seenIDs.insert(engine.id).inserted {
                    seenRoots.insert(canonicalRoot)
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

        let expandedInput = Self.expandTilde(rootPath)
        let resolvedRoot = Self.resolveEffectiveEngineRoot(expandedInput)
        let quarantinePath = Self.enclosingAppBundlePath(for: resolvedRoot)
            ?? Self.enclosingAppBundlePath(for: expandedInput)
            ?? URL(fileURLWithPath: expandedInput).standardizedFileURL.path

        let engineID = "custom-\(UUID().uuidString.lowercased())"
        let candidate = EngineCandidateRoot(
            id: engineID,
            displayName: trimmedName,
            rootPath: resolvedRoot,
            source: .custom,
            quarantineCheckPath: quarantinePath
        )

        // 先执行只读探测，再在单一原子 actor turn 内完成去重与持久化（B-4）
        let engine = try await inspectCandidateStrict(candidate)
        try Self.verifyDylibDependencies(of: engine)
        let canonicalNewRoot = Self.canonicalPath(engine.rootPath)

        try await configStore.mutate { config in
            if let existing = config.customEngines.first(where: {
                Self.canonicalPath(Self.resolveEffectiveEngineRoot($0.rootPath)) == canonicalNewRoot
            }) {
                throw VermouthError.engineAlreadyRegistered(id: existing.id)
            }
            config.customEngines.append(
                CustomEngineEntry(id: engine.id, name: trimmedName, rootPath: engine.rootPath)
            )
        }
        return engine
    }

    public func unregisterCustomEngine(id: String) async throws {
        let removed: Bool = try await configStore.mutate { config in
            guard let index = config.customEngines.firstIndex(where: { $0.id == id }) else {
                return false
            }
            config.customEngines.remove(at: index)
            if config.defaultEngineID == id {
                config.defaultEngineID = nil
            }
            return true
        }
        if removed {
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
        try await configStore.mutate { config in
            config.defaultEngineID = id
        }
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
        let effectiveRoot = Self.resolveEffectiveEngineRoot(candidate.rootPath)
        let rootURL = URL(fileURLWithPath: effectiveRoot, isDirectory: true)

        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let wineURL = binURL.appendingPathComponent("wine", isDirectory: false)
        let wine64URL = binURL.appendingPathComponent("wine64", isDirectory: false)
        let wine32on64URL = binURL.appendingPathComponent("wine32on64", isDirectory: false)
        let wineserverURL = binURL.appendingPathComponent("wineserver", isDirectory: false)

        let hasWine = Self.isRegularFile(atPath: wineURL.path)
        let hasWine64 = Self.isRegularFile(atPath: wine64URL.path)
        let hasWine32on64 = Self.isRegularFile(atPath: wine32on64URL.path)
        let hasWineserver = Self.isRegularFile(atPath: wineserverURL.path)

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

        let hasI386Windows = Self.isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/i386-windows").path)
            || Self.isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/i386-windows").path)
        let hasI386Unix = Self.isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/i386-unix").path)
            || Self.isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/i386-unix").path)
        let hasX64Windows = Self.isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/x86_64-windows").path)
            || Self.isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/x86_64-windows").path)
        let hasX64Unix = Self.isDirectory(atPath: rootURL.appendingPathComponent("lib/wine/x86_64-unix").path)
            || Self.isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine/x86_64-unix").path)

        let isNewWoW64 = hasI386Windows
            && !hasI386Unix
            && !hasWine32on64
            && ((majorVersion ?? 0) >= 9 || !hasWine64)
        let supports32Bit = isNewWoW64 || hasI386Unix || hasWine32on64 || (hasWine && hasI386Windows)
        let supports64Bit = hasX64Windows || hasX64Unix || hasWine64

        let binaryProbePaths = [
            rootURL.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so").path,
            rootURL.appendingPathComponent("lib64/wine/x86_64-unix/ntdll.so").path,
            wineserverURL.path,
            wineBinaryPath,
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

        let quarantinePath = Self.enclosingAppBundlePath(for: effectiveRoot)
            ?? Self.enclosingAppBundlePath(for: candidate.quarantineCheckPath)
            ?? candidate.quarantineCheckPath
        var quarantined = await systemProber.isQuarantined(path: quarantinePath)
        if !quarantined && quarantinePath != wineBinaryPath {
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

    /// 自定义引擎（如单独拷出来的 Sikarugir `wswine.bundle`）常缺 `@rpath` 依赖，
    /// 登记成功后才在运行时报 `dyld: Library not loaded: @rpath/libinotify.0.dylib`。
    /// 登记前检查 `bin/wine`、`bin/wineserver` 与 `x86_64-unix/ntdll.so`，缺库时列出来并拒绝登记。
    /// 只用于用户手动登记：自动发现的引擎走 `inspectCandidateIfValid`，在那里抛错会让引擎静默消失。
    internal static func verifyDylibDependencies(of engine: WineEngine) throws {
        let rootURL = URL(fileURLWithPath: engine.rootPath, isDirectory: true)
        let ntdllCandidates = [
            rootURL.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so").path,
            rootURL.appendingPathComponent("lib64/wine/x86_64-unix/ntdll.so").path,
        ].filter { isRegularFile(atPath: $0) }

        let unresolved = try MachODependencyInspector.unresolvedDependencies(
            engineRoot: engine.rootPath,
            executables: [engine.wineBinaryPath, engine.wineserverPath],
            loadedLibraries: ntdllCandidates,
            hostExecutable: engine.wineBinaryPath
        )
        guard !unresolved.isEmpty else { return }

        let details = unresolved.map { item in
            "\(item.binary) → \(item.dependency)（已查找：\(item.searchedPaths.joined(separator: ", "))）"
        }
        throw VermouthError.invalidEngineRoot(
            path: engine.rootPath,
            reason: "引擎缺少运行所需的动态库，启动时会报 dyld: Library not loaded：\n"
                + details.joined(separator: "\n")
                + "\n请把缺失的 .dylib 补进引擎的 lib 目录后重新登记。"
        )
    }

    internal static func enclosingAppBundlePath(for path: String) -> String? {
        let expanded = expandTilde(path)
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let components = url.pathComponents
        for (index, component) in components.enumerated() where index > 0 {
            if component.lowercased().hasSuffix(".app") {
                var rebuilt = URL(fileURLWithPath: "/", isDirectory: true)
                for part in components[1...index] {
                    rebuilt.appendPathComponent(part)
                }
                return rebuilt.standardizedFileURL.path
            }
        }
        return nil
    }

    private static func expandTilde(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed == "~" {
            return home
        }
        if trimmed.hasPrefix("~/") {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .standardizedFileURL.path
        }
        return trimmed
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func hasWineLibraryDirectory(under rootPath: String) -> Bool {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        return isDirectory(atPath: rootURL.appendingPathComponent("lib/wine").path)
            || isDirectory(atPath: rootURL.appendingPathComponent("lib64/wine").path)
    }

    internal static func resolveEffectiveEngineRoot(_ rawPath: String) -> String {
        let expanded = expandTilde(rawPath)
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path

        var candidateRoot = standardized
        let directBin = URL(fileURLWithPath: standardized).appendingPathComponent("bin", isDirectory: true)
        let directHasWine = isRegularFile(atPath: directBin.appendingPathComponent("wine").path)
            || isRegularFile(atPath: directBin.appendingPathComponent("wine64").path)

        if !directHasWine {
            let nestedCandidates = [
                "Contents/Resources/wine",
                "Contents/SharedSupport/CrossOver",
            ]
            for relative in nestedCandidates {
                let nestedRoot = URL(fileURLWithPath: standardized)
                    .appendingPathComponent(relative, isDirectory: true)
                    .standardizedFileURL.path
                let nestedBin = URL(fileURLWithPath: nestedRoot).appendingPathComponent("bin", isDirectory: true)
                if isRegularFile(atPath: nestedBin.appendingPathComponent("wine").path)
                    || isRegularFile(atPath: nestedBin.appendingPathComponent("wine64").path)
                {
                    candidateRoot = nestedRoot
                    break
                }
            }
        }

        // 若该目录缺少 lib/wine（典型如 /opt/homebrew 下通过符号链接指向 Wine Stable.app 或 Cellar），
        // 解析 bin/wine 符号链接并回溯到真实引擎根目录以正确探测能力并避免重复项（B-6c）。
        if !hasWineLibraryDirectory(under: candidateRoot) {
            let binDir = URL(fileURLWithPath: candidateRoot).appendingPathComponent("bin", isDirectory: true)
            let binaryURLs = [
                binDir.appendingPathComponent("wine", isDirectory: false),
                binDir.appendingPathComponent("wine64", isDirectory: false),
            ]
            for binaryURL in binaryURLs where isRegularFile(atPath: binaryURL.path) {
                let resolvedBinary = binaryURL.resolvingSymlinksInPath().standardizedFileURL
                var probeDir = resolvedBinary.deletingLastPathComponent()
                for _ in 0..<3 {
                    if probeDir.lastPathComponent == "bin" {
                        let realRoot = probeDir.deletingLastPathComponent().standardizedFileURL.path
                        if hasWineLibraryDirectory(under: realRoot) {
                            return realRoot
                        }
                    } else if hasWineLibraryDirectory(under: probeDir.path) {
                        return probeDir.standardizedFileURL.path
                    }
                    let parent = probeDir.deletingLastPathComponent()
                    if parent.path == probeDir.path {
                        break
                    }
                    probeDir = parent
                }
            }
        }

        return candidateRoot
    }

    private func probeWineVersion(wineBinaryPath: String) async -> String {
        let request = CommandRequest(
            executablePath: wineBinaryPath,
            arguments: ["--version"],
            environment: [:],
            inheritEnvironment: true
        )
        guard let result = try? await commandRunner.run(request),
              result.exitCode == 0
        else {
            return "unknown"
        }
        let stdoutLine = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return stdoutLine ?? "unknown"
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

    /// 从 `wine --version` 输出（如 `"wine-11.0"`、`"wine-9.0 (Staging)"`）严格匹配 `wine-?(\d+)\.(\d+)` 或 `\b(\d+)\.(\d+)` 提取主版本号，防止将进程 PID 等数字误判为版本号（B-6b）。
    internal static func parseMajorVersion(from versionString: String) -> Int? {
        let patterns = [
            #"(?i)wine-?(\d+)\.(\d+)"#,
            #"\b(\d+)\.(\d+)"#,
        ]
        let nsString = versionString as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            if let match = regex.firstMatch(in: versionString, range: fullRange),
               match.numberOfRanges >= 2
            {
                let majorRange = match.range(at: 1)
                if majorRange.location != NSNotFound,
                   let major = Int(nsString.substring(with: majorRange))
                {
                    return major
                }
            }
        }
        return nil
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

    private static func isRegularFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    private static func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
