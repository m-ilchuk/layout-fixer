import AppKit

/// "Export Debug Log…": Layout Fixer's own log for the last day, the last update's output and a short summary,
/// in one text file to send to whoever is helping. The log never holds typed text: counts, layouts, reasons.
enum DebugLog {
    static let subsystem = "io.github.m-ilchuk.layoutfixer"
    static let period = "24h"

    /// Asks where to save (the save panel also gives access to that folder), then writes the file and shows it.
    static func export(summary: String) {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "Layout Fixer debug \(stamp.string(from: Date())).txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let text = """
            Layout Fixer debug log
            \(summary)
            Exported: \(Date())

            == Log, last \(period) ==
            \(appLog())

            == Last update ==
            \((try? String(contentsOf: Updater.logURL, encoding: .utf8)) ?? "(no update run yet)")
            """
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save the debug log"
                    alert.informativeText = "\(error.localizedDescription) Try another folder."
                    alert.runModal()
                }
            }
        }
    }

    /// `log show` for this app's subsystem: works without admin rights for the user's own processes.
    private static func appLog() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", period, "--style", "compact", "--info",
                             "--predicate", "subsystem == \"\(subsystem)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "(couldn't read the log: \(error.localizedDescription))"
        }
    }
}
