import Foundation

/// Locates read-only bundled resources (such as built-in `.recipe.json` files) across
/// packaged macOS `.app` bundles, standalone CLI executables, `swift test`, and source trees.
///
/// Always probes `Bundle.main.resourceURL` and executable-relative paths before touching
/// SwiftPM's `Bundle.module` so non-Xcode `.app` bundles never trigger `Bundle.module`'s `fatalError`.
public enum VermouthResourceLocator: Sendable {
    private static let resourceBundleName = "Vermouth_VermouthCore.bundle"
    private static let recipeFileSuffix = ".recipe.json"

    private final class BundleAnchor: Sendable {}

    /// Returns the directory containing built-in `.recipe.json` files, or `nil` if unavailable.
    public static func builtInRecipesDirectory() -> URL? {
        // 1. Check Bundle.main.resourceURL and executable-relative paths first so packaged
        //    `.app` bundles and bundled companion CLI binaries never hit Bundle.module's fatalError.
        for candidate in primaryBundleCandidates() {
            if !recipeFiles(in: candidate).isEmpty {
                return candidate
            }
        }

        // 2. Check SwiftPM / test bundle paths only when not executing inside a `.app` bundle.
        if !isRunningInsideAppBundle() {
            for candidate in secondaryBundleCandidates() {
                if !recipeFiles(in: candidate).isEmpty {
                    return candidate
                }
            }
        }

        // 3. Fallback to the source-tree relative directory via `#filePath` if it exists on disk.
        let sourceFallback = sourceTreeRecipesDirectory()
        if !recipeFiles(in: sourceFallback).isEmpty {
            return sourceFallback
        }
        if directoryExists(at: sourceFallback) {
            return sourceFallback
        }

        return nil
    }

    /// Returns all built-in `.recipe.json` files sorted lexicographically by filename.
    public static func builtInRecipeFiles() -> [URL] {
        guard let directory = builtInRecipesDirectory() else {
            return []
        }
        return recipeFiles(in: directory)
    }

    // MARK: - Candidate Resolution

    private static func isRunningInsideAppBundle() -> Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private static func primaryBundleCandidates() -> [URL] {
        var candidates: [URL] = []

        if let mainResourceURL = Bundle.main.resourceURL {
            candidates.append(contentsOf: expandResourceBundle(at: mainResourceURL.appendingPathComponent(resourceBundleName)))
            candidates.append(mainResourceURL.appendingPathComponent("Recipes"))
            candidates.append(mainResourceURL.appendingPathComponent("Resources"))
        }

        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(contentsOf: expandResourceBundle(at: executableDir.appendingPathComponent(resourceBundleName)))
            candidates.append(executableDir.appendingPathComponent("Recipes"))

            let siblingResources = executableDir
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
            candidates.append(contentsOf: expandResourceBundle(at: siblingResources.appendingPathComponent(resourceBundleName)))
            candidates.append(siblingResources.appendingPathComponent("Recipes"))
        }

        return deduplicate(candidates)
    }

    private static func secondaryBundleCandidates() -> [URL] {
        var candidates: [URL] = []

        let anchorBundle = Bundle(for: BundleAnchor.self)
        if let anchorResourceURL = anchorBundle.resourceURL {
            candidates.append(contentsOf: expandResourceBundle(at: anchorResourceURL.appendingPathComponent(resourceBundleName)))
        }
        candidates.append(contentsOf: expandResourceBundle(at: anchorBundle.bundleURL.appendingPathComponent(resourceBundleName)))
        candidates.append(
            contentsOf: expandResourceBundle(
                at: anchorBundle.bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(resourceBundleName)
            )
        )

        candidates.append(
            contentsOf: expandResourceBundle(
                at: Bundle.main.bundleURL.appendingPathComponent(resourceBundleName)
            )
        )

        #if SWIFT_PACKAGE
        if canSafelyAccessModuleBundle(anchorBundle: anchorBundle) {
            let moduleBundle = Bundle.module
            if let moduleResourceURL = moduleBundle.resourceURL {
                candidates.append(moduleResourceURL.appendingPathComponent("Resources"))
                candidates.append(moduleResourceURL.appendingPathComponent("Recipes"))
                candidates.append(moduleResourceURL)
            }
            candidates.append(moduleBundle.bundleURL.appendingPathComponent("Resources"))
            candidates.append(moduleBundle.bundleURL)
        }
        #endif

        return deduplicate(candidates)
    }

    /// Mirrors SwiftPM's generated `Bundle.module` search paths to verify that accessing
    /// `Bundle.module` will succeed without triggering a runtime `fatalError`.
    private static func canSafelyAccessModuleBundle(anchorBundle: Bundle) -> Bool {
        var searchRoots: [URL] = []

        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let override = env["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? env["PACKAGE_RESOURCE_BUNDLE_URL"],
           !override.isEmpty
        {
            searchRoots.append(URL(fileURLWithPath: override))
        }
        #endif

        if let mainResourceURL = Bundle.main.resourceURL {
            searchRoots.append(mainResourceURL)
        }
        if let anchorResourceURL = anchorBundle.resourceURL {
            searchRoots.append(anchorResourceURL)
        }
        searchRoots.append(Bundle.main.bundleURL)

        for root in searchRoots {
            let bundleURL = root.appendingPathComponent(resourceBundleName)
            if Bundle(url: bundleURL) != nil {
                return true
            }
        }

        return false
    }

    private static func expandResourceBundle(at bundleURL: URL) -> [URL] {
        var candidates: [URL] = [
            bundleURL.appendingPathComponent("Resources"),
            bundleURL.appendingPathComponent("Contents/Resources/Resources"),
        ]

        if let loadedBundle = Bundle(url: bundleURL), let resourceURL = loadedBundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Resources"))
            candidates.append(resourceURL)
        }

        candidates.append(bundleURL.appendingPathComponent("Contents/Resources"))
        candidates.append(bundleURL)

        return candidates
    }

    private static func sourceTreeRecipesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Common/
            .deletingLastPathComponent() // VermouthCore/
            .appendingPathComponent("Recipes", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func recipeFiles(in directory: URL) -> [URL] {
        guard directoryExists(at: directory) else {
            return []
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { url in
                guard url.lastPathComponent.lowercased().hasSuffix(recipeFileSuffix) else {
                    return false
                }
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            let normalized = url.standardizedFileURL.path
            if seen.insert(normalized).inserted {
                result.append(url)
            }
        }
        return result
    }
}
