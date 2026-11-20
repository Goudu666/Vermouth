import Foundation

/// 程序图标缓存：把 `.exe` 的图标提取一次、按「路径 + 大小 + 修改时间」落盘缓存为 `.ico`，供 UI 程序卡片墙使用。
///
/// - 线程安全（内部锁），可在任意并发上下文调用；提取失败或无图标时返回 `nil`，并记住负结果避免反复解析。
/// - 缓存位于 `VermouthPaths.iconCacheDirectory`，可随时整体删除。
public final class ProgramIconCache: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var memory: [String: Data] = [:]
    private var misses: Set<String> = []

    public init(paths: VermouthPaths) {
        self.directory = paths.iconCacheDirectory
    }

    /// 把容器内的程序路径解析为宿主机绝对路径（规则与启动时一致：`/` 开头为绝对路径，`~/` 展开，其余相对 prefix）。
    public static func resolveHostPath(_ rawPath: String, prefixPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser
        if trimmed == "~" {
            return home.standardizedFileURL.path
        }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2))).standardizedFileURL.path
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
    }

    /// 返回程序的 `.ico` 字节；无图标、文件不存在或解析失败时返回 `nil`。
    public func icoData(forExecutableAt hostPath: String) -> Data? {
        guard let key = Self.cacheKey(for: hostPath) else {
            return nil
        }
        let cached: (Data?, Bool) = lock.withLock { (memory[key], misses.contains(key)) }
        if let data = cached.0 {
            return data
        }
        if cached.1 {
            return nil
        }

        let fileURL = directory.appendingPathComponent("\(key).ico")
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            lock.withLock { memory[key] = data }
            return data
        }

        guard let iconSet = try? PEIconExtractor.extractIcon(fileAtPath: hostPath) else {
            lock.withLock { _ = misses.insert(key) }
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? iconSet.icoData.write(to: fileURL, options: .atomic)
        lock.withLock { memory[key] = iconSet.icoData }
        return iconSet.icoData
    }

    /// 清空内存与磁盘缓存。
    public func purge() throws {
        lock.withLock {
            memory.removeAll()
            misses.removeAll()
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// 键 = SHA-256(规范路径 | 字节数 | 修改时间毫秒)：程序更新后自动失效。
    static func cacheKey(for hostPath: String) -> String? {
        let path = URL(fileURLWithPath: hostPath).standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return PureSHA256.hash(string: "\(path)|\(size)|\(Int64(modified * 1000))")
    }
}
