import Foundation

struct ObsidianTaskWriteSummary: Equatable {
    var checkedOff: Int = 0
    var renamed: Int = 0

    var total: Int {
        checkedOff + renamed
    }
}

struct ObsidianTaskCompletionWriter {
    private static let checkboxRegex = try! NSRegularExpression(
        pattern: #"^(\s*(?:[-*+]|\d+[.)])\s+\[)([^\]])(\]\s+)(.*)$"#
    )

    private static let metadataMarkerRegex = try! NSRegularExpression(
        pattern: #"(?:📅|⏳|🛫|✅|➕|🔁|⛔|❌|⏫|🔼|🔽|⏬|\bdue:)"#,
        options: [.caseInsensitive]
    )

    func applyReminderSnapshots(
        _ snapshotsByTaskID: [String: ReminderTaskSnapshot],
        to tasks: [ObsidianTask]
    ) throws -> ObsidianTaskWriteSummary {
        let updates = tasks.compactMap { task -> ObsidianTaskLineUpdate? in
            guard let snapshot = snapshotsByTaskID[task.id] else {
                return nil
            }

            let shouldCheckOff = snapshot.isCompleted && !task.isCompleted
            let pulledTitle = titleToPull(from: snapshot, for: task)

            guard shouldCheckOff || pulledTitle != nil else {
                return nil
            }

            return ObsidianTaskLineUpdate(
                task: task,
                shouldCheckOff: shouldCheckOff,
                title: pulledTitle
            )
        }

        let updatesByFile = Dictionary(grouping: updates) { update in
            update.task.fileURL
        }

        var summary = ObsidianTaskWriteSummary()

        for (fileURL, updatesInFile) in updatesByFile {
            let fileSummary = try apply(updatesInFile, in: fileURL)
            summary.checkedOff += fileSummary.checkedOff
            summary.renamed += fileSummary.renamed
        }

        return summary
    }

    private func apply(_ updates: [ObsidianTaskLineUpdate], in fileURL: URL) throws -> ObsidianTaskWriteSummary {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        var lines = contents.components(separatedBy: newline)
        var summary = ObsidianTaskWriteSummary()

        for update in updates.sorted(by: { $0.task.lineNumber < $1.task.lineNumber }) {
            let lineIndex = update.task.lineNumber - 1
            guard lines.indices.contains(lineIndex) else {
                continue
            }

            let originalLine = lines[lineIndex]
            guard let updatedLine = updatedLine(originalLine, update: update), updatedLine != originalLine else {
                continue
            }

            lines[lineIndex] = updatedLine
            if update.shouldCheckOff {
                summary.checkedOff += 1
            }
            if update.title != nil {
                summary.renamed += 1
            }
        }

        if summary.total > 0 {
            try lines.joined(separator: newline).write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return summary
    }

    private func updatedLine(_ line: String, update: ObsidianTaskLineUpdate) -> String? {
        let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let match = Self.checkboxRegex.firstMatch(in: line, range: lineRange),
            let prefixRange = Range(match.range(at: 1), in: line),
            let statusRange = Range(match.range(at: 2), in: line),
            let closingRange = Range(match.range(at: 3), in: line),
            let bodyRange = Range(match.range(at: 4), in: line)
        else {
            return nil
        }

        let status = update.shouldCheckOff ? "x" : String(line[statusRange])
        let body = update.title.map {
            renamedBody(
                String(line[bodyRange]),
                currentTitle: update.task.title,
                newTitle: $0
            )
        } ?? String(line[bodyRange])

        return "\(line[prefixRange])\(status)\(line[closingRange])\(body)"
    }

    private func titleToPull(from snapshot: ReminderTaskSnapshot, for task: ObsidianTask) -> String? {
        let reminderTitle = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reminderTitle.isEmpty, reminderTitle != task.title else {
            return nil
        }

        guard let lastSyncedTitle = snapshot.lastSyncedTitle else {
            return reminderTitle
        }

        return task.title == lastSyncedTitle && reminderTitle != lastSyncedTitle ? reminderTitle : nil
    }

    private func renamedBody(_ body: String, currentTitle: String, newTitle: String) -> String {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return body
        }

        if let titleRange = body.range(of: currentTitle) {
            var updatedBody = body
            updatedBody.replaceSubrange(titleRange, with: trimmedTitle)
            return updatedBody
        }

        guard let metadataRange = firstMetadataRange(in: body) else {
            return trimmedTitle
        }

        let metadata = body[metadataRange.lowerBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return metadata.isEmpty ? trimmedTitle : "\(trimmedTitle) \(metadata)"
    }

    private func firstMetadataRange(in body: String) -> Range<String.Index>? {
        let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
        guard
            let match = Self.metadataMarkerRegex.firstMatch(in: body, range: bodyRange),
            let range = Range(match.range, in: body)
        else {
            return nil
        }

        return range
    }
}

private struct ObsidianTaskLineUpdate {
    let task: ObsidianTask
    let shouldCheckOff: Bool
    let title: String?
}
