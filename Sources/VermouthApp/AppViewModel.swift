#if os(macOS)
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import VermouthCore

enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case programs
    case configuration
    case console
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .programs:
            return "程序"
        case .configuration:
            return "转译配置"
        case .console:
            return "运行日志与诊断"
        case .advanced:
            return "高级与覆写"
        }
    }

    var systemImage: String {
        switch self {
        case .programs:
            return "square.grid.2x2"
        case .configuration:
            return "slider.horizontal.3"
        case .console:
            return "terminal"
        case .advanced:
            return "wrench.and.screwdriver"
        }
    }
}

enum CreateBottleMode: String, CaseIterable, Identifiable, Sendable {
    case createNew
    case importExisting

    var id: Self { self }

    var title: String {
        switch self {
        case .createNew:
            return "新建空白容器"
        case .importExisting:
            return "导入已有 WINEPREFIX"
        }
    }
}

enum EngineSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case engines
    case graphics

    var id: Self { self }

    var title: String {
        switch self {
        case .engines:
            return "Wine 引擎管理"
        case .graphics:
            return "图形转译层库 (DXMT / DXVK)"
        }
    }
}

private final class DownloadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitUptime: TimeInterval = 0

    func shouldEmit(fraction: Double?) -> Bool {
        lock.withLock {
            if let fraction, fraction >= 1.0 {
                return true
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastEmitUptime >= 0.05 {
                lastEmitUptime = now
                return true
            }
            return false
        }
    }
}

@Observable
@MainActor
final class AppViewModel {
    private static let maxBufferedLogLines = 2000
    private static let logTrimHysteresis = 250

    // MARK: - Core Services

    let paths: VermouthPaths
    let commandRunner: LiveCommandRunner
    let systemProber: LiveSystemProber
    let httpFetcher: LiveHTTPFetcher
    let engineManager: EngineManager
    let bottleStore: BottleStore
    let graphicsManager: GraphicsStackManager
    let wineRunner: WineRunner
    let executableScanner: ExecutableScanner
    let crashDiagnoser: CrashDiagnoser
    let snapshotManager: SnapshotManager
    let recipeEngine: RecipeEngine

    // MARK: - Modal & Sheet Presentation State

    var preflightReport: PreflightReport?
    var isPerformingPreflight: Bool = false
    var isShowingPreflightSheet: Bool = false
    var isShowingEngineSettings: Bool = false
    var engineSettingsInitialTab: EngineSettingsTab = .engines
    var isShowingCreateBottleSheet: Bool = false
    var createBottleInitialMode: CreateBottleMode = .createNew
    var isShowingSnapshotSheet: Bool = false

    // MARK: - Domain State

    var engines: [WineEngine] = []
    var defaultEngineID: String?

    var bottles: [Bottle] = []
    var selectedBottleID: UUID?
    var selectedTab: WorkspaceSection = .programs

    var discoveredExecutables: [DiscoveredExecutable] = []
    var isScanningExecutables: Bool = false

    var installedGraphicsPackages: [GraphicsLayerPackage] = []
    var deploymentRecords: [UUID: GraphicsDeploymentRecord] = [:]
    var remoteReleases: [GraphicsBackend: [RemoteGraphicsRelease]] = [:]
    var isFetchingRemoteReleases: [GraphicsBackend: Bool] = [:]
    var activeDownloadProgress: [String: Double] = [:]

    var recipes: [Recipe] = []
    var snapshotsByBottle: [UUID: [SnapshotRecord]] = [:]

    // MARK: - Transparent Preview & Live Session State

    var previewLaunchPlan: LaunchPlan?
    var isRunningProcess: Bool = false
    var isBusyWithBottleOperation: Bool = false
    var busyStatusText: String?
    var currentLaunchPlan: LaunchPlan?
    var liveLogLines: [LogLine] = []
    var diagnosticFindings: [DiagnosticFinding] = []
    var statusBannerMessage: String?
    var errorAlertMessage: String?

    // MARK: - Internal Coordination State

    private var hasBootstrapped: Bool = false
    private var activeSessionTask: Task<Void, Never>?
    private var previewRefreshTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    private var seenDiagnosticIDs: Set<String> = []

    init(paths: VermouthPaths = VermouthPaths()) {
        let commandRunner = LiveCommandRunner()
        let systemProber = LiveSystemProber(commandRunner: commandRunner)
        let httpFetcher = LiveHTTPFetcher()
        let bottleStore = BottleStore(paths: paths)

        self.paths = paths
        self.commandRunner = commandRunner
        self.systemProber = systemProber
        self.httpFetcher = httpFetcher
        self.engineManager = EngineManager(
            paths: paths,
            commandRunner: commandRunner,
            systemProber: systemProber
        )
        self.bottleStore = bottleStore
        self.graphicsManager = GraphicsStackManager(
            paths: paths,
            commandRunner: commandRunner,
            httpFetcher: httpFetcher,
            bottleStore: bottleStore
        )
        self.wineRunner = WineRunner(
            paths: paths,
            commandRunner: commandRunner,
            systemProber: systemProber
        )
        self.executableScanner = ExecutableScanner()
        self.crashDiagnoser = CrashDiagnoser()
        self.snapshotManager = SnapshotManager(paths: paths, commandRunner: commandRunner)
        self.recipeEngine = RecipeEngine(paths: paths)
    }

    // MARK: - Computed Properties & Lookups

    var selectedBottle: Bottle? {
        guard let selectedBottleID else { return nil }
        return bottles.first { $0.id == selectedBottleID }
    }

    var activeDefaultEngine: WineEngine? {
        if let defaultEngineID,
           let matched = engines.first(where: { $0.id == defaultEngineID })
        {
            return matched
        }
        return engines.first
    }

    func resolvedEngine(for bottle: Bottle) -> WineEngine? {
        if let engineID = bottle.config.engineID,
           let matched = engines.first(where: { $0.id == engineID })
        {
            return matched
        }
        return activeDefaultEngine
    }

    func resolvedGraphicsPackage(for bottle: Bottle) -> GraphicsLayerPackage? {
        let backend = bottle.config.graphicsBackend
        guard backend != .wined3d else { return nil }
        if let versionID = bottle.config.graphicsLayerVersionID,
           let matched = installedGraphicsPackages.first(where: {
               $0.id == versionID && $0.backend == backend
           })
        {
            return matched
        }
        return installedGraphicsPackages
            .filter { $0.backend == backend }
            .sorted { lhs, rhs in
                if lhs.installedAt != rhs.installedAt {
                    return lhs.installedAt > rhs.installedAt
                }
                return lhs.id > rhs.id
            }
            .first
    }

    func deploymentRecord(for bottle: Bottle) -> GraphicsDeploymentRecord {
        if let cached = deploymentRecords[bottle.id] {
            return cached
        }
        if let loaded = try? graphicsManager.deploymentState(for: bottle) {
            return loaded
        }
        return GraphicsDeploymentRecord(backend: .wined3d, strategy: .wined3dBuiltin)
    }

    func dllOverrideResolution(for bottle: Bottle, appOverrides: [DllOverride] = []) -> DllOverrideResolution {
        DllOverrideFormatter.resolve(
            graphicsBackend: bottle.config.graphicsBackend,
            graphicsPackage: resolvedGraphicsPackage(for: bottle),
            bottleOverrides: bottle.config.dllOverrides,
            appOverrides: appOverrides
        )
    }

    func snapshots(for bottleID: UUID) -> [SnapshotRecord] {
        snapshotsByBottle[bottleID] ?? []
    }

    // MARK: - Bootstrap & Refresh

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        try? paths.ensureBaseDirectories()
        reloadBottlesFromDisk()
        reloadInstalledGraphicsPackages()
        reloadRecipesFromDisk()

        await refreshPreflight(autoPresentIfNotReady: true)

        if let bottle = selectedBottle {
            reloadSnapshots(for: bottle.id)
            refreshDeploymentState(for: bottle)
            await scanExecutables(for: bottle, silentIfUninitialized: true)
            schedulePreviewLaunchPlanRefresh()
        }
    }

    func handleSelectedBottleChanged() async {
        discoveredExecutables = []
        previewLaunchPlan = nil

        guard let bottle = selectedBottle else { return }
        reloadSnapshots(for: bottle.id)
        refreshDeploymentState(for: bottle)
        await scanExecutables(for: bottle, silentIfUninitialized: true)
        schedulePreviewLaunchPlanRefresh()
    }

    func refreshPreflight(autoPresentIfNotReady: Bool = false) async {
        isPerformingPreflight = true
        defer { isPerformingPreflight = false }

        let report = await engineManager.runPreflight()
        preflightReport = report

        let listedEngines = (try? await engineManager.listEngines()) ?? report.discoveredEngines
        engines = listedEngines
        defaultEngineID = (try? await engineManager.defaultEngine())?.id

        if autoPresentIfNotReady && !report.isReadyToLaunch {
            isShowingPreflightSheet = true
        }

        schedulePreviewLaunchPlanRefresh()
    }

    func reloadBottlesFromDisk(preferredSelection: UUID? = nil) {
        do {
            let loaded = try bottleStore.listBottles()
            bottles = loaded
            if let preferredSelection, loaded.contains(where: { $0.id == preferredSelection }) {
                selectedBottleID = preferredSelection
            } else if let current = selectedBottleID, loaded.contains(where: { $0.id == current }) {
                // Keep existing valid selection
            } else {
                selectedBottleID = loaded.first?.id
            }

            for bottle in loaded {
                if let state = try? graphicsManager.deploymentState(for: bottle) {
                    deploymentRecords[bottle.id] = state
                }
            }
        } catch {
            presentError(error)
        }
    }

    func reloadInstalledGraphicsPackages() {
        do {
            installedGraphicsPackages = try graphicsManager.listInstalledPackages()
        } catch {
            presentError(error)
        }
    }

    func reloadRecipesFromDisk() {
        do {
            recipes = try recipeEngine.listRecipes()
        } catch {
            presentError(error)
        }
    }

    func reloadSnapshots(for bottleID: UUID) {
        if let list = try? snapshotManager.listSnapshots(bottleID: bottleID, targetID: nil) {
            snapshotsByBottle[bottleID] = list
        } else {
            snapshotsByBottle[bottleID] = []
        }
    }

    func refreshDeploymentState(for bottle: Bottle) {
        if let state = try? graphicsManager.deploymentState(for: bottle) {
            deploymentRecords[bottle.id] = state
        }
    }

    // MARK: - Transparent LaunchPlan Preview

    func schedulePreviewLaunchPlanRefresh() {
        previewRefreshTask?.cancel()
        guard let bottle = selectedBottle,
              let engine = resolvedEngine(for: bottle)
        else {
            previewLaunchPlan = nil
            return
        }

        let graphicsPkg = resolvedGraphicsPackage(for: bottle)
        let target: LaunchTarget
        if let firstPinned = bottle.apps.first(where: \.isPinned) ?? bottle.apps.first {
            target = .appEntry(firstPinned)
        } else {
            target = .builtinTool(.winecfg, extraArguments: [])
        }

        previewRefreshTask = Task { [weak self] in
            guard let self else { return }
            if let plan = try? await self.wineRunner.buildLaunchPlan(
                bottle: bottle,
                engine: engine,
                target: target,
                graphicsPackage: graphicsPkg,
                extraArgs: [],
                debugChannelsOverride: nil
            ) {
                guard !Task.isCancelled else { return }
                self.previewLaunchPlan = plan
            }
        }
    }

    func buildPreviewPlan(for app: AppEntry, in bottle: Bottle) async -> LaunchPlan? {
        guard let engine = resolvedEngine(for: bottle) else { return nil }
        let pkg = resolvedGraphicsPackage(for: bottle)
        return try? await wineRunner.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: .appEntry(app),
            graphicsPackage: pkg,
            extraArgs: [],
            debugChannelsOverride: nil
        )
    }

    // MARK: - Engine Management & Quarantine

    func openEngineSettings(tab: EngineSettingsTab = .engines) {
        engineSettingsInitialTab = tab
        isShowingEngineSettings = true
    }

    func openCreateBottleSheet(mode: CreateBottleMode = .createNew) {
        createBottleInitialMode = mode
        isShowingCreateBottleSheet = true
    }

    func setDefaultEngine(_ engineID: String) async {
        do {
            try await engineManager.setDefaultEngine(id: engineID)
            defaultEngineID = (try? await engineManager.defaultEngine())?.id ?? engineID
            schedulePreviewLaunchPlanRefresh()
            if let name = engines.first(where: { $0.id == engineID })?.name {
                showBanner("已将「\(name)」设为全局默认引擎")
            }
        } catch {
            presentError(error)
        }
    }

    func registerCustomEngine(name: String, rootPath: String) async -> Bool {
        do {
            let engine = try await engineManager.registerCustomEngine(name: name, rootPath: rootPath)
            await refreshPreflight(autoPresentIfNotReady: false)
            showBanner("已登记自定义 Wine 引擎：\(engine.name)")
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func unregisterCustomEngine(_ engine: WineEngine) async {
        do {
            try await engineManager.unregisterCustomEngine(id: engine.id)
            await refreshPreflight(autoPresentIfNotReady: false)
            showBanner("已移除自定义引擎登记：\(engine.name)")
        } catch {
            presentError(error)
        }
    }

    func removeQuarantineForEngine(_ engine: WineEngine) async {
        let targetPath = Self.enclosingAppBundlePath(for: engine.rootPath) ?? engine.rootPath
        do {
            try await systemProber.removeQuarantine(path: targetPath, recursive: true)
            await refreshPreflight(autoPresentIfNotReady: false)
            removeDiagnosticFindings { finding in
                finding.category == .quarantineBlocked
            }
            showBanner("已解除「\(engine.name)」的 macOS 隔离属性")
        } catch {
            presentError(error)
        }
    }

    func promptAndRegisterCustomEngine() async {
        let panel = NSOpenPanel()
        panel.title = "选择本地 Wine 引擎目录或 .app 捆绑包"
        panel.message = "可选择 Wine Stable.app / Wine Crossover.app，或包含 bin/wine 的自定义目录"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        let inferredName = selectedURL.deletingPathExtension().lastPathComponent
        let displayName = inferredName.isEmpty ? "Custom Wine" : inferredName
        _ = await registerCustomEngine(name: displayName, rootPath: selectedURL.path)
    }

    // MARK: - Bottle CRUD

    func createBottle(
        name: String,
        engineID: String?,
        windowsVersion: WindowsVersion,
        graphicsBackend: GraphicsBackend,
        syncMode: SyncMode,
        enableChinese: Bool,
        initialRecipeID: String?
    ) async -> Bool {
        let detectedFont = RegistryPatcher.detectAvailableCJKFont()
        let initialConfig = BottleConfig(
            engineID: engineID,
            windowsVersion: windowsVersion,
            syncMode: syncMode,
            graphicsBackend: .wined3d,
            graphicsLayerVersionID: nil,
            display: DisplayConfig(),
            locale: LocaleConfig(
                chineseLocalizationEnabled: enableChinese,
                lcAll: "zh_CN.UTF-8",
                fallbackFontName: detectedFont
            ),
            dllOverrides: [],
            environmentVariables: [:],
            wineDebugChannels: "-all,err+all"
        )

        do {
            var created = try bottleStore.createBottle(
                name: name,
                engineID: engineID,
                initialConfig: initialConfig
            )

            reloadBottlesFromDisk(preferredSelection: created.id)

            if let recipeID = initialRecipeID,
               let recipe = recipes.first(where: { $0.id == recipeID })
            {
                await applyRecipe(recipe, to: created)
                if let refreshed = try? bottleStore.loadBottle(id: created.id) {
                    created = refreshed
                }
            } else {
                if graphicsBackend != .wined3d {
                    let matchingPackages = installedGraphicsPackages.filter { $0.backend == graphicsBackend }
                    if !matchingPackages.isEmpty, resolvedEngine(for: created) != nil {
                        await switchGraphicsBackend(graphicsBackend, packageID: nil, for: created)
                        if let refreshed = try? bottleStore.loadBottle(id: created.id) {
                            created = refreshed
                        }
                    } else {
                        showBanner("容器已创建（当前尚未安装 \(graphicsBackend.displayName) 包，已暂用 WineD3D，可在图形库下载后切换）")
                    }
                }

                if let engine = resolvedEngine(for: created) {
                    let bottleToInit = created
                    await performBusyOperation("正在初始化容器与注册表…") {
                        try? await self.wineRunner.ensurePrefixInitialized(bottle: bottleToInit, engine: engine)
                        try? await self.wineRunner.applyBottleRegistrySettings(bottle: bottleToInit, engine: engine)
                    }
                }
            }

            reloadBottlesFromDisk(preferredSelection: created.id)
            reloadSnapshots(for: created.id)
            await scanExecutables(for: created, silentIfUninitialized: true)
            schedulePreviewLaunchPlanRefresh()
            showBanner("已创建容器「\(created.name)」")
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func importExistingPrefix(
        name: String,
        sourcePrefixPath: String,
        copyFiles: Bool
    ) async -> Bool {
        do {
            let imported = try await performBusyThrowingOperation(
                copyFiles ? "正在通过 APFS 克隆导入 WINEPREFIX…" : "正在关联外部 WINEPREFIX…"
            ) {
                try self.bottleStore.importExistingPrefix(
                    name: name,
                    sourcePrefixPath: sourcePrefixPath,
                    copyFiles: copyFiles
                )
            }

            reloadBottlesFromDisk(preferredSelection: imported.id)
            reloadSnapshots(for: imported.id)
            await scanExecutables(for: imported, silentIfUninitialized: false)
            schedulePreviewLaunchPlanRefresh()
            showBanner("已导入容器「\(imported.name)」")
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func renameBottle(_ bottle: Bottle, newName: String) {
        do {
            let updated = try bottleStore.renameBottle(id: bottle.id, newName: newName)
            reloadBottlesFromDisk(preferredSelection: updated.id)
            schedulePreviewLaunchPlanRefresh()
            showBanner("已重命名容器为「\(updated.name)」")
        } catch {
            presentError(error)
        }
    }

    func cloneBottle(_ bottle: Bottle, newName: String) async {
        do {
            if let engine = resolvedEngine(for: bottle) {
                try? await wineRunner.killWineServer(for: bottle, engine: engine, force: false)
            }
            let cloned = try await performBusyThrowingOperation("正在克隆容器「\(bottle.name)」…") {
                try self.bottleStore.cloneBottle(id: bottle.id, newName: newName)
            }
            reloadBottlesFromDisk(preferredSelection: cloned.id)
            reloadSnapshots(for: cloned.id)
            await scanExecutables(for: cloned, silentIfUninitialized: true)
            schedulePreviewLaunchPlanRefresh()
            showBanner("已克隆新容器「\(cloned.name)」")
        } catch {
            presentError(error)
        }
    }

    func deleteBottle(_ bottle: Bottle, removePrefixFiles: Bool) async {
        do {
            if let engine = resolvedEngine(for: bottle) {
                try? await wineRunner.killWineServer(for: bottle, engine: engine, force: true)
            }
            // L-005: External prefix is strictly protected in both UI & BottleStore
            let shouldRemovePrefix = bottle.isExternalPrefix ? false : removePrefixFiles
            try bottleStore.deleteBottle(id: bottle.id, removePrefixFiles: shouldRemovePrefix)
            deploymentRecords.removeValue(forKey: bottle.id)
            snapshotsByBottle.removeValue(forKey: bottle.id)
            reloadBottlesFromDisk()
            await handleSelectedBottleChanged()
            if bottle.isExternalPrefix {
                showBanner("已移除容器记录「\(bottle.name)」（外部原目录已安全保留）")
            } else {
                showBanner("已删除容器「\(bottle.name)」")
            }
        } catch {
            presentError(error)
        }
    }

    // MARK: - Bottle Tools (PRD §4.1B)

    func openDriveC(for bottle: Bottle) {
        let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let driveCURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let targetURL = FileManager.default.fileExists(atPath: driveCURL.path) ? driveCURL : prefixURL
        if !NSWorkspace.shared.open(targetURL) {
            presentError(
                VermouthError.ioError(
                    operation: "openFinder",
                    path: targetURL.path,
                    underlyingDescription: "无法在 Finder 中打开目录（若容器尚未首次启动，可先运行任意工具初始化前缀）"
                )
            )
        }
    }

    func revealBottleInFinder(_ bottle: Bottle) {
        let bottleDir = paths.bottleDirectory(id: bottle.id)
        if FileManager.default.fileExists(atPath: bottleDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([bottleDir])
        } else {
            _ = NSWorkspace.shared.open(paths.bottlesDirectory)
        }
    }

    func openBottleLogsDirectory(for bottle: Bottle) {
        let logsDir = paths.bottleLogsDirectory(id: bottle.id)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        _ = NSWorkspace.shared.open(logsDir)
    }

    func launchBuiltinTool(_ tool: WineBuiltinTool, for bottle: Bottle) async {
        selectedTab = .console
        await executeLaunchTarget(
            .builtinTool(tool, extraArguments: []),
            in: bottle,
            rescanAfterExit: tool == .cmd
        )
    }

    func openPreInjectedTerminal(for bottle: Bottle) {
        guard let engine = resolvedEngine(for: bottle) else {
            presentError(VermouthError.noEngineAvailable)
            return
        }

        do {
            let pkg = resolvedGraphicsPackage(for: bottle)
            var script = try wineRunner.buildInteractiveTerminalScript(
                bottle: bottle,
                engine: engine,
                graphicsPackage: pkg
            )
            // Keep interactive shell alive when launched via Terminal.app .command script
            if !script.contains("\nexec ") {
                script += "\nexec \"${SHELL:-/bin/zsh}\" -i\n"
            }

            let tempDir = FileManager.default.temporaryDirectory
            let scriptURL = tempDir.appendingPathComponent(
                "vermouth-shell-\(bottle.id.uuidString).command",
                isDirectory: false
            )
            try Data(script.utf8).write(to: scriptURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: scriptURL.path
            )

            if NSWorkspace.shared.open(scriptURL) {
                showBanner("已在终端打开「\(bottle.name)」预注入环境")
            } else {
                presentError(
                    VermouthError.ioError(
                        operation: "openTerminal",
                        path: scriptURL.path,
                        underlyingDescription: "macOS 未能拉起终端打开 .command 脚本"
                    )
                )
            }
        } catch {
            presentError(error)
        }
    }

    func killWineServer(for bottle: Bottle, force: Bool = false) async {
        if isRunningProcess {
            activeSessionTask?.cancel()
            activeSessionTask = nil
            isRunningProcess = false
        }

        guard let engine = resolvedEngine(for: bottle) else {
            presentError(VermouthError.noEngineAvailable)
            return
        }

        do {
            try await wineRunner.killWineServer(for: bottle, engine: engine, force: force)
            removeDiagnosticFindings { $0.category == .syncMismatch }
            showBanner("已终止容器「\(bottle.name)」的残留 wineserver 进程")
        } catch {
            presentError(error)
        }
    }

    func applyChineseEnvironmentFix(for bottle: Bottle) async {
        do {
            var updated = try bottleStore.loadBottle(id: bottle.id)
            updated.config.locale.chineseLocalizationEnabled = true
            if updated.config.locale.lcAll.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.config.locale.lcAll = "zh_CN.UTF-8"
            }
            if updated.config.locale.fallbackFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.config.locale.fallbackFontName = RegistryPatcher.detectAvailableCJKFont()
            }
            updated.updatedAt = VermouthJSON.currentTimestamp()
            try bottleStore.saveBottle(updated)
            reloadBottlesFromDisk(preferredSelection: updated.id)

            if let engine = resolvedEngine(for: updated) {
                try await performBusyThrowingOperation("正在写入中文字体映射与 Locale 注册表…") {
                    try await self.wineRunner.applyBottleRegistrySettings(bottle: updated, engine: engine)
                }
            }

            removeDiagnosticFindings { $0.category == .fontOrLocale }
            schedulePreviewLaunchPlanRefresh()
            showBanner("已完成中文环境补全并同步容器注册表")
        } catch {
            presentError(error)
        }
    }

    // MARK: - Program & Installer Launcher (PRD §4.1D)

    func promptAndRunInstaller(for bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "选择要在「\(bottle.name)」中运行的 Windows 安装程序 (.exe / .msi)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        let allowedTypes = [
            UTType(filenameExtension: "exe"),
            UTType(filenameExtension: "msi"),
        ].compactMap { $0 }
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        Task {
            await runInstaller(at: fileURL.path, in: bottle)
        }
    }

    func handleDroppedURLs(_ urls: [URL], in bottle: Bottle) -> Bool {
        let supported = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "exe" || ext == "msi" || url.lastPathComponent.lowercased().hasSuffix(".recipe.json")
        }
        guard let first = supported.first else {
            return false
        }

        if first.lastPathComponent.lowercased().hasSuffix(".recipe.json") {
            Task {
                await importAndApplyRecipeFile(at: first.path, to: bottle)
            }
            return true
        }

        Task {
            await runInstaller(at: first.path, in: bottle)
        }
        return true
    }

    func runInstaller(at path: String, in bottle: Bottle) async {
        selectedTab = .console
        await executeLaunchTarget(
            .installer(path: path),
            in: bottle,
            rescanAfterExit: true
        )
    }

    func scanExecutables(for bottle: Bottle, silentIfUninitialized: Bool = false) async {
        let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: prefixURL.path) {
            discoveredExecutables = []
            return
        }

        isScanningExecutables = true
        defer { isScanningExecutables = false }

        do {
            discoveredExecutables = try executableScanner.scan(prefixPath: bottle.prefixPath)
        } catch {
            discoveredExecutables = []
            if !silentIfUninitialized {
                presentError(error)
            }
        }
    }

    func isDiscoveredExecutablePinned(_ exec: DiscoveredExecutable, in bottle: Bottle) -> Bool {
        let targetCanonical = Self.canonicalExecutableKey(exec.executablePath, prefixPath: bottle.prefixPath)
        return bottle.apps.contains { app in
            Self.canonicalExecutableKey(app.executablePath, prefixPath: bottle.prefixPath) == targetCanonical
        }
    }

    func pinDiscoveredExecutable(_ exec: DiscoveredExecutable, in bottle: Bottle) {
        do {
            var updated = try bottleStore.loadBottle(id: bottle.id)
            let targetCanonical = Self.canonicalExecutableKey(exec.executablePath, prefixPath: updated.prefixPath)
            if let index = updated.apps.firstIndex(where: {
                Self.canonicalExecutableKey($0.executablePath, prefixPath: updated.prefixPath) == targetCanonical
            }) {
                updated.apps[index].isPinned = true
            } else {
                let entry = AppEntry(
                    name: exec.name,
                    executablePath: exec.executablePath,
                    arguments: exec.arguments,
                    workingDirectory: exec.workingDirectory,
                    isPinned: true
                )
                updated.apps.append(entry)
            }
            updated.updatedAt = VermouthJSON.currentTimestamp()
            try bottleStore.saveBottle(updated)
            reloadBottlesFromDisk(preferredSelection: updated.id)
            schedulePreviewLaunchPlanRefresh()
            showBanner("已固定「\(exec.name)」到启动面板")
        } catch {
            presentError(error)
        }
    }

    func promptAndAddManualApp(in bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "选择 Windows 可执行文件 (.exe) 固定为快捷卡片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        if let exeType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [exeType]
        }

        let driveCURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
        if FileManager.default.fileExists(atPath: driveCURL.path) {
            panel.directoryURL = driveCURL
        }

        guard panel.runModal() == .OK, let exeURL = panel.url else {
            return
        }

        let stem = exeURL.deletingPathExtension().lastPathComponent
        let entry = AppEntry(
            name: stem.isEmpty ? exeURL.lastPathComponent : stem,
            executablePath: exeURL.path,
            arguments: [],
            workingDirectory: exeURL.deletingLastPathComponent().path,
            isPinned: true
        )
        saveAppEntry(entry, in: bottle)
        showBanner("已添加程序「\(entry.name)」")
    }

    func saveAppEntry(_ entry: AppEntry, in bottle: Bottle) {
        do {
            var updated = try bottleStore.loadBottle(id: bottle.id)
            if let existingIndex = updated.apps.firstIndex(where: { $0.id == entry.id }) {
                updated.apps[existingIndex] = entry
            } else {
                updated.apps.append(entry)
            }
            updated.updatedAt = VermouthJSON.currentTimestamp()
            try bottleStore.saveBottle(updated)
            reloadBottlesFromDisk(preferredSelection: updated.id)
            schedulePreviewLaunchPlanRefresh()
        } catch {
            presentError(error)
        }
    }

    func removeAppEntry(_ entry: AppEntry, in bottle: Bottle) {
        do {
            var updated = try bottleStore.loadBottle(id: bottle.id)
            updated.apps.removeAll { $0.id == entry.id }
            updated.updatedAt = VermouthJSON.currentTimestamp()
            try bottleStore.saveBottle(updated)
            reloadBottlesFromDisk(preferredSelection: updated.id)
            schedulePreviewLaunchPlanRefresh()
            showBanner("已移除固定程序「\(entry.name)」")
        } catch {
            presentError(error)
        }
    }

    func launchApp(_ app: AppEntry, in bottle: Bottle, debugChannelsOverride: String? = nil) async {
        var launchedApp = app
        launchedApp.lastLaunchedAt = VermouthJSON.currentTimestamp()
        saveAppEntry(launchedApp, in: bottle)

        let latestBottle = (try? bottleStore.loadBottle(id: bottle.id)) ?? bottle
        selectedTab = .console
        await executeLaunchTarget(
            .appEntry(launchedApp),
            in: latestBottle,
            debugChannelsOverride: debugChannelsOverride,
            rescanAfterExit: false
        )
    }

    func launchDiscoveredExecutable(_ exec: DiscoveredExecutable, in bottle: Bottle) async {
        selectedTab = .console
        await executeLaunchTarget(
            .executable(path: exec.executablePath, workingDirectory: exec.workingDirectory),
            in: bottle,
            extraArgs: exec.arguments,
            rescanAfterExit: false
        )
    }

    // MARK: - Graphics Stack Management (PRD §4.1C)

    func switchGraphicsBackend(
        _ backend: GraphicsBackend,
        packageID: String? = nil,
        for bottle: Bottle
    ) async {
        if backend != .wined3d {
            let candidates = installedGraphicsPackages.filter { $0.backend == backend }
            if candidates.isEmpty {
                openEngineSettings(tab: .graphics)
                showBanner("尚未安装 \(backend.displayName) 图形包，请先从官方 GitHub Releases 下载或本地导入")
                return
            }
        }

        guard let engine = resolvedEngine(for: bottle) else {
            if backend == .wined3d {
                await updateBottleConfig(for: bottle) { config in
                    config.graphicsBackend = .wined3d
                    config.graphicsLayerVersionID = nil
                }
                return
            }
            presentError(VermouthError.noEngineAvailable)
            return
        }

        do {
            let result = try await performBusyThrowingOperation("正在切换图形转译层至 \(backend.displayName)…") {
                try await self.graphicsManager.applyBackend(
                    backend,
                    packageID: packageID,
                    to: bottle,
                    engine: engine
                )
            }
            deploymentRecords[bottle.id] = result.record
            reloadBottlesFromDisk(preferredSelection: result.bottle.id)
            for warning in result.warnings {
                recordDiagnosticFinding(warning)
            }
            removeDiagnosticFindings { $0.category == .graphicsInitFailed }
            schedulePreviewLaunchPlanRefresh()
            showBanner("容器图形后端已切换为 \(backend.displayName)")
        } catch {
            presentError(error)
        }
    }

    func fetchRemoteReleases(for backend: GraphicsBackend) async {
        guard backend != .wined3d else { return }
        isFetchingRemoteReleases[backend] = true
        defer { isFetchingRemoteReleases[backend] = false }

        do {
            let releases = try await graphicsManager.fetchAvailableReleases(for: backend)
            remoteReleases[backend] = releases
            if releases.isEmpty {
                showBanner("未在官方仓库查询到可用的 \(backend.displayName) 归档")
            }
        } catch {
            presentError(error)
        }
    }

    func downloadAndInstallRelease(_ release: RemoteGraphicsRelease) async {
        let releaseID = release.id
        guard activeDownloadProgress[releaseID] == nil else { return }

        activeDownloadProgress[releaseID] = 0.0
        let gate = DownloadProgressGate()

        do {
            let installed = try await graphicsManager.installPackage(from: release) { [weak self] progress in
                guard gate.shouldEmit(fraction: progress.fractionCompleted) else { return }
                let fraction = progress.fractionCompleted ?? -1.0
                Task { @MainActor [weak self] in
                    guard let self, self.activeDownloadProgress[releaseID] != nil else { return }
                    self.activeDownloadProgress[releaseID] = fraction
                }
            }
            activeDownloadProgress.removeValue(forKey: releaseID)
            reloadInstalledGraphicsPackages()
            schedulePreviewLaunchPlanRefresh()
            showBanner("已下载并安装图形转译层：\(installed.id)")
        } catch {
            activeDownloadProgress.removeValue(forKey: releaseID)
            presentError(error)
        }
    }

    func importLocalGraphicsArchive(
        at archivePath: String,
        backend: GraphicsBackend,
        version: String
    ) async -> Bool {
        do {
            let installed = try await performBusyThrowingOperation("正在校验并解压本地图形包…") {
                try await self.graphicsManager.importLocalArchive(
                    at: archivePath,
                    backend: backend,
                    version: version
                )
            }
            reloadInstalledGraphicsPackages()
            schedulePreviewLaunchPlanRefresh()
            showBanner("已导入图形转译层：\(installed.id)")
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func removeGraphicsPackage(_ package: GraphicsLayerPackage) {
        do {
            try graphicsManager.removePackage(id: package.id, activeBottles: bottles)
            reloadInstalledGraphicsPackages()
            schedulePreviewLaunchPlanRefresh()
            showBanner("已删除图形包：\(package.id)")
        } catch {
            presentError(error)
        }
    }

    // MARK: - Config Mutation & Registry Sync (L-003 Safe)

    func updateBottleConfig(
        for bottle: Bottle,
        syncRegistry: Bool = false,
        mutate: (inout BottleConfig) -> Void
    ) async {
        do {
            let original = try bottleStore.loadBottle(id: bottle.id)
            var updated = original
            mutate(&updated.config)

            guard updated.config != original.config else {
                if syncRegistry {
                    await syncRegistryNow(for: original)
                }
                return
            }

            let syncModeChanged = original.config.syncMode != updated.config.syncMode
            let engineChanged = original.config.engineID != updated.config.engineID

            // CRITICAL L-003: Terminate existing wineserver using ORIGINAL syncMode & engine BEFORE applying new syncMode!
            if syncModeChanged || engineChanged {
                if let oldEngine = resolvedEngine(for: original) {
                    try? await wineRunner.killWineServer(for: original, engine: oldEngine, force: false)
                }
            }

            updated.updatedAt = VermouthJSON.currentTimestamp()
            try bottleStore.saveBottle(updated)
            reloadBottlesFromDisk(preferredSelection: updated.id)

            if syncRegistry, let newEngine = resolvedEngine(for: updated) {
                try await performBusyThrowingOperation("正在同步配置到容器注册表…") {
                    try await self.wineRunner.applyBottleRegistrySettings(bottle: updated, engine: newEngine)
                }
                showBanner("配置已保存并写入容器注册表")
            }

            schedulePreviewLaunchPlanRefresh()
        } catch {
            presentError(error)
        }
    }

    func syncRegistryNow(for bottle: Bottle) async {
        guard let engine = resolvedEngine(for: bottle) else {
            presentError(VermouthError.noEngineAvailable)
            return
        }
        do {
            let latest = try bottleStore.loadBottle(id: bottle.id)
            try await performBusyThrowingOperation("正在同步配置到容器注册表…") {
                try await self.wineRunner.applyBottleRegistrySettings(bottle: latest, engine: engine)
            }
            showBanner("容器注册表同步完成（Windows 版本 / DPI / 虚拟桌面 / 中文字体）")
        } catch {
            presentError(error)
        }
    }

    // MARK: - Recipes (PRD §4.1D)

    func applyRecipe(_ recipe: Recipe, to bottle: Bottle) async {
        do {
            let latestBottle = try bottleStore.loadBottle(id: bottle.id)
            let engine = resolvedEngine(for: latestBottle)
            let plan = recipeEngine.planApplication(of: recipe, to: latestBottle, engine: engine)

            for warning in plan.warnings {
                recordDiagnosticFinding(warning)
            }

            if plan.requiresWineServerRestart, let engine {
                // L-003: Kill existing wineserver with previous syncMode first
                try? await wineRunner.killWineServer(for: latestBottle, engine: engine, force: false)
            }

            var workingBottle = plan.updatedBottle
            // Preserve previous graphicsBackend in bottle.json until graphicsManager.applyBackend succeeds
            if plan.requiresGraphicsBackendChange {
                workingBottle.config.graphicsBackend = latestBottle.config.graphicsBackend
                workingBottle.config.graphicsLayerVersionID = latestBottle.config.graphicsLayerVersionID
            }
            try bottleStore.saveBottle(workingBottle)

            if plan.requiresGraphicsBackendChange {
                let desiredBackend = plan.updatedBottle.config.graphicsBackend
                let hasPackageForDesired = desiredBackend == .wined3d
                    || installedGraphicsPackages.contains(where: { $0.backend == desiredBackend })

                if let engine, hasPackageForDesired {
                    if let applyResult = try? await graphicsManager.applyBackend(
                        desiredBackend,
                        packageID: nil,
                        to: workingBottle,
                        engine: engine
                    ) {
                        workingBottle = applyResult.bottle
                        deploymentRecords[workingBottle.id] = applyResult.record
                        for warning in applyResult.warnings {
                            recordDiagnosticFinding(warning)
                        }
                    }
                } else if desiredBackend != .wined3d {
                    showBanner("已应用配方「\(recipe.name)」（请先在图形库下载 \(desiredBackend.displayName) 后再切换图形后端）")
                }
            }

            if plan.requiresRegistrySync, let engine = resolvedEngine(for: workingBottle) {
                let bottleToSync = workingBottle
                await performBusyOperation("正在按配方「\(recipe.name)」同步容器注册表…") {
                    try? await self.wineRunner.applyBottleRegistrySettings(bottle: bottleToSync, engine: engine)
                }
            }

            reloadBottlesFromDisk(preferredSelection: workingBottle.id)
            schedulePreviewLaunchPlanRefresh()
            showBanner("已应用配方「\(recipe.name)」")
        } catch {
            presentError(error)
        }
    }

    func promptAndImportRecipe(applyTo bottle: Bottle? = nil) {
        let panel = NSOpenPanel()
        panel.title = "导入兼容配方文件 (.recipe.json)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        Task {
            await importAndApplyRecipeFile(at: fileURL.path, to: bottle)
        }
    }

    func importAndApplyRecipeFile(at path: String, to bottle: Bottle?) async {
        do {
            let recipe = try recipeEngine.importRecipeFile(at: path)
            reloadRecipesFromDisk()
            if let bottle {
                await applyRecipe(recipe, to: bottle)
            } else {
                showBanner("已导入配方「\(recipe.name)」")
            }
        } catch {
            presentError(error)
        }
    }

    func exportRecipe(
        from bottle: Bottle,
        id: String,
        name: String,
        summary: String
    ) -> Bool {
        let sanitized = recipeEngine.exportSanitizedRecipe(
            from: bottle,
            id: id,
            name: name,
            summary: summary
        )

        let savePanel = NSSavePanel()
        savePanel.title = "导出脱敏兼容配方 (.recipe.json)"
        savePanel.nameFieldStringValue = "\(sanitized.id).recipe.json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            return false
        }

        do {
            try VermouthJSON.writeAtomically(sanitized, to: destinationURL)
            showBanner("已导出配方至 \(destinationURL.lastPathComponent)")
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    // MARK: - Live Process Streaming & Diagnostics (PRD §4.1E)

    func stopActiveProcess() {
        activeSessionTask?.cancel()
        activeSessionTask = nil
        isRunningProcess = false
        appendLogLine(
            LogLine(
                timestamp: VermouthJSON.currentTimestamp(),
                stream: .system,
                text: "用户已请求终止当前子进程会话"
            )
        )
    }

    func clearConsoleLogs() {
        liveLogLines.removeAll()
        diagnosticFindings.removeAll()
        seenDiagnosticIDs.removeAll()
    }

    func dismissDiagnosticFinding(id: String) {
        diagnosticFindings.removeAll { $0.id == id }
    }

    func performQuickFix(_ quickFix: DiagnosticQuickFix, findingID: String? = nil) async {
        switch quickFix {
        case let .removeQuarantine(path, recursive):
            do {
                try await systemProber.removeQuarantine(path: path, recursive: recursive)
                await refreshPreflight(autoPresentIfNotReady: false)
                if let findingID {
                    dismissDiagnosticFinding(id: findingID)
                }
                showBanner("已解除隔离属性：\(URL(fileURLWithPath: path).lastPathComponent)")
            } catch {
                presentError(error)
            }

        case let .switchGraphicsBackend(backend):
            guard let bottle = selectedBottle else { return }
            await switchGraphicsBackend(backend, for: bottle)
            if let findingID {
                dismissDiagnosticFinding(id: findingID)
            }

        case .killWineServer:
            guard let bottle = selectedBottle else { return }
            await killWineServer(for: bottle, force: false)
            if let findingID {
                dismissDiagnosticFinding(id: findingID)
            }

        case .select32BitCapableEngine:
            if let capableEngine = engines.first(where: { $0.capabilities.supports32Bit }),
               let bottle = selectedBottle
            {
                await updateBottleConfig(for: bottle) { config in
                    config.engineID = capableEngine.id
                }
                if let findingID {
                    dismissDiagnosticFinding(id: findingID)
                }
                showBanner("已为容器切换至支持 32 位的引擎：\(capableEngine.name)")
            } else {
                openEngineSettings(tab: .engines)
                showBanner("本机尚未检测到支持 32 位的 Wine 引擎，请安装 Wine Stable (WoW64) 或登记引擎目录")
            }

        case let .removeConflictingDllOverrides(conflictingNames):
            guard let bottle = selectedBottle else { return }
            let normalizedSet = Set(conflictingNames.map { DllOverride.normalizeName($0) })
            do {
                var updated = try bottleStore.loadBottle(id: bottle.id)
                updated.config.dllOverrides.removeAll { normalizedSet.contains($0.dllName) }
                for index in updated.apps.indices {
                    updated.apps[index].dllOverrides.removeAll { normalizedSet.contains($0.dllName) }
                }
                updated.updatedAt = VermouthJSON.currentTimestamp()
                try bottleStore.saveBottle(updated)
                reloadBottlesFromDisk(preferredSelection: updated.id)
                schedulePreviewLaunchPlanRefresh()
                if let findingID {
                    dismissDiagnosticFinding(id: findingID)
                }
                showBanner("已移除与 wineBuiltin 图形包冲突的 DLL 覆写")
            } catch {
                presentError(error)
            }

        case .enableChineseLocalization:
            guard let bottle = selectedBottle else { return }
            await applyChineseEnvironmentFix(for: bottle)
            if let findingID {
                dismissDiagnosticFinding(id: findingID)
            }

        case let .copyCommand(label, command):
            copyToClipboard(command, label: label)
        }
    }

    // MARK: - Snapshots Management (PRD §4.1F & L-011)

    func addSnapshotTarget(
        _ target: SnapshotTarget,
        attachToAppID: UUID?,
        in bottle: Bottle
    ) {
        do {
            var updated = try bottleStore.loadBottle(id: bottle.id)
            if let attachToAppID,
               let index = updated.apps.firstIndex(where: { $0.id == attachToAppID })
            {
                if !updated.apps[index].snapshotTargets.contains(where: { $0.path == target.path }) {
                    updated.apps[index].snapshotTargets.append(target)
                }
            } else if !updated.apps.isEmpty {
                if !updated.apps[0].snapshotTargets.contains(where: { $0.path == target.path }) {
                    updated.apps[0].snapshotTargets.append(target)
                }
            }
            updated.updatedAt = VermouthJSON.currentTimestamp()
            try bottleStore.saveBottle(updated)
            reloadBottlesFromDisk(preferredSelection: updated.id)
        } catch {
            presentError(error)
        }
    }

    func removeSnapshotTarget(targetID: UUID, in bottle: Bottle) {
        do {
            var updated = try bottleStore.loadBottle(id: bottle.id)
            for index in updated.apps.indices {
                updated.apps[index].snapshotTargets.removeAll { $0.id == targetID }
            }
            updated.updatedAt = VermouthJSON.currentTimestamp()
            try bottleStore.saveBottle(updated)
            reloadBottlesFromDisk(preferredSelection: updated.id)
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func createSnapshot(
        for target: SnapshotTarget,
        note: String?,
        in bottle: Bottle
    ) -> SnapshotRecord? {
        do {
            let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = try snapshotManager.createSnapshot(
                bottleID: bottle.id,
                target: target,
                note: (trimmedNote?.isEmpty == false) ? trimmedNote : nil
            )
            reloadSnapshots(for: bottle.id)
            showBanner("已创建快照「\(record.label)」（\(VermouthFormatters.formatBytes(record.totalBytes))）")
            return record
        } catch {
            presentError(error)
            return nil
        }
    }

    func rollbackSnapshot(_ record: SnapshotRecord, in bottle: Bottle) {
        do {
            let backup = try snapshotManager.rollback(
                bottleID: bottle.id,
                snapshotID: record.id,
                destinationOverride: nil
            )
            reloadSnapshots(for: bottle.id)
            showBanner("已原子回滚至「\(record.label)」（已自动生成保底快照 \(backup.id.uuidString.prefix(8))）")
        } catch {
            presentError(error)
        }
    }

    func deleteSnapshot(_ record: SnapshotRecord, in bottle: Bottle) {
        do {
            try snapshotManager.deleteSnapshot(bottleID: bottle.id, snapshotID: record.id)
            reloadSnapshots(for: bottle.id)
            showBanner("已删除快照「\(record.label)」")
        } catch {
            presentError(error)
        }
    }

    // MARK: - Clipboard & Status Feedback

    func copyToClipboard(_ content: String, label: String = "内容") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        showBanner("已复制\(label)到剪贴板")
    }

    func showBanner(_ message: String) {
        statusBannerMessage = message
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.statusBannerMessage = nil
        }
    }

    func presentError(_ error: any Error) {
        if let localized = error as? LocalizedError, let desc = localized.errorDescription {
            errorAlertMessage = desc
        } else {
            errorAlertMessage = error.localizedDescription
        }
    }

    // MARK: - Internal Streaming Execution Engine

    private func executeLaunchTarget(
        _ target: LaunchTarget,
        in bottle: Bottle,
        extraArgs: [String] = [],
        debugChannelsOverride: String? = nil,
        rescanAfterExit: Bool
    ) async {
        guard let engine = resolvedEngine(for: bottle) else {
            isShowingPreflightSheet = true
            presentError(VermouthError.noEngineAvailable)
            return
        }

        // Cancel any previous streaming session cleanly
        activeSessionTask?.cancel()
        activeSessionTask = nil

        let graphicsPkg = resolvedGraphicsPackage(for: bottle)

        do {
            isRunningProcess = true
            appendLogLine(
                LogLine(
                    timestamp: VermouthJSON.currentTimestamp(),
                    stream: .system,
                    text: "正在检查并初始化容器前缀 (\(bottle.name))…"
                )
            )

            try await wineRunner.ensurePrefixInitialized(bottle: bottle, engine: engine)

            let plan = try await wineRunner.buildLaunchPlan(
                bottle: bottle,
                engine: engine,
                target: target,
                graphicsPackage: graphicsPkg,
                extraArgs: extraArgs,
                debugChannelsOverride: debugChannelsOverride
            )

            currentLaunchPlan = plan
            previewLaunchPlan = plan

            for warning in plan.warnings {
                recordDiagnosticFinding(warning)
            }

            appendLogLine(
                LogLine(
                    timestamp: VermouthJSON.currentTimestamp(),
                    stream: .system,
                    text: "启动命令: \(plan.shellCommandPreview)"
                )
            )

            let session = wineRunner.launch(plan)
            let bottleID = bottle.id

            activeSessionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await line in session.stream {
                        self.appendLogLine(line)
                    }
                } catch is CancellationError {
                    self.appendLogLine(
                        LogLine(
                            timestamp: VermouthJSON.currentTimestamp(),
                            stream: .system,
                            text: "会话已取消"
                        )
                    )
                } catch {
                    self.appendLogLine(
                        LogLine(
                            timestamp: VermouthJSON.currentTimestamp(),
                            stream: .stderr,
                            text: "启动错误: \(error.localizedDescription)"
                        )
                    )
                    self.presentError(error)
                }

                self.isRunningProcess = false
                if rescanAfterExit,
                   let latestBottle = self.bottles.first(where: { $0.id == bottleID })
                {
                    await self.scanExecutables(for: latestBottle, silentIfUninitialized: true)
                }
            }
        } catch {
            isRunningProcess = false
            appendLogLine(
                LogLine(
                    timestamp: VermouthJSON.currentTimestamp(),
                    stream: .stderr,
                    text: "启动准备失败: \(error.localizedDescription)"
                )
            )
            presentError(error)
        }
    }

    private func appendLogLine(_ line: LogLine) {
        liveLogLines.append(line)
        if liveLogLines.count > Self.maxBufferedLogLines + Self.logTrimHysteresis {
            liveLogLines.removeFirst(liveLogLines.count - Self.maxBufferedLogLines)
        }

        if line.stream != .system {
            let matches = crashDiagnoser.diagnoseLine(line.text)
            for finding in matches {
                recordDiagnosticFinding(finding)
            }
        }
    }

    private func recordDiagnosticFinding(_ finding: DiagnosticFinding) {
        if seenDiagnosticIDs.insert(finding.id).inserted {
            diagnosticFindings.append(finding)
        }
    }

    private func removeDiagnosticFindings(where predicate: (DiagnosticFinding) -> Bool) {
        let removedIDs = diagnosticFindings.filter(predicate).map(\.id)
        for id in removedIDs {
            seenDiagnosticIDs.remove(id)
        }
        diagnosticFindings.removeAll(where: predicate)
    }

    private func performBusyOperation(
        _ status: String,
        operation: @MainActor () async -> Void
    ) async {
        isBusyWithBottleOperation = true
        busyStatusText = status
        defer {
            isBusyWithBottleOperation = false
            busyStatusText = nil
        }
        await operation()
    }

    private func performBusyThrowingOperation<T: Sendable>(
        _ status: String,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        isBusyWithBottleOperation = true
        busyStatusText = status
        defer {
            isBusyWithBottleOperation = false
            busyStatusText = nil
        }
        return try await operation()
    }

    // MARK: - Static Path Helpers

    private static func canonicalExecutableKey(_ rawPath: String, prefixPath: String) -> String {
        let resolved: URL
        if rawPath.hasPrefix("/") {
            resolved = URL(fileURLWithPath: rawPath)
        } else {
            resolved = URL(fileURLWithPath: prefixPath, isDirectory: true)
                .appendingPathComponent(rawPath)
        }
        return resolved.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    static func enclosingAppBundlePath(for rawPath: String) -> String? {
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
}
#endif
