import AppIntents
import Foundation

/// Denko's Focus filter (System Settings → Focus → a Focus → Focus filters → Denko).
/// When that Focus turns on, macOS runs this with the chosen value; when it turns off,
/// macOS runs it again with the default (いつもどおり). No special permission is needed.
struct DenkoFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Denko の掲示板"
    static let description: IntentDescription? = "この集中モードのあいだに掲示板に流すお知らせを選びます。"

    @Parameter(title: "流すお知らせ", default: .same)
    var behavior: FocusChoice

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "掲示板：\(behavior.localizedStringResource)")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(behavior.rawValue, forKey: FocusChoice.key)
        return .result()
    }
}

enum FocusChoice: String, AppEnum {
    case same, urgentOnly, silent
    static let key = "focusFilterBehavior"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "流すお知らせ"
    static let caseDisplayRepresentations: [FocusChoice: DisplayRepresentation] = [
        .same: "いつもどおり",
        .urgentOnly: "緊急だけ",
        .silent: "流さない",
    ]

    /// What the active Focus asks for right now (いつもどおり when no Focus uses Denko's filter).
    static var current: FocusBehavior {
        FocusBehavior(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .same
    }
}
