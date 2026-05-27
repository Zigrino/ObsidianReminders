import Combine
import Foundation

struct TaskFileSelection: Identifiable, Hashable {
    let url: URL
    let reminderListName: String
    let draftReminderListName: String
    let hasPendingReminderListChange: Bool

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
    @Published private var taskFileReminderListNamesByPath: [String: String] = [:]
    @Published private var taskFileReminderListNameDraftsByPath: [String: String] = [:]
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
    @Published var clearsOldDailyNotes: Bool {
        didSet {
            defaults.set(clearsOldDailyNotes, forKey: DefaultsKey.clearsOldDailyNotes)
            scanNow()
            kickContinuousSyncIfNeeded()
        }
    }
    @Published var hidesCompletedTasks: Bool {
        didSet {
            defaults.set(hidesCompletedTasks, forKey: DefaultsKey.hidesCompletedTasks)
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
        static let taskFileReminderListNamesByPath = "taskFileReminderListNamesByPath"
        static let reminderListName = "reminderListName"
        static let knownReminderListNames = "knownReminderListNames"
        static let continuousSyncEnabled = "continuousSyncEnabled"
        static let clearsOldDailyNotes = "clearsOldDailyNotes"
        static let hidesCompletedTasks = "hidesCompletedTasks"
        static let syncedReminderTaskIDs = "syncedReminderTaskIDs"
        static let deletedReminderTaskTitlesByID = "deletedReminderTaskTitlesByID"
        static let manuallyExcludedReminderTaskTitlesByID = "manuallyExcludedReminderTaskTitlesByID"
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

    private struct OldDailyTaskFilterResult {
        let tasksToSync: [ObsidianTask]
        let skippedTasks: [ObsidianTask]
    }

    private let defaults: UserDefaults
    private let parser = ObsidianTaskParser()
    private let completionWriter = ObsidianTaskCompletionWriter()
    private let reminderSyncService = ReminderSyncService()
    private let calendar = Calendar.current
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
        self.clearsOldDailyNotes = defaults.object(forKey: DefaultsKey.clearsOldDailyNotes) as? Bool ?? false
        self.hidesCompletedTasks = defaults.object(forKey: DefaultsKey.hidesCompletedTasks) as? Bool ?? false
        self.taskFileReminderListNamesByPath = defaults.dictionary(forKey: DefaultsKey.taskFileReminderListNamesByPath) as? [String: String] ?? [:]
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
        taskFileURLs.map { url in
            let reminderListName = reminderListName(forTaskFile: url)
            let draftReminderListName = draftReminderListName(forTaskFile: url)
            return TaskFileSelection(
                url: url,
                reminderListName: reminderListName,
                draftReminderListName: draftReminderListName,
                hasPendingReminderListChange: draftReminderListName != reminderListName
            )
        }
    }

    var visibleTasks: [ObsidianTask] {
        hidesCompletedTasks ? tasks.filter { !$0.isCompleted } : tasks
    }

    var hasPendingTaskFileReminderListChanges: Bool {
        taskFileURLs.contains { url in
            let path = url.standardizedFileURL.path
            guard let draftReminderListName = taskFileReminderListNameDraftsByPath[path] else {
                return false
            }

            return draftReminderListName != reminderListName(forTaskFile: url)
        }
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
            taskFileReminderListNamesByPath.removeValue(forKey: selection.id)
            taskFileReminderListNameDraftsByPath.removeValue(forKey: selection.id)
            saveTaskFileReminderListNames()
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
        defaults.removeObject(forKey: DefaultsKey.taskFileReminderListNamesByPath)
        taskFileReminderListNamesByPath = [:]
        taskFileReminderListNameDraftsByPath = [:]
        taskFileURLs = []
        scanNow()
        updateContinuousSyncStatus()
    }

    func setDraftReminderListName(_ listName: String, for selection: TaskFileSelection) {
        if listName == reminderListName(forTaskFile: selection.url) {
            taskFileReminderListNameDraftsByPath.removeValue(forKey: selection.id)
        } else {
            taskFileReminderListNameDraftsByPath[selection.id] = listName
        }
    }

    func applyTaskFileReminderListChanges() {
        guard hasPendingTaskFileReminderListChanges else {
            taskFileReminderListNameDraftsByPath = [:]
            return
        }

        let defaultListName = sanitizedReminderListName
        var changedEffectiveList = false

        for taskFileURL in taskFileURLs {
            let path = taskFileURL.standardizedFileURL.path
            guard let draftReminderListName = taskFileReminderListNameDraftsByPath[path] else {
                continue
            }

            let previousReminderListName = reminderListName(forTaskFile: taskFileURL)
            let nextReminderListName = sanitizedListName(draftReminderListName)
            changedEffectiveList = changedEffectiveList || nextReminderListName != previousReminderListName

            if nextReminderListName == defaultListName {
                taskFileReminderListNamesByPath.removeValue(forKey: path)
            } else {
                taskFileReminderListNamesByPath[path] = nextReminderListName
            }
        }

        taskFileReminderListNameDraftsByPath = [:]
        saveTaskFileReminderListNames()
        scanNow()
        statusMessage = changedEffectiveList ? "Applied task file list changes." : "No task file list changes to apply."

        if changedEffectiveList {
            kickContinuousSyncIfNeeded()
        } else {
            updateContinuousSyncStatus()
        }
    }

    func scanNow() {
        guard hasSelectedSources else {
            tasks = []
            statusMessage = "Select a daily notes folder or task files."
            updateContinuousSyncStatus()
            return
        }

        do {
            let loadedTasks = try loadTasks()
            let oldDailyFilter = filterOldDailyTasks(loadedTasks)
            tasks = oldDailyFilter.tasksToSync
            lastSummary = nil
            if oldDailyFilter.skippedTasks.isEmpty {
                statusMessage = "\(tasks.count) Obsidian tasks found."
            } else {
                statusMessage = "\(tasks.count) active Obsidian tasks found, \(oldDailyFilter.skippedTasks.count) old daily skipped."
            }
        } catch {
            tasks = []
            statusMessage = error.localizedDescription
        }

        updateContinuousSyncStatus()
    }

    func syncNow() async {
        await performSync(trigger: .manual)
    }

    func syncStatusLabel(for task: ObsidianTask) -> String {
        isTaskExcludedFromSync(task) ? "Excluded" : "Included"
    }

    func syncStatusSystemImage(for task: ObsidianTask) -> String {
        isTaskExcludedFromSync(task) ? "nosign" : "arrow.triangle.2.circlepath"
    }

    func syncStatusHelp(for task: ObsidianTask) -> String {
        isTaskExcludedFromSync(task)
            ? "Include this task in future syncs"
            : "Exclude this task and remove its Reminder"
    }

    func isTaskExcludedFromSync(_ task: ObsidianTask) -> Bool {
        excludedTaskTitle(for: task) == task.title
    }

    func toggleSyncExclusion(for task: ObsidianTask) async {
        let listName = reminderListName(for: task)
        let postScanStatusMessage: String

        if isTaskExcludedFromSync(task) {
            var manuallyExcludedTaskTitlesByID = storedManuallyExcludedReminderTaskTitlesByID(in: listName)
            manuallyExcludedTaskTitlesByID.removeValue(forKey: task.id)
            saveManuallyExcludedReminderTaskTitlesByID(manuallyExcludedTaskTitlesByID, in: listName)

            var deletedTaskTitlesByID = storedDeletedReminderTaskTitlesByID(in: listName)
            deletedTaskTitlesByID.removeValue(forKey: task.id)
            saveDeletedReminderTaskTitlesByID(deletedTaskTitlesByID, in: listName)
            postScanStatusMessage = "Included in sync; it will be recreated in Reminders on the next sync."
        } else {
            do {
                let deletedTaskIDs = try await reminderSyncService.deleteReminders(
                    taskIDs: [task.id],
                    listName: listName
                )
                var deletedTaskTitlesByID = storedDeletedReminderTaskTitlesByID(in: listName)
                deletedTaskTitlesByID[task.id] = task.title
                saveDeletedReminderTaskTitlesByID(deletedTaskTitlesByID, in: listName)

                var manuallyExcludedTaskTitlesByID = storedManuallyExcludedReminderTaskTitlesByID(in: listName)
                manuallyExcludedTaskTitlesByID.removeValue(forKey: task.id)
                saveManuallyExcludedReminderTaskTitlesByID(manuallyExcludedTaskTitlesByID, in: listName)

                postScanStatusMessage = deletedTaskIDs.isEmpty
                    ? "Excluded from sync; no matching Reminder was found to remove."
                    : "Excluded from sync and removed from Reminders."
            } catch {
                statusMessage = error.localizedDescription
                updateContinuousSyncStatus()
                return
            }
        }

        scanNow()
        statusMessage = postScanStatusMessage
        kickContinuousSyncIfNeeded()
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
            let initialOldDailyFilter = filterOldDailyTasks(loadedTasks)
            var listNames = reminderListNames(for: loadedTasks)
            listNames.formUnion(selectedSourceReminderListNames())
            listNames.formUnion(storedKnownReminderListNames())
            var snapshotResults = try await taskSnapshotResults(for: listNames)
            let writeCandidateTasks = initialOldDailyFilter.tasksToSync.filter {
                !isTaskExcludedFromSync($0)
            }
            let reminderSnapshots = routedReminderSnapshots(
                from: snapshotResults,
                tasks: writeCandidateTasks
            )
            let writeSummary = try writeReminderChangesToObsidian(
                tasks: writeCandidateTasks,
                reminderSnapshots: reminderSnapshots
            )
            let tasksToSync = writeSummary.total > 0 ? try loadTasks() : loadedTasks
            let oldDailyFilter = filterOldDailyTasks(tasksToSync)
            tasks = oldDailyFilter.tasksToSync

            listNames.formUnion(reminderListNames(for: tasksToSync))
            listNames.formUnion(selectedSourceReminderListNames())
            listNames.formUnion(storedKnownReminderListNames())
            snapshotResults = try await taskSnapshotResults(for: listNames)

            var summary = ReminderSyncSummary()
            for listName in listNames.sorted() {
                let snapshotResult = snapshotResults[listName] ?? ReminderTaskSnapshotResult(
                    listExists: false,
                    snapshots: [:]
                )
                let allTasksForList = tasksToSync.filter { reminderListName(for: $0) == listName }
                let activeTasksForList = oldDailyFilter.tasksToSync.filter { reminderListName(for: $0) == listName }
                let oldDailyTasksForList = oldDailyFilter.skippedTasks.filter { reminderListName(for: $0) == listName }
                let clearedOldDailyTaskIDs = try await reminderSyncService.deleteReminders(
                    taskIDs: Set(oldDailyTasksForList.map(\.id)),
                    listName: listName
                )
                let obsidianDeletedTaskIDs = taskIDsDeletedFromObsidian(
                    tasks: allTasksForList,
                    reminderSnapshots: snapshotResult.snapshots,
                    reminderListExists: snapshotResult.listExists,
                    listName: listName
                )
                let deletedFromRemindersTaskIDs = try await reminderSyncService.deleteReminders(
                    taskIDs: obsidianDeletedTaskIDs,
                    listName: listName
                )
                let exclusionFilter = filterTasksExcludedFromSync(
                    trackedTasks: allTasksForList,
                    syncCandidateTasks: activeTasksForList,
                    reminderSnapshots: snapshotResult.snapshots,
                    reminderListExists: snapshotResult.listExists,
                    listName: listName
                )

                var listSummary = ReminderSyncSummary()
                if snapshotResult.listExists || !exclusionFilter.tasksToSync.isEmpty {
                    listSummary = try await reminderSyncService.sync(
                        tasks: exclusionFilter.tasksToSync,
                        listName: listName
                    )
                }
                listSummary.skippedDeleted = exclusionFilter.skippedCount
                listSummary.deletedFromReminders = deletedFromRemindersTaskIDs.count
                listSummary.clearedOldDailyNotes = clearedOldDailyTaskIDs.count
                listSummary.skippedOldDailyNotes = oldDailyTasksForList.count
                rememberSyncedReminderTaskIDs(
                    listSummary.syncedTaskIDs,
                    currentTaskIDs: Set(activeTasksForList.map(\.id)),
                    deletedTaskIDs: exclusionFilter.deletedTaskIDs
                        .union(deletedFromRemindersTaskIDs)
                        .union(clearedOldDailyTaskIDs),
                    listName: listName
                )
                summary.merge(listSummary)
            }
            saveKnownReminderListNames(retainedReminderListNames(from: listNames, currentTasks: tasksToSync))

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
        reminderListExists: Bool,
        listName: String
    ) -> Set<String> {
        guard reminderListExists else { return [] }

        let currentTaskIDs = Set(tasks.map(\.id))
        let reminderTaskIDs = Set(reminderSnapshots.keys)

        return selectedSourceSyncedTaskIDs(in: listName)
            .subtracting(currentTaskIDs)
            .intersection(reminderTaskIDs)
    }

    private func selectedSourceSyncedTaskIDs(in listName: String) -> Set<String> {
        Set(storedSyncedReminderTaskIDs(in: listName).filter { taskID in
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

    private func filterOldDailyTasks(_ tasks: [ObsidianTask]) -> OldDailyTaskFilterResult {
        guard clearsOldDailyNotes else {
            return OldDailyTaskFilterResult(tasksToSync: tasks, skippedTasks: [])
        }

        let now = Date()
        let skippedTasks = tasks.filter { isOldDailyTask($0, now: now) }
        let skippedTaskIDs = Set(skippedTasks.map(\.id))
        let tasksToSync = tasks.filter { !skippedTaskIDs.contains($0.id) }

        return OldDailyTaskFilterResult(tasksToSync: tasksToSync, skippedTasks: skippedTasks)
    }

    private func isOldDailyTask(_ task: ObsidianTask, now: Date) -> Bool {
        guard task.source == .dailyNote, let dailyNoteDate = task.dailyNoteDate else {
            return false
        }

        let todayStart = calendar.startOfDay(for: now)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            return false
        }

        let noteDay = calendar.startOfDay(for: dailyNoteDate)
        if noteDay < yesterdayStart {
            return true
        }

        guard calendar.isDate(noteDay, inSameDayAs: yesterdayStart) else {
            return false
        }

        var cutoffComponents = calendar.dateComponents([.year, .month, .day], from: todayStart)
        cutoffComponents.hour = 8
        cutoffComponents.minute = 0
        cutoffComponents.second = 0
        let yesterdayClearCutoff = calendar.date(from: cutoffComponents) ?? todayStart

        return now >= yesterdayClearCutoff
    }

    private func reminderListNames(for tasks: [ObsidianTask]) -> Set<String> {
        Set(tasks.map { reminderListName(for: $0) })
    }

    private func selectedSourceReminderListNames() -> Set<String> {
        var listNames: Set<String> = []

        if dailyNotesFolderURL != nil {
            listNames.insert(sanitizedReminderListName)
        }

        for taskFileURL in taskFileURLs {
            listNames.insert(reminderListName(forTaskFile: taskFileURL))
        }

        return listNames
    }

    private func reminderListName(for task: ObsidianTask) -> String {
        switch task.source {
        case .dailyNote:
            return sanitizedReminderListName
        case .todoFile:
            return reminderListName(forTaskFile: task.fileURL)
        }
    }

    private func reminderListName(forTaskFile url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let listName = taskFileReminderListNamesByPath[path] else {
            return sanitizedReminderListName
        }

        return sanitizedListName(listName)
    }

    private func draftReminderListName(forTaskFile url: URL) -> String {
        let path = url.standardizedFileURL.path
        return taskFileReminderListNameDraftsByPath[path] ?? reminderListName(forTaskFile: url)
    }

    private func taskSnapshotResults(
        for listNames: Set<String>
    ) async throws -> [String: ReminderTaskSnapshotResult] {
        var results: [String: ReminderTaskSnapshotResult] = [:]
        for listName in listNames {
            results[listName] = try await reminderSyncService.taskSnapshotResult(inListNamed: listName)
        }

        return results
    }

    private func routedReminderSnapshots(
        from results: [String: ReminderTaskSnapshotResult],
        tasks: [ObsidianTask]
    ) -> [String: ReminderTaskSnapshot] {
        tasks.reduce(into: [:]) { partialResult, task in
            let listName = reminderListName(for: task)
            if let snapshot = results[listName]?.snapshots[task.id] {
                partialResult[task.id] = snapshot
            }
        }
    }

    private func retainedReminderListNames(
        from listNames: Set<String>,
        currentTasks: [ObsidianTask]
    ) -> Set<String> {
        var retainedListNames = selectedSourceReminderListNames()
        retainedListNames.formUnion(reminderListNames(for: currentTasks))

        for listName in listNames {
            if !storedSyncedReminderTaskIDs(in: listName).isEmpty
                || !storedDeletedReminderTaskTitlesByID(in: listName).isEmpty
                || !storedManuallyExcludedReminderTaskTitlesByID(in: listName).isEmpty {
                retainedListNames.insert(listName)
            }
        }

        return retainedListNames
    }

    private func filterTasksExcludedFromSync(
        trackedTasks: [ObsidianTask],
        syncCandidateTasks: [ObsidianTask],
        reminderSnapshots: [String: ReminderTaskSnapshot],
        reminderListExists: Bool,
        listName: String
    ) -> DeletedReminderFilterResult {
        let tasksByID = trackedTasks.reduce(into: [String: ObsidianTask]()) { partialResult, task in
            partialResult[task.id] = task
        }
        let currentTaskIDs = Set(tasksByID.keys)
        let syncCandidateTaskIDs = Set(syncCandidateTasks.map(\.id))
        let reminderTaskIDs = Set(reminderSnapshots.keys)
        let knownSyncedTaskIDs = storedSyncedReminderTaskIDs(in: listName).intersection(currentTaskIDs)
        let manuallyExcludedTaskTitlesByID = storedManuallyExcludedReminderTaskTitlesByID(in: listName).filter { taskID, title in
            tasksByID[taskID]?.title == title
        }
        var deletedTaskTitlesByID = storedDeletedReminderTaskTitlesByID(in: listName).filter { taskID, title in
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

        saveDeletedReminderTaskTitlesByID(deletedTaskTitlesByID, in: listName)
        saveManuallyExcludedReminderTaskTitlesByID(manuallyExcludedTaskTitlesByID, in: listName)

        let excludedTaskTitlesByID = manuallyExcludedTaskTitlesByID.merging(deletedTaskTitlesByID) { manual, _ in
            manual
        }

        let tasksToSync = syncCandidateTasks.filter { task in
            excludedTaskTitlesByID[task.id] != task.title
        }
        let deletedTaskIDs = Set(deletedTaskTitlesByID.keys)
            .intersection(currentTaskIDs)
            .intersection(syncCandidateTaskIDs)

        return DeletedReminderFilterResult(
            tasksToSync: tasksToSync,
            skippedCount: syncCandidateTasks.count - tasksToSync.count,
            deletedTaskIDs: deletedTaskIDs
        )
    }

    private func rememberSyncedReminderTaskIDs(
        _ taskIDs: Set<String>,
        currentTaskIDs: Set<String>,
        deletedTaskIDs: Set<String>,
        listName: String
    ) {
        var knownTaskIDs = storedSyncedReminderTaskIDs(in: listName)
        knownTaskIDs.formUnion(taskIDs)
        knownTaskIDs.formIntersection(currentTaskIDs)
        knownTaskIDs.subtract(deletedTaskIDs)
        saveSyncedReminderTaskIDs(knownTaskIDs, in: listName)
    }

    private func storedSyncedReminderTaskIDs(in listName: String) -> Set<String> {
        Set(defaults.stringArray(forKey: listScopedDefaultsKey(DefaultsKey.syncedReminderTaskIDs, listName: listName)) ?? [])
    }

    private func saveSyncedReminderTaskIDs(_ taskIDs: Set<String>, in listName: String) {
        defaults.set(taskIDs.sorted(), forKey: listScopedDefaultsKey(DefaultsKey.syncedReminderTaskIDs, listName: listName))
    }

    private func storedDeletedReminderTaskTitlesByID(in listName: String) -> [String: String] {
        defaults.dictionary(forKey: listScopedDefaultsKey(DefaultsKey.deletedReminderTaskTitlesByID, listName: listName)) as? [String: String] ?? [:]
    }

    private func saveDeletedReminderTaskTitlesByID(_ taskTitlesByID: [String: String], in listName: String) {
        saveTaskTitlesByID(taskTitlesByID, key: DefaultsKey.deletedReminderTaskTitlesByID, listName: listName)
    }

    private func storedManuallyExcludedReminderTaskTitlesByID(in listName: String) -> [String: String] {
        defaults.dictionary(forKey: listScopedDefaultsKey(DefaultsKey.manuallyExcludedReminderTaskTitlesByID, listName: listName)) as? [String: String] ?? [:]
    }

    private func saveManuallyExcludedReminderTaskTitlesByID(_ taskTitlesByID: [String: String], in listName: String) {
        saveTaskTitlesByID(taskTitlesByID, key: DefaultsKey.manuallyExcludedReminderTaskTitlesByID, listName: listName)
    }

    private func saveTaskTitlesByID(_ taskTitlesByID: [String: String], key: String, listName: String) {
        let defaultsKey = listScopedDefaultsKey(key, listName: listName)
        if taskTitlesByID.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(taskTitlesByID, forKey: defaultsKey)
        }
    }

    private func listScopedDefaultsKey(_ key: String, listName: String) -> String {
        "\(key).\(listName)"
    }

    private func excludedTaskTitle(for task: ObsidianTask) -> String? {
        let listName = reminderListName(for: task)
        if let title = storedManuallyExcludedReminderTaskTitlesByID(in: listName)[task.id] {
            return title
        }

        return storedDeletedReminderTaskTitlesByID(in: listName)[task.id]
    }

    private func storedKnownReminderListNames() -> Set<String> {
        Set((defaults.stringArray(forKey: DefaultsKey.knownReminderListNames) ?? []).map(sanitizedListName))
    }

    private func saveKnownReminderListNames(_ listNames: Set<String>) {
        let cleanedListNames = Set(listNames.map(sanitizedListName))
        if cleanedListNames.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.knownReminderListNames)
        } else {
            defaults.set(cleanedListNames.sorted(), forKey: DefaultsKey.knownReminderListNames)
        }
    }

    private var sanitizedReminderListName: String {
        sanitizedListName(reminderListName)
    }

    private func sanitizedListName(_ listName: String) -> String {
        let trimmed = listName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Obsidian" : trimmed
    }

    private func saveTaskFileReminderListNames() {
        let defaultListName = sanitizedReminderListName
        let cleanedListNames = taskFileReminderListNamesByPath.compactMapValues { listName -> String? in
            let sanitized = sanitizedListName(listName)
            return sanitized == defaultListName ? nil : sanitized
        }

        taskFileReminderListNamesByPath = cleanedListNames
        if cleanedListNames.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.taskFileReminderListNamesByPath)
        } else {
            defaults.set(cleanedListNames, forKey: DefaultsKey.taskFileReminderListNamesByPath)
        }
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
