import Foundation

/// 「一键准备运行环境」中的一个步骤。普通用户界面只展示这些白话步骤，不展示预检细节。
public struct SetupStep: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// Apple Silicon 运行 x86 程序所需
        case rosetta
        /// 用于安装开源 Wine 引擎
        case homebrew
        /// 开源 Wine 引擎本体
        case wineEngine
        /// 已安装的引擎被 macOS 隔离，App 内即可解除，无需终端
        case unquarantineEngine
        /// 运行库安装工具（可选，用于诊断后的一键修复）
        case winetricks
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    /// 缺少它就无法启动任何 Windows 程序
    public var isRequired: Bool
    /// 仅 `.unquarantineEngine` 使用
    public var engineID: String?

    public var id: String { kind.rawValue + (engineID.map { "-\($0)" } ?? "") }

    /// 需要在「终端」里执行（可能要求输入开机密码），否则由 App 直接完成。
    public var runsInTerminal: Bool { kind != .unquarantineEngine }

    public init(kind: Kind, title: String, detail: String, isRequired: Bool, engineID: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isRequired = isRequired
        self.engineID = engineID
    }
}

/// 把预检报告翻译成「还差哪几步」，并把需要终端的步骤合成一条脚本，让用户只点一次按钮。
public enum EnvironmentSetupPlanner {
    static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    public static func steps(for report: PreflightReport) -> [SetupStep] {
        var steps: [SetupStep] = []

        if report.architecture == .arm64 && !report.rosetta2Ready {
            steps.append(
                SetupStep(
                    kind: .rosetta,
                    title: "安装 Rosetta 2",
                    detail: "苹果官方组件，让 M 系列芯片能运行为 Intel 编写的 Windows 程序。",
                    isRequired: true
                )
            )
        }

        let usableEngines = report.discoveredEngines.filter { !$0.isQuarantined }
        let quarantinedEngines = report.discoveredEngines.filter(\.isQuarantined)

        if report.discoveredEngines.isEmpty {
            if report.homebrewPath == nil {
                steps.append(
                    SetupStep(
                        kind: .homebrew,
                        title: "安装 Homebrew",
                        detail: "Mac 上最常用的开源软件安装工具，用来下载 Wine。",
                        isRequired: true
                    )
                )
            }
            steps.append(
                SetupStep(
                    kind: .wineEngine,
                    title: "安装 Wine",
                    detail: "开源的 Windows 兼容层，是运行 Windows 程序的核心。",
                    isRequired: true
                )
            )
        }

        for engine in quarantinedEngines {
            steps.append(
                SetupStep(
                    kind: .unquarantineEngine,
                    title: "允许运行「\(engine.name)」",
                    detail: "macOS 默认会拦截从网上下载的程序，点一下即可放行。",
                    isRequired: usableEngines.isEmpty,
                    engineID: engine.id
                )
            )
        }

        if report.winetricksPath == nil {
            steps.append(
                SetupStep(
                    kind: .winetricks,
                    title: "安装运行库工具",
                    detail: "可选。程序缺少 VC++、DirectX 等组件时，Vermouth 可以自动帮你补上。",
                    isRequired: false
                )
            )
        }

        return steps
    }

    /// 是否已经可以启动 Windows 程序（没有必需步骤）。
    public static func isReady(_ report: PreflightReport) -> Bool {
        report.isReadyToLaunch && !steps(for: report).contains(where: \.isRequired)
    }

    /// 把需要终端的步骤按依赖顺序合成一条 bash 脚本；没有终端步骤时返回 `nil`。
    /// 不依赖 Homebrew 可能移除的便捷参数（L-019），每一步都打印中文进度。
    public static func terminalScript(for steps: [SetupStep]) -> String? {
        let order: [SetupStep.Kind] = [.rosetta, .homebrew, .wineEngine, .winetricks]
        let kinds = order.filter { kind in steps.contains { $0.kind == kind && $0.runsInTerminal } }
        guard !kinds.isEmpty else { return nil }

        var lines: [String] = [
            "#!/bin/bash",
            "# 由 Vermouth 生成：准备运行 Windows 程序所需的环境",
            "set -e",
            "echo \"==> Vermouth 正在准备运行环境，过程中可能需要输入开机密码。\"",
        ]

        for (index, kind) in kinds.enumerated() {
            let header = "[\(index + 1)/\(kinds.count)]"
            lines.append("echo \"\"")
            switch kind {
            case .rosetta:
                lines.append("echo \"==> \(header) 安装 Rosetta 2\"")
                lines.append("softwareupdate --install-rosetta --agree-to-license")
            case .homebrew:
                lines.append("echo \"==> \(header) 安装 Homebrew\"")
                lines.append(homebrewInstallCommand)
            case .wineEngine:
                lines.append("echo \"==> \(header) 安装 Wine（约 300 MB，请耐心等待）\"")
                lines.append(contentsOf: brewShellEnvLines)
                lines.append("brew install --cask gcenx/wine/wine-stable")
                lines.append("if [ -d \"/Applications/Wine Stable.app\" ]; then xattr -dr com.apple.quarantine \"/Applications/Wine Stable.app\"; fi")
            case .winetricks:
                lines.append("echo \"==> \(header) 安装运行库工具 winetricks\"")
                lines.append(contentsOf: brewShellEnvLines)
                lines.append("brew install winetricks")
            case .unquarantineEngine:
                break
            }
        }

        lines.append("echo \"\"")
        lines.append("echo \"✅ 全部完成！现在可以关掉这个窗口，回到 Vermouth 了。\"")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 刚装完 Homebrew 时当前 shell 还找不到 `brew`，先按官方路径载入。
    private static let brewShellEnvLines = [
        "if [ -x /opt/homebrew/bin/brew ]; then eval \"$(/opt/homebrew/bin/brew shellenv)\"; elif [ -x /usr/local/bin/brew ]; then eval \"$(/usr/local/bin/brew shellenv)\"; fi",
    ]
}
