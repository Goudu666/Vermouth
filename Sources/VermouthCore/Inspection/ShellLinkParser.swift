import Foundation

/// 从 Windows `.lnk`（MS-SHLLINK）快捷方式文件中解析出的目标信息。
public struct ShellLinkInfo: Codable, Equatable, Sendable {
    public let targetPath: String?
    public let arguments: String?
    public let workingDirectory: String?
    public let description: String?

    public init(
        targetPath: String? = nil,
        arguments: String? = nil,
        workingDirectory: String? = nil,
        description: String? = nil
    ) {
        self.targetPath = targetPath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.description = description
    }
}

/// 100% Clean-Room 纯 Swift MS-SHLLINK（`.lnk`）二进制快捷方式解析器。
public enum ShellLinkParser: Sendable {
    private static let maximumFileReadBytes = 1_048_576
    private static let expectedHeaderSize: UInt32 = 0x0000_004C // 76 bytes
    private static let expectedCLSID: [UInt8] = [
        0x01, 0x14, 0x02, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x46,
    ]

    // LinkFlags bit masks (MS-SHLLINK §2.1.1)
    private static let flagHasLinkTargetIDList: UInt32 = 1 << 0
    private static let flagHasLinkInfo: UInt32 = 1 << 1
    private static let flagHasName: UInt32 = 1 << 2
    private static let flagHasRelativePath: UInt32 = 1 << 3
    private static let flagHasWorkingDir: UInt32 = 1 << 4
    private static let flagHasArguments: UInt32 = 1 << 5
    private static let flagHasIconLocation: UInt32 = 1 << 6
    private static let flagIsUnicode: UInt32 = 1 << 7

    // LinkInfoFlags bit masks (MS-SHLLINK §2.3)
    private static let linkInfoFlagVolumeIDAndLocalBasePath: UInt32 = 1 << 0

    /// 解析磁盘上的 `.lnk` 文件。
    public static func parse(fileAtPath path: String) throws -> ShellLinkInfo {
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw VermouthError.ioError(
                operation: "openFile",
                path: path,
                underlyingDescription: error.localizedDescription
            )
        }
        defer {
            try? handle.close()
        }

        let data: Data
        do {
            data = try handle.read(upToCount: maximumFileReadBytes) ?? Data()
        } catch {
            throw VermouthError.ioError(
                operation: "readFile",
                path: path,
                underlyingDescription: error.localizedDescription
            )
        }

        return try parse(data: data, path: path)
    }

    /// 解析内存中的 `.lnk` 二进制数据。
    public static func parse(data: Data, path: String = "<memory>") throws -> ShellLinkInfo {
        try data.withUnsafeBytes { raw in
            let totalCount = raw.count
            guard totalCount >= Int(expectedHeaderSize) else {
                throw VermouthError.invalidShellLink(
                    path: path,
                    reason: "File too small (\(totalCount) bytes) for 76-byte ShellLinkHeader"
                )
            }

            let headerSize = readUInt32LE(raw, at: 0)
            guard headerSize == expectedHeaderSize else {
                throw VermouthError.invalidShellLink(
                    path: path,
                    reason: String(format: "Unexpected HeaderSize 0x%08X (expected 0x0000004C)", headerSize)
                )
            }

            for index in 0..<expectedCLSID.count {
                if raw[4 + index] != expectedCLSID[index] {
                    throw VermouthError.invalidShellLink(
                        path: path,
                        reason: "Invalid Shell Link CLSID"
                    )
                }
            }

            let linkFlags = readUInt32LE(raw, at: 20)
            let isUnicode = (linkFlags & flagIsUnicode) != 0
            var cursor = Int(expectedHeaderSize)

            // 1. Optional LinkTargetIDList
            if (linkFlags & flagHasLinkTargetIDList) != 0 {
                guard canRead(offset: cursor, length: 2, totalCount: totalCount) else {
                    throw VermouthError.invalidShellLink(
                        path: path,
                        reason: "Truncated LinkTargetIDList size field"
                    )
                }
                let idListSize = Int(readUInt16LE(raw, at: cursor))
                cursor += 2
                guard canRead(offset: cursor, length: idListSize, totalCount: totalCount) else {
                    throw VermouthError.invalidShellLink(
                        path: path,
                        reason: "Truncated LinkTargetIDList payload (\(idListSize) bytes)"
                    )
                }
                cursor += idListSize
            }

            // 2. Optional LinkInfo
            var linkInfoTargetPath: String?
            if (linkFlags & flagHasLinkInfo) != 0 {
                let parsedLinkInfo = try parseLinkInfo(raw: raw, startOffset: cursor, path: path)
                linkInfoTargetPath = parsedLinkInfo.targetPath
                cursor = parsedLinkInfo.nextOffset
            }

            // 3. Optional StringData (strict MS-SHLLINK §2.4 order)
            var description: String?
            if (linkFlags & flagHasName) != 0 {
                description = try readStringData(raw: raw, cursor: &cursor, isUnicode: isUnicode, path: path)
            }

            var relativePath: String?
            if (linkFlags & flagHasRelativePath) != 0 {
                relativePath = try readStringData(raw: raw, cursor: &cursor, isUnicode: isUnicode, path: path)
            }

            var workingDirectory: String?
            if (linkFlags & flagHasWorkingDir) != 0 {
                workingDirectory = try readStringData(raw: raw, cursor: &cursor, isUnicode: isUnicode, path: path)
            }

            var arguments: String?
            if (linkFlags & flagHasArguments) != 0 {
                arguments = try readStringData(raw: raw, cursor: &cursor, isUnicode: isUnicode, path: path)
            }

            if (linkFlags & flagHasIconLocation) != 0 {
                _ = try readStringData(raw: raw, cursor: &cursor, isUnicode: isUnicode, path: path)
            }

            let resolvedTarget = nonEmpty(linkInfoTargetPath) ?? nonEmpty(relativePath)

            return ShellLinkInfo(
                targetPath: resolvedTarget,
                arguments: nonEmpty(arguments),
                workingDirectory: nonEmpty(workingDirectory),
                description: nonEmpty(description)
            )
        }
    }

    // MARK: - LinkInfo Parsing

    private static func parseLinkInfo(
        raw: UnsafeRawBufferPointer,
        startOffset: Int,
        path: String
    ) throws -> (targetPath: String?, nextOffset: Int) {
        let totalCount = raw.count
        guard canRead(offset: startOffset, length: 4, totalCount: totalCount) else {
            throw VermouthError.invalidShellLink(
                path: path,
                reason: "Truncated LinkInfoSize field"
            )
        }

        let linkInfoSizeU32 = readUInt32LE(raw, at: startOffset)
        guard linkInfoSizeU32 >= 4,
              let linkInfoSize = Int(exactly: linkInfoSizeU32),
              canRead(offset: startOffset, length: linkInfoSize, totalCount: totalCount)
        else {
            throw VermouthError.invalidShellLink(
                path: path,
                reason: "Invalid or truncated LinkInfo structure (size: \(linkInfoSizeU32))"
            )
        }

        let linkInfoEnd = startOffset + linkInfoSize
        guard linkInfoSize >= 28 else {
            return (nil, linkInfoEnd)
        }

        let linkInfoHeaderSize = readUInt32LE(raw, at: startOffset + 4)
        let linkInfoFlags = readUInt32LE(raw, at: startOffset + 8)
        let localBasePathOffset = readUInt32LE(raw, at: startOffset + 16)
        let commonPathSuffixOffset = readUInt32LE(raw, at: startOffset + 24)

        var localBasePathOffsetUnicode: UInt32 = 0
        var commonPathSuffixOffsetUnicode: UInt32 = 0
        if linkInfoHeaderSize >= 0x24, linkInfoSize >= 36 {
            localBasePathOffsetUnicode = readUInt32LE(raw, at: startOffset + 28)
            commonPathSuffixOffsetUnicode = readUInt32LE(raw, at: startOffset + 32)
        }

        let hasLocalBasePath = (linkInfoFlags & linkInfoFlagVolumeIDAndLocalBasePath) != 0

        var localBasePath: String?
        if hasLocalBasePath {
            if localBasePathOffsetUnicode != 0,
               let offset = Int(exactly: localBasePathOffsetUnicode),
               offset < linkInfoSize
            {
                localBasePath = readNullTerminatedUTF16LE(
                    raw: raw,
                    start: startOffset + offset,
                    end: linkInfoEnd
                )
            }
            if nonEmpty(localBasePath) == nil,
               localBasePathOffset != 0,
               let offset = Int(exactly: localBasePathOffset),
               offset < linkInfoSize
            {
                localBasePath = readNullTerminatedANSI(
                    raw: raw,
                    start: startOffset + offset,
                    end: linkInfoEnd
                )
            }
        }

        var commonPathSuffix: String?
        if commonPathSuffixOffsetUnicode != 0,
           let offset = Int(exactly: commonPathSuffixOffsetUnicode),
           offset < linkInfoSize
        {
            commonPathSuffix = readNullTerminatedUTF16LE(
                raw: raw,
                start: startOffset + offset,
                end: linkInfoEnd
            )
        }
        if nonEmpty(commonPathSuffix) == nil,
           commonPathSuffixOffset != 0,
           let offset = Int(exactly: commonPathSuffixOffset),
           offset < linkInfoSize
        {
            commonPathSuffix = readNullTerminatedANSI(
                raw: raw,
                start: startOffset + offset,
                end: linkInfoEnd
            )
        }

        let combined = combineWindowsPath(base: nonEmpty(localBasePath), suffix: nonEmpty(commonPathSuffix))
        return (combined, linkInfoEnd)
    }

    private static func combineWindowsPath(base: String?, suffix: String?) -> String? {
        switch (base, suffix) {
        case let (.some(lhs), .some(rhs)):
            let lhsHasSep = lhs.hasSuffix("\\") || lhs.hasSuffix("/")
            let rhsHasSep = rhs.hasPrefix("\\") || rhs.hasPrefix("/")
            if lhsHasSep && rhsHasSep {
                return lhs + String(rhs.dropFirst())
            } else if lhsHasSep || rhsHasSep {
                return lhs + rhs
            } else {
                return "\(lhs)\\\(rhs)"
            }
        case let (.some(lhs), .none):
            return lhs
        case let (.none, .some(rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }

    // MARK: - StringData & Null-Terminated Decoders

    private static func readStringData(
        raw: UnsafeRawBufferPointer,
        cursor: inout Int,
        isUnicode: Bool,
        path: String
    ) throws -> String? {
        let totalCount = raw.count
        guard canRead(offset: cursor, length: 2, totalCount: totalCount) else {
            throw VermouthError.invalidShellLink(
                path: path,
                reason: "Truncated StringData character count"
            )
        }
        let charCount = Int(readUInt16LE(raw, at: cursor))
        cursor += 2

        let byteCount = isUnicode ? charCount * 2 : charCount
        guard canRead(offset: cursor, length: byteCount, totalCount: totalCount) else {
            throw VermouthError.invalidShellLink(
                path: path,
                reason: "Truncated StringData payload (\(byteCount) bytes)"
            )
        }

        if byteCount == 0 {
            return nil
        }

        guard let baseAddress = raw.baseAddress else {
            return nil
        }
        let slice = Data(bytes: baseAddress.advanced(by: cursor), count: byteCount)
        cursor += byteCount

        let decoded: String?
        if isUnicode {
            decoded = String(data: slice, encoding: .utf16LittleEndian)
        } else {
            decoded = decodeANSIBytes(slice)
        }

        return nonEmpty(decoded?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
    }

    private static func readNullTerminatedUTF16LE(
        raw: UnsafeRawBufferPointer,
        start: Int,
        end: Int
    ) -> String? {
        guard start >= 0, start < end, end <= raw.count else { return nil }
        var pos = start
        while pos + 1 < end {
            if raw[pos] == 0x00 && raw[pos + 1] == 0x00 {
                break
            }
            pos += 2
        }
        let byteCount = pos - start
        guard byteCount > 0, let baseAddress = raw.baseAddress else { return nil }
        let data = Data(bytes: baseAddress.advanced(by: start), count: byteCount)
        return String(data: data, encoding: .utf16LittleEndian)
    }

    private static func readNullTerminatedANSI(
        raw: UnsafeRawBufferPointer,
        start: Int,
        end: Int
    ) -> String? {
        guard start >= 0, start < end, end <= raw.count else { return nil }
        var pos = start
        while pos < end && raw[pos] != 0x00 {
            pos += 1
        }
        let byteCount = pos - start
        guard byteCount > 0, let baseAddress = raw.baseAddress else { return nil }
        let data = Data(bytes: baseAddress.advanced(by: start), count: byteCount)
        return decodeANSIBytes(data)
    }

    private static func decodeANSIBytes(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let cp1252 = String(data: data, encoding: .windowsCP1252) {
            return cp1252
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Primitive Readers

    @inline(__always)
    private static func canRead(offset: Int, length: Int, totalCount: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= totalCount && length <= totalCount - offset
    }

    @inline(__always)
    private static func readUInt16LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    @inline(__always)
    private static func readUInt32LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(raw[offset])
            | (UInt32(raw[offset + 1]) << 8)
            | (UInt32(raw[offset + 2]) << 16)
            | (UInt32(raw[offset + 3]) << 24)
    }
}
