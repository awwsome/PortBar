import AppKit
import Darwin
import ServiceManagement
import SwiftUI

// MARK: - Store

struct RepoGroup: Identifiable {
    let id: String
    let repo: RepoInfo?
    let ports: [ListeningPort]
}

@MainActor
@Observable
final class PortStore {
    var ports: [ListeningPort] = []
    var query = ""
    var devOnly = UserDefaults.standard.object(forKey: "devOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(devOnly, forKey: "devOnly") }
    }
    var message: String?
    var pendingConfirm: String?
    var stubborn: Set<Int32> = []
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var confirmReset: Task<Void, Never>?
    @ObservationIgnored private var messageReset: Task<Void, Never>?

    init() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    var visible: [ListeningPort] { devOnly ? ports.filter(\.isDev) : ports }

    var filtered: [ListeningPort] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return visible }
        return visible.filter { p in
            let fields = [String(p.port), String(p.pid), p.displayName, p.command,
                          p.commandLine ?? "", p.repo?.name ?? "", p.repo?.branch ?? "", p.subpath ?? ""]
            return fields.contains { $0.lowercased().contains(q) }
        }
    }

    /// 레포 체크아웃 단위로 묶는다. 레포를 못 찾은 항목은 마지막 "레포 없음" 묶음으로 간다.
    var groups: [RepoGroup] {
        let byRoot = Dictionary(grouping: filtered) { $0.repo?.root ?? "" }
        return byRoot.map { RepoGroup(id: $0.key, repo: $0.value.first?.repo, ports: $0.value) }
            .sorted { a, b in
                switch (a.repo, b.repo) {
                case (nil, _): return false
                case (_, nil): return true
                case let (x?, y?): return (x.name.lowercased(), x.branch ?? "") < (y.name.lowercased(), y.branch ?? "")
                }
            }
    }

    func refresh() async {
        let result = await Task.detached(priority: .utility) { PortScanner.scan() }.value
        ports = result
        stubborn.formIntersection(Set(result.map(\.pid)))
    }

    /// 첫 클릭은 확인 상태로 바꾸고, 3초 안에 다시 누르면 종료한다.
    func tapKill(_ port: ListeningPort) {
        if stubborn.contains(port.pid) {
            kill(port, force: true)
        } else if pendingConfirm == port.id {
            kill(port, force: false)
        } else {
            pendingConfirm = port.id
            confirmReset?.cancel()
            confirmReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.pendingConfirm = nil
            }
        }
    }

    func kill(_ port: ListeningPort, force: Bool) {
        pendingConfirm = nil
        let pid = port.pid
        let name = port.repo?.name ?? port.displayName
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            let reason = errno == EPERM
                ? "권한이 없습니다. 다른 사용자(\(port.user))의 프로세스입니다."
                : String(cString: strerror(errno))
            show("\(name) 종료 실패: \(reason)")
            return
        }
        show(force ? "\(name) :\(port.port)(PID \(pid))를 강제 종료했습니다."
                   : "\(name) :\(port.port)(PID \(pid))에 종료 신호를 보냈습니다.")
        watch([pid], label: name, forced: force)
    }

    func killAll(in group: RepoGroup) {
        pendingConfirm = nil
        let pids = Array(Set(group.ports.map(\.pid)))
        let failed = pids.filter { Darwin.kill($0, SIGTERM) != 0 }
        let name = group.repo?.name ?? "레포 없음"
        show(failed.isEmpty
             ? "\(name)의 프로세스 \(pids.count)개에 종료 신호를 보냈습니다."
             : "\(name): \(pids.count - failed.count)개 종료, \(failed.count)개 실패")
        watch(pids, label: name, forced: false)
    }

    /// 1.5초 뒤에도 살아 있으면 강제 종료 버튼으로 바꾼다.
    private func watch(_ pids: [Int32], label: String, forced: Bool) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            let alive = pids.filter { Darwin.kill($0, 0) == 0 }
            if !forced && !alive.isEmpty {
                self.stubborn.formUnion(alive)
                self.show("\(label)가 응답하지 않습니다. 빨간 버튼을 누르면 강제 종료합니다.")
            }
            await self.refresh()
        }
    }

    func icon(for port: ListeningPort) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: port.pid), let icon = app.icon {
            return icon
        }
        let key = port.executablePath ?? port.command
        if let cached = iconCache[key] { return cached }
        let icon: NSImage
        if let path = port.executablePath, let range = path.range(of: ".app/") {
            icon = NSWorkspace.shared.icon(forFile: String(path[..<range.lowerBound]) + ".app")
        } else {
            icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        iconCache[key] = icon
        return icon
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("로그인 시 실행 설정 실패: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func show(_ text: String) {
        message = text
        messageReset?.cancel()
        messageReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

// MARK: - Actions

enum Actions {
    /// 설치된 에디터 (번들 ID, 메뉴 이름)
    static let editors: [(id: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "VS Code"),
        ("dev.zed.Zed", "Zed"),
        ("com.exafunction.windsurf", "Windsurf"),
    ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
        .map { (id: $0.0, name: $0.1) }

    static func open(_ path: String, withBundleID bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

struct PortListView: View {
    @Bindable var store: PortStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let message = store.message {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }
            Divider()
            footer
        }
        .frame(width: 440)
        .animation(.easeOut(duration: 0.15), value: store.message)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $store.devOnly) {
                    Text("개발 서버").tag(true)
                    Text("전체").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(store.visible.count)개 열림")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("새로고침")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("포트, 레포, 브랜치, 프로세스 검색", text: $store.query)
                    .textFieldStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let items = store.filtered
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(!store.query.isEmpty ? "검색 결과가 없습니다"
                     : store.devOnly ? "실행 중인 개발 서버가 없습니다" : "열려 있는 포트가 없습니다")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else if store.devOnly {
            let groups = store.groups
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.ports) { PortRow(port: $0, store: store, grouped: true) }
                        } header: {
                            RepoHeader(group: group, store: store)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(items.count) * 48 + CGFloat(groups.count) * 34, 480))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { PortRow(port: $0, store: store, grouped: false) }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(items.count) * 48 + 8, 480))
        }
    }

    private var footer: some View {
        HStack {
            Toggle("로그인 시 실행", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            Spacer()
            Button("종료") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct RepoHeader: View {
    let group: RepoGroup
    let store: PortStore

    var body: some View {
        HStack(spacing: 6) {
            if let repo = group.repo {
                Image(systemName: repo.isWorktree ? "arrow.triangle.branch" : "folder.fill")
                    .foregroundStyle(.secondary)
                    .help(repo.isWorktree ? "git worktree" : "git 레포")
                Text(repo.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let branch = repo.branch {
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 4)
                Menu {
                    repoMenu(repo)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.secondary)
                Text("레포 없음")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
        .help(group.repo?.root ?? "")
    }

    @ViewBuilder
    private func repoMenu(_ repo: RepoInfo) -> some View {
        Button("Finder에서 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: repo.root)) }
        Button("터미널에서 열기") { Actions.open(repo.root, withBundleID: "com.apple.Terminal") }
        ForEach(Actions.editors, id: \.id) { editor in
            Button("\(editor.name)로 열기") { Actions.open(repo.root, withBundleID: editor.id) }
        }
        if let url = repo.webURL {
            Button("원격 저장소 웹에서 열기") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("경로 복사") { Actions.copy(repo.root) }
        Divider()
        Button("이 레포의 포트 모두 종료") { store.killAll(in: group) }
    }
}

struct PortRow: View {
    let port: ListeningPort
    let store: PortStore
    let grouped: Bool
    @State private var hovering = false

    private var confirming: Bool { store.pendingConfirm == port.id }
    private var stubborn: Bool { store.stubborn.contains(port.pid) }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: ":\(port.port)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 64, alignment: .leading)

            Image(nsImage: store.icon(for: port))
                .resizable()
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(grouped ? port.shortCommand : port.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !port.isLocalOnly {
                        Text("외부 노출")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                            .fixedSize()
                            .help("모든 네트워크 인터페이스(\(port.addresses.joined(separator: ", ")))에서 접근 가능")
                    }
                }
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            killButton
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(port.commandLine ?? port.command)
        .contextMenu { menu }
    }

    private var subtitle: String {
        var parts = ["PID \(port.pid)"]
        if grouped {
            if let subpath = port.subpath { parts.append(subpath) }
            parts.append(port.command)
        } else {
            if let repo = port.repo { parts.append(repo.name + (repo.branch.map { " (\($0))" } ?? "")) }
            parts.append(port.shortCommand)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var killButton: some View {
        if stubborn {
            Button("강제 종료") { store.tapKill(port) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        } else if confirming {
            Button("종료") { store.tapKill(port) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        } else {
            Button {
                store.tapKill(port)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(hovering ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help("프로세스 종료")
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("브라우저에서 열기") {
            if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("종료 (SIGTERM)") { store.kill(port, force: false) }
        Button("강제 종료 (SIGKILL)") { store.kill(port, force: true) }
        Divider()
        Button("포트 번호 복사") { Actions.copy(String(port.port)) }
        Button("PID 복사") { Actions.copy(String(port.pid)) }
        if let commandLine = port.commandLine {
            Button("실행 명령 복사") { Actions.copy(commandLine) }
        }
        if let cwd = port.workingDirectory, cwd != "/" {
            Button("작업 폴더 경로 복사") { Actions.copy(cwd) }
        }
        if let path = port.executablePath {
            Button("실행 파일 Finder에서 보기") { Actions.revealInFinder(path) }
        }
    }
}

// MARK: - App

@main
struct PortBarApp: App {
    @State private var store = PortStore()

    var body: some Scene {
        MenuBarExtra {
            PortListView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text(verbatim: "\(store.visible.count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
