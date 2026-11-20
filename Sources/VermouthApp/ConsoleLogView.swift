#if os(macOS)
import SwiftUI
import VermouthCore

struct ConsoleLogView: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle

    @State private var searchText: String = ""
    @State private var selectedStreamFilter: StreamFilter = .all
    @State private var autoScroll: Bool = true
    @State private var isShowingCustomDebugPopover: Bool = false
    @State private var customDebugDraft: String = ""

    private enum StreamFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case stderr = "stderr"
        case stdout = "stdout"
        case system = "系统"

        var id: Self { self }
    }

    private var isLoadDllEnabled: Bool {
        bottle.config.wineDebugChannels.localizedCaseInsensitiveContains("+loaddll")
    }

    private var filteredLines: [LogLine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.liveLogLines.filter { line in
            switch selectedStreamFilter {
            case .all:
                break
            case .stderr:
                if line.stream != .stderr { return false }
            case .stdout:
                if line.stream != .stdout { return false }
            case .system:
                if line.stream != .system { return false }
            }
            if query.isEmpty {
                return true
            }
            return line.text.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            consoleToolbar
            Divider()

            if !viewModel.diagnosticFindings.isEmpty {
                diagnosticsBannerList
                Divider()
            }

            if viewModel.liveLogLines.isEmpty {
                ContentUnavailableView {
                    Label("暂无实时运行日志", systemImage: "terminal")
                } description: {
                    Text(
                        "在「程序」页面启动应用、运行安装包或拉起 winecfg 后，子进程的 stdout / stderr 将在此流式呈现，并自动匹配常见闪退原因。"
                    )
                } actions: {
                    Button {
                        viewModel.openBottleLogsDirectory(for: bottle)
                    } label: {
                        Label("在 Finder 中查看历史日志文件", systemImage: "folder")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logStreamList
            }
        }
        .onAppear {
            customDebugDraft = bottle.config.wineDebugChannels
        }
        .onChange(of: bottle.config.wineDebugChannels) { _, newValue in
            customDebugDraft = newValue
        }
    }

    // MARK: - Toolbar

    private var consoleToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if viewModel.isRunningProcess {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("运行中")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12), in: Capsule())
                } else {
                    PillBadge(text: "空闲", systemImage: "pause.circle", tint: .secondary)
                }

                Menu {
                    Button {
                        setDebugChannels("-all,err+all")
                    } label: {
                        if bottle.config.wineDebugChannels == "-all,err+all" {
                            Label("精简错误通道 (-all,err+all)", systemImage: "checkmark")
                        } else {
                            Text("精简错误通道 (-all,err+all)")
                        }
                    }

                    Button {
                        setDebugChannels("-all,err+all,+loaddll")
                    } label: {
                        if bottle.config.wineDebugChannels == "-all,err+all,+loaddll" {
                            Label("DLL 加载追踪 (-all,err+all,+loaddll)", systemImage: "checkmark")
                        } else {
                            Text("DLL 加载追踪 (-all,err+all,+loaddll)")
                        }
                    }

                    Button {
                        setDebugChannels("warn+all,err+all")
                    } label: {
                        if bottle.config.wineDebugChannels == "warn+all,err+all" {
                            Label("警告与错误 (warn+all,err+all)", systemImage: "checkmark")
                        } else {
                            Text("警告与错误 (warn+all,err+all)")
                        }
                    }

                    Divider()

                    Button("自定义 WINEDEBUG…") {
                        customDebugDraft = bottle.config.wineDebugChannels
                        isShowingCustomDebugPopover = true
                    }
                } label: {
                    Label(
                        isLoadDllEnabled ? "调试: +loaddll" : "调试: \(bottle.config.wineDebugChannels)",
                        systemImage: "slider.horizontal.below.rectangle"
                    )
                }
                .controlSize(.small)
                .popover(isPresented: $isShowingCustomDebugPopover) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("自定义容器 WINEDEBUG 通道")
                            .font(.subheadline.weight(.semibold))
                        TextField("-all,err+all", text: $customDebugDraft)
                            .font(.caption.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                        HStack {
                            Spacer()
                            Button("应用") {
                                setDebugChannels(customDebugDraft)
                                isShowingCustomDebugPopover = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                }

                Picker("通道", selection: $selectedStreamFilter) {
                    ForEach(StreamFilter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .labelsHidden()

                TextField("过滤日志关键字…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 220)

                Spacer()

                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button {
                    let joined = filteredLines.map { line in
                        "[\(VermouthFormatters.formatConsoleTime(line.timestamp))] [\(line.stream.rawValue)] \(line.text)"
                    }.joined(separator: "\n")
                    viewModel.copyToClipboard(joined, label: "运行日志")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(filteredLines.isEmpty)

                Button {
                    viewModel.openBottleLogsDirectory(for: bottle)
                } label: {
                    Label("日志目录", systemImage: "folder")
                }
                .controlSize(.small)

                Button {
                    viewModel.clearConsoleLogs()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(viewModel.liveLogLines.isEmpty && viewModel.diagnosticFindings.isEmpty)

                if viewModel.isRunningProcess {
                    Button(role: .destructive) {
                        viewModel.stopActiveProcess()
                    } label: {
                        Label("停止进程", systemImage: "xmark.circle.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.killWineServer(for: bottle, force: false)
                        }
                    } label: {
                        Label("wineserver -k", systemImage: "stop.circle")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Diagnostic Cards

    private var diagnosticsBannerList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                ForEach(viewModel.diagnosticFindings) { finding in
                    DiagnosticFindingCard(
                        finding: finding,
                        onQuickFix: { fix in
                            Task {
                                await viewModel.performQuickFix(fix, findingID: finding.id)
                            }
                        },
                        onDismiss: {
                            viewModel.dismissDiagnosticFinding(id: finding.id)
                        }
                    )
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 230)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Streaming Monospaced Log View

    private var logStreamList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filteredLines) { line in
                        logLineRow(line)
                            .id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: viewModel.liveLogLines.last?.id) { _, lastID in
                guard autoScroll, let lastID else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func logLineRow(_ line: LogLine) -> some View {
        let (badgeLabel, badgeTint): (String, Color) = {
            switch line.stream {
            case .stdout:
                return ("OUT", .secondary)
            case .stderr:
                return ("ERR", .orange)
            case .system:
                return ("SYS", .blue)
            }
        }()

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(VermouthFormatters.formatConsoleTime(line.timestamp))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            Text(badgeLabel)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(badgeTint)
                .frame(width: 28, alignment: .leading)

            Text(line.text)
                .font(.caption.monospaced())
                .foregroundStyle(line.stream == .system ? Color.accentColor : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setDebugChannels(_ channels: String) {
        let trimmed = channels.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? "-all,err+all" : trimmed
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                config.wineDebugChannels = effective
            }
        }
    }
}
#endif
