// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

// HookLink's launcher: three tabs, Settings, Play (in the middle, shown first) and Extras, laid out as a title bar, a list on the left and a detail panel on the right.
// Play keeps the first launcher's column (the app's icon, its name, its version, Play) on the left and shows how the game will run on the right. Settings lists every
// setting by section; the panel explains the chosen one and holds its control. Extras: saves and the game log through the share sheet, cloud saves, cheat files, reset, credits.
private enum HL {
    static let ground = Color(red: 0.106, green: 0.078, blue: 0.047), bar = Color(red: 0.145, green: 0.106, blue: 0.063), panel = Color(red: 0.055, green: 0.039, blue: 0.024)
    static let line = Color(red: 0.365, green: 0.290, blue: 0.173), trim = Color(red: 0.541, green: 0.439, blue: 0.251), gold = Color(red: 0.788, green: 0.659, blue: 0.353)
    static let text = Color(red: 0.937, green: 0.894, blue: 0.784), dim = Color(red: 0.788, green: 0.722, blue: 0.561), tabOn = Color(red: 0.247, green: 0.192, blue: 0.118)
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .serif) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
}
private enum HLTab: Int, CaseIterable { case settings, play, extras
    var title: String { ["Settings", "Play", "Extras"][rawValue] } }

/// The curled trim under the title bar: two lines that end in a curl at the middle
private struct Trim: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let m = r.midX, y = r.minY + 2
        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: m - 86, y: y))
        p.addQuadCurve(to: CGPoint(x: m - 64, y: y + 9), control: CGPoint(x: m - 68, y: y)); p.addQuadCurve(to: CGPoint(x: m - 82, y: y + 11), control: CGPoint(x: m - 74, y: y + 5))
        p.move(to: CGPoint(x: r.maxX, y: y)); p.addLine(to: CGPoint(x: m + 86, y: y))
        p.addQuadCurve(to: CGPoint(x: m + 64, y: y + 9), control: CGPoint(x: m + 68, y: y)); p.addQuadCurve(to: CGPoint(x: m + 82, y: y + 11), control: CGPoint(x: m + 74, y: y + 5))
        return p
    }
}
private struct Divider2: View {
    var body: some View {
        HStack(spacing: 10) { Rectangle().fill(HL.trim).frame(height: 1); Rectangle().fill(HL.gold).frame(width: 7, height: 7).rotationEffect(.degrees(45)); Rectangle().fill(HL.trim).frame(height: 1) }
    }
}
/// One row of a list: its name on the left, its value on the right, outlined when chosen
private struct HLRow: View {
    let title: String, value: String, chosen: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(HL.body(14, .bold)).foregroundStyle(HL.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(value).font(HL.body(13, .medium)).foregroundStyle(chosen ? HL.text : HL.dim).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(Color.white.opacity(chosen ? 0.12 : 0.045))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(chosen ? Color.white : HL.line, lineWidth: chosen ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
    }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
private struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }

private let hlCredits = """
HookLink builds on other people's work. Thank you to:

nxnative, the engine: seedds and its contributors.

kid-with-sword and its fork: cheemu21 (the touch controls' inspiration, steady 30 fps, frame generation, the 8 GB memory layout), ednofedulo, ChiefSZ13 (the game's profile and bring-up), Pedro Nascimento (lunks), Xipzer, nanotchec, Adrian Smith, Romen Adama Caetano Ramírez, Travis (travislikestocode), uncraftablexd, mmkzer0, Nimesh Ambepitiya, MetaIX, TheGoldfish11, David Padron-Harris, zatteogit, tut, and the author of the oot2 branch.

Pull requests used: PromethOps (#1455, memory), LeonardoBai12 (#1543, real game speed), vladbondarenko97 (#1460, Wide view).

Fixes and testing: oliverames (game speed below 60 fps, iPhone Duo), Tyuv97G (iPhone 17 Pro), cshess, gunvalk (the frame step finding).

HookShot by NotRexed: the name, and the idea of frame generation.

HookLink is an unofficial fan project, not affiliated with Nintendo. You build the game from your own copy.
"""

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var tab: HLTab = .play
    @State private var chosen: String = "DM_FRAME_MODE"
    @State private var extra: String = "saves"
    @State private var share: ShareItems?
    @State private var picking = false
    @State private var note = ""
    @State private var checking = false
    @State private var check = 0   // which Play the running cloud check is for: one the player went on from without it is dropped
    @State private var report: SaveSyncReport?
    @State private var asking: SaveSyncReport.Step?
    @State private var cheatsOn: Set<String> = Set((UserDefaults.standard.string(forKey: "hooklink.cheats") ?? "").split(separator: "\n").map(String.init))

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var version: String { (info("HookLinkVersion") as? String) ?? "1.8" }
    private var playRows: [Setting] {
        let want = ["DM_FRAME_MODE", "DM_RENDER_SCALE", "DM_DYNAMIC_RESOLUTION", "DM_WIDE_VIEW", "DM_PAD_THEME"]
        return want.compactMap { e in m.settings.first { $0.env == e } }
    }
    private func value(_ s: Setting) -> String {
        let v = m.values[s.env] ?? s.def
        switch s.kind {
        case "choice": return s.options?.first { $0[0] == v }?[1] ?? v
        case "range": return m.rangeLabel(s, Double(v) ?? 1)
        default: return v == s.onValue ? "On" : "Off"
        }
    }
    private var storage: String {
        let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Trim().stroke(HL.trim, lineWidth: 2).frame(height: 16).background(HL.ground)
            Group {
                switch tab {
                case .play: playTab
                case .settings: settingsTab
                case .extras: extrasTab
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HL.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .confirmationDialog(SaveSyncReport.chooseTitle, isPresented: isAsking(.choose), titleVisibility: .visible, presenting: report) { r in
            Button(r.localLabel(here: "iPhone")) { go(r.localChoice) }
            Button(r.cloudLabel) { go(r.cloudChoice) }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.chooseMessage(here: "iPhone")) }
        .confirmationDialog(SaveSyncReport.unreadableTitle, isPresented: isAsking(.unreadable), titleVisibility: .visible, presenting: report) { r in
            Button("Play This iPhone's Save") { go("offline") }
            Button("Try Again") { DispatchQueue.main.async { start() } }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.unreadableMessage(here: "iPhone")) }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.folder]) { url in picking = false; importSave(url) } onCancel: { picking = false }
        }
        .task {
            while !Task.isCancelled { memory = os_proc_available_memory(); try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private var titleBar: some View {
        ZStack {
            HStack {
                Text("HookLink \(version)").font(HL.body(14, .heavy)).foregroundStyle(HL.dim)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory) + " free memory").font(HL.body(14, .heavy)).foregroundStyle(HL.dim).monospacedDigit()
            }.padding(.horizontal, 20)
            HStack(spacing: 6) {
                keyCap("L")
                ForEach(HLTab.allCases, id: \.rawValue) { t in
                    Button { tab = t } label: {
                        Text(t.title).font(HL.body(17, .heavy)).foregroundStyle(tab == t ? Color.white : HL.dim)
                            .padding(.horizontal, 28).frame(height: 46).background(tab == t ? HL.tabOn : Color.clear)
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == t ? .isSelected : [])
                }
                keyCap("R")
            }
        }
        .frame(height: 46).background(HL.bar).overlay(Rectangle().fill(HL.line).frame(height: 1), alignment: .bottom)
    }
    private func keyCap(_ t: String) -> some View {
        Text(t).font(HL.body(11, .heavy)).foregroundStyle(HL.ground).frame(width: 24, height: 18).background(HL.dim).clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
    }
    private func panel<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 8) {
            Text(title).font(HL.serif(24)).foregroundStyle(.white).multilineTextAlignment(.center)
            Divider2()
            content()
        }
        .padding(.horizontal, 24).padding(.vertical, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(HL.panel).overlay(Rectangle().fill(HL.line).frame(width: 1), alignment: .leading)
    }

    // Play: the first launcher's column on the left, how the game will run on the right
    private var playTab: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 104, height: 104).clipShape(RoundedRectangle(cornerRadius: 22))
                            .overlay(RoundedRectangle(cornerRadius: 22).stroke(HL.trim, lineWidth: 2)).shadow(color: .black.opacity(0.6), radius: 9, y: 6).accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game").font(HL.serif(25)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")  •  Ready to play").font(HL.body(13, .medium)).foregroundStyle(HL.dim)
                    Button(action: { applyCheats(); start() }) {
                        Text("Play").font(HL.body(22, .heavy)).foregroundStyle(HL.ground).frame(maxWidth: .infinity).frame(height: 54)
                            .background(LinearGradient(colors: [Color(red: 0.914, green: 0.776, blue: 0.416), Color(red: 0.773, green: 0.604, blue: 0.204)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 2))
                            .shadow(color: Color(red: 1, green: 0.925, blue: 0.667).opacity(0.5), radius: 7)
                    }.buttonStyle(.plain).disabled(checking)
                    if checking {
                        HStack(spacing: 6) { ProgressView(); Text("Checking the cloud save…").font(HL.body(13, .medium)).foregroundStyle(HL.dim) }
                        Button("Play without it") { checking = false; go("offline") }.font(HL.body(13, .bold)).foregroundStyle(HL.gold)
                    }
                    if lowDisk { Text("Less than 25 GB free: the game keeps up to about 10 GB of memory on the disk, and it stops when space runs out. Free some space first.").font(HL.body(12, .medium)).foregroundStyle(HL.gold).multilineTextAlignment(.center) }
                }
                .padding(.horizontal, 32).padding(.bottom, 12).frame(width: g.size.width * 0.40, height: g.size.height)
                .background(RadialGradient(colors: [Color(red: 0.231, green: 0.176, blue: 0.098), HL.ground], center: .init(x: 0.5, y: 0.4), startRadius: 10, endRadius: 300))
                panel("How it will run") {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(playRows) { s in HLRow(title: s.label, value: value(s), chosen: false) { chosen = s.env; tab = .settings } }
                            HLRow(title: "Storage", value: storage, chosen: false) {}
                        }
                        Text("Tap a row to change it in Settings.").font(HL.body(13, .medium)).foregroundStyle(HL.dim).padding(.top, 4)
                    }
                }
            }
        }
    }

    // Settings: every setting by section on the left, the chosen one's explanation and control on the right
    private var settingsTab: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(m.sections, id: \.self) { section in
                            let rows = m.rows(in: section)
                            if !rows.isEmpty {
                                Text(section).font(HL.serif(17)).foregroundStyle(HL.gold).padding(.top, 6)
                                ForEach(rows) { s in HLRow(title: s.label, value: value(s), chosen: chosen == s.env) { chosen = s.env } }
                            }
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 8)
                }.frame(width: g.size.width * 0.46)
                if let s = m.settings.first(where: { $0.env == chosen }) ?? m.settings.first {
                    panel(s.label) {
                        ScrollView {
                            VStack(spacing: 8) {
                                let locked = m.fixed.contains(s.env)
                                if !s.note.isEmpty { Text(s.note).font(HL.body(13, .medium)).foregroundStyle(HL.text).multilineTextAlignment(.center) }
                                if locked { Text(m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file").font(HL.body(13, .bold)).foregroundStyle(HL.gold) }
                                control(s).disabled(locked).opacity(locked ? 0.5 : 1)
                            }
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private func control(_ s: Setting) -> some View {
        switch s.kind {
        case "choice":
            VStack(spacing: 5) {
                ForEach(s.options ?? [], id: \.[0]) { o in
                    HLRow(title: o[1], value: (m.values[s.env] ?? s.def) == o[0] ? "Selected" : "", chosen: (m.values[s.env] ?? s.def) == o[0]) { m.values[s.env] = o[0] }
                }
            }
        case "range":
            let b = Binding<Double>(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 }, set: { m.values[s.env] = String(format: "%.2f", $0) })
            VStack(spacing: 6) {
                Text(m.rangeLabel(s, b.wrappedValue)).font(HL.body(17, .heavy)).foregroundStyle(.white).monospacedDigit()
                Slider(value: b, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05).tint(HL.gold).accessibilityLabel(s.label)
            }
        default:
            let on = (m.values[s.env] ?? s.def) == s.onValue
            HStack(spacing: 8) {
                HLRow(title: "On", value: on ? "Selected" : "", chosen: on) { m.values[s.env] = s.onValue }
                HLRow(title: "Off", value: on ? "" : "Selected", chosen: !on) { m.values[s.env] = s.offValue }
            }
        }
    }

    // Extras
    private var extrasTab: some View {
        let items: [(String, String, String)] = [("saves", "Export saves", ""), ("import", "Import a save", ""), ("log", "Export game log", ""), ("cloud", "Cloud saves", ""),
                                                   ("cheats", "Cheats", cheatNames().isEmpty ? "No file" : "\(cheatsOn.intersection(cheatNames()).count) on"),
                                                   ("reset", "Reset to tested defaults", m.changed ? "" : "Nothing changed"), ("credits", "Credits", "")]
        return GeometryReader { g in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) { ForEach(items, id: \.0) { it in HLRow(title: it.1, value: it.2, chosen: extra == it.0) { extra = it.0; note = "" } } }
                        .padding(.horizontal, 18).padding(.vertical, 8)
                }.frame(width: g.size.width * 0.40)
                panel(items.first { $0.0 == extra }?.1 ?? "Extras") { ScrollView { extraDetail } }
            }
        }
    }
    private func words(_ t: String) -> some View { Text(t).font(HL.body(13, .medium)).foregroundStyle(HL.text).multilineTextAlignment(.center).frame(maxWidth: .infinity) }
    @ViewBuilder private var extraDetail: some View {
        VStack(spacing: 8) {
            switch extra {
            case "saves":
                words("Sends a copy of your save folder to Files, AirDrop or another app. Your saves stay on the phone.")
                HLRow(title: "Export saves", value: "", chosen: true) { exportSaves() }
            case "import":
                words("Replaces the game's saves with a save folder you choose. The saves you have now are copied to save-backups first.")
                HLRow(title: "Choose a save folder", value: "", chosen: true) { picking = true }
            case "log":
                words("Sends the game's log of the last session, and the one before it. Share it when something looks or runs wrong.")
                HLRow(title: "Export game log", value: "", chosen: true) { exportLog() }
            case "cloud":
                List { CloudSavesSection() }.listStyle(.insetGrouped).scrollContentBackground(.hidden).frame(height: 230)
            case "cheats":
                let names = cheatNames()
                if names.isEmpty {
                    words("No cheat file found. Put an Atmosphère cheat file for this game (a .txt of [Name] entries) in the app's cheats folder in Files, then come back. HookLink ships none.")
                } else {
                    words("Cheats from your file. They change the running game and can break a save: export your saves first.")
                    ForEach(names, id: \.self) { n in
                        HLRow(title: n, value: cheatsOn.contains(n) ? "On" : "Off", chosen: cheatsOn.contains(n)) {
                            if cheatsOn.contains(n) { cheatsOn.remove(n) } else { cheatsOn.insert(n) }
                            UserDefaults.standard.set(cheatsOn.sorted().joined(separator: "\n"), forKey: "hooklink.cheats")
                        }
                    }
                }
            case "reset":
                words("Brings back all settings this game was tested with.")
                HLRow(title: "Reset to tested defaults", value: "", chosen: m.changed) { m.reset(); note = "Settings are back to the tested defaults." }.disabled(!m.changed)
            default:
                Text(hlCredits).font(HL.body(13, .medium)).foregroundStyle(HL.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !note.isEmpty { Text(note).font(HL.body(13, .bold)).foregroundStyle(HL.gold).multilineTextAlignment(.center) }
        }
    }

    private func exportSaves() {
        let save = docs.appendingPathComponent("save")
        guard let n = try? FileManager.default.contentsOfDirectory(atPath: save.path), !n.isEmpty else { note = "There are no saves yet."; return }
        share = ShareItems(urls: [save])
    }
    private func exportLog() {
        let logs = ["log.txt", "log.prev.txt"].map { docs.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if logs.isEmpty { note = "There is no log yet. Play once first." } else { share = ShareItems(urls: logs) }
    }
    // The chosen folder becomes Documents/save: it must hold a save (account.sav or a slot folder), and the saves there now go to save-backups first
    private func importSave(_ url: URL) {
        let fm = FileManager.default, scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let names = try? fm.contentsOfDirectory(atPath: url.path), names.contains(where: { $0 == "account.sav" || $0.hasPrefix("slot_") }) else { note = "That folder has no save in it (no account.sav or slot folder)."; return }
        let save = docs.appendingPathComponent("save"), f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        do {
            if let old = try? fm.contentsOfDirectory(atPath: save.path), !old.isEmpty {
                let back = docs.appendingPathComponent("save-backups"); try fm.createDirectory(at: back, withIntermediateDirectories: true)
                try fm.moveItem(at: save, to: back.appendingPathComponent(f.string(from: Date()) + " before import"))
            } else { try? fm.removeItem(at: save) }
            try fm.copyItem(at: url, to: save)
            try? fm.removeItem(at: docs.appendingPathComponent("save.work"))
            note = "Imported. The saves you had are in save-backups."
        } catch { note = "The import failed: \(error.localizedDescription)" }
    }
    // The [Name] entries of the cheat files in Documents/cheats (the engine's cheats folder, main.m DM_CHEATS)
    private func cheatNames() -> [String] {
        let dir = docs.appendingPathComponent("cheats"); var out: [String] = []
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let f as URL in e where f.pathExtension == "txt" {
            guard let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for l in t.split(separator: "\n") { let s = l.trimmingCharacters(in: .whitespaces); if s.hasPrefix("[") && s.hasSuffix("]") && s.count > 2 { let n = String(s.dropFirst().dropLast()); if !out.contains(n) { out.append(n) } } }
        }
        return out
    }
    /// The cheats turned on here, for the engine (DM_CHEATS_ON, hle_cheats.c): called by Play
    func applyCheats() {
        let on = cheatsOn.intersection(cheatNames()).sorted()
        if !on.isEmpty { setenv("DM_CHEATS_ON", on.joined(separator: ","), 1); fputs("launcher: cheats on: \(on.joined(separator: ", "))\n", stderr) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
    /// Under 25 GB free: the guest's memory files grow to about 10 GB and the disk guard stops the game near the end (Tyuv97G, HookLink issue 3)
    private var lowDisk: Bool {
        let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        return free < 25_000_000_000
    }

    // Play, once the cloud's save is compared with this iPhone's (upstream's save_sync_report, SaveSyncReport): a save that changed on both sides is the player's pick
    private func isAsking(_ step: SaveSyncReport.Step) -> Binding<Bool> {
        Binding(get: { asking == step }, set: { if !$0 && asking == step { asking = nil } })
    }
    private func start() {
        check += 1; checking = true; asking = nil
        let mine = check
        dm_cloud_saves_env()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.compare()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }
                checking = false
                switch SaveSyncReport.step(r) {
                case .play(let choice): go(choice)
                case let step: report = r; asking = step
                }
            }
        }
    }
    private static func compare() -> SaveSyncReport? {
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        guard save_sync_report(save, dm_save_title(), nil, SaveSyncReport.waitMs, &buf, buf.count) == 0 else {
            fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr); return nil
        }
        let line = String(cString: buf)
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }
    private func go(_ choice: String?) {
        asking = nil
        if let choice { setenv("DM_SAVE_SYNC_CHOICE", choice, 1); fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr) }
        play()
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let model = LauncherModel(file.settings)
    gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = DmHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
