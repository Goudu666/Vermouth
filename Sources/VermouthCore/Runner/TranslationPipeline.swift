import Foundation

/// 转译链路中的一段（UI 用来画 `x86 程序 → Rosetta 2 → Wine → 图形层 → Metal` 管线）。
public struct TranslationStage: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Windows 程序本身（x86 / x64 指令）
        case windowsProgram
        /// 指令集转译（Rosetta 2）
        case instructionTranslation
        /// Windows API 兼容层（Wine）
        case wine
        /// DirectX → 下层图形 API 的转译层（DXMT / DXVK / WineD3D）
        case graphicsTranslation
        /// 中间图形 API（MoltenVK、OpenGL）
        case intermediateAPI
        /// 最终落到的 Apple GPU 接口（Metal）
        case metal
    }

    public var id: String { "\(kind.rawValue)-\(title)" }
    public let kind: Kind
    public let title: String
    public let detail: String
    /// 该段是否已就绪（如 Rosetta 未安装、未选择引擎时为 `false`，UI 显示警示色）。
    public let isReady: Bool

    public init(kind: Kind, title: String, detail: String, isReady: Bool = true) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isReady = isReady
    }
}

/// 根据容器配置、引擎与环境推导完整转译链路。纯函数，无 I/O。
public enum TranslationPipeline: Sendable {
    public static func stages(
        backend: GraphicsBackend,
        engine: WineEngine?,
        programArchitecture: PEArchitecture? = nil,
        rosettaReady: Bool? = nil
    ) -> [TranslationStage] {
        var stages: [TranslationStage] = []

        let archTitle: String
        switch programArchitecture {
        case .x86_32: archTitle = "32 位程序"
        case .x86_64: archTitle = "64 位程序"
        case .arm64: archTitle = "ARM64 程序"
        default: archTitle = "Windows 程序"
        }
        stages.append(TranslationStage(kind: .windowsProgram, title: archTitle, detail: "PE · DirectX"))

        if programArchitecture != .arm64 {
            stages.append(TranslationStage(
                kind: .instructionTranslation,
                title: "Rosetta 2",
                detail: "x86_64 → arm64",
                isReady: rosettaReady ?? true
            ))
        }

        if let engine {
            stages.append(TranslationStage(kind: .wine, title: shortWineTitle(engine), detail: "Win32 API → macOS"))
        } else {
            stages.append(TranslationStage(kind: .wine, title: "Wine", detail: "未选择引擎", isReady: false))
        }

        switch backend {
        case .dxmt:
            stages.append(TranslationStage(kind: .graphicsTranslation, title: "DXMT", detail: "D3D10/11 → Metal"))
        case .dxvk:
            stages.append(TranslationStage(kind: .graphicsTranslation, title: "DXVK", detail: "D3D9/10/11 → Vulkan"))
            stages.append(TranslationStage(kind: .intermediateAPI, title: "MoltenVK", detail: "Vulkan → Metal"))
        case .wined3d:
            stages.append(TranslationStage(kind: .graphicsTranslation, title: "WineD3D", detail: "D3D → OpenGL"))
            stages.append(TranslationStage(kind: .intermediateAPI, title: "OpenGL", detail: "Apple GL → Metal"))
        }

        stages.append(TranslationStage(kind: .metal, title: "Metal", detail: "Apple GPU"))
        return stages
    }

    /// 从 `wine --version` 输出（如 `wine-11.0 (Staging)`）提炼短标题 `Wine 11.0`。
    static func shortWineTitle(_ engine: WineEngine) -> String {
        let raw = engine.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = raw.lowercased().hasPrefix("wine-") ? String(raw.dropFirst(5)) : raw
        let version = withoutPrefix.split(separator: " ").first.map(String.init) ?? ""
        guard let first = version.first, first.isNumber else {
            return "Wine"
        }
        return "Wine \(version)"
    }
}
