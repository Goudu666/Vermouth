import Foundation
import XCTest
@testable import VermouthCore

final class PEIconExtractorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try createTempDirectory(prefix: "vermouth-peicon-test")
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private let dibPayload: [UInt8] = [0x28, 0x00, 0x00, 0x00] + Array(repeating: 0xAB, count: 60)
    private let pngPayload: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0xCD, count: 40)

    // MARK: - Happy Paths

    func testExtractsGroupIconAndRebuildsValidICOFromPE32() throws {
        let data = makePE(
            pe32Plus: false,
            icons: [(1, dibPayload), (2, pngPayload)],
            group: [(16, 16, 32, 1), (0, 0, 32, 2)]
        )

        let iconSet = try XCTUnwrap(PEIconExtractor.extractIcon(data: data))
        XCTAssertEqual(iconSet.groupID, 101)
        XCTAssertEqual(iconSet.images, [
            PEIconImage(width: 16, height: 16, bitCount: 32, isPNG: false, byteCount: dibPayload.count),
            PEIconImage(width: 256, height: 256, bitCount: 32, isPNG: true, byteCount: pngPayload.count),
        ])
        XCTAssertEqual(iconSet.largestImage?.width, 256)
        XCTAssertEqual(iconSet.largestImage?.isPNG, true)

        let ico = [UInt8](iconSet.icoData)
        // ICONDIR: reserved 0, type 1 (icon), count 2
        XCTAssertEqual(Array(ico[0..<6]), [0, 0, 1, 0, 2, 0])
        // First ICONDIRENTRY: 16x16, bitCount 32, bytesInRes, imageOffset = 6 + 2*16
        XCTAssertEqual(ico[6], 16)
        XCTAssertEqual(ico[7], 16)
        XCTAssertEqual(readU16(ico, 6 + 6), 32)
        XCTAssertEqual(readU32(ico, 6 + 8), UInt32(dibPayload.count))
        let firstOffset = Int(readU32(ico, 6 + 12))
        XCTAssertEqual(firstOffset, 38)
        // Second entry: 0 means 256 in the on-disk format
        XCTAssertEqual(ico[22], 0)
        let secondOffset = Int(readU32(ico, 22 + 12))
        XCTAssertEqual(secondOffset, firstOffset + dibPayload.count)
        XCTAssertEqual(Array(ico[firstOffset..<(firstOffset + dibPayload.count)]), dibPayload)
        XCTAssertEqual(Array(ico[secondOffset...]), pngPayload)
    }

    func testPE32PlusFromDiskMatchesInMemoryExtraction() throws {
        let data = makePE(pe32Plus: true, icons: [(7, pngPayload)], group: [(0, 0, 32, 7)])
        let fileURL = tempDir.appendingPathComponent("game64.exe")
        try data.write(to: fileURL)

        let fromDisk = try XCTUnwrap(PEIconExtractor.extractIcon(fileAtPath: fileURL.path))
        let fromMemory = try XCTUnwrap(PEIconExtractor.extractIcon(data: data))
        XCTAssertEqual(fromDisk, fromMemory)
        XCTAssertEqual(fromDisk.images.count, 1)
    }

    func testResourceDirectoryNotAtSectionStartIsResolvedRelativeToRoot() throws {
        // Some linkers merge .rsrc into another section, so the resource root is at an offset inside it.
        let data = makePE(pe32Plus: false, icons: [(1, dibPayload)], group: [(32, 32, 8, 1)], rootPadding: 0x80)
        let iconSet = try XCTUnwrap(PEIconExtractor.extractIcon(data: data))
        XCTAssertEqual(iconSet.images.first?.width, 32)
        XCTAssertEqual(iconSet.images.first?.bitCount, 8)
    }

    // MARK: - Absent / Partial Resources

    func testExecutableWithoutResourceDirectoryReturnsNil() throws {
        let data = makePE(pe32Plus: false, icons: [], group: [], includeResourceDirectory: false)
        XCTAssertNil(try PEIconExtractor.extractIcon(data: data))
    }

    func testGroupReferencingMissingIconsSkipsThemAndReturnsNilWhenNoneRemain() throws {
        let partial = makePE(pe32Plus: false, icons: [(1, dibPayload)], group: [(16, 16, 32, 1), (48, 48, 32, 9)])
        let partialSet = try XCTUnwrap(PEIconExtractor.extractIcon(data: partial))
        XCTAssertEqual(partialSet.images.map(\.width), [16])
        XCTAssertEqual(readU16([UInt8](partialSet.icoData), 4), 1, "ICO count must reflect only resolvable images")

        let dangling = makePE(pe32Plus: false, icons: [(1, dibPayload)], group: [(48, 48, 32, 9)])
        XCTAssertNil(try PEIconExtractor.extractIcon(data: dangling))
    }

    // MARK: - Malformed Input Safety

    func testOutOfBoundsResourceDataThrowsInsteadOfTrapping() throws {
        var bytes = [UInt8](makePE(pe32Plus: false, icons: [(1, dibPayload)], group: [(16, 16, 32, 1)]))
        // Corrupt every data-entry size field to a huge value: the group data entry is located by its RVA pattern.
        let layout = lastLayout!
        for entryOffset in layout.dataEntryFileOffsets {
            write32(&bytes, entryOffset + 4, 0x7FFF_FFFF)
        }
        XCTAssertThrowsError(try PEIconExtractor.extractIcon(data: Data(bytes))) { error in
            guard case VermouthError.invalidPEFile = error else {
                return XCTFail("Expected invalidPEFile, got \(error)")
            }
        }
    }

    func testNonPEInputThrows() {
        XCTAssertThrowsError(try PEIconExtractor.extractIcon(data: Data(repeating: 0x00, count: 512)))
        XCTAssertThrowsError(try PEIconExtractor.extractIcon(fileAtPath: tempDir.appendingPathComponent("missing.exe").path))
    }

    // MARK: - Synthetic PE Builder

    private struct Layout {
        var dataEntryFileOffsets: [Int] = []
    }

    private var lastLayout: Layout?

    /// Builds a minimal PE with one section whose resource tree contains RT_ICON entries and one RT_GROUP_ICON (id 101).
    private func makePE(
        pe32Plus: Bool,
        icons: [(id: UInt16, payload: [UInt8])],
        group: [(width: UInt8, height: UInt8, bitCount: UInt16, iconID: UInt16)],
        rootPadding: Int = 0,
        includeResourceDirectory: Bool = true
    ) -> Data {
        let peOffset = 0x80
        let optionalSize = pe32Plus ? 240 : 224
        let sectionTableOffset = peOffset + 24 + optionalSize
        let rawPointer = 0x400
        let sectionVA: UInt32 = 0x2000

        let resource = makeResourceTree(icons: icons, group: group, sectionVA: sectionVA, rootPadding: rootPadding)
        var file = [UInt8](repeating: 0, count: rawPointer)
        file[0] = 0x4D
        file[1] = 0x5A
        write32(&file, 0x3C, UInt32(peOffset))
        file[peOffset] = 0x50
        file[peOffset + 1] = 0x45
        write16(&file, peOffset + 4, pe32Plus ? 0x8664 : 0x014C)
        write16(&file, peOffset + 6, 1) // NumberOfSections
        write16(&file, peOffset + 20, UInt16(optionalSize))
        write16(&file, peOffset + 22, 0x0102)

        let optional = peOffset + 24
        write16(&file, optional, pe32Plus ? 0x020B : 0x010B)
        let countOffset = optional + (pe32Plus ? 108 : 92)
        write32(&file, countOffset, 16) // NumberOfRvaAndSizes
        if includeResourceDirectory {
            let resourceEntry = countOffset + 4 + 2 * 8
            write32(&file, resourceEntry, sectionVA + UInt32(rootPadding))
            write32(&file, resourceEntry + 4, UInt32(resource.bytes.count - rootPadding))
        }

        let section = sectionTableOffset
        file.replaceSubrange(section..<(section + 5), with: Array(".rsrc".utf8))
        write32(&file, section + 8, UInt32(resource.bytes.count)) // VirtualSize
        write32(&file, section + 12, sectionVA)
        write32(&file, section + 16, UInt32(resource.bytes.count)) // SizeOfRawData
        write32(&file, section + 20, UInt32(rawPointer))

        file.append(contentsOf: resource.bytes)
        lastLayout = Layout(dataEntryFileOffsets: resource.dataEntryOffsets.map { $0 + rawPointer })
        return Data(file)
    }

    private func makeResourceTree(
        icons: [(id: UInt16, payload: [UInt8])],
        group: [(width: UInt8, height: UInt8, bitCount: UInt16, iconID: UInt16)],
        sectionVA: UInt32,
        rootPadding: Int
    ) -> (bytes: [UInt8], dataEntryOffsets: [Int]) {
        var groupBytes: [UInt8] = [0, 0, 1, 0]
        groupBytes += le16(UInt16(group.count))
        for item in group {
            groupBytes += [item.width, item.height, 0, 0]
            groupBytes += le16(1) + le16(item.bitCount)
            let size = icons.first { $0.id == item.iconID }?.payload.count ?? 0
            groupBytes += le32(UInt32(size)) + le16(item.iconID)
        }

        // Offsets relative to the resource root.
        let rootSize = 16 + 2 * 8
        let iconTypeDir = rootSize
        let groupTypeDir = iconTypeDir + 16 + icons.count * 8
        let firstLanguageDir = groupTypeDir + 16 + 8
        let languageDirSize = 16 + 8
        let leaves = icons.count + 1 // each icon + the group
        let firstDataEntry = firstLanguageDir + leaves * languageDirSize
        let firstPayload = firstDataEntry + leaves * 16

        var tree = [UInt8](repeating: 0, count: firstPayload)
        func directory(at offset: Int, entries: [(UInt32, UInt32)]) {
            write16(&tree, offset + 14, UInt16(entries.count))
            for (index, entry) in entries.enumerated() {
                write32(&tree, offset + 16 + index * 8, entry.0)
                write32(&tree, offset + 16 + index * 8 + 4, entry.1)
            }
        }
        directory(at: 0, entries: [(3, 0x8000_0000 | UInt32(iconTypeDir)), (14, 0x8000_0000 | UInt32(groupTypeDir))])

        let payloads: [[UInt8]] = icons.map(\.payload) + [groupBytes]
        var iconEntries: [(UInt32, UInt32)] = []
        for (index, icon) in icons.enumerated() {
            iconEntries.append((UInt32(icon.id), 0x8000_0000 | UInt32(firstLanguageDir + index * languageDirSize)))
        }
        directory(at: iconTypeDir, entries: iconEntries)
        directory(at: groupTypeDir, entries: [(101, 0x8000_0000 | UInt32(firstLanguageDir + icons.count * languageDirSize))])

        var payloadCursor = firstPayload
        var dataEntryOffsets: [Int] = []
        for leaf in 0..<leaves {
            let languageDir = firstLanguageDir + leaf * languageDirSize
            let dataEntry = firstDataEntry + leaf * 16
            directory(at: languageDir, entries: [(0x409, UInt32(dataEntry))])
            let payload = payloads[leaf]
            write32(&tree, dataEntry, sectionVA + UInt32(rootPadding + payloadCursor))
            write32(&tree, dataEntry + 4, UInt32(payload.count))
            dataEntryOffsets.append(rootPadding + dataEntry)
            payloadCursor += payload.count
        }
        payloads.forEach { tree += $0 }
        return ([UInt8](repeating: 0xEE, count: rootPadding) + tree, dataEntryOffsets)
    }

    // MARK: - Byte Helpers

    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    private func write16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes.replaceSubrange(offset..<(offset + 2), with: le16(value))
    }

    private func write32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes.replaceSubrange(offset..<(offset + 4), with: le32(value))
    }

    private func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
