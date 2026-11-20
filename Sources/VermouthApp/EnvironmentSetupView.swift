#if os(macOS)
import AppKit
import SwiftUI
import VermouthCore

/// 「准备运行环境」：把 Rosetta / Homebrew / Wine / 隔离属性这些概念翻译成一个按钮。
/// `.card` 嵌在程序库顶部；`.sheet` 用于菜单和启动时缺环境的弹窗。
struct EnvironmentSetupPanel: View {
    enum Style {
        case card
        case sheet
    }

    @Bindable var viewModel: AppViewModel
    let style: Style

    private var steps: [SetupStep] {
        style == .card ? viewModel.requiredSetupSteps : viewModel.setupSteps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: viewModel.isEnvironmentReady ? "checkmark.seal.fill" : "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        viewModel.isEnvironmentReady ? AnyShapeStyle(Color.green) : AnyShapeStyle(VermouthTheme.brandGradient),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.isEnvironmentReady ? "运行环境已就绪" : "还差一步，就能运行 Windows 程序")
                        .font(.title3.weight(.semibold))
                    Text(
                        viewModel.isEnvironmentReady
                            ? "可以直接添加和启动程序了。下面是可选的增强组件。"
                            : "点一下「一键准备」，Vermouth 会在「终端」里帮你装好需要的组件。过程中可能要输入开机密码，装完回到这里会自动刷新。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(step, index: index + 1)
                    }
                }
                .padding(.leading, 58)
            }

            HStack(spacing: 10) {
                if !steps.isEmpty {
                    Button {
                        Task { await viewModel.runEnvironmentSetup() }
                    } label: {
                        Label(viewModel.isEnvironmentReady ? "安装可选组件" : "一键准备", systemImage: "bolt.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VermouthTheme.burgundy)
                    .controlSize(.large)
                }

                Button {
                    Task { await viewModel.refreshPreflight() }
                } label: {
                    if viewModel.isPerformingPreflight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("重新检测")
                    }
                }
                .controlSize(.large)
                .disabled(viewModel.isPerformingPreflight)

                Spacer()

                Menu("已经装过 Wine？") {
                    Button("选择 Wine / CrossOver 所在位置…") {
                        Task { await viewModel.promptAndRegisterCustomEngine() }
                    }
                    Button("复制安装命令") {
                        viewModel.copyToClipboard(EngineManager.recommendedWineInstallCommand, label: "Wine 安装命令")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 58)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(VermouthTheme.amber.opacity(viewModel.isEnvironmentReady ? 0 : 0.45), lineWidth: 1)
        }
    }

    private func stepRow(_ step: SetupStep, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.kind.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(step.isRequired ? VermouthTheme.amber : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.callout.weight(.semibold))
                    if !step.isRequired {
                        PillBadge(text: "可选", tint: .secondary)
                    }
                }
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SetupStep.Kind {
    var systemImage: String {
        switch self {
        case .rosetta: "cpu"
        case .homebrew: "mug"
        case .wineEngine: "wineglass"
        case .unquarantineEngine: "lock.open"
        case .winetricks: "shippingbox"
        }
    }
}

/// 弹窗版：菜单「运行环境…」或启动时发现缺环境。
struct EnvironmentSetupSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EnvironmentSetupPanel(viewModel: viewModel, style: .sheet)

            HStack {
                Button("查看详细检查结果…") {
                    dismiss()
                    // 等这个弹窗收起再弹下一个，macOS 不能同时叠两个同级 sheet
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        viewModel.isShowingPreflightSheet = true
                    }
                }
                .buttonStyle(.link)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refreshPreflight() }
        }
    }
}
#endif
