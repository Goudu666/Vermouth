import Foundation

/// 从 PE 资源段提取出的单张图标图像的元数据。
public struct PEIconImage: Sendable, Equatable, Codable {
    /// 像素宽度（资源目录里 0 表示 256）。
    public let width: Int
    /// 像素高度（资源目录里 0 表示 256）。
    public let height: Int
    /// 色深（位/像素）。
    public let bitCount: Int
    /// 图像数据是否为 PNG 压缩（Vista 起 256×256 图标常以 PNG 存储），否则为 DIB（BMP 去掉文件头）。
    public let isPNG: Bool
    /// 图像数据字节数。
    public let byteCount: Int

    public init(width: Int, height: Int, bitCount: Int, isPNG: Bool, byteCount: Int) {
        self.width = width
        self.height = height
        self.bitCount = bitCount
        self.isPNG = isPNG
        self.byteCount = byteCount
    }
}

/// 一个完整的图标组：可直接写成 `.ico` 文件，`NSImage(data:)` 能原生解码。
public struct PEIconSet: Sendable, Equatable {
    /// 来源 `RT_GROUP_ICON` 资源的数字 ID（以名称命名的资源为 `nil`）。
    public let groupID: UInt32?
    /// 组内每张图像的元数据，与 `.ico` 中的顺序一致。
    public let images: [PEIconImage]
    /// 标准 Windows `.ico` 文件字节（ICONDIR + ICONDIRENTRY[] + 图像数据）。
    public let icoData: Data

    /// 组内面积最大、色深最高的图像（UI 选封面用）。
    public var largestImage: PEIconImage? {
        images.max { lhs, rhs in
            (lhs.width * lhs.height, lhs.bitCount) < (rhs.width * rhs.height, rhs.bitCount)
        }
    }
}

/// 100% Clean-Room 纯 Swift PE 资源段图标提取器。
///
/// 按 PE/COFF 规范解析 `.rsrc` 资源树（类型 → 名称 → 语言 三级），取第一个 `RT_GROUP_ICON`，
/// 再按组内 `nID` 收集对应的 `RT_ICON` 图像，重新拼成独立的 `.ico` 文件。
/// 只读、无副作用；所有偏移都做越界校验，畸形文件只会返回错误，绝不越界读取或死循环。
public enum PEIconExtractor: Sendable {
    /// 资源段读取上限：正常程序的 `.rsrc` 远小于此值，防止恶意文件声明超大尺寸耗尽内存。
    public static let maximumResourceSectionBytes = 64 * 1024 * 1024

    private static let headerReadLimit = 65_536
    private static let resourceTypeIcon: UInt32 = 3
    private static let resourceTypeGroupIcon: UInt32 = 14
    private static let resourceDirectoryIndex = 2
    private static let groupIconHeaderSize = 6
    private static let groupIconEntrySize = 14
    private static let icoDirectoryEntrySize = 16

    /// 从磁盘上的 `.exe` / `.dll` 提取第一个图标组。文件没有图标资源时返回 `nil`。
    public static func extractIcon(fileAtPath path: String) throws -> PEIconSet? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw VermouthError.ioError(operation: "openFile", path: path, underlyingDescription: error.localizedDescription)
        }
        defer { try? handle.close() }

        let header = try read(handle, offset: 0, length: headerReadLimit, path: path)
        guard let location = try locateResourceSection(header: header, path: path) else {
            return nil
        }
        let section = try read(handle, offset: UInt64(location.pointerToRawData), length: location.readLength, path: path)
        return try extractIcon(
            resourceSection: section,
            sectionVirtualAddress: location.virtualAddress,
            rootOffset: Int(location.resourceRVA - location.virtualAddress),
            path: path
        )
    }

    /// 解析内存中的完整 PE 文件字节。
    public static func extractIcon(data: Data, path: String = "<memory>") throws -> PEIconSet? {
        let bytes = [UInt8](data)
        guard let location = try locateResourceSection(header: bytes, path: path) else {
            return nil
        }
        let start = Int(location.pointerToRawData)
        guard start <= bytes.count else {
            throw VermouthError.invalidPEFile(path: path, reason: "Resource section raw data starts beyond end of file")
        }
        let end = min(bytes.count, start + location.readLength)
        return try extractIcon(
            resourceSection: Array(bytes[start..<end]),
            sectionVirtualAddress: location.virtualAddress,
            rootOffset: Int(location.resourceRVA - location.virtualAddress),
            path: path
        )
    }

    // MARK: - Headers & Section Table

    private struct ResourceSectionLocation {
        let virtualAddress: UInt32
        let pointerToRawData: UInt32
        let readLength: Int
        let resourceRVA: UInt32
    }

    private static func locateResourceSection(header raw: [UInt8], path: String) throws -> ResourceSectionLocation? {
        guard raw.count >= 0x40, raw[0] == 0x4D, raw[1] == 0x5A else {
            throw VermouthError.invalidPEFile(path: path, reason: "Missing MZ DOS signature")
        }
        let peOffset = Int(u32(raw, 0x3C) ?? 0)
        guard let signature = u32(raw, peOffset), signature == 0x0000_4550 else {
            throw VermouthError.invalidPEFile(path: path, reason: "Missing PE\\0\\0 signature within header window")
        }
        guard let sectionCount = u16(raw, peOffset + 6),
              let optionalSize = u16(raw, peOffset + 20)
        else {
            throw VermouthError.invalidPEFile(path: path, reason: "Truncated COFF file header")
        }
        let optionalOffset = peOffset + 24
        guard let magic = u16(raw, optionalOffset) else {
            throw VermouthError.invalidPEFile(path: path, reason: "Truncated optional header")
        }
        let directoryCountOffset: Int
        switch magic {
        case 0x010B: directoryCountOffset = 92 // PE32
        case 0x020B: directoryCountOffset = 108 // PE32+
        default:
            throw VermouthError.invalidPEFile(path: path, reason: "Unknown optional header magic 0x\(String(magic, radix: 16))")
        }
        guard let directoryCount = u32(raw, optionalOffset + directoryCountOffset),
              directoryCount > UInt32(resourceDirectoryIndex)
        else {
            return nil
        }
        let resourceEntryOffset = optionalOffset + directoryCountOffset + 4 + resourceDirectoryIndex * 8
        guard resourceEntryOffset + 8 <= optionalOffset + Int(optionalSize),
              let resourceRVA = u32(raw, resourceEntryOffset),
              let resourceSize = u32(raw, resourceEntryOffset + 4)
        else {
            return nil
        }
        guard resourceRVA != 0, resourceSize != 0 else {
            return nil
        }

        let sectionTableOffset = optionalOffset + Int(optionalSize)
        for index in 0..<Int(sectionCount) {
            let base = sectionTableOffset + index * 40
            guard let virtualSize = u32(raw, base + 8),
                  let virtualAddress = u32(raw, base + 12),
                  let rawSize = u32(raw, base + 16),
                  let rawPointer = u32(raw, base + 20)
            else {
                throw VermouthError.invalidPEFile(path: path, reason: "Section table truncated at section \(index)")
            }
            let span = max(virtualSize, rawSize)
            guard resourceRVA >= virtualAddress, UInt64(resourceRVA) < UInt64(virtualAddress) + UInt64(span) else {
                continue
            }
            guard rawSize > 0 else {
                return nil
            }
            guard Int(rawSize) <= maximumResourceSectionBytes else {
                throw VermouthError.invalidPEFile(path: path, reason: "Resource section too large (\(rawSize) bytes)")
            }
            return ResourceSectionLocation(
                virtualAddress: virtualAddress,
                pointerToRawData: rawPointer,
                readLength: Int(rawSize),
                resourceRVA: resourceRVA
            )
        }
        return nil
    }

    // MARK: - Resource Tree

    private struct ResourceEntry {
        let id: UInt32? // nil when the entry is identified by a name string
        let offset: UInt32
        let isDirectory: Bool
    }

    private struct DataEntry {
        let rva: UInt32
        let size: UInt32
    }

    private static func extractIcon(
        resourceSection raw: [UInt8],
        sectionVirtualAddress: UInt32,
        rootOffset: Int,
        path: String
    ) throws -> PEIconSet? {
        // 资源树内所有目录 / 数据项偏移都相对于资源目录根（不一定是节起点，资源目录可能并入其他节）
        let rootEntries = try directoryEntries(raw, at: rootOffset, path: path)
        guard let groupType = rootEntries.first(where: { $0.id == resourceTypeGroupIcon && $0.isDirectory }) else {
            return nil
        }
        let iconType = rootEntries.first { $0.id == resourceTypeIcon && $0.isDirectory }

        let groups = try directoryEntries(raw, at: rootOffset + Int(groupType.offset), path: path)
        guard let firstGroup = groups.first else {
            return nil
        }
        guard let groupData = try firstDataEntry(raw, under: firstGroup, rootOffset: rootOffset, path: path) else {
            return nil
        }
        let groupBytes = try slice(raw, rva: groupData.rva, size: groupData.size, base: sectionVirtualAddress, path: path)
        guard groupBytes.count >= groupIconHeaderSize, u16(groupBytes, 2) == 1, let count = u16(groupBytes, 4) else {
            throw VermouthError.invalidPEFile(path: path, reason: "Malformed GRPICONDIR header")
        }

        // 预先建立 RT_ICON id → 数据项的索引
        var iconDataByID: [UInt32: DataEntry] = [:]
        if let iconType {
            for entry in try directoryEntries(raw, at: rootOffset + Int(iconType.offset), path: path) {
                guard let id = entry.id,
                      let data = try firstDataEntry(raw, under: entry, rootOffset: rootOffset, path: path)
                else { continue }
                iconDataByID[id] = data
            }
        }

        var images: [PEIconImage] = []
        var directory: [[UInt8]] = []
        var payloads: [[UInt8]] = []
        for index in 0..<Int(count) {
            let base = groupIconHeaderSize + index * groupIconEntrySize
            guard base + groupIconEntrySize <= groupBytes.count,
                  let bitCount = u16(groupBytes, base + 6),
                  let iconID = u16(groupBytes, base + 12)
            else {
                throw VermouthError.invalidPEFile(path: path, reason: "GRPICONDIR entry \(index) truncated")
            }
            guard let data = iconDataByID[UInt32(iconID)] else {
                continue // 组里引用了不存在的 RT_ICON：跳过该尺寸，保留其余图像
            }
            let payload = try slice(raw, rva: data.rva, size: data.size, base: sectionVirtualAddress, path: path)
            let rawWidth = Int(groupBytes[base])
            let rawHeight = Int(groupBytes[base + 1])
            let isPNG = payload.starts(with: [0x89, 0x50, 0x4E, 0x47])
            images.append(PEIconImage(
                width: rawWidth == 0 ? 256 : rawWidth,
                height: rawHeight == 0 ? 256 : rawHeight,
                bitCount: Int(bitCount),
                isPNG: isPNG,
                byteCount: payload.count
            ))
            // ICONDIRENTRY 的前 12 字节与 GRPICONDIRENTRY 相同（宽、高、色数、保留、平面数、色深、字节数）
            var entry = Array(groupBytes[base..<(base + 8)])
            entry.append(contentsOf: le32(UInt32(payload.count)))
            directory.append(entry)
            payloads.append(payload)
        }

        guard !images.isEmpty else {
            return nil
        }

        var ico: [UInt8] = [0, 0, 1, 0]
        ico.append(contentsOf: le16(UInt16(images.count)))
        var nextOffset = UInt32(6 + images.count * icoDirectoryEntrySize)
        for (entry, payload) in zip(directory, payloads) {
            ico.append(contentsOf: entry)
            ico.append(contentsOf: le32(nextOffset))
            nextOffset += UInt32(payload.count)
        }
        for payload in payloads {
            ico.append(contentsOf: payload)
        }

        return PEIconSet(groupID: firstGroup.id, images: images, icoData: Data(ico))
    }

    private static func directoryEntries(_ raw: [UInt8], at offset: Int, path: String) throws -> [ResourceEntry] {
        guard let named = u16(raw, offset + 12), let numbered = u16(raw, offset + 14) else {
            throw VermouthError.invalidPEFile(path: path, reason: "Resource directory at 0x\(String(offset, radix: 16)) truncated")
        }
        let total = Int(named) + Int(numbered)
        var entries: [ResourceEntry] = []
        entries.reserveCapacity(total)
        for index in 0..<total {
            let base = offset + 16 + index * 8
            guard let nameField = u32(raw, base), let dataField = u32(raw, base + 4) else {
                throw VermouthError.invalidPEFile(path: path, reason: "Resource directory entry truncated")
            }
            let isNamed = (nameField & 0x8000_0000) != 0
            entries.append(ResourceEntry(
                id: isNamed ? nil : nameField,
                offset: dataField & 0x7FFF_FFFF,
                isDirectory: (dataField & 0x8000_0000) != 0
            ))
        }
        return entries
    }

    /// 名称级条目 → 第一个语言级数据项（资源树固定三级，不会无限递归）。
    private static func firstDataEntry(
        _ raw: [UInt8],
        under entry: ResourceEntry,
        rootOffset: Int,
        path: String
    ) throws -> DataEntry? {
        var leafOffset = rootOffset + Int(entry.offset)
        if entry.isDirectory {
            guard let language = try directoryEntries(raw, at: leafOffset, path: path).first, !language.isDirectory else {
                return nil
            }
            leafOffset = rootOffset + Int(language.offset)
        }
        guard let rva = u32(raw, leafOffset), let size = u32(raw, leafOffset + 4) else {
            throw VermouthError.invalidPEFile(path: path, reason: "Resource data entry truncated")
        }
        return DataEntry(rva: rva, size: size)
    }

    private static func slice(_ raw: [UInt8], rva: UInt32, size: UInt32, base: UInt32, path: String) throws -> [UInt8] {
        guard rva >= base else {
            throw VermouthError.invalidPEFile(path: path, reason: "Resource data RVA lies before resource section")
        }
        let start = Int(rva - base)
        let length = Int(size)
        guard start <= raw.count, length <= raw.count - start else {
            throw VermouthError.invalidPEFile(path: path, reason: "Resource data (RVA 0x\(String(rva, radix: 16)), \(size) bytes) exceeds section")
        }
        return Array(raw[start..<(start + length)])
    }

    // MARK: - I/O & Little-Endian Helpers

    private static func read(_ handle: FileHandle, offset: UInt64, length: Int, path: String) throws -> [UInt8] {
        do {
            try handle.seek(toOffset: offset)
            var result: [UInt8] = []
            result.reserveCapacity(min(length, 1 << 20))
            // 普通文件上 read(upToCount:) 可能分段返回，循环读满或直到 EOF
            while result.count < length {
                guard let chunk = try handle.read(upToCount: length - result.count), !chunk.isEmpty else { break }
                result.append(contentsOf: chunk)
            }
            return result
        } catch {
            throw VermouthError.ioError(operation: "readFile", path: path, underlyingDescription: error.localizedDescription)
        }
    }

    @inline(__always)
    private static func u16(_ raw: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= raw.count else { return nil }
        return UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    @inline(__always)
    private static func u32(_ raw: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= raw.count else { return nil }
        return UInt32(raw[offset])
            | (UInt32(raw[offset + 1]) << 8)
            | (UInt32(raw[offset + 2]) << 16)
            | (UInt32(raw[offset + 3]) << 24)
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}
