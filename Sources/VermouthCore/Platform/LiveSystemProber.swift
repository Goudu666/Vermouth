import Foundation

/// 宿主机真实只读探测与 macOS Quarantine 安全清理实现（遵循 L-006 与 L-016）。
public final class LiveSystemProber: SystemProbing, Sendable {
    private let commandRunner: any CommandRunning

    public init(commandRunner: any CommandRunning = LiveCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func hostArchitecture() -> HostArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }

    public func operatingSystemVersion() -> OSVersionInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let major = version.majorVersion
        let minor = version.minorVersion
        let patch = version.patchVersion
        #if os(macOS)
        let prefix = "macOS"
        #elseif os(Linux)
        let prefix = "Linux"
        #else
        let prefix = "OS"
        #endif
        return OSVersionInfo(
            major: major,
            minor: minor,
            patch: patch,
            displayString: "\(prefix) \(major).\(minor).\(patch)"
        )
    }

    public func isRosetta2Installed() async -> Bool {
        #if os(macOS)
        #if arch(arm64)
        let fileManager = FileManager.default
        let rosettaMarkers = [
            "/Library/Apple/usr/share/rosetta/rosetta",
            "/Library/Apple/usr/libexec/oah/libRosettaRuntime",
        ]
        if rosettaMarkers.contains(where: { fileManager.fileExists(atPath: $0) }) {
            return true
        }

        let request = CommandRequest(
            executablePath: "/usr/bin/arch",
            arguments: ["-x86_64", "/usr/bin/true"],
            environment: [:],
            inheritEnvironment: true
        )
        if let result = try? await commandRunner.run(request) {
            return result.exitCode == 0
        }
        return false
        #elseif arch(x86_64)
        return true
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    public func findExecutable(named: String, searchPaths: [String]) -> String? {
        let trimmed = named.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            return isExecutableRegularFile(atPath: standardized) ? standardized : nil
        }

        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(trimmed, isDirectory: false)
                .standardizedFileURL.path
            if isExecutableRegularFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public func isQuarantined(path: String) async -> Bool {
        #if os(macOS)
        let expanded = Self.expandTilde(path)
        guard !expanded.isEmpty else { return false }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path

        let request = CommandRequest(
            executablePath: "/usr/bin/xattr",
            arguments: ["-p", "com.apple.quarantine", standardized],
            environment: [:],
            inheritEnvironment: true
        )
        guard let result = try? await commandRunner.run(request) else {
            return false
        }
        return result.exitCode == 0
        #else
        return false
        #endif
    }

    public func removeQuarantine(path: String, recursive: Bool) async throws {
        let expanded = Self.expandTilde(path)
        guard !expanded.isEmpty else {
            throw VermouthError.ioError(
                operation: "removeQuarantine",
                path: path,
                underlyingDescription: "目标路径不能为空"
            )
        }

        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path

        // L-006 安全护栏：严禁对系统目录、用户主目录或 ~/Downloads 等宽范围目录执行递归解除隔离
        if recursive {
            try Self.validateSafeRecursiveQuarantineTarget(standardized, originalPath: path)
        }

        #if os(macOS)
        let flags = recursive ? "-dr" : "-d"
        let request = CommandRequest(
            executablePath: "/usr/bin/xattr",
            arguments: [flags, "com.apple.quarantine", standardized],
            environment: [:],
            inheritEnvironment: true
        )
        let result = try await commandRunner.run(request)
        if result.exitCode == 0 {
            return
        }
        if result.stderr.localizedCaseInsensitiveContains("No such xattr") {
            return
        }
        throw VermouthError.commandExecutionFailed(
            executable: "/usr/bin/xattr",
            exitCode: result.exitCode,
            stderr: result.stderr
        )
        #endif
    }

    // MARK: - Private Safety & Path Helpers

    internal static func validateSafeRecursiveQuarantineTarget(
        _ expandedPath: String,
        originalPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let standardized = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: expandedPath).resolvingSymlinksInPath().standardizedFileURL.path

        let rawHome = homeDirectory.standardizedFileURL.path
        let resolvedHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path

        var forbidden = Set<String>([
            "/",
            "/Applications",
            "/System",
            "/Library",
            "/Users",
            "/usr",
            "/opt",
            "/private",
            "/var",
            "/tmp",
            "/private/tmp",
            "/private/var",
            rawHome,
            resolvedHome,
        ])

        let sensitiveHomeSubdirs = [
            "Downloads",
            "Desktop",
            "Documents",
            "Library",
            "Applications",
        ]
        for subdir in sensitiveHomeSubdirs {
            forbidden.insert(
                URL(fileURLWithPath: rawHome, isDirectory: true)
                    .appendingPathComponent(subdir)
                    .standardizedFileURL.path
            )
            forbidden.insert(
                URL(fileURLWithPath: resolvedHome, isDirectory: true)
                    .appendingPathComponent(subdir)
                    .standardizedFileURL.path
            )
        }

        if forbidden.contains(standardized) || forbidden.contains(resolved) {
            throw VermouthError.ioError(
                operation: "removeQuarantine",
                path: originalPath,
                underlyingDescription: "安全限制（L-006）：拒绝递归解除系统目录或宽范围用户目录的隔离属性，请限定到具体文件、.app 或单个容器目录"
            )
        }
    }

    private func isExecutableRegularFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    private static func expandTilde(
        _ rawPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return homeDirectory.standardizedFileURL.path
        }
        if trimmed.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .standardizedFileURL.path
        }
        return trimmed
    }
}
