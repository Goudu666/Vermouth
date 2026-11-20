import Foundation

/// 兼容配方管理引擎：
/// - 合并加载内置配方（`VermouthResourceLocator`）与用户目录配方（`$VERMOUTH_HOME/recipes/`）
/// - 支持按路径或配方 ID 加载、社区配方文件导入、生成应用风险与副作用计划以及脱敏导出
public final class RecipeEngine: RecipeManaging, Sendable {
    private static let blockedExportEnvKeys: Set<String> = [
        "HOME",
        "USER",
        "LOGNAME",
        "USERNAME",
        "SHELL",
        "PATH",
        "PWD",
        "OLDPWD",
        "TMPDIR",
        "TEMP",
        "TMP",
        "WINEPREFIX",
        "WINELOADER",
        "WINESERVER",
        "WINEDLLPATH",
        "WINEDLLPATH_PREPEND",
        "VERMOUTH_HOME",
        "SSH_AUTH_SOCK",
        "DISPLAY",
        "XAUTHORITY",
    ]

    private static let sensitiveExportKeySubstrings: [String] = [
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PASSWD",
        "API_KEY",
        "APIKEY",
        "AUTH",
        "CREDENTIAL",
        "PRIVATE_KEY",
        "COOKIE",
        "SESSION",
    ]

    private let paths: VermouthPaths

    public init(paths: VermouthPaths) {
        self.paths = paths
    }

    // MARK: - RecipeManaging

    public func listRecipes() throws -> [Recipe] {
        var byID: [String: Recipe] = [:]

        // 1. 内置只读配方
        for fileURL in VermouthResourceLocator.builtInRecipeFiles() {
            let recipe = try readAndValidateRecipe(at: fileURL)
            byID[recipe.id] = recipe
        }

        // 2. 用户导入配方（同 ID 覆写内置配方）
        for fileURL in userRecipeFiles() {
            let recipe = try readAndValidateRecipe(at: fileURL)
            byID[recipe.id] = recipe
        }

        return byID.values.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    public func loadRecipe(from filePath: String) throws -> Recipe {
        let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VermouthError.recipeNotFound(identifier: filePath)
        }

        let expanded = Self.expandTilde(trimmed)
        let candidateURL = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDir),
           !isDir.boolValue
        {
            return try readAndValidateRecipe(at: candidateURL)
        }

        // 若不是磁盘文件路径，则按配方 ID 从已发现配方中查找
        let allRecipes = try listRecipes()
        if let matched = allRecipes.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }

        throw VermouthError.recipeNotFound(identifier: filePath)
    }

    /// 校验社区配方 JSON 文件并原子导入到 `$VERMOUTH_HOME/recipes/<id>.recipe.json`。
    @discardableResult
    public func importRecipeFile(at sourcePath: String) throws -> Recipe {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VermouthError.invalidRecipe(path: sourcePath, reason: "配方文件路径不能为空")
        }

        let expanded = Self.expandTilde(trimmed)
        let sourceURL = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir),
              !isDir.boolValue
        else {
            throw VermouthError.recipeNotFound(identifier: sourcePath)
        }

        let recipe = try readAndValidateRecipe(at: sourceURL)
        let safeFileStem = Self.sanitizeRecipeFileStem(recipe.id)
        let destinationURL = paths.recipesDirectory
            .appendingPathComponent("\(safeFileStem).recipe.json", isDirectory: false)
        try VermouthJSON.writeAtomically(recipe, to: destinationURL)
        return recipe
    }

    public func planApplication(
        of recipe: Recipe,
        to bottle: Bottle,
        engine: WineEngine?
    ) -> RecipeApplicationPlan {
        var updated = bottle

        let backendChanged = updated.config.graphicsBackend != recipe.recommendedBackend
        let windowsVersionChanged = updated.config.windowsVersion != recipe.recommendedWindowsVersion
        let syncModeChanged = updated.config.syncMode != recipe.recommendedSyncMode
        let willEnableChinese = recipe.chineseLocalizationSuggested && !updated.config.locale.chineseLocalizationEnabled

        updated.config.windowsVersion = recipe.recommendedWindowsVersion
        updated.config.graphicsBackend = recipe.recommendedBackend
        if backendChanged {
            updated.config.graphicsLayerVersionID = nil
        }
        updated.config.syncMode = recipe.recommendedSyncMode

        if recipe.chineseLocalizationSuggested {
            updated.config.locale.chineseLocalizationEnabled = true
        }

        // 合并 DLL 覆写（按规范化小写 dllName 匹配更新或追加，保留现有无关覆写）
        var mergedOverrides = updated.config.dllOverrides
        for recipeOverride in recipe.dllOverrides {
            if let existingIndex = mergedOverrides.firstIndex(where: { $0.dllName == recipeOverride.dllName }) {
                mergedOverrides[existingIndex] = recipeOverride
            } else {
                mergedOverrides.append(recipeOverride)
            }
        }
        updated.config.dllOverrides = mergedOverrides

        // 合并环境变量
        for (key, value) in recipe.environmentVariables {
            updated.config.environmentVariables[key] = value
        }

        if let debugChannels = recipe.wineDebugChannels?.trimmingCharacters(in: .whitespacesAndNewlines),
           !debugChannels.isEmpty
        {
            updated.config.wineDebugChannels = debugChannels
        }

        updated.appliedRecipeID = recipe.id
        updated.updatedAt = VermouthJSON.currentTimestamp()

        let requiresGraphicsBackendChange = backendChanged
        let requiresRegistrySync = windowsVersionChanged || willEnableChinese
        let requiresWineServerRestart = syncModeChanged || backendChanged || windowsVersionChanged || willEnableChinese

        var warnings: [DiagnosticFinding] = []
        if let engine {
            if recipe.targetArchitecture == .x86_32 && !engine.capabilities.supports32Bit {
                warnings.append(
                    DiagnosticFinding(
                        id: "recipe-arch32-mismatch-\(recipe.id)",
                        category: .architectureMismatch,
                        severity: .error,
                        title: "当前引擎不支持该配方要求的 32 位架构",
                        explanation: "配方「\(recipe.name)」面向 32 位 x86 Windows 程序，但当前引擎「\(engine.name)」不支持 32 位执行。",
                        suggestion: "请切换至支持 WoW64 / 32 位的 Wine 引擎（例如 Wine Stable 11+ 或 Wine Crossover）。",
                        quickFix: .select32BitCapableEngine
                    )
                )
            } else if recipe.targetArchitecture == .x86_64 && !engine.capabilities.supports64Bit {
                warnings.append(
                    DiagnosticFinding(
                        id: "recipe-arch64-mismatch-\(recipe.id)",
                        category: .architectureMismatch,
                        severity: .error,
                        title: "当前引擎不支持该配方要求的 64 位架构",
                        explanation: "配方「\(recipe.name)」面向 64 位 x86_64 Windows 程序，但当前引擎「\(engine.name)」不支持 64 位执行。",
                        suggestion: "请选择支持 64 位架构的 Wine 引擎。"
                    )
                )
            }

            if recipe.recommendedBackend == .dxmt && !engine.capabilities.supportsWineDLLPathPrepend {
                warnings.append(
                    DiagnosticFinding(
                        id: "recipe-dxmt-unsupported-\(recipe.id)",
                        category: .graphicsInitFailed,
                        severity: .warning,
                        title: "当前引擎不支持 DXMT 所需的 WINEDLLPATH_PREPEND",
                        explanation: "配方「\(recipe.name)」推荐使用 DXMT，但引擎「\(engine.name)」不支持 WINEDLLPATH_PREPEND（L-001），无法零拷贝加载 DXMT builtin 包。",
                        suggestion: "请更换支持 WINEDLLPATH_PREPEND 的 Wine 引擎，或在应用后切换为 DXVK-macOS (nativeDLLs) / WineD3D。",
                        quickFix: .switchGraphicsBackend(.dxvk)
                    )
                )
            }

            if recipe.recommendedSyncMode == .msync && !engine.capabilities.supportsMSync {
                warnings.append(
                    DiagnosticFinding(
                        id: "recipe-msync-unsupported-\(recipe.id)",
                        category: .syncMismatch,
                        severity: .warning,
                        title: "当前引擎未检测到 MSync 支持",
                        explanation: "配方「\(recipe.name)」推荐使用 MSync 同步模式，但引擎「\(engine.name)」二进制中未探测到 WINEMSYNC 标记。",
                        suggestion: "如启动异常，可在容器设置中将同步模式切换为 ESync 或关闭。"
                    )
                )
            }
        }

        return RecipeApplicationPlan(
            updatedBottle: updated,
            requiresGraphicsBackendChange: requiresGraphicsBackendChange,
            requiresRegistrySync: requiresRegistrySync,
            requiresWineServerRestart: requiresWineServerRestart,
            warnings: warnings
        )
    }

    public func exportSanitizedRecipe(
        from bottle: Bottle,
        id: String,
        name: String,
        summary: String
    ) -> Recipe {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        let sanitizedEnv = Self.sanitizeEnvironmentVariables(
            bottle.config.environmentVariables,
            prefixPath: bottle.prefixPath
        )

        let inferredArchitecture = Self.inferTargetArchitecture(from: bottle)
        let debugChannels = bottle.config.wineDebugChannels.trimmingCharacters(in: .whitespacesAndNewlines)

        return Recipe(
            schemaVersion: Recipe.currentSchemaVersion,
            id: trimmedID.isEmpty ? "custom-recipe" : trimmedID,
            name: trimmedName.isEmpty ? bottle.name : trimmedName,
            summary: trimmedSummary,
            targetArchitecture: inferredArchitecture,
            recommendedWindowsVersion: bottle.config.windowsVersion,
            recommendedBackend: bottle.config.graphicsBackend,
            recommendedSyncMode: bottle.config.syncMode,
            chineseLocalizationSuggested: bottle.config.locale.chineseLocalizationEnabled,
            dllOverrides: bottle.config.dllOverrides,
            environmentVariables: sanitizedEnv,
            wineDebugChannels: debugChannels.isEmpty ? nil : debugChannels,
            notes: [],
            knownIssues: []
        )
    }

    // MARK: - Private Helpers

    private func userRecipeFiles() -> [URL] {
        let directory = paths.recipesDirectory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            return []
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { url in
                let lower = url.lastPathComponent.lowercased()
                guard lower.hasSuffix(".recipe.json") || lower.hasSuffix(".json") else {
                    return false
                }
                var isEntryDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isEntryDir) && !isEntryDir.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readAndValidateRecipe(at url: URL) throws -> Recipe {
        let recipe: Recipe
        do {
            recipe = try VermouthJSON.read(Recipe.self, from: url)
        } catch let error as VermouthError {
            switch error {
            case let .decodingFailed(_, path, underlying):
                throw VermouthError.invalidRecipe(path: path ?? url.path, reason: underlying)
            default:
                throw error
            }
        }

        guard recipe.schemaVersion <= Recipe.currentSchemaVersion else {
            throw VermouthError.unsupportedSchemaVersion(
                found: recipe.schemaVersion,
                supported: Recipe.currentSchemaVersion,
                path: url.path
            )
        }

        guard !recipe.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VermouthError.invalidRecipe(path: url.path, reason: "配方 id 不能为空")
        }

        guard !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VermouthError.invalidRecipe(path: url.path, reason: "配方 name 不能为空")
        }

        return recipe
    }

    private static func sanitizeEnvironmentVariables(
        _ environment: [String: String],
        prefixPath: String
    ) -> [String: String] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path.lowercased()
        let normalizedPrefix = URL(fileURLWithPath: prefixPath).standardizedFileURL.path.lowercased()

        var sanitized: [String: String] = [:]
        for (key, value) in environment {
            let upperKey = key.uppercased()
            if blockedExportEnvKeys.contains(upperKey) {
                continue
            }
            if sensitiveExportKeySubstrings.contains(where: { upperKey.contains($0) }) {
                continue
            }

            let lowerValue = value.lowercased()
            if lowerValue.contains("/users/")
                || lowerValue.contains("/home/")
                || lowerValue.contains("/volumes/")
                || lowerValue.contains(#"c:\users\"#)
                || (!homePath.isEmpty && lowerValue.contains(homePath))
                || (!normalizedPrefix.isEmpty && lowerValue.contains(normalizedPrefix))
            {
                continue
            }

            sanitized[key] = value
        }
        return sanitized
    }

    private static func inferTargetArchitecture(from bottle: Bottle) -> PEArchitecture {
        for app in bottle.apps {
            let candidatePath: String
            if app.executablePath.hasPrefix("/") {
                candidatePath = app.executablePath
            } else {
                candidatePath = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
                    .appendingPathComponent(app.executablePath)
                    .standardizedFileURL.path
            }
            if let inspection = try? PEInspector.inspect(fileAtPath: candidatePath),
               inspection.architecture != .unknown
            {
                return inspection.architecture
            }
        }
        return bottle.config.windowsVersion == .winxp ? .x86_32 : .x86_64
    }

    private static func sanitizeRecipeFileStem(_ rawID: String) -> String {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.map { char -> Character in
            if char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "_" || char == ".") {
                return char
            }
            return "-"
        }
        let result = String(allowed)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "recipe" : result
    }

    private static func expandTilde(
        _ rawPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if rawPath == "~" {
            return homeDirectory.standardizedFileURL.path
        }
        if rawPath.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(rawPath.dropFirst(2)))
                .standardizedFileURL.path
        }
        return rawPath
    }
}
