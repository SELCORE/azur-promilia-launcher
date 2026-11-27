// 아주르 프로밀리아 런처 (비공식)
// 창 하나짜리 macOS 앱이에요. 실제 작업은 앱 안의 Contents/Resources/azurctl.sh가 해요.
import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct AzurLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LauncherModel()
    var body: some Scene {
        WindowGroup("아주르 프로밀리아 런처", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.deliver = { [weak model] url in model?.openPlugURL(url) }
                    appDelegate.onScreenshotKey = { [weak model] in model?.takeScreenshot(fromHotKey: true) }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // 메뉴 막대 아이콘: 상태를 보고 게임을 켜거나 끌 수 있어요 (설정에서 끌 수 있어요).
        // MenuBarExtra는 같은 값을 계속 다시 넣어요. 그대로 받으면 모델이 바뀐 걸로 알려서 화면이 끝없이 다시 그려져요.
        MenuBarExtra("아주르 프로밀리아", systemImage: "gamecontroller.fill",
                     isInserted: Binding(get: { model.menuBar }, set: { v in if model.menuBar != v { model.menuBar = v } })) {
            MenuBarContent().environmentObject(model)
        }
    }
}

/// 넥슨 플러그의 브라우저 로그인(구글, 애플 등)이 끝나면 Safari가 ngm:// (한국) 또는 nexonplug:// (일본)
/// 링크를 이 앱에 넘겨요.
/// SwiftUI는 링크가 올 때마다 창을 새로 열어서, 링크 이벤트를 여기서 먼저 받아요.
/// 링크에 로그인 토큰이 들어 있어서 화면이나 기록에 남기지 않아요.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [String] = []
    /// 창이 뜨면 모델에 연결돼요. 링크로 앱이 처음 켜졌을 때는 그때까지 링크를 들고 있어요.
    var deliver: ((String) -> Void)? { didSet { flush() } }
    /// ⌘⇧9 (게임 스크린샷)이 눌리면 불려요.
    var onScreenshotKey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        registerScreenshotHotKey()
    }

    /// ⌘⇧9를 전역 단축키로 등록해요. 게임이 앞에 있어도 받아요. (Carbon 단축키라 손쉬운 사용 권한이 필요 없어요.)
    private func registerScreenshotHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in me.onScreenshotKey?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x415A_5552), id: 1)   // 'AZUR'
        RegisterEventHotKey(UInt32(kVK_ANSI_9), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              ["ngm:", "nexonplug:"].contains(where: url.lowercased().hasPrefix) else { return }
        pending.append(url)
        flush()
    }

    private func flush() {
        guard let deliver, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        urls.forEach(deliver)
    }
}

// MARK: - 모델

/// 아주르 프로밀리아 커뮤니티(forum.nexon.com/azurpromilia)의 고정 글. 넥슨 플러그 게임 화면의 소식과 같은 목록이에요.
struct NewsItem: Identifiable {
    let id: String        // 글 번호 (숫자만)
    let board: String     // 게시판 이름 (공지사항, 이벤트, …)
    let title: String
    let date: Date

    var url: URL? { URL(string: "https://forum.nexon.com/azurpromilia/board_view?thread=\(id)") }
    var shortBoard: String { board == "공지사항" ? "공지" : board }
    var badgeColor: Color {
        if board.contains("공지") { return Color(hex: "#ffd166") }
        if board.contains("이벤트") { return Color(hex: "#7ee08a") }
        if board.contains("업데이트") || board.contains("점검") { return Color(hex: "#ff9a8a") }
        return Color(hex: "#a9d4ff")
    }
}


@MainActor
final class LauncherModel: ObservableObject {
    enum State { case checking, needsSetup, ready }

    @Published var state: State = .checking
    @Published var running = false
    @Published var plugRunning = false
    @Published var gameRunning = false
    @Published var gameCPU = 0
    /// 게임시작을 누른 뒤 게임이 켜지기 전: "login"(넥슨 플러그 로그인 중), "ngm"(NGM이 게임을 켜는 중), 아니면 "none"
    @Published var stage = "none"
    @Published var playAge = 0
    @Published var onBattery = false
    /// wineserver 없이 Wine 프로세스만 남은 상태 (멈춘 찌꺼기, CPU를 계속 쓸 수 있어요)
    @Published var stale = false
    /// 넥슨 플러그 실행/종료를 처리하는 중 (버튼을 두 번 누르지 않게)
    @Published var acting = false
    @Published var busy = false
    @Published var progress = ""
    @Published var errorText: String?

    @Published var metalHud = false
    @Published var retina = false
    @Published var leftCmdCtrl = false
    @Published var gameHangul = true
    @Published var gameMode = true
    @Published var minimizePlug = true
    @Published var avx2 = true
    @Published var afterGame = "restore"
    @Published var batteryFps = true
    @Published var menuBar = true { didSet { if menuBar != oldValue { save("menu_bar", menuBar) } } }
    @Published var screenshotKey = true
    @Published var autoPlay = false
    /// 넥슨 플러그 게임 화면과 같은 그림 (background, game_logo, game_banner). 넥슨 공개 API에서 받아 이 맥에만 저장해요.
    @Published var art: [String: NSImage] = [:]
    @Published var keyColor = Color(hex: "#21639a")
    /// 커뮤니티 고정 글 (최신 순)
    @Published var news: [NewsItem] = []
    @Published var newsFailed = false
    private var autoPlayed = false
    @Published var customResolution = false
    @Published var width = "1920"
    @Published var height = "1200"
    @Published var customFps = false
    @Published var fps = "60"

    // 다운로드 상태 (none|downloading|stalled|stopped|installed)
    @Published var downloadState = "none"
    @Published var gameGB = "0.0"
    // 새 버전
    @Published var newVersion: String?
    @Published var newVersionURL: URL?
    // 알림 창
    @Published var notice: String?

    let repo = "SELCORE/azur-promilia-launcher"
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var loading = false
    private var pollTask: Task<Void, Never>?
    private var staleCount = 0

    let ctl = (Bundle.main.resourceURL ?? URL(fileURLWithPath: Bundle.main.bundlePath))
        .appendingPathComponent("azurctl.sh").path
    var appHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Azur Promilia Launcher")
    }

    init() {
        // 상태 확인은 한 줄로 차례대로 돌려요. 앞의 확인이 끝나기 전에 다음 확인이 겹쳐 쌓이지 않아요.
        pollTask = Task { [weak self] in
            await self?.refresh()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.refreshRunning()
                if tick % 3 == 0 { await self.refreshDownload() }   // 다운로드 상태는 15초에 한 번
                if tick % 720 == 719 { await self.loadNews() }      // 소식은 한 시간에 한 번
                tick += 1
            }
        }
        Task { await checkForUpdate() }
        Task { await loadArt() }
        Task { await loadNews() }
    }

    /// bash로 명령을 실행해요. onLine이 있으면 한 줄씩 넘겨줘요.
    /// - timeout: 이 시간(초)이 지나도 안 끝나면 멈춰요. nil이면 끝날 때까지 기다려요(준비처럼 오래 걸리는 일).
    /// 스크립트가 띄운 Wine/wineserver가 출력 파이프를 물고 있어도, 스크립트가 끝나면 기다리지 않고 돌아와요.
    nonisolated func shell(_ args: [String], timeout: TimeInterval? = 30,
                           onLine: (@Sendable (String) -> Void)? = nil) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                let lock = NSLock()
                var out = Data()
                let eof = DispatchSemaphore(value: 0)
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; eof.signal(); return }
                    lock.lock(); out.append(d); lock.unlock()
                    if let onLine {
                        let s = String(decoding: d, as: UTF8.self)
                        for line in s.split(whereSeparator: \.isNewline) where !line.isEmpty { onLine(String(line)) }
                    }
                }
                do { try p.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: (-1, "실행하지 못했어요: \(error.localizedDescription)"))
                    return
                }
                var timedOut = false
                if let timeout {
                    let deadline = Date().addingTimeInterval(timeout)
                    while p.isRunning && Date() < deadline { usleep(50_000) }
                    if p.isRunning {
                        timedOut = true
                        p.terminate()
                        usleep(500_000)
                        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    }
                }
                p.waitUntilExit()
                _ = eof.wait(timeout: .now() + 1)   // 남은 출력은 1초만 기다려요
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock(); let all = out; lock.unlock()
                var text = String(decoding: all, as: UTF8.self)
                if timedOut { text += "\n시간이 너무 오래 걸려서 멈췄어요. 다시 해 보고, 계속 그러면 문제 보고를 눌러 주세요." }
                cont.resume(returning: (timedOut ? -2 : p.terminationStatus, text))
            }
        }
    }

    func ctlRun(_ args: String..., timeout: TimeInterval? = 30) async -> (Int32, String) {
        await shell([ctl] + args, timeout: timeout)
    }

    func refresh() async {
        let (_, code) = await ctlRun("status-code")
        state = code.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" ? .ready : .needsSetup
        await loadSettings()
        await refreshRunning()
        // 런처를 열면 바로 게임 시작 (설정), 앱을 연 처음 한 번만
        if !autoPlayed, autoPlay, state == .ready, !running {
            autoPlayed = true
            play()
        }
        autoPlayed = true
    }

    /// 넥슨 플러그가 게임 화면에 쓰는 그림과 색을 넥슨 공개 API에서 받아요 (넥슨 플러그와 같은 요청).
    /// 받은 그림은 ~/Library/Application Support/Azur Promilia Launcher/cache/art에만 두고, 바뀌었을 때만 다시 받아요.
    func loadArt() async {
        let dir = appHome.appendingPathComponent("cache/art")
        let keys = ["background", "game_logo", "game_banner"]
        for k in keys where art[k] == nil {
            if let img = NSImage(contentsOf: dir.appendingPathComponent(k)) { art[k] = img }
        }
        if let c = try? String(contentsOf: dir.appendingPathComponent("key_color"), encoding: .utf8) { keyColor = Color(hex: c) }
        guard let api = URL(string: "https://public.api.nexon.com/nexonplug/sdkapi/contents/nx-plug/v2/game/2887") else { return }
        var req = URLRequest(url: api)
        req.setValue("nx-plug", forHTTPHeaderField: "client-type")
        req.setValue("2514", forHTTPHeaderField: "gid")       // 넥슨 플러그의 서비스 번호
        req.setValue("ko_KR", forHTTPHeaderField: "locale")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let images = result["images"] as? [String: Any] else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for k in keys {
            guard let s = images[k] as? String, let u = URL(string: s), u.scheme == "https" else { continue }
            let urlFile = dir.appendingPathComponent(k + ".url")
            if (try? String(contentsOf: urlFile, encoding: .utf8)) == s, art[k] != nil { continue }
            guard let (d, resp) = try? await URLSession.shared.data(from: u),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: d) else { continue }
            try? d.write(to: dir.appendingPathComponent(k))
            try? s.write(to: urlFile, atomically: true, encoding: .utf8)
            art[k] = img
        }
        if let c = result["key_color"] as? String, c.hasPrefix("#"), c.count == 7 {
            keyColor = Color(hex: c)
            try? c.write(to: dir.appendingPathComponent("key_color"), atomically: true, encoding: .utf8)
        }
    }

    /// 커뮤니티 고정 글을 넥슨 공개 API에서 받아요 (넥슨 플러그 게임 화면과 같은 요청, 로그인 정보 없음).
    /// 마지막으로 받은 목록은 cache/news.json에 두고, 받기 전이나 인터넷이 없을 때 그걸 보여 줘요.
    func loadNews() async {
        let cache = appHome.appendingPathComponent("cache/news.json")
        if news.isEmpty, let d = try? Data(contentsOf: cache), let items = Self.parseNews(d), !items.isEmpty { news = items }
        guard let api = URL(string: "https://public.api.nexon.com/nexonplug-cache/community/community/621/stickyThreadsV2?alias=azurpromilia") else { return }
        var req = URLRequest(url: api)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let items = Self.parseNews(data), !items.isEmpty else {
            newsFailed = news.isEmpty
            return
        }
        news = items
        newsFailed = false
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
    }

    nonisolated static func parseNews(_ data: Data) -> [NewsItem]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["stickyThreads"] as? [[String: Any]] else { return nil }
        func text(_ v: Any?) -> String? { (v as? String) ?? (v as? NSNumber)?.stringValue }
        var items: [NewsItem] = []
        for t in list {
            guard let id = text(t["threadId"]), !id.isEmpty, id.allSatisfy(\.isNumber),
                  let raw = text(t["title"]) else { continue }
            let board = text(t["boardTitle"]) ?? text(t["headlineName"]) ?? ""
            let secs = Double(text(t["createDate"]) ?? "") ?? 0
            var title = cleanTitle(raw)
            if let bar = title.firstIndex(of: "|"),
               title[..<bar].trimmingCharacters(in: .whitespaces) == board,
               !title[title.index(after: bar)...].trimmingCharacters(in: .whitespaces).isEmpty {
                title = title[title.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            }
            items.append(NewsItem(id: id, board: board, title: title, date: Date(timeIntervalSince1970: secs)))
        }
        return items.sorted { $0.date > $1.date }
    }

    /// "&lt;바니 페스타&gt;" 같은 제목을 "<바니 페스타>"로 정리하고 이모지를 빼요.
    nonisolated static func cleanTitle(_ s: String) -> String {
        var t = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        // 이모지는 모두 빼요 (숫자, #, * 같은 글자는 남겨요)
        t = String(String.UnicodeScalarView(t.unicodeScalars.map { u -> Unicode.Scalar in
            let pr = u.properties
            let emoji = pr.isEmojiPresentation || (pr.isEmoji && u.value >= 0x2000) || u.value == 0xFE0F || u.value == 0x200D
                || (0x1F3FB...0x1F3FF).contains(u.value) || (0xE0020...0xE007F).contains(u.value)
            return emoji ? " " : u
        }))
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func refreshRunning() async {
        let (_, r) = await ctlRun("live")
        var kv: [String: String] = [:]
        for part in r.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { kv[pair[0]] = pair[1] }
        }
        let s = kv["running"] ?? "no"
        running = s == "yes"
        plugRunning = kv["plug"] == "yes"
        gameRunning = kv["game"] == "yes"
        gameCPU = Int(kv["game_cpu"] ?? "0") ?? 0
        onBattery = kv["battery"] == "yes"
        stage = kv["stage"] ?? "none"
        playAge = Int(kv["play_age"] ?? "0") ?? 0
        // 켜거나 끄는 순간에도 잠깐 stale로 보일 수 있어서, 두 번 연속일 때만 알려요.
        staleCount = s == "stale" ? staleCount + 1 : 0
        stale = staleCount >= 2 && !acting
    }

    func refreshDownload() async {
        guard state == .ready else { return }
        let (_, out) = await ctlRun("download-status")
        for part in out.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "state" { downloadState = kv[1] }
            if kv[0] == "game_gb" { gameGB = kv[1] }
        }
    }

    /// GitHub 릴리스에서 이 앱보다 새 버전(v로 시작하는 태그)이 있는지 봐요.
    func checkForUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=15") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for rel in list {
            guard let tag = rel["tag_name"] as? String, tag.hasPrefix("v"),
                  (rel["draft"] as? Bool) != true else { continue }
            let v = String(tag.dropFirst())
            if isNewer(v, than: appVersion) {
                newVersion = v
                newVersionURL = URL(string: rel["html_url"] as? String ?? "")
            }
            return   // 가장 최근 앱 릴리스만 비교해요
        }
    }

    func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 문제 보고: 상태와 로그(개인정보 가림)를 모아 클립보드에 복사하고 GitHub 이슈 양식을 열어요.
    func report() {
        Task {
            let (_, out) = await shell(["-c", "AZUR_APP_VERSION=\"$1\" \"$0\" report", ctl, appVersion], timeout: 90)
            let file = appHome.appendingPathComponent("logs/report.md")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? out.write(to: file, atomically: true, encoding: .utf8)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(out, forType: .string)
            if let url = URL(string: "https://github.com/\(repo)/issues/new?template=bug_report.yml") {
                NSWorkspace.shared.open(url)
            }
            notice = "문제 보고 내용을 클립보드에 복사했어요. 열린 GitHub 이슈 양식의 \"런처 보고 내용\" 칸에 붙여 넣어 주세요.\n로그인 토큰, 이메일, 맥 사용자 이름은 가려져 있어요. 같은 내용이 logs/report.md에도 저장돼요."
        }
    }

    /// 지우기: keepGame이면 받은 게임은 남겨요.
    func uninstall(keepGame: Bool) {
        busy = true
        Task {
            let (status, out) = await ctlRun("uninstall", keepGame ? "--keep-game" : "--all", timeout: nil)
            busy = false
            notice = status == 0
                ? out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n앱 자체는 응용 프로그램 폴더에서 휴지통으로 옮기면 지워져요."
                : out.trimmingCharacters(in: .whitespacesAndNewlines)
            await refresh()
        }
    }

    func loadSettings() async {
        loading = true
        defer { loading = false }
        let (_, out) = await ctlRun("settings")
        var kv: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        metalHud = kv["metal_hud"] == "1"
        retina = kv["retina"] == "1"
        leftCmdCtrl = kv["left_cmd_ctrl"] == "1"
        gameHangul = kv["game_hangul"] != "0"
        gameMode = kv["game_mode"] != "0"
        minimizePlug = kv["minimize_plug"] != "0"
        avx2 = kv["avx2"] != "0"
        afterGame = kv["after_game"] ?? "restore"
        batteryFps = kv["battery_fps"] != "0"
        menuBar = kv["menu_bar"] != "0"
        screenshotKey = kv["screenshot_key"] != "0"
        autoPlay = kv["auto_play"] == "1"
        customResolution = kv["custom_resolution"] == "1"
        customFps = kv["custom_fps"] == "1"
        width = kv["width"] ?? "1920"
        height = kv["height"] ?? "1200"
        fps = kv["fps"] ?? "60"
    }

    func save(_ key: String, _ value: String) {
        guard !loading else { return }
        // 숫자는 저장하기 전에 여기서 먼저 확인해요 (잘못된 값으로 스크립트를 부르지 않게).
        let limits: [String: (ClosedRange<Int>, String)] = [
            "width": (640...16384, "가로 해상도는 640에서 16384 사이 숫자로 넣어 주세요."),
            "height": (480...16384, "세로 해상도는 480에서 16384 사이 숫자로 넣어 주세요."),
            "fps": (30...360, "주사율은 30에서 360 사이 숫자로 넣어 주세요."),
        ]
        if let (range, message) = limits[key] {
            guard let n = Int(value), range.contains(n) else {
                errorText = message
                Task { await loadSettings() }
                return
            }
        }
        Task {
            let (status, out) = await ctlRun("set", key, value)
            if status != 0 {
                errorText = out.trimmingCharacters(in: .whitespacesAndNewlines)
                await loadSettings()
            } else {
                errorText = nil
            }
        }
    }

    func save(_ key: String, _ on: Bool) { save(key, on ? "1" : "0") }

    func setup() {
        busy = true
        errorText = nil
        progress = "준비를 시작해요…"
        Task {
            let (status, out) = await shell(
                ["-c", "\"$0\" setup $(\"$0\" detect-sources)", ctl],
                timeout: nil,
                onLine: { line in
                    Task { @MainActor [weak self] in
                        if line.hasPrefix("==>") || line.hasPrefix("받는 중") || line.contains("완료") {
                            self?.progress = line.replacingOccurrences(of: "==> ", with: "")
                        }
                    }
                })
            busy = false
            if status != 0 {
                let lastLines = out.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
                errorText = "준비하다가 문제가 생겼어요.\n\(lastLines)"
            }
            try? out.write(to: appHome.appendingPathComponent("logs/setup.log"), atomically: true, encoding: .utf8)
            await refresh()
        }
    }

    func launchPlug() {
        guard !acting else { return }
        acting = true
        Task {
            let (status, out) = await ctlRun("plug", timeout: 120)
            errorText = status == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            acting = false
            await refreshRunning()
        }
    }

    /// 넥슨 플러그를 켜고 로그인되면 바로 게임을 실행해요 (azurctl.sh play).
    func play() {
        guard !acting else { return }
        acting = true
        Task {
            let (status, out) = await ctlRun("play", timeout: 120)
            errorText = status == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            acting = false
            await refreshRunning()
        }
    }

    var statusLine: String {
        var s: String
        if gameRunning { s = "게임 실행 중 · CPU \(gameCPU)%" }
        else if stage == "ngm" { s = "게임 켜는 중 · \(playAge)초" }
        else if stage == "login" { s = "넥슨 플러그 로그인 중 · \(playAge)초" }
        else if plugRunning { s = "넥슨 플러그 켜짐" }
        else if stale { s = "Wine 프로세스가 남아 있어요" }
        else { s = "꺼져 있음" }
        if onBattery { s += " · 배터리" }
        return s
    }

    /// 런타임 파일을 검사하고, 다르거나 검사 기준이 없으면 고쳐요.
    func checkRuntime() {
        guard !busy else { return }
        busy = true
        progress = "런타임 파일을 검사하는 중…"
        Task {
            let (_, out) = await ctlRun("verify-runtime", timeout: 300)
            let lines = out.split(whereSeparator: \.isNewline).map(String.init)
            if lines.last == "result=ok" {
                notice = "런타임 파일이 모두 받았을 때 그대로예요."
            } else if running {
                notice = lines.dropLast().joined(separator: "\n") + "\n넥슨 플러그와 게임을 종료한 뒤 다시 눌러 주세요. 그때 고쳐요."
            } else {
                progress = "런타임 파일을 고치는 중… (받아 둔 파일이 없으면 약 296MB를 받아요)"
                let (status, fixOut) = await ctlRun("repair-runtime", timeout: nil)
                notice = fixOut.trimmingCharacters(in: .whitespacesAndNewlines)
                if status != 0 { errorText = notice; notice = nil }
            }
            busy = false
            progress = ""
        }
    }

    /// 이 맥 화면에 맞는 권장 값: Retina는 끄고, 게임 해상도는 화면 크기(포인트)로.
    var recommendedResolution: (width: Int, height: Int, scale: CGFloat) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = screen?.frame.size ?? CGSize(width: 1920, height: 1200)
        return (Int(size.width) / 2 * 2, Int(size.height) / 2 * 2, screen?.backingScaleFactor ?? 2)
    }

    func applyRecommendedResolution() {
        let r = recommendedResolution
        retina = false
        customResolution = true
        width = String(r.width)
        height = String(r.height)
        save("retina", false)
        save("custom_resolution", true)
        save("width", width)
        save("height", height)
        notice = "Retina를 끄고 게임 해상도를 \(r.width)×\(r.height)로 맞췄어요. 넥슨 플러그를 다시 켜면 적용돼요."
    }

    /// 게임 화면을 ~/Pictures/Azur Promilia에 PNG로 저장해요 (macOS screencapture로 게임 창만 찍어요).
    func takeScreenshot(fromHotKey: Bool = false) {
        if fromHotKey && !screenshotKey { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            notice = "스크린샷을 찍으려면 화면 기록 권한이 필요해요.\n시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹화에서 '아주르 프로밀리아 런처'를 켠 뒤 런처를 다시 열어 주세요."
            return
        }
        let gamePIDs = Set(NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == "AzurPromilia.exe" || ($0.bundleIdentifier ?? "").hasSuffix(".AzurPromilia.exe")
        }.map(\.processIdentifier))
        let windows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let game = windows.filter {
            let pid = $0[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let owner = $0[kCGWindowOwnerName as String] as? String ?? ""
            return ($0[kCGWindowLayer as String] as? Int) == 0 && (gamePIDs.contains(pid) || owner.contains("AzurPromilia"))
        }.max { a, b in
            func area(_ w: [String: Any]) -> CGFloat {
                let r = CGRect(dictionaryRepresentation: (w[kCGWindowBounds as String] as! CFDictionary)) ?? .zero
                return r.width * r.height
            }
            return area(a) < area(b)
        }
        guard let id = game?[kCGWindowNumber as String] as? Int else {
            if !fromHotKey { notice = "게임 창을 찾지 못했어요. 게임이 켜져 있을 때 찍어 주세요." }
            return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Azur Promilia")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let file = dir.appendingPathComponent("Azur Promilia \(f.string(from: Date())).png")
        Task {
            _ = await shell(["-c", "/usr/sbin/screencapture -x -o -l\"$0\" \"$1\"", String(id), file.path], timeout: 15)
            if FileManager.default.fileExists(atPath: file.path) {
                NSSound(named: "Tink")?.play()
            } else {
                errorText = "스크린샷을 저장하지 못했어요."
            }
        }
    }

    func openScreenshots() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Azur Promilia")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 브라우저 로그인을 마치고 돌아온 ngm:// / nexonplug:// 링크를 넥슨 플러그에 넘겨요 (azurctl.sh open-url).
    /// 넥슨 플러그가 꺼져 있으면 켜면서 넘겨요.
    func openPlugURL(_ url: String) {
        Task {
            let (status, out) = await ctlRun("open-url", url, timeout: 120)
            if status != 0 {
                errorText = "브라우저 로그인 결과를 넥슨 플러그에 넘기지 못했어요.\n"
                    + out.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                await bringPlugForward()
            }
            await refreshRunning()
        }
    }

    /// Safari가 링크를 이 앱에 넘기면 macOS가 런처를 앞으로 꺼내요. 로그인 결과를 받는 건 넥슨 플러그라서
    /// 넥슨 플러그를 앞으로 보내요. 방금 켰으면 나타날 때까지 20초까지 기다려요.
    func bringPlugForward() async {
        for _ in 0..<40 {
            let plug = NSWorkspace.shared.runningApplications.first {
                $0.localizedName == "NexonPlug.exe" || ($0.bundleIdentifier ?? "").hasSuffix(".NexonPlug.exe")
            }
            if let plug {
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: plug)
                    plug.activate()
                } else {
                    plug.activate(options: [.activateIgnoringOtherApps])
                }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// 넥슨 플러그와 게임을 끄고, 서버를 잃고 남은 Wine 프로세스도 정리해요.
    func stop() {
        guard !acting else { return }
        acting = true
        stale = false
        Task {
            _ = await ctlRun("stop", timeout: 60)
            acting = false
            staleCount = 0
            await refreshRunning()
        }
    }

    func openLogs() {
        let logs = appHome.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }
}

// MARK: - 화면

struct ContentView: View {
    @EnvironmentObject var m: LauncherModel
    @State private var showSettings = false
    @State private var newsTab = 0   // 0 전체, 1 공지, 2 이벤트

    static let width: CGFloat = 960
    static let heroHeight: CGFloat = 412   // 제목 줄 아래부터. 그림은 제목 줄 뒤까지 이어져요.
    static let barHeight: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            hero
            bottomBar
        }
        .frame(width: Self.width, height: Self.heroHeight + Self.barHeight)
        // 배경 그림만 창 제목 줄 뒤까지 그려요 (창 버튼이 그림 위에 떠요).
        .background(alignment: .top) { heroArt.ignoresSafeArea() }
        .background(Color.black.ignoresSafeArea())
        .overlay { settingsOverlay }
        .preferredColorScheme(.dark)
        .alert("알림", isPresented: Binding(get: { m.notice != nil }, set: { if !$0 { m.notice = nil } })) {
            Button("확인") { m.notice = nil }
        } message: {
            Text(m.notice ?? "")
        }
    }

    // MARK: 설정 패널 (창 안에서 오른쪽에서 밀려 나와요)

    @ViewBuilder var settingsOverlay: some View {
        ZStack(alignment: .trailing) {
            if showSettings {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeSettings() }
                    .transition(.opacity)
                SettingsPanel(close: closeSettings)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    func openSettings() { withAnimation(.easeOut(duration: 0.22)) { showSettings = true } }
    func closeSettings() { withAnimation(.easeIn(duration: 0.18)) { showSettings = false } }

    // MARK: 위: 배경 그림, 로고, 상태

    /// 배경 그림 (제목 줄 높이만큼 더 길게, 위에서부터)
    var heroArt: some View {
        let h = Self.heroHeight + 40
        return ZStack {
            if let bg = m.art["background"] {
                Image(nsImage: bg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: h, alignment: .top)
                    .clipped()
            } else {
                LinearGradient(colors: [m.keyColor.opacity(0.9), .black], startPoint: .top, endPoint: .bottom)
            }
            // 아래쪽은 게임 색으로 이어지게, 위쪽은 창 버튼과 글자가 잘 보이게
            LinearGradient(colors: [.clear, .clear, m.keyColor.opacity(0.95)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
        }
        .frame(width: Self.width, height: h)
    }

    var hero: some View {
        ZStack(alignment: .top) {
            topBar

            Group {
                if let logo = m.art["game_logo"] {
                    Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(width: 340)
                } else {
                    Text("아주르 프로밀리아").font(.system(size: 46, weight: .black)).foregroundStyle(.white)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 12)
            .position(x: Self.width * 0.56, y: Self.heroHeight * 0.38)

            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                notices
            }
            .frame(width: Self.width - 32, alignment: .leading)
            .padding(.bottom, 14)
        }
        .frame(width: Self.width, height: Self.heroHeight)
    }

    var topBar: some View {
        HStack(spacing: 10) {
            Text("AZUR PROMILIA LAUNCHER")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if m.state == .ready {
                HStack(spacing: 6) {
                    Circle().fill(m.gameRunning ? Color.green : (m.running ? Color.blue : Color.gray)).frame(width: 7, height: 7)
                    Text(m.statusLine).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .frame(width: Self.width, alignment: .top)
    }

    @ViewBuilder var notices: some View {
        if let v = m.newVersion {
            pill(text: "새 버전 v\(v)이 나왔어요 (지금 v\(m.appVersion))", button: "받으러 가기") {
                if let u = m.newVersionURL { NSWorkspace.shared.open(u) }
            }
        }
        if m.stale {
            pill(text: "비정상으로 꺼진 Wine 프로세스가 남아 있어요", button: "정리하기") { m.stop() }
        }
        switch m.downloadState {
        case "downloading": pill(text: "게임을 받는 중 · \(m.gameGB)GB / 약 82GB (넥슨 플러그는 닫지 마세요)")
        case "stalled": pill(text: "다운로드가 2분 넘게 멈춰 있어요 (\(m.gameGB)GB)")
        case "stopped": pill(text: "다운로드가 멈췄어요 (\(m.gameGB)GB). 넥슨 플러그에서 설치(이어받기)를 눌러 주세요",
                              button: m.running ? nil : "넥슨 플러그 열기") { m.launchPlug() }
        default: EmptyView()
        }
        if m.busy && !m.progress.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(m.progress).font(.callout).lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
        if let e = m.errorText {
            pill(text: e, button: "닫기") { m.errorText = nil }
        }
    }

    func pill(text: String, button: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(text).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let button, let action { Button(button, action: action).controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: 아래: 소식, 제목, 게임시작

    var bottomBar: some View {
        HStack(spacing: 20) {
            newsCard

            VStack(alignment: .leading, spacing: 7) {
                Text("아주르 프로밀리아").font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if m.state == .ready {
                    HStack(spacing: 12) {
                        Button(m.plugRunning ? "넥슨 플러그 보기" : "넥슨 플러그만 열기") {
                            if m.plugRunning { Task { await m.bringPlugForward() } } else { m.launchPlug() }
                        }
                        .disabled(m.acting)
                        Button("종료") { m.stop() }.disabled(m.acting || !(m.running || m.stale))
                        Button("스크린샷") { m.openScreenshots() }
                            .help("게임 중 ⌘⇧9로 게임 화면을 저장해요. 누르면 저장한 폴더를 열어요.")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .tint(.white.opacity(0.85))
                }
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                startButton
                Button { openSettings() } label: {
                    Text("설정").font(.system(size: 15, weight: .semibold))
                        .frame(width: 58, height: 58)
                        .background(.white.opacity(showSettings ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.white.opacity(0.85))
                .help("설정")
            }
        }
        .padding(.horizontal, 22)
        .frame(width: Self.width, height: Self.barHeight)
        .background(LinearGradient(colors: [m.keyColor, m.keyColor.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        .background(Color.black)
    }

    /// 넥슨 플러그 게임 화면처럼 커뮤니티 소식 세 줄 (전체 / 공지 / 이벤트)
    var newsCard: some View {
        let tabs = ["전체", "공지", "이벤트"]
        let items = Array(m.news.filter { item in
            switch newsTab {
            case 1: return item.board.contains("공지")
            case 2: return item.board.contains("이벤트")
            default: return true
            }
        }.prefix(3))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text("소식").font(.system(size: 13, weight: .bold)).padding(.trailing, 6)
                ForEach(tabs.indices, id: \.self) { i in
                    Button { newsTab = i } label: {
                        Text(tabs[i])
                            .font(.system(size: 11, weight: newsTab == i ? .semibold : .regular))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(newsTab == i ? Color.white.opacity(0.18) : .clear, in: Capsule())
                            .foregroundStyle(.white.opacity(newsTab == i ? 1 : 0.6))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                Spacer(minLength: 4)
                Button {
                    if let u = URL(string: "https://forum.nexon.com/azurpromilia") { NSWorkspace.shared.open(u) }
                } label: {
                    Text("더보기")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("아주르 프로밀리아 커뮤니티를 브라우저로 열어요")
            }
            .padding(.horizontal, 6)

            if items.isEmpty {
                Text(m.news.isEmpty ? (m.newsFailed ? "소식을 불러오지 못했어요" : "소식을 불러오는 중…") : "새 글이 없어요")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 1) {
                    ForEach(items) { NewsRow(item: $0) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 9)
        .frame(width: 330, height: 116, alignment: .top)
        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))
        .foregroundStyle(.white)
    }

    var subtitle: String {
        switch m.state {
        case .checking: return "확인하는 중…"
        case .needsSetup: return "처음 실행이라 준비가 필요해요 (Wine 런타임, WebView2, 넥슨 플러그, NGM)"
        case .ready: return "판타지 월드 RPG · 런처 v\(m.appVersion)"
        }
    }

    @ViewBuilder var startButton: some View {
        switch m.state {
        case .checking:
            BigButton(title: "확인 중…", enabled: false) {}
        case .needsSetup:
            BigButton(title: m.busy ? "준비하는 중…" : "준비 시작", enabled: !m.busy) { m.setup() }
        case .ready:
            if m.gameRunning {
                BigButton(title: "게임 실행 중", enabled: false) {}
            } else if m.stage != "none" && !m.acting {
                BigButton(title: m.stage == "ngm" ? "게임 켜는 중…" : "로그인 중…", enabled: false) {}
            } else {
                BigButton(title: m.acting ? "처리 중…" : "게임시작", enabled: !m.acting) { m.play() }
            }
        }
    }
}

/// 넥슨 플러그의 파란 게임시작 버튼과 비슷한 큰 버튼
struct BigButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 19, weight: .bold))
            }
            .frame(width: 222, height: 58)
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.7))
            .background(
                LinearGradient(colors: enabled
                               ? [Color(hex: hover ? "#5cc2ff" : "#46b4ff"), Color(hex: hover ? "#2f95f5" : "#1f86ec")]
                               : [Color.white.opacity(0.22), Color.white.opacity(0.14)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(enabled ? 0.3 : 0), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// 소식 카드의 한 줄: [게시판] 제목 날짜. 누르면 브라우저로 글을 열어요.
struct NewsRow: View {
    let item: NewsItem
    @State private var hover = false
    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM.dd"
        return f
    }()

    var body: some View {
        Button {
            if let u = item.url { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 8) {
                Text(item.shortBoard)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: 44)
                    .padding(.vertical, 2)
                    .background(item.badgeColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(item.badgeColor)
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(Self.dateFormat.string(from: item.date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hover ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .help(item.title)
    }
}

/// 톱니바퀴로 여는 설정. 시트 대신 런처 창 안에서 오른쪽에서 밀려 나와요. 흰 바탕에 게임 색(파랑)을 포인트로 써요.
struct SettingsPanel: View {
    @EnvironmentObject var m: LauncherModel
    let close: () -> Void
    @State private var confirmUninstall = false
    /// 직접 고친 숫자 칸 (패널을 닫을 때 Enter를 안 눌렀어도 저장해요)
    @State private var edited: Set<String> = []

    static let accent = Color(hex: "#1f6fb5")
    static let ink = Color(hex: "#1b2230")
    static let sub = Color(hex: "#6b7280")
    static let width: CGFloat = 430

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("게임 실행") {
                        row("런처를 열면 바로 게임 시작", "넥슨 플러그는 숨긴 채로 로그인하고 게임을 켜요.",
                            $m.autoPlay) { m.save("auto_play", $0) }
                        line
                        row("게임 중 넥슨 플러그 최소화", "넥슨 플러그는 뒤에 있어도 화면을 그려서 CPU를 50~60% 써요. 최소화하면 멈춰요.",
                            $m.minimizePlug) { m.save("minimize_plug", $0) }
                        line
                        afterGameRow
                        line
                        row("macOS 게임 모드", "전체 화면일 때 CPU·GPU를 게임에 먼저 줘요.",
                            $m.gameMode, restart: true) { m.save("game_mode", $0) }
                    }

                    section("화면과 성능") {
                        resolutionRow
                        line
                        row("Retina 모드", "맥 화면의 원래 해상도로 그려요. 선명하지만 픽셀이 \(Int(m.recommendedResolution.scale * m.recommendedResolution.scale))배라 훨씬 무거워요.",
                            $m.retina, restart: true) { m.save("retina", $0) }
                        line
                        fpsRow
                        line
                        row("배터리일 때 60 FPS", "충전기를 빼고 켜면 발열과 배터리 소모를 줄여요.",
                            $m.batteryFps, restart: true) { m.save("battery_fps", $0) }
                        line
                        row("AVX2 명령어 (Rosetta)", "게임 일부(Unity Burst)가 더 빠른 코드로 돌아요. 필드 64 → 67 FPS. 자주 튕기면 꺼 보세요.",
                            $m.avx2, restart: true) { m.save("avx2", $0) }
                        line
                        row("Metal HUD", "게임 화면 위에 FPS와 GPU 정보를 보여 줘요.",
                            $m.metalHud, restart: true) { m.save("metal_hud", $0) }
                    }

                    section("입력") {
                        row("게임 안 한글 입력", "한국어 입력 소스로 채팅에 한글을 넣어요. 조합 중인 글자는 다음 글자를 칠 때 나타나요.",
                            $m.gameHangul, restart: true) { m.save("game_hangul", $0) }
                        line
                        row("왼쪽 ⌘를 Ctrl로", "왼쪽 Command 키를 Ctrl 키처럼 써요.",
                            $m.leftCmdCtrl, restart: true) { m.save("left_cmd_ctrl", $0) }
                    }

                    section("편의") {
                        row("메뉴 막대 아이콘", "상태를 보고, 게임 바로 시작·종료·스크린샷을 해요.", $m.menuBar) { _ in }
                        line
                        row("스크린샷 단축키 ⌘⇧9", "게임 화면만 사진 › Azur Promilia 폴더에 저장해요. 처음 한 번 화면 기록 권한을 물어요.",
                            $m.screenshotKey) { m.save("screenshot_key", $0) }
                    }

                    section("관리") {
                        HStack(spacing: 8) {
                            PanelButton(title: "문제 보고") { m.report() }
                            PanelButton(title: "기록 폴더") { m.openLogs() }
                            PanelButton(title: "런타임 검사") { m.checkRuntime() }
                                .disabled(m.busy || m.state != .ready)
                        }
                        .padding(12)
                        line
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("런처 지우기").font(.system(size: 13, weight: .medium))
                                Text("Wine, 넥슨 플러그, 설정, 기록을 지워요. 게임은 남길 수 있어요.")
                                    .font(.system(size: 11)).foregroundStyle(Self.sub)
                            }
                            Spacer(minLength: 8)
                            PanelButton(title: "지우기…", destructive: true) { confirmUninstall = true }
                                .disabled(m.busy || m.state == .checking)
                                .fixedSize()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }

                    if let e = m.errorText {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#d93a2b"))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("비공식 런처 · 계정 제재 위험은 본인 책임이에요 · v\(m.appVersion)")
                        Text("게임 그림과 소식은 넥슨 플러그와 같은 넥슨 공개 API에서 받아 이 맥에만 저장해요.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .foregroundStyle(Self.ink)
        .background(background.ignoresSafeArea())
        .environment(\.colorScheme, .light)   // 스위치, 선택 막대, 입력 칸도 밝은 모양으로
        .overlay(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.08)).frame(width: 1).ignoresSafeArea()
        }
        .onDisappear { commitNumbers() }
        .confirmationDialog("런처를 지울까요?", isPresented: $confirmUninstall) {
            Button("게임은 남기고 지우기") { m.uninstall(keepGame: true) }
            Button("게임까지 모두 지우기", role: .destructive) { m.uninstall(keepGame: false) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("Wine, 넥슨 플러그, 설정, 기록을 지워요. 게임을 남기면 다시 준비할 때 받지 않고 그대로 써요. 게임까지 지우면 되돌릴 수 없어요 (약 82GB).")
        }
    }

    /// 흰 단색 바탕
    var background: some View { Color.white }

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("설정").font(.system(size: 19, weight: .bold))
                Text("\u{201C}다시 켜야 적용\u{201D} 표시가 있는 설정은 넥슨 플러그를 다시 켜면 바뀌어요")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.sub)
            }
            Spacer()
            Button(action: close) {
                Text("닫기")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(.black.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(.cancelAction)
            .help("닫기 (esc)")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Self.accent)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(Color(hex: "#f3f5f8"), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.06)))
        }
    }

    var line: some View {
        Rectangle().fill(.black.opacity(0.07)).frame(height: 1).padding(.leading, 14)
    }

    func label(_ title: String, _ detail: String?, restart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                if restart {
                    Text("다시 켜야 적용")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Self.sub)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.black.opacity(0.05), in: Capsule())
                        .help("넥슨 플러그를 다시 켜야 적용돼요")
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func toggle(_ value: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; onChange($0) }))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }

    func row(_ title: String, _ detail: String?, _ value: Binding<Bool>, restart: Bool = false,
             onChange: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            label(title, detail, restart: restart)
            Spacer(minLength: 8)
            toggle(value, onChange: onChange)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var afterGameRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("게임이 끝나면", "Wine 끄기는 넥슨 플러그까지 닫아 배터리를 아껴요.", restart: false)
            Picker("", selection: Binding(get: { m.afterGame }, set: { m.afterGame = $0; m.save("after_game", $0) })) {
                Text("넥슨 플러그 띄우기").tag("restore")
                Text("Wine 끄기").tag("quit")
                Text("그대로").tag("none")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var resolutionRow: some View {
        let r = m.recommendedResolution
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                label("해상도 직접 정하기", "넥슨 플러그를 켤 때마다 게임 해상도를 이 값으로 맞춰요.", restart: true)
                Spacer(minLength: 8)
                toggle($m.customResolution) { m.save("custom_resolution", $0) }
            }
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    numberField("width", "가로", $m.width)
                    Text("×").foregroundStyle(Self.sub)
                    numberField("height", "세로", $m.height)
                }
                .disabled(!m.customResolution)
                .opacity(m.customResolution ? 1 : 0.45)
                Spacer(minLength: 8)
                PanelButton(title: "이 맥에 맞게 \(r.width)×\(r.height)", compact: true) {
                    edited.subtract(["width", "height"])
                    m.applyRecommendedResolution()
                }
                .help("이 맥 화면 크기로 해상도를 켜고 Retina를 꺼요")
                .fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var fpsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            label("모니터 주사율 직접 정하기", "FPS가 60 아래로 묶이면 켜고 모니터 주사율(예: 120)을 넣으세요.", restart: true)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                numberField("fps", "Hz", $m.fps)
                Text("Hz").font(.system(size: 11)).foregroundStyle(Self.sub)
            }
            .disabled(!m.customFps)
            .opacity(m.customFps ? 1 : 0.45)
            toggle($m.customFps) { m.save("custom_fps", $0) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func numberField(_ key: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = $0; edited.insert(key) }))
            .textFieldStyle(.plain)
            .font(.system(size: 12).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 58)
            .padding(.vertical, 5)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.15)))
            .onSubmit { commit(key, text.wrappedValue) }
    }

    func commit(_ key: String, _ value: String) {
        edited.remove(key)
        m.save(key, value.filter(\.isNumber))
    }

    func commitNumbers() {
        for key in edited.sorted() {
            switch key {
            case "width": commit(key, m.width)
            case "height": commit(key, m.height)
            case "fps": commit(key, m.fps)
            default: break
            }
        }
    }
}

/// 설정 패널의 작은 버튼 (흰 바탕용)
struct PanelButton: View {
    let title: String
    var destructive = false
    var compact = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: compact ? 11 : 12, weight: .medium)).lineLimit(1)
            .padding(.horizontal, compact ? 9 : 10)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 26 : 32)
            .foregroundStyle(destructive ? Color(hex: "#d93a2b") : Color(hex: "#1b2230"))
            .background((destructive ? Color(hex: "#d93a2b") : .black).opacity(hover && enabled ? 0.1 : 0.05),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.black.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
    }
}

extension Color {
    /// "#21639a" 같은 16진수 색
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        let v = UInt32(h, radix: 16) ?? 0x21639a
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

// MARK: - 메뉴 막대

struct MenuBarContent: View {
    @EnvironmentObject var m: LauncherModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(m.statusLine)
        Divider()
        Button("게임 바로 시작") { m.play() }
            .disabled(m.acting || m.gameRunning || m.state != .ready)
        Button(m.plugRunning ? "넥슨 플러그 앞으로" : "넥슨 플러그만 실행") {
            if m.plugRunning { Task { await m.bringPlugForward() } } else { m.launchPlug() }
        }
        .disabled(m.acting || m.state != .ready)
        Button("스크린샷 (⌘⇧9)") { m.takeScreenshot() }
            .disabled(!m.gameRunning)
        Button("모두 종료") { m.stop() }
            .disabled(m.acting || !(m.running || m.stale))
        Divider()
        Button("런처 창 열기") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("스크린샷 폴더 열기") { m.openScreenshots() }
        Button("런처 끝내기") { NSApp.terminate(nil) }
    }
}
