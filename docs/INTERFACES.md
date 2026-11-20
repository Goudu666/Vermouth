# Vermouth 核心接口与数据契约（Interface & Schema Specification）

> **状态**：Phase 0 接口定型稿（已通过 Phase 0 对抗审查修订，符合 Swift 6 `StrictConcurrency` 编译约束）  
> **适用范围**：`VermouthCore` 公开 API、持久化 JSON Schema、`VermouthCLI` 命令接口  
> **并发约束**：所有跨边界数据模型均为 `Sendable, Codable, Equatable` 值类型；所有服务协议均要求 `Sendable`；**严禁在 `async` 协议方法中使用 `inout` 传递可能受 Actor 隔离的状态**。

---

## 1. 系统边界协议（System Boundaries）

所有宿主机副作用收敛到 3 个 `Sendable` 协议，测试时可无痛注入 Mock：

```swift
public enum ProcessStreamChunk: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(Int32)
}

public struct CommandRequest: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]
    /// 当 `inheritEnvironment == true` 时合并覆盖当前进程环境；为 `false` 时仅使用此字典
    public let environment: [String: String]
    public let inheritEnvironment: Bool
    public let workingDirectory: String?
}

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public struct OSVersionInfo: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let displayString: String         // 如 "macOS 26.5.1"

    public func isAtLeast(major: Int, minor: Int = 0) -> Bool
}

public struct DownloadProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let totalBytesExpected: Int64?    // 服务端无 Content-Length 时为 nil
    public var fractionCompleted: Double?
}

/// 抽象子进程调度（生产：LiveCommandRunner 必须并发排空 stdout/stderr 并在 EOF 同步后再发 .exited）
public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<ProcessStreamChunk, Error>
}

/// 抽象宿主机只读探测与 Quarantine 属性操作
public protocol SystemProbing: Sendable {
    func hostArchitecture() -> HostArchitecture
    func operatingSystemVersion() -> OSVersionInfo
    func isRosetta2Installed() async -> Bool
    func findExecutable(named: String, searchPaths: [String]) -> String?
    func isQuarantined(path: String) async -> Bool
    func removeQuarantine(path: String, recursive: Bool) async throws
}

/// 抽象网络拉取（生产实现需通过 `#if canImport(FoundationNetworking)` 兼容双端，使用 continuation 封装）
public protocol HTTPFetching: Sendable {
    func data(from url: URL, headers: [String: String]) async throws -> Data
    func download(
        from url: URL,
        to destination: URL,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws
}
```

---

## 2. 核心领域模型（Domain Models）

### 2.1 引擎与预检模型（`EngineModels.swift`）

```swift
public enum HostArchitecture: String, Codable, Sendable {
    case arm64, x86_64, unknown
}

public enum EngineSource: String, Codable, Sendable {
    case homebrewCask      // /Applications/Wine *.app 或 /opt/homebrew
    case applicationBundle // CrossOver.app 或其他 .app
    case managed           // ~/Library/Application Support/Vermouth/Engines/
    case custom            // 用户手动登记目录
}

public struct EngineCapabilities: Codable, Equatable, Sendable {
    public var supports32Bit: Bool
    public var supports64Bit: Bool
    public var isNewWoW64: Bool              // Wine 9+ 单 wine 二进制 WoW64（禁止设置 WINEARCH=win32）
    public var supportsMSync: Bool
    public var supportsWineDLLPathPrepend: Bool
}

public struct WineEngine: Codable, Equatable, Identifiable, Sendable {
    public var id: String                    // 稳定标识符（如 "app-wine-stable" 或自定义 UUID）
    public var name: String                  // 展示名（如 "Wine Stable 11.0 (WoW64)"）
    public var rootPath: String              // 引擎根目录（含 bin/ 与 lib/wine/）
    public var wineBinaryPath: String        // 实际可执行路径（wine 或 wine64）
    public var wineserverPath: String        // wineserver 路径
    public var version: String               // `wine --version` 原始输出
    public var source: EngineSource
    public var capabilities: EngineCapabilities
    public var isQuarantined: Bool
}

public struct PreflightCheckItem: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case pass, warning, fail }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    public var remediationCommand: String?   // 一键复制的终端引导命令（绝不静默执行）
}

public struct PreflightReport: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var architecture: HostArchitecture
    public var osVersion: OSVersionInfo
    public var rosetta2Ready: Bool
    public var homebrewPath: String?
    public var winetricksPath: String?
    public var discoveredEngines: [WineEngine]
    public var items: [PreflightCheckItem]
    public var isReadyToLaunch: Bool
}
```

### 2.2 容器、覆写与预设模型（`BottleModels.swift`）

```swift
public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case winxp, win7, win10, win11
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case msync, esync, none
}

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case wined3d
    case dxvk      // Gcenx/DXVK-macOS
    case dxmt      // 3Shain/dxmt
}

public enum DllOverrideMode: String, Codable, CaseIterable, Sendable {
    case nativeThenBuiltin = "n,b"
    case builtinThenNative = "b,n"
    case nativeOnly = "n"
    case builtinOnly = "b"
    case disabled = ""
}

public struct DllOverride: Codable, Equatable, Identifiable, Sendable {
    public var id: String { dllName }        // dllName 在 init 与 init(from:) 中统一规范为小写、去空格、去 .dll 后缀
    public let dllName: String
    public var mode: DllOverrideMode
    public var enabled: Bool
    public var note: String?

    public static func normalizeName(_ raw: String) -> String

    /// PRD §4.1F 内置高频快捷预设（ASI / CLEO / ModLoader / BepInEx 等）
    public static let commonPresets: [DllOverride] // dinput8, vorbisFile, winhttp, version, dsound, d3d9
}

public struct VirtualDesktopConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var width: Int
    public var height: Int
}

public struct DisplayConfig: Codable, Equatable, Sendable {
    public var retinaMode: Bool
    public var dpi: Int                      // 96 / 144 / 192
    public var metalHUD: Bool                // MTL_HUD_ENABLED=1
    public var virtualDesktop: VirtualDesktopConfig
}

public struct LocaleConfig: Codable, Equatable, Sendable {
    public var chineseLocalizationEnabled: Bool
    public var lcAll: String                 // 开启时默认 "zh_CN.UTF-8"
    public var fallbackFontName: String      // 按本机实际可用中文字体回退探测（STHeiti / Hiragino Sans GB / PingFang SC）
}

public struct AppEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var executablePath: String        // 相对 prefix 或绝对路径
    public var arguments: [String]
    public var workingDirectory: String?
    public var environmentOverrides: [String: String]
    public var dllOverrides: [DllOverride]
    public var snapshotTargets: [SnapshotTarget]
    public var isPinned: Bool
    public var lastLaunchedAt: Date?
}

public struct BottleConfig: Codable, Equatable, Sendable {
    public var engineID: String?
    public var windowsVersion: WindowsVersion
    public var syncMode: SyncMode
    public var graphicsBackend: GraphicsBackend
    public var graphicsLayerVersionID: String?
    public var display: DisplayConfig
    public var locale: LocaleConfig
    public var dllOverrides: [DllOverride]
    public var environmentVariables: [String: String]
    public var wineDebugChannels: String     // 默认 "-all,err+all"
}

public struct Bottle: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int            // 当前为 1
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var prefixPath: String
    public var isExternalPrefix: Bool        // 为 true 时（外部引用导入），删除容器默认禁止删除外部 prefix 目录
    public var config: BottleConfig
    public var apps: [AppEntry]
    public var appliedRecipeID: String?
}
```

### 2.3 图形转译层模型（`GraphicsModels.swift`）

```swift
public enum GraphicsArchiveFormat: String, Codable, Sendable {
    case wineBuiltin   // 含 x86_64-windows/ + 可选 x86_64-unix/ + 可选 i386-windows/（必须走 WINEDLLPATH_PREPEND）
    case nativeDLLs    // 含 x64/ + 可选 x32/（可走 prefixCopyWithBackup）
}

public enum GraphicsDeploymentStrategy: String, Codable, Sendable {
    case wined3dBuiltin
    case wineDLLPathPrepend
    case prefixCopyWithBackup
}

public struct RemoteGraphicsRelease: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(backend.rawValue)-\(tagName)-\(assetName)" }
    public var backend: GraphicsBackend
    public var tagName: String
    public var version: String
    public var assetName: String
    public var downloadURL: URL
    public var sizeBytes: Int64?
    public var format: GraphicsArchiveFormat
    public var publishedAt: Date?
}

public struct GraphicsLayerPackage: Codable, Equatable, Identifiable, Sendable {
    public var id: String                    // 如 "dxmt-v0.80" / "dxvk-v1.10.3-20230507-repack"
    public var backend: GraphicsBackend
    public var version: String
    public var format: GraphicsArchiveFormat
    public var installPath: String
    public var sourceURL: String?
    public var sha256: String?
    public var installedAt: Date
    public var containedDLLs: [String]       // 小写无后缀，如 ["d3d11", "dxgi", "d3d10core", "winemetal"]
}

public struct GraphicsDeploymentRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var backend: GraphicsBackend
    public var packageID: String?
    public var strategy: GraphicsDeploymentStrategy
    public var deployedFiles: [String]       // 相对 prefix 的已写入路径
    public var backedUpFiles: [String: String] // prefix 相对路径 -> backup 相对路径
    public var updatedAt: Date
}

/// 值语义返回，避免 Swift 6 async + inout Actor 隔离编译冲突
public struct GraphicsApplyResult: Equatable, Sendable {
    public let bottle: Bottle
    public let record: GraphicsDeploymentRecord
    public let warnings: [DiagnosticFinding]
}
```

### 2.4 启动计划、日志、发现、诊断、快照与配方模型

```swift
public enum PEArchitecture: String, Codable, Sendable {
    case x86_32, x86_64, arm64, unknown
}

public struct PEInspectionResult: Codable, Equatable, Sendable {
    public var path: String
    public var architecture: PEArchitecture
    public var isDLL: Bool
    public var subsystem: UInt16
}

public enum WineBuiltinTool: String, Codable, CaseIterable, Sendable {
    case winecfg, regedit, cmd, wineboot
}

public enum LaunchTarget: Codable, Equatable, Sendable {
    case executable(path: String, workingDirectory: String?)
    case appEntry(AppEntry)
    case installer(path: String)             // 自动识别 .msi（转 msiexec /i Z:\... 并跳过 PE 检查）与 .exe
    case builtinTool(WineBuiltinTool, extraArguments: [String])
}

public struct LogLine: Codable, Equatable, Identifiable, Sendable {
    public enum Stream: String, Codable, Sendable { case stdout, stderr, system }
    public var id: UUID
    public var timestamp: Date
    public var stream: Stream
    public var text: String
    public var exitCode: Int32?              // 仅在进程结束的系统事件行非 nil
}

public struct LaunchPlan: Codable, Equatable, Sendable {
    public var bottleID: UUID
    public var engine: WineEngine
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var warnings: [DiagnosticFinding]
    public var logFilePath: String           // 落盘日志路径 bottles/<UUID>/logs/<timestamp>-<target>.log
    public var shellCommandPreview: String   // POSIX 单引号安全转义命令
}

public struct LaunchSession: Sendable {
    public let plan: LaunchPlan
    public let logFilePath: String
    public let stream: AsyncThrowingStream<LogLine, Error>
}

public struct DiscoveredExecutable: Codable, Equatable, Identifiable, Sendable {
    public enum DiscoverySource: String, Codable, Sendable {
        case startMenuShortcut
        case desktopShortcut
        case programFilesScan
    }
    public var id: String { executablePath.lowercased() }
    public var name: String
    public var executablePath: String        // 宿主机绝对路径
    public var arguments: [String]
    public var workingDirectory: String?
    public var source: DiscoverySource
    public var architecture: PEArchitecture
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case info, warning, error
}

public enum DiagnosticCategory: String, Codable, Sendable {
    case missingDLL
    case quarantineBlocked
    case architectureMismatch
    case graphicsInitFailed
    case dllOverrideConflict
    case syncMismatch
    case rosettaMissing
    case fontOrLocale
}

public enum DiagnosticQuickFix: Codable, Equatable, Sendable {
    case removeQuarantine(path: String, recursive: Bool)
    case switchGraphicsBackend(GraphicsBackend)
    case killWineServer
    case select32BitCapableEngine
    case removeConflictingDllOverrides([String])
    case enableChineseLocalization
    case copyCommand(label: String, command: String)
}

public struct DiagnosticFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var category: DiagnosticCategory
    public var severity: DiagnosticSeverity
    public var title: String
    public var explanation: String
    public var suggestion: String
    public var matchedLine: String?
    public var missingDLLName: String?
    public var recommendedRuntime: String?
    public var quickFix: DiagnosticQuickFix?
}

public struct SnapshotTarget: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var path: String                  // 绝对路径或相对 prefix 的路径（支持目录与单文件）
}

public struct SnapshotRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var targetID: UUID
    public var label: String
    public var sourcePath: String            // 快照创建时的规范化源路径，供回滚默认还原
    public var isDirectory: Bool
    public var note: String?
    public var createdAt: Date
    public var archivePath: String
    public var fileCount: Int
    public var totalBytes: UInt64
    public var sha256: String
}

public struct Recipe: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int            // 当前为 1
    public var id: String
    public var name: String
    public var summary: String
    public var targetArchitecture: PEArchitecture
    public var recommendedWindowsVersion: WindowsVersion
    public var recommendedBackend: GraphicsBackend
    public var recommendedSyncMode: SyncMode
    public var chineseLocalizationSuggested: Bool
    public var dllOverrides: [DllOverride]
    public var environmentVariables: [String: String]
    public var wineDebugChannels: String?
    public var notes: [String]
    public var knownIssues: [String]
}

public struct RecipeApplicationPlan: Equatable, Sendable {
    public let updatedBottle: Bottle
    public let requiresGraphicsBackendChange: Bool
    public let requiresRegistrySync: Bool
    public let requiresWineServerRestart: Bool
    public let warnings: [DiagnosticFinding] // 如目标架构 32 位但当前引擎不支持 32 位
}
```

---

## 3. 核心服务协议（Service Contracts）

```swift
public protocol EngineManaging: Sendable {
    func runPreflight() async -> PreflightReport
    func listEngines() async throws -> [WineEngine]
    func registerCustomEngine(name: String, rootPath: String) async throws -> WineEngine
    func unregisterCustomEngine(id: String) async throws
    func defaultEngine() async throws -> WineEngine?
    func setDefaultEngine(id: String) async throws
}

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

    /// 生成与 LaunchPlan 同源的预注入终端 shell 初始化脚本（PRD §4.1B）
    func buildInteractiveTerminalScript(
        bottle: Bottle,
        engine: WineEngine,
        graphicsPackage: GraphicsLayerPackage?
    ) throws -> String

    func launch(_ plan: LaunchPlan) -> LaunchSession
    /// 若该前缀当前无运行中的 wineserver，视为安全 no-op（不报错）
    func killWineServer(for bottle: Bottle, engine: WineEngine, force: Bool) async throws
    func applyBottleRegistrySettings(bottle: Bottle, engine: WineEngine) async throws
}

public protocol ExecutableScanning: Sendable {
    func scan(prefixPath: String) throws -> [DiscoveredExecutable]
}

public protocol CrashDiagnosing: Sendable {
    func diagnose(logs: [String], preflightWarnings: [DiagnosticFinding]) -> [DiagnosticFinding]
    func diagnoseLine(_ line: String) -> [DiagnosticFinding]
}

public protocol SnapshotManaging: Sendable {
    func listSnapshots(bottleID: UUID, targetID: UUID?) throws -> [SnapshotRecord]
    func createSnapshot(bottleID: UUID, target: SnapshotTarget, note: String?) throws -> SnapshotRecord
    /// 先校验 SHA-256 与路径安全，再自动创建保底快照并执行兄弟临时目录原子替换回滚；destinationOverride 为 nil 时使用 snapshot.sourcePath
    func rollback(bottleID: UUID, snapshotID: UUID, destinationOverride: String?) throws -> SnapshotRecord
    func deleteSnapshot(bottleID: UUID, snapshotID: UUID) throws
}

public protocol RecipeManaging: Sendable {
    func listRecipes() throws -> [Recipe]
    func loadRecipe(from filePath: String) throws -> Recipe
    func planApplication(of recipe: Recipe, to bottle: Bottle, engine: WineEngine?) -> RecipeApplicationPlan
    func exportSanitizedRecipe(from bottle: Bottle, id: String, name: String, summary: String) -> Recipe
}
```

---

## 4. 持久化文件布局与 JSON 约定

数据根目录默认为 `~/Library/Application Support/Vermouth`（支持环境变量 `VERMOUTH_HOME` 覆写），所有 JSON 统一由 `VermouthJSON`（ISO-8601 含毫秒、2 空格缩进、键排序、不转义斜杠、原子替换写盘）序列化：

```text
$VERMOUTH_HOME/
├── engines.json                     # schemaVersion, defaultEngineID, customEngines[]
├── graphics/
│   ├── index.json                   # 已安装图形包元数据索引
│   ├── dxmt/<version>/              # 解压后的 DXMT 文件（根下含 x86_64-unix / x86_64-windows / i386-windows）
│   └── dxvk/<version>/              # 解压后的 DXVK-macOS 文件
├── recipes/
│   └── *.recipe.json                # 用户导入配方（内置配方同为 *.recipe.json，打包于 Resources）
└── bottles/
    └── <UUID>/
        ├── bottle.json              # 期望状态配置（schemaVersion: 1）
        ├── graphics-state.json      # 落盘部署状态与回滚记录
        ├── prefix/                  # 独立 WINEPREFIX（仅当 isExternalPrefix == false 时归容器托管）
        ├── backups/                 # 图形 DLL 原始文件备份
        ├── snapshots/               # 时间戳快照归档 + index.json
        └── logs/                    # 每次启动的原始日志文件
```

### `WINEDLLOVERRIDES` 合成优先级与冲突检测契约

1. **图形层规则**：
   - `wineBuiltin`（如 DXMT v0.80 / DXVK builtin）：对包内 DLL（如 `d3d11`, `dxgi`, `d3d10core`, `winemetal`）**发出 `=b`**（覆盖旧注册表残留 `n,b`），绝不输出 `n,b`；若用户配置了同名 `n,b`/`n` 覆写，立即产出 `.dllOverrideConflict` 警告与一键移除 `DiagnosticQuickFix`。
   - `nativeDLLs`（如传统 DXVK）：**仅对实际包含并部署进容器的 DLL** 自动添加 `=n,b`。
2. **容器级 `bottle.config.dllOverrides`**（仅 `enabled == true`）。
3. **单程序级 `app.dllOverrides`**（同名 DLL 覆盖容器级）。
4. **规范化输出**：全部去 `.dll` 后缀转小写，按 DLL 名称字典序输出（如 `d3d10core=n,b;d3d11=n,b;dinput8=n,b`）。

---

## 5. `VermouthCLI` 命令契约

```text
vermouth preflight [--json]
vermouth engine list [--json]
vermouth engine add <name> <root-path>
vermouth engine default <engine-id>
vermouth bottle list [--json]
vermouth bottle create <name> [--win win10] [--graphics wined3d|dxvk|dxmt] [--sync msync|esync|none]
vermouth bottle inspect <name-or-id> [--json]
vermouth bottle clone <source> <new-name>
vermouth bottle import <name> <prefix-path> [--copy]
vermouth bottle delete <name-or-id> [--keep-prefix]
vermouth bottle chinese-fix <name-or-id>
vermouth bottle terminal-script <name-or-id>
vermouth bottle kill <name-or-id> [--force]
vermouth graphics list [--json]
vermouth graphics import <dxmt|dxvk> <version> <archive-path>
vermouth graphics set <bottle> <wined3d|dxvk|dxmt> [--package <id>]
vermouth run <bottle> <exe-or-msi-path> [--dry-run] [--debug <channels>] [-- <args...>]
vermouth scan <bottle> [--json]
vermouth diagnose <log-file-path> [--json]
vermouth snapshot create <bottle> <path> [--label <name>] [--note <text>]
vermouth snapshot list <bottle> [--json]
vermouth snapshot rollback <bottle> <snapshot-id> [--to <override-path>]
vermouth recipe list [--json]
vermouth recipe apply <bottle> <recipe-id-or-path>
vermouth recipe export <bottle> <output-path> --id <id> --name <name>
```
