import SwiftUI

/// The one way the transcript folds things away (tool runs, thinking,
/// plans, messages from other sessions): a quiet line with a leading
/// chevron (a spinner while it runs) and a control-size label, which
/// brightens and gets a pill on hover. Its text lines up with the replies.
struct ClaudeDisclosureLine<Label: View>: View {
    @Binding var expanded: Bool
    var running = false
    @ViewBuilder var label: Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    /// The pill's padding, the chevron's slot and the gap after it.
    static var pillPadding: CGFloat { Theme.Space.s - Theme.Space.xxs }
    static var chevronWidth: CGFloat { 12 }
    static var chevronGap: CGFloat { Theme.Space.s - 1 }
    /// Only the hover pill's padding hangs out: the chevron sits on the
    /// replies' left edge, so nothing breaks out of the composer's width.
    static var hang: CGFloat { pillPadding + (chevronWidth - 7) / 2 }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: Self.chevronGap) {
                ZStack {
                    if running {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.toasty(Theme.Glyph.small, .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(enabled ? 1 : 0)
                    }
                }
                .frame(width: Self.chevronWidth, height: 12)
                label
                    .font(.toasty(Theme.Size.control))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(hovering && enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Self.pillPadding)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(hovering && enabled ? Theme.Fill.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.leading, -Self.hang)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

/// What a disclosure line opens onto, and other quiet blocks inside the
/// transcript: a faint card with a hairline border.
struct ClaudeTranscriptCard: ViewModifier {
    var padding: CGFloat = Theme.Space.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Fill.faint))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
    }
}

extension View {
    func claudeTranscriptCard(padding: CGFloat = Theme.Space.l) -> some View {
        modifier(ClaudeTranscriptCard(padding: padding))
    }
}
