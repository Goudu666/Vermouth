#if os(macOS)
import AppKit
import SwiftUI
import VermouthCore

// MARK: - Program Detail

/// 单个程序的详情页：大号启动按钮、出问题时的白话解释与一键修复、常用工具；
/// 转译链路、启动命令和实时日志都折叠在「技术详情」里，需要时再展开。
struct ProgramDetailSheet: View {
    @Bindable var viewModel: AppViewModel
    let itemID: UUID

    @AppStorage(AppViewModel.advancedModeDefaultsKey) private var isAdvancedMode = false
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingName = false
    @State private var nameDraft = ""
    @State private var isShowingTechnicalDetails = false
    @State private var isShowingRuntimeInstaller = false

    private var item: LibraryItem? { viewModel.libraryItem(id: itemID) }

    var body: some View {
        Group {
            if let item, let bottle = viewModel.bottle(id: item.bottleID) {
                content(item: item, bottle: bottle)
            } else {
                ContentUnavailableView("程序已被移除", systemImage: "questionmark.app")
                    .frame(width: 560, height: 320)
            }
        }
        .sheet(isPresented: $isShowingRuntimeInstaller) {
            if let item, let bottle = viewModel.bottle(id: item.bottleID) {
                RuntimeInstallerSheet(viewModel: viewModel, bottle: bottle)
            }
        }
    }

    private func content(item: LibraryItem, bottle: Bottle) -> some View {
        VStack(spacing: 0) {
            hero(item: item, bottle: bottle)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !viewModel.isEnvironmentReady {
                        EnvironmentSetupPanel(viewModel: viewModel, style: .card)
                    }

                    if let report = viewModel.lastLaunchReport, report.appID == item.id {
                        ProblemAssistantSection(
                            viewModel: viewModel,
                            report: report,
                            onInstallRuntime: { verb in openRuntimeInstaller(preselecting: [verb], bottle: bottle) }
                        )
                    }

                    toolsSection(item: item, bottle: bottle)
                    technicalSection(item: item, bottle: bottle)
                }
                .padding(22)
            }
            Divider()
            footer(item: item)
        }
        .frame(width: 680, height: 660)
        .onAppear {
            viewModel.selectedBottleID = bottle.id
        }
    }

    // MARK: Hero

    private func hero(item: LibraryItem, bottle: Bottle) -> some View {
        let hue = VermouthTheme.stableHue(for: item.app.name)
        let isThis = viewModel.launchActivity.appID == item.id
        return HStack(alignment: .center, spacing: 20) {
            ProgramIconView(
                hostPath: viewModel.hostPath(for: item),
                name: item.app.name,
                cache: viewModel.iconCache,
                size: 96
            )
            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 8) {
                if isEditingName {
                    TextField("程序名称", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.weight(.bold))
                        .onSubmit { commitName(item) }
                } else {
                    HStack(spacing: 8) {
                        Text(item.app.name)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Button {
                            nameDraft = item.app.name
                            isEditingName = true
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.borderless)
                        .help("重命名")
                    }
                }

                Text(lastRunText(item))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 10) {
                    if isThis, case .running = viewModel.launchActivity {
                        Button {
                            Task { await viewModel.stopProgram(in: item.bottleID) }
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                                .frame(minWidth: 96)
                        }
                        .controlSize(.large)
                    } else {
                        Button {
                            Task { await viewModel.quickLaunch(item) }
                        } label: {
                            if isThis {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("正在准备…")
                                }
                                .frame(minWidth: 96)
                            } else {
                                Label("启动", systemImage: "play.fill")
                                    .frame(minWidth: 96)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(VermouthTheme.amber)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.launchActivity.isActive || !viewModel.isEnvironmentReady)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.5, brightness: 0.45),
                    VermouthTheme.berry,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func lastRunText(_ item: LibraryItem) -> String {
        if case let .preparing(appID, message) = viewModel.launchActivity, appID == item.id {
            return message
        }
        if case let .running(appID, _) = viewModel.launchActivity, appID == item.id {
            return "正在运行"
        }
        if let last = item.app.lastLaunchedAt {
            return "上次运行 \(last.formatted(.relative(presentation: .named)))"
        }
        return "还没运行过 · 点「启动」试试"
    }

    private func commitName(_ item: LibraryItem) {
        viewModel.renameLibraryItem(item, to: nameDraft)
        isEditingName = false
    }

    // MARK: Tools

    private func toolsSection(item: LibraryItem, bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("常用修复")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                toolButton(
                    title: "安装运行库",
                    detail: "提示缺少 VC++、DirectX、.NET 时",
                    systemImage: "shippingbox"
                ) {
                    openRuntimeInstaller(preselecting: [], bottle: bottle)
                }
                toolButton(
                    title: "修复中文显示",
                    detail: "界面出现方块字或乱码时",
                    systemImage: "character.book.closed"
                ) {
                    Task { await viewModel.applyChineseEnvironmentFix(for: bottle) }
                }
                toolButton(
                    title: "强制结束",
                    detail: "程序卡住、无法退出时",
                    systemImage: "xmark.octagon"
                ) {
                    Task { await viewModel.stopProgram(in: bottle.id) }
                }
                toolButton(
                    title: "Windows 设置",
                    detail: "分辨率、声音等系统选项",
                    systemImage: "gearshape.2"
                ) {
                    Task { await viewModel.launchBuiltinTool(.winecfg, for: bottle) }
                }
            }
        }
    }

    private func toolButton(
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(VermouthTheme.amber)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isEnvironmentReady)
    }

    private func openRuntimeInstaller(preselecting verbs: [String], bottle: Bottle) {
        viewModel.selectedBottleID = bottle.id
        viewModel.runtimeInstallerPreselection = Set(verbs.isEmpty ? WinetricksCatalog.recommendedIDs : verbs)
        isShowingRuntimeInstaller = true
    }

    // MARK: Technical Details

    private func technicalSection(item: LibraryItem, bottle: Bottle) -> some View {
        DisclosureGroup(isExpanded: $isShowingTechnicalDetails) {
            VStack(alignment: .leading, spacing: 14) {
                TranslationPipelineView(
                    stages: TranslationPipeline.stages(
                        backend: bottle.config.graphicsBackend,
                        engine: viewModel.resolvedEngine(for: bottle),
                        rosettaReady: viewModel.preflightReport?.rosetta2Ready
                    )
                )

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("程序位置").foregroundStyle(.secondary)
                        Text(viewModel.hostPath(for: item))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    GridRow {
                        Text("Windows 环境").foregroundStyle(.secondary)
                        Text("\(bottle.name) · \(bottle.config.windowsVersion.displayName) · \(bottle.config.graphicsBackend.displayName)")
                    }
                    GridRow {
                        Text("Wine 引擎").foregroundStyle(.secondary)
                        Text(viewModel.resolvedEngine(for: bottle)?.name ?? "未找到")
                    }
                }
                .font(.caption)

                VStack(alignment: .leading, spacing: 6) {
                    Text("实时日志")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ConsoleLogView(viewModel: viewModel, bottle: bottle)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        }
                }

                Button {
                    dismiss()
                    isAdvancedMode = true
                } label: {
                    Label("在高级模式中打开这个环境", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.link)
            }
            .padding(.top, 10)
        } label: {
            Label("技术详情（转译链路、日志）", systemImage: "wrench.and.screwdriver")
                .font(.headline)
        }
    }

    // MARK: Footer

    private func footer(item: LibraryItem) -> some View {
        HStack {
            Button {
                viewModel.revealInFinder(item)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            Button(role: .destructive) {
                viewModel.removeFromLibrary(item)
                dismiss()
            } label: {
                Label("从程序库移除", systemImage: "minus.circle")
            }
            Spacer()
            Button("完成") {
                if isEditingName { commitName(item) }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

// MARK: - Problem Assistant

/// 运行出问题后的白话解释：一句结论 + 每个原因的一键修复。
struct ProblemAssistantSection: View {
    @Bindable var viewModel: AppViewModel
    let report: LaunchReport
    let onInstallRuntime: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(report.outcome.headline(programName: report.programName))
                    .font(.headline)
                Spacer()
                Button("忽略") {
                    viewModel.lastLaunchReport = nil
                }
                .buttonStyle(.borderless)
            }

            if report.findings.isEmpty {
                Text("暂时没有找到明确原因。可以先试试「安装运行库」，或展开下面的「技术详情」看看日志。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.findings) { finding in
                    DiagnosticFindingCard(
                        finding: finding,
                        onQuickFix: { fix in
                            Task { await viewModel.quickFix(fix, findingID: finding.id, bottleID: report.bottleID) }
                        },
                        onInstallRuntime: onInstallRuntime
                    )
                }
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }
}

/// 没有对应卡片的任务（如安装程序）出问题时单独弹出。
struct ProblemAssistantSheet: View {
    @Bindable var viewModel: AppViewModel
    let report: LaunchReport
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingRuntimeInstaller = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                ProblemAssistantSection(
                    viewModel: viewModel,
                    report: viewModel.lastLaunchReport ?? report,
                    onInstallRuntime: { verb in
                        viewModel.selectedBottleID = report.bottleID
                        viewModel.runtimeInstallerPreselection = [verb]
                        isShowingRuntimeInstaller = true
                    }
                )
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 460)
        .sheet(isPresented: $isShowingRuntimeInstaller) {
            if let bottle = viewModel.bottle(id: report.bottleID) {
                RuntimeInstallerSheet(viewModel: viewModel, bottle: bottle)
            }
        }
    }
}

// MARK: - Installed Programs Browser

/// 「查找已安装的程序」：列出默认环境里还没加入程序库的程序。
struct InstalledProgramsSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("已安装的程序")
                    .font(.title2.weight(.bold))
                Text("这些程序已经装在 Windows 环境里，点「添加」就会出现在程序库。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let bottle = viewModel.selectedBottle {
                let candidates = viewModel.discoveredExecutables.filter {
                    !viewModel.isDiscoveredExecutablePinned($0, in: bottle)
                }
                if viewModel.isScanningExecutables {
                    ProgressView("正在查找…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "没有找到新的程序",
                        systemImage: "tray",
                        description: Text("先用安装包安装软件，或者直接把 .exe 拖进程序库。")
                    )
                    .frame(minHeight: 220)
                } else {
                    List(candidates) { exec in
                        HStack(spacing: 12) {
                            ProgramIconView(hostPath: exec.executablePath, name: exec.name, cache: viewModel.iconCache, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exec.name)
                                    .font(.callout.weight(.semibold))
                                Text(URL(fileURLWithPath: exec.executablePath).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("添加") {
                                viewModel.pinDiscoveredExecutable(exec, in: bottle)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(minHeight: 260)
                }
            }

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
#endif
