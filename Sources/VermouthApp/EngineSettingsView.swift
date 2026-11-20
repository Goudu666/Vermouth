#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VermouthCore

struct EngineSettingsView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: EngineSettingsTab = .engines

    // Custom Engine Registration Draft
    @State private var isShowingCustomEngineForm: Bool = false
    @State private var customEngineName: String = ""
    @State private var customEnginePath: String = ""
    @State private var isRegisteringEngine: Bool = false

    // Graphics Library State
    @State private var selectedReleaseBackend: GraphicsBackend = .dxmt
    @State private var isShowingLocalArchiveForm: Bool = false
    @State private var localArchivePath: String = ""
    @State private var localArchiveBackend: GraphicsBackend = .dxmt
    @State private var localArchiveVersion: String = ""
    @State private var isImportingArchive: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("引擎与图形转译层版本库")
                            .font(.headline)
                        Text("引擎与外壳彻底解耦：自由管理多版本开源 Wine、DXMT 与 DXVK-macOS。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Picker("页面", selection: $activeTab) {
                    ForEach(EngineSettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(18)
            .background(.bar)

            Divider()

            switch activeTab {
            case .engines:
                enginesTabContent
            case .graphics:
                graphicsTabContent
            }

            Divider()

            HStack {
                Button("打开环境预检清单…") {
                    dismiss()
                    viewModel.isShowingPreflightSheet = true
                }

                Spacer()

                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 740, idealWidth: 800, minHeight: 560, idealHeight: 640)
        .onAppear {
            activeTab = viewModel.engineSettingsInitialTab
            viewModel.reloadInstalledGraphicsPackages()
        }
    }

    // MARK: - Tab 1: Wine Engines

    private var enginesTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("已发现与已登记引擎 (\(viewModel.engines.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        Task {
                            await viewModel.refreshPreflight(autoPresentIfNotReady: false)
                        }
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isPerformingPreflight)

                    Button {
                        withAnimation {
                            isShowingCustomEngineForm.toggle()
                        }
                    } label: {
                        Label("手动登记自定义引擎…", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }

                if isShowingCustomEngineForm {
                    customEngineRegistrationCard
                }

                if viewModel.engines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("尚未检测到可用的本机 Wine 引擎")
                            .font(.subheadline.weight(.semibold))
                        Text("推荐通过 Homebrew 安装开源新 WoW64 引擎，或点击上方「手动登记自定义引擎…」绑定已有的 Wine.app / CrossOver.app：")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        let brewCmd = EngineManager.recommendedWineInstallCommand
                        HStack {
                            Text(brewCmd)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                            Button("复制命令") {
                                viewModel.copyToClipboard(brewCmd, label: "Homebrew 安装命令")
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.engines) { engine in
                            engineCard(engine)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var customEngineRegistrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登记本机自定义 Wine 目录或 .app 捆绑包")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                TextField("引擎根目录或 .app 路径", text: $customEnginePath)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                Button("浏览…") {
                    browseCustomEngineRoot()
                }
            }

            HStack(spacing: 8) {
                TextField("显示名称（如：Wine Staging 11.2）", text: $customEngineName)
                    .textFieldStyle(.roundedBorder)

                Button("取消") {
                    isShowingCustomEngineForm = false
                }

                Button("探测并登记") {
                    submitCustomEngine()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isRegisteringEngine
                        || customEngineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || customEnginePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func engineCard(_ engine: WineEngine) -> some View {
        let isDefault = viewModel.activeDefaultEngine?.id == engine.id

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(isDefault ? Color.accentColor : .secondary)

                Text(engine.name)
                    .font(.subheadline.weight(.semibold))

                if isDefault {
                    PillBadge(text: "全局默认", systemImage: "star.fill", tint: .accentColor)
                }

                PillBadge(text: engine.source.displayName, tint: .secondary)

                Spacer()

                if engine.isQuarantined {
                    Button {
                        Task {
                            await viewModel.removeQuarantineForEngine(engine)
                        }
                    } label: {
                        Label("解除隔离属性", systemImage: "lock.open.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }

                if !isDefault {
                    Button("设为默认") {
                        Task {
                            await viewModel.setDefaultEngine(engine.id)
                        }
                    }
                    .controlSize(.small)
                }

                Button {
                    let revealPath = AppViewModel.enclosingAppBundlePath(for: engine.rootPath) ?? engine.rootPath
                    let url = URL(fileURLWithPath: revealPath)
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("在 Finder 中显示引擎目录")

                if engine.source == .custom {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.unregisterCustomEngine(engine)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .help("移除自定义登记（不会删除磁盘上的引擎文件）")
                }
            }

            Text("版本：\(engine.version) · 路径：\(engine.rootPath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            EngineCapabilityPills(engine: engine)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDefault ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.16),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Tab 2: Graphics Layer Library

    private var graphicsTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                installedGraphicsSection
                remoteReleasesSection
            }
            .padding(20)
        }
    }

    private var installedGraphicsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地已安装图形转译层 (\(viewModel.installedGraphicsPackages.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    withAnimation {
                        isShowingLocalArchiveForm.toggle()
                    }
                } label: {
                    Label("导入本地 .tar.gz / .tar.xz…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
            }

            if isShowingLocalArchiveForm {
                localArchiveImportCard
            }

            if viewModel.installedGraphicsPackages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("尚未安装任何外部图形转译层包")
                        .font(.subheadline.weight(.medium))
                    Text("WineD3D 已随 Wine 引擎内置可用；如需畅玩 DX10/DX11 现代游戏，可在下方从官方 GitHub Releases 一键拉取 DXMT 或 DXVK-macOS。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.installedGraphicsPackages) { pkg in
                        installedPackageCard(pkg)
                    }
                }
            }
        }
    }

    private var localArchiveImportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("从本地归档导入图形转译层")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                TextField("选择 .tar.gz / .tar.xz / .tgz 归档文件", text: $localArchivePath)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                Button("选择文件…") {
                    browseLocalGraphicsArchive()
                }
            }

            HStack(spacing: 8) {
                Picker("后端类型", selection: $localArchiveBackend) {
                    Text("DXMT").tag(GraphicsBackend.dxmt)
                    Text("DXVK-macOS").tag(GraphicsBackend.dxvk)
                }
                .frame(width: 180)

                TextField("版本号（如 v0.80）", text: $localArchiveVersion)
                    .textFieldStyle(.roundedBorder)

                Button("取消") {
                    isShowingLocalArchiveForm = false
                }

                Button("校验并导入") {
                    submitLocalArchiveImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isImportingArchive
                        || localArchivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || localArchiveVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func installedPackageCard(_ pkg: GraphicsLayerPackage) -> some View {
        let usingBottles = viewModel.bottles.filter {
            $0.config.graphicsBackend != .wined3d && $0.config.graphicsLayerVersionID == pkg.id
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PillBadge(
                    text: pkg.backend.displayName,
                    systemImage: pkg.backend.systemImage,
                    tint: pkg.backend.badgeTint
                )

                Text(pkg.version)
                    .font(.subheadline.weight(.semibold))

                PillBadge(text: pkg.format.displayName, tint: .teal)

                if pkg.isDXVKMissingDXGI {
                    PillBadge(text: "缺 dxgi.dll", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                        .help(pkg.missingDXGIWarning?.explanation ?? "")
                }

                if !usingBottles.isEmpty {
                    PillBadge(
                        text: "使用中: \(usingBottles.map(\.name).joined(separator: ", "))",
                        tint: .green
                    )
                }

                Spacer()

                Button {
                    let url = URL(fileURLWithPath: pkg.installPath)
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("在 Finder 中查看解压后的图形包目录")

                Button(role: .destructive) {
                    viewModel.removeGraphicsPackage(pkg)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .disabled(!usingBottles.isEmpty)
                .help(usingBottles.isEmpty ? "删除此图形包" : "该图形包正被容器使用，请先切换容器后端后再删除")
            }

            HStack(spacing: 6) {
                Text("包含 DLL：")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(pkg.containedDLLs, id: \.self) { dll in
                    Text("\(dll).dll")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 4))
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Official GitHub Releases Section

    private var remoteReleasesSection: some View {
        let releases = viewModel.remoteReleases[selectedReleaseBackend] ?? []
        let isFetching = viewModel.isFetchingRemoteReleases[selectedReleaseBackend] == true
        let repoLabel = selectedReleaseBackend == .dxmt ? "3Shain/dxmt" : "Gcenx/DXVK-macOS"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("官方 GitHub Releases 在线获取")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("仓库", selection: $selectedReleaseBackend) {
                    Text("DXMT (3Shain/dxmt)").tag(GraphicsBackend.dxmt)
                    Text("DXVK-macOS (Gcenx/DXVK-macOS)").tag(GraphicsBackend.dxvk)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .labelsHidden()

                Spacer()

                Button {
                    Task {
                        await viewModel.fetchRemoteReleases(for: selectedReleaseBackend)
                    }
                } label: {
                    Label(
                        isFetching ? "拉取中…" : "拉取最新 Releases",
                        systemImage: "cloud.fill"
                    )
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(isFetching)
            }

            if isFetching && releases.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在连接 GitHub API 查询 \(repoLabel) 发行版…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .center)
            } else if releases.isEmpty {
                Text("点击右上角「拉取最新 Releases」从 GitHub (`\(repoLabel)`) 获取官方开源构建包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    ForEach(releases) { release in
                        remoteReleaseRow(release)
                    }
                }
            }
        }
    }

    private func remoteReleaseRow(_ release: RemoteGraphicsRelease) -> some View {
        let installedPackage = viewModel.installedGraphicsPackages.first { release.isInstalled(in: [$0]) }
        let isAlreadyInstalled = installedPackage != nil
        let progress = viewModel.activeDownloadProgress[release.id]

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(release.assetName)
                        .font(.subheadline.weight(.semibold))
                    PillBadge(text: release.tagName, tint: release.backend.badgeTint)
                    PillBadge(text: release.format.displayName, tint: .teal)
                    // 未下载的资产没有 DLL 清单，只对已安装的包标注
                    if installedPackage?.isDXVKMissingDXGI == true {
                        PillBadge(text: "缺 dxgi.dll", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            .help(installedPackage?.missingDXGIWarning?.explanation ?? "")
                    }
                    if let size = release.sizeBytes {
                        PillBadge(text: VermouthFormatters.formatBytes(size), tint: .secondary)
                    }
                }

                if let published = release.publishedAt {
                    Text("发布于 \(VermouthFormatters.formatDateTime(published))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let progress {
                HStack(spacing: 8) {
                    if progress >= 0 {
                        ProgressView(value: progress, total: 1.0)
                            .frame(width: 90)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("下载中…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if isAlreadyInstalled {
                PillBadge(text: "已安装", systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                Button {
                    Task {
                        await viewModel.downloadAndInstallRelease(release)
                    }
                } label: {
                    Label("下载并安装", systemImage: "arrow.down.circle.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func browseCustomEngineRoot() {
        let panel = NSOpenPanel()
        panel.title = "选择 Wine 引擎根目录或 .app 捆绑包"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        customEnginePath = url.path
        if customEngineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customEngineName = url.deletingPathExtension().lastPathComponent
        }
    }

    private func submitCustomEngine() {
        isRegisteringEngine = true
        Task {
            let ok = await viewModel.registerCustomEngine(
                name: customEngineName,
                rootPath: customEnginePath
            )
            isRegisteringEngine = false
            if ok {
                customEngineName = ""
                customEnginePath = ""
                isShowingCustomEngineForm = false
            }
        }
    }

    private func browseLocalGraphicsArchive() {
        let panel = NSOpenPanel()
        panel.title = "选择 DXMT 或 DXVK-macOS 归档 (.tar.gz / .tar.xz)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true

        let archiveTypes: [UTType] = [
            .gzip,
            .archive,
            UTType(filenameExtension: "xz"),
            UTType(filenameExtension: "tgz"),
        ].compactMap { $0 }
        if !archiveTypes.isEmpty {
            panel.allowedContentTypes = archiveTypes
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        localArchivePath = url.path
        let fileName = url.lastPathComponent.lowercased()
        if fileName.contains("dxvk") {
            localArchiveBackend = .dxvk
        } else if fileName.contains("dxmt") {
            localArchiveBackend = .dxmt
        }

        if localArchiveVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            localArchiveVersion = Self.inferVersionFromArchiveName(url.lastPathComponent)
        }
    }

    private func submitLocalArchiveImport() {
        isImportingArchive = true
        Task {
            let ok = await viewModel.importLocalGraphicsArchive(
                at: localArchivePath,
                backend: localArchiveBackend,
                version: localArchiveVersion
            )
            isImportingArchive = false
            if ok {
                localArchivePath = ""
                localArchiveVersion = ""
                isShowingLocalArchiveForm = false
            }
        }
    }

    private static func inferVersionFromArchiveName(_ fileName: String) -> String {
        var cleaned = fileName
        for suffix in [".tar.gz", ".tar.xz", ".tgz"] {
            if cleaned.lowercased().hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }
        for prefix in ["dxmt-", "dxvk-", "DXMT-", "DXVK-macOS-", "dxvk-macos-"] {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }
        return cleaned.isEmpty ? "custom" : cleaned
    }
}
#endif
