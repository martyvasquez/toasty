import AppKit

// A write to a program that has just died (a Claude Code bridge, a git
// pipe) is an error to handle, not a signal that ends Toasty. Terminal
// shells get the default back (PTYProcess).
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
