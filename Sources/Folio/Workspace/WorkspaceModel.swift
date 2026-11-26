import AppKit
import FolioKit
import SwiftUI

/// Where the workspace is pointed: a sidebar destination or a folder inside one.
enum Destination: Hashable {
    case home, recent, favorites, tools
    case folder(URL)
}

/// Grid of cards or a sortable table; remembered across launches.
enum ViewMode: String, CaseIterable {
    case grid, list
    static let key = "workspace.viewMode"
}

/// A short message at the bottom of the window, with an optional Undo.
struct Toast: Identifiable {
    let id = UUID()
    let message: String
    var undo: (() -> Void)?
}

/// State and actions of the Folio workspace window: navigation, the file lists behind
/// each destination, selection, and every file operation the menus, context menus,
/// keyboard and command palette trigger.
///
/// One instance for the app (the workspace is a single `Window` scene), so menu commands
/// work even before the window first appears. Nothing here touches the disk on the main
/// thread: listings and metadata load in detached tasks and land here afterwards, so the
/// window always draws immediately with whatever is known so far.
@Observable
final class WorkspaceModel {
    static let shared = WorkspaceModel()

    @ObservationIgnored private let log = Log.make("Workspace")

    // MARK: Navigation

    private(set) var destination: Destination = .home
    private var backStack: [Destination] = []
    private var forwardStack: [Destination] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: Lists

    private(set) var recent: [FileItem] = []
    private(set) var favorites: [FileItem] = []
    private(set) var folderItems: [FileItem] = []
    /// The folder `folderItems` belongs to, so a stale listing never shows under another folder.
    private(set) var listedFolder: URL?
    private(set) var libraryURL = Library.url
    private(set) var libraryItems: [FileItem] = []
    private(set) var locations: [URL] = []
    private(set) var freeSpace: (available: Int64, total: Int64)?
    /// True until the first Recent results land, to show placeholders instead of "empty".
    private(set) var loadingRecent = true

    // MARK: View state

    var query = ""
    var filter = KindFilter.all
    var sort = FileSort.lastOpened
    var ascending = false
    var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: ViewMode.key) ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: ViewMode.key) }
    }
    var selection: Set<URL> = [] {
        didSet { QuickLook.shared.follow(selectedItems.map(\.url)) }
    }
    /// The item being renamed inline, if any.
    var renaming: URL?
    /// Set by the search field; menu shortcuts that would eat typing check it.
    var isSearchFocused = false
    var showsPalette = false
    var toast: Toast?
    /// Asked of the view to focus the search field (⌘F).
    var searchFocusRequest = 0

    var isEditingText: Bool { isSearchFocused || renaming != nil || showsPalette }

    // MARK: Environment hooks set by the window

    /// SwiftUI's `openDocument`, so files open through the right `DocumentGroup`.
    @ObservationIgnored var openDocumentAction: OpenDocumentAction?
    @ObservationIgnored weak var undoManager: UndoManager?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var recentSearch: SpotlightSearch?
    @ObservationIgnored private var favoriteSearch: SpotlightSearch?
    @ObservationIgnored private var spotlightRecent: [URL: Date?] = [:]
    @ObservationIgnored private var spotlightFavorites: Set<URL> = []
    @ObservationIgnored private var libraryWatcher: FolderWatcher?
    @ObservationIgnored private var folderWatcher: FolderWatcher?
    @ObservationIgnored private var recentGeneration = 0
    @ObservationIgnored private var appsByExtension: [String: [URL]] = [:]

    private init() {}

    // MARK: - Derived lists

    /// Everything the current destination could show, before search and filters.
    var sourceItems: [FileItem] {
        switch destination {
        case .home, .recent: recent
        case .favorites: favorites
        case .folder: folderItems
        case .tools: []
        }
    }

    /// What the current view shows: searched, filtered and sorted.
    var visibleItems: [FileItem] {
        let items = FileQuery.apply(sourceItems, query: query, filter: filter, sort: sort, ascending: ascending)
        return destination == .home ? Array(items.prefix(12)) : items
    }

    var selectedItems: [FileItem] {
        let all = recent + favorites + folderItems
        var seen = Set<URL>()
        return all.filter { selection.contains($0.url) && seen.insert($0.url).inserted }
    }

    /// The sidebar root (library or a location) that contains the current folder.
    var currentRoot: URL? {
        guard case .folder(let url) = destination else { return nil }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return ([libraryURL] + locations).first { root in
            let rootPath = root.standardizedFileURL.path(percentEncoded: false)
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    var title: String {
        switch destination {
        case .home: "Home"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .tools: "Tools"
        case .folder(let url): url == libraryURL ? "Library" : FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        }
    }

    /// Breadcrumbs from the sidebar root down to the current folder.
    var breadcrumbs: [URL] {
        guard case .folder(let url) = destination, let root = currentRoot else { return [] }
        var out = [url]
        var cursor = url
        while cursor.standardizedFileURL != root.standardizedFileURL, cursor.pathComponents.count > 1 {
            cursor = cursor.deletingLastPathComponent()
            out.insert(cursor, at: 0)
        }
        return out
    }

    func displayName(_ url: URL) -> String {
        url.standardizedFileURL == libraryURL.standardizedFileURL
            ? "Library" : FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }

    // MARK: - Lifecycle

    /// Starts every background source once, after the window's first frame.
    func start() {
        guard !started else { return }
        started = true
        locations = Library.isIsolated ? [] : Locations.load()
        watchLibrary()
        refreshRecent()
        startSpotlight()
        refreshFreeSpace()
    }

    private func startSpotlight() {
        // In isolated mode (tests, snapshots) keep every query inside the library folder.
        let scopes: [Any] = Library.isIsolated ? [libraryURL] : [NSMetadataQueryUserHomeScope]
        recentSearch = SpotlightSearch(predicate: SpotlightSearch.recentPredicate(), scopes: scopes) { [weak self] results in
            self?.spotlightRecent = Dictionary(results.map { ($0.url.standardizedFileURL, $0.lastUsed) }) { a, _ in a }
            self?.refreshRecent()
        }
        favoriteSearch = SpotlightSearch(predicate: SpotlightSearch.favoritesPredicate, scopes: scopes) { [weak self] results in
            self?.spotlightFavorites = Set(results.map(\.url.standardizedFileURL))
            self?.refreshFavorites()
        }
        recentSearch?.start()
        favoriteSearch?.start()
    }

    private func watchLibrary() {
        libraryWatcher?.cancel()
        libraryWatcher = FolderWatcher(libraryURL) { [weak self] in self?.refreshLibrary() }
        refreshLibrary()
    }

    // MARK: - Loading

    /// Re-lists the library root (sidebar count, Recent and Favorites inputs).
    func refreshLibrary() {
        let url = libraryURL
        Task {
            let items = await Self.list(url)
            guard url == libraryURL else { return }
            libraryItems = items
            if libraryWatcher == nil, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                libraryWatcher = FolderWatcher(url) { [weak self] in self?.refreshLibrary() }
            }
            if listedFolder == url { folderItems = items }
            refreshRecent()
            refreshFavorites()
        }
    }

    /// Merges Open Recent, Spotlight and recently changed library files into Recent.
    func refreshRecent() {
        var dates: [URL: Date?] = spotlightRecent
        if !Library.isIsolated {
            for url in NSDocumentController.shared.recentDocumentURLs where dates[url.standardizedFileURL] == nil {
                dates[url.standardizedFileURL] = .some(nil)
            }
        }
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        for item in libraryItems where !item.isFolder && item.modified > monthAgo && dates[item.url.standardizedFileURL] == nil {
            dates[item.url.standardizedFileURL] = .some(nil)
        }
        recentGeneration += 1
        let generation = recentGeneration
        let snapshot = dates
        Task {
            let items = await Self.load(snapshot)
            guard generation == recentGeneration else { return }
            recent = FileSort.lastOpened.sorted(items.filter { !$0.isFolder }, ascending: false)
            loadingRecent = false
        }
    }

    /// Favorites: Spotlight's tagged files plus any tagged file already listed (Spotlight
    /// can lag behind a new tag, and doesn't index every folder).
    func refreshFavorites() {
        var urls = spotlightFavorites
        for item in libraryItems + folderItems + recent where item.isFavorite { urls.insert(item.url.standardizedFileURL) }
        let snapshot = Dictionary(urls.map { ($0, Date?.none) }) { a, _ in a }
        Task {
            let items = await Self.load(snapshot)
            favorites = FileSort.lastOpened.sorted(items.filter(\.isFavorite), ascending: false)
        }
    }

    private func loadFolder(_ url: URL) {
        folderWatcher?.cancel()
        folderWatcher = url == libraryURL ? nil : FolderWatcher(url) { [weak self] in self?.reloadFolder() }
        if listedFolder != url {
            folderItems = url == libraryURL ? libraryItems : []
            listedFolder = url
        }
        reloadFolder()
    }

    private func reloadFolder() {
        guard case .folder(let url) = destination else { return }
        Task {
            let items = await Self.list(url)
            guard destination == .folder(url) else { return }
            folderItems = items
            selection = selection.filter { s in items.contains { $0.url == s } }
        }
    }

    func refreshFreeSpace() {
        let url = libraryURL.deletingLastPathComponent()
        Task {
            freeSpace = await Self.capacity(of: url)
        }
    }

    /// After any change Folio makes itself: watchers catch most, this catches the rest
    /// (tags, files outside watched folders).
    private func refreshAll() {
        refreshLibrary()
        reloadFolder()
        refreshFreeSpace()
    }

    nonisolated private static func list(_ folder: URL) async -> [FileItem] {
        FileItem.list(folder: folder)
    }

    nonisolated private static func load(_ urls: [URL: Date?]) async -> [FileItem] {
        urls.compactMap { url, date in SpotlightSearch.isNoise(url) ? nil : FileItem.load(url, lastUsed: date) }
    }

    nonisolated private static func capacity(of url: URL) async -> (Int64, Int64)? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    // MARK: - Navigation

    func go(_ new: Destination) {
        guard new != destination else { return }
        backStack.append(destination)
        forwardStack.removeAll()
        show(new)
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(destination)
        show(previous)
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(destination)
        show(next)
    }

    func goToLibrary() {
        do {
            libraryURL = try Library.ensureExists()
            if libraryWatcher == nil { watchLibrary() }
            go(.folder(libraryURL))
        } catch {
            Alert.show(error, title: "Couldn't create the Folio library folder")
        }
    }

    private func show(_ new: Destination) {
        withAnimation(Hero.animation) {
            destination = new
            query = ""
            filter = .all
            selection = []
            renaming = nil
        }
        if case .folder(let url) = new { loadFolder(url) } else { folderWatcher?.cancel() }
    }

    // MARK: - Opening

    /// Folders navigate; files open in their Folio editor.
    func open(_ items: [FileItem]) {
        if items.count == 1, let folder = items.first, folder.isFolder {
            go(.folder(folder.url))
            return
        }
        for item in items where !item.isFolder { openFile(item.url) }
    }

    func openSelection() { open(selectedItems) }

    func openFile(_ url: URL) {
        Task {
            do {
                if let openDocumentAction {
                    try await openDocumentAction(at: url)
                } else {
                    _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
                }
                // The system list feeds Open Recent and our Recent view.
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                log.error("Couldn't open file: \(error.localizedDescription, privacy: .public)")
                Alert.show(error, title: "Couldn't open “\(url.lastPathComponent)”")
            }
        }
    }

    func showOpenPanel() { NSDocumentController.shared.openDocument(nil) }

    /// Apps other than Folio that can open `item`, for Open With ›. Cached per extension
    /// because the context menu is rebuilt for every card.
    func otherApps(for item: FileItem) -> [URL] {
        let ext = item.url.pathExtension.lowercased()
        if let cached = appsByExtension[ext] { return cached }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url).filter { $0 != Bundle.main.bundleURL }
        appsByExtension[ext] = Array(apps.prefix(12))
        return appsByExtension[ext] ?? []
    }

    func open(_ items: [FileItem], withApp app: URL) {
        NSWorkspace.shared.open(items.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Creating

    /// Writes a new empty file and opens it: in the folder being viewed when there is one
    /// and `inCurrentFolder` is set, otherwise in the library.
    func create(_ new: NewFile, inCurrentFolder: Bool = true) {
        do {
            let folder: URL
            if inCurrentFolder, case .folder(let url) = destination {
                folder = url
            } else {
                folder = try Library.ensureExists()
            }
            let url = try new.create(in: folder)
            log.info("Created a new \(new.rawValue, privacy: .public) file")
            refreshAll()
            openFile(url)
        } catch {
            Alert.show(error, title: "Couldn't create a new \(new.title.lowercased())")
        }
    }

    // MARK: - File operations

    func quickLook() { QuickLook.shared.toggle(selectedItems.filter { !$0.isFolder }.map(\.url)) }

    func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url)) }

    func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedItems.map { $0.url.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
        show(Toast(message: selectedItems.count == 1 ? "Copied path" : "Copied \(selectedItems.count) paths"))
    }

    func beginRename() {
        guard let item = selectedItems.first, selectedItems.count == 1 else { return }
        renaming = item.url
    }

    func rename(_ item: FileItem, to input: String) {
        renaming = nil
        guard let target = FileNaming.renamed(item.url, to: input, isFolder: item.isFolder), target != item.url else {
            if FileNaming.renamed(item.url, to: input, isFolder: item.isFolder) == nil, input != item.baseName {
                Alert.show(FolioError("Names can't be empty, start with a dot, or contain “/” or “:”."), title: "Couldn't rename")
            }
            return
        }
        guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            Alert.show(FolioError("An item named “\(target.lastPathComponent)” already exists here."), title: "Couldn't rename")
            return
        }
        move([(item.url, target)], actionName: "Rename")
        selection = [target]
    }

    func duplicate() {
        var copies: [URL] = []
        for item in selectedItems {
            let ext = item.isFolder ? "" : item.url.pathExtension
            let target = FolioTool.unique(in: item.url.deletingLastPathComponent(), name: "\(item.baseName) copy", ext: ext)
            do {
                try FileManager.default.copyItem(at: item.url, to: target)
                copies.append(target)
            } catch {
                Alert.show(error, title: "Couldn't duplicate “\(item.name)”")
            }
        }
        guard !copies.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.trash(copies, announce: false) }
        }
        undoManager?.setActionName("Duplicate")
        selection = Set(copies)
        refreshAll()
    }

    func toggleFavorite() {
        let items = selectedItems.filter { !$0.isFolder }
        let makeFavorite = !items.allSatisfy(\.isFavorite)
        setFavorite(makeFavorite, items.map(\.url))
    }

    func setFavorite(_ favorite: Bool, _ urls: [URL]) {
        for url in urls {
            do {
                try Favorites.set(favorite, for: url)
                if favorite {
                    spotlightFavorites.insert(url.standardizedFileURL)
                } else {
                    spotlightFavorites.remove(url.standardizedFileURL)
                }
            } catch {
                Alert.show(error, title: "Couldn't change the favorite tag")
            }
        }
        // Flip the star right away; listings catch up in the background.
        func flip(_ list: inout [FileItem]) {
            for i in list.indices where urls.contains(list[i].url) { list[i].isFavorite = favorite }
        }
        flip(&recent)
        flip(&folderItems)
        flip(&libraryItems)
        if !favorite { favorites.removeAll { urls.contains($0.url) } }
        refreshFavorites()
    }

    /// Move the selection into `folder`.
    func moveSelection(to folder: URL) {
        let pairs = selectedItems.filter { $0.url.deletingLastPathComponent() != folder }.map { item in
            (item.url, FolioTool.unique(in: folder, name: item.baseName, ext: item.isFolder ? "" : item.url.pathExtension))
        }
        move(pairs, actionName: "Move")
    }

    /// Moves items and registers the reverse move with Undo (rename, Move to ›, put back).
    func move(_ pairs: [(from: URL, to: URL)], actionName: String) {
        var done: [(from: URL, to: URL)] = []
        for pair in pairs {
            do {
                try FileManager.default.moveItem(at: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                Alert.show(error, title: "Couldn't move “\(pair.from.lastPathComponent)”")
            }
        }
        guard !done.isEmpty else { return }
        let reverse = done.map { (from: $0.to, to: $0.from) }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.move(reverse, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        refreshAll()
    }

    func trashSelection() { trash(selectedItems.map(\.url), announce: true) }

    /// Moves to the Trash (never deletes), with Undo in the toast and in Edit › Undo.
    func trash(_ urls: [URL], announce: Bool) {
        guard !urls.isEmpty else { return }
        Task {
            do {
                let trashed = try await NSWorkspace.shared.recycle(urls)
                let putBack = trashed.map { (from: $0.value, to: $0.key) }
                undoManager?.registerUndo(withTarget: self) { model in
                    MainActor.assumeIsolated { model.move(putBack, actionName: "Move to Trash") }
                }
                undoManager?.setActionName("Move to Trash")
                selection = []
                refreshAll()
                if announce {
                    let message =
                        urls.count == 1 ? "Moved “\(urls[0].lastPathComponent)” to the Trash" : "Moved \(urls.count) items to the Trash"
                    show(Toast(message: message) { [weak self] in self?.undoOrPutBack(putBack) })
                }
            } catch {
                Alert.show(error, title: "Couldn't move to the Trash")
            }
        }
    }

    private func undoOrPutBack(_ putBack: [(from: URL, to: URL)]) {
        if let undoManager, undoManager.canUndo, undoManager.undoActionName == "Move to Trash" {
            undoManager.undo()
        } else {
            move(putBack, actionName: "Move to Trash")
        }
        toast = nil
    }

    /// Files dropped on a folder view: copied in (⌥ moves them, as in Finder).
    func importFiles(_ urls: [URL], into folder: URL, move shouldMove: Bool) {
        let pairs = urls.filter { $0.deletingLastPathComponent() != folder }.map { url in
            (from: url, to: FolioTool.unique(in: folder, name: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension))
        }
        if shouldMove {
            move(pairs, actionName: "Move")
            return
        }
        for pair in pairs {
            do {
                try FileManager.default.copyItem(at: pair.from, to: pair.to)
            } catch {
                Alert.show(error, title: "Couldn't copy “\(pair.from.lastPathComponent)”")
            }
        }
        refreshAll()
    }

    func runTool(_ tool: FolioTool, on items: [FileItem]) {
        ToolRunner.shared.start(tool, inputs: items.map(\.url))
    }

    /// Tools that take every selected file, for the Tools › submenu.
    func tools(for items: [FileItem]) -> [FolioTool] {
        guard !items.isEmpty, items.allSatisfy({ !$0.isFolder }) else { return [] }
        return ToolCatalog.all.filter { tool in items.count >= tool.minimumInputs && items.allSatisfy { tool.accepts($0.url) } }
    }

    // MARK: - Selection

    /// Click, ⌘-click and ⇧-click, the way Finder treats them.
    func click(_ item: FileItem, in items: [FileItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
        } else if flags.contains(.shift), let anchor = items.firstIndex(where: { selection.contains($0.url) }),
            let target = items.firstIndex(of: item)
        {
            let range = min(anchor, target)...max(anchor, target)
            selection = Set(items[range].map(\.url))
        } else {
            selection = [item.url]
        }
        renaming = nil
    }

    /// Arrow keys in the grid: move the selection by `offset` cards.
    func moveSelection(by offset: Int, in items: [FileItem]) {
        guard !items.isEmpty else { return }
        let current = items.lastIndex { selection.contains($0.url) }
        let next = current.map { min(max(0, $0 + offset), items.count - 1) } ?? 0
        selection = [items[next].url]
    }

    // MARK: - Library and locations

    func setLibrary(_ url: URL) {
        UserDefaults.standard.set(url.path(percentEncoded: false), forKey: Library.pathKey)
        libraryURL = Library.url
        watchLibrary()
        refreshFreeSpace()
    }

    func addLocationWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to show in the Folio sidebar."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.addLocations(panel.urls) }
        }
    }

    func addLocations(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let new = folders.filter { url in !locations.contains(url) && url != libraryURL }
        guard !new.isEmpty else { return }
        locations += new
        Locations.save(locations)
    }

    func removeLocation(_ url: URL) {
        locations.removeAll { $0 == url }
        Locations.save(locations)
        if currentRoot == url { go(.home) }
    }

    // MARK: - Toasts

    func show(_ toast: Toast) {
        withAnimation(Hero.animation) { self.toast = toast }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if self.toast?.id == toast.id { withAnimation(Hero.animation) { self.toast = nil } }
        }
    }
}

/// The workspace model of the key window, for ``WorkspaceCommands``.
struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}
