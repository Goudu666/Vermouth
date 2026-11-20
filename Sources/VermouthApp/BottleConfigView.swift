#if os(macOS)
import SwiftUI
import VermouthCore

struct BottleConfigView: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle

    @State private var virtualWidthText: String = "1280"
    @State private var virtualHeightText: String = "720"
    @State private var lcAllText: String = "zh_CN.UTF-8"
    @State private var fallbackFontText: String = "STHeiti"
    @State private var isShowingCommandPreview: Bool = true

    private var activeEngine: WineEngine? {
        viewModel.resolvedEngine(for: bottle)
    }

    private var deploymentState: GraphicsDeploymentRecord {
        viewModel.deploymentRecord(for: bottle)
    }

    private var matchingPackagesForCurrentBackend: [GraphicsLayerPackage] {
        guard bottle.config.graphicsBackend != .wined3d else { return [] }
        return viewModel.installedGraphicsPackages.filter {
            $0.backend == bottle.config.graphicsBackend
        }
    }

    private var engineSelectionBinding: Binding<String> {
        Binding(
            get: { bottle.config.engineID ?? "__default__" },
            set: { newValue in
                let newID: String? = newValue == "__default__" ? nil : newValue
                Task {
                    await viewModel.updateBottleConfig(for: bottle) { config in
                        config.engineID = newID
                    }
                }
            }
        )
    }

    private var windowsVersionBinding: Binding<WindowsVersion> {
        Binding(
            get: { bottle.config.windowsVersion },
            set: { newVersion in
                Task {
                    await viewModel.updateBottleConfig(for: bottle, syncRegistry: true) { config in
                        config.windowsVersion = newVersion
                    }
                }
            }
        )
    }

    private var syncModeBinding: Binding<SyncMode> {
        Binding(
            get: { bottle.config.syncMode },
            set: { newSyncMode in
                Task {
                    await viewModel.updateBottleConfig(for: bottle) { config in
                        config.syncMode = newSyncMode
                    }
                }
            }
        )
    }

    private var metalHUDBinding: Binding<Bool> {
        Binding(
            get: { bottle.config.display.metalHUD },
            set: { enabled in
                Task {
                    await viewModel.updateBottleConfig(for: bottle) { config in
                        config.display.metalHUD = enabled
                    }
                }
            }
        )
    }

    private var retinaModeBinding: Binding<Bool> {
        Binding(
            get: { bottle.config.display.retinaMode },
            set: { enabled in
                Task {
                    await viewModel.updateBottleConfig(for: bottle) { config in
                        config.display.retinaMode = enabled
                    }
                }
            }
        )
    }

    private var dpiBinding: Binding<Int> {
        Binding(
            get: { bottle.config.display.dpi },
            set: { newDPI in
                Task {
                    await viewModel.updateBottleConfig(for: bottle) { config in
                        config.display.dpi = newDPI
                    }
                }
            }
        )
    }

    private var virtualDesktopEnabledBinding: Binding<Bool> {
        Binding(
            get: { bottle.config.display.virtualDesktop.enabled },
            set: { enabled in
                let parsedW = max(320, Int(virtualWidthText) ?? bottle.config.display.virtualDesktop.width)
                let parsedH = max(240, Int(virtualHeightText) ?? bottle.config.display.virtualDesktop.height)
                Task {
                    await viewModel.updateBottleConfig(for: bottle) { config in
                        config.display.virtualDesktop.enabled = enabled
                        config.display.virtualDesktop.width = parsedW
                        config.display.virtualDesktop.height = parsedH
                    }
                }
            }
        )
    }

    private var chineseEnabledBinding: Binding<Bool> {
        Binding(
            get: { bottle.config.locale.chineseLocalizationEnabled },
            set: { enabled in
                let lc = lcAllText.trimmingCharacters(in: .whitespacesAndNewlines)
                let font = fallbackFontText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await viewModel.updateBottleConfig(for: bottle) { config in
                        config.locale.chineseLocalizationEnabled = enabled
                        if !lc.isEmpty {
                            config.locale.lcAll = lc
                        }
                        if !font.isEmpty {
                            config.locale.fallbackFontName = font
                        }
                    }
                }
            }
        )
    }

    var body: some View {
        Form {
            engineAndSystemSection
            graphicsStackSection
            syncAndDisplaySection
            chineseLocalizationSection
            transparentPreviewSection
        }
        .formStyle(.grouped)
        .onAppear {
            syncLocalTextFields()
        }
        .onChange(of: bottle) { _, _ in
            syncLocalTextFields()
        }
    }

    // MARK: - Section 1: Engine & Windows Version

    private var engineAndSystemSection: some View {
        Section {
            Picker("Wine 转译引擎", selection: engineSelectionBinding) {
                if let defEngine = viewModel.activeDefaultEngine {
                    Text("跟随全局默认（\(defEngine.name)）").tag("__default__")
                } else {
                    Text("跟随全局默认（未检测到引擎）").tag("__default__")
                }
                ForEach(viewModel.engines) { engine in
                    Text("\(engine.name) — \(engine.version)").tag(engine.id)
                }
            }

            if let engine = activeEngine {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("生效引擎能力探测")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if engine.isQuarantined {
                            Button {
                                Task {
                                    await viewModel.removeQuarantineForEngine(engine)
                                }
                            } label: {
                                Label("解除隔离属性", systemImage: "lock.open.fill")
                            }
                            .controlSize(.mini)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                    EngineCapabilityPills(engine: engine)
                }
                .padding(.vertical, 2)
            } else {
                HStack {
                    Label("当前未检测到可用的 Wine 引擎", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("打开环境预检…") {
                        viewModel.isShowingPreflightSheet = true
                    }
                    .controlSize(.small)
                }
            }

            Picker("Windows 目标版本", selection: windowsVersionBinding) {
                ForEach(WindowsVersion.allCases, id: \.self) { ver in
                    Text(ver.displayName).tag(ver)
                }
            }

            LabeledContent("容器前缀路径") {
                HStack(spacing: 6) {
                    if bottle.isExternalPrefix {
                        PillBadge(text: "外部引用 (L-005 保护)", systemImage: "shield.lefthalf.filled", tint: .orange)
                    }
                    Text(bottle.prefixPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("引擎与 Windows 系统版本")
        }
    }

    // MARK: - Section 2: DirectX Graphics Translation Stack

    private var graphicsStackSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(GraphicsBackend.allCases, id: \.self) { backend in
                    graphicsBackendRow(backend)
                }
            }
            .padding(.vertical, 4)

            if bottle.config.graphicsBackend != .wined3d {
                let activePkgID = viewModel.resolvedGraphicsPackage(for: bottle)?.id ?? ""
                Picker(
                    "图形包版本",
                    selection: Binding(
                        get: { activePkgID },
                        set: { newPkgID in
                            guard !newPkgID.isEmpty else { return }
                            Task {
                                await viewModel.switchGraphicsBackend(
                                    bottle.config.graphicsBackend,
                                    packageID: newPkgID,
                                    for: bottle
                                )
                            }
                        }
                    )
                ) {
                    if matchingPackagesForCurrentBackend.isEmpty {
                        Text("尚未安装本地包").tag("")
                    } else {
                        ForEach(matchingPackagesForCurrentBackend) { pkg in
                            Text("\(pkg.version) [\(pkg.format.displayName)]\(pkg.isDXVKMissingDXGI ? " ⚠️ 缺 dxgi" : "")").tag(pkg.id)
                        }
                    }
                }
            }

            LabeledContent("落盘部署机制") {
                Text(deploymentState.strategy.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let pkg = viewModel.resolvedGraphicsPackage(for: bottle),
               pkg.format == .wineBuiltin,
               let engine = activeEngine,
               !engine.capabilities.supportsWineDLLPathPrepend
            {
                Label(
                    "警告（L-001）：当前图形包 \(pkg.id) 为 wineBuiltin 格式，必须搭配支持 WINEDLLPATH_PREPEND 的 Wine 引擎运行，严禁复制到 system32。",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }

            HStack {
                Text("支持从 3Shain/dxmt 与 Gcenx/DXVK-macOS 官方 Releases 按需拉取或导入归档。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.openEngineSettings(tab: .graphics)
                } label: {
                    Label("管理图形转译层版本库…", systemImage: "square.stack.3d.down.right")
                }
                .controlSize(.small)
            }
        } header: {
            Text("DirectX 图形转译层")
        }
    }

    private func graphicsBackendRow(_ backend: GraphicsBackend) -> some View {
        let isSelected = bottle.config.graphicsBackend == backend
        let installedCount = viewModel.installedGraphicsPackages.filter { $0.backend == backend }.count

        return Button {
            guard !isSelected else { return }
            Task {
                await viewModel.switchGraphicsBackend(backend, packageID: nil, for: bottle)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                Image(systemName: backend.systemImage)
                    .foregroundStyle(backend.badgeTint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(backend.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if backend == .wined3d {
                            PillBadge(text: "内置免下载", tint: .secondary)
                        } else if installedCount > 0 {
                            PillBadge(text: "已安装 \(installedCount) 个版本", tint: .green)
                        } else {
                            PillBadge(text: "需下载安装", tint: .orange)
                        }
                    }
                    Text(backend.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusyWithBottleOperation)
    }

    // MARK: - Section 3: Sync, Display & Performance HUD

    private var syncAndDisplaySection: some View {
        Section {
            Picker("进程同步原语", selection: syncModeBinding) {
                ForEach(SyncMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Toggle("开启 Apple Metal Performance HUD 帧率与 GPU 监控", isOn: metalHUDBinding)

            Toggle("Retina 高分屏原生渲染模式 (Mac Driver RetinaMode)", isOn: retinaModeBinding)

            Picker("桌面缩放 DPI", selection: dpiBinding) {
                Text("96 DPI（标准 100%）").tag(96)
                Text("144 DPI（放大 150%）").tag(144)
                Text("192 DPI（放大 200%）").tag(192)
            }

            Toggle("启用独立窗口虚拟桌面（兼容老游戏全屏切换黑屏）", isOn: virtualDesktopEnabledBinding)

            if bottle.config.display.virtualDesktop.enabled {
                HStack(spacing: 8) {
                    Text("虚拟桌面分辨率")
                    Spacer()
                    TextField("宽", text: $virtualWidthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onSubmit { commitDisplayDimensions() }
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("高", text: $virtualHeightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onSubmit { commitDisplayDimensions() }

                    Menu("常用预设") {
                        Button("1280 × 720 (720p)") { applyResolutionPreset(1280, 720) }
                        Button("1600 × 900 (900p)") { applyResolutionPreset(1600, 900) }
                        Button("1920 × 1080 (1080p)") { applyResolutionPreset(1920, 1080) }
                        Button("2560 × 1440 (1440p)") { applyResolutionPreset(2560, 1440) }
                    }
                    .frame(width: 96)
                }
            }

            HStack {
                Text("修改 Retina、DPI 或虚拟桌面后，点击右侧按钮立即同步进容器注册表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    commitAllPendingTextAndSyncRegistry()
                } label: {
                    Label("同步配置到容器注册表", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                }
                .controlSize(.small)
                .disabled(viewModel.isBusyWithBottleOperation)
            }
        } header: {
            Text("同步机制、显示与性能监控")
        } footer: {
            Text("切换同步模式时会自动安全终止该容器已有的后台 wineserver，防止 msync_init 协议冲突（L-003）。")
        }
    }

    // MARK: - Section 4: Chinese Localization

    private var chineseLocalizationSection: some View {
        Section {
            Toggle("启用中文 Locale 与中文字体防乱码映射", isOn: chineseEnabledBinding)

            HStack {
                Text("Locale (LC_ALL / LANG)")
                Spacer()
                TextField("zh_CN.UTF-8", text: $lcAllText)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { commitLocaleTextFields() }
            }

            HStack {
                Text("macOS 中文字体回退目标")
                Spacer()
                TextField("STHeiti", text: $fallbackFontText)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { commitLocaleTextFields() }

                Menu("选择本机字体") {
                    ForEach(RegistryPatcher.preferredMacOSCJKFonts, id: \.name) { item in
                        Button(item.name) {
                            fallbackFontText = item.name
                            commitLocaleTextFields()
                        }
                    }
                }
                .frame(width: 110)
            }

            HStack {
                Text("将 SimSun/宋体/微软雅黑/Tahoma 等映射至 macOS 系统字体（UTF-16LE + REG_MULTI_SZ）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        let lc = lcAllText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let font = fallbackFontText.trimmingCharacters(in: .whitespacesAndNewlines)
                        await viewModel.updateBottleConfig(for: bottle, syncRegistry: false) { config in
                            config.locale.chineseLocalizationEnabled = true
                            if !lc.isEmpty { config.locale.lcAll = lc }
                            if !font.isEmpty { config.locale.fallbackFontName = font }
                        }
                        if let latest = viewModel.selectedBottle {
                            await viewModel.applyChineseEnvironmentFix(for: latest)
                        }
                    }
                } label: {
                    Label("一键开启并立即写入注册表", systemImage: "character.book.closed.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusyWithBottleOperation)
            }
        } header: {
            Text("中文环境补全 (防方块乱码)")
        }
    }

    // MARK: - Section 5: Transparent Command Preview

    private var transparentPreviewSection: some View {
        Section {
            DisclosureGroup(
                "展开查看底层完整 WINEPREFIX、环境变量与 POSIX 启动命令",
                isExpanded: $isShowingCommandPreview
            ) {
                if let plan = viewModel.previewLaunchPlan {
                    LaunchPlanInspectorView(plan: plan) { cmd in
                        viewModel.copyToClipboard(cmd, label: "启动命令")
                    }
                    .padding(.top, 8)
                } else {
                    Text("请先安装或登记一套可用的 Wine 引擎以生成实时命令预览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        } header: {
            Text("配置透明性预览")
        }
    }

    // MARK: - Local Field Sync Helpers

    private func syncLocalTextFields() {
        virtualWidthText = "\(bottle.config.display.virtualDesktop.width)"
        virtualHeightText = "\(bottle.config.display.virtualDesktop.height)"
        lcAllText = bottle.config.locale.lcAll
        fallbackFontText = bottle.config.locale.fallbackFontName
    }

    private func applyResolutionPreset(_ width: Int, _ height: Int) {
        virtualWidthText = "\(width)"
        virtualHeightText = "\(height)"
        commitDisplayDimensions()
    }

    private func commitDisplayDimensions() {
        let width = max(320, Int(virtualWidthText) ?? 1280)
        let height = max(240, Int(virtualHeightText) ?? 720)
        virtualWidthText = "\(width)"
        virtualHeightText = "\(height)"
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                config.display.virtualDesktop.width = width
                config.display.virtualDesktop.height = height
            }
        }
    }

    private func commitLocaleTextFields() {
        let lc = lcAllText.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = fallbackFontText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                if !lc.isEmpty {
                    config.locale.lcAll = lc
                }
                if !font.isEmpty {
                    config.locale.fallbackFontName = font
                }
            }
        }
    }

    private func commitAllPendingTextAndSyncRegistry() {
        let width = max(320, Int(virtualWidthText) ?? bottle.config.display.virtualDesktop.width)
        let height = max(240, Int(virtualHeightText) ?? bottle.config.display.virtualDesktop.height)
        let lc = lcAllText.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = fallbackFontText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            await viewModel.updateBottleConfig(for: bottle, syncRegistry: true) { config in
                config.display.virtualDesktop.width = width
                config.display.virtualDesktop.height = height
                if !lc.isEmpty {
                    config.locale.lcAll = lc
                }
                if !font.isEmpty {
                    config.locale.fallbackFontName = font
                }
            }
        }
    }
}
#endif
