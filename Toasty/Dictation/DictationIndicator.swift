import SwiftUI

/// The composer's mic button, which is also dictation's indicator for that
/// composer (plan §9.3): a quiet mic at rest; while listening, an accent mic
/// with a soft halo that follows the voice level; a small spinner while
/// transcribing; a brief warning glyph when a dictation fails.
/// Click: start a hands-free dictation, or finish one.
struct DictationMicButton: View {
    let conversation: UUID
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
                    Circle().fill(Color.primary.opacity(hovering ? 0.07 : 0))
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                case .listening:
                    Circle().fill(Color.accentColor.opacity(0.16))
                        .scaleEffect(1 + CGFloat(dictation.level) * 0.3)
                        .animation(.easeOut(duration: 0.08), value: dictation.level)
                    Circle().fill(Color.accentColor.opacity(hovering ? 0.22 : 0.14))
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                case .transcribing:
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(label)
    }

    private var help: String {
        switch phase {
        case .idle: "Dictate (hold Right Option, or double-tap it to keep listening)"
        case .listening: dictation.locked ? "Finish Dictation (Right Option) · Cancel (esc)" : "Listening… · Cancel (esc)"
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
