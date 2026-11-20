import Foundation

/// 容器生命周期与持久化存储实现（`bottle.json` 原子读写、克隆、外部前缀安全导入与删除隔离）。
///
/// 严格遵循：
/// - **L-005**：当 `bottle.isExternalPrefix == true` 时，删除容器严禁删除外部 `WINEPREFIX` 目录。
/// - **L-011**：所有持久化均通过 `VermouthJSON`（含毫秒 ISO-8601 + POSIX 原子替换）。
public final class BottleStore: BottleManaging, Sendable {
    public let paths: VermouthPaths
    private let lock = NSLock()

    public init(paths: VermouthPaths = VermouthPaths()) {
        self.paths = paths
    }

    // MARK: - BottleManaging

    public func listBottles() throws -> [Bottle] {
        try withLock {
            try listBottlesUnlocked()
        }
    }

    public func loadBottle(id: UUID) throws -> Bottle {
        try withLock {
            try loadBottleUnlocked(id: id)
        }
    }

    public func createBottle(
        name: String,
        engineID: String? = nil,
        initialConfig: BottleConfig? = nil
    ) throws -> Bottle {
        try withLock {
            let trimmedName = try validateBottleName(name)
            try paths.ensureBaseDirectories()

            let id = UUID()
            let now = VermouthJSON.currentTimestamp()
            let bottleDir = paths.bottleDirectory(id: id)
            let prefixURL = paths.bottlePrefixURL(id: id)
            let fileManager = FileManager.default

            do {
                try createDirectory(at: bottleDir, fileManager: fileManager)
                try createDirectory(at: prefixURL, fileManager: fileManager)
                try createDirectory(at: paths.bottleSnapshotsDirectory(id: id), fileManager: fileManager)
                try createDirectory(at: paths.bottleLogsDirectory(id: id), fileManager: fileManager)
                try createDirectory(at: paths.bottleBackupsDirectory(id: id), fileManager: fileManager)

                var config = initialConfig ?? BottleConfig()
                if let engineID {
                    config.engineID = engineID
                }

                let bottle = Bottle(
                    schemaVersion: Bottle.currentSchemaVersion,
                    id: id,
                    name: trimmedName,
                    createdAt: now,
                    updatedAt: now,
                    prefixPath: prefixURL.path,
                    isExternalPrefix: false,
                    config: config,
                    apps: [],
                    appliedRecipeID: nil
                )

                try VermouthJSON.writeAtomically(bottle, to: paths.bottleConfigURL(id: id))
                return bottle
            } catch {
                try? fileManager.removeItem(at: bottleDir)
                throw error
            }
        }
    }

    public func saveBottle(_ bottle: Bottle) throws {
        try withLock {
            let trimmedName = try validateBottleName(bottle.name)

            let configURL = paths.bottleConfigURL(id: bottle.id)
            let fileManager = FileManager.default
            guard regularFileExists(at: configURL, fileManager: fileManager) else {
                throw VermouthError.bottleNotFound(identifier: bottle.id.uuidString)
            }

            guard bottle.schemaVersion <= Bottle.currentSchemaVersion else {
                throw VermouthError.unsupportedSchemaVersion(
                    found: bottle.schemaVersion,
                    supported: Bottle.currentSchemaVersion,
                    path: configURL.path
                )
            }

            var normalizedBottle = bottle
            normalizedBottle.name = trimmedName
            try VermouthJSON.writeAtomically(normalizedBottle, to: configURL)
        }
    }

    public func renameBottle(id: UUID, newName: String) throws -> Bottle {
        try withLock {
            let trimmedName = try validateBottleName(newName)
            var bottle = try loadBottleUnlocked(id: id)
            bottle.name = trimmedName
            bottle.updatedAt = VermouthJSON.currentTimestamp()
            try VermouthJSON.writeAtomically(bottle, to: paths.bottleConfigURL(id: id))
            return bottle
        }
    }

    public func cloneBottle(id: UUID, newName: String) throws -> Bottle {
        try withLock {
            let trimmedName = try validateBottleName(newName)
            let source = try loadBottleUnlocked(id: id)
            try paths.ensureBaseDirectories()

            let fileManager = FileManager.default
            let sourcePrefixURL = URL(fileURLWithPath: source.prefixPath, isDirectory: true).standardizedFileURL
            // 解析顶层源前缀符号链接，确保复制的是真实目录内容而非指向外部的符号链接（B-7）
            let resolvedSourcePrefixURL = sourcePrefixURL.resolvingSymlinksInPath().standardizedFileURL
            guard directoryExists(at: resolvedSourcePrefixURL, fileManager: fileManager) else {
                throw VermouthError.invalidPrefixPath(
                    path: sourcePrefixURL.path,
                    reason: "源容器 WINEPREFIX 目录不存在，无法克隆"
                )
            }

            let newID = UUID()
            let now = VermouthJSON.currentTimestamp()
            let newBottleDir = paths.bottleDirectory(id: newID)
            let newPrefixURL = paths.bottlePrefixURL(id: newID)
            let newBackupsDir = paths.bottleBackupsDirectory(id: newID)

            guard !isPath(newPrefixURL.path, insideOrEqualTo: resolvedSourcePrefixURL.path) else {
                throw VermouthError.invalidPrefixPath(
                    path: resolvedSourcePrefixURL.path,
                    reason: "目标容器目录位于源 WINEPREFIX 目录内部，禁止递归复制"
                )
            }

            do {
                try createDirectory(at: newBottleDir, fileManager: fileManager)
                try createDirectory(at: paths.bottleSnapshotsDirectory(id: newID), fileManager: fileManager)
                try createDirectory(at: paths.bottleLogsDirectory(id: newID), fileManager: fileManager)

                // APFS 上 FileManager.copyItem 会自动利用 copy-on-write 克隆目录
                try copyItem(from: resolvedSourcePrefixURL, to: newPrefixURL, fileManager: fileManager)

                let sourceGraphicsState = paths.bottleGraphicsStateURL(id: source.id)
                if fileManager.fileExists(atPath: sourceGraphicsState.path) {
                    try copyItem(
                        from: sourceGraphicsState,
                        to: paths.bottleGraphicsStateURL(id: newID),
                        fileManager: fileManager
                    )
                }

                let sourceBackupsDir = paths.bottleBackupsDirectory(id: source.id)
                let resolvedSourceBackupsDir = sourceBackupsDir.resolvingSymlinksInPath().standardizedFileURL
                if directoryExists(at: resolvedSourceBackupsDir, fileManager: fileManager),
                   !isPath(newBackupsDir.path, insideOrEqualTo: resolvedSourceBackupsDir.path)
                {
                    try copyItem(from: resolvedSourceBackupsDir, to: newBackupsDir, fileManager: fileManager)
                } else {
                    try createDirectory(at: newBackupsDir, fileManager: fileManager)
                }

                let rewrittenApps = source.apps.map { entry in
                    rewriteAppEntryPaths(
                        entry,
                        fromPrefix: sourcePrefixURL.path,
                        toPrefix: newPrefixURL.path
                    )
                }

                let cloned = Bottle(
                    schemaVersion: Bottle.currentSchemaVersion,
                    id: newID,
                    name: trimmedName,
                    createdAt: now,
                    updatedAt: now,
                    prefixPath: newPrefixURL.path,
                    isExternalPrefix: false,
                    config: source.config,
                    apps: rewrittenApps,
                    appliedRecipeID: source.appliedRecipeID
                )

                try VermouthJSON.writeAtomically(cloned, to: paths.bottleConfigURL(id: newID))
                return cloned
            } catch {
                try? fileManager.removeItem(at: newBottleDir)
                throw error
            }
        }
    }

    public func importExistingPrefix(
        name: String,
        sourcePrefixPath: String,
        copyFiles: Bool = false
    ) throws -> Bottle {
        try withLock {
            let trimmedName = try validateBottleName(name)
            let fileManager = FileManager.default
            let sourcePrefixURL = try validateImportablePrefix(sourcePrefixPath, fileManager: fileManager)

            try paths.ensureBaseDirectories()

            let newID = UUID()
            let now = VermouthJSON.currentTimestamp()
            let newBottleDir = paths.bottleDirectory(id: newID)
            let managedPrefixURL = paths.bottlePrefixURL(id: newID)

            // 复制导入时先解析顶层符号链接并阻断父目录向子目录的递归复制（B-7）
            let resolvedSourcePrefixURL = sourcePrefixURL.resolvingSymlinksInPath().standardizedFileURL
            if copyFiles {
                guard !isPath(managedPrefixURL.path, insideOrEqualTo: resolvedSourcePrefixURL.path) else {
                    throw VermouthError.invalidPrefixPath(
                        path: resolvedSourcePrefixURL.path,
                        reason: "目标容器目录位于源 WINEPREFIX 目录内部，禁止递归复制"
                    )
                }
            }

            do {
                try createDirectory(at: newBottleDir, fileManager: fileManager)
                try createDirectory(at: paths.bottleSnapshotsDirectory(id: newID), fileManager: fileManager)
                try createDirectory(at: paths.bottleLogsDirectory(id: newID), fileManager: fileManager)
                try createDirectory(at: paths.bottleBackupsDirectory(id: newID), fileManager: fileManager)

                let finalPrefixPath: String
                let isExternal: Bool

                if copyFiles {
                    try copyItem(from: resolvedSourcePrefixURL, to: managedPrefixURL, fileManager: fileManager)
                    finalPrefixPath = managedPrefixURL.path
                    isExternal = false
                } else {
                    // 引用模式：严格标记 isExternalPrefix = true，避免删除容器时误删用户外部 WINEPREFIX（L-005）
                    finalPrefixPath = sourcePrefixURL.path
                    isExternal = true
                }

                let bottle = Bottle(
                    schemaVersion: Bottle.currentSchemaVersion,
                    id: newID,
                    name: trimmedName,
                    createdAt: now,
                    updatedAt: now,
                    prefixPath: finalPrefixPath,
                    isExternalPrefix: isExternal,
                    config: BottleConfig(),
                    apps: [],
                    appliedRecipeID: nil
                )

                try VermouthJSON.writeAtomically(bottle, to: paths.bottleConfigURL(id: newID))
                return bottle
            } catch {
                try? fileManager.removeItem(at: newBottleDir)
                throw error
            }
        }
    }

    public func deleteBottle(id: UUID, removePrefixFiles: Bool = true) throws {
        try withLock {
            let bottle = try loadBottleUnlocked(id: id)
            let fileManager = FileManager.default
            let bottleDir = paths.bottleDirectory(id: id).standardizedFileURL
            let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true).standardizedFileURL

            if bottle.isExternalPrefix {
                // 关键 L-005 保护：外部引用前缀绝不允许删除 bottle.prefixPath（无论 removePrefixFiles 为何值）。
                if isPath(prefixURL.path, insideOrEqualTo: bottleDir.path) {
                    try removeMetadataOnly(for: id, fileManager: fileManager)
                } else {
                    try removeItemIfExists(at: bottleDir, fileManager: fileManager)
                }
            } else if removePrefixFiles {
                try removeItemIfExists(at: bottleDir, fileManager: fileManager)
            } else {
                // 保留受管 prefix/ 目录，仅删除 Vermouth 元数据与日志/快照/备份。
                try removeMetadataOnly(for: id, fileManager: fileManager)
            }
        }
    }

    // MARK: - Convenience Lookup

    /// 按 UUID 优先、其次按名称精确匹配（优先大小写敏感，再回退大小写不敏感）查找容器。
    public func findBottle(nameOrID: String) throws -> Bottle {
        try withLock {
            let query = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw VermouthError.bottleNotFound(identifier: nameOrID)
            }

            if let uuid = UUID(uuidString: query) {
                let configURL = paths.bottleConfigURL(id: uuid)
                if FileManager.default.fileExists(atPath: configURL.path) {
                    return try loadBottleUnlocked(id: uuid)
                }
            }

            let bottles = try listBottlesUnlocked()
            if let exactMatch = bottles.first(where: { $0.name == query }) {
                return exactMatch
            }
            if let caseInsensitiveMatch = bottles.first(where: {
                $0.name.caseInsensitiveCompare(query) == .orderedSame
            }) {
                return caseInsensitiveMatch
            }

            throw VermouthError.bottleNotFound(identifier: nameOrID)
        }
    }

    // MARK: - Unlocked Core Helpers

    private func listBottlesUnlocked() throws -> [Bottle] {
        let fileManager = FileManager.default
        let bottlesDir = paths.bottlesDirectory
        guard directoryExists(at: bottlesDir, fileManager: fileManager) else {
            return []
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: bottlesDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VermouthError.ioError(
                operation: "contentsOfDirectory",
                path: bottlesDir.path,
                underlyingDescription: error.localizedDescription
            )
        }

        var bottles: [Bottle] = []
        for entry in entries {
            guard directoryExists(at: entry, fileManager: fileManager) else {
                continue
            }
            let configURL = entry.appendingPathComponent("bottle.json", isDirectory: false)
            guard regularFileExists(at: configURL, fileManager: fileManager) else {
                continue
            }

            let bottle = try VermouthJSON.read(Bottle.self, from: configURL)
            guard bottle.schemaVersion <= Bottle.currentSchemaVersion else {
                throw VermouthError.unsupportedSchemaVersion(
                    found: bottle.schemaVersion,
                    supported: Bottle.currentSchemaVersion,
                    path: configURL.path
                )
            }
            bottles.append(bottle)
        }

        bottles.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return bottles
    }

    private func loadBottleUnlocked(id: UUID) throws -> Bottle {
        let configURL = paths.bottleConfigURL(id: id)
        let fileManager = FileManager.default
        guard regularFileExists(at: configURL, fileManager: fileManager) else {
            throw VermouthError.bottleNotFound(identifier: id.uuidString)
        }

        let bottle = try VermouthJSON.read(Bottle.self, from: configURL)
        guard bottle.schemaVersion <= Bottle.currentSchemaVersion else {
            throw VermouthError.unsupportedSchemaVersion(
                found: bottle.schemaVersion,
                supported: Bottle.currentSchemaVersion,
                path: configURL.path
            )
        }
        return bottle
    }

    // MARK: - Validation & Path Helpers

    private func validateBottleName(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r")
        else {
            throw VermouthError.invalidBottleName(rawName)
        }
        return trimmed
    }

    private func validateImportablePrefix(
        _ rawPath: String,
        fileManager: FileManager
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VermouthError.invalidPrefixPath(path: rawPath, reason: "WINEPREFIX 路径不能为空")
        }

        let expanded = expandTilde(trimmed, homeDirectory: fileManager.homeDirectoryForCurrentUser)
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw VermouthError.invalidPrefixPath(path: url.path, reason: "目录不存在")
        }
        guard isDir.boolValue else {
            throw VermouthError.invalidPrefixPath(path: url.path, reason: "指定路径不是目录")
        }

        let driveCExists = directoryExists(
            at: url.appendingPathComponent("drive_c", isDirectory: true),
            fileManager: fileManager
        )
        let systemRegExists = regularFileExists(
            at: url.appendingPathComponent("system.reg", isDirectory: false),
            fileManager: fileManager
        )
        let userRegExists = regularFileExists(
            at: url.appendingPathComponent("user.reg", isDirectory: false),
            fileManager: fileManager
        )
        let userDefRegExists = regularFileExists(
            at: url.appendingPathComponent("userdef.reg", isDirectory: false),
            fileManager: fileManager
        )

        guard driveCExists || systemRegExists || userRegExists || userDefRegExists else {
            throw VermouthError.invalidPrefixPath(
                path: url.path,
                reason: "目录缺少 drive_c 或 Wine 注册表文件（system.reg / user.reg），不是有效的 WINEPREFIX"
            )
        }

        return url
    }

    private func rewriteAppEntryPaths(
        _ entry: AppEntry,
        fromPrefix oldPrefix: String,
        toPrefix newPrefix: String
    ) -> AppEntry {
        var updated = entry
        updated.executablePath = rewritePrefixPath(
            entry.executablePath,
            fromPrefix: oldPrefix,
            toPrefix: newPrefix
        )
        if let workingDir = entry.workingDirectory {
            updated.workingDirectory = rewritePrefixPath(
                workingDir,
                fromPrefix: oldPrefix,
                toPrefix: newPrefix
            )
        }
        updated.snapshotTargets = entry.snapshotTargets.map { target in
            var updatedTarget = target
            updatedTarget.path = rewritePrefixPath(
                target.path,
                fromPrefix: oldPrefix,
                toPrefix: newPrefix
            )
            return updatedTarget
        }
        return updated
    }

    private func rewritePrefixPath(
        _ rawPath: String,
        fromPrefix oldPrefix: String,
        toPrefix newPrefix: String
    ) -> String {
        guard rawPath.hasPrefix("/") else {
            return rawPath
        }

        let normalizedNew = URL(fileURLWithPath: newPrefix).standardizedFileURL.path

        if let rewritten = rewriteIfMatching(
            candidatePath: URL(fileURLWithPath: rawPath).standardizedFileURL.path,
            oldPrefixPath: URL(fileURLWithPath: oldPrefix).standardizedFileURL.path,
            newPrefixPath: normalizedNew
        ) {
            return rewritten
        }

        let resolvedCandidate = resolveSymlinksResiliently(rawPath)
        let resolvedOld = resolveSymlinksResiliently(oldPrefix)
        if let rewritten = rewriteIfMatching(
            candidatePath: resolvedCandidate,
            oldPrefixPath: resolvedOld,
            newPrefixPath: normalizedNew
        ) {
            return rewritten
        }

        return rawPath
    }

    private func rewriteIfMatching(
        candidatePath: String,
        oldPrefixPath: String,
        newPrefixPath: String
    ) -> String? {
        if candidatePath == oldPrefixPath {
            return newPrefixPath
        }
        let oldBoundary = oldPrefixPath.hasSuffix("/") ? oldPrefixPath : oldPrefixPath + "/"
        guard candidatePath.hasPrefix(oldBoundary) else {
            return nil
        }
        let relativeSuffix = String(candidatePath.dropFirst(oldBoundary.count))
        if newPrefixPath.hasSuffix("/") {
            return newPrefixPath + relativeSuffix
        }
        return newPrefixPath + "/" + relativeSuffix
    }

    private func isPath(_ candidate: String, insideOrEqualTo directory: String) -> Bool {
        let pairs: [(String, String)] = [
            (
                URL(fileURLWithPath: candidate).standardizedFileURL.path,
                URL(fileURLWithPath: directory).standardizedFileURL.path
            ),
            (
                resolveSymlinksResiliently(candidate),
                resolveSymlinksResiliently(directory)
            ),
        ]

        for (normalizedCandidate, normalizedDir) in pairs {
            if normalizedCandidate == normalizedDir {
                return true
            }
            let dirBoundary = normalizedDir.hasSuffix("/") ? normalizedDir : normalizedDir + "/"
            if normalizedCandidate.hasPrefix(dirBoundary) {
                return true
            }
        }
        return false
    }

    private func resolveSymlinksResiliently(_ path: String) -> String {
        let fileManager = FileManager.default
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var trailingComponents: [String] = []

        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            trailingComponents.append(current.lastPathComponent)
            current = parent
        }

        var resolved = current.resolvingSymlinksInPath().standardizedFileURL
        for component in trailingComponents.reversed() {
            resolved = resolved.appendingPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    private func removeMetadataOnly(for id: UUID, fileManager: FileManager) throws {
        let metadataItems: [URL] = [
            paths.bottleConfigURL(id: id),
            paths.bottleGraphicsStateURL(id: id),
            paths.bottleLogsDirectory(id: id),
            paths.bottleSnapshotsDirectory(id: id),
            paths.bottleBackupsDirectory(id: id),
        ]
        for item in metadataItems {
            try removeItemIfExists(at: item, fileManager: fileManager)
        }
    }

    private func expandTilde(_ path: String, homeDirectory: URL) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return homeDirectory.appendingPathComponent(suffix).path
        }
        return path
    }

    // MARK: - FileManager Wrappers & Locking

    private func directoryExists(at url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func regularFileExists(at url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private func createDirectory(at url: URL, fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VermouthError.ioError(
                operation: "createDirectory",
                path: url.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func copyItem(from source: URL, to destination: URL, fileManager: FileManager) throws {
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw VermouthError.ioError(
                operation: "copyItem",
                path: destination.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func removeItemIfExists(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw VermouthError.ioError(
                operation: "removeItem",
                path: url.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
