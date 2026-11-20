import Foundation

/// POSIX shell 安全引号转义与 Wine Unix/Windows 路径双向转换工具。
public enum ShellQuoting {
    /// 对任意字符串进行 POSIX shell 安全转义。
    /// - 空字符串输出 `''`
    /// - 仅含 `[A-Za-z0-9_./:@%+=,-]` 的 ASCII token 原样返回
    /// - 其余字符串使用单引号包裹，并将内部 `'` 转为 `'\''`
    public static func posixEscape(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        if value.unicodeScalars.allSatisfy(isSafeBareTokenScalar) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// 将环境变量（按 key 字典序确定性输出）、可执行文件与参数格式化为可直接复制执行的 POSIX 命令字符串。
    public static func formatCommand(
        environment: [String: String] = [:],
        executable: String,
        arguments: [String] = []
    ) -> String {
        var components: [String] = []
        components.reserveCapacity(environment.count + 1 + arguments.count)

        for key in environment.keys.sorted() {
            if let value = environment[key] {
                components.append("\(key)=\(posixEscape(value))")
            }
        }

        components.append(posixEscape(executable))

        for argument in arguments {
            components.append(posixEscape(argument))
        }

        return components.joined(separator: " ")
    }

    /// 将宿主机 Unix 路径转换为 Wine Windows 路径。
    /// 若路径位于 `<prefixPath>/drive_c` 内则映射为 `C:\...`，否则映射为 `Z:\...`。
    public static func toWindowsPath(unixPath: String, prefixPath: String) -> String {
        let normalizedUnix = standardizeUnixPath(unixPath)
        let normalizedPrefix = standardizeUnixPath(prefixPath)
        let driveCRoot = normalizedPrefix == "/" ? "/drive_c" : "\(normalizedPrefix)/drive_c"

        if normalizedUnix == driveCRoot {
            return "C:\\"
        }

        let driveCPrefix = "\(driveCRoot)/"
        if normalizedUnix.hasPrefix(driveCPrefix) {
            let relative = normalizedUnix.dropFirst(driveCPrefix.count)
            return "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
        }

        if normalizedUnix == "/" || normalizedUnix.isEmpty {
            return "Z:\\"
        }

        let stripped = normalizedUnix.hasPrefix("/") ? String(normalizedUnix.dropFirst()) : normalizedUnix
        return "Z:\\" + stripped.replacingOccurrences(of: "/", with: "\\")
    }

    /// 将 Wine Windows 路径（`C:\...` 或 `Z:\...`，不区分盘符大小写，兼容 `\` 与 `/`）转换为宿主机 Unix 路径。
    /// 非 `C:` / `Z:` 盘符或非法路径返回 `nil`。
    public static func toUnixPath(windowsPath: String, prefixPath: String) -> String? {
        guard windowsPath.count >= 2 else { return nil }

        let firstIndex = windowsPath.startIndex
        let secondIndex = windowsPath.index(after: firstIndex)
        guard windowsPath[secondIndex] == ":" else { return nil }

        let drive = String(windowsPath[firstIndex]).uppercased()
        guard drive == "C" || drive == "Z" else { return nil }

        let afterColon = windowsPath[windowsPath.index(after: secondIndex)...]
        if let firstAfterColon = afterColon.first, firstAfterColon != "\\" && firstAfterColon != "/" {
            return nil
        }

        var resolvedComponents: [String] = []
        for rawPart in afterColon.split(whereSeparator: { $0 == "\\" || $0 == "/" }) {
            let part = String(rawPart)
            if part.isEmpty || part == "." {
                continue
            } else if part == ".." {
                if !resolvedComponents.isEmpty {
                    resolvedComponents.removeLast()
                }
            } else {
                resolvedComponents.append(part)
            }
        }

        switch drive {
        case "C":
            let normalizedPrefix = standardizeUnixPath(prefixPath)
            let driveCRoot = normalizedPrefix == "/" ? "/drive_c" : "\(normalizedPrefix)/drive_c"
            if resolvedComponents.isEmpty {
                return driveCRoot
            }
            return "\(driveCRoot)/\(resolvedComponents.joined(separator: "/"))"

        case "Z":
            if resolvedComponents.isEmpty {
                return "/"
            }
            return "/\(resolvedComponents.joined(separator: "/"))"

        default:
            return nil
        }
    }

    // MARK: - Private Helpers

    private static func isSafeBareTokenScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        if (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
            return true
        }
        switch value {
        case 0x5F, // _
             0x2E, // .
             0x2F, // /
             0x3A, // :
             0x40, // @
             0x25, // %
             0x2B, // +
             0x3D, // =
             0x2C, // ,
             0x2D: // -
            return true
        default:
            return false
        }
    }

    private static func standardizeUnixPath(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let isAbsolute = raw.hasPrefix("/")
        var stack: [String] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(component))
            }
        }
        if isAbsolute {
            return "/" + stack.joined(separator: "/")
        }
        return stack.isEmpty ? "." : stack.joined(separator: "/")
    }
}
