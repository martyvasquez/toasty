import SwiftUI

/// The composer's mic button, which is also dictation's indicator for that
/// composer (plan §9.3): a quiet mic at rest; while listening, an accent mic
/// with a soft halo that follows the voice level; a small spinner while
/// transcribing; a brief warning glyph when a dictation fails.
/// Click: start a hands-free dictation, or finish one.
struct DictationMicButton: View {
    let conversation: UUID
    /// As wide as the composer's other icons; smaller in the comment field.
    var width: CGFloat = ComposerIconButton.width
    var height: CGFloat = Theme.Control.height
    @ObservedObject private var dictation = DictationController.shared
    @State private var hovering = false

    private var phase: DictationController.Phase {
        dictation.target == conversation ? dictation.phase : .idle
    }

    var body: some View {
        Button { DictationController.shared.toggleFromButton() } label: {
            ZStack {
                switch phase {
                case .idle:
                    // As the app's bar buttons: full ink and a hairline
                    // capsule under the pointer.
                    Capsule().strokeBorder(hovering ? Theme.Stroke.hover : Color.clear, lineWidth: 1)
                    Image(systemName: "mic")
                        .font(.toasty(Theme.Size.body, .regular))
                        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                case .listening:
                    Circle().fill(Color.accentColor.opacity(0.16))
                        .scaleEffect(1 + CGFloat(dictation.level) * 0.3)
                        .animation(.easeOut(duration: 0.08), value: dictation.level)
                    Circle().fill(Color.accentColor.opacity(hovering ? 0.22 : 0.14))
                    Image(systemName: "mic.fill")
                        .font(.toasty(Theme.Size.control, .medium))
                        .foregroundStyle(Color.accentColor)
                case .transcribing:
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.toasty(Theme.Size.control, .regular))
                        .foregroundStyle(.secondary)
                }
            }
            // As wide as the composer's other icons (their hover oval).
            .frame(width: width, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip(label, shortcut: "Right ⌥", detail: help)
        .accessibilityLabel(label)
    }

    private var help: String {
        switch phase {
        case .idle: "Hold Right Option to talk, or double-tap it to keep listening."
        case .listening: dictation.locked ? "Right Option finishes; esc cancels." : "Listening. esc cancels."
        case .transcribing: "Transcribing…"
        case .failed(let reason): reason
        }
    }

    private var label: String {
        switch phase {
        case .idle: "Dictate"
        case .listening: "Finish Dictation"
        case .transcribing: "Transcribing"
        case .failed: "Dictation Failed"
        }
    }
}
