import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: SyncViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            Table(viewModel.tasks) {
                TableColumn("Status") { task in
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isCompleted ? .green : .secondary)
                }
                .width(56)

                TableColumn("Task", value: \.title)

                TableColumn("Source") { task in
                    Text(task.sourceLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 220, ideal: 280)

                TableColumn("Due", value: \.dueDateLabel)
                    .width(120)
            }
            .overlay {
                if viewModel.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "checklist",
                        description: Text("Select sources or rescan.")
                    )
                }
            }

            Divider()

            statusBar
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                sourcePicker(
                    title: "Daily Notes",
                    systemImage: "folder",
                    selection: viewModel.dailyNotesFolderLabel,
                    chooseAction: chooseDailyNotesFolder,
                    clearAction: viewModel.clearDailyNotesFolder
                )

                taskFilesPicker
            }

            HStack(spacing: 12) {
                Label("Reminders: \(viewModel.remindersStatus)", systemImage: "bell.badge")
                    .foregroundStyle(.secondary)

                TextField("List", text: $viewModel.reminderListName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Toggle(isOn: $viewModel.isContinuousSyncEnabled) {
                    Label("Auto", systemImage: "clock.arrow.2.circlepath")
                }
                .toggleStyle(.switch)

                Spacer()

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
        }
        .padding(16)
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
    }

    private func sourcePicker(
        title: String,
        systemImage: String,
        selection: String,
        chooseAction: @escaping () -> Void,
        clearAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: chooseAction) {
                    Label(title, systemImage: systemImage)
                }

                Button(action: clearAction) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            Text(selection)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
