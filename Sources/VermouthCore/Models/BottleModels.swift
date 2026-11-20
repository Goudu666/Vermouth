import Foundation

/// 容器模拟的 Windows 目标版本。
public enum WindowsVersion: String, Codable, CaseIterable, Equatable, Sendable {
    case winxp
    case win7
    case win10
    case win11
}

/// Wine 进程同步原语模式。
public enum SyncMode: String, Codable, CaseIterable, Equatable, Sendable {
    case msync
    case esync
    case none
}

/// DirectX 图形转译后端。
public enum GraphicsBackend: String, Codable, CaseIterable, Equatable, Sendable {
    case wined3d
    /// `Gcenx/DXVK-macOS`
    case dxvk
    /// `3Shain/dxmt`
    case dxmt
}

/// `WINEDLLOVERRIDES` 单条 DLL 加载顺序模式。
public enum DllOverrideMode: String, Codable, CaseIterable, Equatable, Sendable {
    case nativeThenBuiltin = "n,b"
    case builtinThenNative = "b,n"
    case nativeOnly = "n"
    case builtinOnly = "b"
    case disabled = ""
}

/// 单条 DLL 覆写规则（在 `init` 与 `init(from:)` 统一规范化 `dllName` 以避免 ID 冲突，符合 L-011）。
public struct DllOverride: Codable, Equatable, Identifiable, Sendable {
    public var id: String { dllName }
    public let dllName: String
    public var mode: DllOverrideMode
    public var enabled: Bool
    public var note: String?

    private enum CodingKeys: String, CodingKey {
        case dllName
        case mode
        case enabled
        case note
    }

    public init(
        dllName: String,
        mode: DllOverrideMode = .nativeThenBuiltin,
        enabled: Bool = true,
        note: String? = nil
    ) {
        self.dllName = Self.normalizeName(dllName)
        self.mode = mode
        self.enabled = enabled
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try container.decode(String.self, forKey: .dllName)
        self.dllName = Self.normalizeName(rawName)
        self.mode = try container.decode(DllOverrideMode.self, forKey: .mode)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dllName, forKey: .dllName)
        try container.encode(mode, forKey: .mode)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(note, forKey: .note)
    }

    /// 规范化 DLL 名称：去除首尾空白、转小写并移除 `.dll` 后缀。
    public static func normalizeName(_ raw: String) -> String {
        var normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalized.hasSuffix(".dll") {
            normalized.removeLast(4)
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    /// PRD §4.1F 内置高频快捷预设（ASI / CLEO / ModLoader / BepInEx 等常见钩子）。
    public static let commonPresets: [DllOverride] = [
        DllOverride(
            dllName: "dinput8",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "ASI Loader / Ultimate ASI Loader / 常见 DirectInput Mod 钩子"
        ),
        DllOverride(
            dllName: "vorbisFile",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "vorbisFile — GTA: San Andreas ASI / CLEO 钩子"
        ),
        DllOverride(
            dllName: "winhttp",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "BepInEx / Unity Mod Doorstop 入口"
        ),
        DllOverride(
            dllName: "version",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "ModLoader / 版本代理钩子"
        ),
        DllOverride(
            dllName: "dsound",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "DirectSound 音频补丁 / EAX 还原钩子"
        ),
        DllOverride(
            dllName: "d3d9",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "DX9 画面补丁 / SilentPatch / ReShade 代理"
        ),
    ]
}

/// Wine 虚拟桌面配置。
public struct VirtualDesktopConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var width: Int
    public var height: Int

    public init(enabled: Bool = false, width: Int = 1280, height: Int = 720) {
        self.enabled = enabled
        self.width = width
        self.height = height
    }
}

/// 容器显示与性能叠加配置。
public struct DisplayConfig: Codable, Equatable, Sendable {
    public var retinaMode: Bool
    /// 常见 DPI 档位：96 / 144 / 192
    public var dpi: Int
    /// 对应 `MTL_HUD_ENABLED=1`
    public var metalHUD: Bool
    public var virtualDesktop: VirtualDesktopConfig

    public init(
        retinaMode: Bool = false,
        dpi: Int = 96,
        metalHUD: Bool = false,
        virtualDesktop: VirtualDesktopConfig = VirtualDesktopConfig()
    ) {
        self.retinaMode = retinaMode
        self.dpi = dpi
        self.metalHUD = metalHUD
        self.virtualDesktop = virtualDesktop
    }
}

/// 容器中文语言与字体回退配置。
public struct LocaleConfig: Codable, Equatable, Sendable {
    public var chineseLocalizationEnabled: Bool
    /// 开启时默认 `"zh_CN.UTF-8"`
    public var lcAll: String
    /// 本机可用中文字体回退名（如 `STHeiti` / `Hiragino Sans GB` / `PingFang SC`）
    public var fallbackFontName: String

    public init(
        chineseLocalizationEnabled: Bool = false,
        lcAll: String = "zh_CN.UTF-8",
        fallbackFontName: String = "STHeiti"
    ) {
        self.chineseLocalizationEnabled = chineseLocalizationEnabled
        self.lcAll = lcAll
        self.fallbackFontName = fallbackFontName
    }
}

/// 容器内固定或已配置的 Windows 应用程序入口。
public struct AppEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// 相对 prefix 或宿主机绝对路径
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environmentOverrides: [String: String]
    public var dllOverrides: [DllOverride]
    public var snapshotTargets: [SnapshotTarget]
    public var isPinned: Bool
    public var lastLaunchedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environmentOverrides: [String: String] = [:],
        dllOverrides: [DllOverride] = [],
        snapshotTargets: [SnapshotTarget] = [],
        isPinned: Bool = false,
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
        self.dllOverrides = dllOverrides
        self.snapshotTargets = snapshotTargets
        self.isPinned = isPinned
        self.lastLaunchedAt = lastLaunchedAt
    }
}

/// 容器期望转译配置（持久化于 `bottle.json`）。
public struct BottleConfig: Codable, Equatable, Sendable {
    public var engineID: String?
    public var windowsVersion: WindowsVersion
    public var syncMode: SyncMode
    public var graphicsBackend: GraphicsBackend
    public var graphicsLayerVersionID: String?
    public var display: DisplayConfig
    public var locale: LocaleConfig
    public var dllOverrides: [DllOverride]
    public var environmentVariables: [String: String]
    /// 默认 `"-all,err+all"`
    public var wineDebugChannels: String

    public init(
        engineID: String? = nil,
        windowsVersion: WindowsVersion = .win10,
        syncMode: SyncMode = .msync,
        graphicsBackend: GraphicsBackend = .wined3d,
        graphicsLayerVersionID: String? = nil,
        display: DisplayConfig = DisplayConfig(),
        locale: LocaleConfig = LocaleConfig(),
        dllOverrides: [DllOverride] = [],
        environmentVariables: [String: String] = [:],
        wineDebugChannels: String = "-all,err+all"
    ) {
        self.engineID = engineID
        self.windowsVersion = windowsVersion
        self.syncMode = syncMode
        self.graphicsBackend = graphicsBackend
        self.graphicsLayerVersionID = graphicsLayerVersionID
        self.display = display
        self.locale = locale
        self.dllOverrides = dllOverrides
        self.environmentVariables = environmentVariables
        self.wineDebugChannels = wineDebugChannels
    }
}

/// 容器完整持久化模型（`bottle.json`，当前 `schemaVersion == 1`）。
public struct Bottle: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var prefixPath: String
    /// 为 `true` 时表示外部引用导入的 `WINEPREFIX`，删除容器时严禁删除该外部目录（L-005）
    public var isExternalPrefix: Bool
    public var config: BottleConfig
    public var apps: [AppEntry]
    public var appliedRecipeID: String?

    public init(
        schemaVersion: Int = Bottle.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        prefixPath: String,
        isExternalPrefix: Bool = false,
        config: BottleConfig = BottleConfig(),
        apps: [AppEntry] = [],
        appliedRecipeID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.prefixPath = prefixPath
        self.isExternalPrefix = isExternalPrefix
        self.config = config
        self.apps = apps
        self.appliedRecipeID = appliedRecipeID
    }
}
