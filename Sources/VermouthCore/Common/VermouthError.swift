import Foundation

/// Vermouth 核心领域错误类型，覆盖容器、引擎、图形转译层、启动器、二进制探测、快照、配方与文件 I/O。
public enum VermouthError: Error, LocalizedError, Equatable, Sendable {
    // MARK: - IO & Serialization
    case ioError(operation: String, path: String, underlyingDescription: String)
    case encodingFailed(type: String, underlyingDescription: String)
    case decodingFailed(type: String, path: String?, underlyingDescription: String)
    case invalidPath(String, reason: String)
    case unsupportedSchemaVersion(found: Int, supported: Int, path: String?)

    // MARK: - Engine
    case engineNotFound(id: String)
    case invalidEngineRoot(path: String, reason: String)
    case engineAlreadyRegistered(id: String)
    case cannotUnregisterDiscoveredEngine(id: String)
    case noEngineAvailable

    // MARK: - Bottle
    case bottleNotFound(identifier: String)
    case invalidBottleName(String)
    case bottleAlreadyExists(name: String)
    case invalidPrefixPath(path: String, reason: String)
    case prefixAlreadyExists(path: String)

    // MARK: - Graphics
    case graphicsPackageNotFound(id: String)
    case graphicsPackageInUse(id: String, bottleNames: [String])
    case invalidGraphicsArchive(path: String, reason: String)
    case engineMissingDLLPathPrepend(engineName: String, packageID: String)
    case graphicsBackendPackageRequired(GraphicsBackend)
    case graphicsDeploymentFailed(reason: String)
    case networkRequestFailed(url: String, statusCode: Int?, reason: String)

    // MARK: - Runner & Process
    case commandExecutionFailed(executable: String, exitCode: Int32, stderr: String)
    case launchTargetNotFound(path: String)
    case incompatibleArchitecture(executablePath: String, architecture: PEArchitecture, engineName: String)
    case prefixInitializationFailed(bottleName: String, reason: String)
    case registryPatchFailed(reason: String)

    // MARK: - Inspection
    case invalidPEFile(path: String, reason: String)
    case invalidShellLink(path: String, reason: String)

    // MARK: - Snapshot
    case snapshotNotFound(id: UUID)
    case snapshotTargetNotFound(path: String)
    case snapshotIntegrityCheckFailed(snapshotID: UUID, expectedSHA256: String, actualSHA256: String)
    case snapshotUnsafeArchiveEntry(entryPath: String)
    case snapshotOperationFailed(reason: String)

    // MARK: - Recipe
    case recipeNotFound(identifier: String)
    case invalidRecipe(path: String?, reason: String)

    // MARK: - Runtimes (winetricks)
    case winetricksNotInstalled
    case invalidWinetricksVerb(String)

    public var errorDescription: String? {
        switch self {
        case let .ioError(operation, path, underlyingDescription):
            return "文件操作失败 (\(operation)) [\(path)]: \(underlyingDescription)"
        case let .encodingFailed(type, underlyingDescription):
            return "JSON 编码失败 (\(type)): \(underlyingDescription)"
        case let .decodingFailed(type, path, underlyingDescription):
            if let path {
                return "JSON 解码失败 (\(type)) [\(path)]: \(underlyingDescription)"
            }
            return "JSON 解码失败 (\(type)): \(underlyingDescription)"
        case let .invalidPath(path, reason):
            return "无效路径 [\(path)]: \(reason)"
        case let .unsupportedSchemaVersion(found, supported, path):
            if let path {
                return "不支持的配置版本 schemaVersion=\(found)（当前支持 <= \(supported)）[\(path)]"
            }
            return "不支持的配置版本 schemaVersion=\(found)（当前支持 <= \(supported)）"

        case let .engineNotFound(id):
            return "未找到指定的 Wine 引擎 (id: \(id))"
        case let .invalidEngineRoot(path, reason):
            return "无效的 Wine 引擎目录 [\(path)]: \(reason)"
        case let .engineAlreadyRegistered(id):
            return "Wine 引擎已存在 (id: \(id))"
        case let .cannotUnregisterDiscoveredEngine(id):
            return "系统自动发现的 Wine 引擎不支持移除登记 (id: \(id))"
        case .noEngineAvailable:
            return "当前未检测到可用的 Wine 引擎，请先通过 Homebrew 安装或在设置中登记本地 Wine 目录"

        case let .bottleNotFound(identifier):
            return "未找到指定的容器 (\(identifier))"
        case let .invalidBottleName(name):
            return "无效的容器名称: \"\(name)\""
        case let .bottleAlreadyExists(name):
            return "容器名称已存在: \"\(name)\""
        case let .invalidPrefixPath(path, reason):
            return "无效的 WINEPREFIX 目录 [\(path)]: \(reason)"
        case let .prefixAlreadyExists(path):
            return "目标 WINEPREFIX 目录已存在 [\(path)]"

        case let .graphicsPackageNotFound(id):
            return "未找到指定的图形转译层包 (id: \(id))"
        case let .graphicsPackageInUse(id, bottleNames):
            let joined = bottleNames.joined(separator: ", ")
            return "图形转译层包 \(id) 正在被容器使用（\(joined)），请先切换这些容器的图形后端后再删除"
        case let .invalidGraphicsArchive(path, reason):
            return "无效的图形转译层归档 [\(path)]: \(reason)"
        case let .engineMissingDLLPathPrepend(engineName, packageID):
            return "引擎 \"\(engineName)\" 不支持 WINEDLLPATH_PREPEND，无法加载 wineBuiltin 图形包 \(packageID)。请切换支持该特性的 Wine 引擎，或改用 DXVK (nativeDLLs) / WineD3D。"
        case let .graphicsBackendPackageRequired(backend):
            return "切换到 \(backend.rawValue) 需要指定或安装对应的本地图形转译层包"
        case let .graphicsDeploymentFailed(reason):
            return "图形转译层部署失败: \(reason)"
        case let .networkRequestFailed(url, statusCode, reason):
            if let statusCode {
                return "网络请求失败 (HTTP \(statusCode)) [\(url)]: \(reason)"
            }
            return "网络请求失败 [\(url)]: \(reason)"

        case let .commandExecutionFailed(executable, exitCode, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "命令执行失败 [\(executable)]，退出码 \(exitCode)"
            }
            return "命令执行失败 [\(executable)]，退出码 \(exitCode): \(trimmed)"
        case let .launchTargetNotFound(path):
            return "启动目标不存在 [\(path)]"
        case let .incompatibleArchitecture(executablePath, architecture, engineName):
            return "架构不兼容：目标程序 [\(executablePath)] 为 \(architecture.rawValue)，当前引擎 \"\(engineName)\" 不支持运行该架构"
        case let .prefixInitializationFailed(bottleName, reason):
            return "容器 \"\(bottleName)\" 初始化 WINEPREFIX 失败: \(reason)"
        case let .registryPatchFailed(reason):
            return "容器注册表写入失败: \(reason)"

        case let .invalidPEFile(path, reason):
            return "无效的 Windows PE 可执行文件 [\(path)]: \(reason)"
        case let .invalidShellLink(path, reason):
            return "无效的 Windows 快捷方式 (.lnk) [\(path)]: \(reason)"

        case let .snapshotNotFound(id):
            return "未找到指定的快照 (id: \(id.uuidString))"
        case let .snapshotTargetNotFound(path):
            return "快照目标路径不存在 [\(path)]"
        case let .snapshotIntegrityCheckFailed(snapshotID, expectedSHA256, actualSHA256):
            return "快照完整性校验失败 (id: \(snapshotID.uuidString))：期望 SHA-256 \(expectedSHA256)，实际 \(actualSHA256)，已中止回滚以保护现有文件"
        case let .snapshotUnsafeArchiveEntry(entryPath):
            return "快照归档包含不安全的路径条目 [\(entryPath)]，已拒绝解压以防止路径穿越"
        case let .snapshotOperationFailed(reason):
            return "快照操作失败: \(reason)"

        case let .recipeNotFound(identifier):
            return "未找到指定的兼容配方 (\(identifier))"
        case .winetricksNotInstalled:
            return "未检测到 winetricks，请先执行 brew install winetricks"
        case let .invalidWinetricksVerb(verb):
            return "无效的 winetricks 组件名：\(verb)（只允许小写字母、数字、下划线与 = 号）"
        case let .invalidRecipe(path, reason):
            if let path {
                return "无效的兼容配方文件 [\(path)]: \(reason)"
            }
            return "无效的兼容配方: \(reason)"
        }
    }
}
