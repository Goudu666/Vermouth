#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VermouthCore

struct BottleDetailView: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle

    @State private var isDropTargeted = false
    @State private var discoveredSearchText = ""
    @State private var editingAppEntry: AppEntry?
    @State private var inspectedAppPlan: LaunchPlan?
    @State private var inspectedAppID: UUID?
    @State private var isLoadingAppPlan = false
    @State private var isShowingExportRecipeSheet = false

    private var filteredDiscoveredExecutables: [DiscoveredExecutable] {
        let query = discoveredSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return viewModel.discoveredExecutables
        }
        return viewModel.discoveredExecutables.filter { item in
            item.name.localizedCaseInsensitiveContains(query)
                || item.executablePath.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                quickContainerToolbar
                installerDropBanner
                appliedRecipeHintIfPresent
                pinnedProgramsSection
                discoveredProgramsSection
            }
            .padding(20)
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.handleDroppedURLs(urls, in: bottle)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .sheet(item: $editingAppEntry) { entry in
            AppEntryEditorSheet(
                viewModel: viewModel,
                bottle: bottle,
                initialEntry: entry
            )
        }
        .sheet(isPresented: $isShowingExportRecipeSheet) {
            RecipeExportSheet(viewModel: viewModel, bottle: bottle)
        }
    }

    // MARK: - Quick Container Toolbar

    private var quickContainerToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    viewModel.promptAndRunInstaller(for: bottle)
                } label: {
                    Label("运行安装包 (.exe / .msi)…", systemImage: "shippingbox.and.arrow.backward.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.openDriveC(for: bottle)
                } label: {
                    Label("打开 drive_c", systemImage: "folder")
                }

                Menu {
                    Section("推荐兼容配方") {
                        ForEach(viewModel.recipes) { recipe in
                            Button {
                                Task {
                                    await viewModel.applyRecipe(recipe, to: bottle)
                                }
                            } label: {
                                if bottle.appliedRecipeID == recipe.id {
                                    Label("\(recipe.name)（当前已应用）", systemImage: "checkmark")
                                } else {
                                    Text("\(recipe.name) — \(recipe.recommendedBackend.displayName)")
                                }
                            }
                        }
                    }

                    Divider()

                    Button {
                        viewModel.promptAndImportRecipe(applyTo: bottle)
                    } label: {
                        Label("导入并应用外部配方 (.recipe.json)…", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        isShowingExportRecipeSheet = true
                    } label: {
                        Label("导出当前容器配置为脱敏配方…", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("兼容配方", systemImage: "wand.and.stars")
                }

                Spacer()

                Button {
                    viewModel.isShowingSnapshotSheet = true
                } label: {
                    Label("存档与配置快照", systemImage: "clock.arrow.circlepath")
                }
            }

            HStack(spacing: 8) {
                Text("容器工具：")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await viewModel.launchBuiltinTool(.winecfg, for: bottle)
                    }
                } label: {
                    Label("winecfg", systemImage: "gearshape")
                }
                .controlSize(.small)

                Button {
                    Task {
                        await viewModel.launchBuiltinTool(.regedit, for: bottle)
                    }
                } label: {
                    Label("regedit", systemImage: "tablecells")
                }
                .controlSize(.small)

                Button {
                    Task {
                        await viewModel.launchBuiltinTool(.cmd, for: bottle)
                    }
                } label: {
                    Label("cmd", systemImage: "greaterthan.square")
                }
                .controlSize(.small)

                Button {
                    viewModel.openPreInjectedTerminal(for: bottle)
                } label: {
                    Label("终端 (已注入环境)", systemImage: "apple.terminal")
                }
                .controlSize(.small)
                .help("在 macOS 终端打开已注入相同 WINEPREFIX、同步模式与图形层环境变量的交互式 Shell")

                Button {
                    Task {
                        await viewModel.applyChineseEnvironmentFix(for: bottle)
                    }
                } label: {
                    Label(
                        bottle.config.locale.chineseLocalizationEnabled ? "中文环境已开启" : "中文防乱码补全",
                        systemImage: "character.book.closed"
                    )
                }
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    Task {
                        await viewModel.killWineServer(for: bottle, force: false)
                    }
                } label: {
                    Label("终止残留进程 (wineserver -k)", systemImage: "stop.circle")
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Drag & Drop Zone

    private var installerDropBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "plus.viewfinder")
                .font(.title3)
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isDropTargeted
                        ? "松开鼠标即可在「\(bottle.name)」中运行该程序或应用配方"
                        : "支持直接将 Windows 安装包 (.exe / .msi) 或社区配方 (.recipe.json) 拖入此窗口运行"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .primary)

                Text("安装完成后将自动扫描开始菜单快捷方式与 Program Files 目录并更新下方程序列表。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            (isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05)),
            in: .rect(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: [5, 4])
                )
        )
    }

    @ViewBuilder
    private var appliedRecipeHintIfPresent: some View {
        if let appliedID = bottle.appliedRecipeID,
           let recipe = viewModel.recipes.first(where: { $0.id == appliedID })
        {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.purple)
                    Text("已应用配方：\(recipe.name)")
                        .font(.caption.weight(.semibold))
                    PillBadge(text: recipe.targetArchitecture.displayName, tint: recipe.targetArchitecture.badgeTint)
                    Spacer()
                }
                Text(recipe.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let firstNote = recipe.notes.first {
                    Text("提示：\(firstNote)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.purple.opacity(0.07), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.purple.opacity(0.22), lineWidth: 1)
            )
        }
    }

    // MARK: - Pinned Programs Section

    private var pinnedProgramsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("程序库 (\(bottle.apps.count))", systemImage: "square.grid.2x2.fill")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.promptAndAddManualApp(in: bottle)
                } label: {
                    Label("手动添加 .exe…", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if bottle.apps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("尚未固定任何快捷启动程序")
                        .font(.subheadline.weight(.medium))
                    Text("你可以先运行 `.exe` / `.msi` 安装包，从下方「自动发现的程序」一键固定，或点击右上角「手动添加 .exe…」绑定任意本地免安装程序。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(bottle.apps) { app in
                        pinnedAppTile(app)
                    }
                }

                if let inspectedApp = bottle.apps.first(where: { $0.id == inspectedAppID }) {
                    commandInspectorPanel(for: inspectedApp)
                }
            }
        }
    }

    private func pinnedAppTile(_ app: AppEntry) -> some View {
        var badges: [(text: String, tint: Color)] = []
        if !app.arguments.isEmpty {
            badges.append((text: "参数 \(app.arguments.count)", tint: Color.indigo))
        }
        if !app.dllOverrides.isEmpty {
            badges.append((text: "DLL \(app.dllOverrides.count)", tint: Color.orange))
        }
        if !app.snapshotTargets.isEmpty {
            badges.append((text: "快照", tint: Color.teal))
        }
        let subtitle: String = {
            if let lastLaunched = app.lastLaunchedAt {
                return "上次启动 \(VermouthFormatters.formatDateTime(lastLaunched))"
            }
            return URL(fileURLWithPath: app.executablePath).lastPathComponent
        }()

        return ProgramTile(
            name: app.name,
            subtitle: subtitle,
            hostPath: ProgramIconCache.resolveHostPath(app.executablePath, prefixPath: bottle.prefixPath),
            cache: viewModel.iconCache,
            badges: badges,
            isSelected: inspectedAppID == app.id,
            isLaunchDisabled: viewModel.isRunningProcess,
            onLaunch: {
                Task {
                    await viewModel.launchApp(app, in: bottle)
                }
            },
            menu: {
                pinnedAppMenu(app)
            }
        )
    }

    @ViewBuilder
    private func pinnedAppMenu(_ app: AppEntry) -> some View {
        Button {
            toggleCommandPreview(for: app)
        } label: {
            Label(inspectedAppID == app.id ? "收起命令预览" : "查看完整启动命令", systemImage: "terminal")
        }

        Button {
            editingAppEntry = app
        } label: {
            Label("编辑参数与覆写…", systemImage: "slider.horizontal.3")
        }

        Button {
            if let firstTarget = app.snapshotTargets.first {
                _ = viewModel.createSnapshot(
                    for: firstTarget,
                    note: "从「\(app.name)」卡片一键创建快照",
                    in: bottle
                )
            } else {
                viewModel.isShowingSnapshotSheet = true
            }
        } label: {
            Label(app.snapshotTargets.isEmpty ? "配置快照…" : "一键快照", systemImage: "camera.metering.matrix")
        }

        Button {
            revealExecutable(app.executablePath)
        } label: {
            Label("在 Finder 中显示可执行文件", systemImage: "folder")
        }

        Button {
            Task {
                await viewModel.launchApp(app, in: bottle, debugChannelsOverride: "+loaddll")
            }
        } label: {
            Label("附带 +loaddll 调试通道启动", systemImage: "ant")
        }
        .disabled(viewModel.isRunningProcess)

        Divider()

        Button(role: .destructive) {
            viewModel.removeAppEntry(app, in: bottle)
        } label: {
            Label("取消固定并移除卡片", systemImage: "trash")
        }
    }

    private func commandInspectorPanel(for app: AppEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("「\(app.name)」的完整启动命令", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    toggleCommandPreview(for: app)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("收起")
            }

            if isLoadingAppPlan {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在生成精确启动命令…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let plan = inspectedAppPlan {
                LaunchPlanInspectorView(plan: plan) { cmd in
                    viewModel.copyToClipboard(cmd, label: "启动命令")
                }
            } else {
                Text("未能构建启动预览，请先确认已配置可用的 Wine 引擎。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(VermouthTheme.amber.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Discovered Executables Section

    private var discoveredProgramsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(
                    "容器内自动发现的程序 (\(viewModel.discoveredExecutables.count))",
                    systemImage: "sparkle.magnifyingglass"
                )
                .font(.headline)

                if viewModel.isScanningExecutables {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                TextField("搜索发现的程序…", text: $discoveredSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                Button {
                    Task {
                        await viewModel.scanExecutables(for: bottle, silentIfUninitialized: false)
                    }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(viewModel.isScanningExecutables)
            }

            if filteredDiscoveredExecutables.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        viewModel.discoveredExecutables.isEmpty
                            ? "暂未在开始菜单、桌面或 Program Files 中发现可启动程序"
                            : "没有匹配「\(discoveredSearchText)」的程序"
                    )
                    .font(.subheadline.weight(.medium))
                    Text("安装软件后点击「重新扫描」，或直接把免安装游戏目录放入 drive_c 后手动添加 `.exe`。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(filteredDiscoveredExecutables) { exec in
                        let alreadyPinned = viewModel.isDiscoveredExecutablePinned(exec, in: bottle)

                        HStack(spacing: 10) {
                            ProgramIconView(
                                hostPath: exec.executablePath,
                                name: exec.name,
                                cache: viewModel.iconCache,
                                size: 30
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(exec.name)
                                        .font(.subheadline.weight(.medium))
                                    PillBadge(
                                        text: exec.architecture.displayName,
                                        tint: exec.architecture.badgeTint
                                    )
                                    PillBadge(text: exec.source.displayName, tint: .secondary)
                                }

                                Text(exec.executablePath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if alreadyPinned {
                                PillBadge(text: "已固定", systemImage: "checkmark", tint: .green)
                            } else {
                                Button {
                                    viewModel.pinDiscoveredExecutable(exec, in: bottle)
                                } label: {
                                    Label("固定", systemImage: "pin")
                                }
                                .controlSize(.small)
                            }

                            Button {
                                Task {
                                    await viewModel.launchDiscoveredExecutable(exec, in: bottle)
                                }
                            } label: {
                                Label("运行", systemImage: "play")
                            }
                            .controlSize(.small)
                            .disabled(viewModel.isRunningProcess)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func toggleCommandPreview(for app: AppEntry) {
        if inspectedAppID == app.id {
            inspectedAppID = nil
            inspectedAppPlan = nil
            return
        }

        inspectedAppID = app.id
        inspectedAppPlan = nil
        isLoadingAppPlan = true
        Task {
            let plan = await viewModel.buildPreviewPlan(for: app, in: bottle)
            if inspectedAppID == app.id {
                inspectedAppPlan = plan
                isLoadingAppPlan = false
            }
        }
    }

    private func revealExecutable(_ rawPath: String) {
        let url: URL
        if rawPath.hasPrefix("/") {
            url = URL(fileURLWithPath: rawPath)
        } else {
            url = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
                .appendingPathComponent(rawPath)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            viewModel.openDriveC(for: bottle)
        }
    }
}

// MARK: - Create / Import Bottle Sheet

struct CreateBottleSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: CreateBottleMode = .createNew
    @State private var name: String = ""
    @State private var selectedEngineID: String = "__default__"
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var graphicsBackend: GraphicsBackend = .wined3d
    @State private var syncMode: SyncMode = .msync
    @State private var enableChinese: Bool = true
    @State private var selectedRecipeID: String = "__none__"

    // Import Existing Prefix Fields
    @State private var sourcePrefixPath: String = ""
    @State private var copyFilesOnImport: Bool = true
    @State private var isSubmitting: Bool = false

    private var selectedRecipe: Recipe? {
        guard selectedRecipeID != "__none__" else { return nil }
        return viewModel.recipes.first { $0.id == selectedRecipeID }
    }

    private var canSubmit: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasName && !isSubmitting else { return false }
        switch mode {
        case .createNew:
            return true
        case .importExisting:
            return !sourcePrefixPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("添加 Windows 容器")
                    .font(.headline)
                Picker("模式", selection: $mode) {
                    ForEach(CreateBottleMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(18)
            .background(.bar)

            Divider()

            Form {
                Section("容器基本信息") {
                    TextField("容器名称（如：Steam 现代游戏 / GTA SA）", text: $name)
                }

                if mode == .createNew {
                    Section("快速兼容配方（可选）") {
                        Picker("初始兼容配方", selection: $selectedRecipeID) {
                            Text("不使用预设配方（自定义配置）").tag("__none__")
                            ForEach(viewModel.recipes) { recipe in
                                Text("\(recipe.name) [\(recipe.targetArchitecture.displayName)]")
                                    .tag(recipe.id)
                            }
                        }
                        .onChange(of: selectedRecipeID) { _, newValue in
                            if let recipe = viewModel.recipes.first(where: { $0.id == newValue }) {
                                windowsVersion = recipe.recommendedWindowsVersion
                                graphicsBackend = recipe.recommendedBackend
                                syncMode = recipe.recommendedSyncMode
                                enableChinese = recipe.chineseLocalizationSuggested
                                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    name = recipe.name
                                }
                            }
                        }

                        if let recipe = selectedRecipe {
                            Text(recipe.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("转译栈初始预设") {
                        Picker("绑定 Wine 引擎", selection: $selectedEngineID) {
                            Text("跟随全局默认引擎").tag("__default__")
                            ForEach(viewModel.engines) { engine in
                                Text(engine.name).tag(engine.id)
                            }
                        }

                        Picker("Windows 目标版本", selection: $windowsVersion) {
                            ForEach(WindowsVersion.allCases, id: \.self) { ver in
                                Text(ver.displayName).tag(ver)
                            }
                        }

                        Picker("图形转译后端", selection: $graphicsBackend) {
                            ForEach(GraphicsBackend.allCases, id: \.self) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }

                        Picker("同步原语模式", selection: $syncMode) {
                            ForEach(SyncMode.allCases, id: \.self) { sync in
                                Text(sync.displayName).tag(sync)
                            }
                        }

                        Toggle("开启中文环境与字体防乱码补全 (推荐)", isOn: $enableChinese)
                    }
                } else {
                    Section("源 WINEPREFIX 目录") {
                        HStack {
                            TextField("选择包含 drive_c 与 system.reg 的前缀目录", text: $sourcePrefixPath)
                                .font(.caption.monospaced())
                            Button("浏览…") {
                                browsePrefixDirectory()
                            }
                        }

                        Toggle("复制文件到 Vermouth 托管目录（APFS 克隆隔离）", isOn: $copyFilesOnImport)

                        if copyFilesOnImport {
                            Text("将源前缀完整克隆至 `~/Library/Application Support/Vermouth/bottles/` 下独立管理，不影响原软件数据。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(
                                "外部引用模式（L-005 数据保护）：就地使用外部 WINEPREFIX；后续在 Vermouth 中删除此容器时，绝不会删除外部原目录。",
                                systemImage: "shield.lefthalf.filled"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在处理容器…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode == .createNew ? "创建容器" : "导入容器") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 560, height: 540)
        .onAppear {
            mode = viewModel.createBottleInitialMode
        }
    }

    private func browsePrefixDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择已有的 WINEPREFIX 目录（含 drive_c）"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        sourcePrefixPath = url.path
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = url.lastPathComponent
        }
    }

    private func submit() {
        isSubmitting = true
        let engineChoice: String? = selectedEngineID == "__default__" ? nil : selectedEngineID
        let recipeChoice: String? = selectedRecipeID == "__none__" ? nil : selectedRecipeID

        Task {
            let ok: Bool
            switch mode {
            case .createNew:
                ok = await viewModel.createBottle(
                    name: name,
                    engineID: engineChoice,
                    windowsVersion: windowsVersion,
                    graphicsBackend: graphicsBackend,
                    syncMode: syncMode,
                    enableChinese: enableChinese,
                    initialRecipeID: recipeChoice
                )
            case .importExisting:
                ok = await viewModel.importExistingPrefix(
                    name: name,
                    sourcePrefixPath: sourcePrefixPath,
                    copyFiles: copyFilesOnImport
                )
            }
            isSubmitting = false
            if ok {
                dismiss()
            }
        }
    }
}

// MARK: - AppEntry Editor Sheet

struct AppEntryEditorSheet: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle
    let initialEntry: AppEntry

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var executablePath: String = ""
    @State private var argumentsText: String = ""
    @State private var workingDirectory: String = ""
    @State private var envPairs: [EditableEnvPair] = []
    @State private var newEnvKey: String = ""
    @State private var newEnvValue: String = ""
    @State private var dllOverrides: [DllOverride] = []
    @State private var newDllName: String = ""
    @State private var newDllMode: DllOverrideMode = .nativeThenBuiltin
    @State private var snapshotTargets: [SnapshotTarget] = []
    @State private var newTargetLabel: String = ""
    @State private var newTargetPath: String = ""

    private struct EditableEnvPair: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑程序启动项：\(initialEntry.name)")
                        .font(.headline)
                    Text("单程序级参数、环境变量与 DLL 覆写优先生效，覆盖容器默认配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(.bar)

            Divider()

            Form {
                Section("基本路径与参数") {
                    TextField("显示名称", text: $name)

                    HStack {
                        TextField("可执行文件路径 (.exe)", text: $executablePath)
                            .font(.caption.monospaced())
                        Button("浏览…") {
                            browseExecutable()
                        }
                    }

                    HStack {
                        TextField("工作目录（留空则默认可执行文件所在目录）", text: $workingDirectory)
                            .font(.caption.monospaced())
                        Button("浏览…") {
                            browseWorkingDirectory()
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("启动参数（每行一个参数，避免空格转义歧义）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $argumentsText)
                            .font(.caption.monospaced())
                            .frame(height: 64)
                    }
                }

                Section("单程序级 DLL 覆写（可选）") {
                    HStack(spacing: 6) {
                        Text("快捷钩子：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(DllOverride.commonPresets) { preset in
                            let exists = dllOverrides.contains { $0.dllName == preset.dllName }
                            Button(preset.dllName) {
                                if !exists {
                                    dllOverrides.append(preset)
                                }
                            }
                            .controlSize(.mini)
                            .disabled(exists)
                        }
                    }

                    ForEach($dllOverrides) { $dllEntry in
                        HStack {
                            Toggle("", isOn: $dllEntry.enabled)
                                .labelsHidden()
                            Text(dllEntry.dllName)
                                .font(.caption.monospaced().weight(.semibold))
                                .frame(width: 90, alignment: .leading)
                            Picker("", selection: $dllEntry.mode) {
                                ForEach(DllOverrideMode.allCases, id: \.self) { mode in
                                    Text(mode.shortCode).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            Spacer()
                            Button(role: .destructive) {
                                let targetID = dllEntry.id
                                dllOverrides.removeAll { $0.id == targetID }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("新增 DLL 名称（如 dinput8）", text: $newDllName)
                            .font(.caption.monospaced())
                        Picker("", selection: $newDllMode) {
                            ForEach(DllOverrideMode.allCases, id: \.self) { mode in
                                Text(mode.shortCode).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button("添加") {
                            let normalized = DllOverride.normalizeName(newDllName)
                            guard !normalized.isEmpty else { return }
                            dllOverrides.removeAll { $0.dllName == normalized }
                            dllOverrides.append(DllOverride(dllName: normalized, mode: newDllMode, enabled: true))
                            newDllName = ""
                        }
                        .disabled(DllOverride.normalizeName(newDllName).isEmpty)
                    }
                }

                Section("单程序级独立环境变量") {
                    ForEach($envPairs) { $pair in
                        HStack {
                            TextField("KEY", text: $pair.key)
                                .font(.caption.monospaced())
                                .frame(width: 150)
                            TextField("VALUE", text: $pair.value)
                                .font(.caption.monospaced())
                            Button(role: .destructive) {
                                let id = pair.id
                                envPairs.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("变量名 (如 DXMT_CONFIG)", text: $newEnvKey)
                            .font(.caption.monospaced())
                            .frame(width: 160)
                        TextField("变量值", text: $newEnvValue)
                            .font(.caption.monospaced())
                        Button("添加") {
                            let key = newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty, !key.contains("=") else { return }
                            envPairs.removeAll { $0.key == key }
                            envPairs.append(EditableEnvPair(key: key, value: newEnvValue))
                            newEnvKey = ""
                            newEnvValue = ""
                        }
                        .disabled(newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("关联存档或配置快照目录") {
                    ForEach(snapshotTargets) { target in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.label)
                                    .font(.caption.weight(.semibold))
                                Text(target.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                snapshotTargets.removeAll { $0.id == target.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("标签（如：游戏存档）", text: $newTargetLabel)
                            .frame(width: 130)
                        TextField("目录或文件路径", text: $newTargetPath)
                            .font(.caption.monospaced())
                        Button("浏览…") {
                            browseSnapshotTarget()
                        }
                        Button("添加") {
                            let path = newTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !path.isEmpty else { return }
                            let label = newTargetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                            let finalLabel = label.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : label
                            snapshotTargets.append(SnapshotTarget(label: finalLabel, path: path))
                            newTargetLabel = ""
                            newTargetPath = ""
                        }
                        .disabled(newTargetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存更改") {
                    saveChanges()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 620, height: 620)
        .onAppear {
            name = initialEntry.name
            executablePath = initialEntry.executablePath
            argumentsText = initialEntry.arguments.joined(separator: "\n")
            workingDirectory = initialEntry.workingDirectory ?? ""
            envPairs = initialEntry.environmentOverrides.keys.sorted().compactMap { key in
                guard let val = initialEntry.environmentOverrides[key] else { return nil }
                return EditableEnvPair(key: key, value: val)
            }
            dllOverrides = initialEntry.dllOverrides
            snapshotTargets = initialEntry.snapshotTargets
        }
    }

    private func browseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择可执行文件 (.exe)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        if let exeType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [exeType]
        }
        panel.directoryURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
        }
    }

    private func browseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择工作目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func browseSnapshotTarget() {
        let panel = NSOpenPanel()
        panel.title = "选择要纳入快照备份的存档目录或配置文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            newTargetPath = url.path
            if newTargetLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newTargetLabel = url.lastPathComponent
            }
        }
    }

    private func saveChanges() {
        let parsedArgs = argumentsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var envDict: [String: String] = [:]
        for pair in envPairs {
            let trimmedKey = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty && !trimmedKey.contains("=") {
                envDict[trimmedKey] = pair.value
            }
        }

        let trimmedWorkingDir = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = initialEntry
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.executablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.arguments = parsedArgs
        updated.workingDirectory = trimmedWorkingDir.isEmpty ? nil : trimmedWorkingDir
        updated.environmentOverrides = envDict
        updated.dllOverrides = dllOverrides
        updated.snapshotTargets = snapshotTargets

        viewModel.saveAppEntry(updated, in: bottle)
        dismiss()
    }
}

// MARK: - Sanitized Recipe Export Sheet

struct RecipeExportSheet: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle
    @Environment(\.dismiss) private var dismiss

    @State private var recipeID: String = ""
    @State private var recipeName: String = ""
    @State private var recipeSummary: String = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导出脱敏兼容配方 (.recipe.json)")
                    .font(.headline)
                Text("自动剥离本机路径、用户名、Token/密钥等敏感环境变量，可安全分享给社区其他玩家。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.bar)

            Divider()

            Form {
                TextField("配方标识符 (ID)", text: $recipeID)
                    .font(.caption.monospaced())
                TextField("配方显示名称", text: $recipeName)
                TextField("简要说明（如测试机型与转译组合表现）", text: $recipeSummary)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("选择保存位置并导出…") {
                    if viewModel.exportRecipe(
                        from: bottle,
                        id: recipeID,
                        name: recipeName,
                        summary: recipeSummary
                    ) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    recipeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 480, height: 300)
        .onAppear {
            let slug = bottle.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            recipeID = slug.isEmpty ? "custom-recipe" : slug
            recipeName = bottle.name
            recipeSummary = "\(bottle.config.windowsVersion.displayName) + \(bottle.config.graphicsBackend.displayName) + \(bottle.config.syncMode.shortLabel)"
        }
    }
}
#endif
