import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// 全局统一 JSON 编解码与原子落盘工具（符合 L-011 约束）。
/// - 编码：ISO-8601 UTC 含毫秒精度（四舍五入至整数毫秒，不截断）、`.prettyPrinted`、`.sortedKeys`、`.withoutEscapingSlashes`
/// - 解码：兼容含毫秒与不含毫秒的 ISO-8601 字符串
/// - 落盘：同父目录唯一临时文件写入后 POSIX 原子 `rename` 替换
public enum VermouthJSON {
    /// 返回量化到整数毫秒的当前时间戳，确保与 `VermouthJSON` 序列化往返精确相等。
    public static func currentTimestamp() -> Date {
        let millis = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        return Date(timeIntervalSince1970: Double(millis) / 1000.0)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let scaled = date.timeIntervalSince1970 * 1000.0
            guard scaled.isFinite,
                  scaled >= Double(Int64.min / 2),
                  scaled <= Double(Int64.max / 2)
            else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Date out of representable ISO-8601 millisecond range: \(date)"
                    )
                )
            }

            let totalMs = Int64(scaled.rounded())
            var wholeSeconds = totalMs / 1000
            var remainderMs = totalMs % 1000
            if remainderMs < 0 {
                remainderMs += 1000
                wholeSeconds -= 1
            }

            let wholeDate = Date(timeIntervalSince1970: Double(wholeSeconds))
            let formatter = ISO8601DateFormatter()
            if let utc = TimeZone(secondsFromGMT: 0) {
                formatter.timeZone = utc
            }
            formatter.formatOptions = [.withInternetDateTime]

            var wholeString = formatter.string(from: wholeDate)
            if wholeString.hasSuffix("Z") {
                wholeString.removeLast()
            }

            let formatted = wholeString + String(format: ".%03dZ", Int(remainderMs))
            var container = encoder.singleValueContainer()
            try container.encode(formatted)
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            if let utc = TimeZone(secondsFromGMT: 0) {
                fractionalFormatter.timeZone = utc
            }
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractionalFormatter.date(from: raw) {
                let totalMs = Int64((parsed.timeIntervalSince1970 * 1000.0).rounded())
                return Date(timeIntervalSince1970: Double(totalMs) / 1000.0)
            }

            let standardFormatter = ISO8601DateFormatter()
            if let utc = TimeZone(secondsFromGMT: 0) {
                standardFormatter.timeZone = utc
            }
            standardFormatter.formatOptions = [.withInternetDateTime]
            if let parsed = standardFormatter.date(from: raw) {
                let wholeSeconds = Int64(parsed.timeIntervalSince1970.rounded())
                return Date(timeIntervalSince1970: Double(wholeSeconds))
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date string: \(raw)"
            )
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    public static func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        let destinationURL = url.standardizedFileURL
        let data: Data
        do {
            data = try encode(value)
        } catch {
            throw VermouthError.encodingFailed(
                type: String(describing: T.self),
                underlyingDescription: error.localizedDescription
            )
        }

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
                operation: "writeAtomically",
                path: destinationURL.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let sourceURL = url.standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw VermouthError.ioError(
                operation: "read",
                path: sourceURL.path,
                underlyingDescription: error.localizedDescription
            )
        }
        do {
            return try decode(type, from: data)
        } catch {
            throw VermouthError.decodingFailed(
                type: String(describing: type),
                path: sourceURL.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }
}
