import Foundation

/// 容器内可执行程序与快捷方式扫描器：
/// - Pass 1：解析开始菜单与桌面 `.lnk` 快捷方式（最高保真度，保留参数与工作目录）
/// - Pass 2：有限深度扫描 `Program Files` 与 `Program Files (x86)` 中的 `.exe`
/// - 自动过滤卸载器、崩溃上报器、运行库安装包与 Wine 内置程序，按规范路径去重并确定性排序
public final class ExecutableScanner: ExecutableScanning, Sendable {
    private static let maxShortcutScanDepth = 6
    private static let maxProgramFilesScanDepth = 4

    private static let skippedProgramFilesDirectories: Set<String> = [
        "common files",
        "internet explorer",
        "windows media player",
        "windows nt",
        "windows defender",
        "windows mail",
        "windows photo viewer",
        "windows powershell",
        "windowsapps",
        "modifiablewindowsapps",
        "reference assemblies",
        "msbuild",
        "dotnet",
        "uninstall information",
    ]

    public init() {}

    public func scan(prefixPath: String) throws -> [DiscoveredExecutable] {
        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true).standardizedFileURL
        guard isDirectory(atPath: prefixURL.path) else {
            throw VermouthError.invalidPrefixPath(
                path: prefixPath,
                reason: "WINEPREFIX 目录不存在或不是有效目录"
            )
        }

        let driveCURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        guard isDirectory(atPath: driveCURL.path) else {
            return []
        }

        var discoveredByCanonicalPath: [String: DiscoveredExecutable] = [:]

        // Pass 1: Shortcuts (Start Menu & Desktop) — highest fidelity
        let shortcutRoots = collectShortcutDirectories(driveCURL: driveCURL)
        for (directoryURL, source) in shortcutRoots {
            let lnkFiles = collectFiles(
                in: directoryURL,
                matchingExtension: "lnk",
                maxDepth: Self.maxShortcutScanDepth,
                skipDirectory: { _ in false }
            )
            for lnkURL in lnkFiles {
                if let executable = parseShortcutExecutable(
                    lnkURL: lnkURL,
                    source: source,
                    prefixURL: prefixURL,
                    driveCURL: driveCURL
                ) {
                    insertIfHigherPriority(executable, into: &discoveredByCanonicalPath)
                }
            }
        }

        // Pass 2: Program Files & Program Files (x86) bounded recursive scan
        let programFilesRoots = [
            driveCURL.appendingPathComponent("Program Files", isDirectory: true),
            driveCURL.appendingPathComponent("Program Files (x86)", isDirectory: true),
        ]

        for rootURL in programFilesRoots where isDirectory(atPath: rootURL.path) {
            let exeFiles = collectFiles(
                in: rootURL,
                matchingExtension: "exe",
                maxDepth: Self.maxProgramFilesScanDepth,
                skipDirectory: { dirName in
                    let lower = dirName.lowercased()
                    return Self.skippedProgramFilesDirectories.contains(lower)
                        || lower.hasPrefix("windows ")
                        || lower.hasPrefix("uninstall")
                }
            )

            for exeURL in exeFiles {
                let fileName = exeURL.lastPathComponent
                guard !Self.isNoiseExecutable(fileName: fileName) else {
                    continue
                }
                guard !isInsideWindowsSystemDirectory(exeURL.path, driveCURL: driveCURL) else {
                    continue
                }

                let canonical = canonicalKey(for: exeURL.path)
                if discoveredByCanonicalPath[canonical] != nil {
                    continue
                }

                let architecture = (try? PEInspector.inspect(fileAtPath: exeURL.path))?.architecture ?? .unknown
                let displayName = exeURL.deletingPathExtension().lastPathComponent
                let workingDir = exeURL.deletingLastPathComponent().standardizedFileURL.path

                let entry = DiscoveredExecutable(
                    name: displayName,
                    executablePath: exeURL.standardizedFileURL.path,
                    arguments: [],
                    workingDirectory: workingDir,
                    source: .programFilesScan,
                    architecture: architecture
                )
                insertIfHigherPriority(entry, into: &discoveredByCanonicalPath)
            }
        }

        return discoveredByCanonicalPath.values.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.executablePath.lowercased() < rhs.executablePath.lowercased()
        }
    }

    // MARK: - Shortcut Discovery & Parsing

    private func collectShortcutDirectories(
        driveCURL: URL
    ) -> [(URL, DiscoveredExecutable.DiscoverySource)] {
        var directories: [(URL, DiscoveredExecutable.DiscoverySource)] = []
        var seenCanonicalDirs = Set<String>()

        func appendIfExists(_ url: URL, source: DiscoveredExecutable.DiscoverySource) {
            guard isDirectory(atPath: url.path) else { return }
            let key = canonicalKey(for: url.path)
            if seenCanonicalDirs.insert(key).inserted {
                directories.append((url, source))
            }
        }

        // All-users Start Menu
        appendIfExists(
            driveCURL.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu", isDirectory: true),
            source: .startMenuShortcut
        )

        // Per-user Start Menu & Desktop (including Public)
        let usersDir = driveCURL.appendingPathComponent("users", isDirectory: true)
        if isDirectory(atPath: usersDir.path),
           let userEntries = try? FileManager.default.contentsOfDirectory(
               at: usersDir,
               includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
               options: [.skipsHiddenFiles]
           )
        {
            for userDir in userEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? userDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                    continue
                }
                appendIfExists(
                    userDir.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu", isDirectory: true),
                    source: .startMenuShortcut
                )
                appendIfExists(
                    userDir.appendingPathComponent("Desktop", isDirectory: true),
                    source: .desktopShortcut
                )
            }
        }

        // Explicit fallback for Public Desktop in case of unusual casing
        appendIfExists(
            driveCURL.appendingPathComponent("users/Public/Desktop", isDirectory: true),
            source: .desktopShortcut
        )

        return directories
    }

    private func parseShortcutExecutable(
        lnkURL: URL,
        source: DiscoveredExecutable.DiscoverySource,
        prefixURL: URL,
        driveCURL: URL
    ) -> DiscoveredExecutable? {
        let shortcutStem = lnkURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerStem = shortcutStem.lowercased()
        if lowerStem.contains("uninstall") || lowerStem.contains("卸载") {
            return nil
        }

        guard let linkInfo = try? ShellLinkParser.parse(fileAtPath: lnkURL.path),
              let rawTarget = linkInfo.targetPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTarget.isEmpty
        else {
            return nil
        }

        guard let resolvedTargetPath = resolveShortcutTargetPath(
            rawTarget,
            relativeTo: lnkURL.deletingLastPathComponent(),
            prefixPath: prefixURL.path
        ) else {
            return nil
        }

        let targetURL = URL(fileURLWithPath: resolvedTargetPath).standardizedFileURL
        guard isRegularFile(atPath: targetURL.path) else {
            return nil
        }

        let targetFileName = targetURL.lastPathComponent
        guard targetFileName.lowercased().hasSuffix(".exe") else {
            return nil
        }
        guard !Self.isNoiseExecutable(fileName: targetFileName) else {
            return nil
        }
        guard !isInsideWindowsSystemDirectory(targetURL.path, driveCURL: driveCURL) else {
            return nil
        }

        let workingDirectory: String
        if let rawWorkingDir = linkInfo.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawWorkingDir.isEmpty,
           let resolvedWorkingDir = resolveShortcutTargetPath(
               rawWorkingDir,
               relativeTo: lnkURL.deletingLastPathComponent(),
               prefixPath: prefixURL.path
           ),
           isDirectory(atPath: resolvedWorkingDir)
        {
            workingDirectory = URL(fileURLWithPath: resolvedWorkingDir).standardizedFileURL.path
        } else {
            workingDirectory = targetURL.deletingLastPathComponent().standardizedFileURL.path
        }

        let parsedArgs = Self.parseWindowsArguments(linkInfo.arguments)
        let architecture = (try? PEInspector.inspect(fileAtPath: targetURL.path))?.architecture ?? .unknown
        let displayName = shortcutStem.isEmpty
            ? targetURL.deletingPathExtension().lastPathComponent
            : shortcutStem

        return DiscoveredExecutable(
            name: displayName,
            executablePath: targetURL.path,
            arguments: parsedArgs,
            workingDirectory: workingDirectory,
            source: source,
            architecture: architecture
        )
    }

    private func resolveShortcutTargetPath(
        _ rawPath: String,
        relativeTo baseDirectory: URL,
        prefixPath: String
    ) -> String? {
        if let unixFromDrive = ShellQuoting.toUnixPath(windowsPath: rawPath, prefixPath: prefixPath) {
            return unixFromDrive
        }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path
        }
        // Fallback for relative Windows paths from HasRelativePath
        let posixRelative = rawPath.replacingOccurrences(of: "\\", with: "/")
        return baseDirectory.appendingPathComponent(posixRelative).standardizedFileURL.path
    }

    // MARK: - Bounded Filesystem Walk

    private func collectFiles(
        in rootDirectory: URL,
        matchingExtension targetExtension: String,
        maxDepth: Int,
        skipDirectory: (String) -> Bool
    ) -> [URL] {
        var collected: [URL] = []
        let expectedExt = targetExtension.lowercased()

        func walk(_ directory: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in sortedEntries {
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                // Do not traverse symlinks during recursive walks to avoid loops or prefix escapes
                if values?.isSymbolicLink == true {
                    continue
                }
                if values?.isDirectory == true {
                    if depth < maxDepth && !skipDirectory(entry.lastPathComponent) {
                        walk(entry, depth: depth + 1)
                    }
                } else if values?.isRegularFile == true {
                    if entry.pathExtension.lowercased() == expectedExt {
                        collected.append(entry)
                    }
                }
            }
        }

        walk(rootDirectory, depth: 0)
        return collected
    }

    // MARK: - Filtering, Priority & Argument Helpers

    internal static func isNoiseExecutable(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".exe") else { return true }
        let stem = String(lower.dropLast(4))

        if stem.hasPrefix("unins") || stem.contains("uninstall") {
            return true
        }
        if stem.hasPrefix("vc_redist") || stem.hasPrefix("vcredist") {
            return true
        }
        if stem == "dxsetup" || stem == "dxwebsetup" {
            return true
        }
        if stem.hasPrefix("crashreport")
            || stem.hasPrefix("unitycrashhandler")
            || stem.hasPrefix("crashpad_handler")
            || stem.hasPrefix("cef_helper")
            || stem.hasPrefix("dotnet")
        {
            return true
        }
        return false
    }

    internal static func parseWindowsArguments(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var arguments: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false

        for char in trimmed {
            if char == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if !inQuotes && char.isWhitespace {
                if hasToken {
                    arguments.append(current)
                    current.removeAll(keepingCapacity: true)
                    hasToken = false
                }
            } else {
                current.append(char)
                hasToken = true
            }
        }

        if hasToken {
            arguments.append(current)
        }
        return arguments
    }

    private func isInsideWindowsSystemDirectory(_ unixPath: String, driveCURL: URL) -> Bool {
        let canonicalFile = URL(fileURLWithPath: unixPath).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let canonicalDriveC = driveCURL.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let windowsPrefix = canonicalDriveC.hasSuffix("/")
            ? "\(canonicalDriveC)windows/"
            : "\(canonicalDriveC)/windows/"
        return canonicalFile.hasPrefix(windowsPrefix)
    }

    private func insertIfHigherPriority(
        _ candidate: DiscoveredExecutable,
        into map: inout [String: DiscoveredExecutable]
    ) {
        let key = canonicalKey(for: candidate.executablePath)
        if let existing = map[key] {
            if priorityRank(candidate.source) < priorityRank(existing.source) {
                map[key] = candidate
            }
        } else {
            map[key] = candidate
        }
    }

    private func priorityRank(_ source: DiscoveredExecutable.DiscoverySource) -> Int {
        switch source {
        case .startMenuShortcut:
            return 0
        case .desktopShortcut:
            return 1
        case .programFilesScan:
            return 2
        }
    }

    private func canonicalKey(for path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    private func isRegularFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    private func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
