import Foundation
import XCTest
@testable import VermouthCore

final class EngineManagerTests: XCTestCase {
    private var tempDir: URL!
    private var vermouthHome: URL!
    private var paths: VermouthPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try createTempDirectory(prefix: "vermouth-engine-test")
        vermouthHome = tempDir.appendingPathComponent("vermouth-home", isDirectory: true)
        paths = VermouthPaths(baseDirectory: vermouthHome)
        try paths.ensureBaseDirectories()
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempDir)
        tempDir = nil
        vermouthHome = nil
        paths = nil
        try super.tearDownWithError()
    }

    // MARK: - Capability Detection (New WoW64 vs Legacy 64-bit)

    func testDiscoverNewWoW64AndLegacy64BitEngines() async throws {
        // Engine A: Wine 11.0 New WoW64 with WINEMSYNC & WINEDLLPATH_PREPEND markers
        let engineARoot = try createFakeWineEngine(
            named: "wine-11-wow64",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("ELF-HEADER\0WINEMSYNC\0PADDING\0WINEDLLPATH_PREPEND\0".utf8)
        )

        // Engine B: Legacy 64-bit-only Wine (wine64 only, no i386-windows, no markers)
        let engineBRoot = try createFakeWineEngine(
            named: "wine-8-legacy64",
            includeWine: false,
            includeWine64: true,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("PLAIN-LEGACY-NTDLL-WITHOUT-MARKERS".utf8)
        )

        let engineABinary = engineARoot.appendingPathComponent("bin/wine").path
        let engineBBinary = engineBRoot.appendingPathComponent("bin/wine64").path

        let runner = MockCommandRunner(
            resultsByExecutable: [
                engineABinary: CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: ""),
                engineBBinary: CommandResult(exitCode: 0, stdout: "wine-8.0.1\n", stderr: ""),
            ]
        )
        let prober = MockSystemProber()
        let manager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [
                EngineCandidateRoot(
                    id: "test-wow64",
                    displayName: "Wine Stable",
                    rootPath: engineARoot.path,
                    source: .homebrewCask
                ),
                EngineCandidateRoot(
                    id: "test-legacy64",
                    displayName: "Legacy Wine",
                    rootPath: engineBRoot.path,
                    source: .applicationBundle
                ),
            ]
        )

        let engines = try await manager.listEngines()
        XCTAssertEqual(engines.count, 2)

        let engineA = try XCTUnwrap(engines.first(where: { $0.id == "test-wow64" }))
        XCTAssertEqual(engineA.version, "wine-11.0")
        XCTAssertEqual(engineA.name, "Wine Stable 11.0 (WoW64)")
        XCTAssertEqual(engineA.wineBinaryPath, engineABinary)
        XCTAssertEqual(engineA.wineserverPath, engineARoot.appendingPathComponent("bin/wineserver").path)
        XCTAssertEqual(engineA.source, .homebrewCask)
        XCTAssertTrue(engineA.capabilities.isNewWoW64)
        XCTAssertTrue(engineA.capabilities.supports32Bit)
        XCTAssertTrue(engineA.capabilities.supports64Bit)
        XCTAssertTrue(engineA.capabilities.supportsMSync)
        XCTAssertTrue(engineA.capabilities.supportsWineDLLPathPrepend)
        XCTAssertFalse(engineA.isQuarantined)

        let engineB = try XCTUnwrap(engines.first(where: { $0.id == "test-legacy64" }))
        XCTAssertEqual(engineB.version, "wine-8.0.1")
        XCTAssertEqual(engineB.name, "Legacy Wine 8.0.1")
        XCTAssertEqual(engineB.wineBinaryPath, engineBBinary)
        XCTAssertEqual(engineB.wineserverPath, engineBRoot.appendingPathComponent("bin/wineserver").path)
        XCTAssertEqual(engineB.source, .applicationBundle)
        XCTAssertFalse(engineB.capabilities.isNewWoW64)
        XCTAssertFalse(engineB.capabilities.supports32Bit)
        XCTAssertTrue(engineB.capabilities.supports64Bit)
        XCTAssertFalse(engineB.capabilities.supportsMSync)
        XCTAssertFalse(engineB.capabilities.supportsWineDLLPathPrepend)
        XCTAssertFalse(engineB.isQuarantined)

        // Verify MockCommandRunner received --version probes for both binaries
        let probedPaths = Set(runner.recordedRequests.map(\.executablePath))
        XCTAssertEqual(probedPaths, Set([engineABinary, engineBBinary]))
        XCTAssertTrue(runner.recordedRequests.allSatisfy { $0.arguments == ["--version"] })
    }

    func testCrossChunkBoundaryMarkerDetectionInLargeNtdll() async throws {
        // EngineManager reads 65,536-byte chunks with overlap.
        // Place "WINEDLLPATH_PREPEND" (19 bytes) straddling byte 65,536,
        // and "WINEMSYNC" (9 bytes) straddling byte 131,072.
        let chunkSize = 65_536
        var payload = [UInt8](repeating: 0x2E, count: chunkSize * 2 + 4_096)

        let prependMarker = Array("WINEDLLPATH_PREPEND".utf8)
        let prependStart = chunkSize - 9 // 9 bytes in chunk 0, 10 bytes in chunk 1
        for (idx, byte) in prependMarker.enumerated() {
            payload[prependStart + idx] = byte
        }

        let msyncMarker = Array("WINEMSYNC".utf8)
        let msyncStart = (chunkSize * 2) - 4 // 4 bytes in chunk 1, 5 bytes in chunk 2
        for (idx, byte) in msyncMarker.enumerated() {
            payload[msyncStart + idx] = byte
        }

        let engineRoot = try createFakeWineEngine(
            named: "wine-boundary-markers",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data(payload)
        )
        let wineBin = engineRoot.appendingPathComponent("bin/wine").path

        let runner = MockCommandRunner(
            resultsByExecutable: [
                wineBin: CommandResult(exitCode: 0, stdout: "wine-11.0 (Staging)\n", stderr: ""),
            ]
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: MockSystemProber(),
            candidateRoots: [
                EngineCandidateRoot(
                    id: "boundary-engine",
                    displayName: "Boundary Wine",
                    rootPath: engineRoot.path,
                    source: .homebrewCask
                ),
            ]
        )

        let engines = try await manager.listEngines()
        let engine = try XCTUnwrap(engines.first)
        XCTAssertTrue(
            engine.capabilities.supportsWineDLLPathPrepend,
            "WINEDLLPATH_PREPEND straddling 65,536-byte chunk boundary must be detected"
        )
        XCTAssertTrue(
            engine.capabilities.supportsMSync,
            "WINEMSYNC straddling 131,072-byte chunk boundary must be detected"
        )
        XCTAssertTrue(engine.capabilities.isNewWoW64)
    }

    func testScanFilesForMarkersAndParseMajorVersionEdgeCases() throws {
        XCTAssertEqual(EngineManager.parseMajorVersion(from: "wine-11.0"), 11)
        XCTAssertEqual(EngineManager.parseMajorVersion(from: "wine-9.0-rc1 (Staging)"), 9)
        XCTAssertEqual(EngineManager.parseMajorVersion(from: "Wine-10.4.2"), 10)
        XCTAssertEqual(EngineManager.parseMajorVersion(from: "8.0.1"), 8)
        XCTAssertNil(EngineManager.parseMajorVersion(from: "unknown"))

        let missingPath = tempDir.appendingPathComponent("missing.so").path
        let emptyFound = EngineManager.scanFilesForMarkers(
            paths: [missingPath],
            markers: [Array("WINEMSYNC".utf8)]
        )
        XCTAssertTrue(emptyFound.isEmpty)

        let exactFile = tempDir.appendingPathComponent("exact.so")
        try Data("WINEDLLPATH_PREPEND".utf8).write(to: exactFile)
        let exactFound = EngineManager.scanFilesForMarkers(
            paths: [exactFile.path],
            markers: [Array("WINEDLLPATH_PREPEND".utf8), Array("WINEMSYNC".utf8)]
        )
        XCTAssertEqual(exactFound, Set([0]))
    }

    // MARK: - Custom Engine Registration, Persistence, Default & Unregister

    func testCustomEngineRegistrationPersistenceDefaultAndUnregister() async throws {
        let discoveredRoot = try createFakeWineEngine(
            named: "discovered-wine",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("WINEMSYNC".utf8)
        )
        let customRoot = try createFakeWineEngine(
            named: "custom-wine",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("WINEMSYNC WINEDLLPATH_PREPEND".utf8)
        )

        let discoveredCandidate = EngineCandidateRoot(
            id: "discovered-stable",
            displayName: "Wine Stable",
            rootPath: discoveredRoot.path,
            source: .homebrewCask
        )

        let runner = MockCommandRunner(
            resultsByExecutable: [
                discoveredRoot.appendingPathComponent("bin/wine").path: CommandResult(
                    exitCode: 0,
                    stdout: "wine-10.0\n",
                    stderr: ""
                ),
                customRoot.appendingPathComponent("bin/wine").path: CommandResult(
                    exitCode: 0,
                    stdout: "wine-11.1-custom\n",
                    stderr: ""
                ),
            ]
        )
        let prober = MockSystemProber()

        let manager1 = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [discoveredCandidate]
        )

        // Default engine before setting explicit default falls back to first discovered engine
        let initialDefault = try await manager1.defaultEngine()
        XCTAssertEqual(initialDefault?.id, "discovered-stable")

        // Register custom engine
        let registered = try await manager1.registerCustomEngine(
            name: "  My Custom Wine  ",
            rootPath: customRoot.path
        )
        XCTAssertTrue(registered.id.hasPrefix("custom-"))
        XCTAssertEqual(registered.name, "My Custom Wine")
        XCTAssertEqual(registered.source, .custom)
        XCTAssertEqual(registered.version, "wine-11.1-custom")
        XCTAssertTrue(registered.capabilities.supportsWineDLLPathPrepend)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.enginesConfigURL.path))

        // Duplicate registration of same rootPath must fail with engineAlreadyRegistered
        do {
            _ = try await manager1.registerCustomEngine(name: "Duplicate", rootPath: customRoot.path)
            XCTFail("Expected VermouthError.engineAlreadyRegistered")
        } catch let error as VermouthError {
            XCTAssertEqual(error, .engineAlreadyRegistered(id: registered.id))
        }

        // Set custom engine as default
        try await manager1.setDefaultEngine(id: registered.id)

        // Reload in a brand new EngineManager instance to verify persistence
        let manager2 = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [discoveredCandidate]
        )
        let reloadedEngines = try await manager2.listEngines()
        XCTAssertEqual(reloadedEngines.map(\.id), ["discovered-stable", registered.id])

        let reloadedDefault = try await manager2.defaultEngine()
        XCTAssertEqual(reloadedDefault?.id, registered.id)

        // Setting unknown engine as default fails with engineNotFound
        do {
            try await manager2.setDefaultEngine(id: "does-not-exist")
            XCTFail("Expected VermouthError.engineNotFound")
        } catch let error as VermouthError {
            XCTAssertEqual(error, .engineNotFound(id: "does-not-exist"))
        }

        // Attempting to unregister a discovered (non-custom) engine fails
        do {
            try await manager2.unregisterCustomEngine(id: "discovered-stable")
            XCTFail("Expected VermouthError.cannotUnregisterDiscoveredEngine")
        } catch let error as VermouthError {
            XCTAssertEqual(error, .cannotUnregisterDiscoveredEngine(id: "discovered-stable"))
        }

        // Attempting to unregister a non-existent engine fails
        do {
            try await manager2.unregisterCustomEngine(id: "missing-engine-id")
            XCTFail("Expected VermouthError.engineNotFound")
        } catch let error as VermouthError {
            XCTAssertEqual(error, .engineNotFound(id: "missing-engine-id"))
        }

        // Unregister custom engine clears defaultEngineID and persists removal
        try await manager2.unregisterCustomEngine(id: registered.id)

        let manager3 = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [discoveredCandidate]
        )
        let remainingEngines = try await manager3.listEngines()
        XCTAssertEqual(remainingEngines.map(\.id), ["discovered-stable"])

        let fallbackDefault = try await manager3.defaultEngine()
        XCTAssertEqual(fallbackDefault?.id, "discovered-stable")
    }

    func testRegisterCustomEngineResolvesNestedAppBundleAndRejectsInvalidRoots() async throws {
        let appBundle = tempDir.appendingPathComponent("Custom Wine.app", isDirectory: true)
        let nestedRoot = appBundle.appendingPathComponent("Contents/Resources/wine", isDirectory: true)
        try createFakeWineEngine(
            at: nestedRoot,
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows"],
            ntdllPayload: nil
        )

        let runner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: "")
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: MockSystemProber(),
            candidateRoots: []
        )

        // Registering the .app root should automatically resolve to Contents/Resources/wine
        let registered = try await manager.registerCustomEngine(
            name: "Bundled Wine",
            rootPath: appBundle.path
        )
        XCTAssertEqual(registered.rootPath, nestedRoot.standardizedFileURL.path)

        // Empty name rejected
        do {
            _ = try await manager.registerCustomEngine(name: "   ", rootPath: nestedRoot.path)
            XCTFail("Expected VermouthError.invalidEngineRoot for blank name")
        } catch let error as VermouthError {
            guard case .invalidEngineRoot = error else {
                XCTFail("Expected invalidEngineRoot, got \(error)")
                return
            }
        }

        // Directory missing wineserver rejected
        let brokenRoot = try createFakeWineEngine(
            named: "missing-wineserver",
            includeWine: true,
            includeWine64: false,
            includeWineserver: false,
            libSubdirectories: ["lib/wine/x86_64-windows"],
            ntdllPayload: nil
        )
        do {
            _ = try await manager.registerCustomEngine(name: "Broken Wine", rootPath: brokenRoot.path)
            XCTFail("Expected VermouthError.invalidEngineRoot when wineserver is missing")
        } catch let error as VermouthError {
            guard case .invalidEngineRoot = error else {
                XCTFail("Expected invalidEngineRoot, got \(error)")
                return
            }
        }

        // Empty directory missing wine & wine64 rejected
        let emptyDir = tempDir.appendingPathComponent("empty-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        do {
            _ = try await manager.registerCustomEngine(name: "Empty Dir", rootPath: emptyDir.path)
            XCTFail("Expected VermouthError.invalidEngineRoot when wine binary is missing")
        } catch let error as VermouthError {
            guard case .invalidEngineRoot = error else {
                XCTFail("Expected invalidEngineRoot, got \(error)")
                return
            }
        }
    }

    func testManagedEngineDiscoveryUnderVermouthHomeEnginesDirectory() async throws {
        let managedEngineRoot = vermouthHome
            .appendingPathComponent("Engines", isDirectory: true)
            .appendingPathComponent("Wine Custom 11", isDirectory: true)
        try createFakeWineEngine(
            at: managedEngineRoot,
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("WINEMSYNC".utf8)
        )

        let runner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 0, stdout: "wine-11.2\n", stderr: "")
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: MockSystemProber(),
            candidateRoots: []
        )

        let engines = try await manager.listEngines()
        XCTAssertEqual(engines.count, 1)
        let engine = try XCTUnwrap(engines.first)
        XCTAssertEqual(engine.id, "managed-wine-custom-11")
        XCTAssertEqual(engine.source, .managed)
        XCTAssertTrue(engine.capabilities.isNewWoW64)
        XCTAssertTrue(engine.capabilities.supportsMSync)
    }

    func testUnsupportedEnginesConfigSchemaVersionThrows() async throws {
        let futureConfig = EnginesConfigFile(schemaVersion: 99, defaultEngineID: nil, customEngines: [])
        try VermouthJSON.writeAtomically(futureConfig, to: paths.enginesConfigURL)

        let manager = EngineManager(
            paths: paths,
            commandRunner: MockCommandRunner(),
            systemProber: MockSystemProber(),
            candidateRoots: []
        )

        do {
            _ = try await manager.listEngines()
            XCTFail("Expected VermouthError.unsupportedSchemaVersion")
        } catch let error as VermouthError {
            guard case let .unsupportedSchemaVersion(found, supported, _) = error else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, EnginesConfigFile.currentSchemaVersion)
        }
    }

    // MARK: - Preflight Report Scenarios

    func testRunPreflightReadyCaseOnAppleSilicon() async throws {
        let engineRoot = try createFakeWineEngine(
            named: "ready-wine",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("WINEMSYNC WINEDLLPATH_PREPEND".utf8)
        )
        let runner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: "")
        )
        let prober = MockSystemProber(
            architecture: .arm64,
            osVersion: OSVersionInfo(major: 15, minor: 0, patch: 0, displayString: "macOS 15.0.0"),
            rosetta2Installed: true,
            executables: [
                "brew": "/opt/homebrew/bin/brew",
                "winetricks": "/opt/homebrew/bin/winetricks",
            ]
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [
                EngineCandidateRoot(
                    id: "ready-wine",
                    displayName: "Wine Stable",
                    rootPath: engineRoot.path,
                    source: .homebrewCask
                ),
            ]
        )

        let report = await manager.runPreflight()

        XCTAssertTrue(report.isReadyToLaunch)
        XCTAssertEqual(report.architecture, .arm64)
        XCTAssertEqual(report.osVersion, OSVersionInfo(major: 15, minor: 0, patch: 0, displayString: "macOS 15.0.0"))
        XCTAssertTrue(report.rosetta2Ready)
        XCTAssertEqual(report.homebrewPath, "/opt/homebrew/bin/brew")
        XCTAssertEqual(report.winetricksPath, "/opt/homebrew/bin/winetricks")
        XCTAssertEqual(report.discoveredEngines.count, 1)
        XCTAssertTrue(report.items.allSatisfy { $0.status == .pass })
    }

    func testRunPreflightMissingRosetta2OnArm64() async throws {
        let engineRoot = try createFakeWineEngine(
            named: "wine-no-rosetta",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows"],
            ntdllPayload: nil
        )
        let prober = MockSystemProber(
            architecture: .arm64,
            osVersion: OSVersionInfo(major: 15, minor: 0, patch: 0, displayString: "macOS 15.0.0"),
            rosetta2Installed: false
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: MockCommandRunner(
                defaultResult: CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: "")
            ),
            systemProber: prober,
            candidateRoots: [
                EngineCandidateRoot(
                    id: "wine-1",
                    displayName: "Wine Stable",
                    rootPath: engineRoot.path,
                    source: .homebrewCask
                ),
            ]
        )

        let report = await manager.runPreflight()

        XCTAssertFalse(report.isReadyToLaunch)
        XCTAssertFalse(report.rosetta2Ready)
        let rosettaItem = try XCTUnwrap(report.items.first(where: { $0.id == "rosetta2" }))
        XCTAssertEqual(rosettaItem.status, .fail)
        XCTAssertTrue(
            rosettaItem.remediationCommand?.contains("softwareupdate --install-rosetta") == true,
            "Expected Rosetta 2 remediation command, got \(String(describing: rosettaItem.remediationCommand))"
        )
    }

    func testRunPreflightMissingWineEnginesRecommendsWineStableAndMultiSource() async throws {
        let prober = MockSystemProber(
            architecture: .arm64,
            osVersion: OSVersionInfo(major: 15, minor: 0, patch: 0, displayString: "macOS 15.0.0"),
            rosetta2Installed: true,
            executables: ["brew": "/opt/homebrew/bin/brew"]
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: MockCommandRunner(),
            systemProber: prober,
            candidateRoots: []
        )

        let report = await manager.runPreflight()

        XCTAssertFalse(report.isReadyToLaunch)
        XCTAssertTrue(report.discoveredEngines.isEmpty)
        let enginesItem = try XCTUnwrap(report.items.first(where: { $0.id == "wine-engines" }))
        XCTAssertEqual(enginesItem.status, .fail)
        XCTAssertTrue(
            enginesItem.remediationCommand?.contains("wine-stable") == true,
            "Remediation command should recommend wine-stable, got \(String(describing: enginesItem.remediationCommand))"
        )
        XCTAssertTrue(
            enginesItem.detail.contains("Wine Stable"),
            "Preflight detail should mention Wine Stable"
        )
        XCTAssertTrue(
            enginesItem.detail.contains("CrossOver") && enginesItem.detail.contains("自定义"),
            "Preflight detail should mention multi-source compatibility (CrossOver & custom paths), got: \(enginesItem.detail)"
        )
    }

    func testRunPreflightQuarantinedEngineEmitsWarningAndRemediation() async throws {
        // B-6a: Remediation must target enclosing .app bundle (not .../Contents/Resources/wine),
        // and warning must still emit even when only 1 of 2 discovered engines is quarantined.
        let appBundle = tempDir.appendingPathComponent("Wine Stable.app", isDirectory: true)
        let quarantinedRoot = appBundle.appendingPathComponent("Contents/Resources/wine", isDirectory: true)
        try createFakeWineEngine(
            at: quarantinedRoot,
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows"],
            ntdllPayload: nil
        )
        let cleanRoot = try createFakeWineEngine(
            named: "clean-wine",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows"],
            ntdllPayload: nil
        )

        let prober = MockSystemProber(
            architecture: .arm64,
            osVersion: OSVersionInfo(major: 15, minor: 0, patch: 0, displayString: "macOS 15.0.0"),
            rosetta2Installed: true,
            quarantinedPaths: [appBundle.path]
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: MockCommandRunner(
                defaultResult: CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: "")
            ),
            systemProber: prober,
            candidateRoots: [
                EngineCandidateRoot(
                    id: "quarantined-wine",
                    displayName: "Wine Stable",
                    rootPath: quarantinedRoot.path,
                    source: .homebrewCask,
                    quarantineCheckPath: appBundle.path
                ),
                EngineCandidateRoot(
                    id: "clean-wine",
                    displayName: "Clean Wine",
                    rootPath: cleanRoot.path,
                    source: .homebrewCask
                ),
            ]
        )

        let report = await manager.runPreflight()

        XCTAssertEqual(report.discoveredEngines.count, 2)
        XCTAssertEqual(
            report.discoveredEngines.first(where: { $0.id == "quarantined-wine" })?.isQuarantined,
            true
        )
        XCTAssertEqual(
            report.discoveredEngines.first(where: { $0.id == "clean-wine" })?.isQuarantined,
            false
        )

        let enginesItem = try XCTUnwrap(report.items.first(where: { $0.id == "wine-engines" }))
        XCTAssertEqual(enginesItem.status, .warning)

        let remediation = try XCTUnwrap(enginesItem.remediationCommand)
        let expectedBundleTarget = ShellQuoting.posixEscape(appBundle.standardizedFileURL.path)
        XCTAssertEqual(remediation, "xattr -dr com.apple.quarantine \(expectedBundleTarget)")
        XCTAssertFalse(
            remediation.contains("Contents/Resources/wine"),
            "Quarantine remediation must point to enclosing .app bundle, not internal wine dir: \(remediation)"
        )
        // Verify POSIX single-quoting was applied because the .app bundle name contains a space
        XCTAssertTrue(remediation.contains("'"))
    }

    func testRunPreflightOlderMacOSAndIntelArchitectureSemantics() async throws {
        let engineRoot = try createFakeWineEngine(
            named: "intel-wine",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows"],
            ntdllPayload: nil
        )
        let prober = MockSystemProber(
            architecture: .x86_64,
            osVersion: OSVersionInfo(major: 13, minor: 6, patch: 0, displayString: "macOS 13.6.0"),
            rosetta2Installed: false,
            executables: [:]
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: MockCommandRunner(
                defaultResult: CommandResult(exitCode: 0, stdout: "wine-10.0\n", stderr: "")
            ),
            systemProber: prober,
            candidateRoots: [
                EngineCandidateRoot(
                    id: "intel-wine",
                    displayName: "Wine",
                    rootPath: engineRoot.path,
                    source: .homebrewCask
                ),
            ]
        )

        // macOS 13.6.0 does not satisfy macOS 14.0+ requirement -> isReadyToLaunch must be false
        let report13 = await manager.runPreflight()

        XCTAssertEqual(report13.items.first(where: { $0.id == "host-architecture" })?.status, .warning)
        XCTAssertEqual(report13.items.first(where: { $0.id == "os-version" })?.status, .fail)
        XCTAssertEqual(report13.items.first(where: { $0.id == "rosetta2" })?.status, .pass)
        XCTAssertEqual(report13.items.first(where: { $0.id == "homebrew" })?.status, .warning)
        XCTAssertEqual(report13.items.first(where: { $0.id == "winetricks" })?.status, .warning)
        XCTAssertFalse(report13.isReadyToLaunch)

        // Upgrading to macOS 14.0 on Intel x86_64 without Rosetta 2 -> isReadyToLaunch must be true
        prober.osVersion = OSVersionInfo(major: 14, minor: 0, patch: 0, displayString: "macOS 14.0.0")
        let report14 = await manager.runPreflight()

        XCTAssertEqual(report14.items.first(where: { $0.id == "host-architecture" })?.status, .warning)
        XCTAssertEqual(report14.items.first(where: { $0.id == "os-version" })?.status, .pass)
        XCTAssertEqual(report14.items.first(where: { $0.id == "rosetta2" })?.status, .pass)
        XCTAssertTrue(report14.isReadyToLaunch)
    }

    // MARK: - B-6b & B-6c Regression Tests

    func testNonZeroVersionProbeWithDyldStderrDoesNotFalselyTriggerNewWoW64() async throws {
        // B-6b / L-016: Dual-binary engine (both wine & wine64 present) with i386-windows;
        // if `wine --version` exits non-zero printing `dyld[1234]: Library not loaded` to stderr,
        // version must be "unknown" and `1234` must NOT be parsed as major version >= 9.
        let engineRoot = try createFakeWineEngine(
            named: "dyld-broken-wine",
            includeWine: true,
            includeWine64: true,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows"],
            ntdllPayload: nil
        )
        let wineBin = engineRoot.appendingPathComponent("bin/wine").path

        let runner = MockCommandRunner(
            resultsByExecutable: [
                wineBin: CommandResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "dyld[1234]: Library not loaded: @rpath/libwine.dylib\n"
                ),
            ]
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: MockSystemProber(),
            candidateRoots: [
                EngineCandidateRoot(
                    id: "dyld-broken",
                    displayName: "Broken Wine",
                    rootPath: engineRoot.path,
                    source: .homebrewCask
                ),
            ]
        )

        let engines = try await manager.listEngines()
        let engine = try XCTUnwrap(engines.first)
        XCTAssertEqual(engine.version, "unknown")
        XCTAssertFalse(
            engine.capabilities.isNewWoW64,
            "PID 1234 from non-zero dyld stderr must not falsely trigger isNewWoW64"
        )
        XCTAssertNil(EngineManager.parseMajorVersion(from: "dyld[1234]: Library not loaded"))

        // Even if stdout contained a version string, non-zero exitCode must still return "unknown"
        runner.setResult(
            CommandResult(exitCode: 1, stdout: "wine-11.0\n", stderr: "dyld[5678]: crash\n"),
            forExecutable: wineBin
        )
        let enginesAfterNonZeroStdout = try await manager.listEngines()
        let engineAfterNonZeroStdout = try XCTUnwrap(enginesAfterNonZeroStdout.first)
        XCTAssertEqual(engineAfterNonZeroStdout.version, "unknown")
        XCTAssertFalse(engineAfterNonZeroStdout.capabilities.isNewWoW64)
    }

    func testHomebrewSymlinkIntoAppBundleDeduplicatesIntoSingleEngineWithFullCapabilities() async throws {
        // B-6c / L-016: Homebrew Cask installs `/Applications/Wine Stable.app/Contents/Resources/wine`
        // and symlinks `/opt/homebrew/bin/{wine,wineserver}` into that `.app` bundle (without `/opt/homebrew/lib/wine`).
        let fakeApps = tempDir.appendingPathComponent("fake-apps", isDirectory: true)
        let appBundle = fakeApps.appendingPathComponent("Wine Stable.app", isDirectory: true)
        let appEngineRoot = appBundle.appendingPathComponent("Contents/Resources/wine", isDirectory: true)
        try createFakeWineEngine(
            at: appEngineRoot,
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("ELF\0WINEMSYNC\0WINEDLLPATH_PREPEND\0".utf8)
        )

        let fakeHomebrew = tempDir.appendingPathComponent("fake-homebrew", isDirectory: true)
        let fakeHomebrewBin = fakeHomebrew.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHomebrewBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fakeHomebrewBin.appendingPathComponent("wine"),
            withDestinationURL: appEngineRoot.appendingPathComponent("bin/wine")
        )
        try FileManager.default.createSymbolicLink(
            at: fakeHomebrewBin.appendingPathComponent("wineserver"),
            withDestinationURL: appEngineRoot.appendingPathComponent("bin/wineserver")
        )

        let appCandidate = EngineCandidateRoot(
            id: "app-wine-stable",
            displayName: "Wine Stable",
            rootPath: appEngineRoot.path,
            source: .homebrewCask,
            quarantineCheckPath: appBundle.path
        )
        let homebrewCandidate = EngineCandidateRoot(
            id: "homebrew-arm64",
            displayName: "Homebrew Wine",
            rootPath: fakeHomebrew.path,
            source: .homebrewCask
        )

        let runner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: "")
        )
        let prober = MockSystemProber()

        // Order 1: .app candidate before Homebrew symlink candidate
        let managerAppFirst = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [appCandidate, homebrewCandidate]
        )
        let enginesAppFirst = try await managerAppFirst.listEngines()
        XCTAssertEqual(enginesAppFirst.count, 1, "Homebrew symlink must deduplicate with enclosing .app engine")
        let engineAppFirst = try XCTUnwrap(enginesAppFirst.first)
        XCTAssertEqual(engineAppFirst.id, "app-wine-stable")
        XCTAssertTrue(engineAppFirst.capabilities.isNewWoW64)
        XCTAssertTrue(engineAppFirst.capabilities.supports32Bit)
        XCTAssertTrue(engineAppFirst.capabilities.supports64Bit)
        XCTAssertTrue(engineAppFirst.capabilities.supportsMSync)
        XCTAssertTrue(engineAppFirst.capabilities.supportsWineDLLPathPrepend)

        // Order 2: Homebrew symlink candidate before .app candidate must still resolve full capabilities & deduplicate
        let managerBrewFirst = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [homebrewCandidate, appCandidate]
        )
        let enginesBrewFirst = try await managerBrewFirst.listEngines()
        XCTAssertEqual(enginesBrewFirst.count, 1, "Deduplication must hold regardless of candidate ordering")
        let engineBrewFirst = try XCTUnwrap(enginesBrewFirst.first)
        XCTAssertEqual(
            URL(fileURLWithPath: engineBrewFirst.rootPath).resolvingSymlinksInPath().standardizedFileURL.path,
            appEngineRoot.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertTrue(engineBrewFirst.capabilities.isNewWoW64)
        XCTAssertTrue(engineBrewFirst.capabilities.supports32Bit)
        XCTAssertTrue(engineBrewFirst.capabilities.supports64Bit)
        XCTAssertTrue(engineBrewFirst.capabilities.supportsMSync)
        XCTAssertTrue(engineBrewFirst.capabilities.supportsWineDLLPathPrepend)
    }

    // MARK: - Swift 6 Concurrency Safety & B-4 Atomic Config Mutations

    func testConcurrentPreflightAndListEngines() async throws {
        let engineRoot = try createFakeWineEngine(
            named: "concurrent-wine",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows", "lib/wine/x86_64-unix"],
            ntdllPayload: Data("WINEMSYNC WINEDLLPATH_PREPEND".utf8)
        )
        let manager = EngineManager(
            paths: paths,
            commandRunner: MockCommandRunner(
                defaultResult: CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: "")
            ),
            systemProber: MockSystemProber(),
            candidateRoots: [
                EngineCandidateRoot(
                    id: "concurrent-engine",
                    displayName: "Wine Stable",
                    rootPath: engineRoot.path,
                    source: .homebrewCask
                ),
            ]
        )

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for idx in 0..<8 {
                group.addTask {
                    if idx.isMultiple(of: 2) {
                        let engines = try await manager.listEngines()
                        return engines.count
                    } else {
                        let report = await manager.runPreflight()
                        return report.discoveredEngines.count
                    }
                }
            }
            var counts: [Int] = []
            for try await count in group {
                counts.append(count)
            }
            return counts
        }

        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 == 1 })
    }

    func testConcurrentRegisterCustomEngineAndSetDefaultHasNoLostUpdates() async throws {
        // B-4 / L-015: Concurrent registerCustomEngine + setDefaultEngine must never lose writes in engines.json.
        let discoveredRoot = try createFakeWineEngine(
            named: "discovered-base",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows"],
            ntdllPayload: nil
        )
        let discoveredCandidate = EngineCandidateRoot(
            id: "discovered-base",
            displayName: "Base Wine",
            rootPath: discoveredRoot.path,
            source: .homebrewCask
        )

        var customRootPaths: [String] = []
        for idx in 0..<12 {
            let root = try createFakeWineEngine(
                named: "concurrent-custom-\(idx)",
                includeWine: true,
                includeWine64: false,
                includeWineserver: true,
                libSubdirectories: ["lib/wine/x86_64-windows", "lib/wine/i386-windows"],
                ntdllPayload: nil
            )
            customRootPaths.append(root.path)
        }
        let duplicateRaceRoot = try createFakeWineEngine(
            named: "concurrent-dup-race",
            includeWine: true,
            includeWine64: false,
            includeWineserver: true,
            libSubdirectories: ["lib/wine/x86_64-windows"],
            ntdllPayload: nil
        )

        // Small async delay during `--version` ensures multiple register calls overlap before mutating engines.json.
        let runner = MockCommandRunner(
            runHandler: { _ in
                try? await Task.sleep(nanoseconds: 2_000_000)
                return CommandResult(exitCode: 0, stdout: "wine-11.0\n", stderr: "")
            }
        )
        let prober = MockSystemProber()
        let manager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [discoveredCandidate]
        )

        // Phase 1: Register 8 distinct custom engines concurrently alongside setDefaultEngine calls
        let firstBatchPaths = Array(customRootPaths[0..<8])
        let phase1IDs = try await withThrowingTaskGroup(of: String?.self) { group in
            for (idx, rootPath) in firstBatchPaths.enumerated() {
                group.addTask {
                    let engine = try await manager.registerCustomEngine(
                        name: "Concurrent Custom \(idx)",
                        rootPath: rootPath
                    )
                    return engine.id
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    try await manager.setDefaultEngine(id: "discovered-base")
                    return nil
                }
            }
            var ids: [String] = []
            for try await maybeID in group {
                if let id = maybeID {
                    ids.append(id)
                }
            }
            return ids
        }
        XCTAssertEqual(phase1IDs.count, 8)
        let preferredCustomID = try XCTUnwrap(phase1IDs.sorted().first)

        // Phase 2: Register 4 more custom engines concurrently while switching defaultEngineID to a custom engine
        let secondBatchPaths = Array(customRootPaths[8..<12])
        let phase2IDs = try await withThrowingTaskGroup(of: String?.self) { group in
            for (offset, rootPath) in secondBatchPaths.enumerated() {
                let idx = 8 + offset
                group.addTask {
                    let engine = try await manager.registerCustomEngine(
                        name: "Concurrent Custom \(idx)",
                        rootPath: rootPath
                    )
                    return engine.id
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    try await manager.setDefaultEngine(id: preferredCustomID)
                    return nil
                }
            }
            var ids: [String] = []
            for try await maybeID in group {
                if let id = maybeID {
                    ids.append(id)
                }
            }
            return ids
        }
        XCTAssertEqual(phase2IDs.count, 4)

        // Phase 3: Concurrent duplicate registrations of the same root must atomically admit exactly 1
        enum DupOutcome: Sendable {
            case registered(String)
            case alreadyRegistered
            case unexpected(String)
        }
        let dupRootPath = duplicateRaceRoot.path
        let dupOutcomes = await withTaskGroup(of: DupOutcome.self) { group in
            for idx in 0..<4 {
                group.addTask {
                    do {
                        let engine = try await manager.registerCustomEngine(
                            name: "Dup Race \(idx)",
                            rootPath: dupRootPath
                        )
                        return .registered(engine.id)
                    } catch let error as VermouthError {
                        if case .engineAlreadyRegistered = error {
                            return .alreadyRegistered
                        }
                        return .unexpected("\(error)")
                    } catch {
                        return .unexpected("\(error)")
                    }
                }
            }
            var outcomes: [DupOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        var dupRegisteredIDs: [String] = []
        var dupRejectedCount = 0
        for outcome in dupOutcomes {
            switch outcome {
            case let .registered(id):
                dupRegisteredIDs.append(id)
            case .alreadyRegistered:
                dupRejectedCount += 1
            case let .unexpected(message):
                XCTFail("Unexpected error during concurrent duplicate registration: \(message)")
            }
        }
        XCTAssertEqual(dupRegisteredIDs.count, 1)
        XCTAssertEqual(dupRejectedCount, 3)

        // Verify persisted engines.json has zero lost updates
        let persistedConfig = try VermouthJSON.read(EnginesConfigFile.self, from: paths.enginesConfigURL)
        let expectedCustomIDs = Set(phase1IDs + phase2IDs + dupRegisteredIDs)
        XCTAssertEqual(persistedConfig.customEngines.count, 13)
        XCTAssertEqual(Set(persistedConfig.customEngines.map(\.id)), expectedCustomIDs)
        XCTAssertEqual(persistedConfig.defaultEngineID, preferredCustomID)

        // Reload via fresh EngineManager instance and verify full state
        let reloadedManager = EngineManager(
            paths: paths,
            commandRunner: runner,
            systemProber: prober,
            candidateRoots: [discoveredCandidate]
        )
        let reloadedEngines = try await reloadedManager.listEngines()
        XCTAssertEqual(reloadedEngines.count, 14) // 1 discovered + 13 custom
        let reloadedDefault = try await reloadedManager.defaultEngine()
        XCTAssertEqual(reloadedDefault?.id, preferredCustomID)
    }

    // MARK: - Fake Wine Engine Fixture Helpers

    @discardableResult
    private func createFakeWineEngine(
        named folderName: String,
        includeWine: Bool,
        includeWine64: Bool,
        includeWineserver: Bool,
        libSubdirectories: [String],
        ntdllPayload: Data?
    ) throws -> URL {
        let root = tempDir.appendingPathComponent(folderName, isDirectory: true)
        try createFakeWineEngine(
            at: root,
            includeWine: includeWine,
            includeWine64: includeWine64,
            includeWineserver: includeWineserver,
            libSubdirectories: libSubdirectories,
            ntdllPayload: ntdllPayload
        )
        return root
    }

    private func createFakeWineEngine(
        at root: URL,
        includeWine: Bool,
        includeWine64: Bool,
        includeWineserver: Bool,
        libSubdirectories: [String],
        ntdllPayload: Data?
    ) throws {
        let fm = FileManager.default
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        if includeWine {
            try Data("#!/bin/sh\n".utf8).write(to: binDir.appendingPathComponent("wine"))
        }
        if includeWine64 {
            try Data("#!/bin/sh\n".utf8).write(to: binDir.appendingPathComponent("wine64"))
        }
        if includeWineserver {
            try Data("#!/bin/sh\n".utf8).write(to: binDir.appendingPathComponent("wineserver"))
        }

        for relativeSubdir in libSubdirectories {
            let dirURL = root.appendingPathComponent(relativeSubdir, isDirectory: true)
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        if let ntdllPayload {
            let unixDir = root.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
            try fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
            try ntdllPayload.write(to: unixDir.appendingPathComponent("ntdll.so"))
        }
    }
}
