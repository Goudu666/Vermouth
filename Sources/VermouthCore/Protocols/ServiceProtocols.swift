import Foundation

/// Wine 引擎发现、能力探测与默认引擎管理服务协议。
public protocol EngineManaging: Sendable {
    func runPreflight() async -> PreflightReport
    func listEngines() async throws -> [WineEngine]
    func registerCustomEngine(name: String, rootPath: String) async throws -> WineEngine
    func unregisterCustomEngine(id: String) async throws
    func defaultEngine() async throws -> WineEngine?
    func setDefaultEngine(id: String) async throws
}

/// 容器生命周期与持久化存储服务协议。
public protocol BottleManaging: Sendable {
    func listBottles() throws -> [Bottle]
    func loadBottle(id: UUID) throws -> Bottle
    func createBottle(name: String, engineID: String?, initialConfig: BottleConfig?) throws -> Bottle
    func saveBottle(_ bottle: Bottle) throws
    func renameBottle(id: UUID, newName: String) throws -> Bottle
    func cloneBottle(id: UUID, newName: String) throws -> Bottle
    func importExistingPrefix(name: String, sourcePrefixPath: String, copyFiles: Bool) throws -> Bottle
    func deleteBottle(id: UUID, removePrefixFiles: Bool) throws
}

/// 图形转译层（WineD3D / DXVK-macOS / DXMT）拉取、本地导入与精准部署服务协议。
public protocol GraphicsStackManaging: Sendable {
    func listInstalledPackages() throws -> [GraphicsLayerPackage]
    func fetchAvailableReleases(for backend: GraphicsBackend) async throws -> [RemoteGraphicsRelease]
    func installPackage(
        from release: RemoteGraphicsRelease,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> GraphicsLayerPackage
    func importLocalArchive(at archivePath: String, backend: GraphicsBackend, version: String) async throws -> GraphicsLayerPackage
    func removePackage(id: String, activeBottles: [Bottle]) throws
    func deploymentState(for bottle: Bottle) throws -> GraphicsDeploymentRecord
    func applyBackend(
        _ backend: GraphicsBackend,
        packageID: String?,
        to bottle: Bottle,
        engine: WineEngine
    ) async throws -> GraphicsApplyResult
}

/// Wine 容器初始化、启动计划构建、流式运行与 wineserver 管理服务协议。
public protocol WineRunning: Sendable {
    func ensurePrefixInitialized(bottle: Bottle, engine: WineEngine) async throws
    func buildLaunchPlan(
        bottle: Bottle,
        engine: WineEngine,
        target: LaunchTarget,
        graphicsPackage: GraphicsLayerPackage?,
        extraArgs: [String],
        debugChannelsOverride: String?
    ) async throws -> LaunchPlan

    /// 生成与 `LaunchPlan` 同源的预注入终端 shell 初始化脚本（符合 L-003）。
    func buildInteractiveTerminalScript(
        bottle: Bottle,
        engine: WineEngine,
        graphicsPackage: GraphicsLayerPackage?
    ) throws -> String

    func launch(_ plan: LaunchPlan) -> LaunchSession

    /// 若该前缀当前无运行中的 `wineserver`，视为安全 no-op（不报错，符合 L-003）。
    func killWineServer(for bottle: Bottle, engine: WineEngine, force: Bool) async throws
    func applyBottleRegistrySettings(bottle: Bottle, engine: WineEngine) async throws
}

/// 容器内可执行程序与快捷方式发现服务协议。
public protocol ExecutableScanning: Sendable {
    func scan(prefixPath: String) throws -> [DiscoveredExecutable]
}

/// Wine 运行日志规则化崩溃诊断服务协议。
public protocol CrashDiagnosing: Sendable {
    func diagnose(logs: [String], preflightWarnings: [DiagnosticFinding]) -> [DiagnosticFinding]
    func diagnoseLine(_ line: String) -> [DiagnosticFinding]
}

/// 配置/存档目录 SHA-256 原子快照与回滚服务协议（符合 L-011）。
public protocol SnapshotManaging: Sendable {
    func listSnapshots(bottleID: UUID, targetID: UUID?) throws -> [SnapshotRecord]
    func createSnapshot(bottleID: UUID, target: SnapshotTarget, note: String?) throws -> SnapshotRecord
    /// 先校验 SHA-256 与路径安全，再自动创建保底快照并执行兄弟临时目录原子替换回滚；`destinationOverride` 为 `nil` 时使用 `snapshot.sourcePath`
    func rollback(bottleID: UUID, snapshotID: UUID, destinationOverride: String?) throws -> SnapshotRecord
    func deleteSnapshot(bottleID: UUID, snapshotID: UUID) throws
}

/// 兼容配方加载、应用规划与脱敏导出服务协议。
public protocol RecipeManaging: Sendable {
    func listRecipes() throws -> [Recipe]
    func loadRecipe(from filePath: String) throws -> Recipe
    func planApplication(of recipe: Recipe, to bottle: Bottle, engine: WineEngine?) -> RecipeApplicationPlan
    func exportSanitizedRecipe(from bottle: Bottle, id: String, name: String, summary: String) -> Recipe
}
