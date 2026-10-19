import AppIntents

enum Period: String, CaseIterable, AppEnum, Sendable {
    case day, week, month

    var label: String {
        switch self {
        case .day: "24h"
        case .week: "1w"
        case .month: "1m"
        }
    }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Period")

    static let caseDisplayRepresentations: [Period: DisplayRepresentation] = [
        .day: DisplayRepresentation(title: "24h"),
        .week: DisplayRepresentation(title: "1w"),
        .month: DisplayRepresentation(title: "1m"),
    ]
}
