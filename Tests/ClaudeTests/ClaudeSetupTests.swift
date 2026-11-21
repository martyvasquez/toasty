import Foundation
import Testing
@testable import Toasty

@Suite struct ClaudeSetupTests {
    @Test func readsSignedIn() {
        let json = #"{"loggedIn": true, "authMethod": "claude.ai", "email": "a@example.com"}"#
        #expect(ClaudeSetup.parseSignIn(json) == .signedIn(email: "a@example.com"))
        #expect(ClaudeSetup.parseSignIn(#"{"loggedIn": true, "authMethod": "api_key"}"#) == .signedIn(email: nil))
    }

    @Test func readsSignedOut() {
        #expect(ClaudeSetup.parseSignIn(#"{"loggedIn": false}"#) == .signedOut)
    }

    /// An older `claude` without `auth status`, or noise: not held against setup.
    @Test func unreadableIsUnknown() {
        #expect(ClaudeSetup.parseSignIn("") == .unknown)
        #expect(ClaudeSetup.parseSignIn("error: unknown command 'auth'") == .unknown)
        #expect(ClaudeSetup.parseSignIn(#"{"email": "a@example.com"}"#) == .unknown)
    }

    @Test func skipsOutputBeforeTheJSON() {
        #expect(ClaudeSetup.parseSignIn("Welcome!\n{\"loggedIn\": false}") == .signedOut)
    }

    @Test func minimumClaude() {
        #expect(ClaudeSetup.isOlder("2.1.200", than: ClaudeSetup.minimumClaude))
        #expect(!ClaudeSetup.isOlder("2.1.319", than: ClaudeSetup.minimumClaude))
        #expect(!ClaudeSetup.isOlder("2.1.1000", than: ClaudeSetup.minimumClaude))
        #expect(!ClaudeSetup.isOlder("2.2.0", than: ClaudeSetup.minimumClaude))
    }

    @Test func scriptStopsAtFirstFailure() {
        #expect(ClaudeSetup.script([]) == nil)
        let s = ClaudeSetup.script([("Updating Claude Code", "claude update"), ("Signing in to Claude", "claude auth login")])!
        #expect(s.hasPrefix(#"export PATH="$HOME/.local/bin:$PATH" && "#))
        #expect(s.contains("&& claude update && echo && "))
        #expect(s.hasSuffix("&& claude auth login && echo"))
    }
}
