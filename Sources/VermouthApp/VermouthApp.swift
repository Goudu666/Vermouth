#if os(macOS)
import AppKit
import SwiftUI
import VermouthCore

@main
struct VermouthApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("Vermouth") {
            MainWorkspaceView(viewModel: viewModel)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建容器…") {
                    viewModel.openCreateBottleSheet(mode: .createNew)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("导入已有 WINEPREFIX…") {
                    viewModel.openCreateBottleSheet(mode: .importExisting)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandMenu("转译环境") {
                Button("检查转译环境 (Preflight)…") {
                    viewModel.isShowingPreflightSheet = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("管理 Wine 引擎…") {
                    viewModel.openEngineSettings(tab: .engines)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("管理图形转译层库 (DXMT / DXVK)…") {
                    viewModel.openEngineSettings(tab: .graphics)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("在 Finder 中打开 Vermouth 数据目录") {
                    try? viewModel.paths.ensureBaseDirectories()
                    _ = NSWorkspace.shared.open(viewModel.paths.baseDirectory)
                }
            }
        }
    }
}

struct MainWorkspaceView: View {
    @Bindable var viewModel: AppViewModel

    @State private var sidebarSearchText: String = ""
    @State private var bottleToRename: Bottle?
    @State private var bottleToClone: Bottle?
    @State private var bottleToDelete: Bottle?

    private var filteredBottles: [Bottle] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return viewModel.bottles
        }
        return viewModel.bottles.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.config.graphicsBackend.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            detailContent
        }
        .searchable(text: $sidebarSearchText, placement: .sidebar, prompt: "筛选容器…")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.openCreateBottleSheet(mode: .createNew)
                } label: {
                    Label("新建容器", systemImage: "plus")
                }
                .help("新建 Windows 容器 (⌘N)")

                Button {
                    viewModel.openEngineSettings(tab: .graphics)
                } label: {
                    Label("引擎与图形库", systemImage: "square.stack.3d.down.right")
                }
                .help("管理 Wine 引擎与 DXMT / DXVK-macOS 版本库")
            }
        }
        .task {
            await viewModel.bootstrap()
        }
        .onChange(of: viewModel.selectedBottleID) { _, _ in
            Task {
                await viewModel.handleSelectedBottleChanged()
            }
        }
        .sheet(isPresented: $viewModel.isShowingPreflightSheet) {
            PreflightSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingEngineSettings) {
            EngineSettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingCreateBottleSheet) {
            CreateBottleSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingSnapshotSheet) {
            SnapshotSheet(viewModel: viewModel)
        }
        .sheet(item: $bottleToRename) { bottle in
            BottleNamePromptSheet(
                title: "重命名容器",
                subtitle: "修改容器显示名称（不影响内部 WINEPREFIX 路径与已安装软件）。",
                actionTitle: "保存名称",
                initialName: bottle.name
            ) { newName in
                viewModel.renameBottle(bottle, newName: newName)
            }
        }
        .sheet(item: $bottleToClone) { bottle in
            BottleNamePromptSheet(
                title: "克隆容器「\(bottle.name)」",
                subtitle: "利用 APFS 写时复制快速创建一份完整独立的容器副本，并自动重写快捷启动路径。",
                actionTitle: "开始克隆",
                initialName: "\(bottle.name) 副本"
            ) { newName in
                Task {
                    await viewModel.cloneBottle(bottle, newName: newName)
                }
            }
        }
        .confirmationDialog(
            "确认删除容器？",
            isPresented: Binding(
                get: { bottleToDelete != nil },
                set: { if !$0 { bottleToDelete = nil } }
            ),
            presenting: bottleToDelete
        ) { bottle in
            if bottle.isExternalPrefix {
                Button("仅移除 Vermouth 容器登记（保留原外部目录）", role: .destructive) {
                    Task {
                        await viewModel.deleteBottle(bottle, removePrefixFiles: false)
                    }
                    bottleToDelete = nil
                }
            } else {
                Button("彻底删除容器与内部 WINEPREFIX 文件", role: .destructive) {
                    Task {
                        await viewModel.deleteBottle(bottle, removePrefixFiles: true)
                    }
                    bottleToDelete = nil
                }
                Button("仅移除配置与快照，保留 prefix 目录") {
                    Task {
                        await viewModel.deleteBottle(bottle, removePrefixFiles: false)
                    }
                    bottleToDelete = nil
                }
            }
            Button("取消", role: .cancel) {
                bottleToDelete = nil
            }
        } message: { bottle in
            if bottle.isExternalPrefix {
                Text(
                    "「\(bottle.name)」采用外部引用模式（\(bottle.prefixPath)）。遵循 L-005 数据保护约束，删除操作仅移除 Vermouth 侧元数据，绝不会删除外部原始 WINEPREFIX。"
                )
            } else {
                Text("删除「\(bottle.name)」将清理该容器下的文件，此操作不可撤销。")
            }
        }
        .alert(
            "操作未能完成",
            isPresented: Binding(
                get: { viewModel.errorAlertMessage != nil },
                set: { if !$0 { viewModel.errorAlertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                viewModel.errorAlertMessage = nil
            }
        } message: {
            Text(viewModel.errorAlertMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(selection: $viewModel.selectedBottleID) {
            Section {
                if filteredBottles.isEmpty {
                    Text(viewModel.bottles.isEmpty ? "尚未创建任何容器" : "无匹配容器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(filteredBottles) { bottle in
                        sidebarBottleRow(bottle)
                            .tag(bottle.id)
                            .contextMenu {
                                bottleContextMenu(for: bottle)
                            }
                    }
                }
            } header: {
                HStack {
                    Text("容器列表 (\(viewModel.bottles.count))")
                    Spacer()
                    Menu {
                        Button("新建空白容器…") {
                            viewModel.openCreateBottleSheet(mode: .createNew)
                        }
                        Button("导入已有 WINEPREFIX…") {
                            viewModel.openCreateBottleSheet(mode: .importExisting)
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            engineReadinessFooter
        }
    }

    private func sidebarBottleRow(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: bottle.isExternalPrefix ? "externaldrive.badge.icloud" : "wineglass.fill")
                    .foregroundStyle(bottle.isExternalPrefix ? Color.orange : VermouthTheme.amber)
                Text(bottle.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 4) {
                PillBadge(text: bottle.config.windowsVersion.shortBadgeTitle, tint: .secondary)
                PillBadge(
                    text: bottle.config.graphicsBackend.displayName,
                    tint: bottle.config.graphicsBackend.badgeTint
                )
                if bottle.isExternalPrefix {
                    PillBadge(text: "外部", tint: .orange)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func bottleContextMenu(for bottle: Bottle) -> some View {
        Button {
            bottleToRename = bottle
        } label: {
            Label("重命名容器…", systemImage: "pencil")
        }

        Button {
            bottleToClone = bottle
        } label: {
            Label("克隆容器…", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            viewModel.openDriveC(for: bottle)
        } label: {
            Label("打开 drive_c 目录", systemImage: "folder")
        }

        Button {
            viewModel.revealBottleInFinder(bottle)
        } label: {
            Label("在 Finder 中显示容器配置", systemImage: "magnifyingglass")
        }

        Button {
            viewModel.openPreInjectedTerminal(for: bottle)
        } label: {
            Label("打开预注入环境变量终端", systemImage: "apple.terminal")
        }

        Button {
            Task {
                await viewModel.killWineServer(for: bottle, force: false)
            }
        } label: {
            Label("终止残留进程 (wineserver -k)", systemImage: "stop.circle")
        }

        Divider()

        Button(role: .destructive) {
            bottleToDelete = bottle
        } label: {
            Label("删除容器…", systemImage: "trash")
        }
    }

    // MARK: - Bottom Engine Readiness Strip

    private var engineReadinessFooter: some View {
        let isReady = viewModel.preflightReport?.isReadyToLaunch == true
        let dotColor: Color = {
            if viewModel.isPerformingPreflight { return .orange }
            if viewModel.preflightReport == nil { return .secondary }
            return isReady ? .green : .red
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                if let engine = viewModel.activeDefaultEngine {
                    Text(engine.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text("未配置 Wine 引擎")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                if let report = viewModel.preflightReport {
                    Text(report.rosetta2Ready ? "Rosetta 2 就绪" : "缺少 Rosetta 2")
                        .font(.caption2)
                        .foregroundStyle(report.rosetta2Ready ? Color.secondary : Color.red)
                }

                Spacer()

                Button {
                    viewModel.isShowingPreflightSheet = true
                } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.borderless)
                .help("查看转译环境就绪预检")

                Button {
                    viewModel.openEngineSettings(tab: .engines)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("管理 Wine 引擎与 DXMT/DXVK 版本库")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Detail Workspace

    private var detailContent: some View {
        VStack(spacing: 0) {
            topStatusNotificationBar

            if let bottle = viewModel.selectedBottle {
                workspaceSectionHeader(for: bottle)
                Divider()

                Group {
                    switch viewModel.selectedTab {
                    case .programs:
                        BottleDetailView(viewModel: viewModel, bottle: bottle)
                    case .configuration:
                        BottleConfigView(viewModel: viewModel, bottle: bottle)
                    case .console:
                        ConsoleLogView(viewModel: viewModel, bottle: bottle)
                    case .advanced:
                        AdvancedOverridesView(viewModel: viewModel, bottle: bottle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyWorkspacePlaceholder
            }
        }
    }

    @ViewBuilder
    private var topStatusNotificationBar: some View {
        if viewModel.isBusyWithBottleOperation, let busyText = viewModel.busyStatusText {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(busyText)
                    .font(.caption.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))
            Divider()
        } else if let banner = viewModel.statusBannerMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(banner)
                    .font(.caption.weight(.medium))
                Spacer()
                Button {
                    viewModel.statusBannerMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.green.opacity(0.1))
            Divider()
        }
    }

    private func workspaceSectionHeader(for bottle: Bottle) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "wineglass.fill")
                    .font(.title3)
                    .foregroundStyle(VermouthTheme.liquidGradient)

                Text(bottle.name)
                    .font(.title3.weight(.bold))

                PillBadge(
                    text: bottle.config.graphicsBackend.displayName,
                    systemImage: bottle.config.graphicsBackend.systemImage,
                    tint: bottle.config.graphicsBackend.badgeTint
                )

                PillBadge(text: bottle.config.windowsVersion.displayName, tint: .secondary)
                PillBadge(text: bottle.config.syncMode.shortLabel, tint: .indigo)

                if bottle.config.display.metalHUD {
                    PillBadge(text: "Metal HUD", systemImage: "speedometer", tint: .pink)
                }

                Spacer()

                if !viewModel.diagnosticFindings.isEmpty {
                    Button {
                        viewModel.selectedTab = .console
                    } label: {
                        PillBadge(
                            text: "\(viewModel.diagnosticFindings.count) 条诊断建议",
                            systemImage: "stethoscope",
                            tint: .orange
                        )
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.isRunningProcess {
                    Button {
                        viewModel.selectedTab = .console
                    } label: {
                        PillBadge(text: "子进程运行中", systemImage: "waveform.path.ecg", tint: .green)
                    }
                    .buttonStyle(.plain)
                }
            }

            TranslationPipelineView(
                stages: TranslationPipeline.stages(
                    backend: bottle.config.graphicsBackend,
                    engine: viewModel.resolvedEngine(for: bottle),
                    rosettaReady: viewModel.preflightReport?.rosetta2Ready
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("工作区", selection: $viewModel.selectedTab) {
                ForEach(WorkspaceSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var emptyWorkspacePlaceholder: some View {
        let hasEngine = viewModel.activeDefaultEngine != nil
        let rosettaReady = viewModel.preflightReport?.rosetta2Ready == true
        return VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: VermouthTheme.burgundy.opacity(0.35), radius: 18, y: 8)

            VStack(spacing: 8) {
                Text("欢迎使用 Vermouth")
                    .font(.largeTitle.weight(.bold))
                Text("把 Windows 游戏和软件，倒进你的 Apple Silicon Mac。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            TranslationPipelineView(
                stages: TranslationPipeline.stages(
                    backend: .dxmt,
                    engine: viewModel.activeDefaultEngine,
                    rosettaReady: viewModel.preflightReport?.rosetta2Ready
                )
            )
            .frame(maxWidth: 640)

            VStack(alignment: .leading, spacing: 10) {
                onboardingStep(
                    index: 1,
                    title: "检查转译环境",
                    detail: rosettaReady ? "Rosetta 2 已就绪" : "确认 Rosetta 2 与 Homebrew",
                    isDone: rosettaReady
                ) {
                    viewModel.isShowingPreflightSheet = true
                }
                onboardingStep(
                    index: 2,
                    title: "选择 Wine 引擎",
                    detail: viewModel.activeDefaultEngine?.name ?? "推荐 brew install --cask gcenx/wine/wine-stable",
                    isDone: hasEngine
                ) {
                    viewModel.openEngineSettings(tab: .engines)
                }
                onboardingStep(
                    index: 3,
                    title: "新建第一个容器",
                    detail: "或导入已有的 WINEPREFIX",
                    isDone: !viewModel.bottles.isEmpty
                ) {
                    viewModel.openCreateBottleSheet(mode: .createNew)
                }
            }
            .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func onboardingStep(
        index: Int,
        title: String,
        detail: String,
        isDone: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isDone ? AnyShapeStyle(Color.green) : AnyShapeStyle(VermouthTheme.brandGradient))
                        .frame(width: 30, height: 30)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(index)")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Name Prompt Sheet (Rename / Clone)

private struct BottleNamePromptSheet: View {
    let title: String
    let subtitle: String
    let actionTitle: String
    let initialName: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("容器名称", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    confirmIfValid()
                }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(actionTitle) {
                    confirmIfValid()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            nameText = initialName
        }
    }

    private func confirmIfValid() {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}
#endif
