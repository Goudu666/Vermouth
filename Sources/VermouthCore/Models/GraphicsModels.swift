import Foundation

/// 下载进度快照。
public struct DownloadProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    /// 服务端未返回 `Content-Length` 时为 `nil`
    public let totalBytesExpected: Int64?

    public var fractionCompleted: Double? {
        guard let totalBytesExpected, totalBytesExpected > 0 else {
            return nil
        }
        return min(1.0, max(0.0, Double(bytesWritten) / Double(totalBytesExpected)))
    }

    public init(bytesWritten: Int64, totalBytesExpected: Int64? = nil) {
        self.bytesWritten = bytesWritten
        self.totalBytesExpected = totalBytesExpected
    }
}

/// 图形转译层归档格式分类。
public enum GraphicsArchiveFormat: String, Codable, Equatable, CaseIterable, Sendable {
    /// 含 `x86_64-windows/` + 可选 `x86_64-unix/` + 可选 `i386-windows/`，必须走 `WINEDLLPATH_PREPEND`（L-001）
    case wineBuiltin
    /// 含 `x64/` + 可选 `x32/`，通过备份后复制进 prefix 部署（L-002）
    case nativeDLLs
}

/// 图形转译层在容器内的实际部署策略。
public enum GraphicsDeploymentStrategy: String, Codable, Equatable, CaseIterable, Sendable {
    case wined3dBuiltin
    case wineDLLPathPrepend
    case prefixCopyWithBackup
}

/// 远端 GitHub Release 上可下载的图形转译层发行包描述。
public struct RemoteGraphicsRelease: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(backend.rawValue)-\(tagName)-\(assetName)" }
    public var backend: GraphicsBackend
    public var tagName: String
    public var version: String
    public var assetName: String
    public var downloadURL: URL
    public var sizeBytes: Int64?
    public var format: GraphicsArchiveFormat
    public var publishedAt: Date?

    public init(
        backend: GraphicsBackend,
        tagName: String,
        version: String,
        assetName: String,
        downloadURL: URL,
        sizeBytes: Int64? = nil,
        format: GraphicsArchiveFormat,
        publishedAt: Date? = nil
    ) {
        self.backend = backend
        self.tagName = tagName
        self.version = version
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.format = format
        self.publishedAt = publishedAt
    }
}

/// 已安装到本地应用数据目录中的图形转译层包元数据。
public struct GraphicsLayerPackage: Codable, Equatable, Identifiable, Sendable {
    /// 稳定包标识（如 `"dxmt-v0.80"` 或 `"dxvk-v1.10.3-20230507-repack"`）
    public var id: String
    public var backend: GraphicsBackend
    public var version: String
    public var format: GraphicsArchiveFormat
    public var installPath: String
    public var sourceURL: String?
    public var sha256: String?
    public var installedAt: Date
    /// 实际存在于包内的 DLL 列表（小写无后缀，如 `["d3d11", "dxgi", "d3d10core", "winemetal"]`）
    public var containedDLLs: [String]

    public init(
        id: String,
        backend: GraphicsBackend,
        version: String,
        format: GraphicsArchiveFormat,
        installPath: String,
        sourceURL: String? = nil,
        sha256: String? = nil,
        installedAt: Date = Date(),
        containedDLLs: [String] = []
    ) {
        self.id = id
        self.backend = backend
        self.version = version
        self.format = format
        self.installPath = installPath
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.installedAt = installedAt
        self.containedDLLs = containedDLLs
    }
}

/// 单个容器图形层落盘部署状态记录（持久化于 `graphics-state.json`）。
public struct GraphicsDeploymentRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var backend: GraphicsBackend
    public var packageID: String?
    public var strategy: GraphicsDeploymentStrategy
    /// 相对 prefix 的已写入 DLL 路径
    public var deployedFiles: [String]
    /// prefix 相对路径 -> backups 相对路径映射，供切换/回退时精准恢复
    public var backedUpFiles: [String: String]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = GraphicsDeploymentRecord.currentSchemaVersion,
        backend: GraphicsBackend = .wined3d,
        packageID: String? = nil,
        strategy: GraphicsDeploymentStrategy = .wined3dBuiltin,
        deployedFiles: [String] = [],
        backedUpFiles: [String: String] = [:],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.backend = backend
        self.packageID = packageID
        self.strategy = strategy
        self.deployedFiles = deployedFiles
        self.backedUpFiles = backedUpFiles
        self.updatedAt = updatedAt
    }
}

/// 图形后端应用结果（值语义返回，避免 Swift 6 `async` + `inout` 并发冲突，符合 L-007）。
public struct GraphicsApplyResult: Equatable, Sendable {
    public let bottle: Bottle
    public let record: GraphicsDeploymentRecord
    public let warnings: [DiagnosticFinding]

    public init(
        bottle: Bottle,
        record: GraphicsDeploymentRecord,
        warnings: [DiagnosticFinding] = []
    ) {
        self.bottle = bottle
        self.record = record
        self.warnings = warnings
    }
}
