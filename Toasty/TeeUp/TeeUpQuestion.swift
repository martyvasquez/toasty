import SwiftUI

/// Auto-Send's check before it sends the next prompt: did Claude end its
/// reply by asking for something it needs? A reply like "Where are you
/// located?" finishes the turn cleanly, and the next prompt would run
/// over it.
enum TeeUpQuestion {
    /// The reply ends on a question (its last paragraph has one): worth
    /// checking. Most replies don't, and go on with no check at all.
    static func mightAsk(_ reply: String) -> Bool {
        let last = reply.components(separatedBy: "\n\n")
            .last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        return last.contains("?")
    }

    enum Verdict: Equatable {
        /// The work is done; a question at the end is only an offer.
        case goOn
        /// Claude needs this from the user before the work is done.
        case waiting(String)
        /// Not an answer in the form asked for: treated as waiting.
        case unclear
    }

    static let system = """
        A user queued several instructions for a coding assistant. The next one is sent automatically when \
        the assistant finishes, unless the assistant is waiting for the user. You are given what the user \
        asked and the end of the assistant's reply, which ends with a question. Decide which kind it is.

        BLOCKED: the assistant is waiting for the user's answer. The work asked for is not done, or cannot \
        go on, until the user replies. Examples:
        - "Which of the two approaches should I take?"
        - "I couldn't find that file. Where is it?"
        - "What's your API key's environment variable called?"
        - The user said to ask them questions first, and the assistant asked them.

        CONTINUE: the work asked for is done, and the question only offers something extra. Examples:
        - "Done. Want me to add tests too?"
        - "All fixed. Should I also update the docs?"
        - "Hello! How can I help?"
        - "Anything else?"

        Answer in two lines. First line: what the assistant's closing question is for, in one short \
        sentence. Second line: the verdict, exactly one of
        CONTINUE
        BLOCKED: <what the assistant needs, six words at most, such as "which migration path to use">
        """

    /// The question for the small model. The reply is cut to its end,
    /// where a question would be.
    static func prompt(asked: String, reply: String) -> String {
        """
        <asked>
        \(asked.prefix(1500))
        </asked>

        <reply>
        \(reply.suffix(2500))
        </reply>
        """
    }

    /// The model's answer. If it wrote more than the one line (it
    /// sometimes reconsiders out loud), its last verdict is the one it means.
    static func verdict(_ answer: String) -> Verdict {
        for line in answer.split(whereSeparator: \.isNewline).reversed() {
            let line = line.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("CONTINUE") { return .goOn }
            if upper.hasPrefix("BLOCKED") {
                let what = line.dropFirst("BLOCKED".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":.·-—–\"“” ").union(.whitespaces))
                // The pause reads "Claude needs …".
                let need = what.lowercased().hasPrefix("needs ") ? String(what.dropFirst(6)) : what
                return .waiting(need.count > 60 ? String(need.prefix(59)) + "…" : need)
            }
        }
        return .unclear
    }
}

/// Settings ▸ Tee-Up.
final class TeeUpSettings: ObservableObject {
    static let shared = TeeUpSettings()
    private static let key = "TeeUpQuestionCheck"

    /// What Auto-Send does when Claude's reply ends on a question.
    enum QuestionCheck: String, CaseIterable, Identifiable {
        /// Nothing: the countdown is the only chance to stop it.
        case off
        /// Stops, whatever the question.
        case anyQuestion
        /// Asks a small model whether Claude needs an answer.
        case smallModel

        var id: String { rawValue }

        var title: String {
            switch self {
            case .smallModel: "Ask a small model if Claude needs an answer"
            case .anyQuestion: "Always pause"
            case .off: "Keep sending"
            }
        }
    }

    @Published var questionCheck: QuestionCheck {
        didSet { if questionCheck != oldValue { UserDefaults.standard.set(questionCheck.rawValue, forKey: Self.key) } }
    }

    private init() {
        questionCheck = UserDefaults.standard.string(forKey: Self.key).flatMap(QuestionCheck.init(rawValue:)) ?? .smallModel
    }
}

struct TeeUpSettingsView: View {
    @ObservedObject private var settings = TeeUpSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("When Claude's reply ends with a question", selection: $settings.questionCheck) {
                    ForEach([TeeUpSettings.QuestionCheck.smallModel, .anyQuestion, .off]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Auto-Send")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Send sends the next teed-up prompt when Claude finishes. A reply like “Which database should I use?” finishes too, and the next prompt would run over it.")
                    Text(detail)
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 300)
    }

    private var detail: String {
        switch settings.questionCheck {
        case .smallModel:
            "Claude Haiku reads your prompt and the end of the reply, in a query of its own that isn't saved, and Auto-Send pauses if Claude is waiting for an answer. An offer such as “Want me to add tests?” doesn't stop it. If the check fails, it pauses."
        case .anyQuestion:
            "Auto-Send pauses whenever the reply's last paragraph has a question in it, offers included. Nothing extra is sent to Claude."
        case .off:
            "Auto-Send keeps going. The five-second countdown before each prompt is the only chance to stop it."
        }
    }
}
