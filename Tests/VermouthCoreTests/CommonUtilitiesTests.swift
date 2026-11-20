import Foundation
import XCTest
@testable import VermouthCore

final class CommonUtilitiesTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vermouth-common-test-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - PureSHA256

    func testPureSHA256OfficialNISTVectors() {
        XCTAssertEqual(
            PureSHA256.hash(string: ""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            PureSHA256.hash(string: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        // 56-byte exact padding-spill boundary (448-bit NIST FIPS 180-4 vector)
        XCTAssertEqual(
            PureSHA256.hash(string: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // 112-char multi-block NIST FIPS 180-4 vector
        let multiBlock = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        XCTAssertEqual(
            PureSHA256.hash(string: multiBlock),
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        )
    }

    func testPureSHA256IncrementalContextMatchesSingleShot() {
        let message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        let fullData = Data(message.utf8)
        let expectedHex = "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"

        // Feed irregular chunk sizes spanning block boundaries, including empty chunks.
        let chunkSizes = [0, 1, 7, 13, 64, 0, 5, 22]
        var context = PureSHA256.Context()
        var offset = 0
        var sizeIndex = 0
        while offset < fullData.count {
            let chunkSize = chunkSizes[sizeIndex % chunkSizes.count]
            sizeIndex += 1
            let end = min(offset + chunkSize, fullData.count)
            context.update(fullData.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertEqual(context.finalizeHex(), expectedHex)

        // Verify raw digest byte length and values match.
        var byteContext = PureSHA256.Context()
        byteContext.update(fullData)
        let digestBytes = byteContext.finalize()
        XCTAssertEqual(digestBytes.count, 32)
        XCTAssertEqual(digestBytes.first, 0xcf)
        XCTAssertEqual(digestBytes.last, 0xd1)
    }

    func testPureSHA256HashFileStreamingOver128KB() throws {
        // 200,003 bytes (> 128KB and not a multiple of the 64KB streaming buffer)
        var bytes = [UInt8](repeating: 0, count: 200_003)
        for i in 0..<bytes.count {
            bytes[i] = UInt8((i * 31 + 17) & 0xff)
        }
        let payload = Data(bytes)
        let fileURL = tempRoot.appendingPathComponent("large-streaming-payload.bin")
        try payload.write(to: fileURL)

        let expectedKnownDigest = "9eb3796d82883a13f26c159486bbf1b54a54f8ab526ccad16659ec01f26e7ba2"
        let memoryDigest = PureSHA256.hash(data: payload)
        let fileDigest = try PureSHA256.hashFile(at: fileURL)

        XCTAssertEqual(memoryDigest, expectedKnownDigest)
        XCTAssertEqual(fileDigest, expectedKnownDigest)
        XCTAssertEqual(fileDigest, memoryDigest)
    }

    func testPureSHA256HashFileMissingFileThrowsIOError() {
        let missingURL = tempRoot.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try PureSHA256.hashFile(at: missingURL)) { error in
            guard case VermouthError.ioError(let operation, _, _) = error else {
                XCTFail("Expected VermouthError.ioError, got \(error)")
                return
            }
            XCTAssertEqual(operation, "openFile")
        }
    }

    // MARK: - VermouthJSON

    private struct JSONSample: Codable, Equatable, Sendable {
        var zPath: String
        var aName: String
        var createdAt: Date
        var updatedAt: Date
    }

    func testVermouthJSONRoundTripFractionalSecondsAndFormatting() throws {
        // Use binary-exact millisecond timestamps (.375 and .625) to guarantee exact Date equality (L-011).
        let sample = JSONSample(
            zPath: "/Users/test/Library/Application Support/Vermouth/drive_c/game.exe",
            aName: "alpha",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.375),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_123.625)
        )

        let encoded = try VermouthJSON.encode(sample)
        let jsonString = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        // Verify .prettyPrinted
        XCTAssertTrue(jsonString.contains("\n"))

        // Verify .sortedKeys (aName < createdAt < updatedAt < zPath)
        let aNameRange = try XCTUnwrap(jsonString.range(of: "\"aName\""))
        let createdAtRange = try XCTUnwrap(jsonString.range(of: "\"createdAt\""))
        let updatedAtRange = try XCTUnwrap(jsonString.range(of: "\"updatedAt\""))
        let zPathRange = try XCTUnwrap(jsonString.range(of: "\"zPath\""))
        XCTAssertTrue(aNameRange.lowerBound < createdAtRange.lowerBound)
        XCTAssertTrue(createdAtRange.lowerBound < updatedAtRange.lowerBound)
        XCTAssertTrue(updatedAtRange.lowerBound < zPathRange.lowerBound)

        // Verify .withoutEscapingSlashes
        XCTAssertTrue(jsonString.contains("\"/Users/test/Library/Application Support/Vermouth/drive_c/game.exe\""))
        XCTAssertFalse(jsonString.contains("\\/"))

        // Verify fractional milliseconds appear in ISO-8601 output
        XCTAssertTrue(jsonString.contains("\"2023-11-14T22:13:20.375Z\""))
        XCTAssertTrue(jsonString.contains("\"2023-11-14T22:15:23.625Z\""))

        // Verify exact Equatable round-trip
        let decoded = try VermouthJSON.decode(JSONSample.self, from: encoded)
        XCTAssertEqual(decoded, sample)
    }

    func testVermouthJSONDecodesNonFractionalAndOffsetISO8601Dates() throws {
        struct DateHolder: Codable, Equatable {
            var utcNoFractional: Date
            var offsetNoFractional: Date
            var utcFractional: Date
        }

        let rawJSON = """
        {
          "offsetNoFractional": "2025-08-15T20:34:56+08:00",
          "utcFractional": "2023-11-14T22:13:20.375Z",
          "utcNoFractional": "2025-08-15T12:34:56Z"
        }
        """

        let decoded = try VermouthJSON.decode(DateHolder.self, from: Data(rawJSON.utf8))
        XCTAssertEqual(decoded.utcNoFractional, Date(timeIntervalSince1970: 1_755_261_296.0))
        XCTAssertEqual(decoded.offsetNoFractional, Date(timeIntervalSince1970: 1_755_261_296.0))
        XCTAssertEqual(decoded.utcFractional, Date(timeIntervalSince1970: 1_700_000_000.375))
    }

    func testVermouthJSONRejectsInvalidDateString() {
        struct DateBox: Codable {
            var date: Date
        }

        let invalidJSON = Data("{\"date\": \"not-a-valid-date\"}".utf8)
        XCTAssertThrowsError(try VermouthJSON.decode(DateBox.self, from: invalidJSON))
    }

    func testVermouthJSONWriteAtomicallyOverwritesSafelyWithoutStrayTempFiles() throws {
        let nestedDir = tempRoot.appendingPathComponent("nested/config", isDirectory: true)
        let targetURL = nestedDir.appendingPathComponent("state.json", isDirectory: false)

        let first = JSONSample(
            zPath: "/first/path",
            aName: "first",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.250),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000.500)
        )
        try VermouthJSON.writeAtomically(first, to: targetURL)
        XCTAssertEqual(try VermouthJSON.read(JSONSample.self, from: targetURL), first)

        let second = JSONSample(
            zPath: "/second/overwritten/path",
            aName: "second",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.250),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_123.750)
        )
        try VermouthJSON.writeAtomically(second, to: targetURL)
        XCTAssertEqual(try VermouthJSON.read(JSONSample.self, from: targetURL), second)

        // Include hidden dotfiles (contentsOfDirectory(atPath:) does not skip dotfiles) to ensure no `.state.json.tmp.*` remains.
        let entries = try FileManager.default.contentsOfDirectory(atPath: nestedDir.path)
        XCTAssertEqual(entries, ["state.json"])
        XCTAssertFalse(entries.contains(where: { $0.contains(".tmp.") }))
    }

    func testVermouthJSONReadErrors() throws {
        let missingURL = tempRoot.appendingPathComponent("missing.json")
        XCTAssertThrowsError(try VermouthJSON.read(JSONSample.self, from: missingURL)) { error in
            guard case VermouthError.ioError(let operation, _, _) = error else {
                XCTFail("Expected VermouthError.ioError, got \(error)")
                return
            }
            XCTAssertEqual(operation, "read")
        }

        let malformedURL = tempRoot.appendingPathComponent("malformed.json")
        try Data("{ invalid json".utf8).write(to: malformedURL)
        XCTAssertThrowsError(try VermouthJSON.read(JSONSample.self, from: malformedURL)) { error in
            guard case VermouthError.decodingFailed(_, let path, _) = error else {
                XCTFail("Expected VermouthError.decodingFailed, got \(error)")
                return
            }
            XCTAssertEqual(path, malformedURL.standardizedFileURL.path)
        }
    }

    // MARK: - ShellQuoting

    func testShellQuotingPosixEscape() {
        // Empty string
        XCTAssertEqual(ShellQuoting.posixEscape(""), "''")

        // Safe bare tokens pass through unmodified
        XCTAssertEqual(ShellQuoting.posixEscape("/opt/homebrew/bin/wine"), "/opt/homebrew/bin/wine")
        XCTAssertEqual(ShellQuoting.posixEscape("dinput8=n,b"), "dinput8=n,b")
        XCTAssertEqual(ShellQuoting.posixEscape("--version"), "--version")
        XCTAssertEqual(ShellQuoting.posixEscape("zh_CN.UTF-8"), "zh_CN.UTF-8")

        // Spaces and parentheses
        XCTAssertEqual(
            ShellQuoting.posixEscape("/tmp/prefix/drive_c/Program Files (x86)/Game/app.exe"),
            "'/tmp/prefix/drive_c/Program Files (x86)/Game/app.exe'"
        )

        // Embedded single quotes
        XCTAssertEqual(ShellQuoting.posixEscape("O'Brien"), "'O'\\''Brien'")
        XCTAssertEqual(ShellQuoting.posixEscape("'"), "''\\'''")

        // Dollar / backtick / semicolon / command injection resistance
        XCTAssertEqual(ShellQuoting.posixEscape("$(rm -rf /)"), "'$(rm -rf /)'")
        XCTAssertEqual(ShellQuoting.posixEscape("`whoami`"), "'`whoami`'")
        XCTAssertEqual(ShellQuoting.posixEscape("$HOME; id | cat"), "'$HOME; id | cat'")
        XCTAssertEqual(ShellQuoting.posixEscape("d3d11=b;dinput8=n,b"), "'d3d11=b;dinput8=n,b'")

        // Non-ASCII characters are single-quoted
        XCTAssertEqual(ShellQuoting.posixEscape("游戏/启动.exe"), "'游戏/启动.exe'")
    }

    func testShellQuotingFormatCommandDeterministicEnvSorting() {
        let env: [String: String] = [
            "WINEPREFIX": "/Users/O'Brien/Bottles/GTA SA/prefix",
            "LC_ALL": "zh_CN.UTF-8",
            "WINEDLLOVERRIDES": "d3d11=b;dinput8=n,b",
            "MTL_HUD_ENABLED": "1",
        ]

        let formatted = ShellQuoting.formatCommand(
            environment: env,
            executable: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
            arguments: ["C:\\Program Files (x86)\\Game\\gta_sa.exe", "--windowed", "$(echo hi)"]
        )

        let expected = [
            "LC_ALL=zh_CN.UTF-8",
            "MTL_HUD_ENABLED=1",
            "WINEDLLOVERRIDES='d3d11=b;dinput8=n,b'",
            "WINEPREFIX='/Users/O'\\''Brien/Bottles/GTA SA/prefix'",
            "'/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine'",
            "'C:\\Program Files (x86)\\Game\\gta_sa.exe'",
            "--windowed",
            "'$(echo hi)'",
        ].joined(separator: " ")

        XCTAssertEqual(formatted, expected)
        XCTAssertEqual(ShellQuoting.formatCommand(executable: "/usr/bin/env"), "/usr/bin/env")
    }

    func testShellQuotingToWindowsPath() {
        let prefix = "/Users/tester/Library/Application Support/Vermouth/bottles/b1/prefix"

        // Inside drive_c
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(
                unixPath: "\(prefix)/drive_c/Program Files (x86)/Rockstar Games/gta_sa.exe",
                prefixPath: prefix
            ),
            "C:\\Program Files (x86)\\Rockstar Games\\gta_sa.exe"
        )

        // Exact drive_c root and trailing slashes
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(unixPath: "\(prefix)/drive_c", prefixPath: prefix),
            "C:\\"
        )
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(unixPath: "\(prefix)/drive_c/", prefixPath: "\(prefix)/"),
            "C:\\"
        )
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(unixPath: "\(prefix)/drive_c/windows/system32/", prefixPath: "\(prefix)///"),
            "C:\\windows\\system32"
        )

        // Sibling directory named drive_c_backup must NOT match drive_c
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(unixPath: "\(prefix)/drive_c_backup/app.exe", prefixPath: prefix),
            "Z:\\Users\\tester\\Library\\Application Support\\Vermouth\\bottles\\b1\\prefix\\drive_c_backup\\app.exe"
        )

        // External host path -> Z:\...
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(unixPath: "/Users/foo/setup.msi", prefixPath: prefix),
            "Z:\\Users\\foo\\setup.msi"
        )
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(unixPath: "/Users/foo/installers/", prefixPath: prefix),
            "Z:\\Users\\foo\\installers"
        )
        XCTAssertEqual(
            ShellQuoting.toWindowsPath(unixPath: "/", prefixPath: prefix),
            "Z:\\"
        )
    }

    func testShellQuotingToUnixPath() {
        let prefix = "/tmp/vermouth/bottles/b1/prefix"

        // C:\ and c:/ variants
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "C:\\Program Files (x86)\\Game\\app.exe", prefixPath: prefix),
            "\(prefix)/drive_c/Program Files (x86)/Game/app.exe"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "c:/windows/system32/cmd.exe", prefixPath: "\(prefix)/"),
            "\(prefix)/drive_c/windows/system32/cmd.exe"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "C:\\", prefixPath: prefix),
            "\(prefix)/drive_c"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "C:", prefixPath: prefix),
            "\(prefix)/drive_c"
        )

        // Z:\ and z:/ variants
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "Z:\\Users\\foo\\setup.msi", prefixPath: prefix),
            "/Users/foo/setup.msi"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "z:/Users/foo/setup.msi", prefixPath: prefix),
            "/Users/foo/setup.msi"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "Z:\\", prefixPath: prefix),
            "/"
        )

        // Clamped `..` never escapes drive_c or root
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "C:\\..\\..\\..\\etc\\passwd", prefixPath: prefix),
            "\(prefix)/drive_c/etc/passwd"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "C:\\windows\\..\\..\\..", prefixPath: prefix),
            "\(prefix)/drive_c"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "C:\\Program Files\\..\\Users\\.\\Admin", prefixPath: prefix),
            "\(prefix)/drive_c/Users/Admin"
        )
        XCTAssertEqual(
            ShellQuoting.toUnixPath(windowsPath: "Z:\\..\\..\\Users\\foo", prefixPath: prefix),
            "/Users/foo"
        )

        // Invalid or unsupported Windows paths return nil
        XCTAssertNil(ShellQuoting.toUnixPath(windowsPath: "D:\\Games\\app.exe", prefixPath: prefix))
        XCTAssertNil(ShellQuoting.toUnixPath(windowsPath: "C:relative.exe", prefixPath: prefix))
        XCTAssertNil(ShellQuoting.toUnixPath(windowsPath: "", prefixPath: prefix))
        XCTAssertNil(ShellQuoting.toUnixPath(windowsPath: "C", prefixPath: prefix))
        XCTAssertNil(ShellQuoting.toUnixPath(windowsPath: "/Users/foo/app.exe", prefixPath: prefix))
    }

    // MARK: - VermouthPaths

    func testVermouthPathsDefaultAndEnvOverride() throws {
        let fakeHome = tempRoot.appendingPathComponent("fake-home", isDirectory: true).standardizedFileURL

        // Default Application Support/Vermouth path when VERMOUTH_HOME is absent or blank
        let defaultPaths = VermouthPaths(environment: [:], homeDirectory: fakeHome)
        let expectedDefault = fakeHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Vermouth", isDirectory: true)
            .standardizedFileURL
        XCTAssertEqual(defaultPaths.baseDirectory, expectedDefault)

        let blankEnvPaths = VermouthPaths(environment: ["VERMOUTH_HOME": "   \n "], homeDirectory: fakeHome)
        XCTAssertEqual(blankEnvPaths.baseDirectory, expectedDefault)

        // VERMOUTH_HOME absolute override
        let customBase = tempRoot.appendingPathComponent("custom-vermouth-home", isDirectory: true).standardizedFileURL
        let overridePaths = VermouthPaths(
            environment: ["VERMOUTH_HOME": "  \(customBase.path)  "],
            homeDirectory: fakeHome
        )
        XCTAssertEqual(overridePaths.baseDirectory, customBase)

        // VERMOUTH_HOME tilde expansion
        let tildePaths = VermouthPaths(
            environment: ["VERMOUTH_HOME": "~/PortableVermouth"],
            homeDirectory: fakeHome
        )
        XCTAssertEqual(
            tildePaths.baseDirectory,
            fakeHome.appendingPathComponent("PortableVermouth", isDirectory: true).standardizedFileURL
        )

        // Verify derived layout and path traversal sanitization
        let bottleID = UUID()
        XCTAssertEqual(overridePaths.enginesConfigURL.path, customBase.appendingPathComponent("engines.json").path)
        XCTAssertEqual(overridePaths.graphicsIndexURL.path, customBase.appendingPathComponent("graphics/index.json").path)
        XCTAssertEqual(
            overridePaths.graphicsPackageDirectory(backend: .dxmt, version: "v0.80").path,
            customBase.appendingPathComponent("graphics/dxmt/v0.80").path
        )
        XCTAssertEqual(
            overridePaths.graphicsPackageDirectory(backend: .dxvk, version: "..").lastPathComponent,
            "unknown"
        )
        XCTAssertEqual(
            overridePaths.graphicsPackageDirectory(backend: .dxvk, version: "../escape/v1").lastPathComponent,
            "..-escape-v1"
        )
        XCTAssertEqual(
            overridePaths.bottleConfigURL(id: bottleID).path,
            customBase.appendingPathComponent("bottles/\(bottleID.uuidString)/bottle.json").path
        )
        XCTAssertEqual(
            overridePaths.bottlePrefixURL(id: bottleID).path,
            customBase.appendingPathComponent("bottles/\(bottleID.uuidString)/prefix").path
        )
        XCTAssertEqual(
            overridePaths.bottleGraphicsStateURL(id: bottleID).path,
            customBase.appendingPathComponent("bottles/\(bottleID.uuidString)/graphics-state.json").path
        )
        XCTAssertEqual(
            overridePaths.bottleSnapshotsIndexURL(id: bottleID).path,
            customBase.appendingPathComponent("bottles/\(bottleID.uuidString)/snapshots/index.json").path
        )

        // Directory provisioning
        try overridePaths.ensureBaseDirectories()
        for dir in [
            overridePaths.baseDirectory,
            overridePaths.graphicsDirectory,
            overridePaths.recipesDirectory,
            overridePaths.bottlesDirectory,
        ] {
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    // MARK: - VermouthResourceLocator

    func testVermouthResourceLocatorFindsAndDecodesBuiltInRecipes() throws {
        let directory = try XCTUnwrap(
            VermouthResourceLocator.builtInRecipesDirectory(),
            "Built-in recipes directory must be resolvable"
        )
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) && isDir.boolValue)

        let files = VermouthResourceLocator.builtInRecipeFiles()
        let fileNames = files.map(\.lastPathComponent)
        XCTAssertEqual(fileNames, fileNames.sorted(), "Built-in recipe files should be lexicographically sorted")
        XCTAssertTrue(fileNames.contains("dx11-modern-default.recipe.json"))
        XCTAssertTrue(fileNames.contains("gtasa-pc-1.0.recipe.json"))

        var decodedByID: [String: Recipe] = [:]
        for fileURL in files {
            let recipe = try VermouthJSON.read(Recipe.self, from: fileURL)
            XCTAssertEqual(recipe.schemaVersion, Recipe.currentSchemaVersion)
            XCTAssertFalse(recipe.id.isEmpty)
            XCTAssertFalse(recipe.name.isEmpty)
            decodedByID[recipe.id] = recipe
        }

        let dx11Recipe = try XCTUnwrap(decodedByID["dx11-modern-default"])
        XCTAssertEqual(dx11Recipe.targetArchitecture, .x86_64)
        XCTAssertEqual(dx11Recipe.recommendedWindowsVersion, .win10)
        XCTAssertEqual(dx11Recipe.recommendedBackend, .dxmt)
        XCTAssertEqual(dx11Recipe.recommendedSyncMode, .msync)
        XCTAssertTrue(dx11Recipe.chineseLocalizationSuggested)
        XCTAssertTrue(dx11Recipe.dllOverrides.isEmpty)
        XCTAssertFalse(dx11Recipe.notes.isEmpty)
        XCTAssertFalse(dx11Recipe.knownIssues.isEmpty)

        let gtasaRecipe = try XCTUnwrap(decodedByID["gtasa-pc-1.0"])
        XCTAssertEqual(gtasaRecipe.targetArchitecture, .x86_32)
        XCTAssertEqual(gtasaRecipe.recommendedWindowsVersion, .win7)
        XCTAssertEqual(gtasaRecipe.recommendedBackend, .wined3d)
        XCTAssertEqual(gtasaRecipe.recommendedSyncMode, .msync)
        XCTAssertTrue(gtasaRecipe.chineseLocalizationSuggested)
        XCTAssertEqual(gtasaRecipe.dllOverrides.map(\.dllName), ["dinput8", "vorbisfile"])
        XCTAssertTrue(gtasaRecipe.dllOverrides.allSatisfy { $0.mode == .nativeThenBuiltin && !$0.enabled })
        XCTAssertFalse(gtasaRecipe.notes.isEmpty)
        XCTAssertFalse(gtasaRecipe.knownIssues.isEmpty)
    }
}
