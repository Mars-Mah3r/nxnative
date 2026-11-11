// The launcher's Save editor (Extras): OOT SW2SE by Traiver and contributors (MIT, github.com/Traiver/OOT-SW2SE), the save editor for the Switch 2 Ocarina of Time,
// shown in a WKWebView. Its page (Gen/dm/save-editor.html, the project's editor.html unchanged) talks to its host through the WebView2 bridge; the shim below recreates
// that bridge on WebKit's message handlers, as the project's own macOS host does (macos/OOTSW2SE.swift). The three host actions on the phone:
//   openBackup  the game's own saves (Documents/save: slot_00 ... slot_05 with progress.sav and caption.sav, and option.sav), no picker
//   saveFolder  the edited files written into Documents/save, after the player confirms, with the saves as they were copied to save-backups first
//   savePatch   the patch ZIP written to Documents/save-editor (the Files app shows it), the saves left as they are
// The page is offline (its own Content-Security-Policy blocks all network access) and keeps nothing between launches.
import SwiftUI
import WebKit

private enum SaveEditorLimits {
    static let maxBackupBytes = 8 * 1024 * 1024   // as the project's hosts
    static let maxFileBytes = 2 * 1024 * 1024
    static let slots = 6
}
private let editorPageURL = URL(string: "https://editor.oot.local/index.html")!   // an https origin: the page needs a secure context for crypto.subtle
private let editorShim = """
(() => {
  const listeners = new Set();
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage(message) { window.webkit.messageHandlers.host.postMessage(JSON.stringify(message)); },
    addEventListener(type, listener) { if (type === 'message') listeners.add(listener); },
    removeEventListener(type, listener) { if (type === 'message') listeners.delete(listener); },
  };
  Object.defineProperty(window, '__ootHostReply', { value: data => { for (const listener of listeners) listener({ data }); } });
})();
"""
private struct EditorError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

final class SaveEditorModel: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var confirming = false
    @Published var status = ""
    private(set) var pendingCount = 0
    weak var webView: WKWebView?
    private var pending: (files: [String: Data], id: Int)?
    let saves: URL, backups: URL, exports: URL

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        saves = docs.appendingPathComponent("save"); backups = docs.appendingPathComponent("save-backups"); exports = docs.appendingPathComponent("save-editor")
        super.init()
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin   // only the editor page itself may use the host
        guard message.frameInfo.isMainFrame, origin.protocol == editorPageURL.scheme, origin.host == editorPageURL.host,
              let text = message.body as? String, let data = text.data(using: .utf8),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let action = req["action"] as? String
        if action == "workspace" { return }
        guard let id = req["id"] as? Int, id >= 1 else { return }
        switch action {
        case "openBackup":
            do { reply(id, try readSaves(), nil) } catch { reply(id, nil, error.localizedDescription) }
        case "saveFolder":
            do {
                let files = try decode(req["files"] as? [[String: String]], name: req["name"] as? String)
                pending = (files, id); pendingCount = files.count; confirming = true   // the alert in SaveEditorView answers
            } catch { reply(id, nil, error.localizedDescription) }
        case "savePatch":
            do { reply(id, try writeZip(name: req["name"] as? String, contents: req["contents"] as? String), nil) } catch { reply(id, nil, error.localizedDescription) }
        default:
            reply(id, nil, "Unknown editor action.")
        }
    }

    private func reply(_ id: Int, _ result: Any?, _ error: String?) {
        let payload: [String: Any] = ["id": id, "result": result ?? NSNull(), "error": error ?? NSNull()]
        guard let d = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: d, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__ootHostReply(\(json));", completionHandler: nil)
    }

    // The game's saves as the page reads a backup: "Backup/files/slot_0N/progress.sav" and caption.sav for each slot that has both, and "Backup/files/option.sav"
    private func readSaves() throws -> [[String: String]] {
        let fm = FileManager.default; var out: [[String: String]] = []; var total = 0
        func add(_ url: URL, _ path: String) throws {
            let d = try Data(contentsOf: url)
            guard d.count <= SaveEditorLimits.maxFileBytes else { throw EditorError("\(path) is too large.") }
            total += d.count; guard total <= SaveEditorLimits.maxBackupBytes else { throw EditorError("The saves are too large.") }
            out.append(["relativePath": path, "contents": d.base64EncodedString()])
        }
        for i in 0..<SaveEditorLimits.slots {
            let slot = String(format: "slot_%02d", i), dir = saves.appendingPathComponent(slot)
            let p = dir.appendingPathComponent("progress.sav"), c = dir.appendingPathComponent("caption.sav")
            if fm.fileExists(atPath: p.path) && fm.fileExists(atPath: c.path) { try add(p, "Backup/files/\(slot)/progress.sav"); try add(c, "Backup/files/\(slot)/caption.sav") }
        }
        guard !out.isEmpty else { throw EditorError("There are no saves yet. Play once and save, then come back.") }
        let option = saves.appendingPathComponent("option.sav")
        if fm.fileExists(atPath: option.path) { try add(option, "Backup/files/option.sav") }
        return out
    }

    // The page's patch folder: "<yyyyMMdd_HHmmss>/slot_0N/progress.sav", caption.sav and "<stamp>/option.sav" (manifest.json is a Switch backup's, left out). The same checks
    // as the project's macOS host: the folder name and every path match the editor's own layout, at most 2 MB a file and 8 MB in all. The key is the path under Documents/save
    private func decode(_ entries: [[String: String]]?, name: String?) throws -> [String: Data] {
        let namePat = #"\AOcarina-of-Time-(?:Save|slot_0[0-5])-Patch-([0-9]{8}_[0-9]{6})_[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z"#
        guard let name, let rx = try? NSRegularExpression(pattern: namePat), let m = rx.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let r = Range(m.range(at: 1), in: name), let entries, (1...4).contains(entries.count) else { throw EditorError("The editor sent an invalid patch.") }
        let stamp = String(name[r])
        let pathPat = #"\A"# + stamp + #"/(option\.sav|slot_0[0-5]/(?:progress|caption)\.sav)\z"#
        var files: [String: Data] = [:]; var total = 0
        for e in entries {
            guard let path = e["relativePath"] else { throw EditorError("The editor sent an invalid file.") }
            if path == "manifest.json" { continue }
            guard let prx = try? NSRegularExpression(pattern: pathPat), let pm = prx.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
                  let pr = Range(pm.range(at: 1), in: path), let c = e["contents"], let d = Data(base64Encoded: c), !d.isEmpty, d.count <= SaveEditorLimits.maxFileBytes
            else { throw EditorError("The editor sent an invalid file.") }
            total += d.count; guard total <= SaveEditorLimits.maxBackupBytes else { throw EditorError("The edited files are too large.") }
            files[String(path[pr])] = d
        }
        guard !files.isEmpty else { throw EditorError("Nothing to write.") }
        return files
    }

    // After the player confirms: the whole save folder copied to save-backups/editor-<time>, then each edited file written in place (atomically)
    func apply(_ yes: Bool) {
        guard let p = pending else { return }
        pending = nil
        guard yes else { reply(p.id, nil, nil); return }   // the page says "Save canceled."
        do {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            let backup = backups.appendingPathComponent("editor-" + f.string(from: Date()))
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: saves, to: backup)
            for (path, data) in p.files {
                let url = saves.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            fputs("launcher: save editor wrote \(p.files.keys.sorted().joined(separator: ", ")); the saves before it are in save-backups/\(backup.lastPathComponent)\n", stderr)
            reply(p.id, "Written into your saves. The saves before it are in save-backups/\(backup.lastPathComponent).", nil)
        } catch { reply(p.id, nil, "Could not write the saves: \(error.localizedDescription)") }
    }

    private func writeZip(name: String?, contents: String?) throws -> String {
        guard let contents, let d = Data(base64Encoded: contents), d.count >= 22, d.count <= SaveEditorLimits.maxBackupBytes, d.starts(with: [0x50, 0x4B, 0x03, 0x04])
        else { throw EditorError("The editor did not create a valid patch ZIP.") }
        let file = ((name ?? "") as NSString).lastPathComponent
        let out = exports.appendingPathComponent(file.isEmpty || !file.hasSuffix(".zip") ? "Ocarina-of-Time-Patch.zip" : file)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try d.write(to: out, options: .atomic)
        return "in Files: save-editor/\(out.lastPathComponent)"
    }
}

private struct EditorWeb: UIViewRepresentable {
    let model: SaveEditorModel
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration(); let uc = WKUserContentController()
        uc.addUserScript(WKUserScript(source: editorShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        uc.add(model, name: "host"); cfg.userContentController = uc; cfg.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: .zero, configuration: cfg); v.isOpaque = false; v.backgroundColor = .clear
        model.webView = v
        let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
        if let url = dir?.appendingPathComponent("save-editor.html"), let html = try? String(contentsOf: url, encoding: .utf8) {
            v.loadHTMLString(html.replacingOccurrences(of: "{{EDITOR_VERSION}}", with: "1.0.2"), baseURL: editorPageURL)
        } else {
            v.loadHTMLString("<body style='background:#111;color:#ddd;font:16px -apple-system;padding:24px'>The save editor is missing from this build.</body>", baseURL: nil)
        }
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
    static func dismantleUIView(_ v: WKWebView, coordinator: ()) { v.configuration.userContentController.removeScriptMessageHandler(forName: "host") }
}

struct SaveEditorView: View {
    @StateObject private var model = SaveEditorModel()
    let done: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Save editor").font(.headline)
                Spacer()
                Button("Done", action: done).font(.headline)
            }.padding(.horizontal, 18).padding(.vertical, 10).background(Color.black)
            EditorWeb(model: model)
            Text("OOT SW2SE by Traiver and contributors (MIT). Edits can break a save: the saves before each change are kept in save-backups.")
                .font(.caption2).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity).background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
        .alert("Write these changes into your saves?", isPresented: $model.confirming) {
            Button("Write", role: .destructive) { model.apply(true) }
            Button("Cancel", role: .cancel) { model.apply(false) }
        } message: {
            Text("\(model.pendingCount) file\(model.pendingCount == 1 ? "" : "s") will be replaced. Your saves as they are now are copied to save-backups first.")
        }
    }
}
