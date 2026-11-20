import Foundation

/// 宿主机操作系统版本信息。
public struct OSVersionInfo: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let displayString: String

    public init(major: Int, minor: Int, patch: Int = 0, displayString: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.displayString = displayString
    }

    public func isAtLeast(major: Int, minor: Int = 0) -> Bool {
        if self.major != major {
            return self.major > major
        }
        return self.minor >= minor
    }
}

/// 宿主机 CPU 架构类型。
public enum HostArchitecture: String, Codable, Equatable, CaseIterable, Sendable {
    case arm64
    case x86_64
    case unknown
}

/// Wine 引擎来源分类。
public enum EngineSource: String, Codable, Equatable, CaseIterable, Sendable {
    /// `/Applications/Wine *.app` 或 `/opt/homebrew`
    case homebrewCask
    /// `CrossOver.app` 或其他 `.app` 捆绑包
    case applicationBundle
    /// `~/Library/Application Support/Vermouth/Engines/` 托管目录
    case managed
    /// 用户手动登记的自定义目录
    case custom
}

/// 通过只读目录结构与二进制符号探测得到的 Wine 引擎能力集合。
public struct EngineCapabilities: Codable, Equatable, Sendable {
    public var supports32Bit: Bool
    public var supports64Bit: Bool
    /// Wine 9+ 单 `bin/wine` 新 WoW64 模式（禁止设置 `WINEARCH=win32`）
    public var isNewWoW64: Bool
    public var supportsMSync: Bool
    public var supportsWineDLLPathPrepend: Bool

    public init(
        supports32Bit: Bool = false,
        supports64Bit: Bool = true,
        isNewWoW64: Bool = false,
        supportsMSync: Bool = false,
        supportsWineDLLPathPrepend: Bool = false
    ) {
        self.supports32Bit = supports32Bit
        self.supports64Bit = supports64Bit
        self.isNewWoW64 = isNewWoW64
        self.supportsMSync = supportsMSync
        self.supportsWineDLLPathPrepend = supportsWineDLLPathPrepend
    }
}

/// 已发现或手动登记的本机 Wine 引擎描述。
public struct WineEngine: Codable, Equatable, Identifiable, Sendable {
    /// 稳定标识符（如 `"app-wine-stable"` 或自定义 UUID）
    public var id: String
    /// 展示名称（如 `"Wine Stable 11.0 (WoW64)"`）
    public var name: String
    /// 引擎根目录（含 `bin/` 与 `lib/wine/`）
    public var rootPath: String
    /// 实际可执行路径（`wine` 或 `wine64`）
    public var wineBinaryPath: String
    /// `wineserver` 可执行路径
    public var wineserverPath: String
    /// `wine --version` 原始输出
    public var version: String
    public var source: EngineSource
    public var capabilities: EngineCapabilities
    public var isQuarantined: Bool

    public init(
        id: String,
        name: String,
        rootPath: String,
        wineBinaryPath: String,
        wineserverPath: String,
        version: String,
        source: EngineSource,
        capabilities: EngineCapabilities,
        isQuarantined: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.wineBinaryPath = wineBinaryPath
        self.wineserverPath = wineserverPath
        self.version = version
        self.source = source
        self.capabilities = capabilities
        self.isQuarantined = isQuarantined
    }
}

/// 启动预检单项检查结果。
public struct PreflightCheckItem: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Equatable, CaseIterable, Sendable {
        case pass
        case warning
        case fail
    }

    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    /// 一键复制的终端引导命令（绝不静默执行）
    public var remediationCommand: String?

    public init(
        id: String,
        title: String,
        status: Status,
        detail: String,
        remediationCommand: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remediationCommand = remediationCommand
    }
}

/// 环境预检汇总报告。
public struct PreflightReport: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var architecture: HostArchitecture
    public var osVersion: OSVersionInfo
    public var rosetta2Ready: Bool
    public var homebrewPath: String?
    public var winetricksPath: String?
    public var discoveredEngines: [WineEngine]
    public var items: [PreflightCheckItem]
    public var isReadyToLaunch: Bool

    public init(
        checkedAt: Date = Date(),
        architecture: HostArchitecture,
        osVersion: OSVersionInfo,
        rosetta2Ready: Bool,
        homebrewPath: String? = nil,
        winetricksPath: String? = nil,
        discoveredEngines: [WineEngine] = [],
        items: [PreflightCheckItem] = [],
        isReadyToLaunch: Bool
    ) {
        self.checkedAt = checkedAt
        self.architecture = architecture
        self.osVersion = osVersion
        self.rosetta2Ready = rosetta2Ready
        self.homebrewPath = homebrewPath
        self.winetricksPath = winetricksPath
        self.discoveredEngines = discoveredEngines
        self.items = items
        self.isReadyToLaunch = isReadyToLaunch
    }
}
