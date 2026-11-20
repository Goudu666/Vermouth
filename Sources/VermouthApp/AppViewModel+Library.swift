#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers
import VermouthCore

// MARK: - Library Models

/// 程序库中的一张卡片：某个容器里固定的一个程序。普通模式下用户看不到「容器」，只看到程序。
struct LibraryItem: Identifiable, Sendable {
    let app: AppEntry
    let bottleID: UUID
    let bottleName: String

    var id: UUID { app.id }
}

/// 只用来驱动 `sheet(item:)` 的程序 ID 包装。
struct LibraryItemRef: Identifiable, Equatable, Sendable {
    let id: UUID
}

/// 当前是否有程序在准备或运行（同一时间只运行一个会话）。
enum LaunchActivity: Equatable, Sendable {
    case idle
    case preparing(appID: UUID?, message: String)
    case running(appID: UUID?, name: String)

    var isActive: Bool { self != .idle }

    var appID: UUID? {
        switch self {
        case .idle:
            return nil
        case let .preparing(appID, _), let .running(appID, _):
            return appID
        }
    }
}

/// 一次运行结束后值得告诉用户的结论（崩溃或有诊断问题）。
struct LaunchReport: Identifiable, Sendable {
    let id = UUID()
    let appID: UUID?
    let bottleID: UUID
    let programName: String
    let outcome: LaunchOutcome
    var findings: [DiagnosticFinding]
}

/// 用户刚拖进来、等待确认「安装」还是「直接添加」的文件。
struct PendingProgramFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let suggestedKind: ProgramFileKind
    let displayName: String
}

extension DiagnosticSeverity {
    var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }
}

// MARK: - Library Behaviour

extension AppViewModel {
    nonisolated static let advancedModeDefaultsKey = "vermouth.advancedMode"
    nonisolated private static let defaultBottleDefaultsKey = "vermouth.defaultBottleID"
    nonisolated static let defaultBottleName = "我的 Windows"

    /// 高级模式（容器 / 引擎 / 日志工作台）。界面用 `@AppStorage` 读写同一个键。
    var isAdvancedMode: Bool {
        UserDefaults.standard.bool(forKey: Self.advancedModeDefaultsKey)
    }

    /// 所有容器里固定的程序，按名称排序（不按最近运行排序，免得卡片位置跳来跳去）。
    var libraryItems: [LibraryItem] {
        bottles
            .flatMap { bottle in
                bottle.apps.filter(\.isPinned).map { LibraryItem(app: $0, bottleID: bottle.id, bottleName: bottle.name) }
            }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    func libraryItem(id: UUID) -> LibraryItem? {
        libraryItems.first { $0.id == id }
    }

    func bottle(id: UUID) -> Bottle? {
        bottles.first { $0.id == id }
    }

    var setupSteps: [SetupStep] {
        preflightReport.map(EnvironmentSetupPlanner.steps(for:)) ?? []
    }

    var requiredSetupSteps: [SetupStep] {
        setupSteps.filter(\.isRequired)
    }

    /// 预检还没跑完时视为就绪，避免启动瞬间闪一下「需要准备环境」。
    var isEnvironmentReady: Bool {
        guard let preflightReport else { return true }
        return EnvironmentSetupPlanner.isReady(preflightReport)
    }

    func isRunning(_ item: LibraryItem) -> Bool {
        launchActivity.appID == item.id
    }

    // MARK: Default Environment

    /// 普通模式下所有程序默认装进同一个 Windows 环境；没有就自动创建（Win10 + 自动选择同步模式）。
    func ensureDefaultBottle() async -> Bottle? {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultBottleDefaultsKey),
           let id = UUID(uuidString: raw),
           let existing = bottle(id: id)
        {
            return existing
        }
        if let oldest = bottles.min(by: { $0.createdAt < $1.createdAt }) {
            rememberDefaultBottle(oldest)
            return oldest
        }

        guard let engine = activeDefaultEngine else {
            isShowingSetupSheet = true
            return nil
        }

        let created = await createBottle(
            name: Self.defaultBottleName,
            engineID: nil,
            windowsVersion: .win10,
            graphicsBackend: .wined3d,
            syncMode: engine.capabilities.supportsMSync ? .msync : .esync,
            enableChinese: true,
            initialRecipeID: nil,
            announce: false,
            initializingMessage: "第一次使用，正在准备 Windows 环境（约 1 分钟）…"
        )
        guard created, let bottle = bottles.first(where: { $0.name == Self.defaultBottleName }) ?? selectedBottle else {
            return nil
        }
        rememberDefaultBottle(bottle)
        return bottle
    }

    private func rememberDefaultBottle(_ bottle: Bottle) {
        UserDefaults.standard.set(bottle.id.uuidString, forKey: Self.defaultBottleDefaultsKey)
    }

    // MARK: Adding Programs

    func promptForProgramFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 Windows 程序或安装包"
        panel.message = "支持 .exe 和 .msi。安装包会被安装，免安装的游戏或软件会直接加入程序库。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        let types = ProgramFileClassifier.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = stageProgramFile(url)
    }

    /// 拖入 / 选择文件后先停一下，让用户确认是「安装」还是「直接添加」（默认按钮由文件名猜测）。
    @discardableResult
    func stageProgramFile(_ url: URL) -> Bool {
        guard let kind = ProgramFileClassifier.classify(fileName: url.lastPathComponent) else {
            return false
        }
        pendingProgramFile = PendingProgramFile(
            url: url,
            suggestedKind: kind,
            displayName: ProgramFileClassifier.suggestedDisplayName(forFileAt: url.path)
        )
        return true
    }

    func handleLibraryDrop(_ urls: [URL]) -> Bool {
        guard let first = urls.first(where: { ProgramFileClassifier.classify(fileName: $0.lastPathComponent) != nil }) else {
            return false
        }
        return stageProgramFile(first)
    }

    func confirmPendingProgram(_ pending: PendingProgramFile, as kind: ProgramFileKind) async {
        pendingProgramFile = nil
        guard let bottle = await ensureDefaultBottle() else { return }
        switch kind {
        case .application:
            addPortableProgram(at: pending.url, name: pending.displayName, in: bottle)
        case .installer:
            await installProgram(at: pending.url, displayName: pending.displayName, in: bottle)
        }
    }

    private func addPortableProgram(at url: URL, name: String, in bottle: Bottle) {
        let key = Self.canonicalExecutableKey(url.path, prefixPath: bottle.prefixPath)
        if bottle.apps.contains(where: { Self.canonicalExecutableKey($0.executablePath, prefixPath: bottle.prefixPath) == key }) {
            showBanner("「\(name)」已经在程序库里了")
            return
        }
        let entry = AppEntry(
            name: name,
            executablePath: url.path,
            arguments: [],
            workingDirectory: url.deletingLastPathComponent().path,
            isPinned: true
        )
        saveAppEntry(entry, in: bottle)
        showBanner("已添加「\(name)」，双击卡片即可启动")
    }

    private func installProgram(at url: URL, displayName: String, in bottle: Bottle) async {
        let before = (try? executableScanner.scan(prefixPath: bottle.prefixPath)) ?? []
        let bottleID = bottle.id
        selectedBottleID = bottleID
        await executeLaunchTarget(
            .installer(path: url.path),
            in: bottle,
            rescanAfterExit: true,
            activityName: "安装 \(displayName)",
            onExit: { [weak self] outcome in
                guard let self else { return }
                await self.adoptNewlyInstalledPrograms(before: before, bottleID: bottleID, outcome: outcome)
            }
        )
    }

    /// 安装程序结束后，把新出现的程序自动放进程序库。
    private func adoptNewlyInstalledPrograms(
        before: [DiscoveredExecutable],
        bottleID: UUID,
        outcome: LaunchOutcome
    ) async {
        guard var bottle = try? bottleStore.loadBottle(id: bottleID) else { return }
        let after = (try? executableScanner.scan(prefixPath: bottle.prefixPath)) ?? []
        let adoptable = InstalledProgramAdopter.programsToAdopt(before: before, after: after).filter { exec in
            !bottle.apps.contains { Self.canonicalExecutableKey($0.executablePath, prefixPath: bottle.prefixPath) == Self.canonicalExecutableKey(exec.executablePath, prefixPath: bottle.prefixPath) }
        }

        guard !adoptable.isEmpty else {
            if case .stopped = outcome { return }
            showBanner("安装程序已结束。没找到新程序的话，可以点「添加 › 查找已安装的程序」")
            return
        }

        for exec in adoptable {
            bottle.apps.append(
                AppEntry(
                    name: exec.name,
                    executablePath: exec.executablePath,
                    arguments: exec.arguments,
                    workingDirectory: exec.workingDirectory,
                    isPinned: true
                )
            )
        }
        bottle.updatedAt = VermouthJSON.currentTimestamp()
        do {
            try bottleStore.saveBottle(bottle)
            reloadBottlesFromDisk(preferredSelection: bottle.id)
            let names = adoptable.map { "「\($0.name)」" }.joined(separator: "、")
            showBanner("安装完成，已把\(names)加入程序库")
        } catch {
            presentError(error)
        }
    }

    /// 「查找已安装的程序」：扫描默认环境，列出还没加入程序库的程序。
    func openInstalledProgramsBrowser() async {
        guard let bottle = await ensureDefaultBottle() else { return }
        selectedBottleID = bottle.id
        await scanExecutables(for: bottle, silentIfUninitialized: true)
        isShowingInstalledProgramsSheet = true
    }

    // MARK: Launching

    func quickLaunch(_ item: LibraryItem) async {
        guard let bottle = bottle(id: item.bottleID) else { return }
        if case let .running(_, name) = launchActivity {
            errorAlertMessage = "「\(name)」还在运行。请先退出它，或在卡片上点「停止」，再启动其他程序。"
            return
        }
        guard !launchActivity.isActive else { return }
        guard resolvedEngine(for: bottle) != nil else {
            isShowingSetupSheet = true
            return
        }
        lastLaunchReport = nil
        selectedBottleID = bottle.id
        await launchApp(item.app, in: bottle)
    }

    /// 普通模式的「停止」：结束会话并静默关掉该环境里残留的 Windows 进程。
    func stopProgram(in bottleID: UUID?) async {
        stopActiveProcess()
        guard let bottleID, let bottle = bottle(id: bottleID), let engine = resolvedEngine(for: bottle) else { return }
        try? await wineRunner.killWineServer(for: bottle, engine: engine, force: false)
    }

    func renameLibraryItem(_ item: LibraryItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let bottle = bottle(id: item.bottleID) else { return }
        var entry = item.app
        entry.name = trimmed
        saveAppEntry(entry, in: bottle)
    }

    func removeFromLibrary(_ item: LibraryItem) {
        guard let bottle = bottle(id: item.bottleID) else { return }
        removeAppEntry(item.app, in: bottle)
    }

    func revealInFinder(_ item: LibraryItem) {
        guard let bottle = bottle(id: item.bottleID) else { return }
        let path = ProgramIconCache.resolveHostPath(item.app.executablePath, prefixPath: bottle.prefixPath)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func hostPath(for item: LibraryItem) -> String {
        guard let bottle = bottle(id: item.bottleID) else { return item.app.executablePath }
        return ProgramIconCache.resolveHostPath(item.app.executablePath, prefixPath: bottle.prefixPath)
    }

    // MARK: Environment Setup

    /// 一键准备环境：App 内能做的（解除隔离）直接做，其余合成一条脚本在「终端」里跑。
    func runEnvironmentSetup() async {
        let steps = setupSteps
        for step in steps where step.kind == .unquarantineEngine {
            if let engine = engines.first(where: { $0.id == step.engineID }) {
                await removeQuarantineForEngine(engine)
            }
        }

        guard let script = EnvironmentSetupPlanner.terminalScript(for: steps.filter(\.runsInTerminal)) else {
            await refreshPreflight()
            return
        }
        if openTerminalScript(script, fileName: "vermouth-setup.command") {
            showBanner("已在「终端」中开始准备环境，完成后回到这里会自动刷新")
        }
    }

    /// 把脚本写成 `.command` 并交给「终端」打开；用户能看到每一步在做什么。
    @discardableResult
    func openTerminalScript(_ script: String, fileName: String) -> Bool {
        do {
            let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
            try Data(script.utf8).write(to: scriptURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: scriptURL.path
            )
            if NSWorkspace.shared.open(scriptURL) {
                return true
            }
            presentError(
                VermouthError.ioError(
                    operation: "openTerminal",
                    path: scriptURL.path,
                    underlyingDescription: "macOS 未能拉起终端打开 .command 脚本"
                )
            )
        } catch {
            presentError(error)
        }
        return false
    }

    // MARK: Problem Assistant

    func quickFix(_ fix: DiagnosticQuickFix, findingID: String, bottleID: UUID) async {
        selectedBottleID = bottleID
        await performQuickFix(fix, findingID: findingID)
        lastLaunchReport?.findings.removeAll { $0.id == findingID }
    }
}
#endif
