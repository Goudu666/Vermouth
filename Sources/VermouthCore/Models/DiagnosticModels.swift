import Foundation

/// 诊断严重级别。
public enum DiagnosticSeverity: String, Codable, Equatable, CaseIterable, Sendable {
    case info
    case warning
    case error
}

/// 规则化诊断分类。
public enum DiagnosticCategory: String, Codable, Equatable, CaseIterable, Sendable {
    case missingDLL
    case quarantineBlocked
    case architectureMismatch
    case graphicsInitFailed
    case dllOverrideConflict
    case syncMismatch
    case rosettaMissing
    case fontOrLocale
    /// 图形包内容与引擎不配套（如 DXVK 包缺 `dxgi.dll`）
    case graphicsPackageIncomplete
}

/// 类型化一键修复建议动作（由用户显式触发，绝不静默修改宿主机环境）。
public enum DiagnosticQuickFix: Codable, Equatable, Sendable {
    case removeQuarantine(path: String, recursive: Bool)
    case switchGraphicsBackend(GraphicsBackend)
    case killWineServer
    case select32BitCapableEngine
    case removeConflictingDllOverrides([String])
    case enableChineseLocalization
    case copyCommand(label: String, command: String)
}

/// 单条诊断发现项。
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

    public init(
        id: String,
        category: DiagnosticCategory,
        severity: DiagnosticSeverity,
        title: String,
        explanation: String,
        suggestion: String,
        matchedLine: String? = nil,
        missingDLLName: String? = nil,
        recommendedRuntime: String? = nil,
        quickFix: DiagnosticQuickFix? = nil
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.suggestion = suggestion
        self.matchedLine = matchedLine
        self.missingDLLName = missingDLLName
        self.recommendedRuntime = recommendedRuntime
        self.quickFix = quickFix
    }
}
