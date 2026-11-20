import Foundation

/// 100% Clean-Room 纯 Swift Windows PE/COFF 头部只读解析器。
/// 仅读取文件头部字节（常规情况下 <= 64KB），可在微秒级判定 32/64/ARM64 架构、DLL 标志与子系统。
public enum PEInspector: Sendable {
    private static let initialReadLimit = 65_536
    private static let remoteHeaderReadLimit = 4_096

    private static let dosHeaderMinimumSize = 0x40
    private static let eLfanewOffset = 0x3C
    private static let peSignatureAndCOFFSize = 24 // 4 bytes "PE\0\0" + 20 bytes IMAGE_FILE_HEADER

    private static let machineI386: UInt16 = 0x014C
    private static let machineAMD64: UInt16 = 0x8664
    private static let machineARM64: UInt16 = 0xAA64

    private static let optionalMagicPE32: UInt16 = 0x010B
    private static let optionalMagicPE32Plus: UInt16 = 0x020B

    private static let characteristicDLL: UInt16 = 0x2000
    private static let subsystemOffsetInOptionalHeader = 68
    private static let subsystemMinimumOptionalHeaderSize = 70

    /// 只读探测磁盘上的 Windows PE 文件（`.exe` / `.dll`）。
    public static func inspect(fileAtPath path: String) throws -> PEInspectionResult {
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

        let initialChunk: Data
        do {
            initialChunk = try handle.read(upToCount: initialReadLimit) ?? Data()
        } catch {
            throw VermouthError.ioError(
                operation: "readFile",
                path: path,
                underlyingDescription: error.localizedDescription
            )
        }

        let peOffset = try readAndValidateDOSHeader(data: initialChunk, path: path)

        // 常规 PE 头部位于前 64KB 内，直接零额外 I/O 解析
        if peOffset <= UInt64(initialChunk.count) {
            let offsetInt = Int(peOffset)
            if canRead(offset: offsetInt, length: peSignatureAndCOFFSize, totalCount: initialChunk.count) {
                let requiredOptionalTail = peekOptionalHeaderRequiredLength(
                    data: initialChunk,
                    peOffset: offsetInt
                )
                if let requiredOptionalTail,
                   canRead(
                       offset: offsetInt,
                       length: peSignatureAndCOFFSize + requiredOptionalTail,
                       totalCount: initialChunk.count
                   )
                {
                    return try parsePEHeader(data: initialChunk, peOffset: offsetInt, path: path)
                }
            }
        }

        // 若存在超大 DOS Stub 导致 e_lfanew 超出前 64KB，安全 seek 读取 PE 头
        do {
            try handle.seek(toOffset: peOffset)
        } catch {
            throw VermouthError.invalidPEFile(
                path: path,
                reason: "e_lfanew offset \(peOffset) exceeds file size"
            )
        }

        let peChunk: Data
        do {
            peChunk = try handle.read(upToCount: remoteHeaderReadLimit) ?? Data()
        } catch {
            throw VermouthError.ioError(
                operation: "readFile",
                path: path,
                underlyingDescription: error.localizedDescription
            )
        }

        return try parsePEHeader(data: peChunk, peOffset: 0, path: path)
    }

    /// 解析内存中的 PE 二进制数据。
    public static func inspect(data: Data, path: String = "<memory>") throws -> PEInspectionResult {
        let peOffset = try readAndValidateDOSHeader(data: data, path: path)
        guard peOffset <= UInt64(Int.max), Int(peOffset) <= data.count else {
            throw VermouthError.invalidPEFile(
                path: path,
                reason: "e_lfanew offset \(peOffset) exceeds buffer size (\(data.count) bytes)"
            )
        }
        return try parsePEHeader(data: data, peOffset: Int(peOffset), path: path)
    }

    // MARK: - Private Binary Parsing

    private static func readAndValidateDOSHeader(data: Data, path: String) throws -> UInt64 {
        try data.withUnsafeBytes { raw in
            guard raw.count >= dosHeaderMinimumSize else {
                throw VermouthError.invalidPEFile(
                    path: path,
                    reason: "File too small (\(raw.count) bytes) to contain a valid DOS header"
                )
            }
            guard raw[0] == 0x4D, raw[1] == 0x5A else {
                throw VermouthError.invalidPEFile(
                    path: path,
                    reason: "Missing MZ DOS signature"
                )
            }
            let peOffset = readUInt32LE(raw, at: eLfanewOffset)
            return UInt64(peOffset)
        }
    }

    private static func peekOptionalHeaderRequiredLength(data: Data, peOffset: Int) -> Int? {
        data.withUnsafeBytes { raw in
            guard canRead(offset: peOffset, length: peSignatureAndCOFFSize, totalCount: raw.count) else {
                return nil
            }
            let sizeOfOptionalHeader = Int(readUInt16LE(raw, at: peOffset + 20))
            return min(sizeOfOptionalHeader, subsystemMinimumOptionalHeaderSize)
        }
    }

    private static func parsePEHeader(data: Data, peOffset: Int, path: String) throws -> PEInspectionResult {
        try data.withUnsafeBytes { raw in
            guard canRead(offset: peOffset, length: peSignatureAndCOFFSize, totalCount: raw.count) else {
                throw VermouthError.invalidPEFile(
                    path: path,
                    reason: "Truncated PE signature or COFF file header"
                )
            }

            guard raw[peOffset] == 0x50,
                  raw[peOffset + 1] == 0x45,
                  raw[peOffset + 2] == 0x00,
                  raw[peOffset + 3] == 0x00
            else {
                throw VermouthError.invalidPEFile(
                    path: path,
                    reason: "Missing PE\\0\\0 signature"
                )
            }

            let machine = readUInt16LE(raw, at: peOffset + 4)
            let sizeOfOptionalHeader = Int(readUInt16LE(raw, at: peOffset + 20))
            let characteristics = readUInt16LE(raw, at: peOffset + 22)
            let isDLL = (characteristics & characteristicDLL) != 0

            let optionalHeaderOffset = peOffset + peSignatureAndCOFFSize
            var optionalMagic: UInt16 = 0
            var subsystem: UInt16 = 0

            if sizeOfOptionalHeader >= 2 {
                guard canRead(offset: optionalHeaderOffset, length: 2, totalCount: raw.count) else {
                    throw VermouthError.invalidPEFile(
                        path: path,
                        reason: "Truncated PE optional header magic"
                    )
                }
                optionalMagic = readUInt16LE(raw, at: optionalHeaderOffset)
            }

            if sizeOfOptionalHeader >= subsystemMinimumOptionalHeaderSize {
                if canRead(
                    offset: optionalHeaderOffset,
                    length: subsystemMinimumOptionalHeaderSize,
                    totalCount: raw.count
                ) {
                    subsystem = readUInt16LE(
                        raw,
                        at: optionalHeaderOffset + subsystemOffsetInOptionalHeader
                    )
                }
            }

            let architecture: PEArchitecture
            switch machine {
            case machineI386:
                architecture = .x86_32
            case machineAMD64:
                architecture = .x86_64
            case machineARM64:
                architecture = .arm64
            default:
                switch optionalMagic {
                case optionalMagicPE32:
                    architecture = .x86_32
                case optionalMagicPE32Plus:
                    architecture = .x86_64
                default:
                    architecture = .unknown
                }
            }

            return PEInspectionResult(
                path: path,
                architecture: architecture,
                isDLL: isDLL,
                subsystem: subsystem
            )
        }
    }

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
