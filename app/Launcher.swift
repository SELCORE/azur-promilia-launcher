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
    @Published var busy = false
    @Published var progress = ""
    @Published var errorText: String?

    @Published var metalHud = false
    @Published var retina = false
    @Published var leftCmdCtrl = false
    @Published var customResolution = false
    @Published var width = "1920"
    @Published var height = "1200"
    @Published var customFps = false
    @Published var fps = "60"

    private var loading = false
    private var timer: Timer?

    let ctl = Bundle.main.resourceURL!.appendingPathComponent("azurctl.sh").path
    var appHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Azur Promilia Launcher")
    }

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRunning() }
        }
    }

    /// bash로 명령을 실행해요. onLine이 있으면 한 줄씩 넘겨줘요.
    nonisolated func shell(_ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                let lock = NSLock()
                var out = Data()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    lock.lock(); out.append(d); lock.unlock()
                    if let onLine, let s = String(data: d, encoding: .utf8) {
                        for line in s.split(whereSeparator: \.isNewline) where !line.isEmpty { onLine(String(line)) }
                    }
                }
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "\(error)")); return
                }
                p.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); out.append(rest); let all = out; lock.unlock()
                cont.resume(returning: (p.terminationStatus, String(data: all, encoding: .utf8) ?? ""))
            }
        }
    }

    func ctlRun(_ args: String...) async -> (Int32, String) { await shell([ctl] + args) }

    func refresh() async {
        let (_, code) = await ctlRun("status-code")
        state = code.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" ? .ready : .needsSetup
        await loadSettings()
        await refreshRunning()
    }

    func refreshRunning() async {
        let (_, r) = await ctlRun("running")
        running = r.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
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
        customResolution = kv["custom_resolution"] == "1"
        customFps = kv["custom_fps"] == "1"
        width = kv["width"] ?? "1920"
        height = kv["height"] ?? "1200"
        fps = kv["fps"] ?? "60"
    }

    func save(_ key: String, _ value: String) {
        guard !loading else { return }
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
        Task {
            let (status, out) = await ctlRun("plug")
            errorText = status == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshRunning()
        }
    }

    func stop() {
        Task {
            _ = await ctlRun("stop")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch m.state {
            case .checking:
                ProgressView("확인하는 중…")
            case .needsSetup:
                setupSection
            case .ready:
                launchSection
            }
            if let e = m.errorText {
                Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            SettingsSection()
            Divider()
            HStack {
                Button("기록 폴더 열기") { m.openLogs() }
                Spacer()
                Text("비공식 런처 · 계정 제재 위험은 본인 책임이에요")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
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
                Label("넥슨 플러그 실행", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("종료") { m.stop() }
                .controlSize(.large)
                .disabled(!m.running)
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
