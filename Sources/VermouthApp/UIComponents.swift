#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import VermouthCore

// MARK: - Display Metadata Extensions

extension WindowsVersion {
    var displayName: String {
        switch self {
        case .winxp:
            return "Windows XP"
        case .win7:
            return "Windows 7"
        case .win10:
            return "Windows 10"
        case .win11:
            return "Windows 11"
        }
    }

    var shortBadgeTitle: String {
        switch self {
        case .winxp:
            return "WinXP"
        case .win7:
            return "Win7"
        case .win10:
            return "Win10"
        case .win11:
            return "Win11"
        }
    }
}

extension GraphicsBackend {
    var displayName: String {
        switch self {
        case .wined3d:
            return "WineD3D"
        case .dxvk:
            return "DXVK-macOS"
        case .dxmt:
            return "DXMT"
        }
    }

    var subtitle: String {
        switch self {
        case .wined3d:
            return "Wine 内置默认 · DirectX 7/8/9 老游戏高兼容兜底"
        case .dxvk:
            return "Gcenx/DXVK-macOS · DirectX 10/11 → MoltenVK → Metal"
        case .dxmt:
            return "3Shain/dxmt · DirectX 10/11 → Apple Metal 原生直译（性能主力）"
        }
    }

    var badgeTint: Color {
        switch self {
        case .wined3d:
            return .secondary
        case .dxvk:
            return .purple
        case .dxmt:
            return .blue
        }
    }

    var systemImage: String {
        switch self {
        case .wined3d:
            return "cube"
        case .dxvk:
            return "square.3.layers.3d"
        case .dxmt:
            return "bolt.horizontal.circle"
        }
    }
}

extension SyncMode {
    var displayName: String {
        switch self {
        case .msync:
            return "MSync（macOS Mach 信号量，推荐）"
        case .esync:
            return "ESync（文件描述符事件同步）"
        case .none:
            return "关闭（传统 wineserver 同步）"
        }
    }

    var shortLabel: String {
        switch self {
        case .msync:
            return "MSync"
        case .esync:
            return "ESync"
        case .none:
            return "Sync Off"
        }
    }
}

extension DllOverrideMode {
    var displayName: String {
        switch self {
        case .nativeThenBuiltin:
            return "原装优先，回退内置 (native, builtin)"
        case .builtinThenNative:
            return "内置优先，回退原装 (builtin, native)"
        case .nativeOnly:
            return "仅原装 DLL (native)"
        case .builtinOnly:
            return "仅 Wine 内置 (builtin)"
        case .disabled:
            return "禁用加载 (disabled)"
        }
    }

    var shortCode: String {
        switch self {
        case .nativeThenBuiltin:
            return "n,b"
        case .builtinThenNative:
            return "b,n"
        case .nativeOnly:
            return "n"
        case .builtinOnly:
            return "b"
        case .disabled:
            return "disabled"
        }
    }
}

extension PEArchitecture {
    var displayName: String {
        switch self {
        case .x86_32:
            return "32-bit (x86)"
        case .x86_64:
            return "64-bit (x64)"
        case .arm64:
            return "ARM64"
        case .unknown:
            return "未知架构"
        }
    }

    var badgeTint: Color {
        switch self {
        case .x86_32:
            return .orange
        case .x86_64:
            return .teal
        case .arm64:
            return .green
        case .unknown:
            return .secondary
        }
    }
}

extension EngineSource {
    var displayName: String {
        switch self {
        case .homebrewCask:
            return "Homebrew / App"
        case .applicationBundle:
            return "应用捆绑包"
        case .managed:
            return "Vermouth 托管"
        case .custom:
            return "手动登记"
        }
    }
}

extension GraphicsArchiveFormat {
    var displayName: String {
        switch self {
        case .wineBuiltin:
            return "wineBuiltin (零拷贝注入)"
        case .nativeDLLs:
            return "nativeDLLs (容器部署)"
        }
    }
}

extension GraphicsDeploymentStrategy {
    var displayName: String {
        switch self {
        case .wined3dBuiltin:
            return "Wine 内置 WineD3D（未注入外部图形 DLL）"
        case .wineDLLPathPrepend:
            return "WINEDLLPATH_PREPEND 零拷贝注入（强制 =b 保护）"
        case .prefixCopyWithBackup:
            return "容器 system32/syswow64 部署（原始 DLL 已备份）"
        }
    }
}

extension DiscoveredExecutable.DiscoverySource {
    var displayName: String {
        switch self {
        case .startMenuShortcut:
            return "开始菜单"
        case .desktopShortcut:
            return "桌面快捷方式"
        case .programFilesScan:
            return "Program Files"
        }
    }

    var systemImage: String {
        switch self {
        case .startMenuShortcut:
            return "list.star"
        case .desktopShortcut:
            return "menubar.dock.rectangle"
        case .programFilesScan:
            return "folder.badge.gearshape"
        }
    }
}

extension DiagnosticSeverity {
    var tintColor: Color {
        switch self {
        case .error:
            return .red
        case .warning:
            return .orange
        case .info:
            return .blue
        }
    }

    var systemImage: String {
        switch self {
        case .error:
            return "xmark.octagon.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .error:
            return "错误"
        case .warning:
            return "警告"
        case .info:
            return "提示"
        }
    }
}

extension DiagnosticQuickFix {
    var buttonTitle: String {
        switch self {
        case let .removeQuarantine(_, recursive):
            return recursive ? "一键解除目录隔离属性" : "一键解除文件隔离属性"
        case let .switchGraphicsBackend(backend):
            return "一键切换图形后端至 \(backend.displayName)"
        case .killWineServer:
            return "一键终止残留 wineserver"
        case .select32BitCapableEngine:
            return "切换至支持 32 位的引擎"
        case let .removeConflictingDllOverrides(names):
            return "移除冲突覆写 (\(names.joined(separator: ", ")))"
        case .enableChineseLocalization:
            return "一键开启中文环境与字体补全"
        case let .copyCommand(label, _):
            return label
        }
    }

    var systemImage: String {
        switch self {
        case .removeQuarantine:
            return "lock.open.fill"
        case .switchGraphicsBackend:
            return "arrow.triangle.2.circlepath"
        case .killWineServer:
            return "stop.circle.fill"
        case .select32BitCapableEngine:
            return "cpu"
        case .removeConflictingDllOverrides:
            return "trash"
        case .enableChineseLocalization:
            return "character.book.closed.fill"
        case .copyCommand:
            return "doc.on.doc"
        }
    }
}

// MARK: - Formatting Helpers

enum VermouthFormatters {
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let clamped = bytes > UInt64(Int64.max) ? Int64.max : Int64(bytes)
        return ByteCountFormatter.string(fromByteCount: clamped, countStyle: .file)
    }

    static func formatDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func formatConsoleTime(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
        var wholeSeconds = totalMs / 1000
        var remainderMs = totalMs % 1000
        if remainderMs < 0 {
            remainderMs += 1000
            wholeSeconds -= 1
        }
        let wholeDate = Date(timeIntervalSince1970: Double(wholeSeconds))
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: wholeDate)
        return String(
            format: "%02d:%02d:%02d.%03d",
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0,
            Int(remainderMs)
        )
    }
}

// MARK: - Reusable Native UI Components

struct PillBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct EngineCapabilityPills: View {
    let engine: WineEngine

    var body: some View {
        HStack(spacing: 6) {
            if engine.capabilities.supports64Bit {
                PillBadge(text: "64-bit", tint: .teal)
            }
            if engine.capabilities.supports32Bit {
                PillBadge(
                    text: engine.capabilities.isNewWoW64 ? "32-bit (New WoW64)" : "32-bit",
                    tint: .green
                )
            } else {
                PillBadge(text: "无 32-bit", systemImage: "exclamationmark.circle", tint: .orange)
            }
            if engine.capabilities.supportsMSync {
                PillBadge(text: "MSync", tint: .indigo)
            }
            if engine.capabilities.supportsWineDLLPathPrepend {
                PillBadge(text: "DLLPathPrepend", tint: .blue)
            } else {
                PillBadge(text: "无 DLLPathPrepend", tint: .secondary)
            }
            if engine.isQuarantined {
                PillBadge(text: "Quarantined", systemImage: "lock.fill", tint: .orange)
            }
        }
    }
}

struct DiagnosticFindingCard: View {
    let finding: DiagnosticFinding
    let onQuickFix: (DiagnosticQuickFix) -> Void
    var onDismiss: (() -> Void)? = nil
    /// 提供时，若诊断建议安装某个 winetricks 运行库，额外显示「一键安装」按钮。
    var onInstallRuntime: ((String) -> Void)? = nil

    private var winetricksVerb: String? {
        guard case let .copyCommand(_, command)? = finding.quickFix, command.hasPrefix("winetricks") else {
            return nil
        }
        return command.split(separator: " ").last.map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.severity.systemImage)
                    .foregroundStyle(finding.severity.tintColor)
                Text(finding.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let recommended = finding.recommendedRuntime {
                    PillBadge(text: recommended, systemImage: "shippingbox", tint: .purple)
                }
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("忽略此条诊断提示")
                }
            }

            Text(finding.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(finding.suggestion)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let matchedLine = finding.matchedLine, !matchedLine.isEmpty {
                Text(matchedLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.75), in: .rect(cornerRadius: 6))
            }

            if let quickFix = finding.quickFix {
                HStack {
                    Button {
                        onQuickFix(quickFix)
                    } label: {
                        Label(quickFix.buttonTitle, systemImage: quickFix.systemImage)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(finding.severity == .error ? .red : .accentColor)

                    if let verb = winetricksVerb, let onInstallRuntime {
                        Button {
                            onInstallRuntime(verb)
                        } label: {
                            Label("一键安装 \(verb)", systemImage: "puzzlepiece.extension")
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            finding.severity.tintColor.opacity(0.08),
            in: .rect(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(finding.severity.tintColor.opacity(0.28), lineWidth: 1)
        )
    }
}

struct LaunchPlanInspectorView: View {
    let plan: LaunchPlan
    let onCopyCommand: (String) -> Void

    @State private var isShowingEnvironmentTable = false

    private var sortedEnvironmentPairs: [(key: String, value: String)] {
        plan.environment.keys.sorted().compactMap { key in
            guard let value = plan.environment[key] else { return nil }
            return (key: key, value: value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实际执行命令预览 (LaunchPlan)")
                        .font(.subheadline.weight(.semibold))
                    Text("界面按钮启动与终端复现 100% 同源，POSIX 单引号安全转义")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onCopyCommand(plan.shellCommandPreview)
                } label: {
                    Label("复制完整命令", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            Text(plan.shellCommandPreview)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("WINEPREFIX")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(plan.environment["WINEPREFIX"] ?? "-")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("工作目录")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(plan.workingDirectory)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Wine 二进制")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(plan.executablePath) (\(plan.engine.version))")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("落盘日志")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(plan.logFilePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            DisclosureGroup(
                "注入环境变量清单 (\(sortedEnvironmentPairs.count) 项)",
                isExpanded: $isShowingEnvironmentTable
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedEnvironmentPairs, id: \.key) { pair in
                        HStack(alignment: .top, spacing: 8) {
                            Text(pair.key)
                                .font(.caption.monospaced().weight(.semibold))
                                .frame(width: 175, alignment: .leading)
                            Text(pair.value)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption.weight(.medium))
        }
    }
}
#endif
