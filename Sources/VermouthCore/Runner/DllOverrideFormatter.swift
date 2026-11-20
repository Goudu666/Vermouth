import Foundation

/// `WINEDLLOVERRIDES` 解析结果，包含生效覆写清单、确定性环境变量字符串与冲突诊断警告。
public struct DllOverrideResolution: Equatable, Sendable {
    public let effectiveOverrides: [DllOverride]
    public let formattedValue: String
    public let warnings: [DiagnosticFinding]

    public init(
        effectiveOverrides: [DllOverride],
        formattedValue: String,
        warnings: [DiagnosticFinding] = []
    ) {
        self.effectiveOverrides = effectiveOverrides
        self.formattedValue = formattedValue
        self.warnings = warnings
    }
}

/// 统一合成并校验 `WINEDLLOVERRIDES` 环境变量的工具。
///
/// 严格遵循：
/// - **L-001**：`wineBuiltin` 图形包（如 DXMT v0.80 / DXVK builtin）对其包内 DLL 显式发出 `=b`
///   以屏蔽容器注册表残留 `n,b`，绝不输出 `n,b`；若用户配置冲突覆写则产出 `.dllOverrideConflict`
///   警告与 `.removeConflictingDllOverrides` 一键修复。
/// - **L-002**：`nativeDLLs` 图形包仅对包内实际存在的 `containedDLLs` 发出 `=n,b`，严禁硬编码 `d3d9`/`dxgi`。
/// - **L-011**：所有 DLL 名称统一规范为小写无 `.dll` 后缀，并按字典序确定性输出。
public enum DllOverrideFormatter: Sendable {
    /// 按优先级（图形层 → 容器级 → 单程序级）合成最终 `WINEDLLOVERRIDES` 并执行冲突检测。
    public static func resolve(
        graphicsBackend: GraphicsBackend,
        graphicsPackage: GraphicsLayerPackage?,
        bottleOverrides: [DllOverride],
        appOverrides: [DllOverride]
    ) -> DllOverrideResolution {
        var resolvedByName: [String: DllOverride] = [:]
        var builtinProtectedDLLs: Set<String> = []
        var activeBuiltinPackageID: String?

        // Layer 1: 图形转译层
        if graphicsBackend != .wined3d, let package = graphicsPackage {
            let normalizedPackageDLLs = package.containedDLLs
                .map { DllOverride.normalizeName($0) }
                .filter { !$0.isEmpty }

            switch package.format {
            case .wineBuiltin:
                activeBuiltinPackageID = package.id
                for dllName in normalizedPackageDLLs {
                    builtinProtectedDLLs.insert(dllName)
                    resolvedByName[dllName] = DllOverride(
                        dllName: dllName,
                        mode: .builtinOnly,
                        enabled: true,
                        note: "Managed by \(package.id) (wineBuiltin)"
                    )
                }

            case .nativeDLLs:
                for dllName in normalizedPackageDLLs {
                    resolvedByName[dllName] = DllOverride(
                        dllName: dllName,
                        mode: .nativeThenBuiltin,
                        enabled: true,
                        note: "Managed by \(package.id) (nativeDLLs)"
                    )
                }
            }
        }

        // Layer 2 (Bottle) -> Layer 3 (App): 仅合并已启用的覆写，App 级覆盖容器级同名 DLL
        var activeUserOverrides: [String: DllOverride] = [:]

        for override in bottleOverrides where override.enabled {
            let name = DllOverride.normalizeName(override.dllName)
            guard !name.isEmpty else { continue }
            activeUserOverrides[name] = DllOverride(
                dllName: name,
                mode: override.mode,
                enabled: true,
                note: override.note
            )
        }

        for override in appOverrides where override.enabled {
            let name = DllOverride.normalizeName(override.dllName)
            guard !name.isEmpty else { continue }
            activeUserOverrides[name] = DllOverride(
                dllName: name,
                mode: override.mode,
                enabled: true,
                note: override.note
            )
        }

        // 合并用户覆写，并检测与 wineBuiltin 图形包之间的冲突（L-001）
        var conflictingDLLs: Set<String> = []
        for (name, userOverride) in activeUserOverrides {
            if builtinProtectedDLLs.contains(name), userOverride.mode != .builtinOnly {
                conflictingDLLs.insert(name)
                // L-001 强制保留 =b，防止 n,b / n / b,n / disabled 破坏 DXMT/DXVK builtin 加载
                continue
            }
            resolvedByName[name] = userOverride
        }

        let effectiveOverrides = resolvedByName.values.sorted { lhs, rhs in
            lhs.dllName < rhs.dllName
        }

        let formattedValue = effectiveOverrides
            .map { "\($0.dllName)=\($0.mode.rawValue)" }
            .joined(separator: ";")

        var warnings: [DiagnosticFinding] = []
        if !conflictingDLLs.isEmpty {
            let sortedConflicts = conflictingDLLs.sorted()
            let joinedNames = sortedConflicts.joined(separator: ", ")
            let packageLabel = activeBuiltinPackageID ?? graphicsBackend.rawValue

            warnings.append(
                DiagnosticFinding(
                    id: "dll-override-conflict-\(sortedConflicts.joined(separator: ","))",
                    category: .dllOverrideConflict,
                    severity: .warning,
                    title: "DLL 覆写与 wineBuiltin 图形层冲突（\(joinedNames)）",
                    explanation: "当前容器使用 wineBuiltin 图形包 \(packageLabel)（通过 WINEDLLPATH_PREPEND 作为 Wine 内置 DLL 加载），需要强制使用 =b；用户已启用的覆写（\(joinedNames)）包含非 builtin 模式（如 n,b / n），会导致图形层加载失败。本次启动已自动强制维持 =b。",
                    suggestion: "建议移除容器或程序中针对 \(joinedNames) 的自定义 DLL 覆写，避免后续配置混淆。",
                    quickFix: .removeConflictingDllOverrides(sortedConflicts)
                )
            )
        }

        return DllOverrideResolution(
            effectiveOverrides: effectiveOverrides,
            formattedValue: formattedValue,
            warnings: warnings
        )
    }

    /// 将一组 `DllOverride`（仅已启用项）规范化、去重并按字典序格式化为 `WINEDLLOVERRIDES` 字符串。
    public static func format(_ overrides: [DllOverride]) -> String {
        var byName: [String: DllOverride] = [:]
        for override in overrides where override.enabled {
            let name = DllOverride.normalizeName(override.dllName)
            guard !name.isEmpty else { continue }
            byName[name] = DllOverride(
                dllName: name,
                mode: override.mode,
                enabled: true,
                note: override.note
            )
        }
        return byName.values
            .sorted { $0.dllName < $1.dllName }
            .map { "\($0.dllName)=\($0.mode.rawValue)" }
            .joined(separator: ";")
    }
}
