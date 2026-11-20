#if os(macOS)
import AppKit
import SwiftUI
import VermouthCore

struct PreflightSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let report = viewModel.preflightReport {
                        readinessSummaryBanner(report)
                        checklistSection(report)
                        discoveredEnginesSection()
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在执行系统与转译环境只读预检…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                    }
                }
                .padding(20)
            }

            Divider()
            footerSection
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 540, idealHeight: 600)
        .task {
            if viewModel.preflightReport == nil {
                await viewModel.refreshPreflight(autoPresentIfNotReady: false)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist.checked")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("转译环境就绪预检")
                    .font(.headline)
                Text("Vermouth 仅执行只读环境探测，绝不静默修改系统环境；缺失组件可一键复制命令安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isPerformingPreflight {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Summary Banner

    private func readinessSummaryBanner(_ report: PreflightReport) -> some View {
        let tint: Color = report.isReadyToLaunch ? .green : .orange
        let icon = report.isReadyToLaunch ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        let title = report.isReadyToLaunch
            ? "核心转译环境已就绪，可直接创建容器并启动 Windows 程序"
            : "存在待补充的前置组件，请参考下方引导完成安装或登记本地 Wine 引擎"

        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(
                    "检测时间：\(VermouthFormatters.formatDateTime(report.checkedAt)) · \(report.osVersion.displayString) (\(report.architecture.rawValue))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - Checklist Items

    private func checklistSection(_ report: PreflightReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("环境检查清单")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(report.items) { item in
                    checkItemCard(item)
                }
            }
        }
    }

    private func checkItemCard(_ item: PreflightCheckItem) -> some View {
        let (iconName, tintColor): (String, Color) = {
            switch item.status {
            case .pass:
                return ("checkmark.circle.fill", .green)
            case .warning:
                return ("exclamationmark.triangle.fill", .orange)
            case .fail:
                return ("xmark.octagon.fill", .red)
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tintColor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if let command = item.remediationCommand, !command.isEmpty {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))

                    Button {
                        viewModel.copyToClipboard(command, label: "引导命令")
                    } label: {
                        Label("复制命令", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 26)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Discovered Wine Engines

    private func discoveredEnginesSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已发现的 Wine 引擎 (\(viewModel.engines.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        await viewModel.promptAndRegisterCustomEngine()
                    }
                } label: {
                    Label("登记自定义 Wine 目录…", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
            }

            if viewModel.engines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("尚未在本机探测到任何 Wine 引擎。")
                        .font(.callout.weight(.medium))
                    Text("推荐使用上方命令通过 Homebrew 安装 `gcenx/wine/wine-stable`（同时支持 32 位与 64 位的新 WoW64 引擎），或点击右上角按钮选择已安装的 Wine.app / CrossOver.app。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.engines) { engine in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(engine.name)
                                    .font(.subheadline.weight(.semibold))
                                if viewModel.activeDefaultEngine?.id == engine.id {
                                    PillBadge(text: "默认引擎", systemImage: "star.fill", tint: .accentColor)
                                }
                                PillBadge(text: engine.source.displayName, tint: .secondary)
                                Spacer()
                                if engine.isQuarantined {
                                    Button {
                                        Task {
                                            await viewModel.removeQuarantineForEngine(engine)
                                        }
                                    } label: {
                                        Label("一键解除隔离", systemImage: "lock.open.fill")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                }
                            }

                            Text("\(engine.rootPath) · \(engine.version)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            EngineCapabilityPills(engine: engine)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    engine.isQuarantined ? Color.orange.opacity(0.45) : Color.secondary.opacity(0.16),
                                    lineWidth: 1
                                )
                        )
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await viewModel.refreshPreflight(autoPresentIfNotReady: false)
                }
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isPerformingPreflight)

            Button("管理引擎与图形层库…") {
                dismiss()
                viewModel.openEngineSettings(tab: .engines)
            }

            Spacer()

            Button("完成") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
#endif
