import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: SyncViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            Table(viewModel.visibleTasks) {
                TableColumn("Status") { task in
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isCompleted ? .green : .secondary)
                }
                .width(56)

                TableColumn("Sync") { task in
                    Button {
                        Task {
                            await viewModel.toggleSyncExclusion(for: task)
                        }
                    } label: {
                        Label(
                            viewModel.syncStatusLabel(for: task),
                            systemImage: viewModel.syncStatusSystemImage(for: task)
                        )
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(viewModel.isTaskExcludedFromSync(task) ? .orange : .secondary)
                    .help(viewModel.syncStatusHelp(for: task))
                    .disabled(viewModel.isWorking)
                }
                .width(120)

                TableColumn("Task", value: \.title)

                TableColumn("Source") { task in
                    Text(task.sourceLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 220, ideal: 280)

                TableColumn("Due", value: \.dueDateLabel)
                    .width(120)

                TableColumn("") { task in
                    Button {
                        viewModel.removeTaskFromView(task)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from this view until the next scan or sync")
                    .disabled(viewModel.isWorking)
                }
                .width(44)
            }
            .overlay {
                if viewModel.visibleTasks.isEmpty {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "checklist",
                        description: Text("Select sources or rescan.")
                    )
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            statusBar
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                dailyNotesPicker

                taskFilesPicker
            }
            .fixedSize(horizontal: false, vertical: true)

            syncControlsRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var syncControlsRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge")
                Text("Access: \(viewModel.remindersStatus)")
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Divider()
                .frame(height: 22)

            defaultListField

            Button {
                viewModel.applyReminderListChanges()
            } label: {
                Label("Apply Lists", systemImage: "checkmark.circle")
            }
            .disabled(!viewModel.hasPendingReminderListChanges || viewModel.isWorking)
            .help("Apply Daily Notes and task-file list changes to sync")

            Toggle(isOn: $viewModel.isContinuousSyncEnabled) {
                Label("Auto", systemImage: "clock.arrow.2.circlepath")
            }
            .toggleStyle(.switch)
            .fixedSize()

            Toggle(isOn: $viewModel.clearsOldDailyNotes) {
                Label("Skip Old Daily", systemImage: "calendar.badge.clock")
            }
            .toggleStyle(.switch)
            .help("Do not sync older daily notes; yesterday clears after 8 AM.")
            .fixedSize()

            Toggle(isOn: $viewModel.hidesCompletedTasks) {
                Label("Hide Done", systemImage: "checkmark.circle")
            }
            .toggleStyle(.switch)
            .fixedSize()

            Spacer(minLength: 12)

            Button {
                viewModel.scanNow()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isWorking)

            Button {
                Task {
                    await viewModel.syncNow()
                }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!viewModel.canSync)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var defaultListField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Default list")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            TextField("Obsidian", text: $viewModel.reminderListName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .frame(width: 180, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .help("Default Reminders list for sources without an override")
    }

    private var dailyNotesPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: chooseDailyNotesFolder) {
                    Label("Daily Notes", systemImage: "folder")
                }

                Button(action: viewModel.clearDailyNotesFolder) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove daily notes folder")
            }

            Text(viewModel.dailyNotesFolderLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.hasDailyNotesFolderSelected {
                HStack(spacing: 6) {
                    Text("List")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        "List",
                        text: Binding(
                            get: {
                                viewModel.draftDailyNotesListName
                            },
                            set: { newValue in
                                viewModel.setDraftDailyNotesReminderListName(newValue)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 150)
                    .help("Reminder list for Daily Notes; changes apply after pressing Apply Lists")

                    pendingListIndicator(viewModel.hasPendingDailyNotesReminderListChange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Text(viewModel.statusMessage)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let summary = viewModel.lastSummary, summary.failed > 0 {
                Label("\(summary.failed) failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Label(
                viewModel.continuousSyncStatus,
                systemImage: viewModel.isContinuousSyncEnabled ? "clock.arrow.2.circlepath" : "pause.circle"
            )
            .lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var taskFilesPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: chooseTaskFiles) {
                    Label("Task Files", systemImage: "doc.text")
                }

                if !viewModel.taskFileSelections.isEmpty {
                    Button(action: viewModel.clearTaskFiles) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove all task files")
                }

                Text(viewModel.taskFilesLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.taskFileSelections.isEmpty {
                Text("No files selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(viewModel.taskFileSelections) { selection in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)

                            Text(selection.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text("List")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField(
                                "List",
                                text: Binding(
                                    get: {
                                        selection.draftReminderListName
                                    },
                                    set: { newValue in
                                        viewModel.setDraftReminderListName(newValue, for: selection)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 150)
                            .help("Reminder list for this task file; changes apply after pressing Apply Lists")

                            pendingListIndicator(selection.hasPendingReminderListChange)

                            Button {
                                viewModel.removeTaskFile(selection)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove task file")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func pendingListIndicator(_ isPending: Bool) -> some View {
        if isPending {
            Image(systemName: "circle.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.orange)
                .help("Pending list change")
        } else {
            Color.clear
                .frame(width: 7, height: 7)
        }
    }

    private func chooseDailyNotesFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Daily Notes Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        viewModel.selectDailyNotesFolder(url)
    }

    private func chooseTaskFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Task Files"
        panel.prompt = "Add"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }

        guard panel.runModal() == .OK else {
            return
        }

        viewModel.addTaskFiles(panel.urls)
    }
}
