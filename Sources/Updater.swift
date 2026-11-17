import AppKit

/// Checks GitHub Releases for a newer version (semantic versioning: v1.2.0 > v1.1.9) and installs it by running
/// the same one-line installer as the README. The only network calls Layout Fixer makes; they send nothing about you.
final class Updater {
    static let repository = "m-ilchuk/layout-fixer"
    static let branch = "main"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/\(repository)/\(branch)/get.sh | bash"
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayoutFixer-update.log")
    }

    struct Release: Equatable {
        let version: String
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
                result = latest > current ? .available(Release(version: latest.description, notes: notes)) : .upToDate
            } else {
                result = .failed("GitHub answered \(code)")
            }
            DispatchQueue.main.async { self.finish(result, done) }
        }.resume()
    }

    private func finish(_ result: Status, _ done: ((Status) -> Void)?) {
        status = result
        log.info("update check: \(String(describing: result), privacy: .public)")
        onChange?()
        done?(result)
    }

    /// Downloads, builds and installs the latest version, then opens the new copy and quits this one.
    func install() {
        guard !installing else { return }
        installing = true
        onChange?()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", Updater.installCommand]
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
                self.onChange?()
                let alert = NSAlert()
                alert.messageText = "The update didn't install"
                alert.informativeText = "Layout Fixer is unchanged. Details are in \(Updater.logURL.path)."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        log.info("installing the latest release")
        do { try process.run() } catch {
            log.error("could not start the installer: \(error.localizedDescription, privacy: .public)")
            installing = false
            onChange?()
        }
    }

    /// Open the freshly installed copy once this one has quit.
    private static func relaunch() {
        log.info("update installed; restarting")
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? opener.run()
        NSApp.terminate(nil)
    }
}
