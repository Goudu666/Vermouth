import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `snapshots/index.json` 持久化结构。
public struct SnapshotIndexFile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var records: [SnapshotRecord]

    public init(
        schemaVersion: Int = SnapshotIndexFile.currentSchemaVersion,
        records: [SnapshotRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

/// 纯 Swift 同步锁保护的快照索引原子存储（符合 L-015 原子事务约束）。
private final class SnapshotIndexStore: @unchecked Sendable {
    private let lock = NSLock()
    private let paths: VermouthPaths

    init(paths: VermouthPaths) {
        self.paths = paths
    }

    func load(bottleID: UUID) throws -> SnapshotIndexFile {
        try lock.withLock {
            try loadUnlocked(bottleID: bottleID)
        }
    }

    func mutate<T>(
        bottleID: UUID,
        _ body: (inout SnapshotIndexFile) throws -> T
    ) throws -> T {
        try lock.withLock {
            let original = try loadUnlocked(bottleID: bottleID)
            var updated = original
            let result = try body(&updated)
            if updated != original {
                try VermouthJSON.writeAtomically(updated, to: paths.bottleSnapshotsIndexURL(id: bottleID))
            }
            return result
        }
    }

    private func loadUnlocked(bottleID: UUID) throws -> SnapshotIndexFile {
        let indexURL = paths.bottleSnapshotsIndexURL(id: bottleID)
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return SnapshotIndexFile()
        }
        let decoded = try VermouthJSON.read(SnapshotIndexFile.self, from: indexURL)
        guard decoded.schemaVersion <= SnapshotIndexFile.currentSchemaVersion else {
            throw VermouthError.unsupportedSchemaVersion(
                found: decoded.schemaVersion,
                supported: SnapshotIndexFile.currentSchemaVersion,
                path: indexURL.path
            )
        }
        return decoded
    }
}

/// 配置与存档目录 SHA-256 原子快照与回滚管理器（严格遵循 L-011、L-014、L-015、L-016）。
/// 采用 100% Clean-Room 纯 Swift 二进制快照容器（`.vsnap`）：
/// - 支持单文件与完整目录树（含空目录与 POSIX 权限）
/// - 创建与回滚零外部进程依赖，完全同步且可校验防路径穿越
/// - 回滚前强制校验 SHA-256 与归档条目安全性，再自动创建保底快照并通过兄弟临时目录原子替换目标
public final class SnapshotManager: SnapshotManaging, Sendable {
    private static let archiveMagic: [UInt8] = [0x56, 0x53, 0x4E, 0x50] // "VSNP"
    private static let archiveFormatVersion: UInt32 = 1

    private let paths: VermouthPaths
    private let commandRunner: any CommandRunning
    private let indexStore: SnapshotIndexStore

    public init(
        paths: VermouthPaths,
        commandRunner: any CommandRunning = LiveCommandRunner()
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.indexStore = SnapshotIndexStore(paths: paths)
    }

    // MARK: - SnapshotManaging

    public func listSnapshots(bottleID: UUID, targetID: UUID? = nil) throws -> [SnapshotRecord] {
        let index = try indexStore.load(bottleID: bottleID)
        let filtered: [SnapshotRecord]
        if let targetID {
            filtered = index.records.filter { $0.targetID == targetID }
        } else {
            filtered = index.records
        }
        return filtered.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    public func createSnapshot(
        bottleID: UUID,
        target: SnapshotTarget,
        note: String? = nil
    ) throws -> SnapshotRecord {
        let resolvedSourcePath = try resolveAndValidatePath(target.path, bottleID: bottleID)
        let sourceURL = URL(fileURLWithPath: resolvedSourcePath).standardizedFileURL

        // L-016: 对顶层源路径解引用符号链接以准确判断并归档实际内容
        let canonicalSourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalSourceURL.path, isDirectory: &isDir) else {
            throw VermouthError.snapshotTargetNotFound(path: resolvedSourcePath)
        }

        let snapshotsDir = paths.bottleSnapshotsDirectory(id: bottleID)
        do {
            try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        } catch {
            throw VermouthError.ioError(
                operation: "createDirectory",
                path: snapshotsDir.path,
                underlyingDescription: error.localizedDescription
            )
        }

        let snapshotID = UUID()
        let archiveURL = snapshotsDir.appendingPathComponent("\(snapshotID.uuidString).vsnap", isDirectory: false)
        let stats = try writeArchive(
            from: canonicalSourceURL,
            isDirectory: isDir.boolValue,
            to: archiveURL
        )

        let sha256: String
        do {
            sha256 = try PureSHA256.hashFile(at: archiveURL)
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }

        let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLabel = label.isEmpty ? sourceURL.lastPathComponent : label
        let record = SnapshotRecord(
            id: snapshotID,
            targetID: target.id,
            label: effectiveLabel,
            sourcePath: sourceURL.path,
            isDirectory: isDir.boolValue,
            note: note,
            createdAt: VermouthJSON.currentTimestamp(),
            archivePath: archiveURL.path,
            fileCount: stats.fileCount,
            totalBytes: stats.totalBytes,
            sha256: sha256
        )

        do {
            try indexStore.mutate(bottleID: bottleID) { index in
                index.records.append(record)
            }
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }

        return record
    }

    public func rollback(
        bottleID: UUID,
        snapshotID: UUID,
        destinationOverride: String? = nil
    ) throws -> SnapshotRecord {
        let index = try indexStore.load(bottleID: bottleID)
        guard let snapshot = index.records.first(where: { $0.id == snapshotID }) else {
            throw VermouthError.snapshotNotFound(id: snapshotID)
        }

        let archiveURL = URL(fileURLWithPath: snapshot.archivePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw VermouthError.snapshotOperationFailed(
                reason: "快照归档文件已丢失 [\(archiveURL.path)]"
            )
        }

        // Step 1 (L-011): 回滚前强制校验归档 SHA-256，校验失败绝不修改目标路径
        let actualSHA256 = try PureSHA256.hashFile(at: archiveURL)
        guard actualSHA256 == snapshot.sha256 else {
            throw VermouthError.snapshotIntegrityCheckFailed(
                snapshotID: snapshotID,
                expectedSHA256: snapshot.sha256,
                actualSHA256: actualSHA256
            )
        }

        // Step 2 (L-011): 解析并验证归档清单元数据与路径穿越防护（不触碰目标目录）
        let parsedArchive = try readAndValidateArchive(at: archiveURL)

        // Step 3: 规范化并校验还原目标路径安全性
        let rawDestination = destinationOverride ?? snapshot.sourcePath
        let destinationPath = try resolveAndValidatePath(rawDestination, bottleID: bottleID)
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let parentDirectory = destinationURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw VermouthError.ioError(
                operation: "createDirectory",
                path: parentDirectory.path,
                underlyingDescription: error.localizedDescription
            )
        }

        // Step 4: 在同父目录创建兄弟暂存路径并完整解包（失败时自动清理，原目标丝毫无损）
        let stagingURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).rollback-staging.\(UUID().uuidString)",
            isDirectory: parsedArchive.manifest.isDirectory
        )
        do {
            try extractValidatedArchive(parsedArchive, to: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        // Step 5 (L-011): 替换目标前自动创建保底快照（即使目标已被删除，也记录空保底快照以便审计）
        let safetyBackup: SnapshotRecord
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let backupTarget = SnapshotTarget(
                    id: snapshot.targetID,
                    label: "\(snapshot.label) (回滚前自动保底)",
                    path: destinationURL.path
                )
                safetyBackup = try createSnapshot(
                    bottleID: bottleID,
                    target: backupTarget,
                    note: "回滚至快照 \(snapshot.id.uuidString) 前自动创建的保底快照"
                )
            } else {
                safetyBackup = try createEmptyMarkerSnapshot(
                    bottleID: bottleID,
                    targetID: snapshot.targetID,
                    label: "\(snapshot.label) (回滚前自动保底)",
                    sourcePath: destinationURL.path,
                    isDirectory: snapshot.isDirectory,
                    note: "回滚至快照 \(snapshot.id.uuidString) 前目标不存在，已记录空保底快照"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        // Step 6 (L-011): 使用同父目录兄弟临时路径原子替换目标
        do {
            try atomicallyReplace(destination: destinationURL, withStaging: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        return safetyBackup
    }

    public func deleteSnapshot(bottleID: UUID, snapshotID: UUID) throws {
        let removed: SnapshotRecord? = try indexStore.mutate(bottleID: bottleID) { index in
            guard let position = index.records.firstIndex(where: { $0.id == snapshotID }) else {
                return nil
            }
            return index.records.remove(at: position)
        }

        guard let removed else {
            throw VermouthError.snapshotNotFound(id: snapshotID)
        }

        let archiveURL = URL(fileURLWithPath: removed.archivePath)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            do {
                try FileManager.default.removeItem(at: archiveURL)
            } catch {
                throw VermouthError.ioError(
                    operation: "removeArchive",
                    path: archiveURL.path,
                    underlyingDescription: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Archive Format Implementation (Pure Swift VSNP v1)

    private struct ArchiveEntry: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case file
            case directory
        }

        let relativePath: String
        let kind: Kind
        let posixPermissions: UInt16
        let byteOffset: UInt64
        let byteLength: UInt64
    }

    private struct ArchiveManifest: Codable, Sendable {
        let formatVersion: UInt32
        let isDirectory: Bool
        let rootName: String
        let entries: [ArchiveEntry]
    }

    private struct ParsedArchive {
        let manifest: ArchiveManifest
        let payloadOffset: Int
        let rawData: Data
    }

    private func writeArchive(
        from sourceURL: URL,
        isDirectory: Bool,
        to archiveURL: URL
    ) throws -> (fileCount: Int, totalBytes: UInt64) {
        var entries: [ArchiveEntry] = []
        var payload = Data()
        var fileCount = 0
        var totalBytes: UInt64 = 0

        if isDirectory {
            let rootPerms = posixPermissions(at: sourceURL.path, defaultPermissions: 0o755)
            entries.append(
                ArchiveEntry(
                    relativePath: "",
                    kind: .directory,
                    posixPermissions: rootPerms,
                    byteOffset: 0,
                    byteLength: 0
                )
            )
            try collectDirectoryEntries(
                rootURL: sourceURL,
                currentURL: sourceURL,
                relativePrefix: "",
                entries: &entries,
                payload: &payload,
                fileCount: &fileCount,
                totalBytes: &totalBytes
            )
        } else {
            let fileData: Data
            do {
                fileData = try Data(contentsOf: sourceURL)
            } catch {
                throw VermouthError.ioError(
                    operation: "readSnapshotFile",
                    path: sourceURL.path,
                    underlyingDescription: error.localizedDescription
                )
            }
            let perms = posixPermissions(at: sourceURL.path, defaultPermissions: 0o644)
            let length = UInt64(fileData.count)
            entries.append(
                ArchiveEntry(
                    relativePath: "",
                    kind: .file,
                    posixPermissions: perms,
                    byteOffset: 0,
                    byteLength: length
                )
            )
            payload.append(fileData)
            fileCount = 1
            totalBytes = length
        }

        let manifest = ArchiveManifest(
            formatVersion: Self.archiveFormatVersion,
            isDirectory: isDirectory,
            rootName: sourceURL.lastPathComponent,
            entries: entries
        )
        let archiveData = try serializeArchive(manifest: manifest, payload: payload)
        try writeDataAtomically(archiveData, to: archiveURL)
        return (fileCount, totalBytes)
    }

    private func createEmptyMarkerSnapshot(
        bottleID: UUID,
        targetID: UUID,
        label: String,
        sourcePath: String,
        isDirectory: Bool,
        note: String?
    ) throws -> SnapshotRecord {
        let snapshotsDir = paths.bottleSnapshotsDirectory(id: bottleID)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

        let snapshotID = UUID()
        let archiveURL = snapshotsDir.appendingPathComponent("\(snapshotID.uuidString).vsnap", isDirectory: false)
        let manifest = ArchiveManifest(
            formatVersion: Self.archiveFormatVersion,
            isDirectory: isDirectory,
            rootName: URL(fileURLWithPath: sourcePath).lastPathComponent,
            entries: isDirectory
                ? [ArchiveEntry(relativePath: "", kind: .directory, posixPermissions: 0o755, byteOffset: 0, byteLength: 0)]
                : []
        )
        let archiveData = try serializeArchive(manifest: manifest, payload: Data())
        try writeDataAtomically(archiveData, to: archiveURL)
        let sha256 = try PureSHA256.hashFile(at: archiveURL)

        let record = SnapshotRecord(
            id: snapshotID,
            targetID: targetID,
            label: label,
            sourcePath: sourcePath,
            isDirectory: isDirectory,
            note: note,
            createdAt: VermouthJSON.currentTimestamp(),
            archivePath: archiveURL.path,
            fileCount: 0,
            totalBytes: 0,
            sha256: sha256
        )

        do {
            try indexStore.mutate(bottleID: bottleID) { index in
                index.records.append(record)
            }
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }

        return record
    }

    private func collectDirectoryEntries(
        rootURL: URL,
        currentURL: URL,
        relativePrefix: String,
        entries: inout [ArchiveEntry],
        payload: inout Data,
        fileCount: inout Int,
        totalBytes: inout UInt64
    ) throws {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw VermouthError.ioError(
                operation: "listDirectory",
                path: currentURL.path,
                underlyingDescription: error.localizedDescription
            )
        }

        let sortedChildren = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in sortedChildren {
            let values = try? child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            // Skip internal symlinks to prevent symlink loops or exfiltration outside snapshot root
            if values?.isSymbolicLink == true {
                continue
            }

            let name = child.lastPathComponent
            let relPath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"

            if values?.isDirectory == true {
                let perms = posixPermissions(at: child.path, defaultPermissions: 0o755)
                entries.append(
                    ArchiveEntry(
                        relativePath: relPath,
                        kind: .directory,
                        posixPermissions: perms,
                        byteOffset: 0,
                        byteLength: 0
                    )
                )
                try collectDirectoryEntries(
                    rootURL: rootURL,
                    currentURL: child,
                    relativePrefix: relPath,
                    entries: &entries,
                    payload: &payload,
                    fileCount: &fileCount,
                    totalBytes: &totalBytes
                )
            } else if values?.isRegularFile == true {
                let fileData: Data
                do {
                    fileData = try Data(contentsOf: child)
                } catch {
                    throw VermouthError.ioError(
                        operation: "readSnapshotFile",
                        path: child.path,
                        underlyingDescription: error.localizedDescription
                    )
                }
                let perms = posixPermissions(at: child.path, defaultPermissions: 0o644)
                let offset = UInt64(payload.count)
                let length = UInt64(fileData.count)
                payload.append(fileData)
                entries.append(
                    ArchiveEntry(
                        relativePath: relPath,
                        kind: .file,
                        posixPermissions: perms,
                        byteOffset: offset,
                        byteLength: length
                    )
                )
                fileCount += 1
                totalBytes &+= length
            }
        }
    }

    private func serializeArchive(manifest: ArchiveManifest, payload: Data) throws -> Data {
        let manifestData: Data
        do {
            manifestData = try VermouthJSON.encode(manifest)
        } catch {
            throw VermouthError.encodingFailed(
                type: "SnapshotArchiveManifest",
                underlyingDescription: error.localizedDescription
            )
        }

        guard manifestData.count <= Int(UInt32.max) else {
            throw VermouthError.snapshotOperationFailed(reason: "快照清单超出最大长度限制")
        }

        var output = Data()
        output.reserveCapacity(12 + manifestData.count + payload.count)
        output.append(contentsOf: Self.archiveMagic)
        appendUInt32LE(Self.archiveFormatVersion, to: &output)
        appendUInt32LE(UInt32(manifestData.count), to: &output)
        output.append(manifestData)
        output.append(payload)
        return output
    }

    private func readAndValidateArchive(at archiveURL: URL) throws -> ParsedArchive {
        let rawData: Data
        do {
            rawData = try Data(contentsOf: archiveURL)
        } catch {
            throw VermouthError.ioError(
                operation: "readSnapshotArchive",
                path: archiveURL.path,
                underlyingDescription: error.localizedDescription
            )
        }

        guard rawData.count >= 12 else {
            throw VermouthError.snapshotOperationFailed(reason: "快照归档文件头截断或损坏")
        }

        let headerValid: (version: UInt32, manifestLength: Int) = try rawData.withUnsafeBytes { raw in
            for i in 0..<4 where raw[i] != Self.archiveMagic[i] {
                throw VermouthError.snapshotOperationFailed(reason: "快照归档魔数无效（非 VSNP 归档）")
            }
            let version = readUInt32LE(raw, at: 4)
            let manifestLen = readUInt32LE(raw, at: 8)
            guard version == Self.archiveFormatVersion else {
                throw VermouthError.snapshotOperationFailed(
                    reason: "不支持的快照归档格式版本: \(version)"
                )
            }
            guard let manifestLenInt = Int(exactly: manifestLen),
                  manifestLenInt > 0,
                  manifestLenInt <= raw.count - 12
            else {
                throw VermouthError.snapshotOperationFailed(reason: "快照归档清单长度非法或截断")
            }
            return (version, manifestLenInt)
        }

        let payloadOffset = 12 + headerValid.manifestLength
        let manifestSlice = rawData.subdata(in: 12..<payloadOffset)
        let manifest: ArchiveManifest
        do {
            manifest = try VermouthJSON.decode(ArchiveManifest.self, from: manifestSlice)
        } catch {
            throw VermouthError.snapshotOperationFailed(
                reason: "快照清单 JSON 解析失败: \(error.localizedDescription)"
            )
        }

        let payloadSize = UInt64(rawData.count - payloadOffset)
        for entry in manifest.entries {
            try validateArchiveRelativePath(entry.relativePath, allowEmpty: true)
            if manifest.isDirectory && entry.relativePath.isEmpty && entry.kind == .file {
                throw VermouthError.snapshotUnsafeArchiveEntry(entryPath: entry.relativePath)
            }
            if entry.kind == .file {
                guard entry.byteOffset <= payloadSize,
                      entry.byteLength <= payloadSize - entry.byteOffset
                else {
                    throw VermouthError.snapshotOperationFailed(
                        reason: "快照条目 [\(entry.relativePath)] 数据偏移超出归档边界"
                    )
                }
            }
        }

        return ParsedArchive(manifest: manifest, payloadOffset: payloadOffset, rawData: rawData)
    }

    private func extractValidatedArchive(_ archive: ParsedArchive, to stagingURL: URL) throws {
        let fileManager = FileManager.default
        let stagingStandard = stagingURL.standardizedFileURL

        if archive.manifest.isDirectory {
            try fileManager.createDirectory(at: stagingStandard, withIntermediateDirectories: true)
            for entry in archive.manifest.entries {
                let targetURL: URL
                if entry.relativePath.isEmpty {
                    targetURL = stagingStandard
                } else {
                    try validateArchiveRelativePath(entry.relativePath, allowEmpty: false)
                    targetURL = stagingStandard.appendingPathComponent(entry.relativePath).standardizedFileURL
                    guard isStrictlyInside(childPath: targetURL.path, parentPath: stagingStandard.path) else {
                        throw VermouthError.snapshotUnsafeArchiveEntry(entryPath: entry.relativePath)
                    }
                }

                switch entry.kind {
                case .directory:
                    try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    try? fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: entry.posixPermissions)],
                        ofItemAtPath: targetURL.path
                    )
                case .file:
                    let parentDir = targetURL.deletingLastPathComponent()
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    let start = archive.payloadOffset + Int(entry.byteOffset)
                    let end = start + Int(entry.byteLength)
                    let fileData = archive.rawData.subdata(in: start..<end)
                    try fileData.write(to: targetURL, options: [])
                    try? fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: entry.posixPermissions)],
                        ofItemAtPath: targetURL.path
                    )
                }
            }
        } else {
            guard let fileEntry = archive.manifest.entries.first(where: { $0.kind == .file }) else {
                // Empty marker snapshot for single file: create empty file
                try Data().write(to: stagingStandard, options: [])
                return
            }
            if !fileEntry.relativePath.isEmpty {
                try validateArchiveRelativePath(fileEntry.relativePath, allowEmpty: false)
            }
            let start = archive.payloadOffset + Int(fileEntry.byteOffset)
            let end = start + Int(fileEntry.byteLength)
            let fileData = archive.rawData.subdata(in: start..<end)
            try fileData.write(to: stagingStandard, options: [])
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: fileEntry.posixPermissions)],
                ofItemAtPath: stagingStandard.path
            )
        }
    }

    // MARK: - Atomic Replacement (macOS RENAME_SWAP + POSIX Rename-Aside Fallback)

    private func atomicallyReplace(destination: URL, withStaging staging: URL) throws {
        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: destination.path)

        if !destinationExists {
            try posixRename(from: staging, to: destination)
            return
        }

        #if os(macOS)
        // APFS/macOS 单次内核级原子交换，目录与文件均不会出现空窗期
        let swapErrno: Int32 = staging.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                guard let src, let dst else { return EINVAL }
                if renamex_np(src, dst, UInt32(RENAME_SWAP)) == 0 {
                    return 0
                }
                return errno
            }
        }
        if swapErrno == 0 {
            try? fileManager.removeItem(at: staging)
            return
        }
        #endif

        // Fallback (Linux 或不支持 RENAME_SWAP 的文件系统)：同父目录 rename-aside + 失败恢复
        var isDestDir: ObjCBool = false
        _ = fileManager.fileExists(atPath: destination.path, isDirectory: &isDestDir)
        var isStagingDir: ObjCBool = false
        _ = fileManager.fileExists(atPath: staging.path, isDirectory: &isStagingDir)

        if !isDestDir.boolValue && !isStagingDir.boolValue {
            try posixRename(from: staging, to: destination)
            return
        }

        let displacedURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).rollback-old.\(UUID().uuidString)",
            isDirectory: isDestDir.boolValue
        )
        try posixRename(from: destination, to: displacedURL)
        do {
            try posixRename(from: staging, to: destination)
        } catch {
            // 还原旧目标，确保绝不清空存档
            try? posixRename(from: displacedURL, to: destination)
            throw error
        }
        try? fileManager.removeItem(at: displacedURL)
    }

    // MARK: - Path Safety & Archive Entry Validation

    private func resolveAndValidatePath(_ rawPath: String, bottleID: UUID) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VermouthError.invalidPath(rawPath, reason: "快照路径不能为空")
        }

        let expanded: String
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if trimmed == "~" {
            expanded = homeDir.path
        } else if trimmed.hasPrefix("~/") {
            expanded = homeDir.appendingPathComponent(String(trimmed.dropFirst(2))).standardizedFileURL.path
        } else if trimmed.hasPrefix("/") {
            expanded = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        } else {
            let prefixRoot = resolveBottlePrefixURL(bottleID: bottleID)
            expanded = prefixRoot.appendingPathComponent(trimmed).standardizedFileURL.path
        }

        try validateNotForbiddenSystemPath(expanded, originalPath: rawPath)
        return expanded
    }

    private func resolveBottlePrefixURL(bottleID: UUID) -> URL {
        let bottleConfigURL = paths.bottleConfigURL(id: bottleID)
        if let bottle = try? VermouthJSON.read(Bottle.self, from: bottleConfigURL) {
            return URL(fileURLWithPath: bottle.prefixPath, isDirectory: true).standardizedFileURL
        }
        return paths.bottlePrefixURL(id: bottleID)
    }

    private func validateNotForbiddenSystemPath(_ path: String, originalPath: String) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path

        let rawHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let resolvedHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path

        let forbidden: Set<String> = [
            "/",
            "/System",
            "/Applications",
            "/Users",
            "/Library",
            "/usr",
            "/opt",
            "/bin",
            "/sbin",
            "/etc",
            "/private",
            "/var",
            "/tmp",
            "/private/tmp",
            "/private/var",
            rawHome,
            resolvedHome,
        ]

        if forbidden.contains(standardized) || forbidden.contains(resolved) {
            throw VermouthError.invalidPath(
                originalPath,
                reason: "安全限制：不允许对系统根目录或用户主目录执行快照/回滚"
            )
        }
    }

    private func validateArchiveRelativePath(_ relativePath: String, allowEmpty: Bool) throws {
        if relativePath.isEmpty {
            if allowEmpty { return }
            throw VermouthError.snapshotUnsafeArchiveEntry(entryPath: relativePath)
        }
        if relativePath.hasPrefix("/")
            || relativePath.hasPrefix("\\")
            || relativePath.contains("\\")
            || relativePath.contains("\0")
        {
            throw VermouthError.snapshotUnsafeArchiveEntry(entryPath: relativePath)
        }
        let segments = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." {
                throw VermouthError.snapshotUnsafeArchiveEntry(entryPath: relativePath)
            }
        }
    }

    private func isStrictlyInside(childPath: String, parentPath: String) -> Bool {
        let prefix = parentPath.hasSuffix("/") ? parentPath : "\(parentPath)/"
        return childPath.hasPrefix(prefix)
    }

    // MARK: - Low-Level POSIX & Binary Helpers

    private func posixPermissions(at path: String, defaultPermissions: UInt16) -> UInt16 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.posixPermissions] as? NSNumber
        else {
            return defaultPermissions
        }
        return UInt16(truncatingIfNeeded: number.uint16Value & 0o777)
    }

    private func writeDataAtomically(_ data: Data, to destinationURL: URL) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: tempURL, options: [])
            try posixRename(from: tempURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func posixRename(from source: URL, to destination: URL) throws {
        let renameErrno: Int32 = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                guard let src, let dst else { return EINVAL }
                if rename(src, dst) == 0 {
                    return 0
                }
                return errno
            }
        }
        if renameErrno != 0 {
            let message: String
            if let cStr = strerror(renameErrno) {
                message = String(cString: cStr)
            } else {
                message = "Unknown POSIX error"
            }
            throw VermouthError.ioError(
                operation: "rename",
                path: destination.path,
                underlyingDescription: "\(message) (errno \(renameErrno))"
            )
        }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func readUInt32LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(raw[offset])
            | (UInt32(raw[offset + 1]) << 8)
            | (UInt32(raw[offset + 2]) << 16)
            | (UInt32(raw[offset + 3]) << 24)
    }
}
