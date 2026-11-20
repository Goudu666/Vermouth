import Foundation

/// Mach-O 文件中与动态库加载有关的 load command。
public struct MachOLoadInfo: Equatable, Sendable {
    /// 必须能加载的依赖（`LC_LOAD_DYLIB` / `LC_REEXPORT_DYLIB` / `LC_LOAD_UPWARD_DYLIB`）
    public var requiredDylibs: [String]
    /// 弱依赖（`LC_LOAD_WEAK_DYLIB`），缺失时 dyld 不报错
    public var weakDylibs: [String]
    /// `LC_RPATH` 原文（可能含 `@loader_path` / `@executable_path`）
    public var rpaths: [String]
}

/// 一条无法在引擎目录内解析的 `@rpath` / `@loader_path` / `@executable_path` 依赖。
public struct UnresolvedDylibDependency: Equatable, Sendable {
    /// 引用方二进制相对引擎根目录的路径（如 `bin/wineserver`）
    public var binary: String
    /// 依赖原文（如 `@rpath/libinotify.0.dylib`）
    public var dependency: String
    /// 已尝试的绝对路径
    public var searchedPaths: [String]
}

/// Clean-Room 的 Mach-O load command 读取器（L-008），用于登记自定义引擎前检查 dylib 依赖。
///
/// 不依赖 `otool`：用户机器上通常没有 Xcode / Command Line Tools。
public enum MachODependencyInspector: Sendable {
    private static let mhMagic64: UInt32 = 0xFEED_FACF
    private static let mhMagic32: UInt32 = 0xFEED_FACE
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007

    private static let lcLoadDylib: UInt32 = 0xC
    private static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    private static let lcRpath: UInt32 = 0x8000_001C
    private static let lcReexportDylib: UInt32 = 0x8000_001F
    private static let lcLoadUpwardDylib: UInt32 = 0x8000_0023

    /// 读取 Mach-O（含 fat，优先 x86_64 切片）的依赖与 rpath；不是 Mach-O（如脚本）时返回 `nil`。
    public static func loadInfo(atPath path: String) throws -> MachOLoadInfo? {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        return parse(data)
    }

    public static func parse(_ data: Data) -> MachOLoadInfo? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let bigEndianMagic = readUInt32(bytes, 0, bigEndian: true)
        if bigEndianMagic == fatMagic || bigEndianMagic == fatMagic64 {
            return parseFat(bytes, is64: bigEndianMagic == fatMagic64)
        }
        return parseThin(bytes, at: 0)
    }

    /// 检查引擎关键二进制的 `@` 相对依赖是否都能在磁盘上找到。
    ///
    /// - `executables`：`bin/wine`、`bin/wineserver` 等主程序，`@executable_path` 指向各自目录；
    /// - `loadedLibraries`：由 `hostExecutable` 加载的库（如 `ntdll.so`），dyld 搜索 `@rpath`
    ///   时会同时使用库自身与主程序的 `LC_RPATH`。
    /// 绝对路径依赖（`/usr/lib`、`/System`）位于 dyld 共享缓存中，不在磁盘上，不做检查。
    public static func unresolvedDependencies(
        engineRoot: String,
        executables: [String],
        loadedLibraries: [String],
        hostExecutable: String
    ) throws -> [UnresolvedDylibDependency] {
        var unresolved: [UnresolvedDylibDependency] = []

        for executable in executables {
            guard let info = try loadInfo(atPath: executable) else { continue }
            unresolved += check(
                binary: executable,
                info: info,
                inheritedRpaths: [],
                executableDir: directory(of: executable),
                engineRoot: engineRoot
            )
        }

        let hostRpaths: [(rpath: String, loaderDir: String)]
        if let hostInfo = try loadInfo(atPath: hostExecutable) {
            hostRpaths = hostInfo.rpaths.map { ($0, directory(of: hostExecutable)) }
        } else {
            hostRpaths = []
        }
        for library in loadedLibraries {
            guard let info = try loadInfo(atPath: library) else { continue }
            unresolved += check(
                binary: library,
                info: info,
                inheritedRpaths: hostRpaths,
                executableDir: directory(of: hostExecutable),
                engineRoot: engineRoot
            )
        }
        return unresolved
    }

    // MARK: - Resolution

    private static func check(
        binary: String,
        info: MachOLoadInfo,
        inheritedRpaths: [(rpath: String, loaderDir: String)],
        executableDir: String,
        engineRoot: String
    ) -> [UnresolvedDylibDependency] {
        let loaderDir = directory(of: binary)
        let searchRoots = info.rpaths.map { (rpath: $0, loaderDir: loaderDir) } + inheritedRpaths

        var unresolved: [UnresolvedDylibDependency] = []
        for dependency in info.requiredDylibs {
            let candidates: [String]
            if dependency.hasPrefix("@rpath/") {
                let rest = String(dependency.dropFirst("@rpath/".count))
                candidates = searchRoots.map { root in
                    let expanded = expand(root.rpath, loaderDir: root.loaderDir, executableDir: executableDir)
                    return URL(fileURLWithPath: expanded).appendingPathComponent(rest).standardizedFileURL.path
                }
            } else if dependency.hasPrefix("@loader_path/") || dependency.hasPrefix("@executable_path/") {
                let expanded = expand(dependency, loaderDir: loaderDir, executableDir: executableDir)
                candidates = [URL(fileURLWithPath: expanded).standardizedFileURL.path]
            } else {
                continue
            }

            if !candidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                unresolved.append(
                    UnresolvedDylibDependency(
                        binary: relativePath(binary, to: engineRoot),
                        dependency: dependency,
                        searchedPaths: candidates
                    )
                )
            }
        }
        return unresolved
    }

    private static func expand(_ path: String, loaderDir: String, executableDir: String) -> String {
        if path.hasPrefix("@loader_path") {
            return loaderDir + path.dropFirst("@loader_path".count)
        }
        if path.hasPrefix("@executable_path") {
            return executableDir + path.dropFirst("@executable_path".count)
        }
        return path
    }

    private static func directory(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
    }

    private static func relativePath(_ path: String, to root: String) -> String {
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardizedPath.hasPrefix(standardizedRoot + "/") else { return standardizedPath }
        return String(standardizedPath.dropFirst(standardizedRoot.count + 1))
    }

    // MARK: - Parsing

    private static func parseFat(_ bytes: [UInt8], is64: Bool) -> MachOLoadInfo? {
        let archCount = Int(readUInt32(bytes, 4, bigEndian: true))
        let entrySize = is64 ? 32 : 20
        var sliceOffsets: [(cpuType: UInt32, offset: Int)] = []
        for index in 0..<archCount {
            let entry = 8 + index * entrySize
            guard entry + entrySize <= bytes.count else { return nil }
            let cpuType = readUInt32(bytes, entry, bigEndian: true)
            let offset = is64
                ? Int(readUInt64(bytes, entry + 8, bigEndian: true))
                : Int(readUInt32(bytes, entry + 8, bigEndian: true))
            sliceOffsets.append((cpuType, offset))
        }
        guard let slice = sliceOffsets.first(where: { $0.cpuType == cpuTypeX86_64 }) ?? sliceOffsets.first else {
            return nil
        }
        return parseThin(bytes, at: slice.offset)
    }

    private static func parseThin(_ bytes: [UInt8], at base: Int) -> MachOLoadInfo? {
        guard base + 28 <= bytes.count else { return nil }
        let magic = readUInt32(bytes, base, bigEndian: false)
        let headerSize: Int
        switch magic {
        case mhMagic64: headerSize = 32
        case mhMagic32: headerSize = 28
        default: return nil
        }
        let commandCount = Int(readUInt32(bytes, base + 16, bigEndian: false))

        var info = MachOLoadInfo(requiredDylibs: [], weakDylibs: [], rpaths: [])
        var cursor = base + headerSize
        for _ in 0..<commandCount {
            guard cursor + 8 <= bytes.count else { return nil }
            let command = readUInt32(bytes, cursor, bigEndian: false)
            let commandSize = Int(readUInt32(bytes, cursor + 4, bigEndian: false))
            guard commandSize >= 8, cursor + commandSize <= bytes.count else { return nil }

            switch command {
            case lcLoadDylib, lcReexportDylib, lcLoadUpwardDylib:
                info.requiredDylibs.append(readCommandString(bytes, command: cursor, size: commandSize))
            case lcLoadWeakDylib:
                info.weakDylibs.append(readCommandString(bytes, command: cursor, size: commandSize))
            case lcRpath:
                info.rpaths.append(readCommandString(bytes, command: cursor, size: commandSize))
            default:
                break
            }
            cursor += commandSize
        }
        return info
    }

    /// `dylib_command` 与 `rpath_command` 的字符串偏移都位于命令起点 +8 处。
    private static func readCommandString(_ bytes: [UInt8], command: Int, size: Int) -> String {
        let start = command + Int(readUInt32(bytes, command + 8, bigEndian: false))
        let end = command + size
        guard start < end else { return "" }
        let raw = bytes[start..<end].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool) -> UInt32 {
        let slice = bytes[offset..<offset + 4]
        return slice.enumerated().reduce(UInt32(0)) { value, element in
            let shift = bigEndian ? (3 - element.offset) * 8 : element.offset * 8
            return value | UInt32(element.element) << UInt32(shift)
        }
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool) -> UInt64 {
        let high = UInt64(readUInt32(bytes, offset, bigEndian: bigEndian))
        let low = UInt64(readUInt32(bytes, offset + 4, bigEndian: bigEndian))
        return bigEndian ? (high << 32 | low) : (low << 32 | high)
    }
}
