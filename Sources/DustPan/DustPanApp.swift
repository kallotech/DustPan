import AppKit
import QuickLookUI
import SwiftUI

@main
struct DustPanApp: App {
    var body: some Scene {
        WindowGroup {
            DesktopSorterView()
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}

private struct CoreFolder: Identifiable {
    let name: String
    let icon: String
    let url: URL
    var id: URL { url }
}

private struct DesktopFile: Identifiable, Sendable {
    let url: URL
    let fileSize: Int64
    let modified: Date?
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var kind: String { isDirectory ? "Folder" : (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()) }
}

struct FileIdentity: Equatable {
    let volumeNumber: Int64
    let fileNumber: UInt64

    static func read(at url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volumeNumber = (attributes[.systemNumber] as? NSNumber)?.int64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return FileIdentity(volumeNumber: volumeNumber, fileNumber: fileNumber)
    }
}

enum DestinationPathSafety {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey
    ]

    static func isSafeDirectory(_ destination: URL, under root: URL) -> Bool {
        let standardizedRoot = root.standardizedFileURL
        let standardizedDestination = destination.standardizedFileURL
        let rootComponents = standardizedRoot.pathComponents
        let destinationComponents = standardizedDestination.pathComponents
        guard destinationComponents.starts(with: rootComponents) else { return false }

        var current = standardizedRoot
        for component in destinationComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            guard isVisibleNonLinkDirectory(current) else { return false }
        }
        return isVisibleNonLinkDirectory(standardizedRoot)
    }

    private static func isVisibleNonLinkDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return false }
        return values.isDirectory == true && values.isHidden != true && values.isSymbolicLink == false
    }
}

private enum DesktopDirectoryReader {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey
    ]

    private static let fixedDesktopFolders: Set<String> = [
        "01_university", "02_career", "03_personal", "04_work",
        "inbox - needs review", "to delete - review"
    ]

    private static let protectedTerms = [
        "secret", "password", "credential", "private key", "recovery code", "api key", "token",
        "login details", "account login", "bank account", "bank details", "tax file number", "passport"
    ]

    static func read(from desktopURL: URL) throws -> [DesktopFile] {
        // Avoid URL-based enumeration with prefetched resource keys here. On some
        // Desktop/file-provider setups that API can block while opening the folder.
        let names = try FileManager.default.contentsOfDirectory(atPath: desktopURL.path)
        return names.compactMap { name in
            guard !name.hasPrefix("."), !isProtectedName(name) else { return nil }
            let url = desktopURL.appendingPathComponent(name, isDirectory: false)
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard let values,
                  values.isSymbolicLink != true,
                  values.isHidden != true,
                  values.isRegularFile == true || values.isDirectory == true,
                  !(values.isDirectory == true && fixedDesktopFolders.contains(name.lowercased())),
                  !isProtectedName(name) else { return nil }
            return DesktopFile(
                url: url,
                fileSize: values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate,
                isDirectory: values.isDirectory == true
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isProtectedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "desktop organisation log.md" { return true }
        return protectedTerms.contains(where: lower.contains)
    }
}

private struct MoveRecord {
    let source: URL
    let destination: URL
    let name: String
    let identity: FileIdentity?

    init(source: URL, destination: URL, name: String, identity: FileIdentity? = nil) {
        self.source = source
        self.destination = destination
        self.name = name
        self.identity = identity
    }
}

private struct DesktopSorterView: View {
    @State private var desktopURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    @State private var files: [DesktopFile] = []
    @State private var isLoadingDesktop = false
    @State private var desktopRefreshID = UUID()
    @State private var selectedFiles = Set<URL>()
    @State private var previewURL: URL?
    @State private var renamingFileURL: URL?
    @State private var renameText = ""
    @FocusState private var focusedRenameURL: URL?
    @State private var searchText = ""
    @State private var currentCoreFolder: CoreFolder?
    @State private var folderStack: [URL] = []
    @State private var destinationFolders: [URL] = []
    @State private var lastMoveBatch: [MoveRecord] = []
    @State private var statusMessage: String?
    @State private var alertTitle = "DustPan"
    @State private var alertMessage = ""
    @State private var showStatus = false
    @State private var desktopAccessAlert = false
    @AppStorage("dustpanHiddenItemPaths") private var hiddenItemPathsData = Data()
    @State private var showingHiddenItems = false

    private let fileManager = FileManager.default

    private var coreFolders: [CoreFolder] {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        return [
            CoreFolder(name: "01_University", icon: "graduationcap.fill", url: desktop.appendingPathComponent("01_University", isDirectory: true)),
            CoreFolder(name: "02_Career", icon: "person.crop.rectangle.stack.fill", url: desktop.appendingPathComponent("02_Career", isDirectory: true)),
            CoreFolder(name: "03_Personal", icon: "person.fill", url: desktop.appendingPathComponent("03_Personal", isDirectory: true)),
            CoreFolder(name: "04_Work", icon: "briefcase.fill", url: desktop.appendingPathComponent("04_Work", isDirectory: true))
        ]
    }

    private var visibleFiles: [DesktopFile] {
        let unhiddenFiles = files.filter { !hiddenItemPaths.contains($0.url.standardizedFileURL.path) }
        guard !searchText.isEmpty else { return unhiddenFiles }
        return unhiddenFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var hiddenItemPaths: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: hiddenItemPathsData)) ?? [])
    }

    private var hiddenItemURLs: [URL] {
        hiddenItemPaths.map { URL(fileURLWithPath: $0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var hiddenItemURLsInCurrentFolder: [URL] {
        hiddenItemURLs.filter {
            $0.deletingLastPathComponent().standardizedFileURL == desktopURL.standardizedFileURL
        }
    }

    private var hasHiddenItemsOnCurrentDesktop: Bool {
        files.contains { hiddenItemPaths.contains($0.url.standardizedFileURL.path) }
    }

    private var previewFile: DesktopFile? {
        guard let previewURL else { return nil }
        return files.first { $0.url == previewURL }
    }

    private var activeDestinationURL: URL? { folderStack.last ?? currentCoreFolder?.url }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                desktopPane
                    .frame(minWidth: 380, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                destinationsPane
                    .frame(minWidth: 360, idealWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refreshDesktop)
        .onChange(of: searchText) { _ in
            selectedFiles.formIntersection(Set(visibleFiles.map(\.url)))
        }
        .onChange(of: selectedFiles) { newSelection in
            if let previewURL, !newSelection.contains(previewURL) {
                self.previewURL = newSelection.first
            } else if previewURL == nil {
                previewURL = newSelection.first
            }
        }
        .alert(alertTitle, isPresented: $showStatus) {
            Button(desktopAccessAlert ? "Choose Desktop…" : "OK") {
                if desktopAccessAlert { chooseDesktopFolder() }
                desktopAccessAlert = false
            }
            if desktopAccessAlert {
                Button("Cancel", role: .cancel) { desktopAccessAlert = false }
            }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showingHiddenItems) {
            HiddenItemsSheet(items: hiddenItemURLs, onRestore: restoreHiddenItem)
                .frame(width: 560, height: 420)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.orange)
            Text("DustPan").font(.headline)
            Text("Sort your Desktop").foregroundStyle(.secondary)
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).lineLimit(1)
            }
            Spacer()
            if !hiddenItemPaths.isEmpty {
                Button { showingHiddenItems = true } label: {
                    Label("Hidden (\(hiddenItemPaths.count))", systemImage: "eye.slash")
                }
                .help("Manage items hidden from DustPan")
            }
            if !hiddenItemURLsInCurrentFolder.isEmpty {
                Button("Unhide all (\(hiddenItemURLsInCurrentFolder.count))", systemImage: "eye") {
                    restoreHiddenItemsInCurrentFolder()
                }
                .help("Unhide all items hidden from \(desktopURL.lastPathComponent)")
            }
            if !lastMoveBatch.isEmpty {
                Button("Undo last move") { undoLastMove() }
            }
            Button("Choose Desktop…") { chooseDesktopFolder() }
            Button { refreshDesktop() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var desktopPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(desktopURL.lastPathComponent == "Desktop" ? "Desktop" : desktopURL.lastPathComponent)
                        .font(.title2.bold())
                    Text(isLoadingDesktop
                         ? "Loading Desktop items…"
                         : "\(visibleFiles.count) items  ·  \(selectedFiles.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedFiles.isEmpty {
                    Button("Select all") { selectedFiles = Set(visibleFiles.map(\.url)) }
                        .disabled(visibleFiles.isEmpty)
                } else {
                    if selectedFiles.count == 1 {
                        Button("Rename", systemImage: "pencil") { beginRenamingSelectedFile() }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                    Button("Hide", systemImage: "eye.slash") { hideSelectedItems() }
                        .help("Hide selected items from DustPan. They will stay on your Desktop.")
                    Button("Clear selection") { selectedFiles.removeAll() }
                }
            }
            .padding(16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find files and folders", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            VSplitView {
                Group {
                    if isLoadingDesktop && files.isEmpty {
                        ProgressView("Loading Desktop…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if files.isEmpty {
                        emptyState(title: "Desktop is clear", detail: "Files and folders you can sort will appear here.", icon: "checkmark.circle")
                    } else if visibleFiles.isEmpty {
                        if searchText.isEmpty && hasHiddenItemsOnCurrentDesktop {
                            emptyState(title: "Everything is hidden", detail: "Use Hidden in the toolbar to show items again.", icon: "eye.slash")
                        } else {
                            emptyState(title: "No matches", detail: "Try a different file name.", icon: "magnifyingglass")
                        }
                    } else {
                        List(selection: $selectedFiles) {
                            ForEach(visibleFiles) { file in
                                DesktopFileRow(
                                    file: file,
                                    isRenaming: renamingFileURL == file.url,
                                    renameText: $renameText,
                                    focusedRenameURL: $focusedRenameURL,
                                    onRename: commitRename,
                                    onCancelRename: cancelRename
                                )
                                    .tag(file.url)
                                    .simultaneousGesture(TapGesture().onEnded { previewURL = file.url })
                                    .contextMenu {
                                        if selectedFiles.count == 1, selectedFiles.contains(file.url) {
                                            Button("Rename", systemImage: "pencil") { beginRenamingSelectedFile() }
                                        }
                                        Button("Hide from DustPan", systemImage: "eye.slash") { hideItem(file.url) }
                                        Button("Show in Finder", systemImage: "magnifyingglass") {
                                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                        }
                                    }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minHeight: 170, maxHeight: .infinity)

                previewPane
                    .frame(minHeight: 190, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("Core destinations, hidden items, and access-sensitive names are kept out of this list.")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Preview").font(.headline)
                if let previewFile {
                    Text(previewFile.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let previewFile {
                QuickLookFilePreview(url: previewFile.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState(
                    title: "Select a file to preview",
                    detail: "Click a file above to see it here.",
                    icon: "doc.text.magnifyingglass"
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var destinationsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: currentCoreFolder?.icon ?? "folder.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentCoreFolder?.name ?? "Your folders").font(.title2.bold())
                    Text(currentCoreFolder == nil
                         ? destinationHint
                         : "\(destinationPathDescription) · Click to move; double-click to open")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if currentCoreFolder != nil {
                    Button { goBack() } label: { Label("Folders", systemImage: "chevron.left") }
                        .labelStyle(.iconOnly)
                        .help("Back to the main folders")
                }
            }
            .padding(16)

            Divider()
            binDestinationRow
            Divider()

            if let currentCoreFolder {
                List {
                    ForEach(destinationFolders, id: \.self) { folder in
                        HStack(spacing: 11) {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(folder.lastPathComponent).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .gesture(folderClickGesture(
                            singleClick: { moveSelectedFiles(to: folder) },
                            doubleClick: { openFolder(folder) }
                        ))
                        .help("Click to move selected files here; double-click to open this folder")
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)

                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeDestinationURL?.lastPathComponent ?? currentCoreFolder.name)
                            .font(.subheadline.weight(.medium))
                        Text("Move into this folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(moveButtonTitle) { moveSelectedFiles() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedFiles.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
            } else {
                List {
                    ForEach(coreFolders) { folder in
                        let exists = fileManager.fileExists(atPath: folder.url.path)
                        let safeDestination = exists && DestinationPathSafety.isSafeDirectory(
                            folder.url,
                            under: folder.url.deletingLastPathComponent()
                        )
                        HStack(spacing: 13) {
                            Image(systemName: folder.icon)
                                .font(.system(size: 19))
                                .foregroundStyle(safeDestination ? .blue : .secondary)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name).font(.body.weight(.medium))
                                Text(safeDestination ? "Ready for filing" : (exists ? "Unsafe destination" : "Folder not found"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if safeDestination {
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .gesture(folderClickGesture(
                            singleClick: { if safeDestination { moveSelectedFiles(to: folder.url) } },
                            doubleClick: { if safeDestination { selectCoreFolder(folder) } }
                        ))
                        .help("Click to move selected files here; double-click to open this folder")
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .opacity(safeDestination ? 1 : 0.55)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var binDestinationRow: some View {
        Button { moveSelectedFilesToBin() } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bin").font(.body.weight(.medium))
                    Text(selectedFiles.isEmpty
                         ? "Select files to move them to the Bin"
                         : "Move \(selectedFiles.count) selected file\(selectedFiles.count == 1 ? "" : "s") to the Bin")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedFiles.isEmpty)
        .help("Move selected Desktop files to the Bin. Use Undo last move to restore them.")
        .accessibilityLabel("Move selected files to Bin")
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var moveButtonTitle: String {
        let count = selectedFiles.count
        return count == 1 ? "Move 1 file" : "Move \(count) files"
    }

    private func coreFolderRoot(containing destination: URL) -> URL? {
        let destinationPath = destination.standardizedFileURL.path
        return coreFolders.first { folder in
            let rootPath = folder.url.standardizedFileURL.path
            return destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/")
        }?.url
    }

    private var destinationPathDescription: String {
        guard let currentCoreFolder else { return "Choose where the selected files belong." }
        let destination = activeDestinationURL ?? currentCoreFolder.url
        let relativeComponents = destination.pathComponents.dropFirst(currentCoreFolder.url.pathComponents.count)
        return ([currentCoreFolder.name] + relativeComponents).joined(separator: " / ")
    }

    private var destinationHint: String {
        selectedFiles.isEmpty
            ? "Double-click a folder to browse."
            : "Click to move selected files; double-click to open a folder."
    }

    private func folderClickGesture(
        singleClick: @escaping () -> Void,
        doubleClick: @escaping () -> Void
    ) -> some Gesture {
        TapGesture(count: 2)
            .onEnded { _ in doubleClick() }
            .exclusively(before: TapGesture(count: 1).onEnded { _ in singleClick() })
    }

    private func selectCoreFolder(_ folder: CoreFolder) {
        guard DestinationPathSafety.isSafeDirectory(folder.url, under: folder.url.deletingLastPathComponent()) else { return }
        currentCoreFolder = folder
        folderStack = []
        refreshDestinationFolders()
    }

    private func openFolder(_ folder: URL) {
        folderStack.append(folder)
        refreshDestinationFolders()
    }

    private func goBack() {
        if !folderStack.isEmpty { folderStack.removeLast() }
        else { currentCoreFolder = nil }
        refreshDestinationFolders()
    }

    private func refreshDesktop() {
        let requestedURL = desktopURL
        let requestID = UUID()
        desktopRefreshID = requestID
        isLoadingDesktop = true

        // Desktop may be backed by iCloud or another file provider. Directory enumeration
        // can take a while, so keep it off the main thread to let the window draw and respond.
        Task {
            do {
                let loadedFiles = try await Task.detached(priority: .userInitiated) {
                    try DesktopDirectoryReader.read(from: requestedURL)
                }.value
                guard desktopRefreshID == requestID else { return }
                files = loadedFiles
                selectedFiles.formIntersection(Set(loadedFiles.map(\.url)))
                if let previewURL, !loadedFiles.contains(where: { $0.url == previewURL }) {
                    self.previewURL = nil
                }
                isLoadingDesktop = false
            } catch {
                guard desktopRefreshID == requestID else { return }
                isLoadingDesktop = false
                alertTitle = "Desktop access needed"
                alertMessage = "DustPan couldn't read the Desktop folder. Choose it in the folder picker to grant access."
                desktopAccessAlert = true
                showStatus = true
            }
        }
    }

    private func refreshDestinationFolders() {
        guard let root = activeDestinationURL,
              let currentCoreFolder,
              DestinationPathSafety.isSafeDirectory(root, under: currentCoreFolder.url) else {
            destinationFolders = []
            return
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        let children = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        destinationFolders = children.filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            return values?.isDirectory == true && values?.isHidden != true && values?.isSymbolicLink == false
                && !isProtectedName(url.lastPathComponent)
                && DestinationPathSafety.isSafeDirectory(url, under: currentCoreFolder.url)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isProtectedName(_ name: String) -> Bool {
        DesktopDirectoryReader.isProtectedName(name)
    }

    private func hideSelectedItems() {
        let selectedURLs = files.filter { selectedFiles.contains($0.url) }.map(\.url)
        guard !selectedURLs.isEmpty else { return }
        hideItems(selectedURLs)
    }

    private func hideItem(_ url: URL) {
        hideItems([url])
    }

    private func hideItems(_ urls: [URL]) {
        var paths = hiddenItemPaths
        let standardizedURLs = urls.map(\.standardizedFileURL)
        paths.formUnion(standardizedURLs.map(\.path))
        guard let data = try? JSONEncoder().encode(paths.sorted()) else {
            showError("DustPan couldn't save the hidden-items list. Nothing was changed.")
            return
        }
        hiddenItemPathsData = data
        selectedFiles.subtract(Set(standardizedURLs))
        if let renamingFileURL, standardizedURLs.contains(renamingFileURL.standardizedFileURL) {
            cancelRename()
        }
        if let previewURL, standardizedURLs.contains(previewURL.standardizedFileURL) {
            self.previewURL = nil
        }
        statusMessage = "Hidden \(urls.count) item\(urls.count == 1 ? "" : "s") from DustPan; still on your Desktop."
    }

    private func restoreHiddenItem(_ url: URL) {
        var paths = hiddenItemPaths
        paths.remove(url.standardizedFileURL.path)
        guard let data = try? JSONEncoder().encode(paths.sorted()) else {
            showError("DustPan couldn't update the hidden-items list.")
            return
        }
        hiddenItemPathsData = data
        statusMessage = "Shown \(url.lastPathComponent) in DustPan."
    }

    private func restoreHiddenItemsInCurrentFolder() {
        let currentFolderPath = desktopURL.standardizedFileURL.path
        var paths = hiddenItemPaths
        let pathsToRestore = paths.filter {
            URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path == currentFolderPath
        }
        guard !pathsToRestore.isEmpty else { return }
        paths.subtract(pathsToRestore)
        guard let data = try? JSONEncoder().encode(paths.sorted()) else {
            showError("DustPan couldn't update the hidden-items list.")
            return
        }
        hiddenItemPathsData = data
        statusMessage = "Unhid \(pathsToRestore.count) item\(pathsToRestore.count == 1 ? "" : "s") in \(desktopURL.lastPathComponent)."
    }

    private func moveSelectedFiles(to requestedDestination: URL? = nil) {
        guard !selectedFiles.isEmpty,
              let destination = requestedDestination ?? activeDestinationURL else { return }
        guard let coreRoot = coreFolderRoot(containing: destination),
              DestinationPathSafety.isSafeDirectory(destination, under: coreRoot) else {
            showError("That destination is unavailable or contains a symbolic link. No files were moved.")
            return
        }
        var completed: [MoveRecord] = []
        var problems: [String] = []
        for source in files.filter({ selectedFiles.contains($0.url) }).map(\.url) {
            guard DestinationPathSafety.isSafeDirectory(destination, under: coreRoot) else {
                problems.append("The destination changed or is no longer safe; remaining files were not moved.")
                break
            }
            guard source.deletingLastPathComponent().standardizedFileURL == desktopURL.standardizedFileURL,
                  fileManager.fileExists(atPath: source.path) else {
                problems.append("\(source.lastPathComponent): no longer available on the Desktop")
                continue
            }
            guard !isProtectedName(source.lastPathComponent) else {
                problems.append("A protected file was skipped.")
                continue
            }
            if files.first(where: { $0.url == source })?.isDirectory == true {
                let sourcePath = source.standardizedFileURL.path
                let destinationPath = destination.standardizedFileURL.path
                if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
                    problems.append("\(source.lastPathComponent): a folder can't be moved into itself or one of its own folders")
                    continue
                }
            }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else {
                problems.append("\(source.lastPathComponent): a file with that name already exists in the destination")
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: target)
                let identity = FileIdentity.read(at: target)
                if identity == nil {
                    problems.append("\(source.lastPathComponent): moved, but Undo is unavailable because the file identity could not be verified")
                }
                completed.append(MoveRecord(
                    source: source,
                    destination: target,
                    name: source.lastPathComponent,
                    identity: identity
                ))
            } catch {
                problems.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !completed.isEmpty {
            lastMoveBatch = completed.filter { $0.identity != nil }
        }
        selectedFiles.subtract(Set(completed.map { $0.source }))
        refreshDesktop()
        let logIssue = completed.isEmpty ? nil : appendLog(for: completed, heading: "DustPan manual filing")
        if !completed.isEmpty {
            statusMessage = "Moved \(completed.count) file\(completed.count == 1 ? "" : "s") to \(destination.lastPathComponent)."
        }
        var messages = problems
        if let logIssue { messages.append(logIssue) }
        if !messages.isEmpty { showError(messages.joined(separator: "\n")) }
    }

    private func moveSelectedFilesToBin() {
        guard !selectedFiles.isEmpty else { return }
        var completed: [MoveRecord] = []
        var problems: [String] = []
        for source in files.filter({ selectedFiles.contains($0.url) }).map(\.url) {
            guard source.deletingLastPathComponent().standardizedFileURL == desktopURL.standardizedFileURL,
                  fileManager.fileExists(atPath: source.path) else {
                problems.append("\(source.lastPathComponent): no longer available on the Desktop")
                continue
            }
            guard !isProtectedName(source.lastPathComponent) else {
                problems.append("A protected file was skipped.")
                continue
            }
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: source, resultingItemURL: &resultingURL)
                guard let resultingURL else {
                    problems.append("\(source.lastPathComponent): moved to the Bin, but its new location couldn't be recorded for Undo")
                    continue
                }
                let identity = FileIdentity.read(at: resultingURL as URL)
                completed.append(MoveRecord(
                    source: source,
                    destination: resultingURL as URL,
                    name: source.lastPathComponent,
                    identity: identity
                ))
                if identity == nil {
                    problems.append("\(source.lastPathComponent): moved to the Bin, but Undo is unavailable because the file identity could not be verified")
                }
            } catch {
                problems.append("\(source.lastPathComponent): couldn't move to the Bin — \(error.localizedDescription)")
            }
        }
        if !completed.isEmpty {
            lastMoveBatch = completed.filter { $0.identity != nil }
            selectedFiles.subtract(Set(completed.map { $0.source }))
            refreshDesktop()
            let logIssue = appendLog(for: completed, heading: "DustPan moved files to Bin")
            statusMessage = "Moved \(completed.count) file\(completed.count == 1 ? "" : "s") to the Bin."
            if let logIssue { problems.append(logIssue) }
        }
        if !problems.isEmpty { showError(problems.joined(separator: "\n")) }
    }

    private func beginRenamingSelectedFile() {
        guard selectedFiles.count == 1,
              let source = selectedFiles.first,
              let file = files.first(where: { $0.url == source }) else { return }
        renamingFileURL = source
        renameText = file.isDirectory || source.pathExtension.isEmpty
            ? file.name
            : source.deletingPathExtension().lastPathComponent
        focusedRenameURL = source
    }

    private func cancelRename() {
        renamingFileURL = nil
        focusedRenameURL = nil
        renameText = ""
    }

    private func commitRename() {
        guard let source = renamingFileURL else { return }
        let newBaseName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newBaseName.isEmpty,
              newBaseName != ".",
              newBaseName != "..",
              !newBaseName.contains("/") else {
            cancelRename()
            showError("That name isn't valid. The original file was kept.")
            return
        }
        guard source.deletingLastPathComponent().standardizedFileURL == desktopURL.standardizedFileURL,
              fileManager.fileExists(atPath: source.path),
              !isProtectedName(source.lastPathComponent) else {
            cancelRename()
            showError("The selected file is no longer available to rename.")
            return
        }

        let isDirectory = files.first(where: { $0.url == source })?.isDirectory == true
        let newName = isDirectory || source.pathExtension.isEmpty
            ? newBaseName
            : "\(newBaseName).\(source.pathExtension)"
        guard !isProtectedName(newName) else {
            cancelRename()
            showError("That name is reserved. The original file was kept.")
            return
        }
        let target = source.deletingLastPathComponent().appendingPathComponent(newName)
        if target.standardizedFileURL == source.standardizedFileURL {
            cancelRename()
            return
        }
        guard !fileManager.fileExists(atPath: target.path) else {
            cancelRename()
            showError("A file with that name already exists on the Desktop. The original was kept.")
            return
        }

        do {
            try fileManager.moveItem(at: source, to: target)
            selectedFiles.remove(source)
            selectedFiles.insert(target)
            if previewURL == source { previewURL = target }
            let logIssue = appendLog(
                for: [MoveRecord(source: source, destination: target, name: newName)],
                heading: "DustPan manual rename"
            )
            statusMessage = "Renamed to \(newName)."
            cancelRename()
            refreshDesktop()
            if let logIssue { showError(logIssue) }
        } catch {
            cancelRename()
            showError("The file couldn't be renamed: \(error.localizedDescription)")
        }
    }

    private func undoLastMove() {
        var undone: [MoveRecord] = []
        var problems: [String] = []
        var staleDestinations = Set<URL>()
        for record in lastMoveBatch.reversed() {
            guard fileManager.fileExists(atPath: record.destination.path) else {
                problems.append("\(record.name): no longer in the folder it was moved to")
                staleDestinations.insert(record.destination)
                continue
            }
            guard let expectedIdentity = record.identity,
                  FileIdentity.read(at: record.destination) == expectedIdentity else {
                problems.append("\(record.name): the moved item changed or could not be verified; Undo left it untouched")
                staleDestinations.insert(record.destination)
                continue
            }
            guard !fileManager.fileExists(atPath: record.source.path) else {
                problems.append("\(record.name): a file with that name now exists on the Desktop")
                continue
            }
            do {
                try fileManager.moveItem(at: record.destination, to: record.source)
                undone.append(record)
            } catch {
                problems.append("\(record.name): \(error.localizedDescription)")
            }
        }
        let undoneDestinations = Set(undone.map(\.destination))
        lastMoveBatch.removeAll {
            undoneDestinations.contains($0.destination) || staleDestinations.contains($0.destination)
        }
        if !undone.isEmpty {
            refreshDesktop()
        }
        let reverseRecords = undone.map { MoveRecord(source: $0.destination, destination: $0.source, name: $0.name) }
        let logIssue = undone.isEmpty ? nil : appendLog(for: reverseRecords, heading: "DustPan undo")
        if !undone.isEmpty {
            statusMessage = "Put \(undone.count) file\(undone.count == 1 ? "" : "s") back on the Desktop."
        }
        var messages = problems
        if let logIssue { messages.append(logIssue) }
        if !messages.isEmpty { showError(messages.joined(separator: "\n")) }
    }

    private func appendLog(for records: [MoveRecord], heading: String) -> String? {
        let logURL = desktopURL.appendingPathComponent("Desktop Organisation Log.md")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = formatter.string(from: Date())
        var section = "\n## \(date) — \(heading)\n\n"
        for record in records {
            section += "- \(record.source.path) → \(record.destination.path)\n"
        }
        do {
            if let values = try? logURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                return "DustPan refused to write through a symbolic link at the organisation log path."
            }
            if !fileManager.fileExists(atPath: logURL.path) {
                try section.write(to: logURL, atomically: true, encoding: .utf8)
            } else {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(section.utf8))
            }
        } catch {
            return "The file changes succeeded, but DustPan couldn't append the organisation log: \(error.localizedDescription)"
        }
        return nil
    }

    private func chooseDesktopFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Desktop folder"
        panel.prompt = "Use Desktop"
        panel.directoryURL = desktopURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            desktopURL = url
            refreshDesktop()
        }
    }

    private func showError(_ message: String) {
        alertTitle = "Some files need attention"
        alertMessage = message
        desktopAccessAlert = false
        showStatus = true
    }

    private func emptyState(title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DesktopFileRow: View {
    let file: DesktopFile
    let isRenaming: Bool
    @Binding var renameText: String
    var focusedRenameURL: FocusState<URL?>.Binding
    let onRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 24, height: 24)
            if isRenaming {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        TextField("File name", text: $renameText)
                            .textFieldStyle(.plain)
                            .focused(focusedRenameURL, equals: file.url)
                            .onSubmit(onRename)
                            .onExitCommand(perform: onCancelRename)
                            .accessibilityLabel("New file name")
                        if !file.isDirectory && !file.url.pathExtension.isEmpty {
                            Text(".\(file.url.pathExtension)").foregroundStyle(.secondary)
                        }
                    }
                    Text("Press Rename or Return to save · Esc to cancel")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { focusedRenameURL.wrappedValue = file.url }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.isDirectory
                         ? "Folder"
                         : file.kind + "  ·  " + file.fileSize.formatted(.byteCount(style: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if isRenaming {
                Button("Rename", action: onRename)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Save this new name")
                Button(action: onCancelRename) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel renaming")
                .accessibilityLabel("Cancel renaming")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct HiddenItemsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let items: [URL]
    let onRestore: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hidden from DustPan").font(.title2.bold())
                    Text("These items stay on your Desktop. Show one again to return it to the list.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eye").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("No hidden items").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, id: \.self) { item in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                            .resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.lastPathComponent).lineLimit(1)
                            Text(item.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Show again") { onRestore(item) }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.autostarts = true
        preview.previewItem = url as NSURL
        return preview
    }

    func updateNSView(_ preview: QLPreviewView, context: Context) {
        guard preview.previewItem?.previewItemURL != url else { return }
        preview.previewItem = url as NSURL
    }

    static func dismantleNSView(_ preview: QLPreviewView, coordinator: ()) {
        preview.close()
    }
}
