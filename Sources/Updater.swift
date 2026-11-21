import AppKit

/// Checks GitHub Releases for a newer version (semantic versioning: v1.2.0 > v1.1.9) and installs it by running
/// the same one-line installer as the README. The only network calls Layout Fixer makes; they send nothing about you.
final class Updater {
    static let repository = "m-ilchuk/layout-fixer"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayoutFixer-update.log")
    }

    struct Release: Equatable {
        let version: String
        /// The release's tag ("v0.3.0"): what gets installed, its installer and its source.
        let tag: String
        let notes: String
    }

    enum Status: Equatable {
        case unknown, upToDate, available(Release), failed(String)
    }

    /// This build's version (Info.plist, set by release.sh).
    static var currentVersion: Version? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Version.init)
    }

    /// The commit this build came from (build.sh writes it into Info.plist), for telling builds apart.
    static var currentCommit: String? {
        let commit = Bundle.main.object(forInfoDictionaryKey: "LFSourceCommit") as? String
        return commit == "unknown" ? nil : commit
    }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdates") }
    }
    private(set) var status: Status = .unknown
    /// An install is running (about a minute): the menu says so and another click does nothing.
    private(set) var installing = false
    /// Where the running install is, for the window's progress bar.
    private(set) var progress: UpdateProgress.State?
    private var progressTimer: Timer?
    private var compileStarted: Date?
    static let progressInterval: TimeInterval = 0.5
    static let defaultCompileSeconds: TimeInterval = 45
    /// How long compiling took last time on this Mac ("Built in 41s"), so the bar moves at the right pace.
    private var expectedCompile: TimeInterval {
        let last = UserDefaults.standard.double(forKey: "lastBuildSeconds")
        return last > 0 ? last : Updater.defaultCompileSeconds
    }
    var onChange: (() -> Void)?
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Updater.checkInterval, repeats: true) { [weak self] _ in
            if self?.automatic == true { self?.check() }
        }
        if automatic { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.check() } }
    }

    /// Asks GitHub for the latest release and compares its version with this build's.
    func check(then done: ((Status) -> Void)? = nil) {
        guard let current = Updater.currentVersion else { return finish(.failed("this build doesn't know its version"), done) }
        let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Status
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                result = .failed(error.localizedDescription)
            } else if code == 404 {
                result = .upToDate  // no release published yet
            } else if code == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String, let latest = Version(tag) {
                let notes = (json["body"] as? String) ?? ""
                result = latest > current ? .available(Release(version: latest.description, tag: tag, notes: notes)) : .upToDate
            } else {
                result = .failed("GitHub answered \(code)")
            }
            DispatchQueue.main.async { self.finish(result, done) }
        }.resume()
    }

    private func finish(_ result: Status, _ done: ((Status) -> Void)?) {
        status = result
        let summary: String
        switch result {
        case .available(let release): summary = "\(release.tag) available"  // not its notes: they'd fill the log
        default: summary = String(describing: result)
        }
        log.notice("update check: \(summary, privacy: .public)")
        onChange?()
        done?(result)
    }

    /// Downloads, builds and installs the release found by the last check, then opens the new copy and quits this one.
    func install() {
        guard !installing else { return }
        guard case .available(let release) = status else {
            log.notice("install asked for without a release to install; checking first")
            return check { if case .available = $0 { self.install() } }
        }
        guard let command = InstallCommand.forRelease(tag: release.tag, repository: Updater.repository) else {
            return finish(.failed("the latest release's tag isn't a version (vX.Y.Z)"), nil)
        }
        installing = true
        compileStarted = nil
        progress = UpdateProgress.state(log: "", compilingFor: 0, expectedCompile: expectedCompile)
        onChange?()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        // The installer leaves restarting to us (LAYOUT_FIXER_NO_LAUNCH): it can't reliably quit the app that started it.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                               "LAYOUT_FIXER_NO_LAUNCH": "1"]
        FileManager.default.createFile(atPath: Updater.logURL.path, contents: nil)
        if let output = try? FileHandle(forWritingTo: Updater.logURL) {
            process.standardOutput = output
            process.standardError = output
        }
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else {
                DispatchQueue.main.async { Updater.relaunch() }
                return
            }
            DispatchQueue.main.async {
                self.installing = false
                self.stopProgress()
                self.onChange?()
                let alert = NSAlert()
                alert.messageText = "The update didn't install"
                alert.informativeText = "Layout Fixer is unchanged. Details are in \(Updater.logURL.path)."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        log.notice("installing release \(release.tag, privacy: .public)")
        do {
            try process.run()
            progressTimer = Timer.scheduledTimer(withTimeInterval: Updater.progressInterval, repeats: true) { [weak self] _ in
                self?.readProgress()
            }
        } catch {
            log.error("could not start the installer: \(error.localizedDescription, privacy: .public)")
            installing = false
            stopProgress()
            onChange?()
        }
    }

    private func readProgress() {
        let output = (try? String(contentsOf: Updater.logURL, encoding: .utf8)) ?? ""
        if compileStarted == nil && UpdateProgress.isCompiling(log: output) { compileStarted = Date() }
        let compiling = compileStarted.map { Date().timeIntervalSince($0) } ?? 0
        progress = UpdateProgress.state(log: output, compilingFor: compiling, expectedCompile: expectedCompile)
        if let built = UpdateProgress.builtSeconds(log: output) {
            UserDefaults.standard.set(Double(built), forKey: "lastBuildSeconds")
        }
        onChange?()
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = nil
    }

    /// Open the freshly installed copy once this one has quit.
    private static func relaunch() {
        log.notice("update installed; restarting")
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? opener.run()
        NSApp.terminate(nil)
    }
}
