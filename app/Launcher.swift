// 아주르 프로밀리아 런처 (비공식)
// 창 하나짜리 macOS 앱이에요. 실제 작업은 앱 안의 Contents/Resources/azurctl.sh가 해요.
import AppKit
import SwiftUI

@main
struct AzurLauncherApp: App {
    @StateObject private var model = LauncherModel()
    var body: some Scene {
        WindowGroup("아주르 프로밀리아 런처") {
            ContentView()
                .environmentObject(model)
                .frame(width: 520)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - 모델

@MainActor
final class LauncherModel: ObservableObject {
    enum State { case checking, needsSetup, ready }

    @Published var state: State = .checking
    @Published var running = false
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
                tick += 1
            }
        }
        Task { await checkForUpdate() }
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
    }

    func refreshRunning() async {
        let (_, r) = await ctlRun("running")
        let s = r.trimmingCharacters(in: .whitespacesAndNewlines)
        running = s == "yes"
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
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let v = m.newVersion {
                banner(color: .blue, icon: "arrow.down.circle.fill",
                       text: "새 버전 v\(v)이 나왔어요. 지금은 v\(m.appVersion)이에요.",
                       button: "받으러 가기") { if let u = m.newVersionURL { NSWorkspace.shared.open(u) } }
            }
            switch m.state {
            case .checking:
                ProgressView("확인하는 중…")
            case .needsSetup:
                setupSection
            case .ready:
                launchSection
                if m.stale {
                    banner(color: .orange, icon: "exclamationmark.triangle.fill",
                           text: "넥슨 플러그나 게임이 비정상으로 꺼지면서 Wine 프로세스가 남아 있어요. CPU를 계속 쓸 수 있으니 정리해 주세요.",
                           button: "정리하기") { m.stop() }
                }
                downloadSection
            }
            if let e = m.errorText {
                Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            SettingsSection()
            Divider()
            HStack(spacing: 10) {
                Button("문제 보고") { m.report() }
                Button("기록 폴더 열기") { m.openLogs() }
                Button("지우기…") { confirmUninstall = true }
                    .disabled(m.busy || m.state == .checking)
                Spacer()
            }
            Text("비공식 런처 · 계정 제재 위험은 본인 책임이에요 · v\(m.appVersion)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .confirmationDialog("런처를 지울까요?", isPresented: $confirmUninstall) {
            Button("게임은 남기고 지우기") { m.uninstall(keepGame: true) }
            Button("게임까지 모두 지우기", role: .destructive) { m.uninstall(keepGame: false) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("Wine, 넥슨 플러그, 설정, 기록을 지워요. 게임을 남기면 다시 준비할 때 받지 않고 그대로 써요. 게임까지 지우면 되돌릴 수 없어요 (약 82GB).")
        }
        .alert("알림", isPresented: Binding(get: { m.notice != nil }, set: { if !$0 { m.notice = nil } })) {
            Button("확인") { m.notice = nil }
        } message: {
            Text(m.notice ?? "")
        }
    }

    func banner(color: Color, icon: String, text: String, button: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let button, let action { Button(button, action: action) }
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder var downloadSection: some View {
        switch m.downloadState {
        case "downloading":
            banner(color: .green, icon: "arrow.down.circle",
                   text: "게임을 받는 중이에요 · 지금 \(m.gameGB)GB (전체 약 82GB). 넥슨 플러그는 닫지 말고 최소화만 해 주세요.")
        case "stalled":
            banner(color: .orange, icon: "exclamationmark.triangle.fill",
                   text: "다운로드가 2분 넘게 진행되지 않아요 (\(m.gameGB)GB). 조금 더 기다려도 그대로면 넥슨 플러그에서 설치(이어받기)를 다시 눌러 주세요.")
        case "stopped":
            banner(color: .orange, icon: "pause.circle.fill",
                   text: "게임 다운로드가 중간에 멈췄어요 (\(m.gameGB)GB). 받은 부분은 남아 있어요. 넥슨 플러그에서 설치(이어받기)를 다시 눌러 주세요.",
                   button: m.running ? nil : "넥슨 플러그 열기") { m.launchPlug() }
        default:
            EmptyView()
        }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("아주르 프로밀리아 런처").font(.title2.bold())
            Spacer()
            if m.state == .ready {
                Label(m.running ? "실행 중" : "꺼져 있음", systemImage: m.running ? "circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(m.running ? .green : .secondary)
            }
        }
    }

    var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("처음 실행이라 준비가 필요해요. 몇 분 걸려요.")
            VStack(alignment: .leading, spacing: 4) {
                Text("• Wine + DXMT 런타임(약 281MB)과 WebView2를 받아요")
                Text("• 넥슨 공식 서버에서 넥슨 플러그와 NGM을 받아요")
                Text("• CrossOver에 받아 둔 게임이 있으면 다시 받지 않고 가져와요")
            }
            .font(.callout).foregroundStyle(.secondary)
            if m.busy {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(m.progress).font(.callout).lineLimit(2)
            } else {
                Button("준비 시작") { m.setup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    var launchSection: some View {
        HStack(spacing: 12) {
            Button {
                m.launchPlug()
            } label: {
                Label(m.acting ? "처리 중…" : "넥슨 플러그 실행", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(m.acting)
            Button("종료") { m.stop() }
                .controlSize(.large)
                .disabled(m.acting || !(m.running || m.stale))
        }
    }
}

struct SettingsSection: View {
    @EnvironmentObject var m: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("설정").font(.headline)

            option("Metal HUD", "게임 화면 위에 FPS와 GPU 정보를 표시해요.", $m.metalHud) { m.save("metal_hud", $0) }
            option("Retina 모드", "맥 화면의 원래 해상도로 그려요. 선명하지만 훨씬 무거워져요.", $m.retina) { m.save("retina", $0) }
            option("왼쪽 CMD를 CTRL로 할당", "왼쪽 ⌘ 키를 Ctrl 키로 써요.", $m.leftCmdCtrl) { m.save("left_cmd_ctrl", $0) }
            option("게임 안 한글 입력",
                   "맥 입력 소스가 한국어일 때 게임 채팅에 완성된 한글을 넣어요. 조합 중인 글자는 다음 글자를 칠 때 나타나요. 끄면 한국어 입력 소스에서도 영문이 쳐져요.",
                   $m.gameHangul) { m.save("game_hangul", $0) }
            option("macOS 게임 모드",
                   "게임을 macOS가 게임으로 알아보게 해서, 전체 화면일 때 게임 모드(CPU·GPU 우선, 백그라운드 작업 줄이기)를 받아요. 넥슨 플러그를 다시 켜면 적용돼요.",
                   $m.gameMode) { m.save("game_mode", $0) }

            VStack(alignment: .leading, spacing: 6) {
                option("사용자 정의 해상도", "켜 두면 넥슨 플러그를 켤 때마다 게임 해상도를 이 값으로 맞춰요.", $m.customResolution) {
                    m.save("custom_resolution", $0)
                }
                HStack {
                    numberField("가로", $m.width) { m.save("width", $0) }
                    Text("×")
                    numberField("세로", $m.height) { m.save("height", $0) }
                }
                .disabled(!m.customResolution)
                .padding(.leading, 22)
            }

            VStack(alignment: .leading, spacing: 6) {
                option("사용자 지정 모니터 주사율 (Hz)",
                       "FPS가 60 아래로 묶이면 켜고 모니터 주사율(예: 120)을 넣으세요. 게임 주사율과 프레임 상한을 이 값으로 맞춰요.",
                       $m.customFps) { m.save("custom_fps", $0) }
                numberField("Hz", $m.fps) { m.save("fps", $0) }
                    .frame(width: 120)
                    .disabled(!m.customFps)
                    .padding(.leading, 22)
            }

            Text("설정은 다음에 넥슨 플러그를 켤 때 적용돼요. 이미 켜져 있으면 종료한 뒤 다시 실행하세요. 숫자는 입력 후 Enter를 누르면 저장돼요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func option(_ title: String, _ detail: String, _ value: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; onChange($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    func numberField(_ placeholder: String, _ text: Binding<String>, onCommit: @escaping (String) -> Void) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            .onSubmit { onCommit(text.wrappedValue.filter(\.isNumber)) }
    }
}
