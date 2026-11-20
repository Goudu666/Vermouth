import Foundation

/// 已知无害的 Wine 报错规则：某个可选辅助程序缺少某些 DLL，加载失败不影响主程序。
///
/// 规则按「导入方程序文件名 + 缺失 DLL 名」精确匹配，只针对具体的辅助程序；
/// 主程序缺同名 DLL 时导入方不同，仍按正常规则报错。
public struct KnownBenignImportFailure: Equatable, Sendable {
    /// 导入方程序的文件名（小写，如 `gldriverquery.exe`）
    public let importerFileNames: Set<String>
    /// 缺失后无害的 DLL（小写带后缀，如 `sdl2.dll`）
    public let missingDLLs: Set<String>
    /// 给用户看的说明
    public let reason: String

    public init(importerFileNames: Set<String>, missingDLLs: Set<String>, reason: String) {
        self.importerFileNames = importerFileNames
        self.missingDLLs = missingDLLs
        self.reason = reason
    }
}

/// 识别已知无害的 Wine 报错行，供 `CrashDiagnoser`（不生成诊断）与 `WineLogClassifier`（降为 info）共用。
public enum KnownBenignLogLines: Sendable {
    public static let importFailures: [KnownBenignImportFailure] = [
        KnownBenignImportFailure(
            importerFileNames: ["gldriverquery.exe", "gldriverquery64.exe"],
            missingDLLs: ["sdl2.dll"],
            reason: "Steam 自带的可选 GPU 驱动探测工具 bin\\gldriverquery.exe 依赖 SDL2.dll，加载失败只会跳过探测，不影响 Steam 本体。"
        ),
    ]

    /// `err:module:import_dll Library SDL2.dll (which is needed by L"C:\\...\\gldriverquery.exe") not found`
    private static let importDLLPattern =
        #"(?i)err:module:import_dll\s+Library\s+([^\s("']+\.dll)\s+\(which is needed by\s+L?"(.+?)"\)"#
    /// `err:module:loader_init Importing dlls for L"C:\\...\\gldriverquery.exe" failed, status c0000135`
    private static let loaderInitPattern =
        #"(?i)err:module:loader_init\s+Importing dlls for\s+L?"(.+?)"\s+failed"#

    /// 返回命中的无害规则；不是已知无害行时返回 `nil`。
    public static func match(_ line: String) -> KnownBenignImportFailure? {
        if let captures = captureGroups(in: line, pattern: importDLLPattern), captures.count == 2 {
            let dll = captures[0].lowercased()
            let importer = importerFileName(captures[1])
            return importFailures.first {
                $0.missingDLLs.contains(dll) && $0.importerFileNames.contains(importer)
            }
        }
        if let captures = captureGroups(in: line, pattern: loaderInitPattern), captures.count == 1 {
            let importer = importerFileName(captures[0])
            return importFailures.first { $0.importerFileNames.contains(importer) }
        }
        return nil
    }

    /// 取 Windows 路径的文件名（Wine 日志里反斜杠会被转义成 `\\`）。
    private static func importerFileName(_ windowsPath: String) -> String {
        let components = windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        return (components.last.map(String.init) ?? windowsPath).lowercased()
    }

    private static func captureGroups(in text: String, pattern: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { nsText.substring(with: match.range(at: $0)) }
    }
}
