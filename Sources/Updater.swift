import AppKit

/// Checks GitHub for a newer version and installs it by running the same one-line installer as the README.
/// The only network calls Layout Fixer makes; they send nothing but the version it was built from.
final class Updater {
    static let repository = "m-ilchuk/layout-fixer"
    static let branch = "main"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/\(repository)/\(branch)/get.sh | bash"
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayoutFixer-update.log")
    }

    enum Status: Equatable {
        case unknown, upToDate, available(changes: Int), failed(String)
    }

    /// The commit this build came from (build.sh writes it into Info.plist).
    static var currentCommit: String? {
        let commit = Bundle.main.object(forInfoDictionaryKey: "LFSourceCommit") as? String
        return commit == "unknown" ? nil : commit
    }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdates") }
    }
    private(set) var status: Status = .unknown
    var onChange: (() -> Void)?
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Updater.checkInterval, repeats: true) { [weak self] _ in
            if self?.automatic == true { self?.check() }
        }
        if automatic { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.check() } }
    }

    /// Asks GitHub how far main is ahead of this build.
    func check(then done: ((Status) -> Void)? = nil) {
        guard let current = Updater.currentCommit else { return finish(.failed("this build doesn't know its version"), done) }
        let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/compare/\(current)...\(Updater.branch)")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Status
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                result = .failed(error.localizedDescription)
            } else if code == 404 {
                result = .upToDate  // built from a commit GitHub doesn't have yet (a local change)
            } else if code == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ahead = json["ahead_by"] as? Int {
                result = ahead > 0 ? .available(changes: ahead) : .upToDate
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

    /// Downloads, builds and installs the latest version; the installer quits this copy and starts the new one.
    func install() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", Updater.installCommand]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        FileManager.default.createFile(atPath: Updater.logURL.path, contents: nil)
        if let output = try? FileHandle(forWritingTo: Updater.logURL) {
            process.standardOutput = output
            process.standardError = output
        }
        process.terminationHandler = { finished in
            // Only reached when the install failed: on success the installer quits this app first.
            guard finished.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "The update didn't install"
                alert.informativeText = "Layout Fixer is unchanged. Details are in \(Updater.logURL.path)."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        do { try process.run() } catch {
            log.error("could not start the installer: \(error.localizedDescription, privacy: .public)")
        }
    }
}
