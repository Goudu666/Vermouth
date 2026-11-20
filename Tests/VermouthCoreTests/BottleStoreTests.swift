import Foundation
import XCTest
@testable import VermouthCore

final class BottleStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var paths: VermouthPaths!
    private var store: BottleStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vermouth-bottlestore-test-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        paths = VermouthPaths(baseDirectory: tempRoot.appendingPathComponent("vermouth-home", isDirectory: true))
        store = BottleStore(paths: paths)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        store = nil
        paths = nil
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeFakeExternalPrefix(named folderName: String, withDriveC: Bool = true, withSystemReg: Bool = true) throws -> URL {
        let prefixURL = tempRoot.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)

        if withDriveC {
            let gameDir = prefixURL.appendingPathComponent("drive_c/Games/MyGame", isDirectory: true)
            try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
            try Data("SAVE-SLOT-CONTENT".utf8).write(to: gameDir.appendingPathComponent("important.sav"))
        }

        if withSystemReg {
            try Data("WINE REGISTRY Version 2\n".utf8).write(to: prefixURL.appendingPathComponent("system.reg"))
        }

        return prefixURL
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - CRUD Lifecycle

    func testCreateLoadAndListBottlesDeterministicOrder() throws {
        XCTAssertEqual(try store.listBottles(), [])

        let customConfig = BottleConfig(
            engineID: "old-engine",
            windowsVersion: .win7,
            syncMode: .esync,
            graphicsBackend: .dxvk,
            graphicsLayerVersionID: "dxvk-v1.10.3",
            wineDebugChannels: "-all,err+all"
        )

        var first = try store.createBottle(
            name: "  GTA San Andreas  ",
            engineID: "override-engine",
            initialConfig: customConfig
        )
        XCTAssertEqual(first.name, "GTA San Andreas")
        XCTAssertEqual(first.schemaVersion, Bottle.currentSchemaVersion)
        XCTAssertFalse(first.isExternalPrefix)
        XCTAssertEqual(first.prefixPath, paths.bottlePrefixURL(id: first.id).path)
        XCTAssertEqual(first.config.engineID, "override-engine")
        XCTAssertEqual(first.config.windowsVersion, .win7)
        XCTAssertEqual(first.config.syncMode, .esync)
        XCTAssertEqual(first.config.graphicsBackend, .dxvk)

        // Verify per-bottle directories and config file were created
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.bottleConfigURL(id: first.id).path))
        XCTAssertTrue(directoryExists(at: paths.bottlePrefixURL(id: first.id)))
        XCTAssertTrue(directoryExists(at: paths.bottleSnapshotsDirectory(id: first.id)))
        XCTAssertTrue(directoryExists(at: paths.bottleLogsDirectory(id: first.id)))
        XCTAssertTrue(directoryExists(at: paths.bottleBackupsDirectory(id: first.id)))

        var second = try store.createBottle(name: "Second Bottle")
        var third = try store.createBottle(name: "Third Bottle")

        // Assign controlled createdAt values including an exact tie to verify deterministic sort:
        // createdAt ascending, then id.uuidString ascending on tie.
        let earlier = Date(timeIntervalSince1970: 1_700_000_000.250)
        let tiedTime = Date(timeIntervalSince1970: 1_700_000_500.500)
        first.createdAt = tiedTime
        second.createdAt = earlier
        third.createdAt = tiedTime
        try store.saveBottle(first)
        try store.saveBottle(second)
        try store.saveBottle(third)

        // Also drop a stray directory without bottle.json and a stray file inside bottles/ to verify listBottles ignores them.
        let strayDir = paths.bottlesDirectory.appendingPathComponent("orphan-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: paths.bottlesDirectory.appendingPathComponent("README.txt"))

        let listed = try store.listBottles()
        let expectedTiedOrder = [first.id, third.id].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(listed.map(\.id), [second.id] + expectedTiedOrder)

        // Loading an unknown UUID throws bottleNotFound
        let unknownID = UUID()
        XCTAssertThrowsError(try store.loadBottle(id: unknownID)) { error in
            guard case VermouthError.bottleNotFound(let identifier) = error else {
                XCTFail("Expected VermouthError.bottleNotFound, got \(error)")
                return
            }
            XCTAssertEqual(identifier, unknownID.uuidString)
        }
    }

    func testCreateBottleRejectsInvalidNames() {
        for badName in ["", "   ", "\t\n ", "Line1\nLine2", "Carriage\rReturn", "Null\0Byte"] {
            XCTAssertThrowsError(try store.createBottle(name: badName)) { error in
                guard case VermouthError.invalidBottleName = error else {
                    XCTFail("Expected VermouthError.invalidBottleName for \(badName.debugDescription), got \(error)")
                    return
                }
            }
        }
    }

    func testSaveBottleExactReloadEqualityAndValidation() throws {
        var bottle = try store.createBottle(name: "Exact Reload Test")

        // Use binary-exact millisecond dates so Codable round-trip preserves exact Date equality (L-011).
        bottle.createdAt = Date(timeIntervalSince1970: 1_700_000_000.250)
        bottle.updatedAt = Date(timeIntervalSince1970: 1_700_000_600.750)
        bottle.appliedRecipeID = "gtasa-pc-1.0"
        bottle.config = BottleConfig(
            engineID: "app-wine-stable",
            windowsVersion: .win11,
            syncMode: .msync,
            graphicsBackend: .dxmt,
            graphicsLayerVersionID: "dxmt-v0.80",
            display: DisplayConfig(
                retinaMode: true,
                dpi: 192,
                metalHUD: true,
                virtualDesktop: VirtualDesktopConfig(enabled: true, width: 1600, height: 900)
            ),
            locale: LocaleConfig(
                chineseLocalizationEnabled: true,
                lcAll: "zh_CN.UTF-8",
                fallbackFontName: "STHeiti"
            ),
            dllOverrides: [
                DllOverride(dllName: "DInput8.DLL", mode: .nativeThenBuiltin, enabled: true, note: "ASI"),
                DllOverride(dllName: "vorbisfile", mode: .nativeThenBuiltin, enabled: false, note: "CLEO"),
            ],
            environmentVariables: ["DXMT_HUD": "1", "TEST_KEY": "value"],
            wineDebugChannels: "-all,err+all"
        )
        bottle.apps = [
            AppEntry(
                id: UUID(),
                name: "Game",
                executablePath: "\(bottle.prefixPath)/drive_c/Games/game.exe",
                arguments: ["-dx11"],
                workingDirectory: "\(bottle.prefixPath)/drive_c/Games",
                environmentOverrides: ["APP_ENV": "yes"],
                dllOverrides: [DllOverride(dllName: "winhttp", mode: .nativeThenBuiltin)],
                snapshotTargets: [
                    SnapshotTarget(id: UUID(), label: "Saves", path: "\(bottle.prefixPath)/drive_c/Saves"),
                ],
                isPinned: true,
                lastLaunchedAt: Date(timeIntervalSince1970: 1_700_000_555.125)
            ),
        ]

        try store.saveBottle(bottle)
        let reloaded = try store.loadBottle(id: bottle.id)
        XCTAssertEqual(reloaded, bottle)

        // Saving a non-existent bottle ID fails with bottleNotFound
        let phantom = Bottle(id: UUID(), name: "Ghost", prefixPath: "/tmp/ghost/prefix")
        XCTAssertThrowsError(try store.saveBottle(phantom)) { error in
            guard case VermouthError.bottleNotFound = error else {
                XCTFail("Expected VermouthError.bottleNotFound, got \(error)")
                return
            }
        }

        // Saving with unsupported schemaVersion fails
        var futureSchema = bottle
        futureSchema.schemaVersion = Bottle.currentSchemaVersion + 10
        XCTAssertThrowsError(try store.saveBottle(futureSchema)) { error in
            guard case VermouthError.unsupportedSchemaVersion(let found, let supported, _) = error else {
                XCTFail("Expected VermouthError.unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(found, Bottle.currentSchemaVersion + 10)
            XCTAssertEqual(supported, Bottle.currentSchemaVersion)
        }

        // Loading a bottle.json with unsupported schemaVersion on disk also fails
        try VermouthJSON.writeAtomically(futureSchema, to: paths.bottleConfigURL(id: bottle.id))
        XCTAssertThrowsError(try store.loadBottle(id: bottle.id)) { error in
            guard case VermouthError.unsupportedSchemaVersion = error else {
                XCTFail("Expected VermouthError.unsupportedSchemaVersion, got \(error)")
                return
            }
        }
    }

    func testRenameBottleTrimsWhitespaceAndRejectsEmpty() throws {
        let original = try store.createBottle(name: "Initial Name")

        let renamed = try store.renameBottle(id: original.id, newName: "  \t Clean Renamed Name  \n ")
        XCTAssertEqual(renamed.name, "Clean Renamed Name")
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertGreaterThanOrEqual(renamed.updatedAt.timeIntervalSince1970, original.updatedAt.timeIntervalSince1970)

        let reloaded = try store.loadBottle(id: original.id)
        XCTAssertEqual(reloaded.name, "Clean Renamed Name")

        // Empty / whitespace / newline names must throw and leave persisted name unchanged
        for invalid in ["", "    ", "\n\t", "Bad\nName", "Bad\0Name"] {
            XCTAssertThrowsError(try store.renameBottle(id: original.id, newName: invalid)) { error in
                guard case VermouthError.invalidBottleName = error else {
                    XCTFail("Expected VermouthError.invalidBottleName, got \(error)")
                    return
                }
            }
        }
        XCTAssertEqual(try store.loadBottle(id: original.id).name, "Clean Renamed Name")

        // Unknown ID throws bottleNotFound
        XCTAssertThrowsError(try store.renameBottle(id: UUID(), newName: "Valid")) { error in
            guard case VermouthError.bottleNotFound = error else {
                XCTFail("Expected VermouthError.bottleNotFound, got \(error)")
                return
            }
        }
    }

    func testFindBottleByUUIDExactNameAndCaseInsensitiveFallback() throws {
        let gta = try store.createBottle(name: "GTA San Andreas")
        let alphaUpper = try store.createBottle(name: "Alpha")
        let alphaLower = try store.createBottle(name: "alpha")

        // Lookup by UUID (exact & whitespace padded)
        XCTAssertEqual(try store.findBottle(nameOrID: gta.id.uuidString).id, gta.id)
        XCTAssertEqual(try store.findBottle(nameOrID: "  \(gta.id.uuidString.lowercased())  ").id, gta.id)

        // Lookup by exact case-sensitive name takes precedence over case-insensitive collision
        XCTAssertEqual(try store.findBottle(nameOrID: "Alpha").id, alphaUpper.id)
        XCTAssertEqual(try store.findBottle(nameOrID: "alpha").id, alphaLower.id)

        // Lookup by case-insensitive fallback
        XCTAssertEqual(try store.findBottle(nameOrID: "gta san andreas").id, gta.id)
        XCTAssertEqual(try store.findBottle(nameOrID: "  GTA SAN ANDREAS ").id, gta.id)

        // Missing or empty queries throw bottleNotFound
        for missing in ["", "   ", "NonExistentBottle", UUID().uuidString] {
            XCTAssertThrowsError(try store.findBottle(nameOrID: missing)) { error in
                guard case VermouthError.bottleNotFound = error else {
                    XCTFail("Expected VermouthError.bottleNotFound for \(missing.debugDescription), got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Clone Bottle

    func testCloneBottleCopiesPrefixAndGraphicsStateAndRewritesPaths() throws {
        var source = try store.createBottle(
            name: "Source Game",
            engineID: "wine-stable",
            initialConfig: BottleConfig(
                windowsVersion: .win7,
                syncMode: .msync,
                graphicsBackend: .dxvk,
                graphicsLayerVersionID: "dxvk-v1.10.3"
            )
        )
        source.appliedRecipeID = "gtasa-pc-1.0"

        // Populate source prefix files
        let sourcePrefixURL = URL(fileURLWithPath: source.prefixPath, isDirectory: true)
        let sourceGameDir = sourcePrefixURL.appendingPathComponent("drive_c/Program Files (x86)/MyGame", isDirectory: true)
        let sourceSavesDir = sourcePrefixURL.appendingPathComponent("drive_c/users/crossover/Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceGameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceSavesDir, withIntermediateDirectories: true)
        try Data("ORIGINAL-EXE".utf8).write(to: sourceGameDir.appendingPathComponent("game.exe"))
        try Data("ORIGINAL-SAVE".utf8).write(to: sourceSavesDir.appendingPathComponent("slot1.sav"))
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: sourcePrefixURL.appendingPathComponent("system.reg"))

        // Write graphics-state.json and a backup file
        let graphicsState = GraphicsDeploymentRecord(
            backend: .dxvk,
            packageID: "dxvk-v1.10.3",
            strategy: .prefixCopyWithBackup,
            deployedFiles: ["drive_c/windows/system32/d3d11.dll"],
            backedUpFiles: ["drive_c/windows/system32/d3d11.dll": "system32/d3d11.dll.orig"],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200.250)
        )
        try VermouthJSON.writeAtomically(graphicsState, to: paths.bottleGraphicsStateURL(id: source.id))
        try Data("BACKUP-DLL".utf8).write(
            to: paths.bottleBackupsDirectory(id: source.id).appendingPathComponent("d3d11.dll.orig")
        )

        // Add AppEntry with prefix-internal, relative, external, and sibling-prefix-trap paths
        let externalSavePath = "/Users/shared/ExternalSaves/slot.sav"
        let siblingPrefixTrap = "\(source.prefixPath)_sibling/drive_c/should_not_rewrite.sav"
        let relativeTargetPath = "drive_c/users/crossover/settings.ini"

        source.apps = [
            AppEntry(
                id: UUID(),
                name: "MyGame",
                executablePath: "\(source.prefixPath)/drive_c/Program Files (x86)/MyGame/game.exe",
                arguments: ["-mod"],
                workingDirectory: "\(source.prefixPath)/drive_c/Program Files (x86)/MyGame",
                snapshotTargets: [
                    SnapshotTarget(
                        id: UUID(),
                        label: "Prefix Saves",
                        path: "\(source.prefixPath)/drive_c/users/crossover/Saves"
                    ),
                    SnapshotTarget(
                        id: UUID(),
                        label: "Relative Settings",
                        path: relativeTargetPath
                    ),
                    SnapshotTarget(
                        id: UUID(),
                        label: "External Saves",
                        path: externalSavePath
                    ),
                    SnapshotTarget(
                        id: UUID(),
                        label: "Sibling Prefix Trap",
                        path: siblingPrefixTrap
                    ),
                ],
                isPinned: true
            ),
        ]
        try store.saveBottle(source)

        // Clone the bottle
        let cloned = try store.cloneBottle(id: source.id, newName: "  Cloned Game  ")

        XCTAssertNotEqual(cloned.id, source.id)
        XCTAssertEqual(cloned.name, "Cloned Game")
        XCTAssertFalse(cloned.isExternalPrefix)
        XCTAssertEqual(cloned.prefixPath, paths.bottlePrefixURL(id: cloned.id).path)
        XCTAssertEqual(cloned.config, source.config)
        XCTAssertEqual(cloned.appliedRecipeID, source.appliedRecipeID)

        // Verify prefix files were copied
        let clonedPrefixURL = URL(fileURLWithPath: cloned.prefixPath, isDirectory: true)
        let clonedExeURL = clonedPrefixURL.appendingPathComponent("drive_c/Program Files (x86)/MyGame/game.exe")
        let clonedSaveURL = clonedPrefixURL.appendingPathComponent("drive_c/users/crossover/Saves/slot1.sav")
        XCTAssertEqual(try Data(contentsOf: clonedExeURL), Data("ORIGINAL-EXE".utf8))
        XCTAssertEqual(try Data(contentsOf: clonedSaveURL), Data("ORIGINAL-SAVE".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clonedPrefixURL.appendingPathComponent("system.reg").path))

        // Verify graphics-state.json and backups were copied
        let clonedGraphicsStateURL = paths.bottleGraphicsStateURL(id: cloned.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clonedGraphicsStateURL.path))
        let clonedGraphicsState = try VermouthJSON.read(GraphicsDeploymentRecord.self, from: clonedGraphicsStateURL)
        XCTAssertEqual(clonedGraphicsState, graphicsState)
        XCTAssertEqual(
            try Data(contentsOf: paths.bottleBackupsDirectory(id: cloned.id).appendingPathComponent("d3d11.dll.orig")),
            Data("BACKUP-DLL".utf8)
        )

        // Verify AppEntry and SnapshotTarget path rewriting
        let clonedApp = try XCTUnwrap(cloned.apps.first)
        XCTAssertEqual(
            clonedApp.executablePath,
            "\(cloned.prefixPath)/drive_c/Program Files (x86)/MyGame/game.exe"
        )
        XCTAssertEqual(
            clonedApp.workingDirectory,
            "\(cloned.prefixPath)/drive_c/Program Files (x86)/MyGame"
        )
        XCTAssertEqual(clonedApp.snapshotTargets.count, 4)
        XCTAssertEqual(
            clonedApp.snapshotTargets[0].path,
            "\(cloned.prefixPath)/drive_c/users/crossover/Saves"
        )
        XCTAssertEqual(clonedApp.snapshotTargets[1].path, relativeTargetPath)
        XCTAssertEqual(clonedApp.snapshotTargets[2].path, externalSavePath)
        XCTAssertEqual(clonedApp.snapshotTargets[3].path, siblingPrefixTrap)

        // Mutating the clone's prefix must leave the original bottle and its files completely untouched
        try Data("CLONE-MODIFIED".utf8).write(to: clonedSaveURL)
        XCTAssertEqual(
            try Data(contentsOf: sourceSavesDir.appendingPathComponent("slot1.sav")),
            Data("ORIGINAL-SAVE".utf8)
        )
        let reloadedSource = try store.loadBottle(id: source.id)
        XCTAssertEqual(reloadedSource.apps.first?.executablePath, source.apps.first?.executablePath)
        XCTAssertEqual(reloadedSource.name, "Source Game")
    }

    func testCloneExternalPrefixBottleProducesManagedClone() throws {
        let externalPrefix = try makeFakeExternalPrefix(named: "external-crossover-prefix")
        let imported = try store.importExistingPrefix(
            name: "Imported External",
            sourcePrefixPath: externalPrefix.path,
            copyFiles: false
        )
        XCTAssertTrue(imported.isExternalPrefix)

        let cloned = try store.cloneBottle(id: imported.id, newName: "Managed Clone")
        XCTAssertFalse(cloned.isExternalPrefix)
        XCTAssertEqual(cloned.prefixPath, paths.bottlePrefixURL(id: cloned.id).path)
        XCTAssertEqual(
            try Data(contentsOf: paths.bottlePrefixURL(id: cloned.id).appendingPathComponent("drive_c/Games/MyGame/important.sav")),
            Data("SAVE-SLOT-CONTENT".utf8)
        )
    }

    // MARK: - Import Existing Prefix

    func testImportExistingPrefixValidation() throws {
        // Non-existent directory
        let missingDir = tempRoot.appendingPathComponent("nonexistent-prefix")
        XCTAssertThrowsError(
            try store.importExistingPrefix(name: "Bad", sourcePrefixPath: missingDir.path, copyFiles: false)
        ) { error in
            guard case VermouthError.invalidPrefixPath = error else {
                XCTFail("Expected VermouthError.invalidPrefixPath, got \(error)")
                return
            }
        }

        // Regular file instead of directory
        let regularFile = tempRoot.appendingPathComponent("not-a-directory.txt")
        try Data("hello".utf8).write(to: regularFile)
        XCTAssertThrowsError(
            try store.importExistingPrefix(name: "BadFile", sourcePrefixPath: regularFile.path, copyFiles: false)
        ) { error in
            guard case VermouthError.invalidPrefixPath = error else {
                XCTFail("Expected VermouthError.invalidPrefixPath, got \(error)")
                return
            }
        }

        // Directory missing drive_c and *.reg files
        let emptyDir = tempRoot.appendingPathComponent("random-empty-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: emptyDir.appendingPathComponent("notes.txt"))
        XCTAssertThrowsError(
            try store.importExistingPrefix(name: "NotAPrefix", sourcePrefixPath: emptyDir.path, copyFiles: false)
        ) { error in
            guard case VermouthError.invalidPrefixPath = error else {
                XCTFail("Expected VermouthError.invalidPrefixPath, got \(error)")
                return
            }
        }

        // Prefix containing only user.reg (no drive_c yet) is still recognized as valid Wine prefix
        let regOnlyDir = tempRoot.appendingPathComponent("reg-only-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: regOnlyDir, withIntermediateDirectories: true)
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: regOnlyDir.appendingPathComponent("user.reg"))
        let imported = try store.importExistingPrefix(
            name: "Reg Only",
            sourcePrefixPath: regOnlyDir.path,
            copyFiles: false
        )
        XCTAssertTrue(imported.isExternalPrefix)
        XCTAssertEqual(imported.prefixPath, regOnlyDir.path)
    }

    func testImportExistingPrefixCopyModeCopiesFilesAndSetsManaged() throws {
        let sourcePrefix = try makeFakeExternalPrefix(named: "source-copy-prefix")

        let imported = try store.importExistingPrefix(
            name: "Copied Bottle",
            sourcePrefixPath: sourcePrefix.path,
            copyFiles: true
        )

        XCTAssertFalse(imported.isExternalPrefix)
        XCTAssertEqual(imported.prefixPath, paths.bottlePrefixURL(id: imported.id).path)

        let copiedSave = paths.bottlePrefixURL(id: imported.id)
            .appendingPathComponent("drive_c/Games/MyGame/important.sav")
        let sourceSave = sourcePrefix.appendingPathComponent("drive_c/Games/MyGame/important.sav")
        XCTAssertEqual(try Data(contentsOf: copiedSave), Data("SAVE-SLOT-CONTENT".utf8))

        // Mutating the managed copy does not affect the external source
        try Data("MODIFIED-IN-MANAGED".utf8).write(to: copiedSave)
        XCTAssertEqual(try Data(contentsOf: sourceSave), Data("SAVE-SLOT-CONTENT".utf8))
    }

    func testImportExistingPrefixReferenceModeSetsExternalAndDoesNotCopy() throws {
        let externalPrefix = try makeFakeExternalPrefix(named: "source-ref-prefix")

        let imported = try store.importExistingPrefix(
            name: "Referenced Bottle",
            sourcePrefixPath: externalPrefix.path,
            copyFiles: false
        )

        XCTAssertTrue(imported.isExternalPrefix)
        XCTAssertEqual(imported.prefixPath, externalPrefix.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottlePrefixURL(id: imported.id).path))
    }

    // MARK: - CRITICAL L-005 Delete Protection Tests

    func testDeleteExternalPrefixBottleNeverDeletesExternalFilesEvenWhenRemovePrefixFilesIsTrue() throws {
        let externalPrefix = try makeFakeExternalPrefix(named: "precious-crossover-prefix")
        let importantSaveURL = externalPrefix.appendingPathComponent("drive_c/Games/MyGame/important.sav")
        let systemRegURL = externalPrefix.appendingPathComponent("system.reg")

        let imported = try store.importExistingPrefix(
            name: "Precious CrossOver Bottle",
            sourcePrefixPath: externalPrefix.path,
            copyFiles: false
        )
        XCTAssertTrue(imported.isExternalPrefix)

        // Add Vermouth metadata files (graphics-state.json & logs) to confirm metadata IS removed
        try VermouthJSON.writeAtomically(
            GraphicsDeploymentRecord(),
            to: paths.bottleGraphicsStateURL(id: imported.id)
        )
        try Data("session log".utf8).write(
            to: paths.bottleLogsDirectory(id: imported.id).appendingPathComponent("launch.log")
        )

        // CRITICAL L-005: removePrefixFiles: true MUST NOT touch external prefix files!
        try store.deleteBottle(id: imported.id, removePrefixFiles: true)

        // Vermouth metadata and listing are gone
        XCTAssertTrue(try store.listBottles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleConfigURL(id: imported.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleDirectory(id: imported.id).path))
        XCTAssertThrowsError(try store.loadBottle(id: imported.id)) { error in
            guard case VermouthError.bottleNotFound = error else {
                XCTFail("Expected VermouthError.bottleNotFound, got \(error)")
                return
            }
        }

        // External prefix files MUST remain 100% intact
        XCTAssertTrue(directoryExists(at: externalPrefix))
        XCTAssertEqual(try Data(contentsOf: importantSaveURL), Data("SAVE-SLOT-CONTENT".utf8))
        XCTAssertEqual(try Data(contentsOf: systemRegURL), Data("WINE REGISTRY Version 2\n".utf8))
    }

    func testDeleteExternalPrefixInsideBottleDirStillPreservesPrefix() throws {
        // Defense-in-depth edge case: even if isExternalPrefix == true and prefixPath is inside bottleDir,
        // L-005 protection must remove only metadata and preserve prefixPath.
        var bottle = try store.createBottle(name: "Nested External Guard")
        let sentinelURL = paths.bottlePrefixURL(id: bottle.id).appendingPathComponent("sentinel.dat")
        try Data("KEEP-ME".utf8).write(to: sentinelURL)
        bottle.isExternalPrefix = true
        try store.saveBottle(bottle)

        try store.deleteBottle(id: bottle.id, removePrefixFiles: true)

        XCTAssertTrue(try store.listBottles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleConfigURL(id: bottle.id).path))
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("KEEP-ME".utf8))
    }

    func testDeleteManagedBottleWithKeepPrefixRemovesMetadataOnly() throws {
        let bottle = try store.createBottle(name: "Managed Keep Prefix")
        let prefixURL = paths.bottlePrefixURL(id: bottle.id)
        let saveURL = prefixURL.appendingPathComponent("drive_c/save.dat")
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("KEEP-MANAGED-SAVE".utf8).write(to: saveURL)

        try VermouthJSON.writeAtomically(
            GraphicsDeploymentRecord(),
            to: paths.bottleGraphicsStateURL(id: bottle.id)
        )
        try Data("log data".utf8).write(
            to: paths.bottleLogsDirectory(id: bottle.id).appendingPathComponent("run.log")
        )

        // Delete with removePrefixFiles: false
        try store.deleteBottle(id: bottle.id, removePrefixFiles: false)

        // bottle.json and other metadata must be removed and bottle must no longer be listed
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleConfigURL(id: bottle.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleGraphicsStateURL(id: bottle.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleLogsDirectory(id: bottle.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleSnapshotsDirectory(id: bottle.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleBackupsDirectory(id: bottle.id).path))
        XCTAssertTrue(try store.listBottles().isEmpty)
        XCTAssertThrowsError(try store.loadBottle(id: bottle.id)) { error in
            guard case VermouthError.bottleNotFound = error else {
                XCTFail("Expected VermouthError.bottleNotFound, got \(error)")
                return
            }
        }

        // Managed prefix/ and its files must stay 100% intact
        XCTAssertTrue(directoryExists(at: prefixURL))
        XCTAssertEqual(try Data(contentsOf: saveURL), Data("KEEP-MANAGED-SAVE".utf8))
    }

    func testDeleteManagedBottleWithRemovePrefixFilesRemovesEntireDirectory() throws {
        let bottle = try store.createBottle(name: "Managed Full Delete")
        let saveURL = paths.bottlePrefixURL(id: bottle.id).appendingPathComponent("drive_c/save.dat")
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("DELETE-ME".utf8).write(to: saveURL)

        try store.deleteBottle(id: bottle.id, removePrefixFiles: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleDirectory(id: bottle.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottlePrefixURL(id: bottle.id).path))
        XCTAssertTrue(try store.listBottles().isEmpty)

        // Deleting an already-deleted/unknown bottle throws bottleNotFound
        XCTAssertThrowsError(try store.deleteBottle(id: bottle.id, removePrefixFiles: true)) { error in
            guard case VermouthError.bottleNotFound = error else {
                XCTFail("Expected VermouthError.bottleNotFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Swift 6 Concurrency Safety

    func testConcurrentCreateAndListBottlesIsThreadSafe() async throws {
        let localStore = try XCTUnwrap(store)
        let count = 12

        let createdIDs: Set<UUID> = try await withThrowingTaskGroup(of: UUID.self) { group in
            for idx in 0..<count {
                group.addTask {
                    let created = try localStore.createBottle(name: "Concurrent Bottle \(idx)")
                    _ = try localStore.listBottles()
                    return created.id
                }
            }
            var ids: Set<UUID> = []
            for try await id in group {
                ids.insert(id)
            }
            return ids
        }

        XCTAssertEqual(createdIDs.count, count)
        let allBottles = try localStore.listBottles()
        XCTAssertEqual(Set(allBottles.map(\.id)), createdIDs)
    }
}
