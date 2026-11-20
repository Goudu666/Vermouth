import Foundation

/// 社区与内置兼容配方模型（`*.recipe.json`，当前 `schemaVersion == 1`）。
public struct Recipe: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
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

    public init(
        schemaVersion: Int = Recipe.currentSchemaVersion,
        id: String,
        name: String,
        summary: String,
        targetArchitecture: PEArchitecture,
        recommendedWindowsVersion: WindowsVersion,
        recommendedBackend: GraphicsBackend,
        recommendedSyncMode: SyncMode,
        chineseLocalizationSuggested: Bool = false,
        dllOverrides: [DllOverride] = [],
        environmentVariables: [String: String] = [:],
        wineDebugChannels: String? = nil,
        notes: [String] = [],
        knownIssues: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.summary = summary
        self.targetArchitecture = targetArchitecture
        self.recommendedWindowsVersion = recommendedWindowsVersion
        self.recommendedBackend = recommendedBackend
        self.recommendedSyncMode = recommendedSyncMode
        self.chineseLocalizationSuggested = chineseLocalizationSuggested
        self.dllOverrides = dllOverrides
        self.environmentVariables = environmentVariables
        self.wineDebugChannels = wineDebugChannels
        self.notes = notes
        self.knownIssues = knownIssues
    }
}

/// 将配方应用到容器前生成的副作用与风险预览计划。
public struct RecipeApplicationPlan: Equatable, Sendable {
    public let updatedBottle: Bottle
    public let requiresGraphicsBackendChange: Bool
    public let requiresRegistrySync: Bool
    public let requiresWineServerRestart: Bool
    /// 兼容性提示与警告（例如目标架构 32 位但当前引擎不支持 32 位）
    public let warnings: [DiagnosticFinding]

    public init(
        updatedBottle: Bottle,
        requiresGraphicsBackendChange: Bool,
        requiresRegistrySync: Bool,
        requiresWineServerRestart: Bool,
        warnings: [DiagnosticFinding] = []
    ) {
        self.updatedBottle = updatedBottle
        self.requiresGraphicsBackendChange = requiresGraphicsBackendChange
        self.requiresRegistrySync = requiresRegistrySync
        self.requiresWineServerRestart = requiresWineServerRestart
        self.warnings = warnings
    }
}
