import Foundation

/// 图形转译层（`WineD3D` / `DXVK-macOS` / `DXMT`）下载、本地导入、校验、部署与回滚管理器。
///
/// 严格遵循：
/// - **L-001**：`wineBuiltin` 图形包仅允许部署到支持 `WINEDLLPATH_PREPEND` 的引擎，否则立即快速失败，绝不降级复制到 `system32`。
/// - **L-002**：`nativeDLLs` 图形包严格依据归档内实际存在的 DLL 清单进行备份、部署与覆写，绝不硬编码 `d3d9` / `dxgi`。
/// - **L-003**：切换图形层前安全终止该容器 `wineserver`（无运行进程视为安全 no-op）。
/// - **L-007**：`applyBackend` 采用值语义返回 `GraphicsApplyResult`，禁止 `async` + `inout`。
/// - **L-015**：`graphics/index.json` 读写统一经由 `GraphicsIndexStore` 单次原子 `mutate` 事务完成。
/// - **L-016**：解压前校验 `tar -tf` 退出码并阻断路径穿越与符号链接越狱。
public final class GraphicsStackManager: GraphicsStackManaging, Sendable {
    public let paths: VermouthPaths
    private let commandRunner: any CommandRunning
    private let httpFetcher: any HTTPFetching
    private let bottleStore: (any BottleManaging)?
    private let indexStore: GraphicsIndexStore
    private let deploymentLock = NSLock()

    private static let dxmtReleasesEndpoint = "https://api.github.com/repos/3Shain/dxmt/releases?per_page=10"
    private static let dxvkReleasesEndpoint = "https://api.github.com/repos/Gcenx/DXVK-macOS/releases?per_page=10"

    private static let knownLayoutDirectoryNames: Set<String> = [
        "x86_64-windows",
        "x86_64-unix",
        "i386-windows",
        "x64",
        "x32",
    ]

    public init(
        paths: VermouthPaths,
        commandRunner: any CommandRunning,
        httpFetcher: any HTTPFetching,
        bottleStore: (any BottleManaging)? = nil
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.httpFetcher = httpFetcher
        self.bottleStore = bottleStore
        self.indexStore = GraphicsIndexStore(indexURL: paths.graphicsIndexURL)
    }

    // MARK: - GraphicsStackManaging

    public func listInstalledPackages() throws -> [GraphicsLayerPackage] {
        try indexStore.loadPackages()
    }

    public func fetchAvailableReleases(for backend: GraphicsBackend) async throws -> [RemoteGraphicsRelease] {
        let endpoint: String
        switch backend {
        case .wined3d:
            return []
        case .dxmt:
            endpoint = Self.dxmtReleasesEndpoint
        case .dxvk:
            endpoint = Self.dxvkReleasesEndpoint
        }

        guard let url = URL(string: endpoint) else {
            throw VermouthError.networkRequestFailed(
                url: endpoint,
                statusCode: nil,
                reason: "无效的 GitHub Releases URL"
            )
        }

        let headers = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Vermouth/0.1.0",
        ]
        let data = try await httpFetcher.data(from: url, headers: headers)

        let rawReleases: [GitHubReleaseDTO]
        do {
            rawReleases = try VermouthJSON.decode([GitHubReleaseDTO].self, from: data)
        } catch {
            throw VermouthError.decodingFailed(
                type: "[GitHubReleaseDTO]",
                path: endpoint,
                underlyingDescription: error.localizedDescription
            )
        }

        var results: [RemoteGraphicsRelease] = []
        for release in rawReleases {
            if release.draft == true {
                continue
            }
            let archiveAssets = release.assets.filter { asset in
                let lowerName = asset.name.lowercased()
                return lowerName.hasSuffix(".tar.gz")
                    || lowerName.hasSuffix(".tar.xz")
                    || lowerName.hasSuffix(".tgz")
            }
            for asset in archiveAssets {
                let lowerName = asset.name.lowercased()
                guard let downloadURL = URL(string: asset.browserDownloadURL) else {
                    continue
                }
                let format: GraphicsArchiveFormat = lowerName.contains("builtin")
                    ? .wineBuiltin
                    : .nativeDLLs
                results.append(
                    RemoteGraphicsRelease(
                        backend: backend,
                        tagName: release.tagName,
                        version: Self.releaseAssetVersion(
                            tagName: release.tagName,
                            assetName: asset.name,
                            releaseHasMultipleArchives: archiveAssets.count > 1
                        ),
                        assetName: asset.name,
                        downloadURL: downloadURL,
                        sizeBytes: asset.size,
                        format: format,
                        publishedAt: release.publishedAt
                    )
                )
            }
        }

        return results
    }

    /// 同一 release 的多个归档资产（如 `-repack` 与 `-repack-builtin`、`-CrossOver`）必须得到不同的
    /// 包 id 与安装目录，否则后装的会原地覆盖先装的。
    ///
    /// - 只有一个归档、或资产名以 tag 结尾（主资产）：沿用 tag，保持已有包 id 不变；
    /// - 资产名包含 tag：tag + 资产名中 tag 之后的后缀（`v1.10.3-20230507-repack-builtin`）；
    /// - 其余：用去掉扩展名的资产名。
    static func releaseAssetVersion(
        tagName: String,
        assetName: String,
        releaseHasMultipleArchives: Bool
    ) -> String {
        guard releaseHasMultipleArchives else { return tagName }
        var baseName = assetName
        for suffix in [".tar.gz", ".tar.xz", ".tgz"] where baseName.lowercased().hasSuffix(suffix) {
            baseName = String(baseName.dropLast(suffix.count))
            break
        }
        if baseName.hasSuffix(tagName) {
            return tagName
        }
        if let tagRange = baseName.range(of: tagName) {
            return tagName + baseName[tagRange.upperBound...]
        }
        return baseName
    }

    public func installPackage(
        from release: RemoteGraphicsRelease,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> GraphicsLayerPackage {
        guard release.backend != .wined3d else {
            throw VermouthError.invalidGraphicsArchive(
                path: release.assetName,
                reason: "WineD3D 为 Wine 内置后端，无需安装外部图形包"
            )
        }

        try paths.ensureBaseDirectories()
        let fileManager = FileManager.default
        let downloadsDir = paths.graphicsDirectory.appendingPathComponent(".downloads", isDirectory: true)
        try createDirectory(at: downloadsDir, fileManager: fileManager)

        let safeAssetName = release.assetName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let tempArchiveURL = downloadsDir.appendingPathComponent(
            "\(UUID().uuidString)-\(safeAssetName)",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: tempArchiveURL)
        }

        try await httpFetcher.download(from: release.downloadURL, to: tempArchiveURL, progress: progress)

        return try await importArchiveInternal(
            at: tempArchiveURL.path,
            backend: release.backend,
            version: release.version,
            sourceURL: release.downloadURL.absoluteString
        )
    }

    public func importLocalArchive(
        at archivePath: String,
        backend: GraphicsBackend,
        version: String
    ) async throws -> GraphicsLayerPackage {
        try await importArchiveInternal(
            at: archivePath,
            backend: backend,
            version: version,
            sourceURL: nil
        )
    }

    public func removePackage(id: String, activeBottles: [Bottle]) throws {
        let referencing = activeBottles.filter { bottle in
            bottle.config.graphicsBackend != .wined3d
                && bottle.config.graphicsLayerVersionID == id
        }
        if !referencing.isEmpty {
            throw VermouthError.graphicsPackageInUse(
                id: id,
                bottleNames: referencing.map(\.name)
            )
        }

        let removedPackage: GraphicsLayerPackage = try indexStore.mutate { packages in
            guard let index = packages.firstIndex(where: { $0.id == id }) else {
                throw VermouthError.graphicsPackageNotFound(id: id)
            }
            return packages.remove(at: index)
        }

        let installURL = URL(fileURLWithPath: removedPackage.installPath, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installURL.path) {
            do {
                try fileManager.removeItem(at: installURL)
            } catch {
                throw VermouthError.ioError(
                    operation: "removeItem",
                    path: installURL.path,
                    underlyingDescription: error.localizedDescription
                )
            }
        }
    }

    public func deploymentState(for bottle: Bottle) throws -> GraphicsDeploymentRecord {
        try withDeploymentLock {
            try loadDeploymentRecordUnlocked(for: bottle)
        }
    }

    public func applyBackend(
        _ backend: GraphicsBackend,
        packageID: String?,
        to bottle: Bottle,
        engine: WineEngine
    ) async throws -> GraphicsApplyResult {
        // 1. 先校验目标包与引擎能力，任何不兼容都必须在触碰容器或终止进程前快速失败（L-001）
        let targetPackage: GraphicsLayerPackage?
        if backend == .wined3d {
            targetPackage = nil
        } else {
            let installed = try indexStore.loadPackages()
            let resolved: GraphicsLayerPackage?
            if let requestedID = packageID {
                resolved = installed.first { $0.id == requestedID && $0.backend == backend }
            } else {
                resolved = installed
                    .filter { $0.backend == backend }
                    .sorted { lhs, rhs in
                        if lhs.installedAt != rhs.installedAt {
                            return lhs.installedAt > rhs.installedAt
                        }
                        return lhs.id > rhs.id
                    }
                    .first
            }

            guard let package = resolved else {
                throw VermouthError.graphicsPackageNotFound(id: packageID ?? backend.rawValue)
            }

            let installURL = URL(fileURLWithPath: package.installPath, isDirectory: true).standardizedFileURL
            guard directoryExists(at: installURL, fileManager: FileManager.default) else {
                throw VermouthError.graphicsPackageNotFound(id: package.id)
            }

            // CRITICAL L-001: wineBuiltin 严禁在不支持 WINEDLLPATH_PREPEND 的引擎上降级复制进 system32
            if package.format == .wineBuiltin && !engine.capabilities.supportsWineDLLPathPrepend {
                throw VermouthError.engineMissingDLLPathPrepend(
                    engineName: engine.name,
                    packageID: package.id
                )
            }

            targetPackage = package
        }

        // 2. 切换图形层前先终止容器 wineserver（无运行进程视为安全 no-op，L-003）
        try await WineServerControl.kill(
            bottle: bottle,
            engine: engine,
            force: false,
            commandRunner: commandRunner
        )

        // 3. 同步执行旧部署回滚 + 新后端部署 + 状态落盘（锁不跨越 await）
        let applyOutcome: (record: GraphicsDeploymentRecord, warnings: [DiagnosticFinding], now: Date) =
            try withDeploymentLock {
                let fileManager = FileManager.default
                let previousRecord = try loadDeploymentRecordUnlocked(for: bottle)
                let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true).standardizedFileURL
                let backupsDir = paths.bottleBackupsDirectory(id: bottle.id).standardizedFileURL

                try rollbackPreviousDeploymentUnlocked(
                    previousRecord,
                    prefixURL: prefixURL,
                    backupsDir: backupsDir,
                    fileManager: fileManager
                )

                let now = VermouthJSON.currentTimestamp()
                var warnings: [DiagnosticFinding] = []
                let newRecord: GraphicsDeploymentRecord

                if backend == .wined3d {
                    newRecord = GraphicsDeploymentRecord(
                        schemaVersion: GraphicsDeploymentRecord.currentSchemaVersion,
                        backend: .wined3d,
                        packageID: nil,
                        strategy: .wined3dBuiltin,
                        deployedFiles: [],
                        backedUpFiles: [:],
                        updatedAt: now
                    )
                } else if let package = targetPackage {
                    switch package.format {
                    case .wineBuiltin:
                        let overrideResolution = DllOverrideFormatter.resolve(
                            graphicsBackend: backend,
                            graphicsPackage: package,
                            bottleOverrides: bottle.config.dllOverrides,
                            appOverrides: []
                        )
                        warnings.append(contentsOf: overrideResolution.warnings)

                        newRecord = GraphicsDeploymentRecord(
                            schemaVersion: GraphicsDeploymentRecord.currentSchemaVersion,
                            backend: backend,
                            packageID: package.id,
                            strategy: .wineDLLPathPrepend,
                            deployedFiles: [],
                            backedUpFiles: [:],
                            updatedAt: now
                        )

                    case .nativeDLLs:
                        if let missingDXGI = package.missingDXGIWarning {
                            warnings.append(missingDXGI)
                        }
                        let (deployedFiles, backedUpFiles) = try deployNativeDLLsUnlocked(
                            package: package,
                            prefixURL: prefixURL,
                            backupsDir: backupsDir,
                            fileManager: fileManager
                        )
                        newRecord = GraphicsDeploymentRecord(
                            schemaVersion: GraphicsDeploymentRecord.currentSchemaVersion,
                            backend: backend,
                            packageID: package.id,
                            strategy: .prefixCopyWithBackup,
                            deployedFiles: deployedFiles,
                            backedUpFiles: backedUpFiles,
                            updatedAt: now
                        )
                    }
                } else {
                    throw VermouthError.graphicsPackageNotFound(id: packageID ?? backend.rawValue)
                }

                try VermouthJSON.writeAtomically(newRecord, to: paths.bottleGraphicsStateURL(id: bottle.id))
                return (newRecord, warnings, now)
            }

        var updatedBottle = bottle
        updatedBottle.config.graphicsBackend = backend
        updatedBottle.config.graphicsLayerVersionID = targetPackage?.id
        updatedBottle.updatedAt = applyOutcome.now

        if let bottleStore {
            try bottleStore.saveBottle(updatedBottle)
        }

        return GraphicsApplyResult(
            bottle: updatedBottle,
            record: applyOutcome.record,
            warnings: applyOutcome.warnings
        )
    }

    // MARK: - Archive Import Pipeline

    private func importArchiveInternal(
        at archivePath: String,
        backend: GraphicsBackend,
        version: String,
        sourceURL: String?
    ) async throws -> GraphicsLayerPackage {
        guard backend != .wined3d else {
            throw VermouthError.invalidGraphicsArchive(
                path: archivePath,
                reason: "WineD3D 为 Wine 内置后端，不支持导入外部图形归档"
            )
        }

        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else {
            throw VermouthError.invalidGraphicsArchive(
                path: archivePath,
                reason: "图形包版本号不能为空"
            )
        }

        let fileManager = FileManager.default
        let archiveURL = URL(
            fileURLWithPath: expandTilde(archivePath, homeDirectory: fileManager.homeDirectoryForCurrentUser)
        ).standardizedFileURL

        guard regularFileExists(at: archiveURL, fileManager: fileManager) else {
            throw VermouthError.invalidGraphicsArchive(
                path: archiveURL.path,
                reason: "归档文件不存在或不是普通文件"
            )
        }

        let sha256 = try PureSHA256.hashFile(at: archiveURL)

        // 1. 解压前列出归档条目并阻断 tar-slip 路径穿越（L-016: 必须先校验 exitCode == 0）
        let listResult = try await commandRunner.run(
            CommandRequest(
                executablePath: "/usr/bin/tar",
                arguments: ["-tf", archiveURL.path],
                environment: [:],
                inheritEnvironment: true,
                workingDirectory: nil
            )
        )
        guard listResult.exitCode == 0 else {
            let reason = listResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VermouthError.invalidGraphicsArchive(
                path: archiveURL.path,
                reason: "读取 tar 归档失败（退出码 \(listResult.exitCode)）\(reason.isEmpty ? "" : ": \(reason)")"
            )
        }

        let entries = listResult.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !entries.isEmpty else {
            throw VermouthError.invalidGraphicsArchive(
                path: archiveURL.path,
                reason: "归档为空"
            )
        }

        for entry in entries {
            try validateArchiveEntryPath(entry, archivePath: archiveURL.path)
        }

        // 2. 解压至隔离暂存目录
        try paths.ensureBaseDirectories()
        let stagingDir = paths.graphicsDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try createDirectory(at: stagingDir, fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: stagingDir)
        }

        let extractResult = try await commandRunner.run(
            CommandRequest(
                executablePath: "/usr/bin/tar",
                arguments: ["-xf", archiveURL.path, "-C", stagingDir.path],
                environment: [:],
                inheritEnvironment: true,
                workingDirectory: nil
            )
        )
        guard extractResult.exitCode == 0 else {
            let reason = extractResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VermouthError.invalidGraphicsArchive(
                path: archiveURL.path,
                reason: "解压归档失败（退出码 \(extractResult.exitCode)）\(reason.isEmpty ? "" : ": \(reason)")"
            )
        }

        // 防御符号链接越狱
        try validateNoEscapingSymlinks(in: stagingDir, archivePath: archiveURL.path, fileManager: fileManager)

        // 3. 剥离单层外包装目录（但绝不剥离 x86_64-windows / x64 等格式目录本身）
        let payloadRoot = unwrapSingleWrapperDirectory(in: stagingDir, fileManager: fileManager)

        // 4. 判定归档格式并动态扫描真实存在的 DLL 清单（L-002）
        let format = try detectArchiveFormat(at: payloadRoot, archivePath: archiveURL.path, fileManager: fileManager)
        let containedDLLs = scanContainedDLLs(at: payloadRoot, format: format, fileManager: fileManager)
        guard !containedDLLs.isEmpty else {
            throw VermouthError.invalidGraphicsArchive(
                path: archiveURL.path,
                reason: "归档内未找到任何有效的 .dll 文件"
            )
        }

        // 5. 安全替换落盘到目标目录并原子更新 graphics/index.json（L-015）
        let installURL = paths.graphicsPackageDirectory(backend: backend, version: trimmedVersion).standardizedFileURL
        try replaceDirectorySafely(from: payloadRoot, to: installURL, fileManager: fileManager)

        let packageID = GraphicsLayerPackage.packageID(backend: backend, version: trimmedVersion)
        let package = GraphicsLayerPackage(
            id: packageID,
            backend: backend,
            version: trimmedVersion,
            format: format,
            installPath: installURL.path,
            sourceURL: sourceURL,
            sha256: sha256,
            installedAt: VermouthJSON.currentTimestamp(),
            containedDLLs: containedDLLs
        )

        try indexStore.mutate { packages in
            packages.removeAll { $0.id == package.id }
            packages.append(package)
            packages.sort { $0.id < $1.id }
        }

        return package
    }

    private func validateArchiveEntryPath(_ entry: String, archivePath: String) throws {
        if entry.contains("\0") {
            throw VermouthError.invalidGraphicsArchive(
                path: archivePath,
                reason: "归档包含非法 NUL 字节路径条目"
            )
        }
        if entry.hasPrefix("/") || entry.hasPrefix("\\") {
            throw VermouthError.invalidGraphicsArchive(
                path: archivePath,
                reason: "归档包含绝对路径条目（疑似路径穿越）: \(entry)"
            )
        }
        let components = entry.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if components.contains("..") {
            throw VermouthError.invalidGraphicsArchive(
                path: archivePath,
                reason: "归档包含 '..' 路径穿越条目: \(entry)"
            )
        }
    }

    private func validateNoEscapingSymlinks(
        in rootDir: URL,
        archivePath: String,
        fileManager: FileManager
    ) throws {
        let standardizedRoot = rootDir.standardizedFileURL.path
        let resolvedRoot = rootDir.resolvingSymlinksInPath().standardizedFileURL.path
        let standardizedBoundary = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        let resolvedBoundary = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"

        guard let enumerator = fileManager.enumerator(
            at: rootDir,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return
        }

        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink == true
            else {
                continue
            }

            // 同时校验 readlink 原始目标与 resolvingSymlinksInPath 结果，防止悬空符号链接绕过检测
            if let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: itemURL.path) {
                let lexicalTarget: String
                if rawDestination.hasPrefix("/") {
                    lexicalTarget = URL(fileURLWithPath: rawDestination).standardizedFileURL.path
                } else {
                    lexicalTarget = itemURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(rawDestination)
                        .standardizedFileURL
                        .path
                }

                let insideStandardized = lexicalTarget == standardizedRoot
                    || lexicalTarget.hasPrefix(standardizedBoundary)
                let insideResolved = lexicalTarget == resolvedRoot
                    || lexicalTarget.hasPrefix(resolvedBoundary)
                if !insideStandardized && !insideResolved {
                    throw VermouthError.invalidGraphicsArchive(
                        path: archivePath,
                        reason: "归档包含指向解压目录外部的符号链接: \(itemURL.lastPathComponent) -> \(rawDestination)"
                    )
                }
            }

            let resolvedTarget = itemURL.resolvingSymlinksInPath().standardizedFileURL.path
            if resolvedTarget != resolvedRoot && !resolvedTarget.hasPrefix(resolvedBoundary) {
                throw VermouthError.invalidGraphicsArchive(
                    path: archivePath,
                    reason: "归档包含指向解压目录外部的符号链接: \(itemURL.lastPathComponent)"
                )
            }
        }
    }

    private func unwrapSingleWrapperDirectory(in rootDir: URL, fileManager: FileManager) -> URL {
        var current = rootDir
        for _ in 0..<2 {
            guard let children = try? fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                break
            }
            let filtered = children.filter { $0.lastPathComponent != "__MACOSX" }
            guard filtered.count == 1,
                  let sole = filtered.first,
                  directoryExists(at: sole, fileManager: fileManager),
                  !Self.knownLayoutDirectoryNames.contains(sole.lastPathComponent.lowercased())
            else {
                break
            }
            current = sole
        }
        return current
    }

    private func detectArchiveFormat(
        at payloadRoot: URL,
        archivePath: String,
        fileManager: FileManager
    ) throws -> GraphicsArchiveFormat {
        guard let children = try? fileManager.contentsOfDirectory(
            at: payloadRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw VermouthError.invalidGraphicsArchive(
                path: archivePath,
                reason: "无法枚举解压后的图形包目录"
            )
        }

        let dirNames = Set(
            children
                .filter { directoryExists(at: $0, fileManager: fileManager) }
                .map { $0.lastPathComponent.lowercased() }
        )

        if dirNames.contains("x86_64-windows")
            || dirNames.contains("x86_64-unix")
            || dirNames.contains("i386-windows")
        {
            return .wineBuiltin
        }

        if dirNames.contains("x64") || dirNames.contains("x32") {
            return .nativeDLLs
        }

        throw VermouthError.invalidGraphicsArchive(
            path: archivePath,
            reason: "无法识别图形转译层目录结构（需包含 x86_64-windows/x86_64-unix 或 x64/x32）"
        )
    }

    private func scanContainedDLLs(
        at payloadRoot: URL,
        format: GraphicsArchiveFormat,
        fileManager: FileManager
    ) -> [String] {
        let targetSubdirNames: Set<String>
        switch format {
        case .wineBuiltin:
            targetSubdirNames = ["x86_64-windows", "i386-windows"]
        case .nativeDLLs:
            targetSubdirNames = ["x64", "x32"]
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: payloadRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var dllNames: Set<String> = []
        for child in children {
            guard directoryExists(at: child, fileManager: fileManager),
                  targetSubdirNames.contains(child.lastPathComponent.lowercased()),
                  let files = try? fileManager.contentsOfDirectory(
                      at: child,
                      includingPropertiesForKeys: [.isRegularFileKey],
                      options: [.skipsHiddenFiles]
                  )
            else {
                continue
            }

            for fileURL in files {
                guard regularFileExists(at: fileURL, fileManager: fileManager),
                      fileURL.lastPathComponent.lowercased().hasSuffix(".dll")
                else {
                    continue
                }
                let normalized = DllOverride.normalizeName(fileURL.lastPathComponent)
                if !normalized.isEmpty {
                    dllNames.insert(normalized)
                }
            }
        }

        return dllNames.sorted()
    }

    private func replaceDirectorySafely(
        from stagedPayload: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let parentDir = destination.deletingLastPathComponent()
        try createDirectory(at: parentDir, fileManager: fileManager)

        let backupOldURL = parentDir.appendingPathComponent(
            ".\(destination.lastPathComponent).old.\(UUID().uuidString)",
            isDirectory: true
        )
        let hadExisting = fileManager.fileExists(atPath: destination.path)

        do {
            if hadExisting {
                try fileManager.moveItem(at: destination, to: backupOldURL)
            }
            try fileManager.moveItem(at: stagedPayload, to: destination)
            if hadExisting {
                try? fileManager.removeItem(at: backupOldURL)
            }
        } catch {
            if hadExisting && !fileManager.fileExists(atPath: destination.path)
                && fileManager.fileExists(atPath: backupOldURL.path)
            {
                try? fileManager.moveItem(at: backupOldURL, to: destination)
            }
            throw VermouthError.ioError(
                operation: "moveItem",
                path: destination.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    // MARK: - Deployment & Rollback Helpers (Locked)

    private func loadDeploymentRecordUnlocked(for bottle: Bottle) throws -> GraphicsDeploymentRecord {
        let stateURL = paths.bottleGraphicsStateURL(id: bottle.id)
        let fileManager = FileManager.default
        guard regularFileExists(at: stateURL, fileManager: fileManager) else {
            return GraphicsDeploymentRecord(
                schemaVersion: GraphicsDeploymentRecord.currentSchemaVersion,
                backend: .wined3d,
                packageID: nil,
                strategy: .wined3dBuiltin,
                deployedFiles: [],
                backedUpFiles: [:],
                updatedAt: bottle.updatedAt
            )
        }

        let record = try VermouthJSON.read(GraphicsDeploymentRecord.self, from: stateURL)
        guard record.schemaVersion <= GraphicsDeploymentRecord.currentSchemaVersion else {
            throw VermouthError.unsupportedSchemaVersion(
                found: record.schemaVersion,
                supported: GraphicsDeploymentRecord.currentSchemaVersion,
                path: stateURL.path
            )
        }
        return record
    }

    private func rollbackPreviousDeploymentUnlocked(
        _ previous: GraphicsDeploymentRecord,
        prefixURL: URL,
        backupsDir: URL,
        fileManager: FileManager
    ) throws {
        guard previous.strategy == .prefixCopyWithBackup
            || !previous.deployedFiles.isEmpty
            || !previous.backedUpFiles.isEmpty
        else {
            return
        }

        // 先移除先前写入的图形层 DLL
        for relPath in previous.deployedFiles {
            guard isSafeRelativePath(relPath) else { continue }
            let deployedURL = prefixURL.appendingPathComponent(relPath, isDirectory: false).standardizedFileURL
            if fileManager.fileExists(atPath: deployedURL.path) {
                do {
                    try fileManager.removeItem(at: deployedURL)
                } catch {
                    throw VermouthError.graphicsDeploymentFailed(
                        reason: "回滚删除旧图形层文件失败 [\(deployedURL.path)]: \(error.localizedDescription)"
                    )
                }
            }
        }

        // 再从 backups/ 精准恢复被替换的原始 Wine DLL
        for (relPrefixPath, relBackupPath) in previous.backedUpFiles.sorted(by: { $0.key < $1.key }) {
            guard isSafeRelativePath(relPrefixPath), isSafeRelativePath(relBackupPath) else {
                continue
            }
            let backupURL = backupsDir.appendingPathComponent(relBackupPath, isDirectory: false).standardizedFileURL
            let restoreURL = prefixURL.appendingPathComponent(relPrefixPath, isDirectory: false).standardizedFileURL

            guard fileManager.fileExists(atPath: backupURL.path) else {
                continue
            }

            try createDirectory(at: restoreURL.deletingLastPathComponent(), fileManager: fileManager)
            if fileManager.fileExists(atPath: restoreURL.path) {
                try? fileManager.removeItem(at: restoreURL)
            }
            do {
                try fileManager.copyItem(at: backupURL, to: restoreURL)
                try? fileManager.removeItem(at: backupURL)
            } catch {
                throw VermouthError.graphicsDeploymentFailed(
                    reason: "恢复备份 DLL 失败 [\(restoreURL.path)]: \(error.localizedDescription)"
                )
            }
        }
    }

    private func deployNativeDLLsUnlocked(
        package: GraphicsLayerPackage,
        prefixURL: URL,
        backupsDir: URL,
        fileManager: FileManager
    ) throws -> (deployedFiles: [String], backedUpFiles: [String: String]) {
        let packageRoot = URL(fileURLWithPath: package.installPath, isDirectory: true).standardizedFileURL
        guard let topChildren = try? fileManager.contentsOfDirectory(
            at: packageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw VermouthError.graphicsDeploymentFailed(
                reason: "无法读取图形包目录 [\(packageRoot.path)]"
            )
        }

        let mappings: [(sourceDirName: String, prefixSubdir: String)] = [
            ("x64", "drive_c/windows/system32"),
            ("x32", "drive_c/windows/syswow64"),
        ]

        var deployedFiles: [String] = []
        var backedUpFiles: [String: String] = [:]

        do {
            for mapping in mappings {
                guard let archDir = topChildren.first(where: {
                    directoryExists(at: $0, fileManager: fileManager)
                        && $0.lastPathComponent.lowercased() == mapping.sourceDirName
                }) else {
                    continue
                }

                let dllFiles = try fileManager.contentsOfDirectory(
                    at: archDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                .filter { url in
                    regularFileExists(at: url, fileManager: fileManager)
                        && url.lastPathComponent.lowercased().hasSuffix(".dll")
                }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

                let destDir = prefixURL.appendingPathComponent(mapping.prefixSubdir, isDirectory: true)
                try createDirectory(at: destDir, fileManager: fileManager)

                for sourceDLL in dllFiles {
                    let fileName = sourceDLL.lastPathComponent
                    let relativeDestPath = "\(mapping.prefixSubdir)/\(fileName)"
                    let destURL = prefixURL.appendingPathComponent(relativeDestPath, isDirectory: false)

                    // 使用 attributesOfItem（lstat 语义）同时识别普通文件与符号链接（含悬空链接）
                    if (try? fileManager.attributesOfItem(atPath: destURL.path)) != nil {
                        let relativeBackupPath = "graphics/\(relativeDestPath)"
                        let backupURL = backupsDir.appendingPathComponent(relativeBackupPath, isDirectory: false)
                        try createDirectory(at: backupURL.deletingLastPathComponent(), fileManager: fileManager)
                        if (try? fileManager.attributesOfItem(atPath: backupURL.path)) != nil {
                            try fileManager.removeItem(at: backupURL)
                        }
                        try fileManager.copyItem(at: destURL, to: backupURL)
                        backedUpFiles[relativeDestPath] = relativeBackupPath
                        try fileManager.removeItem(at: destURL)
                    }

                    try fileManager.copyItem(at: sourceDLL, to: destURL)
                    deployedFiles.append(relativeDestPath)
                }
            }

            guard !deployedFiles.isEmpty else {
                throw VermouthError.graphicsDeploymentFailed(
                    reason: "图形包 \(package.id) 未包含可部署的 x64/x32 DLL 文件"
                )
            }

            deployedFiles.sort()
            return (deployedFiles, backedUpFiles)
        } catch {
            // 中途失败则立即回滚本次部分写入与备份，保护容器完整性
            let partialRecord = GraphicsDeploymentRecord(
                schemaVersion: GraphicsDeploymentRecord.currentSchemaVersion,
                backend: package.backend,
                packageID: package.id,
                strategy: .prefixCopyWithBackup,
                deployedFiles: deployedFiles,
                backedUpFiles: backedUpFiles,
                updatedAt: VermouthJSON.currentTimestamp()
            )
            try? rollbackPreviousDeploymentUnlocked(
                partialRecord,
                prefixURL: prefixURL,
                backupsDir: backupsDir,
                fileManager: fileManager
            )

            if let vermouthError = error as? VermouthError {
                throw vermouthError
            }
            throw VermouthError.graphicsDeploymentFailed(
                reason: "部署 nativeDLLs 图形包 \(package.id) 失败: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Private Utilities

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else {
            return false
        }
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !components.contains("..")
    }

    private func expandTilde(_ path: String, homeDirectory: URL) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

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

    private func withDeploymentLock<T>(_ body: () throws -> T) rethrows -> T {
        deploymentLock.lock()
        defer { deploymentLock.unlock() }
        return try body()
    }
}

// MARK: - Atomic Graphics Index Store (L-015)

private struct GraphicsIndexFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion: Int = 1
    var schemaVersion: Int
    var packages: [GraphicsLayerPackage]

    init(schemaVersion: Int = GraphicsIndexFile.currentSchemaVersion, packages: [GraphicsLayerPackage] = []) {
        self.schemaVersion = schemaVersion
        self.packages = packages
    }
}

/// 同步锁保护的单次原子读改写索引存储（绝不跨 `await` 持锁，符合 L-015）。
private final class GraphicsIndexStore: Sendable {
    private let indexURL: URL
    private let lock = NSLock()

    init(indexURL: URL) {
        self.indexURL = indexURL
    }

    func loadPackages() throws -> [GraphicsLayerPackage] {
        try withLock {
            try readFileUnlocked().packages
        }
    }

    @discardableResult
    func mutate<T>(_ transform: (inout [GraphicsLayerPackage]) throws -> T) throws -> T {
        try withLock {
            var file = try readFileUnlocked()
            let result = try transform(&file.packages)
            try VermouthJSON.writeAtomically(file, to: indexURL)
            return result
        }
    }

    private func readFileUnlocked() throws -> GraphicsIndexFile {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return GraphicsIndexFile()
        }
        let file = try VermouthJSON.read(GraphicsIndexFile.self, from: indexURL)
        guard file.schemaVersion <= GraphicsIndexFile.currentSchemaVersion else {
            throw VermouthError.unsupportedSchemaVersion(
                found: file.schemaVersion,
                supported: GraphicsIndexFile.currentSchemaVersion,
                path: indexURL.path
            )
        }
        return file
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - GitHub Releases DTOs

private struct GitHubReleaseDTO: Decodable, Sendable {
    let tagName: String
    let draft: Bool?
    let publishedAt: Date?
    let assets: [GitHubAssetDTO]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubAssetDTO: Decodable, Sendable {
    let name: String
    let size: Int64?
    let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
    }
}
