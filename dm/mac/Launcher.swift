// Mac app launcher: the settings window shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host). Its settings come from the
// app's Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac); the model and the rows are the iOS launcher's (dm/ios/Sources/LauncherSettings.swift, LauncherRow.swift),
// and so is the store: launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown (docs/frontends.md, Saved choices). Basic settings (level basic) come
// first, the others under Advanced settings, each in the list's sections. Play puts the settings into this process's environment, which the host inherits; Quit and closing the window end the
// app without the game. "Show this window at launch" off: no window unless Option is held at launch, and launcher.c applies the saved choices. The window never takes focus by itself: an app
// opened in the background (open -g) keeps its window behind until the player switches to it
import AppKit
import QuartzCore
import SwiftUI

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

/// The host's comparison of the two saves (dm/host/save_sync.c). This launcher links save_sync.o but imports no C header (pack_app.py builds it with swiftc and no bridging
/// header), so the symbol is declared here.
@_silgen_name("save_sync_report")
private func save_sync_report(_ save: UnsafePointer<CChar>, _ title: UnsafePointer<CChar>, _ folder: UnsafePointer<CChar>?, _ waitMs: Int32,
                              _ out: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32

/// Cloud saves before Play: this Mac's save against the cloud's (SaveSyncReport, shared with the iPhone launcher), and the question it needs, as alerts.
/// It runs with the window's Play and, with the window off, before dmMacLauncher returns; DM_LAUNCHER=0 asks nothing (the host takes the newer save).
enum SaveCheck {
    enum Outcome { case play(String?), retry, cancel }

    /// Blocks while the cloud's file comes (SaveSyncReport.waitMs at most): call it off the main thread. nil: no report (sync is then left to the host as before)
    static func report() -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: launcher.c sets DM_SAVE and applies the env files in this process before the window
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        guard let id = info("DMTitleID"), !id.isEmpty else { fputs("launcher: save sync: no DMTitleID\n", stderr); return nil }
        // the folder as launcher.c will pass it (cloud_saves_folder): DM_SAVE_SYNC from the launch environment or an env file, else the window's choice; "0" = off
        let folder = getenv("DM_SAVE_SYNC").map { String(cString: $0) } ?? (UserDefaults.standard.string(forKey: "cloudSaves.folder") ?? "")
        var buf = [CChar](repeating: 0, count: 1024)
        let r = (folder.isEmpty ? "0" : folder).withCString { save_sync_report(save, id, $0, SaveSyncReport.waitMs, &buf, buf.count) }
        let line = String(cString: buf)
        guard r == 0 else { fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr); return nil }
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }

    /// The question the report needs, as a modal alert; `cancel` names the way back ("Cancel" to the window, "Quit" without one)
    static func ask(_ r: SaveSyncReport?, cancel: String) -> Outcome {
        switch SaveSyncReport.step(r) {
        case .play(let choice): return .play(choice)
        case .choose:
            guard let r else { return .play(nil) }
            let a = NSAlert()
            a.messageText = SaveSyncReport.chooseTitle
            a.informativeText = r.chooseMessage(here: "Mac")
            a.alertStyle = .warning
            a.addButton(withTitle: r.localLabel(here: "Mac"))
            a.addButton(withTitle: r.cloudLabel)
            a.addButton(withTitle: cancel)
            a.buttons[0].keyEquivalent = ""   // no default: Return must not pick a save (the newer is not always the one to keep)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play(r.localChoice)
            case .alertSecondButtonReturn: return .play(r.cloudChoice)
            default: return .cancel
            }
        case .unreadable:
            let a = NSAlert()
            a.messageText = SaveSyncReport.unreadableTitle
            a.informativeText = r?.unreadableMessage(here: "Mac") ?? ""
            a.addButton(withTitle: "Play This Mac's Save")
            a.addButton(withTitle: "Try Again")
            a.addButton(withTitle: cancel)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play("offline")   // the mount does not wait for the cloud again
            case .alertSecondButtonReturn: return .retry
            default: return .cancel
            }
        }
    }

    static func apply(_ choice: String?) {
        guard let choice else { return }
        setenv("DM_SAVE_SYNC_CHOICE", choice, 1)
        fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr)
    }

    /// With the window off: the check and its question before the game, the app in front only while it asks. false: the player quit
    static func withoutWindow() -> Bool {
        final class Box: @unchecked Sendable { let lock = NSLock(); var report: SaveSyncReport?; var waiting = false }
        let app = NSApplication.shared
        defer { app.setActivationPolicy(.prohibited) }
        while true {
            let box = Box(), sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let r = report()
                box.lock.lock(); box.report = r; box.lock.unlock()
                sem.signal()
                DispatchQueue.main.async { if box.waiting { app.abortModal() } }   // runs inside the waiting alert's modal loop, if there is one
            }
            if sem.wait(timeout: .now() + 0.5) == .timedOut {   // a cloud file to download: say so, and let the player go on without it
                app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Checking the cloud save…"
                a.informativeText = "Waiting for iCloud to deliver this game's save."
                a.addButton(withTitle: "Play Without It")
                a.addButton(withTitle: "Quit")
                box.waiting = true
                let answer = a.runModal()
                box.waiting = false
                if answer == .alertFirstButtonReturn { apply("offline"); return true }
                if answer == .alertSecondButtonReturn { return false }
                sem.wait()   // aborted: the report is in
            }
            box.lock.lock(); let r = box.report; box.lock.unlock()
            if case .play(let choice) = SaveSyncReport.step(r) { apply(choice); return true }
            app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
            switch ask(r, cancel: "Quit") {
            case .play(let choice): apply(choice); return true
            case .retry: continue
            case .cancel: return false
            }
        }
    }
}

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    let fit: (CGFloat) -> Void
    @AppStorage("window.show") private var show = true
    @AppStorage("window.advanced") private var advanced = false
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info("CFBundleName") ?? "Game").font(.title2.weight(.semibold))
                    Text("Version \(info("CFBundleShortVersionString") ?? "1.0")").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            Form {
                settingSections(basic: true)
                CloudSavesSection()
                Section {
                    DisclosureGroup("Advanced settings", isExpanded: $advanced) {}
                }
                if advanced {
                    settingSections(basic: false)
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                }
            }
            .formStyle(.grouped)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom - $0.containerSize.height
            } action: { _, extraHeight in
                fit(extraHeight)
            }
            HStack {
                Toggle("Show this window at launch", isOn: $show).toggleStyle(.checkbox)
                Spacer()
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking the cloud save…").foregroundStyle(.secondary)
                    Button("Play Without It") { checking = false; SaveCheck.apply("offline"); done(true) }
                }
                Button("Quit") { done(false) }
                Button("Play") { start() }.keyboardShortcut(.defaultAction).disabled(checking)
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560)
    }

    /// Play, once the cloud's save is compared with this Mac's: a save that changed on both sides is the player's pick, not the newer file's (SaveCheck)
    private func start() {
        check += 1; checking = true
        let mine = check
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SaveCheck.report()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveCheck.ask(r, cancel: "Cancel") {
                case .play(let choice): SaveCheck.apply(choice); done(true)
                case .retry: start()
                case .cancel: break   // back to the window, nothing chosen
                }
            }
        }
    }

    @ViewBuilder private func settingSections(basic: Bool) -> some View {
        ForEach(m.sections(basic: basic), id: \.self) { section in
            let rows = m.rows(in: section, basic: basic)
            if !rows.isEmpty {
                Section(section) {
                    ForEach(rows) { SettingRow(s: $0, m: m) }
                }
            }
        }
    }
}

// HookLink: the game launcher in the look of the iPhone's (dm/ios/Sources/Launcher.swift): three tabs, Settings, Play (in the middle, shown first) and Extras, a list on the
// left and a panel on the right. Play keeps the icon, the name and Play on the left; Settings lists every setting by section with the chosen one's control in the panel;
// Extras opens the saves, the logs and the cheats folder in Finder, holds cloud saves, the reset and the credits. Play and Quit work as in LauncherView (the cloud-save check).
private enum HLM {
    static let ground = Color(red: 0.106, green: 0.078, blue: 0.047), bar = Color(red: 0.145, green: 0.106, blue: 0.063), panel = Color(red: 0.055, green: 0.039, blue: 0.024)
    static let line = Color(red: 0.365, green: 0.290, blue: 0.173), trim = Color(red: 0.541, green: 0.439, blue: 0.251), gold = Color(red: 0.788, green: 0.659, blue: 0.353)
    static let text = Color(red: 0.937, green: 0.894, blue: 0.784), dim = Color(red: 0.788, green: 0.722, blue: 0.561), tabOn = Color(red: 0.247, green: 0.192, blue: 0.118)
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .serif) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
}
private struct HLMRow: View {
    let title: String, value: String, chosen: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(HLM.body(14, .bold)).foregroundStyle(HLM.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(value).font(HLM.body(13, .medium)).foregroundStyle(chosen ? HLM.text : HLM.dim).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(Color.white.opacity(chosen ? 0.12 : 0.045))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(chosen ? Color.white : HLM.line, lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
struct HookLinkMacLauncher: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    @AppStorage("window.show") private var show = true
    @State private var tab = 1
    @State private var chosen = "DM_FRAME_MODE"
    @State private var extra = "saves"
    @State private var checking = false
    @State private var check = 0
    @State private var note = ""
    private var save: URL? { getenv("DM_SAVE").map { URL(fileURLWithPath: String(cString: $0)) } }
    private func value(_ s: Setting) -> String {
        let v = m.values[s.env] ?? s.def
        switch s.kind {
        case "choice": return s.options?.first { $0[0] == v }?[1] ?? v
        case "range": return m.rangeLabel(s, Double(v) ?? 1)
        default: return v == s.onValue ? "On" : "Off"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack { Text("HookLink").font(HLM.body(13, .heavy)).foregroundStyle(HLM.dim); Spacer()
                         Toggle("Show at launch", isOn: $show).toggleStyle(.checkbox).font(HLM.body(12)).foregroundStyle(HLM.dim) }.padding(.horizontal, 18)
                HStack(spacing: 0) {
                    ForEach(Array(["Settings", "Play", "Extras"].enumerated()), id: \.offset) { i, t in
                        Button { tab = i } label: {
                            Text(t).font(HLM.body(16, .heavy)).foregroundStyle(tab == i ? Color.white : HLM.dim).padding(.horizontal, 26).frame(height: 42).background(tab == i ? HLM.tabOn : .clear).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 42).background(HLM.bar).overlay(Rectangle().fill(HLM.line).frame(height: 1), alignment: .bottom)
            Rectangle().fill(HLM.trim).frame(height: 2).padding(.horizontal, 40).padding(.top, 6)
            Group {
                if tab == 1 { playTab } else if tab == 0 { settingsTab } else { extrasTab }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HLM.ground)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 540)
    }
    private func panel<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 8) {
            Text(title).font(HLM.serif(22)).foregroundStyle(.white).multilineTextAlignment(.center)
            HStack(spacing: 10) { Rectangle().fill(HLM.trim).frame(height: 1); Rectangle().fill(HLM.gold).frame(width: 7, height: 7).rotationEffect(.degrees(45)); Rectangle().fill(HLM.trim).frame(height: 1) }
            ScrollView { content() }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(HLM.panel).overlay(Rectangle().fill(HLM.line).frame(width: 1), alignment: .leading)
    }
    private var playTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110).accessibilityHidden(true)
                Text(info("CFBundleName") ?? "Game").font(HLM.serif(24)).foregroundStyle(.white).multilineTextAlignment(.center)
                Text("Version \(info("CFBundleShortVersionString") ?? "1.0")").font(HLM.body(13, .medium)).foregroundStyle(HLM.dim)
                Button(action: start) {
                    Text("Play").font(HLM.body(21, .heavy)).foregroundStyle(HLM.ground).frame(maxWidth: .infinity).frame(height: 50)
                        .background(LinearGradient(colors: [Color(red: 0.914, green: 0.776, blue: 0.416), Color(red: 0.773, green: 0.604, blue: 0.204)], startPoint: .top, endPoint: .bottom))
                        .clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 2))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(checking)
                if checking {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the cloud save…").font(HLM.body(12, .medium)).foregroundStyle(HLM.dim) }
                    Button("Play without it") { checking = false; SaveCheck.apply("offline"); done(true) }.buttonStyle(.link)
                }
                Button("Quit") { done(false) }.buttonStyle(.link).foregroundStyle(HLM.dim)
            }
            .padding(30).frame(width: 340)
            panel("How it will run") {
                VStack(spacing: 6) {
                    ForEach(["DM_FRAME_MODE", "DM_RENDER_SCALE", "DM_DYNAMIC_RESOLUTION", "DM_UPSCALER", "DM_FULLSCREEN"].compactMap { e in m.settings.first { $0.env == e } }) { s in
                        HLMRow(title: s.label, value: value(s), chosen: false) { chosen = s.env; tab = 0 }
                    }
                    Text("Click a row to change it in Settings.").font(HLM.body(12, .medium)).foregroundStyle(HLM.dim).padding(.top, 4)
                }
            }
        }
    }
    private var settingsTab: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(m.sections, id: \.self) { section in
                        let rows = m.rows(in: section)
                        if !rows.isEmpty {
                            Text(section).font(HLM.serif(16)).foregroundStyle(HLM.gold).padding(.top, 6)
                            ForEach(rows) { s in HLMRow(title: s.label, value: value(s), chosen: chosen == s.env) { chosen = s.env } }
                        }
                    }
                }.padding(16)
            }.frame(width: 430)
            if let s = m.settings.first(where: { $0.env == chosen }) ?? m.settings.first {
                panel(s.label) {
                    VStack(spacing: 10) {
                        if !s.note.isEmpty { Text(s.note).font(HLM.body(13, .medium)).foregroundStyle(HLM.text).multilineTextAlignment(.center) }
                        SettingRow(s: s, m: m).padding(10).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
    private var extrasTab: some View {
        let items: [(String, String)] = [("saves", "Saves"), ("log", "Game log"), ("cheats", "Cheats folder"), ("cloud", "Cloud saves"), ("reset", "Reset to tested defaults"), ("credits", "Credits")]
        return HStack(spacing: 0) {
            VStack(spacing: 6) { ForEach(items, id: \.0) { it in HLMRow(title: it.1, value: "", chosen: extra == it.0) { extra = it.0; note = "" } } ; Spacer() }.padding(16).frame(width: 340)
            panel(items.first { $0.0 == extra }?.1 ?? "Extras") {
                VStack(spacing: 10) {
                    switch extra {
                    case "saves":
                        Text("Your saves are in this game's folder in your Library. Open it in Finder to copy them or put a save back (with the game closed).").font(HLM.body(13, .medium)).foregroundStyle(HLM.text).multilineTextAlignment(.center)
                        HLMRow(title: "Show the saves in Finder", value: "", chosen: true) { if let u = save { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    case "log":
                        Text("The game's log of the last session and the one before it. Attach it when you report a problem.").font(HLM.body(13, .medium)).foregroundStyle(HLM.text).multilineTextAlignment(.center)
                        HLMRow(title: "Show the logs in Finder", value: "", chosen: true) { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/nxnative")) }
                    case "cheats":
                        Text("Put an Atmosphère cheat file for this game in this folder; the game loads it at start. HookLink ships none. Cheats can break a save: back it up first.").font(HLM.body(13, .medium)).foregroundStyle(HLM.text).multilineTextAlignment(.center)
                        HLMRow(title: "Open the cheats folder", value: "", chosen: true) {
                            if let d = save?.deletingLastPathComponent().appendingPathComponent("cheats") { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); NSWorkspace.shared.open(d) }
                        }
                    case "cloud":
                        Form { CloudSavesSection() }.formStyle(.grouped).frame(height: 220)
                    case "reset":
                        Text("Brings back all settings this game was tested with.").font(HLM.body(13, .medium)).foregroundStyle(HLM.text)
                        HLMRow(title: "Reset to tested defaults", value: m.changed ? "" : "Nothing changed", chosen: m.changed) { m.reset(); note = "Settings are back to the tested defaults." }.disabled(!m.changed)
                    default:
                        Text("HookLink builds on nxnative by seedds and its contributors; cheemu21's kid-with-sword and its contributors (frame generation, steady 30 fps, the touch controls' inspiration); PromethOps, LeonardoBai12 and vladbondarenko97's pull requests; oliverames, Tyuv97G, cshess and gunvalk's testing and findings; and HookShot by NotRexed. HookLink is an unofficial fan project, not affiliated with Nintendo.").font(HLM.body(13, .medium)).foregroundStyle(HLM.text)
                    }
                    if !note.isEmpty { Text(note).font(HLM.body(13, .bold)).foregroundStyle(HLM.gold) }
                }
            }
        }
    }
    private func start() {
        check += 1; checking = true
        let mine = check
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SaveCheck.report()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }
                checking = false
                switch SaveCheck.ask(r, cancel: "Cancel") {
                case .play(let choice): SaveCheck.apply(choice); done(true)
                case .retry: start()
                case .cancel: break
                }
            }
        }
    }
}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        Section {
            LabeledContent("Cloud saves") {
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose)
                    if !folder.isEmpty { Button("Turn off") { folder = "" } }
                }
            }
        } footer: {
            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in the save's -backups folder.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = name; w.isReleasedWhenClosed = false; w.delegate = self
        w.contentMinSize = NSSize(width: 900, height: 540)
        window = w
        w.center()
        let host = NSHostingView(rootView: HookLinkMacLauncher(m: model, done: { [weak self] in self?.finish($0) }))   // HookLink: the tabbed launcher (LauncherView stays for reference)
        host.sizingOptions = []
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }

    func fit(_ extraHeight: CGFloat) {
        guard let w = window, let screen = w.screen else { return }
        let frame = LauncherWindowLayout.fitted(w.frame, extraHeight: extraHeight, visible: screen.visibleFrame)
        if abs(frame.height - w.frame.height) > 0.5 { w.setFrame(frame, display: true) }
    }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        // The main thread blocks in launcher.c's waitpid once run() returns, so the window must leave the screen now: no fade-out (it runs on later run-loop passes),
        // and dmMacLauncher flushes the order-out (AppKit commits it at the end of a pass). Without both, the window stayed on screen, not responding, until the game ended
        w.animationBehavior = .none
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

enum LauncherWindowLayout {
    static func fitted(_ frame: NSRect, extraHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(frame.maxY, visible.maxY)
        let height = min(frame.height + extraHeight, top - visible.minY)
        return NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return 2 }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return 2 }
    if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        return SaveCheck.withoutWindow() ? 2 : 0
    }
    let model = LauncherModel(file.settings)
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    app.run()
    CATransaction.flush()   // finish's order-out
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    return 1
}
