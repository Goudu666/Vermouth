import Foundation
import XCTest
@testable import VermouthCore

final class DiscoveryDiagnosticsSnapshotRecipeTests: XCTestCase {
    private var tempRoot: URL!
    private var paths: VermouthPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try createTempDirectory(prefix: "vermouth-round3-test")
        paths = VermouthPaths(baseDirectory: tempRoot.appendingPathComponent("vermouth-home", isDirectory: true))
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempRoot)
        paths = nil
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Section 1: ExecutableScanner

    func testExecutableScannerShortcutPrecedencePE32DetectionAndNoiseFiltering() throws {
        let prefixURL = tempRoot.appendingPathComponent("scan-prefix", isDirectory: true).standardizedFileURL
        let driveCURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)

        // Create Program Files (x86)/MyGame with PE32 game.exe + noise binaries
        let gameDir = driveCURL.appendingPathComponent("Program Files (x86)/MyGame", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let gameExe = gameDir.appendingPathComponent("game.exe", isDirectory: false)
        try makeMinimalPE(machine: 0x014C, optionalMagic: 0x010B).write(to: gameExe)
        try makeMinimalPE(machine: 0x014C, optionalMagic: 0x010B)
            .write(to: gameDir.appendingPathComponent("unins000.exe", isDirectory: false))
        try makeMinimalPE(machine: 0x8664, optionalMagic: 0x020B)
            .write(to: gameDir.appendingPathComponent("vc_redist.x64.exe", isDirectory: false))
        try makeMinimalPE(machine: 0x8664, optionalMagic: 0x020B)
            .write(to: gameDir.appendingPathComponent("CrashReporter.exe", isDirectory: false))

        // Create Program Files/ToolApp with PE32+ (64-bit) tool64.exe (discovered via Pass 2)
        let toolDir = driveCURL.appendingPathComponent("Program Files/ToolApp", isDirectory: true)
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        let toolExe = toolDir.appendingPathComponent("tool64.exe", isDirectory: false)
        try makeMinimalPE(machine: 0x8664, optionalMagic: 0x020B).write(to: toolExe)

        // Create Windows system binary drive_c/windows/notepad.exe (must always be excluded)
        let windowsDir = driveCURL.appendingPathComponent("windows", isDirectory: true)
        try FileManager.default.createDirectory(at: windowsDir, withIntermediateDirectories: true)
        try makeMinimalPE(machine: 0x8664, optionalMagic: 0x020B)
            .write(to: windowsDir.appendingPathComponent("notepad.exe", isDirectory: false))

        // Create Start Menu .lnk pointing to game.exe (highest priority) + Uninstall .lnk + Notepad .lnk
        let startMenuPrograms = driveCURL.appendingPathComponent(
            "ProgramData/Microsoft/Windows/Start Menu/Programs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: startMenuPrograms, withIntermediateDirectories: true)
        try makeMinimalLnk(
            targetPath: #"C:\Program Files (x86)\MyGame\game.exe"#,
            workingDir: #"C:\Program Files (x86)\MyGame"#,
            arguments: #"-windowed "My Profile""#
        ).write(to: startMenuPrograms.appendingPathComponent("My Game Launcher.lnk"))
        try makeMinimalLnk(
            targetPath: #"C:\Program Files (x86)\MyGame\game.exe"#
        ).write(to: startMenuPrograms.appendingPathComponent("Uninstall MyGame.lnk"))
        try makeMinimalLnk(
            targetPath: #"C:\windows\notepad.exe"#
        ).write(to: startMenuPrograms.appendingPathComponent("Notepad.lnk"))

        // Create Desktop .lnk pointing to the same game.exe (lower priority than Start Menu)
        let publicDesktop = driveCURL.appendingPathComponent("users/Public/Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDesktop, withIntermediateDirectories: true)
        try makeMinimalLnk(
            targetPath: #"C:\Program Files (x86)\MyGame\game.exe"#,
            arguments: "-desktop-fallback"
        ).write(to: publicDesktop.appendingPathComponent("Desktop Duplicate.lnk"))

        let scanner = ExecutableScanner()
        let discovered = try scanner.scan(prefixPath: prefixURL.path)

        XCTAssertEqual(discovered.count, 2, "Should find only My Game Launcher (via .lnk) and tool64 (via scan)")
        XCTAssertEqual(discovered.map(\.name), ["My Game Launcher", "tool64"])

        let gameEntry = try XCTUnwrap(discovered.first { $0.name == "My Game Launcher" })
        XCTAssertEqual(gameEntry.source, .startMenuShortcut)
        XCTAssertEqual(gameEntry.architecture, .x86_32)
        XCTAssertEqual(gameEntry.executablePath, gameExe.path)
        XCTAssertEqual(gameEntry.workingDirectory, gameDir.path)
        XCTAssertEqual(gameEntry.arguments, ["-windowed", "My Profile"])

        let toolEntry = try XCTUnwrap(discovered.first { $0.name == "tool64" })
        XCTAssertEqual(toolEntry.source, .programFilesScan)
        XCTAssertEqual(toolEntry.architecture, .x86_64)
        XCTAssertEqual(toolEntry.executablePath, toolExe.path)
    }

    func testExecutableScannerRejectsMissingPrefixAndHandlesEmptyPrefix() throws {
        let scanner = ExecutableScanner()

        let missingPath = tempRoot.appendingPathComponent("no-such-prefix").path
        XCTAssertThrowsError(try scanner.scan(prefixPath: missingPath)) { error in
            guard case VermouthError.invalidPrefixPath = error else {
                XCTFail("Expected VermouthError.invalidPrefixPath, got \(error)")
                return
            }
        }

        let emptyPrefix = tempRoot.appendingPathComponent("empty-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPrefix, withIntermediateDirectories: true)
        XCTAssertEqual(try scanner.scan(prefixPath: emptyPrefix.path), [])
    }

    // MARK: - Section 2: CrashDiagnoser

    func testCrashDiagnoserCoversAllSevenRulesAndQuickFixes() throws {
        let diagnoser = CrashDiagnoser()

        // Rule 1: Missing DLL -> runtime hint (vcruntime140.dll -> vcrun2022, d3dx9_43.dll -> d3dx9)
        let vcFindings = diagnoser.diagnoseLine(
            #"0024:err:module:import_dll Library vcruntime140.dll (which is needed by L"C:\game.exe") not found"#
        )
        let vcFinding = try XCTUnwrap(vcFindings.first)
        XCTAssertEqual(vcFinding.category, .missingDLL)
        XCTAssertEqual(vcFinding.missingDLLName, "vcruntime140.dll")
        XCTAssertEqual(vcFinding.recommendedRuntime, "vcrun2022")
        XCTAssertEqual(
            vcFinding.quickFix,
            .copyCommand(label: "复制 winetricks 安装命令 (vcrun2022)", command: "winetricks -q vcrun2022")
        )

        let dx9Finding = try XCTUnwrap(
            diagnoser.diagnoseLine("err:module:import_dll Library d3dx9_43.dll not found").first
        )
        XCTAssertEqual(dx9Finding.recommendedRuntime, "d3dx9 / directx9")

        // Rule 2: Quarantine blocked (narrow file -> non-recursive, .app -> recursive, broad ~/Downloads -> nil quickFix)
        let fileQuarantine = try XCTUnwrap(
            diagnoser.diagnoseLine("dyld: Library Validation failed for '/Users/alice/Games/mod.dll' (com.apple.quarantine)").first
        )
        XCTAssertEqual(fileQuarantine.category, .quarantineBlocked)
        XCTAssertEqual(fileQuarantine.quickFix, .removeQuarantine(path: "/Users/alice/Games/mod.dll", recursive: false))

        let appQuarantine = try XCTUnwrap(
            diagnoser.diagnoseLine("com.apple.quarantine blocked /Applications/Wine Stable.app/Contents/MacOS/wine").first
        )
        XCTAssertEqual(appQuarantine.quickFix, .removeQuarantine(path: "/Applications/Wine Stable.app", recursive: true))

        let broadQuarantine = try XCTUnwrap(
            diagnoser.diagnoseLine("com.apple.quarantine on /Users/alice/Downloads").first
        )
        XCTAssertEqual(broadQuarantine.category, .quarantineBlocked)
        XCTAssertNil(broadQuarantine.quickFix, "L-006: broad ~/Downloads path must not offer recursive removeQuarantine")

        // Rule 3: Architecture mismatch (32-bit Bad EXE format)
        let archFinding = try XCTUnwrap(
            diagnoser.diagnoseLine(#"0024:err:process:exec_process Bad EXE format for C:\Games\gta_sa.exe."#).first
        )
        XCTAssertEqual(archFinding.category, .architectureMismatch)
        XCTAssertEqual(archFinding.quickFix, .select32BitCapableEngine)

        // Rule 4: DXMT / Vulkan graphics initialization failure -> switch to WineD3D
        let dxmtFinding = try XCTUnwrap(
            diagnoser.diagnoseLine("dxmt: fatal error creating Metal device").first
        )
        XCTAssertEqual(dxmtFinding.category, .graphicsInitFailed)
        XCTAssertEqual(dxmtFinding.quickFix, .switchGraphicsBackend(.wined3d))

        let vkFinding = try XCTUnwrap(
            diagnoser.diagnoseLine("err:vulkan:vkCreateInstance failed with -9").first
        )
        XCTAssertEqual(vkFinding.category, .graphicsInitFailed)
        XCTAssertEqual(vkFinding.quickFix, .switchGraphicsBackend(.wined3d))

        // Rule 5: MSync / ESync wineserver mismatch -> killWineServer
        let syncFinding = try XCTUnwrap(
            diagnoser.diagnoseLine("msync_init: failed due to wineserver protocol version mismatch").first
        )
        XCTAssertEqual(syncFinding.category, .syncMismatch)
        XCTAssertEqual(syncFinding.quickFix, .killWineServer)

        // Rule 6: Rosetta 2 missing -> install-rosetta command (and must NOT double-classify as architectureMismatch)
        let rosettaFindings = diagnoser.diagnoseLine(
            "arch: posix_spawnp: /Applications/Wine Stable.app/Contents/Resources/wine/bin/wine: Bad CPU type in executable"
        )
        XCTAssertEqual(rosettaFindings.count, 1)
        XCTAssertEqual(rosettaFindings[0].category, .rosettaMissing)
        XCTAssertEqual(
            rosettaFindings[0].quickFix,
            .copyCommand(label: "安装 Rosetta 2", command: "softwareupdate --install-rosetta --agree-to-license")
        )

        // Rule 7: Font / locale warning -> enableChineseLocalization
        let fontFinding = try XCTUnwrap(
            diagnoser.diagnoseLine("0030:err:font:freetype_load_font cannot find font SimSun").first
        )
        XCTAssertEqual(fontFinding.category, .fontOrLocale)
        XCTAssertEqual(fontFinding.severity, .warning)
        XCTAssertEqual(fontFinding.quickFix, .enableChineseLocalization)
    }

    func testCrashDiagnoserDeduplicatesRepeatedLinesAndPreflightWarnings() {
        let diagnoser = CrashDiagnoser()
        let preflightSync = DiagnosticFinding(
            id: "sync-mismatch",
            category: .syncMismatch,
            severity: .warning,
            title: "Preflight Sync Notice",
            explanation: "Existing wineserver detected",
            suggestion: "Kill wineserver",
            quickFix: .killWineServer
        )

        let logs = [
            "err:module:import_dll Library vcruntime140.dll not found\nerr:module:import_dll Library VCRUNTIME140.DLL not found",
            "msync_init: failed",
            "msync_init: protocol version mismatch",
            "err:font:cannot find font SimSun",
            "err:font:cannot find font Microsoft YaHei",
        ]

        let findings = diagnoser.diagnose(logs: logs, preflightWarnings: [preflightSync])
        XCTAssertEqual(findings.map(\.id), ["sync-mismatch", "missing-dll-vcruntime140.dll", "font-or-locale"])
        XCTAssertEqual(findings[0].title, "Preflight Sync Notice", "Preflight finding should retain precedence on duplicate ID")
    }

    // MARK: - Section 3: SnapshotManager

    func testSnapshotManagerDirectoryCreateModifyAndAtomicRollbackWithSafetyBackup() throws {
        let store = BottleStore(paths: paths)
        let bottle = try store.createBottle(name: "Snapshot Dir Bottle")
        let manager = SnapshotManager(paths: paths, commandRunner: MockCommandRunner())

        let savesDir = paths.bottlePrefixURL(id: bottle.id).appendingPathComponent("drive_c/Saves", isDirectory: true)
        let cfgDir = savesDir.appendingPathComponent("cfg", isDirectory: true)
        let emptyDir = savesDir.appendingPathComponent("empty_subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let slot1 = savesDir.appendingPathComponent("slot1.sav")
        let videoIni = cfgDir.appendingPathComponent("video.ini")
        try Data("ORIGINAL-SLOT-1".utf8).write(to: slot1)
        try Data("width=1920\n".utf8).write(to: videoIni)

        let target = SnapshotTarget(label: "Clean Vanilla Saves", path: "drive_c/Saves")
        let snap = try manager.createSnapshot(bottleID: bottle.id, target: target, note: "Before mod install")

        XCTAssertTrue(snap.isDirectory)
        XCTAssertEqual(snap.fileCount, 2)
        XCTAssertEqual(snap.totalBytes, UInt64("ORIGINAL-SLOT-1".utf8.count + "width=1920\n".utf8.count))
        XCTAssertEqual(snap.sha256, try PureSHA256.hashFile(at: URL(fileURLWithPath: snap.archivePath)))
        XCTAssertEqual(try manager.listSnapshots(bottleID: bottle.id, targetID: target.id), [snap])

        // Mutate directory: overwrite slot1, remove video.ini, add extra mod file
        try Data("MODDED-BROKEN-SAVE".utf8).write(to: slot1)
        try FileManager.default.removeItem(at: videoIni)
        let extraModFile = savesDir.appendingPathComponent("broken_mod.asi")
        try Data("BAD-MOD".utf8).write(to: extraModFile)

        // Rollback atomically and receive automatic pre-rollback safety backup
        let safetyBackup = try manager.rollback(bottleID: bottle.id, snapshotID: snap.id)

        XCTAssertNotEqual(safetyBackup.id, snap.id)
        XCTAssertEqual(safetyBackup.targetID, snap.targetID)
        XCTAssertEqual(safetyBackup.fileCount, 2)
        XCTAssertEqual(try manager.listSnapshots(bottleID: bottle.id, targetID: target.id).count, 2)

        // Original directory contents must be restored completely
        XCTAssertEqual(try Data(contentsOf: slot1), Data("ORIGINAL-SLOT-1".utf8))
        XCTAssertEqual(try Data(contentsOf: videoIni), Data("width=1920\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraModFile.path))
        var isEmptySubdirDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: emptyDir.path, isDirectory: &isEmptySubdirDir)
                && isEmptySubdirDir.boolValue
        )

        // Ensure no stray rollback staging directories remain in parent directory
        let parentEntries = try FileManager.default.contentsOfDirectory(
            atPath: savesDir.deletingLastPathComponent().path
        )
        XCTAssertFalse(parentEntries.contains(where: { $0.contains("rollback-staging") }))

        // Rolling forward to the safety backup restores the pre-rollback state
        _ = try manager.rollback(bottleID: bottle.id, snapshotID: safetyBackup.id)
        XCTAssertEqual(try Data(contentsOf: slot1), Data("MODDED-BROKEN-SAVE".utf8))
        XCTAssertEqual(try Data(contentsOf: extraModFile), Data("BAD-MOD".utf8))
    }

    func testSnapshotManagerSingleFileCreateRollbackAndDelete() throws {
        let store = BottleStore(paths: paths)
        let bottle = try store.createBottle(name: "Snapshot File Bottle")
        let manager = SnapshotManager(paths: paths, commandRunner: MockCommandRunner())

        let iniURL = paths.bottlePrefixURL(id: bottle.id).appendingPathComponent("drive_c/settings.ini")
        try FileManager.default.createDirectory(at: iniURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fps_limit=60\n".utf8).write(to: iniURL)

        let target = SnapshotTarget(label: "settings.ini", path: iniURL.path)
        let snap = try manager.createSnapshot(bottleID: bottle.id, target: target)
        XCTAssertFalse(snap.isDirectory)
        XCTAssertEqual(snap.fileCount, 1)
        XCTAssertEqual(snap.totalBytes, UInt64("fps_limit=60\n".utf8.count))

        try Data("fps_limit=999\n".utf8).write(to: iniURL)
        let safetyBackup = try manager.rollback(bottleID: bottle.id, snapshotID: snap.id)
        XCTAssertEqual(try Data(contentsOf: iniURL), Data("fps_limit=60\n".utf8))
        XCTAssertEqual(safetyBackup.fileCount, 1)

        // Delete removes archive file and index entry
        try manager.deleteSnapshot(bottleID: bottle.id, snapshotID: snap.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snap.archivePath))
        XCTAssertEqual(try manager.listSnapshots(bottleID: bottle.id).map(\.id), [safetyBackup.id])
    }

    func testSnapshotManagerRollbackWhenDestinationDeletedBeforehand() throws {
        let store = BottleStore(paths: paths)
        let bottle = try store.createBottle(name: "Deleted Destination Bottle")
        let manager = SnapshotManager(paths: paths, commandRunner: MockCommandRunner())

        let savesDir = paths.bottlePrefixURL(id: bottle.id).appendingPathComponent("drive_c/Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
        let slotFile = savesDir.appendingPathComponent("save.dat")
        try Data("RECOVER-ME".utf8).write(to: slotFile)

        let target = SnapshotTarget(label: "Saves", path: savesDir.path)
        let snap = try manager.createSnapshot(bottleID: bottle.id, target: target)

        // Delete destination directory completely before rollback
        try FileManager.default.removeItem(at: savesDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savesDir.path))

        let safetyBackup = try manager.rollback(bottleID: bottle.id, snapshotID: snap.id)
        XCTAssertEqual(try Data(contentsOf: slotFile), Data("RECOVER-ME".utf8))
        XCTAssertEqual(safetyBackup.fileCount, 0)
        XCTAssertEqual(safetyBackup.totalBytes, 0)
    }

    func testSnapshotManagerDetectsSHA256CorruptionAndLeavesDestinationUntouched() throws {
        let store = BottleStore(paths: paths)
        let bottle = try store.createBottle(name: "Integrity Bottle")
        let manager = SnapshotManager(paths: paths, commandRunner: MockCommandRunner())

        let savesDir = paths.bottlePrefixURL(id: bottle.id).appendingPathComponent("drive_c/Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
        let slotFile = savesDir.appendingPathComponent("slot1.sav")
        try Data("V1-SAVE".utf8).write(to: slotFile)

        let snap = try manager.createSnapshot(
            bottleID: bottle.id,
            target: SnapshotTarget(label: "Saves", path: savesDir.path)
        )

        // Advance live save to precious state
        try Data("CURRENT-PRECIOUS-SAVE".utf8).write(to: slotFile)

        // Corrupt a byte in the stored `.vsnap` archive
        let archiveURL = URL(fileURLWithPath: snap.archivePath)
        var corrupted = try Data(contentsOf: archiveURL)
        corrupted[corrupted.count - 1] ^= 0xFF
        try corrupted.write(to: archiveURL)

        XCTAssertThrowsError(try manager.rollback(bottleID: bottle.id, snapshotID: snap.id)) { error in
            guard case VermouthError.snapshotIntegrityCheckFailed(let id, let expected, let actual) = error else {
                XCTFail("Expected VermouthError.snapshotIntegrityCheckFailed, got \(error)")
                return
            }
            XCTAssertEqual(id, snap.id)
            XCTAssertEqual(expected, snap.sha256)
            XCTAssertNotEqual(actual, expected)
        }

        // Destination must remain 100% untouched and no extra safety backup created
        XCTAssertEqual(try Data(contentsOf: slotFile), Data("CURRENT-PRECIOUS-SAVE".utf8))
        XCTAssertEqual(try manager.listSnapshots(bottleID: bottle.id).count, 1)
    }

    func testSnapshotManagerRejectsUnsafePathTraversalArchiveEntry() throws {
        let store = BottleStore(paths: paths)
        let bottle = try store.createBottle(name: "Traversal Guard Bottle")
        let manager = SnapshotManager(paths: paths, commandRunner: MockCommandRunner())

        let savesDir = paths.bottlePrefixURL(id: bottle.id).appendingPathComponent("drive_c/Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
        let slotFile = savesDir.appendingPathComponent("safe.sav")
        try Data("DO-NOT-TOUCH".utf8).write(to: slotFile)

        // Craft a VSNP v1 archive with valid SHA-256 containing a "../escape.txt" traversal entry (L-011)
        let maliciousID = UUID()
        let snapshotsDir = paths.bottleSnapshotsDirectory(id: bottle.id)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let maliciousArchiveURL = snapshotsDir.appendingPathComponent("\(maliciousID.uuidString).vsnap")

        let manifestJSON = Data("""
        {
          "entries": [
            {
              "byteLength": 4,
              "byteOffset": 0,
              "kind": "file",
              "posixPermissions": 420,
              "relativePath": "../escape.txt"
            }
          ],
          "formatVersion": 1,
          "isDirectory": true,
          "rootName": "Saves"
        }
        """.utf8)
        let payload = Data("EVIL".utf8)
        var rawArchive = Data([0x56, 0x53, 0x4E, 0x50]) // "VSNP"
        appendUInt32LE(1, to: &rawArchive)
        appendUInt32LE(UInt32(manifestJSON.count), to: &rawArchive)
        rawArchive.append(manifestJSON)
        rawArchive.append(payload)
        try rawArchive.write(to: maliciousArchiveURL)

        let record = SnapshotRecord(
            id: maliciousID,
            targetID: UUID(),
            label: "Malicious",
            sourcePath: savesDir.path,
            isDirectory: true,
            archivePath: maliciousArchiveURL.path,
            fileCount: 1,
            totalBytes: 4,
            sha256: try PureSHA256.hashFile(at: maliciousArchiveURL)
        )
        try VermouthJSON.writeAtomically(
            SnapshotIndexFile(records: [record]),
            to: paths.bottleSnapshotsIndexURL(id: bottle.id)
        )

        XCTAssertThrowsError(try manager.rollback(bottleID: bottle.id, snapshotID: maliciousID)) { error in
            guard case VermouthError.snapshotUnsafeArchiveEntry(let entryPath) = error else {
                XCTFail("Expected VermouthError.snapshotUnsafeArchiveEntry, got \(error)")
                return
            }
            XCTAssertEqual(entryPath, "../escape.txt")
        }

        XCTAssertEqual(try Data(contentsOf: slotFile), Data("DO-NOT-TOUCH".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: savesDir.deletingLastPathComponent().appendingPathComponent("escape.txt").path
            )
        )
    }

    // MARK: - Section 4: RecipeEngine

    func testRecipeEngineListsBuiltInsAndImportsCommunityRecipeFile() throws {
        let engine = RecipeEngine(paths: paths)

        let builtIns = try engine.listRecipes()
        let builtInIDs = Set(builtIns.map(\.id))
        XCTAssertTrue(builtInIDs.contains("gtasa-pc-1.0"))
        XCTAssertTrue(builtInIDs.contains("dx11-modern-default"))

        let gtasa = try engine.loadRecipe(from: "gtasa-pc-1.0")
        XCTAssertEqual(gtasa.targetArchitecture, .x86_32)
        XCTAssertEqual(gtasa.recommendedBackend, .wined3d)

        // Import a valid community recipe file
        let customRecipe = Recipe(
            id: "community-rpg-dx11",
            name: "Community RPG DX11",
            summary: "64-bit DX11 community preset",
            targetArchitecture: .x86_64,
            recommendedWindowsVersion: .win10,
            recommendedBackend: .dxmt,
            recommendedSyncMode: .msync,
            chineseLocalizationSuggested: true,
            dllOverrides: [DllOverride(dllName: "winhttp", mode: .nativeThenBuiltin, enabled: true)]
        )
        let importSourceURL = tempRoot.appendingPathComponent("community-rpg.recipe.json")
        try VermouthJSON.writeAtomically(customRecipe, to: importSourceURL)

        let imported = try engine.importRecipeFile(at: importSourceURL.path)
        XCTAssertEqual(imported, customRecipe)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.recipesDirectory.appendingPathComponent("community-rpg-dx11.recipe.json").path
            )
        )
        XCTAssertEqual(try engine.loadRecipe(from: "community-rpg-dx11"), customRecipe)
        XCTAssertTrue(try engine.listRecipes().contains(where: { $0.id == "community-rpg-dx11" }))

        // Invalid JSON fails with VermouthError.invalidRecipe
        let badRecipeURL = tempRoot.appendingPathComponent("corrupt.recipe.json")
        try Data("{ invalid".utf8).write(to: badRecipeURL)
        XCTAssertThrowsError(try engine.importRecipeFile(at: badRecipeURL.path)) { error in
            guard case VermouthError.invalidRecipe = error else {
                XCTFail("Expected VermouthError.invalidRecipe, got \(error)")
                return
            }
        }
    }

    func testRecipeEnginePlanApplicationEmits32BitAndDXMTCapabilityWarnings() throws {
        let recipeEngine = RecipeEngine(paths: paths)
        let gtasa = try recipeEngine.loadRecipe(from: "gtasa-pc-1.0")
        let dx11 = try recipeEngine.loadRecipe(from: "dx11-modern-default")

        let bottle = Bottle(
            name: "Plan Target",
            prefixPath: tempRoot.appendingPathComponent("plan-prefix").path,
            config: BottleConfig(
                windowsVersion: .win10,
                syncMode: .esync,
                graphicsBackend: .dxmt,
                graphicsLayerVersionID: "dxmt-v0.80",
                locale: LocaleConfig(chineseLocalizationEnabled: false),
                dllOverrides: [DllOverride(dllName: "version", mode: .nativeThenBuiltin, enabled: true)]
            )
        )

        // 1. 64-bit-only, no-MSync, no-WINEDLLPATH_PREPEND engine triggers warnings on gtasa & dx11
        let limitedEngine = WineEngine(
            id: "limited-wine",
            name: "Limited 64-bit Wine",
            rootPath: "/tmp/limited-wine",
            wineBinaryPath: "/tmp/limited-wine/bin/wine64",
            wineserverPath: "/tmp/limited-wine/bin/wineserver",
            version: "wine-8.0",
            source: .custom,
            capabilities: EngineCapabilities(
                supports32Bit: false,
                supports64Bit: true,
                isNewWoW64: false,
                supportsMSync: false,
                supportsWineDLLPathPrepend: false
            )
        )

        let gtasaPlan = recipeEngine.planApplication(of: gtasa, to: bottle, engine: limitedEngine)
        XCTAssertTrue(gtasaPlan.requiresGraphicsBackendChange)
        XCTAssertTrue(gtasaPlan.requiresRegistrySync)
        XCTAssertTrue(gtasaPlan.requiresWineServerRestart)
        XCTAssertEqual(gtasaPlan.updatedBottle.appliedRecipeID, "gtasa-pc-1.0")
        XCTAssertEqual(gtasaPlan.updatedBottle.config.windowsVersion, .win7)
        XCTAssertEqual(gtasaPlan.updatedBottle.config.graphicsBackend, .wined3d)
        XCTAssertNil(gtasaPlan.updatedBottle.config.graphicsLayerVersionID)
        XCTAssertEqual(gtasaPlan.updatedBottle.config.syncMode, .msync)
        XCTAssertTrue(gtasaPlan.updatedBottle.config.locale.chineseLocalizationEnabled)
        XCTAssertEqual(
            Set(gtasaPlan.updatedBottle.config.dllOverrides.map(\.dllName)),
            Set(["version", "dinput8", "vorbisfile"])
        )

        let archWarning = try XCTUnwrap(gtasaPlan.warnings.first { $0.category == .architectureMismatch })
        XCTAssertEqual(archWarning.quickFix, .select32BitCapableEngine)
        XCTAssertTrue(gtasaPlan.warnings.contains { $0.category == .syncMismatch })

        // 2. DX11 DXMT recipe on engine lacking WINEDLLPATH_PREPEND warns per L-001
        let dx11Plan = recipeEngine.planApplication(of: dx11, to: bottle, engine: limitedEngine)
        let dxmtWarning = try XCTUnwrap(dx11Plan.warnings.first { $0.category == .graphicsInitFailed })
        XCTAssertEqual(dxmtWarning.id, "recipe-dxmt-unsupported-dx11-modern-default")
        XCTAssertEqual(dxmtWarning.quickFix, .switchGraphicsBackend(.dxvk))

        // 3. Full-capability WoW64 engine produces zero warnings for both built-in recipes
        let capableEngine = WineEngine(
            id: "wow64-wine",
            name: "Wine Stable 11.0 (WoW64)",
            rootPath: "/tmp/wow64-wine",
            wineBinaryPath: "/tmp/wow64-wine/bin/wine",
            wineserverPath: "/tmp/wow64-wine/bin/wineserver",
            version: "wine-11.0",
            source: .homebrewCask,
            capabilities: EngineCapabilities(
                supports32Bit: true,
                supports64Bit: true,
                isNewWoW64: true,
                supportsMSync: true,
                supportsWineDLLPathPrepend: true
            )
        )
        XCTAssertTrue(recipeEngine.planApplication(of: gtasa, to: bottle, engine: capableEngine).warnings.isEmpty)
        XCTAssertTrue(recipeEngine.planApplication(of: dx11, to: bottle, engine: capableEngine).warnings.isEmpty)
    }

    func testRecipeEngineExportSanitizedRecipeStripsUserPathsAndSensitiveEnvKeys() throws {
        let recipeEngine = RecipeEngine(paths: paths)
        let prefixURL = tempRoot.appendingPathComponent("export-prefix", isDirectory: true).standardizedFileURL
        let gameExe = prefixURL.appendingPathComponent("drive_c/Games/classic32.exe", isDirectory: false)
        try FileManager.default.createDirectory(at: gameExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalPE(machine: 0x014C, optionalMagic: 0x010B).write(to: gameExe)

        let bottle = Bottle(
            name: "Private Bottle",
            prefixPath: prefixURL.path,
            config: BottleConfig(
                windowsVersion: .win7,
                syncMode: .msync,
                graphicsBackend: .wined3d,
                locale: LocaleConfig(chineseLocalizationEnabled: true),
                dllOverrides: [DllOverride(dllName: "dinput8", mode: .nativeThenBuiltin, enabled: true)],
                environmentVariables: [
                    // Safe portable tuning flags (must be preserved)
                    "DXMT_ENABLE_NVEXT": "0",
                    "CUSTOM_SCALE": "2",
                    // Blocked host/runtime keys (must be stripped)
                    "HOME": "/Users/alice",
                    "WINEPREFIX": prefixURL.path,
                    "WINEDLLPATH_PREPEND": "/opt/dxmt",
                    "VERMOUTH_HOME": "/Users/alice/Vermouth",
                    // Sensitive credential substrings (must be stripped)
                    "GITHUB_TOKEN": "ghp_secret123",
                    "STEAM_PASSWORD": "hunter2",
                    "MY_API_KEY": "sk-1234",
                    "AUTH_COOKIE": "session=xyz",
                    // Host/prefix path leaks in values (must be stripped)
                    "LEAKED_MAC_PATH": "/Users/alice/Documents/save.dat",
                    "LEAKED_VOLUME_PATH": "/Volumes/ExternalSSD/Games",
                    "LEAKED_WIN_USER": #"C:\Users\Alice\AppData"#,
                    "LEAKED_PREFIX_PATH": "\(prefixURL.path)/drive_c/mods",
                ],
                wineDebugChannels: "-all,err+all"
            ),
            apps: [AppEntry(name: "Classic32", executablePath: gameExe.path)]
        )

        let exported = recipeEngine.exportSanitizedRecipe(
            from: bottle,
            id: "sanitized-classic",
            name: "Sanitized Classic",
            summary: "Safe shareable recipe"
        )

        XCTAssertEqual(exported.id, "sanitized-classic")
        XCTAssertEqual(exported.name, "Sanitized Classic")
        XCTAssertEqual(exported.targetArchitecture, .x86_32)
        XCTAssertEqual(exported.recommendedWindowsVersion, .win7)
        XCTAssertEqual(exported.recommendedBackend, .wined3d)
        XCTAssertEqual(exported.recommendedSyncMode, .msync)
        XCTAssertTrue(exported.chineseLocalizationSuggested)
        XCTAssertEqual(exported.dllOverrides.map(\.dllName), ["dinput8"])
        XCTAssertEqual(
            exported.environmentVariables,
            [
                "DXMT_ENABLE_NVEXT": "0",
                "CUSTOM_SCALE": "2",
            ]
        )
    }

    // MARK: - Compact Binary Fixture Helpers

    private func makeMinimalPE(machine: UInt16, optionalMagic: UInt16) -> Data {
        let peOffset = 0x80
        let optSize: UInt16 = 96
        var bytes = [UInt8](repeating: 0, count: peOffset + 24 + Int(optSize))
        bytes[0] = 0x4D // 'M'
        bytes[1] = 0x5A // 'Z'
        writeUInt32LE(UInt32(peOffset), into: &bytes, at: 0x3C)
        bytes[peOffset] = 0x50     // 'P'
        bytes[peOffset + 1] = 0x45 // 'E'
        writeUInt16LE(machine, into: &bytes, at: peOffset + 4)
        writeUInt16LE(optSize, into: &bytes, at: peOffset + 20)
        writeUInt16LE(0x0102, into: &bytes, at: peOffset + 22)
        writeUInt16LE(optionalMagic, into: &bytes, at: peOffset + 24)
        writeUInt16LE(2, into: &bytes, at: peOffset + 24 + 68) // Windows GUI subsystem
        return Data(bytes)
    }

    private func makeMinimalLnk(
        targetPath: String,
        workingDir: String? = nil,
        arguments: String? = nil
    ) -> Data {
        let validCLSID: [UInt8] = [
            0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
        ]
        var flags: UInt32 = (1 << 1) | (1 << 7) // HasLinkInfo | IsUnicode
        if workingDir != nil { flags |= (1 << 4) }
        if arguments != nil { flags |= (1 << 5) }

        var bytes = [UInt8](repeating: 0, count: 76)
        writeUInt32LE(0x0000_004C, into: &bytes, at: 0)
        for (i, b) in validCLSID.enumerated() { bytes[4 + i] = b }
        writeUInt32LE(flags, into: &bytes, at: 20)

        // Extended Unicode LinkInfo (headerSize = 0x24 = 36)
        var linkInfo = [UInt8](repeating: 0, count: 36)
        writeUInt32LE(0x24, into: &linkInfo, at: 4)
        writeUInt32LE(0x01, into: &linkInfo, at: 8) // VolumeIDAndLocalBasePath
        let unicodeOffset = UInt32(linkInfo.count)
        writeUInt32LE(unicodeOffset, into: &linkInfo, at: 28)
        for unit in targetPath.utf16 {
            linkInfo.append(UInt8(truncatingIfNeeded: unit))
            linkInfo.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        linkInfo.append(contentsOf: [0x00, 0x00])
        writeUInt32LE(UInt32(linkInfo.count), into: &linkInfo, at: 0)
        bytes.append(contentsOf: linkInfo)

        func appendUnicodeStringData(_ value: String) {
            let count = UInt16(value.utf16.count)
            bytes.append(UInt8(truncatingIfNeeded: count))
            bytes.append(UInt8(truncatingIfNeeded: count >> 8))
            for unit in value.utf16 {
                bytes.append(UInt8(truncatingIfNeeded: unit))
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
            }
        }

        if let workingDir { appendUnicodeStringData(workingDir) }
        if let arguments { appendUnicodeStringData(arguments) }

        return Data(bytes)
    }

    private func writeUInt16LE(_ value: UInt16, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeUInt32LE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
