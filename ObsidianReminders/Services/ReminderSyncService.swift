import EventKit
import Foundation
import Security

struct ReminderSyncSummary: Equatable {
    var created: Int = 0
    var updated: Int = 0
    var unchanged: Int = 0
    var deletedFromReminders: Int = 0
    var skippedDeleted: Int = 0
    var failed: Int = 0
    var failureMessages: [String] = []
    var syncedTaskIDs: Set<String> = []

    var headline: String {
        var parts = [
            "\(created) created",
            "\(updated) updated",
            "\(unchanged) unchanged"
        ]

        if skippedDeleted > 0 {
            parts.append("\(skippedDeleted) deleted in Reminders skipped")
        }
        if deletedFromReminders > 0 {
            parts.append("\(deletedFromReminders) deleted from Reminders")
        }

        return parts.joined(separator: ", ")
    }
}

struct ReminderTaskSnapshot: Equatable {
    let taskID: String
    let title: String
    let isCompleted: Bool
    let lastSyncedTitle: String?
}

struct ReminderTaskSnapshotResult: Equatable {
    let listExists: Bool
    let snapshots: [String: ReminderTaskSnapshot]
}

enum ReminderSyncError: LocalizedError {
    case accessDenied(EKAuthorizationStatus)
    case missingApplicationIdentifier
    case missingReminderSource

    var errorDescription: String? {
        switch self {
        case .accessDenied(let status):
            return "Reminders access is \(status.displayName)."
        case .missingApplicationIdentifier:
            return "This sandboxed build is missing a signed application identifier. Use a local debug build without App Sandbox, or sign with an Apple Development team before syncing Reminders."
        case .missingReminderSource:
            return "No Reminders source is available for creating a list."
        }
    }
}

@MainActor
final class ReminderSyncService {
    private let eventStore = EKEventStore()
    private let calendar = Calendar.current
    private let markerPrefix = "ObsidianRemindersID: "
    private let syncedTitlePrefix = "ObsidianRemindersTitleBase64: "
    private let metadataScheme = "obsidian-reminders"
    private let metadataHost = "task"
    private let metadataIDQueryItem = "id"
    private let metadataTitleQueryItem = "title"

    func authorizationStatusText() -> String {
        EKEventStore.authorizationStatus(for: .reminder).displayName
    }

    func requestAccessIfNeeded() async throws {
        let currentStatus = EKEventStore.authorizationStatus(for: .reminder)
        if currentStatus.hasFullRemindersAccess {
            return
        }

        guard currentStatus == .notDetermined else {
            throw ReminderSyncError.accessDenied(currentStatus)
        }

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await eventStore.requestFullAccessToReminders()
        } else {
            granted = try await eventStore.requestAccess(to: .reminder)
        }

        let updatedStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard granted, updatedStatus.hasFullRemindersAccess else {
            throw ReminderSyncError.accessDenied(updatedStatus)
        }
    }

    func sync(tasks: [ObsidianTask], listName: String) async throws -> ReminderSyncSummary {
        try verifySigningCanUseReminders()
        try await requestAccessIfNeeded()

        let calendar = try remindersCalendar(named: listName)
        let existingReminders = await fetchSnapshotReminders(in: calendar)
        let existingRemindersByTaskID = remindersByTaskID(existingReminders)

        var summary = ReminderSyncSummary()
        var hasPendingEventStoreChanges = false

        for task in tasks {
            do {
                let existingReminder = existingRemindersByTaskID[task.id]
                let reminder = existingReminder ?? EKReminder(eventStore: eventStore)

                if existingReminder == nil {
                    reminder.calendar = calendar
                }

                let changed = apply(task, to: reminder, in: calendar)

                if existingReminder == nil {
                    try eventStore.save(reminder, commit: false)
                    summary.created += 1
                    summary.syncedTaskIDs.insert(task.id)
                    hasPendingEventStoreChanges = true
                } else if changed {
                    try eventStore.save(reminder, commit: false)
                    summary.updated += 1
                    summary.syncedTaskIDs.insert(task.id)
                    hasPendingEventStoreChanges = true
                } else {
                    summary.unchanged += 1
                    summary.syncedTaskIDs.insert(task.id)
                }
            } catch {
                summary.failed += 1
                summary.failureMessages.append("\(task.sourceLabel): \(error.localizedDescription)")
            }
        }

        if hasPendingEventStoreChanges {
            try eventStore.commit()
        }

        return summary
    }

    func deleteReminders(taskIDs: Set<String>, listName: String) async throws -> Set<String> {
        guard !taskIDs.isEmpty else { return [] }

        try verifySigningCanUseReminders()
        try await requestAccessIfNeeded()

        guard let calendar = existingRemindersCalendar(named: listName) else {
            return []
        }

        let reminders = await fetchSnapshotReminders(in: calendar)
        var deletedTaskIDs: Set<String> = []
        var hasPendingEventStoreChanges = false

        for reminder in reminders {
            guard let taskID = taskID(in: reminder), taskIDs.contains(taskID) else {
                continue
            }

            try eventStore.remove(reminder, commit: false)
            deletedTaskIDs.insert(taskID)
            hasPendingEventStoreChanges = true
        }

        if hasPendingEventStoreChanges {
            try eventStore.commit()
        }

        return deletedTaskIDs
    }

    func taskSnapshots(inListNamed listName: String) async throws -> [String: ReminderTaskSnapshot] {
        try await taskSnapshotResult(inListNamed: listName).snapshots
    }

    func taskSnapshotResult(inListNamed listName: String) async throws -> ReminderTaskSnapshotResult {
        try verifySigningCanUseReminders()
        try await requestAccessIfNeeded()

        guard let calendar = existingRemindersCalendar(named: listName) else {
            return ReminderTaskSnapshotResult(listExists: false, snapshots: [:])
        }

        let reminders = await fetchSnapshotReminders(in: calendar)
        let snapshots = reminders.reduce(into: [String: ReminderTaskSnapshot]()) { partialResult, reminder in
            guard let taskID = taskID(in: reminder) else { return }

            partialResult[taskID] = ReminderTaskSnapshot(
                taskID: taskID,
                title: reminder.title ?? "",
                isCompleted: reminder.isCompleted,
                lastSyncedTitle: syncedTitle(in: reminder)
            )
        }

        return ReminderTaskSnapshotResult(listExists: true, snapshots: snapshots)
    }

    private func verifySigningCanUseReminders() throws {
        let isSandboxed = entitlementValue(forKey: "com.apple.security.app-sandbox") as? Bool == true
        guard isSandboxed else { return }

        if entitlementValue(forKey: "com.apple.application-identifier") == nil {
            throw ReminderSyncError.missingApplicationIdentifier
        }
    }

    private func entitlementValue(forKey key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return nil
        }

        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    private func remindersCalendar(named name: String) throws -> EKCalendar {
        if let existingCalendar = existingRemindersCalendar(named: name) {
            return existingCalendar
        }

        guard
            let source = eventStore.defaultCalendarForNewReminders()?.source
                ?? eventStore.sources.first(where: { $0.sourceType == .calDAV })
                ?? eventStore.sources.first(where: { $0.sourceType == .local })
                ?? eventStore.sources.first
        else {
            throw ReminderSyncError.missingReminderSource
        }

        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = name
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func existingRemindersCalendar(named name: String) -> EKCalendar? {
        eventStore.calendars(for: .reminder).first { $0.title == name }
    }

    private func fetchReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func fetchCompletedReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let predicate = eventStore.predicateForCompletedReminders(
            withCompletionDateStarting: nil,
            ending: nil,
            calendars: [calendar]
        )
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func fetchSnapshotReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let allReminders = await fetchReminders(in: calendar)
        let completedReminders = await fetchCompletedReminders(in: calendar)

        return (allReminders + completedReminders).reduce(into: [:]) { partialResult, reminder in
            partialResult[reminder.calendarItemIdentifier] = reminder
        }
        .values
        .map { $0 }
    }

    private func remindersByTaskID(_ reminders: [EKReminder]) -> [String: EKReminder] {
        reminders.reduce(into: [:]) { partialResult, reminder in
            guard let taskID = taskID(in: reminder) else { return }
            partialResult[taskID] = reminder
        }
    }

    private func apply(_ task: ObsidianTask, to reminder: EKReminder, in calendar: EKCalendar) -> Bool {
        var changed = false

        if reminder.calendar?.calendarIdentifier != calendar.calendarIdentifier {
            reminder.calendar = calendar
            changed = true
        }

        if reminder.title != task.title {
            reminder.title = task.title
            changed = true
        }

        let dueDateComponents = task.dueDate.map {
            self.calendar.dateComponents([.year, .month, .day], from: $0)
        }
        if !sameDay(reminder.dueDateComponents, dueDateComponents) {
            reminder.dueDateComponents = dueDateComponents
            changed = true
        }

        if reminder.isCompleted != task.isCompleted {
            reminder.isCompleted = task.isCompleted
            reminder.completionDate = task.isCompleted ? Date() : nil
            changed = true
        }

        let notes = notes(for: task)
        if reminder.notes != notes {
            reminder.notes = notes
            changed = true
        }

        let url = metadataURL(for: task)
        if reminder.url != url {
            reminder.url = url
            changed = true
        }

        return changed
    }

    private func sameDay(_ lhs: DateComponents?, _ rhs: DateComponents?) -> Bool {
        lhs?.year == rhs?.year
            && lhs?.month == rhs?.month
            && lhs?.day == rhs?.day
    }

    private func notes(for task: ObsidianTask) -> String {
        "From Obsidian: \(sourceTag(for: task))"
    }

    private func sourceTag(for task: ObsidianTask) -> String {
        switch task.source {
        case .dailyNote:
            return "#daily"
        case .todoFile:
            return "#todo"
        }
    }

    private func taskID(in reminder: EKReminder) -> String? {
        if let taskID = metadataValue(named: metadataIDQueryItem, in: reminder) {
            return taskID
        }

        return reminder.notes?
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix(markerPrefix) }
            .map { String($0.dropFirst(markerPrefix.count)) }
    }

    private func syncedTitle(in reminder: EKReminder) -> String? {
        if let encodedTitle = metadataValue(named: metadataTitleQueryItem, in: reminder) {
            return decodedTitle(encodedTitle)
        }

        guard
            let encodedTitle = reminder.notes?
                .components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix(syncedTitlePrefix) })?
                .dropFirst(syncedTitlePrefix.count),
            let title = decodedTitle(String(encodedTitle))
        else {
            return nil
        }

        return title
    }

    private func metadataURL(for task: ObsidianTask) -> URL? {
        var components = URLComponents()
        components.scheme = metadataScheme
        components.host = metadataHost
        components.queryItems = [
            URLQueryItem(name: metadataIDQueryItem, value: task.id),
            URLQueryItem(name: metadataTitleQueryItem, value: encodedTitle(task.title))
        ]

        return components.url
    }

    private func metadataValue(named name: String, in reminder: EKReminder) -> String? {
        guard
            let url = reminder.url,
            url.scheme == metadataScheme,
            url.host == metadataHost,
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else {
            return nil
        }

        return queryItems.first { $0.name == name }?.value
    }

    private func encodedTitle(_ title: String) -> String {
        Data(title.utf8).base64EncodedString()
    }

    private func decodedTitle(_ encodedTitle: String) -> String? {
        guard let data = Data(base64Encoded: encodedTitle) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

private extension EKAuthorizationStatus {
    var hasFullRemindersAccess: Bool {
        switch self {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .notDetermined:
            return "not determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .fullAccess:
            return "full access"
        case .writeOnly:
            return "write-only"
        @unknown default:
            return "unknown"
        }
    }
}
