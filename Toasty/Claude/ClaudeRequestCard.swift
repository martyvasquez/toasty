import AppKit
import SwiftUI

/// Something Claude Code is waiting on: a tool permission, a
/// question (AskUserQuestion), or plan approval (ExitPlanMode). These come
/// from the SDK's `canUseTool` callback, where the CLI would show its own
/// prompt; the answers go back unchanged in the SDK's format.
struct ClaudeRequestCard: View {
    @ObservedObject var conversation: ClaudeConversation
    let request: ClaudePermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch request.toolName {
            case "AskUserQuestion": ClaudeQuestionForm(conversation: conversation, request: request)
            case "ExitPlanMode": ClaudePlanApproval(conversation: conversation, request: request)
            default: ClaudePermissionPrompt(conversation: conversation, request: request)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Color.claudeField))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
        .raisedShadow()
    }
}

/// A feedback field shared by the prompts: "tell Claude what to do instead".
private struct FeedbackField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.toasty(Theme.Size.meta))
            .onSubmit(onSubmit)
    }
}

// MARK: Tool permission

struct ClaudePermissionPrompt: View {
    @ObservedObject var conversation: ClaudeConversation
    let request: ClaudePermissionRequest
    @State private var feedback = ""

    private var input: [String: Any] { request.input }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: ClaudeToolInfo.icon(request.toolName)).foregroundStyle(Color.orange)
            Text(request.title ?? "Allow Claude to use \(ClaudeToolInfo.displayName(request.toolName))?")
        }
        .font(.toasty(Theme.Size.body, .semibold))
        if let d = request.description ?? (input["description"] as? String), !d.isEmpty,
           d != ClaudeToolInfo.summary(request.toolName, input, cwd: conversation.cwd),
           d != (input["file_path"] as? String) {
            Text(d).font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary).textSelection(.enabled)
        }
        preview
        if let reason = request.decisionReason, !reason.isEmpty {
            Text(reason).font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary)
        }

        FeedbackField(placeholder: "Or tell Claude what to do instead, then ⏎", text: $feedback) {
            let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            conversation.respond(to: request, ["behavior": "deny", "message": text, "interrupt": false])
        }

        // Mac order: the default button last, Cancel's counterpart before it.
        HStack(spacing: Theme.Space.s) {
            if !request.suggestions.isEmpty {
                Button(alwaysLabel) { allow(always: true) }
            }
            Spacer()
            Button("Deny") { deny() }
                .help("esc")
            Button("Allow") { allow() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘⏎")
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var preview: some View {
        switch request.toolName {
        case "Bash":
            ClaudeCodeBlock(language: "bash", code: input["command"] as? String ?? "", compact: true)
        case "Edit", "MultiEdit", "Write":
            VStack(alignment: .leading, spacing: 4) {
                Text(ClaudeToolInfo.summary(request.toolName, input, cwd: conversation.cwd))
                    .font(.toasty(Theme.Size.meta, design: .monospaced))
                    .foregroundStyle(.secondary)
                HuggingScrollView(maxHeight: 260) {
                    ClaudeDiffView(lines: ClaudeToolInfo.diffLines(request.toolName, input), maxLines: nil)
                }
            }
        default:
            let summary = ClaudeToolInfo.summary(request.toolName, input, cwd: conversation.cwd)
            if !summary.isEmpty && input.count <= 1 {
                Text(summary).font(.toasty(Theme.Size.meta, design: .monospaced)).textSelection(.enabled)
            } else if !input.isEmpty {
                HuggingScrollView(maxHeight: 200) {
                    ClaudeCodeBlock(language: "json", code: ClaudeToolInfo.pretty(input), compact: true)
                }
            }
        }
    }

    /// "Yes, and don't ask again for …", from Claude Code's suggestions.
    private var alwaysLabel: String {
        var parts: [String] = []
        for s in request.suggestions {
            switch s["type"] as? String {
            case "addRules", "replaceRules":
                let rules = (s["rules"] as? [[String: Any]] ?? []).map { r -> String in
                    let tool = r["toolName"] as? String ?? ""
                    if let c = r["ruleContent"] as? String, !c.isEmpty { return "\(tool)(\(c))" }
                    return tool
                }
                parts.append(contentsOf: rules)
            case "setMode":
                if s["mode"] as? String == "acceptEdits" { return "Allow All Edits This Session" }
                if let m = s["mode"] as? String { return "Switch to \(ClaudeModeMenu.label(m))" }
            case "addDirectories":
                parts.append(contentsOf: (s["directories"] as? [String] ?? []).map { ($0 as NSString).abbreviatingWithTildeInPath })
            default: break
            }
        }
        let what = parts.joined(separator: ", ")
        return what.isEmpty ? "Always Allow" : "Always Allow \(what.count > 50 ? String(what.prefix(50)) + "…" : what)"
    }

    private func allow(always: Bool = false) {
        var r: [String: Any] = ["behavior": "allow", "updatedInput": input]
        if always { r["updatedPermissions"] = request.suggestions }
        conversation.respond(to: request, r)
    }

    private func deny() {
        conversation.respond(to: request, ["behavior": "deny", "message": "The user rejected this.", "interrupt": true])
    }
}

// MARK: AskUserQuestion

struct ClaudeQuestionForm: View {
    @ObservedObject var conversation: ClaudeConversation
    let request: ClaudePermissionRequest

    @State private var selected: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]

    private var questions: [[String: Any]] { request.input["questions"] as? [[String: Any]] ?? [] }

    var body: some View {
        ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    if let header = q["header"] as? String, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.toasty(Theme.Size.caption, .semibold))
                            .padding(.horizontal, Theme.Space.xs + 1).padding(.vertical, Theme.Space.xxs)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                    }
                    Text(q["question"] as? String ?? "")
                        .font(.toasty(Theme.Size.body, .semibold))
                        .textSelection(.enabled)
                }
                let multi = q["multiSelect"] as? Bool ?? false
                ForEach(Array((q["options"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, option in
                    let label = option["label"] as? String ?? ""
                    let isOn = selected[qi]?.contains(label) ?? false
                    Button {
                        toggle(qi, label, multi: multi)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Image(systemName: multi ? (isOn ? "checkmark.square.fill" : "square")
                                                    : (isOn ? "largecircle.fill.circle" : "circle"))
                                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(label).font(.toasty(Theme.Size.control, .medium))
                                if let d = option["description"] as? String, !d.isEmpty {
                                    Text(d).font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Theme.Space.xs + Theme.Space.xxs).padding(.horizontal, Theme.Space.s)
                        .background(isOn ? Theme.Fill.accent : Theme.Fill.faint,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TextField("Other…", text: Binding(get: { other[qi] ?? "" }, set: { other[qi] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.toasty(Theme.Size.meta))
                    .onSubmit { if complete { submit() } }
            }
        }
        HStack(spacing: Theme.Space.s) {
            Spacer()
            Button("Skip") {
                conversation.respond(to: request, ["behavior": "deny", "message": "The user declined to answer.", "interrupt": true])
            }
            Button("Submit") { submit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!complete)
        }
    }

    private func toggle(_ qi: Int, _ label: String, multi: Bool) {
        var s = selected[qi] ?? []
        if multi {
            if s.contains(label) { s.remove(label) } else { s.insert(label) }
        } else {
            s = s.contains(label) ? [] : [label]
        }
        selected[qi] = s
    }

    private func answer(_ qi: Int) -> String? {
        var parts = Array(selected[qi] ?? [])
        // Keep the options' order.
        let order = (questions[qi]["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        parts.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        if let o = other[qi]?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { parts.append(o) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var complete: Bool {
        questions.indices.allSatisfy { answer($0) != nil }
    }

    private func submit() {
        guard complete else { return }
        var answers: [String: String] = [:]
        for (i, q) in questions.enumerated() {
            if let text = q["question"] as? String, let a = answer(i) { answers[text] = a }
        }
        var input = request.input
        input["answers"] = answers
        conversation.respond(to: request, ["behavior": "allow", "updatedInput": input])
    }
}

// MARK: ExitPlanMode

struct ClaudePlanApproval: View {
    @ObservedObject var conversation: ClaudeConversation
    let request: ClaudePermissionRequest
    @State private var feedback = ""

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(Color.orange)
            Text("Ready to code? Here is Claude's plan:")
        }
        .font(.toasty(Theme.Size.body, .semibold))
        HuggingScrollView(maxHeight: 320) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(ClaudeMarkdown.blocks(request.input["plan"] as? String ?? "", style: .init(cwd: conversation.cwd)).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let s): ClaudeRichText(text: s)
                    case .code(let l, let c): ClaudeCodeBlock(language: l, code: c)
                    case .table(let s): ClaudeTableBlock(text: s)
                    case .rule: Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
        .background(Theme.Fill.faint, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Stroke.border, lineWidth: 0.5))

        FeedbackField(placeholder: "No, keep planning: tell Claude what to change, then ⏎", text: $feedback) {
            let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            conversation.respond(to: request, [
                "behavior": "deny",
                "message": text.isEmpty ? "The user wants to keep planning." : text,
                "interrupt": false,
            ])
        }

        // Mac order: the default button last.
        HStack(spacing: Theme.Space.s) {
            Spacer()
            Button("Yes, Approve Edits Manually") { approve("default") }
            if conversation.autoModeAvailable {
                Button("Yes, Auto Mode") { approve("auto") }
            }
            Button("Yes, Auto-Accept Edits") { approve("acceptEdits") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func approve(_ mode: String) {
        conversation.respond(to: request, [
            "behavior": "allow",
            "updatedInput": request.input,
            "updatedPermissions": [["type": "setMode", "mode": mode, "destination": "session"]],
        ])
        conversation.noteModeChange(mode)
    }
}

/// A vertical scroll view as tall as its content, up to `maxHeight`
/// (a plain ScrollView with a max height always takes the maximum).
struct HuggingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(maxHeight, max(1, contentHeight)))
    }
}
