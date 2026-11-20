import Foundation

/// 用户拖进来的 Windows 文件是「安装程序」还是「可以直接运行的程序」。
public enum ProgramFileKind: String, Equatable, Sendable {
    /// 运行后把软件装进 Windows 环境（`.msi`、`setup.exe` 等）
    case installer
    /// 免安装程序 / 已经解压好的游戏本体，直接加入程序库
    case application
}

/// 根据文件名猜测文件类型并生成好看的显示名称。猜测只用于决定默认按钮，用户始终可以改选。
public enum ProgramFileClassifier {
    /// 支持拖入的扩展名
    public static let supportedExtensions: Set<String> = ["exe", "msi"]

    private static let installerKeywords = [
        "setup", "install", "installer", "安装", "redist", "bootstrapper",
    ]

    /// 卸载程序、崩溃上报等不该出现在程序库里的文件
    private static let helperKeywords = [
        "unins", "uninstall", "卸载", "crashreport", "crashhandler", "updater",
    ]

    /// 返回 `nil` 表示不是支持的 Windows 程序文件。
    public static func classify(fileName: String) -> ProgramFileKind? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return nil }
        if ext == "msi" { return .installer }

        let stem = (fileName as NSString).deletingPathExtension.lowercased()
        if installerKeywords.contains(where: { stem.contains($0) }) {
            return .installer
        }
        return .application
    }

    /// 是否是卸载器 / 更新器之类的辅助程序（安装后自动加入程序库时跳过）。
    public static func isHelperExecutable(fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension.lowercased()
        return helperKeywords.contains(where: { stem.contains($0) })
    }

    /// 引擎打包常见的中间层目录，向上跳过它们继续找游戏名
    private static let buildFolderNames: Set<String> = [
        "bin", "bin32", "bin64", "binaries", "win32", "win64", "x86", "x64", "game",
    ]

    /// 没有信息量的位置：遇到就放弃文件夹名，改用文件名
    private static let genericFolderNames: Set<String> = [
        "desktop", "downloads", "documents", "games", "program files", "program files (x86)",
        "drive_c", "applications", "tmp", "temp", "桌面", "下载", "文稿",
    ]

    /// 免安装程序优先用所在文件夹名（`~/Games/GTA San Andreas/gta_sa.exe` → `GTA San Andreas`），
    /// 文件夹名没有信息量时（Downloads、bin、Win64…）退回文件名。
    public static func suggestedDisplayName(forFileAt path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        if classify(fileName: fileName) == .application {
            var folder = url.deletingLastPathComponent()
            // UE / Unity 常见结构：Game/Binaries/Win64/Game.exe
            for _ in 0..<3 where buildFolderNames.contains(folder.lastPathComponent.lowercased()) {
                folder = folder.deletingLastPathComponent()
            }
            let folderName = folder.lastPathComponent
            let lower = folderName.lowercased()
            if !folderName.isEmpty, folderName != "/",
               !genericFolderNames.contains(lower), !buildFolderNames.contains(lower)
            {
                return folderName
            }
        }
        return suggestedDisplayName(forFileName: fileName)
    }

    /// `GTA_San_Andreas-Setup_v1.0.exe` → `GTA San Andreas`；`gta_sa.exe` → `gta sa`
    public static func suggestedDisplayName(forFileName fileName: String) -> String {
        var stem = (fileName as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")

        let noiseWords: Set<String> = [
            "setup", "install", "installer", "x64", "x86", "win64", "win32", "64bit", "32bit", "full",
        ]
        let words = stem.split(separator: " ").map(String.init).filter { word in
            let lower = word.lowercased()
            if noiseWords.contains(lower) { return false }
            // 去掉版本号：v1.0、1.2.3、v2
            if lower.range(of: #"^v?\d+(\d|\.)*$"#, options: .regularExpression) != nil { return false }
            return true
        }

        let cleaned = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty {
            return (fileName as NSString).deletingPathExtension
        }
        return cleaned
    }
}
