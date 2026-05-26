import Foundation

struct ObsidianTask: Identifiable, Hashable {
    enum Source: String, Hashable {
        case dailyNote
        case todoFile

        var label: String {
            switch self {
            case .dailyNote:
                return "Daily"
            case .todoFile:
                return "Todo"
            }
        }
    }

    let id: String
    let title: String
    let isCompleted: Bool
    let dueDate: Date?
    let source: Source
    let fileURL: URL
    let relativePath: String
    let lineNumber: Int
    let originalLine: String

    var sourceLabel: String {
        "\(source.label) - \(relativePath):\(lineNumber)"
    }

    var dueDateLabel: String {
        guard let dueDate else { return "" }
        return Self.dueDateFormatter.string(from: dueDate)
    }

    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
