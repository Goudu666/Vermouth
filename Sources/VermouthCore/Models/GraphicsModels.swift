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

    /// 安装后对应的 `GraphicsLayerPackage.id`
    public var expectedPackageID: String {
        GraphicsLayerPackage.packageID(backend: backend, version: version)
    }

    /// 该发行资产是否已在本地安装。
    ///
    /// 下载安装的包记录了来源 URL，按 URL 精确比对（同一 release 的 `-repack` 与 `-repack-builtin`
    /// 是两个不同资产）；本地导入的包没有来源 URL，退回到 id + 格式比对。
    public func isInstalled(in packages: [GraphicsLayerPackage]) -> Bool {
        packages.contains { package in
            if let sourceURL = package.sourceURL {
                return sourceURL == downloadURL.absoluteString
            }
            return package.id == expectedPackageID && package.format == format
        }
    }

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

extension GraphicsLayerPackage {
    public static func packageID(backend: GraphicsBackend, version: String) -> String {
        "\(backend.rawValue)-\(version)"
    }

    /// DXVK 的 `d3d11` / `d3d10core` 只认 DXVK 自己的 `dxgi` 适配器。包里没有 `dxgi.dll` 时，
    /// 部署后会落到 Wine 内置 dxgi 上，DXVK 报 `D3D11CoreCreateDevice: Adapter is not a DXVK adapter`。
    /// 典型是 Gcenx `dxvk-macOS-async-v1.10.3-20230507-repack`（只有 d3d10core/d3d11）。
    public var isDXVKMissingDXGI: Bool {
        backend == .dxvk
            && format == .nativeDLLs
            && (containedDLLs.contains("d3d11") || containedDLLs.contains("d3d10core"))
            && !containedDLLs.contains("dxgi")
    }

    /// `isDXVKMissingDXGI` 时给用户的明确警告；其余情况返回 `nil`。
    public var missingDXGIWarning: DiagnosticFinding? {
        guard isDXVKMissingDXGI else { return nil }
        return DiagnosticFinding(
            id: "dxvk-package-missing-dxgi-\(id)",
            category: .graphicsPackageIncomplete,
            severity: .warning,
            title: "DXVK 图形包 \(id) 不含 dxgi.dll",
            explanation: "该包只有 \(containedDLLs.map { "\($0).dll" }.joined(separator: "、"))，DXVK 的 d3d11 需要配套的 DXVK dxgi。在 Wine Stable 等引擎上会退回 Wine 内置 dxgi，日志出现「Adapter is not a DXVK adapter」，D3D11 设备创建失败。",
            suggestion: "请改用包含 dxgi.dll 的 DXVK 包（如 dxvk-macOS-async-v1.10.3-20230507），或切换回 WineD3D。只有引擎自带兼容 DXVK 的 dxgi 时才适合使用此包。",
            quickFix: .switchGraphicsBackend(.wined3d)
        )
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
