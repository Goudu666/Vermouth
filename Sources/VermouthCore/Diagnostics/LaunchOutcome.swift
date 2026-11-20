import Foundation

/// 一次运行结束后的「人话」结论，普通界面据此决定是否弹出问题助手。
public enum LaunchOutcome: Equatable, Sendable {
    /// 正常退出，没有值得打扰用户的问题
    case finished
    /// 用户主动停止
    case stopped
    /// 正常退出，但诊断出了可能影响体验的问题
    case needsAttention(findingCount: Int)
    /// 异常退出（非零退出码或启动失败）
    case crashed(exitCode: Int32?, findingCount: Int)

    /// 是否应该主动提示用户
    public var shouldNotifyUser: Bool {
        switch self {
        case .finished, .stopped:
            return false
        case .needsAttention, .crashed:
            return true
        }
    }

    /// 给普通用户看的一句话标题
    public func headline(programName: String) -> String {
        switch self {
        case .finished:
            return "「\(programName)」已退出"
        case .stopped:
            return "已停止「\(programName)」"
        case let .needsAttention(count):
            return "「\(programName)」运行时遇到 \(count) 个可能的问题"
        case let .crashed(_, count):
            if count > 0 {
                return "「\(programName)」没能正常运行，找到了 \(count) 个可能的原因"
            }
            return "「\(programName)」意外退出了"
        }
    }
}

public enum LaunchOutcomeEvaluator {
    /// - Parameters:
    ///   - exitCode: 子进程退出码；`nil` 表示没拿到（启动失败或流异常结束）
    ///   - wasStopped: 用户主动停止
    ///   - newFindings: 本次运行期间新出现的诊断
    public static func evaluate(
        exitCode: Int32?,
        wasStopped: Bool,
        newFindings: [DiagnosticFinding]
    ) -> LaunchOutcome {
        if wasStopped {
            return .stopped
        }
        let actionable = newFindings.filter { $0.severity != .info }
        guard let exitCode, exitCode == 0 else {
            return .crashed(exitCode: exitCode, findingCount: actionable.count)
        }
        if !actionable.isEmpty {
            return .needsAttention(findingCount: actionable.count)
        }
        return .finished
    }
}
