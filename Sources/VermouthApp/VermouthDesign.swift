#if os(macOS)
import AppKit
import SwiftUI
import VermouthCore

// MARK: - Brand Theme

/// Vermouth 品牌色板（「酒柜」隐喻）：只用在品牌位置，其余界面保持系统中性色。
enum VermouthTheme {
    /// 味美思琥珀
    static var amber: Color { Color(red: 0.93, green: 0.58, blue: 0.20) }
    /// 勃艮第酒红
    static var burgundy: Color { Color(red: 0.48, green: 0.09, blue: 0.20) }
    /// 深莓色（渐变暗部）
    static var berry: Color { Color(red: 0.24, green: 0.04, blue: 0.11) }

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [burgundy, berry],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var liquidGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.0, green: 0.77, blue: 0.36), Color(red: 0.84, green: 0.36, blue: 0.11)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 由名称确定的稳定色相（`String.hashValue` 每次进程启动都会变，不能用）。
    static func stableHue(for name: String) -> Double {
        let sum = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return Double(sum % 360) / 360.0
    }
}

extension WineLogLevel {
    var tint: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .fixme: .secondary
        case .trace: Color.secondary.opacity(0.7)
        case .info: .primary
        }
    }

    var badge: String {
        switch self {
        case .error: "ERR"
        case .warning: "WARN"
        case .fixme: "FIXME"
        case .trace: "TRACE"
        case .info: "INFO"
        }
    }
}

extension TranslationStage.Kind {
    var tint: Color {
        switch self {
        case .windowsProgram: .cyan
        case .instructionTranslation: .indigo
        case .wine: VermouthTheme.burgundy
        case .graphicsTranslation: .purple
        case .intermediateAPI: .teal
        case .metal: VermouthTheme.amber
        }
    }

    var systemImage: String {
        switch self {
        case .windowsProgram: "macwindow"
        case .instructionTranslation: "arrow.triangle.2.circlepath"
        case .wine: "wineglass"
        case .graphicsTranslation: "cube.transparent"
        case .intermediateAPI: "square.stack.3d.up"
        case .metal: "cpu"
        }
    }
}

// MARK: - Program Icons

/// 首字母占位图标：在程序没有图标资源或尚未加载时使用，颜色由名称稳定生成。
struct MonogramTile: View {
    let name: String
    var size: CGFloat = 56

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        let hue = VermouthTheme.stableHue(for: name)
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.85),
                        Color(hue: hue, saturation: 0.75, brightness: 0.55),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
    }
}

/// 显示 Windows 程序的真实图标（Clean-Room 从 PE 资源段提取，磁盘缓存），失败时回退到首字母图标。
struct ProgramIconView: View {
    let hostPath: String
    let name: String
    let cache: ProgramIconCache
    var size: CGFloat = 56

    @State private var icon: NSImage?

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            } else {
                MonogramTile(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: hostPath) {
            let path = hostPath
            let iconCache = cache
            let data = await Task.detached(priority: .utility) {
                iconCache.icoData(forExecutableAt: path)
            }.value
            icon = data.flatMap { NSImage(data: $0) }
        }
    }
}

// MARK: - Program Tile

/// 程序卡片墙中的单个大卡片：图标、名称、标签，悬停浮起并突出「启动」按钮。
struct ProgramTile<MenuContent: View>: View {
    let name: String
    let subtitle: String
    let hostPath: String
    let cache: ProgramIconCache
    var badges: [(text: String, tint: Color)] = []
    var isSelected: Bool = false
    var isLaunchDisabled: Bool = false
    let onLaunch: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            ProgramIconView(hostPath: hostPath, name: name, cache: cache, size: 64)
                .scaleEffect(isHovering ? 1.06 : 1.0)
                .padding(.top, 6)

            VStack(spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)

            if !badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                        PillBadge(text: badge.text, tint: badge.tint)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button(action: onLaunch) {
                    Label("启动", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(VermouthTheme.burgundy)
                .controlSize(.regular)
                .disabled(isLaunchDisabled)

                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
                .help("更多操作")
            }
        }
        .padding(14)
        .frame(minHeight: 210)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovering ? 0.16 : 0.06), radius: isHovering ? 10 : 4, y: isHovering ? 5 : 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? VermouthTheme.amber : Color.secondary.opacity(isHovering ? 0.3 : 0.15),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            menu()
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Translation Pipeline

/// 「转译链路」可视化：`64 位程序 → Rosetta 2 → Wine 11.0 → DXMT → Metal`。
/// 产品最独特的卖点（转译栈透明）一眼可见；未就绪的环节以橙色警示。
struct TranslationPipelineView: View {
    let stages: [TranslationStage]
    var showsDetail: Bool = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    stageChip(stage)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func stageChip(_ stage: TranslationStage) -> some View {
        let tint = stage.isReady ? stage.kind.tint : Color.orange
        return HStack(spacing: 6) {
            Image(systemName: stage.isReady ? stage.kind.systemImage : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(stage.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if showsDetail {
                    Text(stage.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .help("\(stage.title)：\(stage.detail)")
    }
}
#endif
