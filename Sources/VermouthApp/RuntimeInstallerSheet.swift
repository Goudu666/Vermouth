#if os(macOS)
import SwiftUI
import VermouthCore

/// 运行库可视化安装器（PRD §4.2）：勾选常用 winetricks 组件，一键安装到当前容器，进度与输出实时流入「运行日志」。
struct RuntimeInstallerSheet: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    private var orderedSelection: [String] {
        WinetricksCatalog.verbs.map(\.id).filter { selection.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if viewModel.winetricksPath == nil {
                missingWinetricksBanner
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(WinetricksVerb.Category.allCases, id: \.self) { category in
                        let verbs = WinetricksCatalog.verbs.filter { $0.category == category }
                        if !verbs.isEmpty {
                            categorySection(category, verbs: verbs)
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .onAppear {
            selection = viewModel.runtimeInstallerPreselection
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.title)
                .foregroundStyle(VermouthTheme.liquidGradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("运行库安装器")
                    .font(.title3.weight(.bold))
                Text("为「\(bottle.name)」安装常见 Windows 组件，使用与启动程序完全相同的容器环境。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("推荐组合") {
                selection = Set(WinetricksCatalog.recommendedIDs)
            }
            .controlSize(.small)
            .help("VC++ 2015–2022、D3DX9、D3DCompiler 47、核心字体")
        }
        .padding(20)
    }

    private var missingWinetricksBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("未检测到 winetricks")
                    .font(.subheadline.weight(.semibold))
                Text("在终端执行 brew install winetricks 后，点「重新检测」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("复制命令") {
                viewModel.copyToClipboard("brew install winetricks", label: "安装命令")
            }
            .controlSize(.small)
            Button("重新检测") {
                Task {
                    await viewModel.refreshPreflight(autoPresentIfNotReady: false)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.08))
    }

    private func categorySection(_ category: WinetricksVerb.Category, verbs: [WinetricksVerb]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.displayName)
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(verbs) { verb in
                    verbCard(verb)
                }
            }
        }
    }

    private func verbCard(_ verb: WinetricksVerb) -> some View {
        let isSelected = selection.contains(verb.id)
        return Button {
            if isSelected {
                selection.remove(verb.id)
            } else {
                selection.insert(verb.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? VermouthTheme.burgundy : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verb.title)
                            .font(.subheadline.weight(.semibold))
                        if verb.isRecommended {
                            PillBadge(text: "推荐", tint: VermouthTheme.amber)
                        }
                    }
                    Text(verb.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verb.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? VermouthTheme.burgundy.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? VermouthTheme.burgundy.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !orderedSelection.isEmpty {
                Text("winetricks -q \(orderedSelection.joined(separator: " "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("请选择至少一个组件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button {
                let verbs = orderedSelection
                dismiss()
                Task {
                    await viewModel.installRuntimes(verbs, in: bottle)
                }
            } label: {
                Label("安装 \(orderedSelection.count) 个组件", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(VermouthTheme.burgundy)
            .keyboardShortcut(.defaultAction)
            .disabled(orderedSelection.isEmpty || viewModel.winetricksPath == nil || viewModel.isRunningProcess)
        }
        .padding(16)
    }
}
#endif
