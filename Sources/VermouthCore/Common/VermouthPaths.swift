import Foundation

/// 统一管理 Vermouth 的应用数据目录布局。
/// 默认使用 `~/Library/Application Support/Vermouth`，支持通过 `VERMOUTH_HOME` 环境变量或测试注入覆写。
public struct VermouthPaths: Sendable, Equatable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    public init(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let rawHome = environment["VERMOUTH_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHome.isEmpty
        {
            let expanded = Self.expandTilde(rawHome, homeDirectory: homeDirectory)
            self.baseDirectory = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        } else {
            self.baseDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Vermouth", isDirectory: true)
                .standardizedFileURL
        }
    }

    public init() {
        self.init(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    // MARK: - Top-Level Layout

    public var enginesConfigURL: URL {
        baseDirectory.appendingPathComponent("engines.json", isDirectory: false)
    }

    public var graphicsDirectory: URL {
        baseDirectory.appendingPathComponent("graphics", isDirectory: true)
    }

    public var graphicsIndexURL: URL {
        graphicsDirectory.appendingPathComponent("index.json", isDirectory: false)
    }

    public func graphicsPackageDirectory(backend: GraphicsBackend, version: String) -> URL {
        let sanitizedVersion = Self.sanitizePathComponent(version)
        return graphicsDirectory
            .appendingPathComponent(backend.rawValue, isDirectory: true)
            .appendingPathComponent(sanitizedVersion, isDirectory: true)
    }

    public var recipesDirectory: URL {
        baseDirectory.appendingPathComponent("recipes", isDirectory: true)
    }

    public var bottlesDirectory: URL {
        baseDirectory.appendingPathComponent("bottles", isDirectory: true)
    }

    // MARK: - Per-Bottle Layout

    public func bottleDirectory(id: UUID) -> URL {
        bottlesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func bottleConfigURL(id: UUID) -> URL {
        bottleDirectory(id: id).appendingPathComponent("bottle.json", isDirectory: false)
    }

    public func bottlePrefixURL(id: UUID) -> URL {
        bottleDirectory(id: id).appendingPathComponent("prefix", isDirectory: true)
    }

    public func bottleGraphicsStateURL(id: UUID) -> URL {
        bottleDirectory(id: id).appendingPathComponent("graphics-state.json", isDirectory: false)
    }

    public func bottleBackupsDirectory(id: UUID) -> URL {
        bottleDirectory(id: id).appendingPathComponent("backups", isDirectory: true)
    }

    public func bottleSnapshotsDirectory(id: UUID) -> URL {
        bottleDirectory(id: id).appendingPathComponent("snapshots", isDirectory: true)
    }

    public func bottleSnapshotsIndexURL(id: UUID) -> URL {
        bottleSnapshotsDirectory(id: id).appendingPathComponent("index.json", isDirectory: false)
    }

    public func bottleLogsDirectory(id: UUID) -> URL {
        bottleDirectory(id: id).appendingPathComponent("logs", isDirectory: true)
    }

    // MARK: - Directory Provisioning

    public func ensureBaseDirectories() throws {
        let fileManager = FileManager.default
        let directories = [
            baseDirectory,
            graphicsDirectory,
            recipesDirectory,
            bottlesDirectory,
        ]
        for directory in directories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw VermouthError.ioError(
                    operation: "createDirectory",
                    path: directory.path,
                    underlyingDescription: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Private Helpers

    private static func expandTilde(_ path: String, homeDirectory: URL) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return homeDirectory.appendingPathComponent(suffix).path
        }
        return path
    }

    private static func sanitizePathComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        if replaced.isEmpty || replaced == "." || replaced == ".." {
            return "unknown"
        }
        return replaced
    }
}
