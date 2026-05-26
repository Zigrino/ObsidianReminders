import Combine
import Foundation

struct TaskFileSelection: Identifiable, Hashable {
    let url: URL

    var id: String {
        url.standardizedFileURL.path
    }

    var name: String {
        url.lastPathComponent
    }

    var path: String {
        url.path(percentEncoded: false)
    }
}

@MainActor
final class SyncViewModel: ObservableObject {
    @Published private(set) var dailyNotesFolderURL: URL?
    @Published private(set) var taskFileURLs: [URL] = []
    @Published var reminderListName: String {
        didSet {
            defaults.set(reminderListName, forKey: DefaultsKey.reminderListName)
        }
    }
    @Published var isContinuousSyncEnabled: Bool {
        didSet {
            defaults.set(isContinuousSyncEnabled, forKey: DefaultsKey.continuousSyncEnabled)
            configureContinuousSync(runImmediately: isContinuousSyncEnabled)
        }
    }
    @Published private(set) var tasks: [ObsidianTask] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Select a daily notes folder or task files."
    @Published private(set) var remindersStatus = "not checked"
    @Published private(set) var continuousSyncStatus = "Auto sync off"
    @Published private(set) var lastSummary: ReminderSyncSummary?

    private enum DefaultsKey {
        static let dailyNotesFolderBookmark = "dailyNotesFolderBookmark"
        static let todoFileBookmark = "todoFileBookmark"
        static let taskFileBookmarks = "taskFileBookmarks"
        static let reminderListName = "reminderListName"
        static let continuousSyncEnabled = "continuousSyncEnabled"
        static let syncedReminderTaskIDs = "syncedReminderTaskIDs"
        static let deletedReminderTaskTitlesByID = "deletedReminderTaskTitlesByID"
    }

    private enum SyncTrigger {
        case manual
        case continuous
    }

    private struct DeletedReminderFilterResult {
        let tasksToSync: [ObsidianTask]
        let skippedCount: Int
        let deletedTaskIDs: Set<String>
    }

    private let defaults: UserDefaults
    private let parser = ObsidianTaskParser()
    private let completionWriter = ObsidianTaskCompletionWriter()
    private let reminderSyncService = ReminderSyncService()
    private static let continuousSyncIntervalNanoseconds: UInt64 = 60 * 1_000_000_000
    private static let continuousSyncTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
    private var continuousSyncTask: Task<Void, Never>?
    private var lastContinuousSyncDate: Date?
    private var continuousSyncNeedsAttention = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reminderListName = defaults.string(forKey: DefaultsKey.reminderListName) ?? "Obsidian"
        self.isContinuousSyncEnabled = defaults.object(forKey: DefaultsKey.continuousSyncEnabled) as? Bool ?? true
        restoreBookmarks()
        refreshRemindersStatus()
        scanNow()
        configureContinuousSync(runImmediately: true)
    }

    deinit {
        continuousSyncTask?.cancel()
    }

    var dailyNotesFolderLabel: String {
        dailyNotesFolderURL?.path(percentEncoded: false) ?? "No folder selected"
    }

    var taskFilesLabel: String {
        taskFileURLs.isEmpty ? "No files selected" : "\(taskFileURLs.count) file\(taskFileURLs.count == 1 ? "" : "s") selected"
    }

    var taskFileSelections: [TaskFileSelection] {
        taskFileURLs.map(TaskFileSelection.init)
    }

    var canSync: Bool {
        !isWorking && (!tasks.isEmpty || hasSelectedSources)
    }

    private var hasSelectedSources: Bool {
        dailyNotesFolderURL != nil || !taskFileURLs.isEmpty
    }

    func selectDailyNotesFolder(_ url: URL) {
        storeSelection(url, defaultsKey: DefaultsKey.dailyNotesFolderBookmark) {
            dailyNotesFolderURL = url
        }
    }

    func addTaskFiles(_ urls: [URL]) {
        let newURLs = urls.filter { $0.pathExtension.lowercased() == "md" }
        guard !newURLs.isEmpty else { return }

        do {
            let existingPaths = Set(taskFileURLs.map { $0.standardizedFileURL.path })
            let uniqueNewURLs = newURLs.filter { !existingPaths.contains($0.standardizedFileURL.path) }
            guard !uniqueNewURLs.isEmpty else { return }

            let updatedURLs = taskFileURLs + uniqueNewURLs
            try saveTaskFileBookmarks(for: updatedURLs)
            taskFileURLs = updatedURLs
            scanNow()
            kickContinuousSyncIfNeeded()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearDailyNotesFolder() {
        defaults.removeObject(forKey: DefaultsKey.dailyNotesFolderBookmark)
        dailyNotesFolderURL = nil
        scanNow()
        updateContinuousSyncStatus()
    }

    func removeTaskFile(_ selection: TaskFileSelection) {
        let updatedURLs = taskFileURLs.filter { $0.standardizedFileURL.path != selection.id }
        do {
            try saveTaskFileBookmarks(for: updatedURLs)
            taskFileURLs = updatedURLs
            scanNow()
            updateContinuousSyncStatus()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearTaskFiles() {
        defaults.removeObject(forKey: DefaultsKey.todoFileBookmark)
        defaults.removeObject(forKey: DefaultsKey.taskFileBookmarks)
        taskFileURLs = []
        scanNow()
        updateContinuousSyncStatus()
    }

    func scanNow() {
        guard hasSelectedSources else {
            tasks = []
            statusMessage = "Select a daily notes folder or task files."
            updateContinuousSyncStatus()
            return
        }

        do {
            tasks = try loadTasks()
            lastSummary = nil
            statusMessage = "\(tasks.count) Obsidian tasks found."
        } catch {
            tasks = []
            statusMessage = error.localizedDescription
        }

        updateContinuousSyncStatus()
    }

    func syncNow() async {
        await performSync(trigger: .manual)
    }

    private func performSync(trigger: SyncTrigger) async {
        guard hasSelectedSources else {
            statusMessage = "Select a daily notes folder or task files."
            updateContinuousSyncStatus()
            return
        }

        guard !isWorking else { return }

        isWorking = true
        if trigger == .continuous {
            continuousSyncStatus = "Auto sync running..."
        }
        defer {
            isWorking = false
            refreshRemindersStatus()
            updateContinuousSyncStatus()
        }

        do {
            let loadedTasks = try loadTasks()
            let snapshotResult = try await reminderSyncService.taskSnapshotResult(
                inListNamed: sanitizedReminderListName
            )
            let writeSummary = try writeReminderChangesToObsidian(
                tasks: loadedTasks,
                reminderSnapshots: snapshotResult.snapshots
            )
            let tasksToSync = writeSummary.total > 0 ? try loadTasks() : loadedTasks
            tasks = tasksToSync
            let obsidianDeletedTaskIDs = taskIDsDeletedFromObsidian(
                tasks: tasksToSync,
                reminderSnapshots: snapshotResult.snapshots,
                reminderListExists: snapshotResult.listExists
            )
            let deletedFromRemindersTaskIDs = try await reminderSyncService.deleteReminders(
                taskIDs: obsidianDeletedTaskIDs,
                listName: sanitizedReminderListName
            )
            let deletionFilter = filterTasksDeletedFromReminders(
                tasks: tasksToSync,
                reminderSnapshots: snapshotResult.snapshots,
                reminderListExists: snapshotResult.listExists
            )

            var summary = try await reminderSyncService.sync(
                tasks: deletionFilter.tasksToSync,
                listName: sanitizedReminderListName
            )
            summary.skippedDeleted = deletionFilter.skippedCount
            summary.deletedFromReminders = deletedFromRemindersTaskIDs.count
            rememberSyncedReminderTaskIDs(
                summary.syncedTaskIDs,
                currentTaskIDs: Set(tasksToSync.map(\.id)),
                deletedTaskIDs: deletionFilter.deletedTaskIDs
            )
            lastSummary = summary
            let pulledPrefix = statusPrefix(for: writeSummary)
            let messagePrefix = trigger == .continuous ? "Auto sync complete" : "Sync complete"
            statusMessage = summary.failed == 0
                ? "\(messagePrefix): \(pulledPrefix)\(summary.headline)."
                : "\(messagePrefix): \(pulledPrefix)\(summary.headline), \(summary.failed) failed."
            if trigger == .continuous {
                lastContinuousSyncDate = Date()
                continuousSyncNeedsAttention = summary.failed > 0
            }
        } catch {
            statusMessage = error.localizedDescription
            if trigger == .continuous {
                continuousSyncNeedsAttention = true
            }
        }
    }

    private func configureContinuousSync(runImmediately: Bool = false) {
        continuousSyncTask?.cancel()
        continuousSyncTask = nil
        continuousSyncNeedsAttention = false
        updateContinuousSyncStatus()

        guard isContinuousSyncEnabled else { return }

        continuousSyncTask = Task { [weak self] in
            if runImmediately {
                await self?.runContinuousSyncCycle()
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.continuousSyncIntervalNanoseconds)
                } catch {
                    return
                }

                await self?.runContinuousSyncCycle()
            }
        }
    }

    private func runContinuousSyncCycle() async {
        guard isContinuousSyncEnabled else { return }
        guard hasSelectedSources else {
            updateContinuousSyncStatus()
            return
        }
        guard !isWorking else {
            updateContinuousSyncStatus()
            return
        }

        await performSync(trigger: .continuous)
    }

    private func updateContinuousSyncStatus() {
        guard isContinuousSyncEnabled else {
            continuousSyncStatus = "Auto sync off"
            return
        }

        guard hasSelectedSources else {
            continuousSyncStatus = "Auto sync waiting for sources"
            return
        }

        if isWorking {
            continuousSyncStatus = "Auto sync running..."
        } else if continuousSyncNeedsAttention {
            continuousSyncStatus = "Auto sync needs attention"
        } else if let lastContinuousSyncDate {
            continuousSyncStatus = "Auto synced \(Self.continuousSyncTimeFormatter.string(from: lastContinuousSyncDate))"
        } else {
            continuousSyncStatus = "Auto sync on"
        }
    }

    private func kickContinuousSyncIfNeeded() {
        guard isContinuousSyncEnabled else {
            updateContinuousSyncStatus()
            return
        }

        configureContinuousSync(runImmediately: true)
    }

    private func taskIDsDeletedFromObsidian(
        tasks: [ObsidianTask],
        reminderSnapshots: [String: ReminderTaskSnapshot],
        reminderListExists: Bool
    ) -> Set<String> {
        guard reminderListExists else { return [] }

        let currentTaskIDs = Set(tasks.map(\.id))
        let reminderTaskIDs = Set(reminderSnapshots.keys)

        return selectedSourceSyncedTaskIDs()
            .subtracting(currentTaskIDs)
            .intersection(reminderTaskIDs)
    }

    private func selectedSourceSyncedTaskIDs() -> Set<String> {
        Set(storedSyncedReminderTaskIDs().filter { taskID in
            isSourceSelected(forTaskID: taskID)
        })
    }

    private func isSourceSelected(forTaskID taskID: String) -> Bool {
        if taskID.hasPrefix("\(ObsidianTask.Source.dailyNote.rawValue):") {
            return dailyNotesFolderURL != nil
        }

        if taskID.hasPrefix("\(ObsidianTask.Source.todoFile.rawValue):") {
            return selectedTaskFileIDPrefixes().contains { taskID.hasPrefix($0) }
        }

        return true
    }

    private func selectedTaskFileIDPrefixes() -> [String] {
        parser.taskFileRelativePaths(for: taskFileURLs).map {
            "\(ObsidianTask.Source.todoFile.rawValue):\($0):"
        }
    }

    private func filterTasksDeletedFromReminders(
        tasks: [ObsidianTask],
        reminderSnapshots: [String: ReminderTaskSnapshot],
        reminderListExists: Bool
    ) -> DeletedReminderFilterResult {
        let tasksByID = tasks.reduce(into: [String: ObsidianTask]()) { partialResult, task in
            partialResult[task.id] = task
        }
        let currentTaskIDs = Set(tasksByID.keys)
        let reminderTaskIDs = Set(reminderSnapshots.keys)
        let knownSyncedTaskIDs = storedSyncedReminderTaskIDs().intersection(currentTaskIDs)
        var deletedTaskTitlesByID = storedDeletedReminderTaskTitlesByID().filter { taskID, title in
            tasksByID[taskID]?.title == title
        }

        if reminderListExists {
            let deletedInReminders = knownSyncedTaskIDs.subtracting(reminderTaskIDs)
            for taskID in deletedInReminders {
                guard let task = tasksByID[taskID] else { continue }
                deletedTaskTitlesByID[taskID] = task.title
            }

            for taskID in reminderTaskIDs {
                deletedTaskTitlesByID.removeValue(forKey: taskID)
            }
        }

        saveDeletedReminderTaskTitlesByID(deletedTaskTitlesByID)

        let tasksToSync = tasks.filter { task in
            deletedTaskTitlesByID[task.id] != task.title
        }
        let deletedTaskIDs = Set(deletedTaskTitlesByID.keys).intersection(currentTaskIDs)

        return DeletedReminderFilterResult(
            tasksToSync: tasksToSync,
            skippedCount: tasks.count - tasksToSync.count,
            deletedTaskIDs: deletedTaskIDs
        )
    }

    private func rememberSyncedReminderTaskIDs(
        _ taskIDs: Set<String>,
        currentTaskIDs: Set<String>,
        deletedTaskIDs: Set<String>
    ) {
        var knownTaskIDs = storedSyncedReminderTaskIDs()
        knownTaskIDs.formUnion(taskIDs)
        knownTaskIDs.formIntersection(currentTaskIDs)
        knownTaskIDs.subtract(deletedTaskIDs)
        saveSyncedReminderTaskIDs(knownTaskIDs)
    }

    private func storedSyncedReminderTaskIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: listScopedDefaultsKey(DefaultsKey.syncedReminderTaskIDs)) ?? [])
    }

    private func saveSyncedReminderTaskIDs(_ taskIDs: Set<String>) {
        defaults.set(taskIDs.sorted(), forKey: listScopedDefaultsKey(DefaultsKey.syncedReminderTaskIDs))
    }

    private func storedDeletedReminderTaskTitlesByID() -> [String: String] {
        defaults.dictionary(forKey: listScopedDefaultsKey(DefaultsKey.deletedReminderTaskTitlesByID)) as? [String: String] ?? [:]
    }

    private func saveDeletedReminderTaskTitlesByID(_ taskTitlesByID: [String: String]) {
        defaults.set(taskTitlesByID, forKey: listScopedDefaultsKey(DefaultsKey.deletedReminderTaskTitlesByID))
    }

    private func listScopedDefaultsKey(_ key: String) -> String {
        "\(key).\(sanitizedReminderListName)"
    }

    private var sanitizedReminderListName: String {
        let trimmed = reminderListName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Obsidian" : trimmed
    }

    private func restoreBookmarks() {
        dailyNotesFolderURL = resolveBookmark(forKey: DefaultsKey.dailyNotesFolderBookmark)
        taskFileURLs = resolveTaskFileBookmarks()
    }

    private func resolveBookmark(forKey key: String) -> URL? {
        guard let bookmarkData = defaults.data(forKey: key) else {
            return nil
        }

        do {
            var isStale = false
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }

            if isStale {
                try saveBookmark(for: url, defaultsKey: key)
            }

            return url
        } catch {
            defaults.removeObject(forKey: key)
            statusMessage = "Could not restore a saved file selection."
            return nil
        }
    }

    private func storeSelection(_ url: URL, defaultsKey: String, update: () -> Void) {
        do {
            try saveBookmark(for: url, defaultsKey: defaultsKey)
            update()
            scanNow()
            kickContinuousSyncIfNeeded()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func resolveTaskFileBookmarks() -> [URL] {
        if let bookmarkDataList = defaults.array(forKey: DefaultsKey.taskFileBookmarks) as? [Data] {
            return bookmarkDataList.compactMap(resolveBookmark)
        }

        if let legacyTodoFile = resolveBookmark(forKey: DefaultsKey.todoFileBookmark) {
            do {
                try saveTaskFileBookmarks(for: [legacyTodoFile])
                defaults.removeObject(forKey: DefaultsKey.todoFileBookmark)
            } catch {
                statusMessage = error.localizedDescription
            }

            return [legacyTodoFile]
        }

        return []
    }

    private func resolveBookmark(_ bookmarkData: Data) -> URL? {
        do {
            var isStale = false
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }

            return url
        } catch {
            statusMessage = "Could not restore a saved file selection."
            return nil
        }
    }

    private func saveTaskFileBookmarks(for urls: [URL]) throws {
        guard !urls.isEmpty else {
            defaults.removeObject(forKey: DefaultsKey.taskFileBookmarks)
            return
        }

        let bookmarkDataList = try urls.map { try bookmarkData(for: $0) }
        defaults.set(bookmarkDataList, forKey: DefaultsKey.taskFileBookmarks)
        defaults.removeObject(forKey: DefaultsKey.todoFileBookmark)
    }

    private func saveBookmark(for url: URL, defaultsKey: String) throws {
        defaults.set(try bookmarkData(for: url), forKey: defaultsKey)
    }

    private func bookmarkData(for url: URL) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        return bookmarkData
    }

    private func loadTasks() throws -> [ObsidianTask] {
        let didAccessDailyNotes = dailyNotesFolderURL?.startAccessingSecurityScopedResource() ?? false
        let accessedTaskFiles = taskFileURLs.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            if didAccessDailyNotes {
                dailyNotesFolderURL?.stopAccessingSecurityScopedResource()
            }
            for (url, didAccess) in accessedTaskFiles where didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try parser.loadTasks(
            dailyNotesFolder: dailyNotesFolderURL,
            taskFiles: taskFileURLs
        )
    }

    private func writeReminderChangesToObsidian(
        tasks: [ObsidianTask],
        reminderSnapshots: [String: ReminderTaskSnapshot]
    ) throws -> ObsidianTaskWriteSummary {
        let didAccessDailyNotes = dailyNotesFolderURL?.startAccessingSecurityScopedResource() ?? false
        let accessedTaskFiles = taskFileURLs.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            if didAccessDailyNotes {
                dailyNotesFolderURL?.stopAccessingSecurityScopedResource()
            }
            for (url, didAccess) in accessedTaskFiles where didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try completionWriter.applyReminderSnapshots(reminderSnapshots, to: tasks)
    }

    private func statusPrefix(for summary: ObsidianTaskWriteSummary) -> String {
        var parts: [String] = []
        if summary.checkedOff > 0 {
            parts.append("\(summary.checkedOff) checked in Obsidian")
        }
        if summary.renamed > 0 {
            parts.append("\(summary.renamed) renamed in Obsidian")
        }

        return parts.isEmpty ? "" : "\(parts.joined(separator: ", ")), "
    }

    private func refreshRemindersStatus() {
        remindersStatus = reminderSyncService.authorizationStatusText()
    }
}
