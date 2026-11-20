#if os(macOS)
import AppKit
import SwiftUI
import VermouthCore

struct SnapshotSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("配置与存档快照管理 (.vsnap)")
                        .font(.headline)
                    Text("回滚前自动执行 SHA-256 完整性校验、路径穿越检查与保底快照，并通过同目录原子替换保护存档安全。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            if let bottle = viewModel.selectedBottle {
                SnapshotWorkspaceContent(viewModel: viewModel, bottle: bottle)
            } else {
                ContentUnavailableView(
                    "未选择容器",
                    systemImage: "shippingbox",
                    description: Text("请先在左侧边栏选择一个容器以管理快照。")
                )
            }

            Divider()

            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 540, idealHeight: 620)
    }
}

struct SnapshotWorkspaceContent: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle

    @State private var targetLabel: String = ""
    @State private var targetPath: String = ""
    @State private var snapshotNote: String = ""
    @State private var selectedAppID: String = "__auto__"
    @State private var pendingRollbackRecord: SnapshotRecord?

    private var records: [SnapshotRecord] {
        viewModel.snapshots(for: bottle.id)
    }

    private var combinedTargets: [SnapshotTarget] {
        var list: [SnapshotTarget] = []
        var seenPaths = Set<String>()

        for app in bottle.apps {
            for target in app.snapshotTargets {
                let norm = URL(fileURLWithPath: target.path).standardizedFileURL.path
                if seenPaths.insert(norm).inserted {
                    list.append(target)
                }
            }
        }

        for record in records {
            let norm = URL(fileURLWithPath: record.sourcePath).standardizedFileURL.path
            if seenPaths.insert(norm).inserted {
                list.append(
                    SnapshotTarget(
                        id: record.targetID,
                        label: record.label,
                        path: record.sourcePath
                    )
                )
            }
        }

        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                newSnapshotCard
                configuredTargetsSection
                recordsHistorySection
            }
            .padding(20)
        }
        .onAppear {
            viewModel.reloadSnapshots(for: bottle.id)
        }
        .confirmationDialog(
            "确认执行原子回滚？",
            isPresented: Binding(
                get: { pendingRollbackRecord != nil },
                set: { if !$0 { pendingRollbackRecord = nil } }
            ),
            presenting: pendingRollbackRecord
        ) { record in
            Button("校验 SHA-256 并安全回滚") {
                viewModel.rollbackSnapshot(record, in: bottle)
                pendingRollbackRecord = nil
            }
            Button("取消", role: .cancel) {
                pendingRollbackRecord = nil
            }
        } message: { record in
            Text(
                "将目标路径「\(record.sourcePath)」还原至 \(VermouthFormatters.formatDateTime(record.createdAt)) 的快照状态。系统会先自动为当前状态生成一份保底快照，再执行原子替换。"
            )
        }
    }

    // MARK: - Create Snapshot Card

    private var newSnapshotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建配置或存档快照")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                TextField("目标目录或单文件路径（如存档目录、ini 配置）", text: $targetPath)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)

                Button("选择目录/文件…") {
                    browseTarget()
                }
            }

            HStack(spacing: 8) {
                TextField("快照标签（如：装 Mod 前原版存档）", text: $targetLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                TextField("备注（可选，如：CLEO 4 安装前备份）", text: $snapshotNote)
                    .textFieldStyle(.roundedBorder)

                if !bottle.apps.isEmpty {
                    Picker("关联程序", selection: $selectedAppID) {
                        Text("自动关联").tag("__auto__")
                        ForEach(bottle.apps) { app in
                            Text(app.name).tag(app.id.uuidString)
                        }
                    }
                    .frame(width: 160)
                }

                Button {
                    createNewSnapshotNow()
                } label: {
                    Label("立即创建快照", systemImage: "camera.metering.matrix")
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Configured Targets

    @ViewBuilder
    private var configuredTargetsSection: some View {
        if !combinedTargets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("已登记的快捷备份目标 (\(combinedTargets.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(combinedTargets) { target in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundStyle(.teal)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.label)
                                .font(.subheadline.weight(.medium))
                            Text(target.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button {
                            let url = resolveTargetURL(target.path)
                            if FileManager.default.fileExists(atPath: url.path) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } else {
                                viewModel.openDriveC(for: bottle)
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .controlSize(.small)
                        .help("在 Finder 中定位")

                        Button {
                            _ = viewModel.createSnapshot(
                                for: target,
                                note: snapshotNote,
                                in: bottle
                            )
                        } label: {
                            Label("拍下新快照", systemImage: "plus.circle")
                        }
                        .controlSize(.small)

                        if bottle.apps.contains(where: { app in
                            app.snapshotTargets.contains(where: { $0.id == target.id })
                        }) {
                            Button(role: .destructive) {
                                viewModel.removeSnapshotTarget(targetID: target.id, in: bottle)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                            .help("从程序关联目标中移除（不删除已有快照归档）")
                        }
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

    // MARK: - Snapshot Records History

    private var recordsHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("时间戳快照历史 (\(records.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.reloadSnapshots(for: bottle.id)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前容器尚无任何快照归档")
                        .font(.subheadline.weight(.medium))
                    Text("在打画质补丁、安装 ASI/CLEO Mod 或修改注册表/配置文件前，建议先为游戏目录或存档目录创建一份快照。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    ForEach(records) { record in
                        snapshotRecordCard(record)
                    }
                }
            }
        }
    }

    private func snapshotRecordCard(_ record: SnapshotRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: record.isDirectory ? "archivebox.fill" : "doc.zipper")
                    .foregroundStyle(Color.accentColor)

                Text(record.label)
                    .font(.subheadline.weight(.semibold))

                PillBadge(
                    text: record.isDirectory ? "目录 (\(record.fileCount) 个文件)" : "单文件",
                    tint: .teal
                )

                PillBadge(
                    text: VermouthFormatters.formatBytes(record.totalBytes),
                    tint: .secondary
                )

                Spacer()

                Text(VermouthFormatters.formatDateTime(record.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = record.note, !note.isEmpty {
                Text("备注：\(note)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 8) {
                Text("源路径：\(record.sourcePath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    viewModel.copyToClipboard(record.sha256, label: "SHA-256 校验值")
                } label: {
                    Text("SHA-256: \(String(record.sha256.prefix(12)))…")
                        .font(.caption2.monospaced())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("点击复制完整 SHA-256: \(record.sha256)")
            }

            HStack {
                Spacer()
                Button {
                    pendingRollbackRecord = record
                } label: {
                    Label("安全原子回滚…", systemImage: "arrow.uturn.backward.circle.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    viewModel.deleteSnapshot(record, in: bottle)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func browseTarget() {
        let panel = NSOpenPanel()
        panel.title = "选择要备份的配置/存档目录或文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let driveCURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
        if FileManager.default.fileExists(atPath: driveCURL.path) {
            panel.directoryURL = driveCURL
        } else {
            panel.directoryURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        targetPath = url.path
        if targetLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetLabel = url.lastPathComponent
        }
    }

    private func createNewSnapshotNow() {
        let trimmedPath = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

        let trimmedLabel = targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLabel = trimmedLabel.isEmpty
            ? URL(fileURLWithPath: trimmedPath).lastPathComponent
            : trimmedLabel

        let target = SnapshotTarget(label: effectiveLabel, path: trimmedPath)
        let attachUUID = UUID(uuidString: selectedAppID)
        if !bottle.apps.isEmpty {
            viewModel.addSnapshotTarget(target, attachToAppID: attachUUID, in: bottle)
        }

        if viewModel.createSnapshot(for: target, note: snapshotNote, in: bottle) != nil {
            snapshotNote = ""
        }
    }

    private func resolveTargetURL(_ rawPath: String) -> URL {
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }
        return URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent(rawPath)
    }
}
#endif
