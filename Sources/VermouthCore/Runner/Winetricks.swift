import Foundation

/// 一个可通过 winetricks 安装的常用 Windows 组件（运行库、DirectX 辅助库、字体、系统设置）。
public struct WinetricksVerb: Codable, Equatable, Identifiable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case runtime
        case directx
        case fonts
        case settings

        public var displayName: String {
            switch self {
            case .runtime: "运行库"
            case .directx: "DirectX 组件"
            case .fonts: "字体"
            case .settings: "系统设置"
            }
        }
    }

    /// winetricks 组件名（如 `vcrun2022`）
    public let id: String
    public let title: String
    public let detail: String
    public let category: Category
    /// 是否为大多数游戏推荐预装
    public let isRecommended: Bool

    public init(id: String, title: String, detail: String, category: Category, isRecommended: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.category = category
        self.isRecommended = isRecommended
    }
}

/// 精选 winetricks 组件目录：覆盖 `CrashDiagnoser` 缺失 DLL 映射到的全部运行库与常见游戏依赖。
public enum WinetricksCatalog: Sendable {
    public static let verbs: [WinetricksVerb] = [
        WinetricksVerb(id: "vcrun2022", title: "Visual C++ 2015–2022", detail: "现代游戏最常见依赖（vcruntime140 / msvcp140）", category: .runtime, isRecommended: true),
        WinetricksVerb(id: "vcrun2013", title: "Visual C++ 2013", detail: "msvcr120 / msvcp120", category: .runtime),
        WinetricksVerb(id: "vcrun2012", title: "Visual C++ 2012", detail: "msvcr110 / msvcp110", category: .runtime),
        WinetricksVerb(id: "vcrun2010", title: "Visual C++ 2010", detail: "msvcr100 / msvcp100", category: .runtime),
        WinetricksVerb(id: "vcrun2008", title: "Visual C++ 2008", detail: "msvcr90，老游戏常用", category: .runtime),
        WinetricksVerb(id: "vcrun6", title: "Visual C++ 6", detail: "msvcp60，千禧年代游戏", category: .runtime),
        WinetricksVerb(id: "dotnet48", title: ".NET Framework 4.8", detail: "Mod 管理器、启动器与工具（安装较慢）", category: .runtime),
        WinetricksVerb(id: "xna40", title: "XNA Framework 4.0", detail: "独立游戏常见框架", category: .runtime),
        WinetricksVerb(id: "physx", title: "NVIDIA PhysX", detail: "部分 DX9/DX11 游戏的物理引擎", category: .runtime),
        WinetricksVerb(id: "d3dx9", title: "D3DX9", detail: "d3dx9_xx.dll，DX9 游戏必备", category: .directx, isRecommended: true),
        WinetricksVerb(id: "d3dcompiler_47", title: "D3DCompiler 47", detail: "DX11 着色器编译器", category: .directx, isRecommended: true),
        WinetricksVerb(id: "d3dcompiler_43", title: "D3DCompiler 43", detail: "较老的 DX10/11 着色器编译器", category: .directx),
        WinetricksVerb(id: "d3dx11_43", title: "D3DX11", detail: "d3dx11_43.dll", category: .directx),
        WinetricksVerb(id: "mf", title: "Media Foundation", detail: "游戏内视频 / 过场动画播放", category: .directx),
        WinetricksVerb(id: "xact", title: "XACT 音频", detail: "xactengine / x3daudio，修复无声", category: .directx),
        WinetricksVerb(id: "xinput", title: "XInput", detail: "手柄支持（xinput1_3）", category: .directx),
        WinetricksVerb(id: "corefonts", title: "微软核心字体", detail: "Arial、Times New Roman 等", category: .fonts, isRecommended: true),
        WinetricksVerb(id: "cjkfonts", title: "中日韩字体", detail: "解决方块乱码的备用方案", category: .fonts),
        WinetricksVerb(id: "win10", title: "设为 Windows 10", detail: "等同于在容器配置中切换系统版本", category: .settings),
    ]

    public static func verb(id: String) -> WinetricksVerb? {
        verbs.first { $0.id == id }
    }

    public static var recommendedIDs: [String] {
        verbs.filter(\.isRecommended).map(\.id)
    }
}

/// 把容器的标准 `LaunchPlan` 转换为 winetricks 安装计划。
///
/// 复用 `EnvironmentBuilder` 生成的同一套环境变量（`WINEPREFIX`、同步模式、DLL 覆写等，满足 L-003），
/// 再告诉 winetricks 使用容器绑定的引擎（`WINE` / `WINESERVER`），避免它误用系统 PATH 里的另一套 Wine。
public enum WinetricksPlanner: Sendable {
    public static func makePlan(
        basedOn base: LaunchPlan,
        winetricksPath: String,
        verbs: [String],
        unattended: Bool = true
    ) throws -> LaunchPlan {
        let trimmedPath = winetricksPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw VermouthError.winetricksNotInstalled
        }
        let normalized = try normalize(verbs)

        var environment = base.environment
        environment["WINE"] = base.engine.wineBinaryPath
        environment["WINESERVER"] = base.engine.wineserverPath

        var arguments: [String] = []
        if unattended {
            arguments.append("-q")
        }
        arguments.append(contentsOf: normalized)

        let logURL = URL(fileURLWithPath: base.logFilePath)
        let logFilePath = logURL
            .deletingLastPathComponent()
            .appendingPathComponent(logURL.deletingPathExtension().lastPathComponent + "-winetricks.log")
            .path

        var plan = base
        plan.executablePath = trimmedPath
        plan.arguments = arguments
        plan.environment = environment
        plan.logFilePath = logFilePath
        plan.shellCommandPreview = ShellQuoting.formatCommand(
            environment: environment,
            executable: trimmedPath,
            arguments: arguments
        )
        return plan
    }

    /// 去重、保序，并拒绝任何可能被当作参数或 shell 片段的输入（只允许 `[a-z0-9_=]`，且不能以 `-` 开头）。
    public static func normalize(_ verbs: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in verbs {
            let verb = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !verb.isEmpty,
                  verb.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "=" }),
                  verb.first != "="
            else {
                throw VermouthError.invalidWinetricksVerb(raw)
            }
            if seen.insert(verb).inserted {
                result.append(verb)
            }
        }
        guard !result.isEmpty else {
            throw VermouthError.invalidWinetricksVerb("")
        }
        return result
    }
}
