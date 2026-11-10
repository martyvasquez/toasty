// POC: run the Agent SDK's own forkSession in JavaScriptCore — no Node.
//
//   jscfork <sdk.mjs> <prelude.js> <cases.json>
// Env: TOASTY_WRITE_ROOT — the only directory writes are allowed under.
import Foundation
import JavaScriptCore
import CryptoKit

let args = CommandLine.arguments
let sdkPath = args[1], preludePath = args[2], casesPath = args[3]
let writeRoot = ProcessInfo.processInfo.environment["TOASTY_WRITE_ROOT"]!
let t0 = Date()
func now() -> Double { Date().timeIntervalSince(t0) * 1000 }

let vm = JSVirtualMachine()!
let ctx = JSContext(virtualMachine: vm)!
ctx.exceptionHandler = { _, e in
    FileHandle.standardError.write("JS exception: \(e?.toString() ?? "?")\n\(e?.objectForKeyedSubscript("stack")?.toString() ?? "")\n".data(using: .utf8)!)
}
let host = JSValue(newObjectIn: ctx)!
func def(_ name: String, _ block: Any) { host.setObject(block, forKeyedSubscript: name as NSString) }

// MARK: bytes <-> Uint8Array without copying through JS
func makeU8(_ data: Data) -> JSValue {
    let c = JSContext.current()!
    let n = data.count
    let p = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 8)
    data.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: n)
    let obj = JSObjectMakeTypedArrayWithBytesNoCopy(c.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, p, n,
                                                    { bytes, _ in bytes?.deallocate() }, nil, nil)
    return JSValue(jsValueRef: obj, in: c)
}
func bytes(_ v: JSValue, _ start: Int = 0, _ end: Int? = nil) -> Data {
    let c = JSContext.current()!.jsGlobalContextRef
    let ref = v.jsValueRef!
    let obj = JSValueToObject(c, ref, nil)
    guard let base = JSObjectGetTypedArrayBytesPtr(c, obj, nil) else { return Data() }
    let len = JSObjectGetTypedArrayLength(c, obj, nil)
    // GetTypedArrayBytesPtr already accounts for byteOffset.
    let s = min(max(start, 0), len), e = min(end ?? len, len)
    guard e > s else { return Data() }
    return Data(bytes: base.advanced(by: s), count: e - s)
}
func fsErr(_ code: String, _ msg: String, _ path: String) -> [String: Any] {
    ["__error": ["code": code, "message": "\(code): \(msg), '\(path)'", "path": path]]
}

def("log", { (s: String) in FileHandle.standardError.write("[js] \(s)\n".data(using: .utf8)!) } as @convention(block) (String) -> Void)
def("now", { now() } as @convention(block) () -> Double)
def("env", { ProcessInfo.processInfo.environment } as @convention(block) () -> [String: String])
def("cwd", { FileManager.default.currentDirectoryPath } as @convention(block) () -> String)
def("home", { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() } as @convention(block) () -> String)
def("tmp", { NSTemporaryDirectory() } as @convention(block) () -> String)
def("arch", { () -> String in
    #if arch(arm64)
    return "arm64"
    #else
    return "x64"
    #endif
} as @convention(block) () -> String)
def("osRelease", { ProcessInfo.processInfo.operatingSystemVersionString } as @convention(block) () -> String)
def("uuid", { UUID().uuidString.lowercased() } as @convention(block) () -> String)
def("randomBytes", { (n: Int) in makeU8(Data((0..<n).map { _ in UInt8.random(in: 0...255) })) } as @convention(block) (Int) -> JSValue)
def("hash", { (alg: String, v: JSValue) -> JSValue in
    let d = bytes(v)
    switch alg.lowercased() {
    case "sha1": return makeU8(Data(Insecure.SHA1.hash(data: d)))
    case "md5": return makeU8(Data(Insecure.MD5.hash(data: d)))
    case "sha512": return makeU8(Data(SHA512.hash(data: d)))
    default: return makeU8(Data(SHA256.hash(data: d)))
    }
} as @convention(block) (String, JSValue) -> JSValue)
def("encode", { (s: String) in makeU8(Data(s.utf8)) } as @convention(block) (String) -> JSValue)
def("utf8Length", { (s: String) in s.utf8.count } as @convention(block) (String) -> Int)
def("decode", { (v: JSValue, s: Int, e: Int) in String(decoding: bytes(v, s, e), as: UTF8.self) } as @convention(block) (JSValue, Int, Int) -> String)
def("toBase64", { (v: JSValue) in bytes(v).base64EncodedString() } as @convention(block) (JSValue) -> String)
def("fromBase64", { (s: String) in makeU8(Data(base64Encoded: s, options: .ignoreUnknownCharacters) ?? Data()) } as @convention(block) (String) -> JSValue)

// MARK: file system (reads anywhere; writes only under TOASTY_WRITE_ROOT)
let fm = FileManager.default
func writable(_ p: String) -> Bool {
    let full = (p as NSString).standardizingPath
    return full.hasPrefix(writeRoot + "/")
}
def("readBytes", { (p: String) -> Any in
    guard let d = fm.contents(atPath: p) else {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
            ? fsErr("EISDIR", "illegal operation on a directory", p) : fsErr("ENOENT", "no such file or directory", p)
    }
    return makeU8(d)
} as @convention(block) (String) -> Any)
def("writeBytes", { (p: String, v: JSValue, append: Bool) -> Any in
    guard writable(p) else { return fsErr("EACCES", "TOASTY SANDBOX: write outside sandbox refused", p) }
    let d = bytes(v)
    if append, let h = FileHandle(forWritingAtPath: p) {
        h.seekToEndOfFile(); h.write(d); h.closeFile()
    } else if !fm.createFile(atPath: p, contents: d, attributes: [.posixPermissions: 0o600]) {
        return fsErr("ENOENT", "no such file or directory", p)
    }
    return NSNull()
} as @convention(block) (String, JSValue, Bool) -> Any)
def("stat", { (p: String, follow: Bool) -> Any in
    var st = stat()
    let r = follow ? stat(p, &st) : lstat(p, &st)
    if r != 0 { return fsErr("ENOENT", "no such file or directory", p) }
    let kind: String
    switch st.st_mode & S_IFMT {
    case S_IFDIR: kind = "dir"
    case S_IFLNK: kind = "link"
    default: kind = "file"
    }
    let ms = { (t: timespec) in Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6 }
    return ["kind": kind, "size": Int(st.st_size), "mtimeMs": ms(st.st_mtimespec), "ctimeMs": ms(st.st_ctimespec),
            "birthtimeMs": ms(st.st_birthtimespec), "mode": Int(st.st_mode), "ino": Int(st.st_ino), "dev": Int(st.st_dev)]
} as @convention(block) (String, Bool) -> Any)
def("readdir", { (p: String) -> Any in
    guard let names = try? fm.contentsOfDirectory(atPath: p) else { return fsErr("ENOENT", "no such file or directory", p) }
    return names.map { n -> [String: String] in
        var st = stat()
        lstat((p as NSString).appendingPathComponent(n), &st)
        let k = (st.st_mode & S_IFMT) == S_IFDIR ? "dir" : (st.st_mode & S_IFMT) == S_IFLNK ? "link" : "file"
        return ["name": n, "kind": k]
    }
} as @convention(block) (String) -> Any)
def("mkdir", { (p: String, rec: Bool) -> Any in
    guard writable(p) else {
        // Creating a directory that already exists is a no-op, not a write.
        var isDir: ObjCBool = false
        if rec, fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return NSNull() }
        return fsErr("EACCES", "TOASTY SANDBOX: mkdir outside sandbox refused", p)
    }
    do { try fm.createDirectory(atPath: p, withIntermediateDirectories: rec) } catch {
        return fsErr(fm.fileExists(atPath: p) ? "EEXIST" : "ENOENT", "\(error)", p)
    }
    return NSNull()
} as @convention(block) (String, Bool) -> Any)
def("realpath", { (p: String) -> Any in
    guard let r = realpath(p, nil) else { return fsErr("ENOENT", "no such file or directory", p) }
    defer { free(r) }
    return String(cString: r)
} as @convention(block) (String) -> Any)
def("readlink", { (p: String) -> Any in
    (try? fm.destinationOfSymbolicLink(atPath: p)) ?? fsErr("EINVAL", "invalid argument", p)
} as @convention(block) (String) -> Any)
def("rename", { (a: String, b: String) -> Any in
    guard writable(a), writable(b) else { return fsErr("EACCES", "TOASTY SANDBOX: rename outside sandbox refused", b) }
    return rename(a, b) == 0 ? NSNull() : fsErr("ENOENT", "rename failed", a)
} as @convention(block) (String, String) -> Any)
def("unlink", { (p: String) -> Any in
    guard writable(p) else { return fsErr("EACCES", "TOASTY SANDBOX: unlink outside sandbox refused", p) }
    return unlink(p) == 0 ? NSNull() : fsErr("ENOENT", "no such file or directory", p)
} as @convention(block) (String) -> Any)
def("after", { (ms: Double, fn: JSValue) in
    DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { fn.call(withArguments: []) }
} as @convention(block) (Double, JSValue) -> Void)

ctx.globalObject.setObject(host, forKeyedSubscript: "__host" as NSString)
if ctx.evaluateScript("typeof URL")!.toString() == "undefined" {
    FileHandle.standardError.write("note: JSC has no URL global\n".data(using: .utf8)!)
}
ctx.evaluateScript(try! String(contentsOfFile: preludePath, encoding: .utf8))

// MARK: translate the SDK module into a script
let tl = now()
var src = try! String(contentsOfFile: sdkPath, encoding: .utf8)
if src.hasPrefix("#!") { src = String(src[src.firstIndex(of: "\n")!...]) }
// 1. imports → hoisted lookups of the Node stand-ins
// import{a as b}from"m" | import*as X from"m" | import X from"m"
let importRE = try! NSRegularExpression(pattern: #"import(?:\{([^}]*)\}|\*as ([A-Za-z_$][\w$]*) | ([A-Za-z_$][\w$]*) )from"([a-z:_/]+)";?"#)
var hoisted: [String] = []
var imports = 0
for m in importRE.matches(in: src, range: NSRange(src.startIndex..., in: src)).reversed() {
    func group(_ i: Int) -> String? { Range(m.range(at: i), in: src).map { String(src[$0]) } }
    let mod = group(4)!
    if let named = group(1) {
        hoisted.append("const{\(named.replacingOccurrences(of: " as ", with: ":"))}=__node(\"\(mod)\");")
    } else {
        hoisted.append("const \(group(2) ?? group(3)!)=__node(\"\(mod)\");")
    }
    src.replaceSubrange(Range(m.range, in: src)!, with: "")
    imports += 1
}
// 2. the export list → globalThis.__sdk
let exportRE = try! NSRegularExpression(pattern: #"export\{([^}]*)\};?\s*$"#)
guard let em = exportRE.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) else { fatalError("no export list") }
let pairs = String(src[Range(em.range(at: 1), in: src)!]).split(separator: ",").map { p -> String in
    let parts = p.components(separatedBy: " as ")
    return parts.count == 2 ? "\(parts[1]):\(parts[0])" : String(p)
}
src.replaceSubrange(Range(em.range, in: src)!, with: "globalThis.__sdk={\(pairs.joined(separator: ","))};")
// 3. import.meta.url → the SDK's own file URL
src = src.replacingOccurrences(of: "import.meta.url", with: "\"file://\(sdkPath)\"")
let script = "(async function(){\"use strict\";\(hoisted.reversed().joined())\n\(src)\n})().then(()=>__host.loaded(),e=>__host.failed(String(e)+'\\n'+(e&&e.stack)))"

var loaded = false
def("loaded", { loaded = true } as @convention(block) () -> Void)
def("failed", { (s: String) in print("LOAD FAILED: \(s)"); exit(1) } as @convention(block) (String) -> Void)
ctx.evaluateScript(script, withSourceURL: URL(fileURLWithPath: sdkPath))
func pump(until done: () -> Bool) {
    let limit = Date() + 60
    while !done() {
        RunLoop.main.run(mode: .default, before: .now + 0.01)
        if Date() > limit { print("TIMEOUT"); exit(2) }
    }
}
pump { loaded }
print(String(format: "SDK loaded in JavaScriptCore: %d imports translated, %.0fms", imports, now() - tl))

// MARK: run the fork cases (same calls the Node bridge makes)
let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: casesPath))) as! [[String: Any]]
var results: [String: Any] = [:]
for c in cases {
    let name = c["name"] as! String
    var done = false
    let start = now()
    let ok: @convention(block) (JSValue) -> Void = { r in
        results[name] = ["sessionId": r.objectForKeyedSubscript("sessionId").toString()!, "ms": Int(now() - start)]; done = true
    }
    let bad: @convention(block) (JSValue) -> Void = { e in results[name] = ["error": e.toString()!]; done = true }
    let opts = JSValue(object: ["dir": c["dir"]!, "upToMessageId": c["upToMessageId"]!, "title": "POC fork"], in: ctx)!
    let p = ctx.objectForKeyedSubscript("__sdk").objectForKeyedSubscript("forkSession").call(withArguments: [c["sessionId"]!, opts])!
    p.invokeMethod("then", withArguments: [JSValue(object: ok, in: ctx)!, JSValue(object: bad, in: ctx)!])
    pump { done }
}
let out = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: out, as: UTF8.self))
