#if os(macOS)
import AppKit
import SwiftUI
import VermouthCore

@main
struct VermouthApp: App {
    var body: some Scene {
        WindowGroup("Vermouth") {
            BootstrapRootView()
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 880, height: 560)
    }
}

private enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview = "Overview"
    case recipes = "Built-in Recipes"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .overview:
            return "shippingbox"
        case .recipes:
            return "doc.text"
        }
    }
}

private struct BootstrapRootView: View {
    @State private var selectedSection: SidebarSection? = .overview
    @State private var recipeDirectory: URL? = VermouthResourceLocator.builtInRecipesDirectory()
    @State private var recipeFiles: [URL] = VermouthResourceLocator.builtInRecipeFiles()

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(recipeFiles.isEmpty ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text("Vermouth \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } detail: {
            switch selectedSection ?? .overview {
            case .overview:
                overviewDetail
            case .recipes:
                recipesDetail
            }
        }
    }

    private var overviewDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Vermouth")
                        .font(.largeTitle.bold())
                    Text("v\(appVersion)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Text("Open-source native macOS Windows compatibility launcher powered by Swift 6, Wine, DXMT, and DXVK-macOS.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                GroupBox("Bundle & Resource Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Discovered Built-in Recipes") {
                            Text("\(recipeFiles.count)")
                                .font(.headline.monospacedDigit())
                        }
                        LabeledContent("Bundle Path") {
                            Text(Bundle.main.bundleURL.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        if let recipeDirectory {
                            LabeledContent("Recipes Directory") {
                                Text(recipeDirectory.path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                            HStack {
                                Spacer()
                                Button("Reveal in Finder") {
                                    _ = NSWorkspace.shared.open(recipeDirectory)
                                }
                            }
                        } else {
                            Text("Built-in recipes directory was not found.")
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(6)
                }

                HStack {
                    Button("Refresh Resources") {
                        recipeDirectory = VermouthResourceLocator.builtInRecipesDirectory()
                        recipeFiles = VermouthResourceLocator.builtInRecipeFiles()
                    }
                    Spacer()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var recipesDetail: some View {
        Group {
            if recipeFiles.isEmpty {
                ContentUnavailableView(
                    "No Built-in Recipes Found",
                    systemImage: "doc.questionmark",
                    description: Text("Ensure Vermouth_VermouthCore.bundle is present inside Contents/Resources.")
                )
            } else {
                List(recipeFiles, id: \.self) { fileURL in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .font(.headline)
                        Text(fileURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Built-in Recipes (\(recipeFiles.count))")
    }
}
#endif
