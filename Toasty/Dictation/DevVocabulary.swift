import Foundation

/// The vocabulary Toasty ships with: common developer names, so dictation
/// is right out of the box (the user's own files still come first).
///
/// The engine takes at most 64 terms per dictation, so the catalogue is
/// split by how it's used:
/// - `[core]`: always offered to the engine (names developers say constantly).
/// - `[project]`: offered to the engine only when the repo uses it (a
///   dependency, a config file, its file type), so a Supabase project
///   hears "Supabase" and a Rust project doesn't spend a slot on it.
/// - `[text]`: never offered to the engine; only casing fixes and known
///   mishearings. Names that sound like ordinary words live here (Vue ≈
///   "view", Rust, React, Swift, Next): as engine terms they would turn the
///   ordinary word into the name.
/// Every entry's casing fix and every replacement apply always (casing
/// only for names that aren't ordinary words, as for the user's own terms).
nonisolated enum DevVocabulary {
    enum Tier: String, Sendable { case core, project, text }

    struct Entry: Sendable {
        var term: Vocabulary.Term
        var tier: Tier
    }

    struct Catalogue: Sendable {
        var entries: [Entry] = []
        var replacements: [Vocabulary.Replacement] = []
    }

    static let catalogue: Catalogue = parse(source)

    static func parse(_ text: String) -> Catalogue {
        var catalogue = Catalogue()
        var tier = Tier.text
        var section: [String] = []
        func flush() {
            let file = Vocabulary.parse(section.joined(separator: "\n"))
            catalogue.entries += file.terms.map { term in
                // The brief's rule, enforced: a single ordinary word never
                // reaches the engine (Jest ≈ "just", Stripe, Codex…).
                let ordinary = !term.text.contains(" ") && Vocabulary.isDictionaryWord(term.text)
                return Entry(term: term, tier: ordinary ? .text : tier)
            }
            catalogue.replacements += file.replacements
            section = []
        }
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("["), line.hasSuffix("]"), let t = Tier(rawValue: String(line.dropFirst().dropLast())) {
                flush()
                tier = t
            } else {
                section.append(line)
            }
        }
        flush()
        return catalogue
    }

    // MARK: Relevance

    /// `[project]` entries this repo uses, in catalogue order.
    static func relevant(in folder: String, index: RepoPaths.Index?) -> [Vocabulary.Term] {
        let signals = signals(in: folder, index: index)
        guard !signals.isEmpty else { return [] }
        return catalogue.entries.filter { entry in
            guard entry.tier == .project else { return false }
            let key = squash(entry.term.text)
            return key.count >= 3 && signals.contains { $0.contains(key) || ($0.count >= 4 && key.hasPrefix($0)) }
        }.map(\.term)
    }

    private static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// What a repo says it uses: dependency names, top-level names, and the
    /// languages and tools its files imply.
    static func signals(in folder: String, index: RepoPaths.Index?) -> Set<String> {
        var names = ContextVocabulary.projectNames(in: folder)
        let root = URL(fileURLWithPath: folder)
        func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        for file in ["requirements.txt", "pyproject.toml", "Gemfile", "go.mod", "Podfile", "Package.resolved", "composer.json"] {
            if let text = read(file) { names += text.split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "@" }.map(String.init) }
        }
        if let paths = index?.paths {
            for path in paths {
                if path.count == 1 { names.append(path[0]) }
                if let name = path.last, let dot = name.lastIndex(of: ".") {
                    if let language = extensions[String(name[name.index(after: dot)...]).lowercased()] { names.append(language) }
                }
                if let name = path.last, let tool = files[name] { names.append(tool) }
            }
        }
        return Set(names.map(squash).filter { $0.count >= 2 })
    }

    /// File extension → what it implies.
    static let extensions: [String: String] = [
        "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript",
        "py": "Python", "ipynb": "Jupyter", "rs": "Rust", "go": "Golang", "swift": "Swift", "kt": "Kotlin",
        "java": "Java", "rb": "Ruby", "ex": "Elixir", "exs": "Elixir", "php": "PHP", "cs": "CSharp",
        "tf": "Terraform", "graphql": "GraphQL", "gql": "GraphQL", "prisma": "Prisma", "vue": "Vue",
        "svelte": "Svelte", "proto": "Protobuf", "sql": "SQL", "zig": "Zig", "dart": "Flutter",
        "scss": "Sass", "astro": "Astro", "sol": "Solidity",
    ]

    /// File name → what it implies.
    static let files: [String: String] = [
        "Dockerfile": "Docker", "docker-compose.yml": "Docker Compose", "compose.yaml": "Docker Compose",
        "project.yml": "XcodeGen", "Package.swift": "Swift Package Manager", "Podfile": "CocoaPods",
        "vercel.json": "Vercel", "netlify.toml": "Netlify", "wrangler.toml": "Cloudflare Workers",
        "firebase.json": "Firebase", "tailwind.config.js": "Tailwind CSS", "tailwind.config.ts": "Tailwind CSS",
        "vite.config.ts": "Vite", "vite.config.js": "Vite", "next.config.js": "Next.js", "next.config.mjs": "Next.js",
        "jest.config.js": "Jest", "vitest.config.ts": "Vitest", "playwright.config.ts": "Playwright",
        "pnpm-lock.yaml": "pnpm", "bun.lockb": "Bun", "deno.json": "Deno", "turbo.json": "Turborepo",
        ".eslintrc.json": "ESLint", "eslint.config.js": "ESLint", "biome.json": "Biome",
        "CLAUDE.md": "Claude Code", "AGENTS.md": "Codex", "Cargo.toml": "Cargo", "go.mod": "Golang",
        "Gemfile": "Ruby on Rails", "manage.py": "Django", "schema.prisma": "Prisma", "drizzle.config.ts": "Drizzle",
        "supabase": "Supabase", "kubernetes": "Kubernetes", "k8s": "Kubernetes", "helm": "Helm",
        ".github": "GitHub Actions", ".gitlab-ci.yml": "GitLab CI", "Makefile": "Makefile",
    ]

    // MARK: The catalogue (Vocabulary file format; see Vocabulary.parse)

    static let source = """
    [core]
    Claude Code
    Claude Agent SDK
    Anthropic
    GitHub
    TypeScript
    JavaScript
    MCP server

    [project]
    Supabase
    Firebase
    PostgreSQL
    Postgres
    MySQL
    SQLite
    MongoDB
    Redis
    GraphQL
    Prisma
    Drizzle
    tRPC
    Kubernetes
    Docker Compose
    Terraform
    Vercel
    Netlify
    Cloudflare Workers
    Tailwind CSS
    Next.js
    Node.js
    NestJS
    FastAPI
    Django
    Flask
    Laravel
    Ruby on Rails
    Svelte
    SvelteKit
    Vite
    webpack
    esbuild
    Turborepo
    pnpm
    Vitest
    Jest
    Playwright
    Cypress
    pytest
    ESLint
    Prettier
    Storybook
    Zustand
    Redux
    SwiftUI
    AppKit
    UIKit
    Xcode
    XcodeGen
    CocoaPods
    Swift Package Manager
    Kotlin
    Jetpack Compose
    Flutter
    Elixir
    Phoenix LiveView
    Golang
    TensorFlow
    PyTorch
    NumPy
    Jupyter
    Hugging Face
    LangChain
    OpenAI
    Codex
    Sentry
    Datadog
    Grafana
    Prometheus
    GitHub Actions
    GitLab CI
    CircleCI
    Protobuf
    gRPC
    WebSocket
    WebAssembly
    OAuth
    Stripe
    Twilio
    Auth0
    Clerk
    Resend
    Expo
    React Native
    Electron
    Tauri

    [text]
    # Names that sound like ordinary words: casing and mishearings only.
    React
    Vue
    Rust
    Swift
    Python
    Docker
    Bun
    Deno
    Express
    Remix
    Astro
    Helm
    macOS
    iOS
    iPadOS
    watchOS
    visionOS
    tvOS
    npm
    JSON
    YAML
    TOML
    JWT
    API
    CLI
    SDK
    CSS
    HTML
    HTTP
    HTTPS
    URL
    LLM
    VS Code
    ChatGPT
    localhost
    Homebrew
    Linux
    Ubuntu
    Neovim
    JetBrains
    IntelliJ
    Android Studio
    Objective-C
    WebKit
    Chromium

    # Mishearings (heard -> written). Only phrases no one says otherwise.
    clawed code -> Claude Code
    clawed agent SDK -> Claude Agent SDK
    cloud agent SDK -> Claude Agent SDK
    superbase -> Supabase
    super base -> Supabase
    swift UI -> SwiftUI
    type script -> TypeScript
    java script -> JavaScript
    git hub -> GitHub
    graph QL -> GraphQL
    postgre SQL -> PostgreSQL
    post gres -> Postgres
    mongo DB -> MongoDB
    next JS -> Next.js
    node JS -> Node.js
    nest JS -> NestJS
    fast API -> FastAPI
    tailwind CSS -> Tailwind CSS
    open AI -> OpenAI
    chat GPT -> ChatGPT
    py torch -> PyTorch
    num py -> NumPy
    Xcode gen -> XcodeGen
    web socket -> WebSocket
    web sockets -> WebSockets
    web assembly -> WebAssembly
    mac OS -> macOS
    VS code -> VS Code
    context 7 -> Context7
    """
}
