import AppKit
import Darwin

// MARK: - Model

struct RepoInfo: Hashable, Sendable {
    /// 체크아웃(worktree 포함) 루트 경로
    let root: String
    /// 원격 저장소 기준 "owner/repo", 원격이 없으면 레포 폴더 이름
    let name: String
    let branch: String?
    let webURL: URL?
    let isWorktree: Bool
}

struct ListeningPort: Identifiable, Hashable, Sendable {
    let pid: Int32
    let command: String
    let user: String
    let port: Int
    let addresses: [String]
    let executablePath: String?
    let arguments: [String]
    let workingDirectory: String?
    let repo: RepoInfo?
    let isDev: Bool

    var id: String { "\(pid)-\(port)" }

    var commandLine: String? { arguments.isEmpty ? nil : arguments.joined(separator: " ") }

    /// 긴 경로 인자를 줄인 실행 명령. 예: "node vite dev --port 7008"
    var shortCommand: String {
        guard !arguments.isEmpty else { return command }
        return arguments.map(Self.shorten).joined(separator: " ")
    }

    /// 레포 루트 기준 작업 디렉터리. 예: "apps/manager"
    var subpath: String? {
        guard let repo, let cwd = workingDirectory, cwd.hasPrefix(repo.root + "/") else { return nil }
        return String(cwd.dropFirst(repo.root.count + 1))
    }

    /// 127.0.0.1 / ::1 에만 바인딩되어 외부에서 접근할 수 없는 포트인지
    var isLocalOnly: Bool {
        addresses.allSatisfy { ["127.0.0.1", "[::1]", "localhost"].contains($0) }
    }

    var displayName: String {
        if let path = executablePath, let range = path.range(of: ".app/") {
            return URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent
        }
        return command
    }

    private static func shorten(_ arg: String) -> String {
        guard arg.hasPrefix("/") else { return arg }
        if let range = arg.range(of: "node_modules/", options: .backwards) {
            let parts = arg[range.upperBound...].split(separator: "/")
            if let first = parts.first {
                return first.hasPrefix("@") && parts.count > 1 ? "\(first)/\(parts[1])" : String(first)
            }
        }
        return URL(fileURLWithPath: arg).lastPathComponent
    }
}

// MARK: - Scanner

enum PortScanner {
    /// 개발 서버로 볼 런타임·도구 (명령 이름 접두사)
    static let devRuntimes = [
        "node", "bun", "deno", "python", "ruby", "java", "php", "dotnet", "beam.smp", "erl",
        "uvicorn", "gunicorn", "puma", "rails", "hugo", "vite", "esbuild", "next-server",
        "workerd", "wrangler", "air", "cargo", "go",
    ]

    /// lsof로 현재 사용자가 볼 수 있는 TCP LISTEN 소켓을 모은다.
    static func scan() -> [ListeningPort] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-FpcLn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> [ListeningPort] {
        struct Entry { var pid: Int32; var command: String; var user: String; var port: Int; var addresses: [String] }
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var pid: Int32 = 0
        var command = ""
        var user = ""
        let ownPid = ProcessInfo.processInfo.processIdentifier

        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "L": user = value
            case "n":
                guard pid != ownPid,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...])
                else { continue }
                let address = String(value[..<colon])
                let key = "\(pid):\(port)"
                if entries[key] == nil {
                    entries[key] = Entry(pid: pid, command: command, user: user, port: port, addresses: [])
                    order.append(key)
                }
                if !entries[key]!.addresses.contains(address) {
                    entries[key]!.addresses.append(address)
                }
            default: break
            }
        }

        struct ProcessDetails { let path: String?; let args: [String]; let cwd: String?; let repo: RepoInfo? }
        var details: [Int32: ProcessDetails] = [:]
        var repoCache: [String: RepoInfo?] = [:]

        func repo(near path: String) -> RepoInfo? {
            if let cached = repoCache[path] { return cached }
            let found = RepoResolver.resolve(path: path)
            repoCache[path] = found
            return found
        }

        func lookup(_ pid: Int32) -> ProcessDetails {
            if let cached = details[pid] { return cached }
            let path = executablePath(pid: pid)
            let args = arguments(pid: pid)
            let cwd = workingDirectory(pid: pid)
            // cwd가 레포 밖이면(예: launchd로 실행) 인자에 들어 있는 절대 경로로 다시 찾는다.
            var found = cwd.flatMap { repo(near: $0) }
            if found == nil {
                found = args.dropFirst().lazy.filter { $0.hasPrefix("/") }.compactMap { repo(near: $0) }.first
            }
            let result = ProcessDetails(path: path, args: args, cwd: cwd, repo: found)
            details[pid] = result
            return result
        }

        return order.compactMap { entries[$0] }.map { e in
            let d = lookup(e.pid)
            let inAppBundle = d.path?.contains(".app/") ?? false
            let name = e.command.lowercased()
            let isRuntime = devRuntimes.contains { name == $0 || name.hasPrefix($0 + " ") || name.hasPrefix($0 + "3") || name.hasPrefix($0 + "-") }
            // 레포를 못 찾은 런타임은 cwd가 사용자 작업 폴더일 때만 개발 서버로 본다.
            // (Raycast 같은 앱이 내장한 node는 cwd가 / 이거나 ~/Library 아래다.)
            let isUserCwd = d.cwd.map { $0 != "/" && !$0.contains("/Library/") } ?? false
            let isDev = !inAppBundle && (d.repo != nil || (isRuntime && isUserCwd))
            return ListeningPort(pid: e.pid, command: e.command, user: e.user, port: e.port,
                                 addresses: e.addresses, executablePath: d.path, arguments: d.args,
                                 workingDirectory: d.cwd, repo: d.repo, isDev: isDev)
        }
        .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// KERN_PROCARGS2에서 실행 인자를 읽는다. 첫 인자는 실행 파일 이름만 남긴다.
    static func arguments(pid: Int32) -> [String] {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 } // 실행 파일 경로
        while i < size && buffer[i] == 0 { i += 1 } // 패딩

        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        if let first = args.first, first.hasPrefix("/") {
            args[0] = URL(fileURLWithPath: first).lastPathComponent
        }
        return args
    }
}

// MARK: - Git

enum RepoResolver {
    /// path에서 위로 올라가며 .git을 찾는다. 홈 디렉터리 자체는 레포로 보지 않는다.
    static func resolve(path start: String) -> RepoInfo? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var dir = URL(fileURLWithPath: start).standardizedFileURL
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            dir.deleteLastPathComponent()
        }
        while dir.path != "/" && dir.path != home {
            let dotGit = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return make(root: dir, dotGit: dotGit, isDirectory: isDirectory.boolValue)
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private static func make(root: URL, dotGit: URL, isDirectory: Bool) -> RepoInfo? {
        var gitDir = dotGit
        var isWorktree = false
        if !isDirectory {
            // worktree·submodule: ".git" 파일에 "gitdir: <경로>"가 들어 있다.
            guard let text = read(dotGit),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            else { return nil }
            gitDir = url(String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces), relativeTo: root)
            isWorktree = true
        }
        var commonDir = gitDir
        if let common = read(gitDir.appendingPathComponent("commondir")) {
            commonDir = url(common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir)
        }

        var branch: String?
        if let head = read(gitDir.appendingPathComponent("HEAD"))?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let prefix = "ref: refs/heads/"
            branch = head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : String(head.prefix(7))
        }

        let remote = read(commonDir.appendingPathComponent("config")).flatMap(remoteURL).flatMap(parseRemote)
        let fallbackName = commonDir.lastPathComponent == ".git"
            ? commonDir.deletingLastPathComponent().lastPathComponent
            : root.lastPathComponent
        var webURL: URL?
        if let remote {
            let host = remote.host.contains("github") ? "github.com"
                : remote.host.contains("gitlab") ? "gitlab.com" : remote.host
            webURL = URL(string: "https://\(host)/\(remote.path)")
        }
        return RepoInfo(root: root.path, name: remote?.path ?? fallbackName, branch: branch,
                        webURL: webURL, isWorktree: isWorktree)
    }

    /// .git/config에서 origin(없으면 첫 원격)의 url을 꺼낸다.
    static func remoteURL(config: String) -> String? {
        var current: String?
        var urls: [String: String] = [:]
        var order: [String] = []
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = line.hasPrefix("[remote \"") ? String(line.dropFirst(9).prefix { $0 != "\"" }) : nil
            } else if let remote = current, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                urls[remote] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                order.append(remote)
            }
        }
        return urls["origin"] ?? order.first.flatMap { urls[$0] }
    }

    /// https://host/owner/repo.git, ssh://git@host/owner/repo, git@host:owner/repo.git → (host, "owner/repo")
    static func parseRemote(_ url: String) -> (host: String, path: String)? {
        var s = url
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasSuffix("/") { s.removeLast() }
        let hostPart: Substring
        let path: Substring
        if let scheme = s.range(of: "://") {
            let rest = s[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            hostPart = rest[..<slash]
            path = rest[rest.index(after: slash)...]
        } else if let colon = s.firstIndex(of: ":"), !s.hasPrefix("/") {
            hostPart = s[..<colon]
            path = s[s.index(after: colon)...]
        } else {
            return nil
        }
        var host = String(hostPart)
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return (host, String(path))
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func url(_ path: String, relativeTo base: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
    }
}
