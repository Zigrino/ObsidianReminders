import Foundation

struct ObsidianTaskParser {
    private static let taskRegex = try! NSRegularExpression(
        pattern: #"^(\s*)([-*+]|\d+[.)])\s+\[([^\]])\]\s+(.*)$"#
    )

    private static let dueDateRegex = try! NSRegularExpression(
        pattern: "(?:\(String(UnicodeScalar(0x1F4C5)!))|due:)\\s*(\\d{4}-\\d{2}-\\d{2})",
        options: [.caseInsensitive]
    )

    private static let dailyNoteDateRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{4})[-_./]?(\d{1,2})[-_./]?(\d{1,2})(?!\d)"#
    )

    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func loadTasks(dailyNotesFolder: URL?, taskFiles: [URL]) throws -> [ObsidianTask] {
        var tasks: [ObsidianTask] = []

        if let dailyNotesFolder {
            let markdownFiles = try markdownFiles(in: dailyNotesFolder)
            for fileURL in markdownFiles {
                tasks.append(contentsOf: try parseFile(
                    fileURL,
                    source: .dailyNote,
                    rootURL: dailyNotesFolder
                ))
            }
        }

        for taskFile in taskFiles {
            tasks.append(contentsOf: try parseFile(
                taskFile,
                source: .todoFile,
                rootURL: taskFileRootURL(for: taskFile, allTaskFiles: taskFiles)
            ))
        }

        return tasks.sorted {
            if $0.relativePath == $1.relativePath {
                return $0.lineNumber < $1.lineNumber
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    func taskFileRelativePaths(for taskFiles: [URL]) -> [String] {
        taskFiles.map { taskFile in
            taskFile.relativePath(from: taskFileRootURL(for: taskFile, allTaskFiles: taskFiles))
        }
    }

    func parseFile(_ fileURL: URL, source: ObsidianTask.Source, rootURL: URL) throws -> [ObsidianTask] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return parse(contents: contents, fileURL: fileURL, source: source, rootURL: rootURL)
    }

    func parse(
        contents: String,
        fileURL: URL,
        source: ObsidianTask.Source,
        rootURL: URL
    ) -> [ObsidianTask] {
        let relativePath = fileURL.relativePath(from: rootURL)
        let dailyNoteDate = source == .dailyNote ? dateInDailyNotePath(relativePath) : nil
        let lines = contents.components(separatedBy: .newlines)

        return lines.enumerated().compactMap { index, line in
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard
                let match = Self.taskRegex.firstMatch(in: line, range: lineRange),
                let statusRange = Range(match.range(at: 3), in: line),
                let bodyRange = Range(match.range(at: 4), in: line)
            else {
                return nil
            }

            let rawBody = String(line[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawBody.isEmpty else { return nil }

            let lineNumber = index + 1
            let id = "\(source.rawValue):\(relativePath):\(lineNumber)"

            return ObsidianTask(
                id: id,
                title: cleanedTitle(from: rawBody),
                isCompleted: String(line[statusRange]).lowercased() == "x",
                dueDate: dueDate(in: rawBody) ?? dailyNoteDate,
                dailyNoteDate: dailyNoteDate,
                source: source,
                fileURL: fileURL,
                relativePath: relativePath,
                lineNumber: lineNumber,
                originalLine: line
            )
        }
    }

    private func markdownFiles(in folderURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
            guard resourceValues.isRegularFile == true, resourceValues.isHidden != true else {
                continue
            }

            if fileURL.pathExtension.lowercased() == "md" {
                files.append(fileURL)
            }
        }

        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func taskFileRootURL(for taskFile: URL, allTaskFiles: [URL]) -> URL {
        let matchingNameFiles = allTaskFiles.filter {
            $0.lastPathComponent.caseInsensitiveCompare(taskFile.lastPathComponent) == .orderedSame
        }

        guard matchingNameFiles.count > 1, let commonDirectory = commonParentDirectory(of: matchingNameFiles) else {
            return taskFile.deletingLastPathComponent()
        }

        return commonDirectory
    }

    private func commonParentDirectory(of urls: [URL]) -> URL? {
        let parentPathComponents = urls.map {
            $0.deletingLastPathComponent().standardizedFileURL.pathComponents
        }
        guard var commonComponents = parentPathComponents.first else {
            return nil
        }

        for components in parentPathComponents.dropFirst() {
            commonComponents = Array(zip(commonComponents, components).prefix { $0 == $1 }.map(\.0))
        }

        guard !commonComponents.isEmpty else {
            return URL(fileURLWithPath: "/", isDirectory: true)
        }

        let path = NSString.path(withComponents: commonComponents)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func dueDate(in body: String) -> Date? {
        let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
        guard
            let match = Self.dueDateRegex.firstMatch(in: body, range: bodyRange),
            let dateRange = Range(match.range(at: 1), in: body)
        else {
            return nil
        }

        let components = String(body[dateRange])
            .split(separator: "-")
            .compactMap { Int(String($0)) }
        guard components.count == 3 else { return nil }

        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]
        return calendar.date(from: dateComponents)
    }

    private func dateInDailyNotePath(_ relativePath: String) -> Date? {
        let searchText = relativePath.replacingOccurrences(of: "\\", with: "/")
        let searchRange = NSRange(searchText.startIndex..<searchText.endIndex, in: searchText)

        guard
            let match = Self.dailyNoteDateRegex.firstMatch(in: searchText, range: searchRange),
            let year = integerCapture(at: 1, in: searchText, match: match),
            let month = integerCapture(at: 2, in: searchText, match: match),
            let day = integerCapture(at: 3, in: searchText, match: match)
        else {
            return nil
        }

        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        return calendar.date(from: dateComponents)
    }

    private func integerCapture(at index: Int, in text: String, match: NSTextCheckingResult) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else {
            return nil
        }

        return Int(String(text[range]))
    }

    private func cleanedTitle(from body: String) -> String {
        let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let withoutDueDate = Self.dueDateRegex.stringByReplacingMatches(
            in: body,
            range: bodyRange,
            withTemplate: ""
        )

        let cleaned = withoutDueDate
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? body : cleaned
    }
}

private extension URL {
    func relativePath(from rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let fullPath = standardizedFileURL.path

        guard fullPath.hasPrefix(rootPath + "/") else {
            return lastPathComponent
        }

        return String(fullPath.dropFirst(rootPath.count + 1))
    }
}
