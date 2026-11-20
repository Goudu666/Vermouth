#if os(macOS)
import SwiftUI
import VermouthCore

struct AdvancedOverridesView: View {
    @Bindable var viewModel: AppViewModel
    let bottle: Bottle

    @State private var newDllName: String = ""
    @State private var newDllMode: DllOverrideMode = .nativeThenBuiltin
    @State private var newDllNote: String = ""

    @State private var newEnvKey: String = ""
    @State private var newEnvValue: String = ""

    private var resolution: DllOverrideResolution {
        viewModel.dllOverrideResolution(for: bottle)
    }

    private var graphicsManagedOverrides: [DllOverride] {
        guard bottle.config.graphicsBackend != .wined3d,
              let pkg = viewModel.resolvedGraphicsPackage(for: bottle)
        else {
            return []
        }
        let mode: DllOverrideMode = pkg.format == .wineBuiltin ? .builtinOnly : .nativeThenBuiltin
        return pkg.containedDLLs.sorted().map { dll in
            DllOverride(
                dllName: dll,
                mode: mode,
                enabled: true,
                note: "\(pkg.id) 自动管理"
            )
        }
    }

    private var sortedCustomEnvironmentPairs: [(key: String, value: String)] {
        bottle.config.environmentVariables.keys.sorted().compactMap { key in
            guard let val = bottle.config.environmentVariables[key] else { return nil }
            return (key: key, value: val)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                livePreviewAndConflictBanner
                presetChipsSection
                customDllOverridesSection
                customEnvironmentSection
                quickSnapshotsBridgeSection
            }
            .padding(20)
        }
    }

    // MARK: - Live WINEDLLOVERRIDES Preview & L-001 Conflict Protection

    private var livePreviewAndConflictBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时合成环境变量预览 (WINEDLLOVERRIDES)")
                        .font(.headline)
                    Text("按「图形层规则 → 容器级覆写 → 单程序级覆写」自动规范化合成；DXMT wineBuiltin 自动受 =b 保护。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let exportLine = "WINEDLLOVERRIDES=\"\(resolution.formattedValue)\""
                    viewModel.copyToClipboard(exportLine, label: "WINEDLLOVERRIDES")
                } label: {
                    Label("复制变量", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(resolution.formattedValue.isEmpty)
            }

            let previewString = resolution.formattedValue.isEmpty
                ? "(当前无自定义或外部图形层覆写，使用 Wine 默认行为)"
                : "WINEDLLOVERRIDES=\"\(resolution.formattedValue)\""

            Text(previewString)
                .font(.caption.monospaced())
                .foregroundStyle(resolution.formattedValue.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            if !graphicsManagedOverrides.isEmpty {
                HStack(spacing: 6) {
                    Text("图形层托管：")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(graphicsManagedOverrides) { item in
                        PillBadge(
                            text: "\(item.dllName)=\(item.mode.shortCode)",
                            systemImage: "lock.shield",
                            tint: .blue
                        )
                    }
                }
            }

            ForEach(resolution.warnings) { warning in
                DiagnosticFindingCard(finding: warning) { quickFix in
                    Task {
                        await viewModel.performQuickFix(quickFix, findingID: warning.id)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Preset Chips (ASI / CLEO / ModLoader / BepInEx)

    private var presetChipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("常见 Mod 钩子快捷预设")
                    .font(.headline)
                Text("点击芯片即可一键开启或关闭对应的 `native,builtin (n,b)` 覆写，无需翻找 `winecfg`。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(DllOverride.commonPresets) { preset in
                    let existing = bottle.config.dllOverrides.first { $0.dllName == preset.dllName }
                    let isEnabled = existing?.enabled == true

                    Button {
                        togglePreset(preset)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isEnabled ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(isEnabled ? Color.accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(preset.dllName)
                                        .font(.caption.monospaced().weight(.bold))
                                    Text("=n,b")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if let note = preset.note {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            isEnabled ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
                            in: .rect(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isEnabled ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Custom DLL Overrides Table

    private var customDllOverridesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("容器级自定义 DLL 覆写列表 (\(bottle.config.dllOverrides.count))")
                .font(.headline)

            VStack(spacing: 8) {
                if bottle.config.dllOverrides.isEmpty {
                    Text("当前尚未配置自定义 DLL 覆写。可点击上方快捷预设，或在下方输入任意 DLL 名称添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                } else {
                    ForEach(bottle.config.dllOverrides) { item in
                        HStack(spacing: 12) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { item.enabled },
                                    set: { newEnabled in
                                        setDllOverrideEnabled(dllName: item.dllName, enabled: newEnabled)
                                    }
                                )
                            )
                            .labelsHidden()

                            Text(item.dllName)
                                .font(.caption.monospaced().weight(.semibold))
                                .frame(width: 110, alignment: .leading)

                            Picker(
                                "",
                                selection: Binding(
                                    get: { item.mode },
                                    set: { newMode in
                                        setDllOverrideMode(dllName: item.dllName, mode: newMode)
                                    }
                                )
                            ) {
                                ForEach(DllOverrideMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)

                            if let note = item.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                removeDllOverride(dllName: item.dllName)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
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

                HStack(spacing: 8) {
                    TextField("DLL 名称（自动转小写并去除 .dll）", text: $newDllName)
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)

                    Picker("模式", selection: $newDllMode) {
                        ForEach(DllOverrideMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)

                    TextField("备注（可选）", text: $newDllNote)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        addCustomDllOverride()
                    } label: {
                        Label("添加覆写", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(DllOverride.normalizeName(newDllName).isEmpty)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Custom Environment Variables

    private var customEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("自定义环境变量 (\(sortedCustomEnvironmentPairs.count))")
                    .font(.headline)
                Text("容器内启动的所有程序与预注入终端均会合并此处的键值对。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let engine = viewModel.resolvedEngine(for: bottle),
               engine.capabilities.isNewWoW64,
               bottle.config.environmentVariables["WINEARCH"]?.lowercased() == "win32"
            {
                Label(
                    "L-004 提示：当前引擎为新 WoW64 单二进制模式，启动器会自动忽略 WINEARCH=win32 以避免破坏容器。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !sortedCustomEnvironmentPairs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(sortedCustomEnvironmentPairs, id: \.key) { pair in
                        HStack(spacing: 10) {
                            Text(pair.key)
                                .font(.caption.monospaced().weight(.semibold))
                                .frame(width: 180, alignment: .leading)

                            if !ShellQuoting.isValidPOSIXIdentifier(pair.key) {
                                PillBadge(text: "非标准标识符 (已通过 env 隔离)", tint: .orange)
                            }

                            Text(pair.value)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(role: .destructive) {
                                removeEnvironmentVariable(key: pair.key)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("变量名（如 DXMT_METAL_PRIVATE_HEAP）", text: $newEnvKey)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)

                TextField("变量值（如 1）", text: $newEnvValue)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)

                Button {
                    addEnvironmentVariable()
                } label: {
                    Label("设置变量", systemImage: "plus")
                }
                .disabled(
                    newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newEnvKey.contains("=")
                )
            }
        }
    }

    // MARK: - Quick Snapshot Bridge

    private var quickSnapshotsBridgeSection: some View {
        let count = viewModel.snapshots(for: bottle.id).count

        return HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 38, height: 38)
                .background(Color.teal.opacity(0.12), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("配置与存档时间点快照 (已有 \(count) 份)")
                    .font(.subheadline.weight(.semibold))
                Text("安装大型 Mod 或调整覆写前，可为游戏目录或存档目录拍下 SHA-256 校验快照，随时一键原子回滚。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.isShowingSnapshotSheet = true
            } label: {
                Label("管理快照与回滚…", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.teal.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Mutation Helpers

    private func togglePreset(_ preset: DllOverride) {
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                if let index = config.dllOverrides.firstIndex(where: { $0.dllName == preset.dllName }) {
                    config.dllOverrides[index].enabled.toggle()
                } else {
                    config.dllOverrides.append(preset)
                }
            }
        }
    }

    private func addCustomDllOverride() {
        let normalized = DllOverride.normalizeName(newDllName)
        guard !normalized.isEmpty else { return }
        let trimmedNote = newDllNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = DllOverride(
            dllName: normalized,
            mode: newDllMode,
            enabled: true,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        newDllName = ""
        newDllNote = ""

        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                if let index = config.dllOverrides.firstIndex(where: { $0.dllName == normalized }) {
                    config.dllOverrides[index] = entry
                } else {
                    config.dllOverrides.append(entry)
                }
            }
        }
    }

    private func setDllOverrideEnabled(dllName: String, enabled: Bool) {
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                if let index = config.dllOverrides.firstIndex(where: { $0.dllName == dllName }) {
                    config.dllOverrides[index].enabled = enabled
                }
            }
        }
    }

    private func setDllOverrideMode(dllName: String, mode: DllOverrideMode) {
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                if let index = config.dllOverrides.firstIndex(where: { $0.dllName == dllName }) {
                    config.dllOverrides[index].mode = mode
                }
            }
        }
    }

    private func removeDllOverride(dllName: String) {
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                config.dllOverrides.removeAll { $0.dllName == dllName }
            }
        }
    }

    private func addEnvironmentVariable() {
        let key = newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("="), !key.contains("\0") else { return }
        let val = newEnvValue
        newEnvKey = ""
        newEnvValue = ""

        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                config.environmentVariables[key] = val
            }
        }
    }

    private func removeEnvironmentVariable(key: String) {
        Task {
            await viewModel.updateBottleConfig(for: bottle) { config in
                config.environmentVariables.removeValue(forKey: key)
            }
        }
    }
}
#endif
