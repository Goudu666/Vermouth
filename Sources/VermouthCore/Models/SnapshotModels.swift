import Foundation

/// 配置或存档快照目标（支持目录与单文件）。
public struct SnapshotTarget: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    /// 绝对路径或相对 prefix 的路径
    public var path: String

    public init(
        id: UUID = UUID(),
        label: String,
        path: String
    ) {
        self.id = id
        self.label = label
        self.path = path
    }
}

/// 已归档快照的完整性与回滚元数据记录。
public struct SnapshotRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var targetID: UUID
    public var label: String
    /// 快照创建时的规范化源路径，供回滚默认还原
    public var sourcePath: String
    public var isDirectory: Bool
    public var note: String?
    public var createdAt: Date
    public var archivePath: String
    public var fileCount: Int
    public var totalBytes: UInt64
    public var sha256: String

    public init(
        id: UUID = UUID(),
        targetID: UUID,
        label: String,
        sourcePath: String,
        isDirectory: Bool,
        note: String? = nil,
        createdAt: Date = Date(),
        archivePath: String,
        fileCount: Int,
        totalBytes: UInt64,
        sha256: String
    ) {
        self.id = id
        self.targetID = targetID
        self.label = label
        self.sourcePath = sourcePath
        self.isDirectory = isDirectory
        self.note = note
        self.createdAt = createdAt
        self.archivePath = archivePath
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.sha256 = sha256
    }
}
