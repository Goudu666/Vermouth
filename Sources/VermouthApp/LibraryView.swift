#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VermouthCore

/// 普通模式主界面：像一个游戏库，拖进来就能装，双击就能玩。
/// 容器、引擎、转译链路、日志这些技术细节都收进「程序详情 › 技术详情」或高级模式。
struct LibraryView: View {
    @Bindable var viewModel: AppViewModel
    @AppStorage(AppViewModel.advancedModeDefaultsKey) private var isAdvancedMode = false

    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State private var detailRef: LibraryItemRef?
    @State private var problemReportForSheet: LaunchReport?

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 22)]

    private var visibleItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.libraryItems }
        return viewModel.libraryItems.filter { $0.app.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            libraryContent
        }
    }

    private var libraryContent: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if !viewModel.isEnvironmentReady {
                        EnvironmentSetupPanel(viewModel: viewModel, style: .card)
                    }

                    if let report = viewModel.lastLaunchReport {
                        problemBanner(report)
                    }

                    if viewModel.libraryItems.isEmpty {
                        emptyLibrary
                    } else if visibleItems.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(visibleItems) { item in
                                LibraryCard(
                                    item: item,
                                    hostPath: viewModel.hostPath(for: item),
                                    cache: viewModel.iconCache,
                                    activity: viewModel.launchActivity,
                                    onLaunch: { Task { await viewModel.quickLaunch(item) } },
                                    onStop: { Task { await viewModel.stopProgram(in: item.bottleID) } },
                                    onOpenDetail: { detailRef = LibraryItemRef(id: item.id) }
                                ) {
                                    cardMenu(for: item)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ActivityToast(viewModel: viewModel)
                .padding(.bottom, 18)
        }
        .background(libraryBackground)
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.handleLibraryDrop(urls)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                isDropTargeted = targeted
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索程序")
        .toolbar { toolbarContent }
        .navigationTitle("Vermouth")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户从「终端」装完环境回来时自动刷新
            if !viewModel.isEnvironmentReady {
                Task { await viewModel.refreshPreflight() }
            }
        }
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(
                get: { viewModel.pendingProgramFile != nil },
                set: { if !$0 { viewModel.pendingProgramFile = nil } }
            ),
            presenting: viewModel.pendingProgramFile
        ) { pending in
            pendingButtons(pending)
        } message: { pending in
            Text(
                pending.suggestedKind == .installer
                    ? "看起来是一个安装程序。安装完成后，装好的程序会自动出现在程序库里。"
                    : "看起来是可以直接运行的程序（免安装游戏或软件），会直接加入程序库。"
            )
        }
        .sheet(item: $detailRef) { ref in
            ProgramDetailSheet(viewModel: viewModel, itemID: ref.id)
        }
        .sheet(item: $problemReportForSheet) { report in
            ProblemAssistantSheet(viewModel: viewModel, report: report)
        }
        .sheet(isPresented: $viewModel.isShowingInstalledProgramsSheet) {
            InstalledProgramsSheet(viewModel: viewModel)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("程序库")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !viewModel.libraryItems.isEmpty {
                Button {
                    viewModel.promptForProgramFile()
                } label: {
                    Label("添加程序", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(VermouthTheme.burgundy)
                .controlSize(.large)
            }
        }
    }

    private var subtitle: String {
        let count = viewModel.libraryItems.count
        if count == 0 {
            return "把 Windows 游戏和软件，倒进你的 Mac。"
        }
        return "\(count) 个程序 · 双击启动，把 .exe 拖进窗口即可添加"
    }

    private var libraryBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [VermouthTheme.burgundy.opacity(0.10), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Empty State

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: VermouthTheme.burgundy.opacity(0.35), radius: 16, y: 8)

            VStack(spacing: 6) {
                Text("把 Windows 程序拖到这里")
                    .font(.title2.weight(.semibold))
                Text("安装包（setup.exe、.msi）会自动安装，免安装的游戏直接加入程序库。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.promptForProgramFile()
                } label: {
                    Label("选择文件…", systemImage: "folder")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(VermouthTheme.burgundy)
                .controlSize(.large)

                Button("查找已安装的程序") {
                    Task { await viewModel.openInstalledProgramsBrowser() }
                }
                .controlSize(.large)
                .disabled(!viewModel.isEnvironmentReady)
            }
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(Color.secondary.opacity(0.35))
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(VermouthTheme.amber.opacity(0.12))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(VermouthTheme.amber, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            }
            .overlay {
                Label("松开即可添加", systemImage: "square.and.arrow.down")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(VermouthTheme.amber)
            }
            .padding(14)
            .allowsHitTesting(false)
    }

    // MARK: Problem Banner

    private func problemBanner(_ report: LaunchReport) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)
                .background(Color.orange.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(report.outcome.headline(programName: report.programName))
                    .font(.headline)
                Text(report.findings.isEmpty ? "可以看看建议，或者查看技术日志。" : "Vermouth 找到了可能的原因，大多数可以一键修复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("查看并修复") {
                if let appID = report.appID, viewModel.libraryItem(id: appID) != nil {
                    detailRef = LibraryItemRef(id: appID)
                } else {
                    problemReportForSheet = report
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button {
                viewModel.lastLaunchReport = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("忽略")
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }

    // MARK: Pending File Dialog

    private var pendingTitle: String {
        guard let pending = viewModel.pendingProgramFile else { return "添加程序" }
        return "添加「\(pending.displayName)」"
    }

    @ViewBuilder
    private func pendingButtons(_ pending: PendingProgramFile) -> some View {
        let install = Button("安装它") {
            Task { await viewModel.confirmPendingProgram(pending, as: .installer) }
        }
        let add = Button("直接加入程序库") {
            Task { await viewModel.confirmPendingProgram(pending, as: .application) }
        }
        if pending.suggestedKind == .installer {
            install.keyboardShortcut(.defaultAction)
            add
        } else {
            add.keyboardShortcut(.defaultAction)
            install
        }
        Button("取消", role: .cancel) {
            viewModel.pendingProgramFile = nil
        }
    }

    // MARK: Card Menu

    @ViewBuilder
    private func cardMenu(for item: LibraryItem) -> some View {
        Button {
            Task { await viewModel.quickLaunch(item) }
        } label: {
            Label("启动", systemImage: "play.fill")
        }
        Button {
            detailRef = LibraryItemRef(id: item.id)
        } label: {
            Label("详情与问题修复…", systemImage: "info.circle")
        }
        Divider()
        Button {
            viewModel.revealInFinder(item)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            viewModel.removeFromLibrary(item)
        } label: {
            Label("从程序库移除", systemImage: "minus.circle")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    viewModel.promptForProgramFile()
                } label: {
                    Label("选择程序或安装包…", systemImage: "doc.badge.plus")
                }
                Button {
                    Task { await viewModel.openInstalledProgramsBrowser() }
                } label: {
                    Label("查找已安装的程序…", systemImage: "magnifyingglass")
                }
                .disabled(!viewModel.isEnvironmentReady)
            } label: {
                Label("添加", systemImage: "plus")
            }
            .help("添加 Windows 程序")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    viewModel.isShowingSetupSheet = true
                } label: {
                    Label("运行环境…", systemImage: "checkmark.seal")
                }
                Button {
                    Task {
                        if let bottle = await viewModel.ensureDefaultBottle() {
                            viewModel.selectedBottleID = bottle.id
                            viewModel.openRuntimeInstaller()
                        }
                    }
                } label: {
                    Label("安装常用运行库（VC++ / DirectX / .NET）…", systemImage: "shippingbox")
                }
                .disabled(!viewModel.isEnvironmentReady)
                Divider()
                Button {
                    isAdvancedMode = true
                } label: {
                    Label("切换到高级模式", systemImage: "slider.horizontal.3")
                }
            } label: {
                Label("更多", systemImage: "gearshape")
            }
            .help("运行环境、运行库与高级模式")
        }
    }
}

// MARK: - Library Card

/// 程序库卡片：封面式图标 + 名称。单击看详情，双击或点悬停的播放键启动。
struct LibraryCard<MenuContent: View>: View {
    let item: LibraryItem
    let hostPath: String
    let cache: ProgramIconCache
    let activity: LaunchActivity
    let onLaunch: () -> Void
    let onStop: () -> Void
    let onOpenDetail: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var isHovering = false

    private var isThisActive: Bool { activity.appID == item.id }
    private var isPreparing: Bool {
        if case .preparing = activity, isThisActive { return true }
        return false
    }
    private var isRunning: Bool {
        if case .running = activity, isThisActive { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            cover
            VStack(spacing: 3) {
                Text(item.app.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                statusLine
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !activity.isActive { onLaunch() }
        }
        .onTapGesture {
            onOpenDetail()
        }
        .contextMenu { menu() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .help("双击启动 · 单击查看详情")
    }

    private var cover: some View {
        let hue = VermouthTheme.stableHue(for: item.app.name)
        return ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.45, brightness: 0.55),
                            Color(hue: hue, saturation: 0.65, brightness: 0.22),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(isHovering ? 0.06 : 0))
                }

            ProgramIconView(hostPath: hostPath, name: item.app.name, cache: cache, size: 76)
                .scaleEffect(isHovering ? 1.07 : 1)
                .opacity(isHovering && !isThisActive ? 0.55 : 1)

            if isPreparing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
            } else if isRunning {
                runningOverlay
            } else if isHovering && !activity.isActive {
                Button(action: onLaunch) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(VermouthTheme.burgundy, in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .help("启动")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 150)
        .shadow(color: .black.opacity(isHovering ? 0.28 : 0.14), radius: isHovering ? 14 : 6, y: isHovering ? 8 : 3)
        .offset(y: isHovering ? -2 : 0)
        .overlay(alignment: .topTrailing) {
            if isRunning {
                Label("运行中", systemImage: "circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .labelStyle(RunningDotLabelStyle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.85), in: Capsule())
                    .padding(10)
            }
        }
    }

    private var runningOverlay: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0)
        .help("停止")
    }

    @ViewBuilder
    private var statusLine: some View {
        if isPreparing {
            Text("正在准备…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isRunning {
            Text("正在运行")
                .font(.caption)
                .foregroundStyle(.green)
        } else if let last = item.app.lastLaunchedAt {
            Text("上次运行 \(last.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("还没运行过")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 「运行中」徽标里的小圆点会轻轻呼吸。
private struct RunningDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 6))
                .symbolEffect(.pulse)
            configuration.title
        }
    }
}

// MARK: - Activity Toast

/// 底部浮动提示：正在准备 / 正在运行 / 操作结果。替代原来的技术状态栏。
struct ActivityToast: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        Group {
            if let busy = viewModel.busyStatusText, viewModel.isBusyWithBottleOperation {
                toast(icon: nil, text: busy, showsSpinner: true)
            } else if case let .preparing(_, message) = viewModel.launchActivity {
                toast(icon: nil, text: message, showsSpinner: true)
            } else if let banner = viewModel.statusBannerMessage {
                toast(icon: "checkmark.circle.fill", text: banner, showsSpinner: false)
                    .onTapGesture { viewModel.statusBannerMessage = nil }
            } else if case let .running(appID, name) = viewModel.launchActivity, appID == nil {
                // 安装程序、运行库等没有卡片的任务
                toast(icon: "hourglass", text: "正在\(name.hasPrefix("安装") ? "" : "运行")\(name)…", showsSpinner: true)
            }
        }
        .animation(.spring(duration: 0.3), value: viewModel.statusBannerMessage)
        .animation(.spring(duration: 0.3), value: viewModel.launchActivity)
    }

    private func toast(icon: String?, text: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 10) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.green)
            }
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .frame(maxWidth: 560)
    }
}
#endif
