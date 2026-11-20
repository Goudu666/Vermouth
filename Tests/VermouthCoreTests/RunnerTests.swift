import Foundation
import XCTest
@testable import VermouthCore

private actor RegFileCaptureStore {
    struct Snapshot: Sendable {
        var capturedWindowsPath: String?
        var capturedUnixPath: String?
        var capturedBytes: Data?
    }

    private var snapshot = Snapshot()

    func record(windowsPath: String, unixPath: String?, bytes: Data?) {
        snapshot.capturedWindowsPath = windowsPath
        snapshot.capturedUnixPath = unixPath
        snapshot.capturedBytes = bytes
    }

    func current() -> Snapshot {
        snapshot
    }
}

final class RunnerTests: XCTestCase {
    private var tempDir: URL!
    private var vermouthHome: URL!
    private var paths: VermouthPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try createTempDirectory(prefix: "vermouth-runner-test")
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

    // MARK: - DllOverrideFormatter Tests

    func testDllOverrideFormatterWineBuiltinEnforcesBuiltinAndDetectsConflicts() throws {
        // L-001: DXMT wineBuiltin must emit `=b` for every contained DLL, never `=n,b`.
        let dxmtPackage = makeDXMTBuiltinPackage()

        let cleanResolution = DllOverrideFormatter.resolve(
            graphicsBackend: .dxmt,
            graphicsPackage: dxmtPackage,
            bottleOverrides: [],
            appOverrides: []
        )
        XCTAssertEqual(cleanResolution.formattedValue, "d3d10core=b;d3d11=b;dxgi=b;winemetal=b")
        XCTAssertFalse(cleanResolution.formattedValue.contains("=n,b"))
        XCTAssertTrue(cleanResolution.warnings.isEmpty)

        // User configures conflicting `d3d11=n,b` alongside valid non-conflicting `dinput8=n,b`
        let conflictResolution = DllOverrideFormatter.resolve(
            graphicsBackend: .dxmt,
            graphicsPackage: dxmtPackage,
            bottleOverrides: [
                DllOverride(dllName: "d3d11", mode: .nativeThenBuiltin, enabled: true),
                DllOverride(dllName: "dinput8", mode: .nativeThenBuiltin, enabled: true),
            ],
            appOverrides: []
        )
        XCTAssertEqual(
            conflictResolution.formattedValue,
            "d3d10core=b;d3d11=b;dinput8=n,b;dxgi=b;winemetal=b"
        )
        XCTAssertEqual(conflictResolution.warnings.count, 1)
        let warning = try XCTUnwrap(conflictResolution.warnings.first)
        XCTAssertEqual(warning.category, .dllOverrideConflict)
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertEqual(warning.quickFix, .removeConflictingDllOverrides(["d3d11"]))

        // Compatible `=b` override and disabled conflicting entry must NOT produce conflict warnings
        let compatibleResolution = DllOverrideFormatter.resolve(
            graphicsBackend: .dxmt,
            graphicsPackage: dxmtPackage,
            bottleOverrides: [
                DllOverride(dllName: "D3D11.DLL", mode: .builtinOnly, enabled: true),
                DllOverride(dllName: "dxgi", mode: .nativeThenBuiltin, enabled: false),
            ],
            appOverrides: []
        )
        XCTAssertTrue(compatibleResolution.warnings.isEmpty)
        XCTAssertEqual(compatibleResolution.formattedValue, "d3d10core=b;d3d11=b;dxgi=b;winemetal=b")

        // App-level conflict + bottle-level disabled conflict are both caught and sorted deterministically
        let multiConflict = DllOverrideFormatter.resolve(
            graphicsBackend: .dxmt,
            graphicsPackage: dxmtPackage,
            bottleOverrides: [
                DllOverride(dllName: "d3d11", mode: .disabled, enabled: true),
            ],
            appOverrides: [
                DllOverride(dllName: "DXGI.dll", mode: .nativeOnly, enabled: true),
            ]
        )
        XCTAssertEqual(multiConflict.formattedValue, "d3d10core=b;d3d11=b;dxgi=b;winemetal=b")
        XCTAssertEqual(
            multiConflict.warnings.first?.quickFix,
            .removeConflictingDllOverrides(["d3d11", "dxgi"])
        )
    }

    func testDllOverrideFormatterNativeDLLsOnlyEmitsContainedDLLs() {
        // L-002: DXVK nativeDLLs must emit `=n,b` strictly for containedDLLs (never hardcoding d3d9/dxgi).
        let dxvkPackage = makeDXVKNativePackage(containedDLLs: ["d3d11", "d3d10core"])

        let resolution = DllOverrideFormatter.resolve(
            graphicsBackend: .dxvk,
            graphicsPackage: dxvkPackage,
            bottleOverrides: [],
            appOverrides: []
        )

        XCTAssertEqual(resolution.formattedValue, "d3d10core=n,b;d3d11=n,b")
        XCTAssertFalse(resolution.formattedValue.contains("d3d9"))
        XCTAssertFalse(resolution.formattedValue.contains("dxgi"))
        XCTAssertTrue(resolution.warnings.isEmpty)

        // When backend is .wined3d, graphicsPackage is ignored
        let wined3dResolution = DllOverrideFormatter.resolve(
            graphicsBackend: .wined3d,
            graphicsPackage: dxvkPackage,
            bottleOverrides: [],
            appOverrides: []
        )
        XCTAssertEqual(wined3dResolution.formattedValue, "")
        XCTAssertTrue(wined3dResolution.warnings.isEmpty)
    }

    func testDllOverrideFormatterPrecedenceDisabledModeAndDeterministicSorting() {
        let bottleOverrides = [
            DllOverride(dllName: "Version.DLL", mode: .builtinThenNative, enabled: true),
            DllOverride(dllName: "DINPUT8.dll", mode: .nativeThenBuiltin, enabled: true),
            DllOverride(dllName: "omitted_off", mode: .nativeOnly, enabled: false),
        ]
        let appOverrides = [
            DllOverride(dllName: "dinput8", mode: .nativeOnly, enabled: true),
            DllOverride(dllName: "Foo.DLL", mode: .disabled, enabled: true),
            DllOverride(dllName: "alpha_off", mode: .builtinOnly, enabled: false),
        ]

        let resolution = DllOverrideFormatter.resolve(
            graphicsBackend: .wined3d,
            graphicsPackage: nil,
            bottleOverrides: bottleOverrides,
            appOverrides: appOverrides
        )

        XCTAssertEqual(resolution.formattedValue, "dinput8=n;foo=;version=b,n")
        XCTAssertEqual(resolution.effectiveOverrides.map(\.dllName), ["dinput8", "foo", "version"])
        XCTAssertTrue(resolution.warnings.isEmpty)

        // Direct format(_:) helper normalizes, deduplicates last-wins, sorts, and skips disabled entries
        let direct = DllOverrideFormatter.format([
            DllOverride(dllName: "Zebra.dll", mode: .builtinOnly, enabled: true),
            DllOverride(dllName: "Alpha", mode: .nativeThenBuiltin, enabled: true),
            DllOverride(dllName: "alpha.dll", mode: .disabled, enabled: true),
            DllOverride(dllName: "DisabledEntry", mode: .nativeOnly, enabled: false),
        ])
        XCTAssertEqual(direct, "alpha=;zebra=b")
    }

    // MARK: - EnvironmentBuilder Tests

    func testEnvironmentBuilderSyncModesDisplayLocaleAndWineDebug() async throws {
        let prober = MockSystemProber()
        let builder = EnvironmentBuilder(paths: paths, systemProber: prober)
        let engine = makeEngine()
        var bottle = makeBottle()

        // 1. MSync + Metal HUD + Chinese locale + smart WINEDEBUG append
        bottle.config.syncMode = .msync
        bottle.config.display.metalHUD = true
        bottle.config.locale = LocaleConfig(
            chineseLocalizationEnabled: true,
            lcAll: "zh_CN.UTF-8",
            fallbackFontName: "STHeiti"
        )
        bottle.config.wineDebugChannels = "-all,err+all"

        let msyncPlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: nil,
            debugChannelsOverride: "+loaddll"
        )
        XCTAssertEqual(msyncPlan.environment["WINEPREFIX"], bottle.prefixPath)
        XCTAssertEqual(msyncPlan.environment["WINEMSYNC"], "1")
        XCTAssertEqual(msyncPlan.environment["WINEESYNC"], "0")
        XCTAssertEqual(msyncPlan.environment["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(msyncPlan.environment["LC_ALL"], "zh_CN.UTF-8")
        XCTAssertEqual(msyncPlan.environment["LANG"], "zh_CN.UTF-8")
        XCTAssertEqual(msyncPlan.environment["WINEDEBUG"], "-all,err+all,+loaddll")

        // 2. ESync + Metal HUD off + locale off + full WINEDEBUG reset override
        bottle.config.syncMode = .esync
        bottle.config.display.metalHUD = false
        bottle.config.locale.chineseLocalizationEnabled = false

        let esyncPlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: .builtinTool(.cmd, extraArguments: []),
            graphicsPackage: nil,
            debugChannelsOverride: "-all,+d3d11"
        )
        XCTAssertEqual(esyncPlan.environment["WINEMSYNC"], "0")
        XCTAssertEqual(esyncPlan.environment["WINEESYNC"], "1")
        XCTAssertNil(esyncPlan.environment["MTL_HUD_ENABLED"])
        XCTAssertNil(esyncPlan.environment["LC_ALL"])
        XCTAssertNil(esyncPlan.environment["LANG"])
        XCTAssertEqual(esyncPlan.environment["WINEDEBUG"], "-all,+d3d11")

        // 3. SyncMode.none + default base WINEDEBUG
        bottle.config.syncMode = .none
        let nonePlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: nil,
            debugChannelsOverride: nil
        )
        XCTAssertEqual(nonePlan.environment["WINEMSYNC"], "0")
        XCTAssertEqual(nonePlan.environment["WINEESYNC"], "0")
        XCTAssertEqual(nonePlan.environment["WINEDEBUG"], "-all,err+all")
    }

    func testEnvironmentBuilderStripsWineArchWin32OnNewWoW64Engine() async throws {
        // L-004: New WoW64 engines must never receive WINEARCH=win32 even if user configures it.
        let builder = EnvironmentBuilder(paths: paths, systemProber: MockSystemProber())
        let wow64Engine = makeEngine(isNewWoW64: true, supports32Bit: true, supports64Bit: true)
        var bottle = makeBottle()
        bottle.config.environmentVariables = [
            "WINEARCH": "win32",
            "CUSTOM_VAR": "from-bottle",
        ]

        let plan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: wow64Engine,
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: nil
        )

        XCTAssertNil(plan.environment["WINEARCH"])
        XCTAssertEqual(plan.environment["CUSTOM_VAR"], "from-bottle")
        XCTAssertTrue(
            plan.warnings.contains(where: {
                $0.id == "wow64-ignored-winearch-win32" && $0.category == .architectureMismatch
            })
        )

        // Legacy non-WoW64 engine retains WINEARCH=win32 without warning
        let legacyEngine = makeEngine(isNewWoW64: false, supports32Bit: true, supports64Bit: true)
        let legacyPlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: legacyEngine,
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: nil
        )
        XCTAssertEqual(legacyPlan.environment["WINEARCH"], "win32")
        XCTAssertFalse(legacyPlan.warnings.contains(where: { $0.id == "wow64-ignored-winearch-win32" }))
    }

    func testEnvironmentBuilderWineBuiltinPrependAndIncapableEngineDiagnostic() async throws {
        // L-001: WINEDLLPATH_PREPEND is set on capable engines, and produces .graphicsInitFailed when unsupported.
        let builder = EnvironmentBuilder(paths: paths, systemProber: MockSystemProber())
        let dxmtPkg = makeDXMTBuiltinPackage()
        var bottle = makeBottle()
        bottle.config.graphicsBackend = .dxmt
        bottle.config.graphicsLayerVersionID = dxmtPkg.id

        let capableEngine = makeEngine(supportsWineDLLPathPrepend: true)
        let capablePlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: capableEngine,
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: dxmtPkg
        )
        XCTAssertEqual(capablePlan.environment["WINEDLLPATH_PREPEND"], dxmtPkg.installPath)
        XCTAssertEqual(capablePlan.environment["WINEDLLOVERRIDES"], "d3d10core=b;d3d11=b;dxgi=b;winemetal=b")
        XCTAssertFalse(capablePlan.warnings.contains(where: { $0.category == .graphicsInitFailed }))

        let incapableEngine = makeEngine(supportsWineDLLPathPrepend: false)
        let incapablePlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: incapableEngine,
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: dxmtPkg
        )
        XCTAssertNil(incapablePlan.environment["WINEDLLPATH_PREPEND"])
        let finding = try XCTUnwrap(incapablePlan.warnings.first(where: { $0.category == .graphicsInitFailed }))
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.quickFix, .switchGraphicsBackend(.wined3d))
    }

    func testEnvironmentBuilderWarnsWhenDeployedDXVKPackageLacksDXGI() async throws {
        // 已部署的 Gcenx -repack 包（无 dxgi）在每次启动时都应提示，而不是让用户只看到 DXVK 的报错
        let builder = EnvironmentBuilder(paths: paths, systemProber: MockSystemProber())
        let repack = GraphicsLayerPackage(
            id: "dxvk-v1.10.3-20230507-repack",
            backend: .dxvk,
            version: "v1.10.3-20230507-repack",
            format: .nativeDLLs,
            installPath: "/tmp/dxvk/v1.10.3-20230507-repack",
            containedDLLs: ["d3d10core", "d3d11"]
        )
        var bottle = makeBottle()
        bottle.config.graphicsBackend = .dxvk
        bottle.config.graphicsLayerVersionID = repack.id

        let plan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: makeEngine(supportsWineDLLPathPrepend: true),
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: repack
        )
        XCTAssertTrue(plan.warnings.contains { $0.id == "dxvk-package-missing-dxgi-\(repack.id)" })

        var full = repack
        full.id = "dxvk-v1.10.3-20230507"
        full.containedDLLs = ["d3d10core", "d3d11", "d3d9", "dxgi"]
        let fullPlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: makeEngine(supportsWineDLLPathPrepend: true),
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: full
        )
        XCTAssertFalse(fullPlan.warnings.contains { $0.category == .graphicsPackageIncomplete })
    }

    func testEnvironmentBuilderMSIInstallerSkipsPEInspectionAndConvertsPaths() async throws {
        // L-009: .msi files are not PE executables; must skip PEInspector and invoke `msiexec /i <WindowsPath>`.
        let builder = EnvironmentBuilder(paths: paths, systemProber: MockSystemProber())
        let x64OnlyEngine = makeEngine(isNewWoW64: false, supports32Bit: false, supports64Bit: true)
        let bottle = makeBottle()

        // Case 1: External host path maps to Z:\...
        let externalPlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: x64OnlyEngine,
            target: .installer(path: "/Users/test/Downloads/Setup.msi"),
            graphicsPackage: nil
        )
        XCTAssertEqual(externalPlan.arguments, ["msiexec", "/i", "Z:\\Users\\test\\Downloads\\Setup.msi"])
        XCTAssertTrue(externalPlan.warnings.isEmpty)

        // Case 2: Non-PE .msi file on disk inside drive_c/temp/a.msi maps to C:\temp\a.msi without PE errors
        let msiURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c/temp/a.msi", isDirectory: false)
        try FileManager.default.createDirectory(
            at: msiURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("NOT-A-PE-OLE-MSI-COMPOUND-DOCUMENT".utf8).write(to: msiURL)

        let driveCPlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: x64OnlyEngine,
            target: .installer(path: msiURL.path),
            graphicsPackage: nil,
            extraArgs: ["/qn"]
        )
        XCTAssertEqual(driveCPlan.arguments, ["msiexec", "/i", "C:\\temp\\a.msi", "/qn"])
        XCTAssertFalse(driveCPlan.warnings.contains(where: { $0.category == .architectureMismatch }))
    }

    func testEnvironmentBuilderDetects32BitPEMismatchOn64BitOnlyEngine() async throws {
        let builder = EnvironmentBuilder(paths: paths, systemProber: MockSystemProber())
        let bottle = makeBottle()

        let exeURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c/Games/classic32.exe", isDirectory: false)
        try FileManager.default.createDirectory(
            at: exeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeMinimalPE32Binary().write(to: exeURL)

        let x64OnlyEngine = makeEngine(isNewWoW64: false, supports32Bit: false, supports64Bit: true)
        let mismatchPlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: x64OnlyEngine,
            target: .executable(path: exeURL.path, workingDirectory: nil),
            graphicsPackage: nil
        )
        let archWarning = try XCTUnwrap(
            mismatchPlan.warnings.first(where: { $0.category == .architectureMismatch })
        )
        XCTAssertEqual(archWarning.quickFix, .select32BitCapableEngine)
        XCTAssertEqual(mismatchPlan.workingDirectory, exeURL.deletingLastPathComponent().standardizedFileURL.path)

        // On a 32-bit capable WoW64 engine, no architecture mismatch warning is emitted
        let wow64Engine = makeEngine(isNewWoW64: true, supports32Bit: true, supports64Bit: true)
        let compatiblePlan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: wow64Engine,
            target: .executable(path: exeURL.path, workingDirectory: nil),
            graphicsPackage: nil
        )
        XCTAssertFalse(compatiblePlan.warnings.contains(where: { $0.category == .architectureMismatch }))
    }

    func testEnvironmentBuilderEmitsQuarantineWarningsForTargetAndEngine() async throws {
        // L-006: LaunchPlan warnings must flag both quarantined target file and quarantined engine.
        let appBundle = tempDir.appendingPathComponent("Wine Stable.app", isDirectory: true)
        let engineRoot = appBundle.appendingPathComponent("Contents/Resources/wine", isDirectory: true)
        let quarantinedEngine = makeEngine(rootPath: engineRoot.path, isQuarantined: true)

        let bottle = makeBottle()
        let exeURL = tempDir.appendingPathComponent("Downloads/game.exe", isDirectory: false)
        try FileManager.default.createDirectory(
            at: exeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeMinimalPE32Binary().write(to: exeURL)

        let prober = MockSystemProber(quarantinedPaths: [exeURL.path])
        let builder = EnvironmentBuilder(paths: paths, systemProber: prober)

        let plan = try await builder.buildLaunchPlan(
            bottle: bottle,
            engine: quarantinedEngine,
            target: .executable(path: exeURL.path, workingDirectory: nil),
            graphicsPackage: nil
        )

        let quarantineFindings = plan.warnings.filter { $0.category == .quarantineBlocked }
        XCTAssertEqual(quarantineFindings.count, 2)
        XCTAssertTrue(
            quarantineFindings.contains(where: {
                $0.quickFix == .removeQuarantine(path: appBundle.standardizedFileURL.path, recursive: true)
            })
        )
        XCTAssertTrue(
            quarantineFindings.contains(where: {
                $0.quickFix == .removeQuarantine(path: exeURL.standardizedFileURL.path, recursive: false)
            })
        )
    }

    func testBuildInteractiveTerminalScriptConsistencyAndInjectionDefense() throws {
        // L-003 & L-015: Terminal script mirrors LaunchPlan env, single-quotes values, and skips invalid env keys.
        let builder = EnvironmentBuilder(paths: paths, systemProber: MockSystemProber())
        let dxmtPkg = makeDXMTBuiltinPackage()
        let engine = makeEngine(supportsWineDLLPathPrepend: true)
        var bottle = makeBottle()
        bottle.config.syncMode = .msync
        bottle.config.graphicsBackend = .dxmt
        bottle.config.graphicsLayerVersionID = dxmtPkg.id
        bottle.config.dllOverrides = [
            DllOverride(dllName: "dinput8", mode: .nativeThenBuiltin, enabled: true),
        ]
        bottle.config.environmentVariables = [
            "SAFE_QUOTE": "it's safe",
            "FOO; rm -rf /": "pwned",
            "9BAD_IDENT": "skip",
            "BAD=KEY": "skip",
        ]

        let script = try builder.buildInteractiveTerminalScript(
            bottle: bottle,
            engine: engine,
            graphicsPackage: dxmtPkg
        )

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash\n"))
        XCTAssertTrue(script.contains("export WINEPREFIX='\(bottle.prefixPath)'"))
        XCTAssertTrue(script.contains("export WINEMSYNC='1'"))
        XCTAssertTrue(script.contains("export WINEESYNC='0'"))
        XCTAssertTrue(script.contains("export WINEDLLPATH_PREPEND='\(dxmtPkg.installPath)'"))
        XCTAssertTrue(
            script.contains("export WINEDLLOVERRIDES='d3d10core=b;d3d11=b;dinput8=n,b;dxgi=b;winemetal=b'")
        )
        XCTAssertTrue(script.contains("export SAFE_QUOTE='it'\\''s safe'"))
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertFalse(script.contains("9BAD_IDENT"))
        XCTAssertFalse(script.contains("BAD=KEY"))
    }

    // MARK: - WineRunner Tests

    func testEnsurePrefixInitializedRunsWinebootSkipsExistingAndThrowsOnFailure() async throws {
        let mockCommandRunner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 0, stdout: "", stderr: "")
        )
        let wineRunner = WineRunner(
            paths: paths,
            commandRunner: mockCommandRunner,
            systemProber: MockSystemProber()
        )
        let engine = makeEngine()
        let bottle = makeBottle()

        // 1. Missing system.reg / drive_c -> invokes wineboot --init
        try await wineRunner.ensurePrefixInitialized(bottle: bottle, engine: engine)
        XCTAssertEqual(mockCommandRunner.recordedRequests.count, 1)
        let initRequest = try XCTUnwrap(mockCommandRunner.recordedRequests.first)
        XCTAssertEqual(initRequest.executablePath, engine.wineBinaryPath)
        XCTAssertEqual(initRequest.arguments, ["wineboot", "--init"])
        XCTAssertEqual(initRequest.environment["WINEPREFIX"], bottle.prefixPath)
        XCTAssertEqual(initRequest.environment["WINEMSYNC"], "1")
        XCTAssertEqual(initRequest.environment["WINEESYNC"], "0")

        // 2. Non-zero wineboot exit -> throws prefixInitializationFailed (L-016)
        mockCommandRunner.resetRecordedRequests()
        mockCommandRunner.setResult(
            CommandResult(exitCode: 1, stdout: "", stderr: "wineboot: failed to create prefix"),
            forExecutable: engine.wineBinaryPath
        )
        do {
            try await wineRunner.ensurePrefixInitialized(bottle: bottle, engine: engine)
            XCTFail("Expected VermouthError.prefixInitializationFailed on non-zero wineboot exit")
        } catch let error as VermouthError {
            guard case let .prefixInitializationFailed(bottleName, reason) = error else {
                XCTFail("Expected prefixInitializationFailed, got \(error)")
                return
            }
            XCTAssertEqual(bottleName, bottle.name)
            XCTAssertTrue(reason.contains("1"))
        }

        // 3. Once system.reg AND drive_c exist -> skips cleanly without invoking any command
        let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: prefixURL.appendingPathComponent("drive_c", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("WINE REGISTRY Version 2\n".utf8).write(
            to: prefixURL.appendingPathComponent("system.reg", isDirectory: false)
        )
        mockCommandRunner.resetRecordedRequests()

        try await wineRunner.ensurePrefixInitialized(bottle: bottle, engine: engine)
        XCTAssertTrue(mockCommandRunner.recordedRequests.isEmpty)
    }

    func testLaunchStreamsLogLinesAndWritesHeaderPreviewAndOutputToLogFile() async throws {
        let engine = makeEngine()
        let bottle = makeBottle()
        let mockCommandRunner = MockCommandRunner(
            streamChunksByExecutable: [
                engine.wineBinaryPath: [
                    .stdout("Starting test app"),
                    .stderr("err:d3d:init minor warning"),
                    .stdout("Rendered frame 1"),
                    .exited(0),
                ],
            ]
        )
        let wineRunner = WineRunner(
            paths: paths,
            commandRunner: mockCommandRunner,
            systemProber: MockSystemProber()
        )

        let plan = try await wineRunner.buildLaunchPlan(
            bottle: bottle,
            engine: engine,
            target: .builtinTool(.winecfg, extraArguments: []),
            graphicsPackage: nil
        )
        let session = wineRunner.launch(plan)
        XCTAssertEqual(session.logFilePath, plan.logFilePath)

        var collected: [LogLine] = []
        for try await line in session.stream {
            collected.append(line)
        }

        XCTAssertEqual(collected.count, 4)
        XCTAssertEqual(collected[0].stream, .stdout)
        XCTAssertEqual(collected[0].text, "Starting test app")
        XCTAssertNil(collected[0].exitCode)

        XCTAssertEqual(collected[1].stream, .stderr)
        XCTAssertEqual(collected[1].text, "err:d3d:init minor warning")

        XCTAssertEqual(collected[2].stream, .stdout)
        XCTAssertEqual(collected[2].text, "Rendered frame 1")

        XCTAssertEqual(collected[3].stream, .system)
        XCTAssertEqual(collected[3].exitCode, 0)

        let logContents = try String(contentsOfFile: plan.logFilePath, encoding: .utf8)
        XCTAssertTrue(logContents.contains("=== Vermouth Launch Log ==="))
        XCTAssertTrue(logContents.contains("Bottle ID: \(bottle.id.uuidString)"))
        XCTAssertTrue(logContents.contains("Command: \(plan.shellCommandPreview)"))
        XCTAssertTrue(logContents.contains("[stdout] Starting test app"))
        XCTAssertTrue(logContents.contains("[stderr] err:d3d:init minor warning"))
        XCTAssertTrue(logContents.contains("[stdout] Rendered frame 1"))
        XCTAssertTrue(logContents.contains("[system] Process exited with code 0"))
    }

    func testKillWineServerHandlesSuccessIdleNoOpAndRealError() async throws {
        // L-003: Idle no-server exits are safe no-ops; genuine execution errors throw.
        let engine = makeEngine()
        let bottle = makeBottle()
        let mockCommandRunner = MockCommandRunner()
        let wineRunner = WineRunner(
            paths: paths,
            commandRunner: mockCommandRunner,
            systemProber: MockSystemProber()
        )

        // 1. Clean exit 0 with force == false -> `-k`
        mockCommandRunner.setResult(
            CommandResult(exitCode: 0, stdout: "", stderr: ""),
            forExecutable: engine.wineserverPath
        )
        try await wineRunner.killWineServer(for: bottle, engine: engine, force: false)
        XCTAssertEqual(mockCommandRunner.recordedRequests.last?.arguments, ["-k"])
        XCTAssertEqual(mockCommandRunner.recordedRequests.last?.environment["WINEMSYNC"], "1")

        // 2. Idle no-server exit (`exitCode: 1`, "wineserver: no server running") -> clean no-op
        mockCommandRunner.setResult(
            CommandResult(exitCode: 1, stdout: "", stderr: "wineserver: no server running\n"),
            forExecutable: engine.wineserverPath
        )
        try await wineRunner.killWineServer(for: bottle, engine: engine, force: true)
        XCTAssertEqual(mockCommandRunner.recordedRequests.last?.arguments, ["-k9"])

        // 3. Idle exit (`exitCode: 1`, empty stderr) -> clean no-op
        mockCommandRunner.setResult(
            CommandResult(exitCode: 1, stdout: "", stderr: ""),
            forExecutable: engine.wineserverPath
        )
        try await wineRunner.killWineServer(for: bottle, engine: engine, force: false)

        // 4. Genuine error (`exitCode: 127`, "permission denied") -> throws commandExecutionFailed
        mockCommandRunner.setResult(
            CommandResult(exitCode: 127, stdout: "", stderr: "permission denied"),
            forExecutable: engine.wineserverPath
        )
        do {
            try await wineRunner.killWineServer(for: bottle, engine: engine, force: false)
            XCTFail("Expected VermouthError.commandExecutionFailed")
        } catch let error as VermouthError {
            XCTAssertEqual(
                error,
                .commandExecutionFailed(
                    executable: engine.wineserverPath,
                    exitCode: 127,
                    stderr: "permission denied"
                )
            )
        }
    }

    func testApplyBottleRegistrySettingsInitializesPrefixWritesUTF16LEBOMAndCleansUp() async throws {
        // L-003 & L-009: Ensures prefix initialized, writes UTF-16LE BOM .reg under drive_c/windows/temp,
        // runs regedit /S C:\windows\temp\... with unified MSync env, and removes temp .reg afterward.
        let engine = makeEngine()
        var bottle = makeBottle()
        bottle.config.syncMode = .msync
        bottle.config.display.dpi = 144
        bottle.config.locale.chineseLocalizationEnabled = true

        let prefixPath = bottle.prefixPath
        let captureStore = RegFileCaptureStore()

        let mockCommandRunner = MockCommandRunner(
            runHandler: { request in
                if request.arguments.first == "regedit", request.arguments.count >= 3 {
                    let winPath = request.arguments[2]
                    let unixPath = ShellQuoting.toUnixPath(windowsPath: winPath, prefixPath: prefixPath)
                    let bytes = unixPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                    await captureStore.record(windowsPath: winPath, unixPath: unixPath, bytes: bytes)
                }
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        let wineRunner = WineRunner(
            paths: paths,
            commandRunner: mockCommandRunner,
            systemProber: MockSystemProber()
        )

        try await wineRunner.applyBottleRegistrySettings(bottle: bottle, engine: engine)

        // Must have called wineboot --init first, then regedit /S C:\windows\temp\...
        let requests = mockCommandRunner.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].arguments, ["wineboot", "--init"])
        XCTAssertEqual(requests[0].environment["WINEMSYNC"], "1")
        XCTAssertEqual(requests[0].environment["WINEESYNC"], "0")

        XCTAssertEqual(Array(requests[1].arguments.prefix(2)), ["regedit", "/S"])
        XCTAssertEqual(requests[1].environment["WINEMSYNC"], "1")
        XCTAssertEqual(requests[1].environment["WINEESYNC"], "0")
        XCTAssertEqual(requests[1].environment["WINEPREFIX"], bottle.prefixPath)

        let captured = await captureStore.current()
        let winPath = try XCTUnwrap(captured.capturedWindowsPath)
        XCTAssertTrue(winPath.hasPrefix("C:\\windows\\temp\\vermouth-settings-"))
        XCTAssertTrue(winPath.hasSuffix(".reg"))

        let regBytes = try XCTUnwrap(captured.capturedBytes)
        XCTAssertGreaterThanOrEqual(regBytes.count, 2)
        XCTAssertEqual(regBytes[0], 0xFF, "Expected UTF-16LE BOM byte 0 (0xFF)")
        XCTAssertEqual(regBytes[1], 0xFE, "Expected UTF-16LE BOM byte 1 (0xFE)")

        let decodedScript = try XCTUnwrap(
            String(data: Data(regBytes.dropFirst(2)), encoding: .utf16LittleEndian)
        )
        XCTAssertTrue(decodedScript.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        XCTAssertTrue(decodedScript.contains("\"LogPixels\"=dword:00000090"))
        XCTAssertTrue(decodedScript.contains("\"宋体\"="))
        XCTAssertTrue(decodedScript.contains("hex(7):"))

        // Temp .reg file must be cleaned up after regedit completes
        let regUnixPath = try XCTUnwrap(captured.capturedUnixPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: regUnixPath))

        // Non-zero regedit exit must throw registryPatchFailed and STILL remove temp .reg file
        let failureCapture = RegFileCaptureStore()
        let failingRunner = MockCommandRunner(
            runHandler: { request in
                if request.arguments.first == "regedit", request.arguments.count >= 3 {
                    let failWinPath = request.arguments[2]
                    let failUnixPath = ShellQuoting.toUnixPath(windowsPath: failWinPath, prefixPath: prefixPath)
                    await failureCapture.record(windowsPath: failWinPath, unixPath: failUnixPath, bytes: nil)
                    return CommandResult(exitCode: 1, stdout: "", stderr: "regedit import error")
                }
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        let failingWineRunner = WineRunner(
            paths: paths,
            commandRunner: failingRunner,
            systemProber: MockSystemProber()
        )
        do {
            try await failingWineRunner.applyBottleRegistrySettings(bottle: bottle, engine: engine)
            XCTFail("Expected VermouthError.registryPatchFailed")
        } catch let error as VermouthError {
            guard case let .registryPatchFailed(reason) = error else {
                XCTFail("Expected registryPatchFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("regedit import error"))
        }
        let failureSnapshot = await failureCapture.current()
        let failedRegUnixPath = try XCTUnwrap(failureSnapshot.capturedUnixPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedRegUnixPath))
    }

    // MARK: - Test Fixture Helpers

    private func makeBottle(name: String = "Test Bottle") -> Bottle {
        let id = UUID()
        let prefixURL = paths.bottlePrefixURL(id: id)
        return Bottle(
            id: id,
            name: name,
            createdAt: VermouthJSON.currentTimestamp(),
            updatedAt: VermouthJSON.currentTimestamp(),
            prefixPath: prefixURL.path,
            isExternalPrefix: false,
            config: BottleConfig()
        )
    }

    private func makeEngine(
        id: String = "test-wine-11",
        rootPath: String? = nil,
        isNewWoW64: Bool = true,
        supports32Bit: Bool = true,
        supports64Bit: Bool = true,
        supportsMSync: Bool = true,
        supportsWineDLLPathPrepend: Bool = true,
        isQuarantined: Bool = false
    ) -> WineEngine {
        let effectiveRoot = rootPath ?? tempDir.appendingPathComponent("fake-wine", isDirectory: true).path
        return WineEngine(
            id: id,
            name: "Wine Stable 11.0 (WoW64)",
            rootPath: effectiveRoot,
            wineBinaryPath: "\(effectiveRoot)/bin/wine",
            wineserverPath: "\(effectiveRoot)/bin/wineserver",
            version: "wine-11.0",
            source: .homebrewCask,
            capabilities: EngineCapabilities(
                supports32Bit: supports32Bit,
                supports64Bit: supports64Bit,
                isNewWoW64: isNewWoW64,
                supportsMSync: supportsMSync,
                supportsWineDLLPathPrepend: supportsWineDLLPathPrepend
            ),
            isQuarantined: isQuarantined
        )
    }

    private func makeDXMTBuiltinPackage() -> GraphicsLayerPackage {
        let installPath = paths.graphicsPackageDirectory(backend: .dxmt, version: "v0.80").path
        return GraphicsLayerPackage(
            id: "dxmt-v0.80",
            backend: .dxmt,
            version: "v0.80",
            format: .wineBuiltin,
            installPath: installPath,
            installedAt: VermouthJSON.currentTimestamp(),
            containedDLLs: ["d3d11", "dxgi", "d3d10core", "winemetal"]
        )
    }

    private func makeDXVKNativePackage(containedDLLs: [String]) -> GraphicsLayerPackage {
        let installPath = paths.graphicsPackageDirectory(backend: .dxvk, version: "v1.10.3").path
        return GraphicsLayerPackage(
            id: "dxvk-v1.10.3",
            backend: .dxvk,
            version: "v1.10.3",
            format: .nativeDLLs,
            installPath: installPath,
            installedAt: VermouthJSON.currentTimestamp(),
            containedDLLs: containedDLLs
        )
    }

    private func makeMinimalPE32Binary() -> Data {
        let eLfanew = 0x80
        let optSize = 224
        var bytes = [UInt8](repeating: 0, count: eLfanew + 24 + optSize)
        // DOS header: MZ + e_lfanew
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes[0x3C] = UInt8(eLfanew & 0xFF)
        // PE\0\0 signature
        bytes[eLfanew] = 0x50
        bytes[eLfanew + 1] = 0x45
        // Machine = 0x014C (i386 32-bit)
        bytes[eLfanew + 4] = 0x4C
        bytes[eLfanew + 5] = 0x01
        // SizeOfOptionalHeader = 224
        bytes[eLfanew + 20] = UInt8(optSize & 0xFF)
        // Characteristics = 0x0102 (EXECUTABLE_IMAGE | 32BIT_MACHINE)
        bytes[eLfanew + 22] = 0x02
        bytes[eLfanew + 23] = 0x01
        // Optional header magic = 0x010B (PE32)
        bytes[eLfanew + 24] = 0x0B
        bytes[eLfanew + 25] = 0x01
        // Subsystem = 2 (Windows GUI)
        bytes[eLfanew + 24 + 68] = 0x02
        return Data(bytes)
    }
}
