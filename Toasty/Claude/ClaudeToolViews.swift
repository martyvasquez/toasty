import AppKit
import SwiftUI

/// How Claude Code's tools are summarized in a conversation.
enum ClaudeToolInfo {
    static func displayName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
            // mcp__server__tool
            if parts.count >= 3 { return "\(parts[1]) · \(parts[2...].joined(separator: "_"))" }
        }
        switch tool {
        case "Task", "Agent": return "Agent"
        case "TodoWrite": return "Update Todos"
        case "MultiEdit": return "Edit"
        case "NotebookEdit": return "Edit Notebook"
        case "BashOutput": return "Shell Output"
        case "KillShell", "KillBash": return "Kill Shell"
        default: return tool
        }
    }

    static func icon(_ tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell", "KillBash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Glob", "Grep", "LS": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        case "Skill": "wand.and.stars"
        case "ExitPlanMode": "list.bullet.clipboard"
        case "AskUserQuestion": "questionmark.bubble"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// One-line summary of a call's input, like the CLI's `Tool(summary)`.
    static func summary(_ tool: String, _ input: [String: Any], cwd: String) -> String {
        func str(_ k: String) -> String? { input[k] as? String }
        func rel(_ p: String?) -> String? {
            guard let p else { return nil }
            if p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
            let home = NSHomeDirectory()
            if p.hasPrefix(home + "/") { return "~/" + p.dropFirst(home.count + 1) }
            return p
        }
        switch tool {
        case "Bash": return str("command").map { $0.replacingOccurrences(of: "\n", with: " ⏎ ") } ?? ""
        case "Read", "Edit", "MultiEdit", "Write": return rel(str("file_path")) ?? ""
        case "NotebookEdit": return rel(str("notebook_path")) ?? ""
        case "Glob": return [str("pattern"), str("path").flatMap(rel)].compactMap { $0 }.joined(separator: " in ")
        case "Grep": return [str("pattern").map { "\"\($0)\"" }, str("path").flatMap(rel)].compactMap { $0 }.joined(separator: " in ")
        case "WebFetch": return str("url") ?? ""
        case "WebSearch": return str("query") ?? ""
        case "Task", "Agent": return str("description") ?? str("subagent_type") ?? ""
        case "Skill": return str("skill") ?? str("command") ?? ""
        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            let done = todos.filter { $0["status"] as? String == "completed" }.count
            return todos.isEmpty ? "" : "\(done)/\(todos.count) done"
        default:
            if let first = input.sorted(by: { $0.key < $1.key }).first(where: { $0.value is String }) {
                return "\(first.key): \(first.value)"
            }
            return ""
        }
    }

    static func isEdit(_ tool: String) -> Bool { ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool) }

    /// "Running", "Reading"… for the live step.
    static func activeVerb(_ tool: String) -> String {
        switch tool {
        case "Bash": "Running"
        case "Read": "Reading"
        case "Edit", "MultiEdit", "NotebookEdit": "Editing"
        case "Write": "Writing"
        case "Glob", "Grep", "LS": "Searching"
        case "WebFetch": "Fetching"
        case "WebSearch": "Searching the web for"
        case "Task", "Agent": "Running agent:"
        case "TodoWrite": "Updating todos"
        case "Skill": "Using skill"
        default: displayName(tool)
        }
    }

    /// One sentence for a run of finished tool calls: "Read 2 files, ran
    /// `npm test`, edited hello.py".
    static func headline(_ items: [ClaudeItem], cwd: String) -> String {
        var order: [String] = []
        var groups: [String: [ClaudeItem]] = [:]
        for item in items {
            let key: String
            switch item.toolName {
            case "Read": key = "read"
            case "Edit", "MultiEdit", "NotebookEdit": key = "edit"
            case "Write": key = "write"
            case "Bash", "BashOutput": key = "bash"
            case "Glob", "Grep", "LS": key = "search"
            case "WebFetch", "WebSearch": key = "web"
            case "Task", "Agent": key = "agent"
            case "TodoWrite": key = "todo"
            default: key = "other:" + item.toolName
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        func files(_ list: [ClaudeItem]) -> [String] {
            Array(Set(list.map { (summary($0.toolName, $0.input, cwd: cwd) as NSString).lastPathComponent })).sorted()
        }
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let parts: [String] = order.map { key in
            let list = groups[key]!
            switch key {
            case "read":
                let f = files(list)
                return f.count == 1 ? "read \(f[0])" : "read \(plural(f.count, "file", "files"))"
            case "edit":
                let f = files(list)
                return f.count == 1 ? "edited \(f[0])" : "edited \(plural(f.count, "file", "files"))"
            case "write":
                let f = files(list)
                return f.count == 1 ? "wrote \(f[0])" : "wrote \(plural(f.count, "file", "files"))"
            case "bash":
                if list.count == 1 {
                    let cmd = summary("Bash", list[0].input, cwd: cwd)
                    return "ran " + (cmd.count > 48 ? String(cmd.prefix(47)) + "…" : cmd)
                }
                return "ran \(plural(list.count, "command", "commands"))"
            case "search": return list.count == 1 ? "searched for \(summary(list[0].toolName, list[0].input, cwd: cwd))" : "searched \(list.count) times"
            case "web": return list.count == 1 ? "looked up \(summary(list[0].toolName, list[0].input, cwd: cwd))" : "looked up \(list.count) pages"
            case "agent": return list.count == 1 ? "ran an agent" : "ran \(list.count) agents"
            case "todo": return "updated todos"
            default:
                let name = displayName(String(key.dropFirst(6)))
                return list.count == 1 ? "used \(name)" : "used \(name) \(list.count) times"
            }
        }
        let s = parts.joined(separator: ", ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "\(value)" }
        return s
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60, s = seconds % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func describeAssistantError(_ error: String) -> String {
        switch error {
        case "authentication_failed": "Claude Code isn't logged in. Run `claude` in the terminal (or `/login`) to sign in."
        case "billing_error": "There's a billing problem with your Claude account."
        case "rate_limit": "Rate limited. Claude Code will retry, or try again shortly."
        case "invalid_request": "The request was invalid."
        case "server_error": "Anthropic's API had a server error."
        default: "Error: \(error)"
        }
    }

    /// Unified-diff-style lines for an edit's input.
    static func diffLines(_ tool: String, _ input: [String: Any]) -> [(Character, String)] {
        func lines(_ s: String?) -> [String] { (s ?? "").components(separatedBy: "\n") }
        var out: [(Character, String)] = []
        switch tool {
        case "Edit":
            out += lines(input["old_string"] as? String).map { ("-", $0) }
            out += lines(input["new_string"] as? String).map { ("+", $0) }
        case "MultiEdit":
            for (i, e) in (input["edits"] as? [[String: Any]] ?? []).enumerated() {
                if i > 0 { out.append(("@", "…")) }
                out += lines(e["old_string"] as? String).map { ("-", $0) }
                out += lines(e["new_string"] as? String).map { ("+", $0) }
            }
        case "Write":
            out += lines(input["content"] as? String).map { ("+", $0) }
        default:
            break
        }
        return out
    }

    /// Diff lines from Claude Code's structured patch (`tool_use_result`),
    /// which has real context lines and line numbers.
    static func patchLines(_ result: Any?) -> [(Character, String)]? {
        guard let r = result as? [String: Any], let hunks = r["structuredPatch"] as? [[String: Any]], !hunks.isEmpty else { return nil }
        var out: [(Character, String)] = []
        for (i, h) in hunks.enumerated() {
            if i > 0 { out.append(("@", "…")) }
            for l in h["lines"] as? [String] ?? [] {
                guard let c = l.first else { out.append((" ", "")); continue }
                out.append(("+-".contains(c) ? c : " ", String(l.dropFirst())))
            }
        }
        return out
    }
}

// MARK: - Tool activity

/// Consecutive tool calls as one quiet line, like a sentence of what Claude
/// did ("Read 2 files, ran `npm test`"); click for the full list. While
/// working, the line follows the live step. Edit diffs and errors stay in
/// view below it: they're the substance.
struct ClaudeToolGroup: View {
    let items: [ClaudeItem]
    let cwd: String
    @State private var expanded = false
    @State private var hovering = false

    /// Every call failed or was rejected: the error lines say it all.
    private var allFailed: Bool { running == nil && items.allSatisfy { $0.resultIsError } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !allFailed { headlineButton }
            if expanded {
                ClaudeToolList(items: items, cwd: cwd)
                    .transition(.opacity)
            } else {
                // What matters without opening it: diffs of edits made, errors.
                ForEach(items.filter(showsInline)) { item in
                    ClaudeToolInlineResult(item: item, cwd: cwd)
                }
            }
        }
    }

    private var headlineButton: some View {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        if running != nil {
                            ProgressView().controlSize(.small).scaleEffect(0.55)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .frame(width: 12, height: 12)
                    Text(headline)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let r = running, let elapsed = r.elapsed {
                        Text(ClaudeToolInfo.duration(Int(elapsed)))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.leading, -6)
            .accessibilityLabel(headline)
            .accessibilityHint(expanded ? "Hide details" : "Show details")
    }

    /// The tool still running, if any.
    private var running: ClaudeItem? { items.last { $0.result == nil && !$0.finalized } ?? items.last { $0.result == nil } }

    private func showsInline(_ item: ClaudeItem) -> Bool {
        guard item.result != nil else { return false }
        // Changes to existing files, not whole new files (those are one click away).
        return item.resultIsError || ["Edit", "MultiEdit"].contains(item.toolName) || item.toolName == "TodoWrite"
    }

    /// "Read 2 files, ran `npm test`", or the live step while working.
    private var headline: String {
        if let r = running {
            let s = ClaudeToolInfo.summary(r.toolName, r.input, cwd: cwd)
            return ClaudeToolInfo.activeVerb(r.toolName) + (s.isEmpty ? "…" : " " + s)
        }
        // Failed calls are listed below with their error, not counted here.
        return ClaudeToolInfo.headline(items.filter { !$0.resultIsError }, cwd: cwd)
    }
}

/// A finished tool's result shown under the group's line: an edit's diff,
/// the todo list, or an error.
struct ClaudeToolInlineResult: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String

    var body: some View {
        if item.resultIsError, let r = item.result {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(width: 12)
                Text("\(ClaudeToolInfo.displayName(item.toolName)) \(ClaudeToolInfo.summary(item.toolName, item.input, cwd: cwd)): ")
                    .foregroundStyle(.secondary)
                + Text(r.trimmingCharacters(in: .whitespacesAndNewlines))
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            .font(.system(size: 12))
            .lineLimit(3)
            .textSelection(.enabled)
        } else if ClaudeToolInfo.isEdit(item.toolName) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ClaudeToolInfo.summary(item.toolName, item.input, cwd: cwd))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                ClaudeDiffView(lines: ClaudeToolInfo.patchLines(item.toolUseResult)
                    ?? ClaudeToolInfo.diffLines(item.toolName, item.input), maxLines: 12)
            }
        } else if item.toolName == "TodoWrite" {
            ClaudeTodoList(todos: item.input["todos"] as? [[String: Any]] ?? [])
        }
    }
}

/// Consecutive tool calls in one rounded container, one row each,
/// like a list in Xcode's navigator (the expanded tool group).
struct ClaudeToolList: View {
    let items: [ClaudeItem]
    let cwd: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 {
                    Rectangle().fill(Color.claudeSeparator.opacity(0.6)).frame(height: 0.5).padding(.leading, 36)
                }
                ClaudeToolRow(item: item, cwd: cwd)
            }
        }
        .background(RoundedRectangle(cornerRadius: ClaudeStyle.cornerRadius, style: .continuous).fill(Color.claudeFill))
        .overlay(RoundedRectangle(cornerRadius: ClaudeStyle.cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// A tool call: icon, name and a one-line summary; click to expand the full
/// input and result.
struct ClaudeToolRow: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    var nested = false
    @State private var expanded = false
    @State private var hovering = false

    private var isEdit: Bool { ["Edit", "MultiEdit", "Write"].contains(item.toolName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    statusIcon
                    Text(ClaudeToolInfo.displayName(item.toolName))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(ClaudeToolInfo.summary(item.toolName, item.input, cwd: cwd))
                        .font(.system(size: 12, design: item.toolName == "Bash" ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let elapsed = item.elapsed, item.result == nil {
                        Text(ClaudeToolInfo.duration(Int(elapsed)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0)
                }
                .padding(.horizontal, nested ? 0 : 10)
                .frame(height: nested ? 24 : 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            Group {
                // The diff shows once the edit is made (while it waits for
                // permission, the prompt below shows it).
                if isEdit, !expanded, item.result != nil {
                    ClaudeDiffView(lines: ClaudeToolInfo.patchLines(item.toolUseResult)
                        ?? ClaudeToolInfo.diffLines(item.toolName, item.input), maxLines: 12)
                }
                if item.toolName == "TodoWrite", !expanded {
                    ClaudeTodoList(todos: item.input["todos"] as? [[String: Any]] ?? [])
                }
                if !item.children.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(expanded ? item.children : Array(item.children.suffix(3))) { child in
                            ClaudeToolRow(item: child, cwd: cwd, nested: true)
                        }
                        if !expanded && item.children.count > 3 {
                            Text("\(item.children.count - 3) more tool uses")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                }
                if expanded { details }
                if item.resultIsError, !expanded, let r = item.result {
                    Text(r.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, nested ? 26 : 36)
            .padding(.trailing, nested ? 0 : 10)
        }
        .padding(.bottom, nested ? 0 : (hasBody ? 10 : 0))
    }

    private var hasBody: Bool {
        (isEdit && !expanded && item.result != nil) || (item.toolName == "TodoWrite" && !expanded) || !item.children.isEmpty
            || expanded || (item.resultIsError && item.result != nil)
    }

    @ViewBuilder private var statusIcon: some View {
        ZStack {
            if item.result == nil {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
            } else if item.resultIsError {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemRed))
            } else {
                Image(systemName: ClaudeToolInfo.icon(item.toolName))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 17, height: 17)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEdit {
                ClaudeDiffView(lines: ClaudeToolInfo.patchLines(item.toolUseResult)
                    ?? ClaudeToolInfo.diffLines(item.toolName, item.input), maxLines: nil)
            } else if item.toolName == "Bash", let cmd = item.input["command"] as? String {
                ClaudeCodeBlock(language: "bash", code: cmd, compact: true)
            } else if !item.input.isEmpty {
                ClaudeCodeBlock(language: "json", code: ClaudeToolInfo.pretty(item.input), compact: true)
            }
            if let result = item.result, !result.isEmpty, !(isEdit && !item.resultIsError) {
                ClaudeCodeBlock(
                    language: "text",
                    code: String(result.prefix(40_000)) + (result.count > 40_000 ? "\n… (truncated)" : ""),
                    compact: true, title: item.resultIsError ? "Error" : "Output")
            }
        }
    }
}

struct ClaudeTodoList: View {
    let todos: [[String: Any]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let status = todo["status"] as? String ?? "pending"
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: status == "completed" ? "checkmark.circle.fill"
                          : status == "in_progress" ? "circle.dotted.circle" : "circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(status == "completed" ? Color.secondary : status == "in_progress" ? Color.accentColor : Color.secondary)
                    Text((status == "in_progress" ? todo["activeForm"] as? String : nil) ?? todo["content"] as? String ?? "")
                        .font(.system(size: 12.5, weight: status == "in_progress" ? .medium : .regular))
                        .strikethrough(status == "completed")
                        .foregroundStyle(status == "completed" ? .secondary : .primary)
                }
            }
        }
    }
}

// MARK: - Diff

struct ClaudeDiffView: View {
    let lines: [(Character, String)]
    let maxLines: Int?

    var body: some View {
        let shown = maxLines.map { Array(lines.prefix($0)) } ?? lines
        VStack(alignment: .leading, spacing: 0) {
            ClaudeRichText(text: attributed(shown), insets: NSSize(width: 0, height: 6))
            if let maxLines, lines.count > maxLines {
                Text("\(lines.count - maxLines) more lines")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.claudeBackground))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func attributed(_ lines: [(Character, String)]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 8
        para.headIndent = 22
        for (i, (kind, text)) in lines.enumerated() {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
            switch kind {
            case "+":
                attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.14)
            case "-":
                attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.14)
            case "@":
                attrs[.foregroundColor] = NSColor.tertiaryLabelColor
            default:
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            }
            let marker = NSAttributedString(string: kind == "@" ? "  " : "\(kind) ", attributes: attrs.merging(
                [.foregroundColor: kind == "+" ? NSColor.systemGreen : kind == "-" ? NSColor.systemRed : NSColor.tertiaryLabelColor],
                uniquingKeysWith: { $1 }))
            s.append(marker)
            // Pad so the line's background runs the full width.
            s.append(NSAttributedString(string: text + (i < lines.count - 1 ? "\n" : ""), attributes: attrs))
        }
        return s
    }
}

// MARK: - Code block

/// A fenced code block, Bear-quiet: a soft rounded box, the code at
/// a comfortable line height, and nothing else until you hover; then its
/// language, Copy, and (for shell code) Run in Terminal, which pastes it into
/// the terminal sidebar ready to run.
struct ClaudeCodeBlock: View {
    let language: String
    let code: String
    var compact = false
    var title: String?
    var onRun: ((String) -> Void)?
    @State private var copied = false
    @State private var hovering = false

    static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "shell", "console", "fish", "terminal", ""]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ClaudeRichText(
                text: ClaudeSyntax.highlight(
                    code, language: language,
                    font: .monospacedSystemFont(ofSize: compact ? 12 : ClaudeTypography.codeSize, weight: .regular)),
                insets: NSSize(width: compact ? 11 : ClaudeTypography.codeBlockPadding, height: compact ? 7 : 10))
                .background(RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)
                    .fill(Color(nsColor: ClaudeTypography.codeBackground)))
                .overlay(alignment: .topTrailing) {
                    if hovering { controls.padding(6).transition(.opacity) }
                }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if !compact, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
            }
            if let onRun, Self.shellLanguages.contains(language.lowercased()) {
                chip("terminal", "Run in Terminal") { onRun(code) }
                    .help("Paste into the terminal sidebar, ready to run")
            }
            chip(copied ? "checkmark" : "square.on.square", copied ? "Copied" : "Copy") { copy() }
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func chip(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// A Markdown table with Bear's rounded outline around the grid.
struct ClaudeTableBlock: View {
    let text: NSAttributedString

    var body: some View {
        ClaudeRichText(text: text)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: ClaudeTypography.tableBorder), lineWidth: 1))
    }
}
