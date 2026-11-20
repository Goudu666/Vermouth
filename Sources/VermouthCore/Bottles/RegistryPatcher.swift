import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Windows 注册表（`.reg`）生成器与应用器（严格遵循 L-009 与 L-016）：
/// - 强制输出 `Windows Registry Editor Version 5.00` + CRLF + UTF-16LE BOM（支持中文键名如 `宋体`/`微软雅黑`）
/// - `FontLink\SystemLink` 严格编码为 `REG_MULTI_SZ` (`hex(7):...`)
/// - 关闭虚拟桌面或中文补全时显式输出 `"Key"=-` 删除语法以确保彻底回退
public struct RegistryPatcher: Sendable {
    /// macOS 系统内置中文字体优先探测清单。
    public static let preferredMacOSCJKFonts: [(name: String, filePaths: [String])] = [
        (
            name: "STHeiti",
            filePaths: [
                "/System/Library/Fonts/STHeiti Light.ttc",
                "/System/Library/Fonts/STHeiti Medium.ttc",
                "/System/Library/Fonts/Supplemental/STHeiti Light.ttc",
                "/System/Library/Fonts/Supplemental/STHeiti Medium.ttc",
            ]
        ),
        (
            name: "Hiragino Sans GB",
            filePaths: [
                "/System/Library/Fonts/Hiragino Sans GB.ttc",
                "/System/Library/Fonts/Supplemental/Hiragino Sans GB.ttc",
            ]
        ),
        (
            name: "Songti SC",
            filePaths: [
                "/System/Library/Fonts/Supplemental/Songti.ttc",
                "/System/Library/Fonts/Songti.ttc",
            ]
        ),
        (
            name: "PingFang SC",
            filePaths: [
                "/System/Library/Fonts/PingFang.ttc",
                "/System/Library/Fonts/Supplemental/PingFang.ttc",
            ]
        ),
    ]

    private static let fontLinkBaseFonts: [String] = [
        "Tahoma",
        "Microsoft Sans Serif",
        "Segoe UI",
        "MS Shell Dlg",
        "MS Shell Dlg 2",
        "Arial",
        "Lucida Sans Unicode",
    ]

    private static let chineseFontSubstituteKeys: [String] = [
        "SimSun",
        "宋体",
        "NSimSun",
        "新宋体",
        "Microsoft YaHei",
        "微软雅黑",
        "SimHei",
        "黑体",
    ]

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    public init() {}

    /// 探测本机实际存在的 macOS 中文字体，若无匹配（如非 macOS 测试环境）安全回退 `"STHeiti"`。
    public static func detectAvailableCJKFont(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        for candidate in preferredMacOSCJKFonts {
            if candidate.filePaths.contains(where: fileExists) {
                return candidate.name
            }
        }
        return "STHeiti"
    }

    /// 将字符串数组编码为 `.reg` Version 5.00 的 `REG_MULTI_SZ` 格式（`hex(7):xx,xx,...`）。
    /// 每个字符串按 UTF-16LE 小端编码并追加 `00,00`，末尾追加 `00,00` 双零终止符。
    public static func encodeRegMultiSZ(_ values: [String]) -> String {
        var bytes: [UInt8] = []
        for value in values {
            for unit in value.utf16 {
                bytes.append(UInt8(unit & 0x00FF))
                bytes.append(UInt8((unit >> 8) & 0x00FF))
            }
            bytes.append(0x00)
            bytes.append(0x00)
        }
        // Final double-null terminator for REG_MULTI_SZ list
        bytes.append(0x00)
        bytes.append(0x00)

        var hexTokens: [String] = []
        hexTokens.reserveCapacity(bytes.count)
        for byte in bytes {
            let hi = hexAlphabet[Int(byte >> 4)]
            let lo = hexAlphabet[Int(byte & 0x0F)]
            hexTokens.append(String(decoding: [hi, lo], as: UTF8.self))
        }
        return "hex(7):\(hexTokens.joined(separator: ","))"
    }

    /// 根据容器配置生成完整的 `Windows Registry Editor Version 5.00` 脚本（严格 CRLF 换行）。
    public static func buildRegistryScript(
        for config: BottleConfig,
        resolvedCJKFont: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("Windows Registry Editor Version 5.00")
        lines.append("")

        // 1. Windows Version
        lines.append(#"[HKEY_CURRENT_USER\Software\Wine]"#)
        lines.append("\"Version\"=\"\(escapeRegString(config.windowsVersion.rawValue))\"")
        lines.append("")

        // 2. Mac Driver Retina Mode
        lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#)
        lines.append("\"RetinaMode\"=\"\(config.display.retinaMode ? "y" : "n")\"")
        lines.append("")

        // 3. Desktop DPI (clamped 72...384, 8-digit lowercase hex)
        let clampedDPI = min(384, max(72, config.display.dpi))
        let dpiHex = String(format: "%08x", clampedDPI)
        lines.append(#"[HKEY_CURRENT_USER\Control Panel\Desktop]"#)
        lines.append("\"LogPixels\"=dword:\(dpiHex)")
        lines.append("")

        // 4. Virtual Desktop (enable or explicit deletion per L-009)
        lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Explorer]"#)
        if config.display.virtualDesktop.enabled {
            let width = max(320, config.display.virtualDesktop.width)
            let height = max(240, config.display.virtualDesktop.height)
            lines.append("\"Desktop\"=\"Default\"")
            lines.append("")
            lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Explorer\Desktops]"#)
            lines.append("\"Default\"=\"\(width)x\(height)\"")
        } else {
            lines.append("\"Desktop\"=-")
            lines.append("")
            lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Explorer\Desktops]"#)
            lines.append("\"Default\"=-")
        }
        lines.append("")

        // 5. CJK FontLink (REG_MULTI_SZ) & FontSubstitutes (enable or explicit deletion per L-009)
        let fontName = resolveFontName(
            explicitFont: resolvedCJKFont,
            configuredFont: config.locale.fallbackFontName
        )

        lines.append(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink]"#)
        if config.locale.chineseLocalizationEnabled {
            let multiSZ = encodeRegMultiSZ([fontName])
            for baseFont in fontLinkBaseFonts {
                lines.append("\"\(escapeRegString(baseFont))\"=\(multiSZ)")
            }
        } else {
            for baseFont in fontLinkBaseFonts {
                lines.append("\"\(escapeRegString(baseFont))\"=-")
            }
        }
        lines.append("")

        lines.append(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]"#)
        if config.locale.chineseLocalizationEnabled {
            let escapedFont = escapeRegString(fontName)
            for key in chineseFontSubstituteKeys {
                lines.append("\"\(escapeRegString(key))\"=\"\(escapedFont)\"")
            }
        } else {
            for key in chineseFontSubstituteKeys {
                lines.append("\"\(escapeRegString(key))\"=-")
            }
        }
        lines.append("")

        return lines.joined(separator: "\r\n")
    }

    /// 将 `.reg` 脚本规范化为 CRLF 并编码为带 `0xFF, 0xFE` BOM 的 UTF-16LE 二进制数据（L-009）。
    public static func encodeUTF16LEWithBOM(_ script: String) -> Data {
        let normalized = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")

        var bytes: [UInt8] = [0xFF, 0xFE]
        bytes.reserveCapacity(2 + normalized.utf16.count * 2)
        for unit in normalized.utf16 {
            bytes.append(UInt8(unit & 0x00FF))
            bytes.append(UInt8((unit >> 8) & 0x00FF))
        }
        return Data(bytes)
    }

    /// 原子写出 UTF-16LE BOM `.reg` 文件并通过统一的 `LaunchPlan`（`regedit /S`）导入容器注册表，严格校验退出码并自动清理临时文件。
    public static func apply(
        bottle: Bottle,
        engine: WineEngine,
        launchPlan: LaunchPlan,
        regFileURL: URL,
        commandRunner: any CommandRunning
    ) async throws {
        let destinationURL = regFileURL.standardizedFileURL
        let script = buildRegistryScript(for: bottle.config)
        let encoded = encodeUTF16LEWithBOM(script)

        try writeBytesAtomically(encoded, to: destinationURL)
        defer {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let request = CommandRequest(
            executablePath: launchPlan.executablePath,
            arguments: launchPlan.arguments,
            environment: launchPlan.environment,
            inheritEnvironment: true,
            workingDirectory: launchPlan.workingDirectory
        )

        let result: CommandResult
        do {
            result = try await commandRunner.run(request)
        } catch {
            throw VermouthError.registryPatchFailed(
                reason: "执行 regedit 失败（引擎 \(engine.name)）: \(error.localizedDescription)"
            )
        }

        guard result.exitCode == 0 else {
            let stderrText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderrText.isEmpty ? stdoutText : stderrText
            if detail.isEmpty {
                throw VermouthError.registryPatchFailed(
                    reason: "regedit 返回非零退出码 \(result.exitCode)"
                )
            }
            throw VermouthError.registryPatchFailed(
                reason: "regedit 返回非零退出码 \(result.exitCode): \(detail)"
            )
        }
    }

    // MARK: - Private Helpers

    private static func resolveFontName(explicitFont: String?, configuredFont: String) -> String {
        if let explicit = explicitFont?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let configured = configuredFont.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return detectAvailableCJKFont()
    }

    private static func escapeRegString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func writeBytesAtomically(_ data: Data, to destinationURL: URL) throws {
        let parentDirectory = destinationURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw VermouthError.ioError(
                operation: "createDirectory",
                path: parentDirectory.path,
                underlyingDescription: error.localizedDescription
            )
        }

        let tempURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)",
            isDirectory: false
        )

        do {
            try data.write(to: tempURL, options: [])
            let renameErrno: Int32 = tempURL.withUnsafeFileSystemRepresentation { src in
                destinationURL.withUnsafeFileSystemRepresentation { dst in
                    guard let src, let dst else { return EINVAL }
                    if rename(src, dst) == 0 {
                        return 0
                    }
                    return errno
                }
            }
            if renameErrno != 0 {
                let message: String
                if let cString = strerror(renameErrno) {
                    message = String(cString: cString)
                } else {
                    message = "Unknown POSIX error"
                }
                throw VermouthError.ioError(
                    operation: "rename",
                    path: destinationURL.path,
                    underlyingDescription: "\(message) (errno \(renameErrno))"
                )
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            if let vermouthError = error as? VermouthError {
                throw vermouthError
            }
            throw VermouthError.ioError(
                operation: "writeRegFile",
                path: destinationURL.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }
}
