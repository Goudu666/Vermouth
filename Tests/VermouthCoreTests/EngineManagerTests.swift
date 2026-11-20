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
        let appBundle = tempDir.appendingPathComponent("Wine Stable.app", isDirectory: true)
        let engineRoot = appBundle.appendingPathComponent("Contents/Resources/wine", isDirectory: true)
        try createFakeWineEngine(
            at: engineRoot,
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
                    rootPath: engineRoot.path,
                    source: .homebrewCask,
                    quarantineCheckPath: appBundle.path
                ),
            ]
        )

        let report = await manager.runPreflight()

        XCTAssertEqual(report.discoveredEngines.count, 1)
        XCTAssertEqual(report.discoveredEngines.first?.isQuarantined, true)

        let enginesItem = try XCTUnwrap(report.items.first(where: { $0.id == "wine-engines" }))
        XCTAssertEqual(enginesItem.status, .warning)
        let remediation = try XCTUnwrap(enginesItem.remediationCommand)
        XCTAssertTrue(remediation.hasPrefix("xattr -dr com.apple.quarantine "))
        // Verify POSIX single-quoting was applied because rootPath contains a space ("Wine Stable.app")
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

        let report = await manager.runPreflight()

        XCTAssertEqual(report.items.first(where: { $0.id == "host-architecture" })?.status, .warning)
        XCTAssertEqual(report.items.first(where: { $0.id == "os-version" })?.status, .fail)
        XCTAssertEqual(report.items.first(where: { $0.id == "rosetta2" })?.status, .pass)
        XCTAssertEqual(report.items.first(where: { $0.id == "homebrew" })?.status, .warning)
        XCTAssertEqual(report.items.first(where: { $0.id == "winetricks" })?.status, .warning)
        // On x86_64, Rosetta 2 is not required for launch readiness
        XCTAssertTrue(report.isReadyToLaunch)
    }

    // MARK: - Swift 6 Concurrency Safety

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
