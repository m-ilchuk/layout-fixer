import AppKit
import Carbon

// End-to-end: types corpus sentences into TextEdit with real key events while the real Layout Fixer runs, and
// checks what TextEdit shows: one document per scenario, a line per sentence, and a report in build/e2e-report.txt. It covers what the simulated Mac only models: macOS's layout reports, the text in key
// events, switch timing, and what the app really receives. Run it with ./e2e.sh (README: "End-to-end test").
//
//   ./e2e.sh               a sample of each kind of sentence, every scenario
//   ./e2e.sh all           every corpus sentence
//
// Needs: Accessibility for the app running it (Terminal), TextEdit allowed to be controlled (asked once),
// Layout Fixer running with "Fix automatically while typing" on, and ABC and Ukrainian-PC turned on.

let keyDelay: useconds_t = 35_000       // between keys: a fast typist
let afterSpaceDelay: useconds_t = 150_000
let settle: useconds_t = 700_000         // before reading what TextEdit shows
let bundleID = "io.github.m-ilchuk.layoutfixer"

func fail(_ message: String) -> Never {
    print("e2e: \(message)")
    exit(2)
}

guard AXIsProcessTrusted() else {
    fail("this Terminal can't send key presses. Allow it in System Settings › Privacy & Security › Accessibility, "
         + "then run ./e2e.sh again.")
}
guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
    fail("Layout Fixer isn't running. Open it first.")
}
guard UserDefaults(suiteName: bundleID)?.bool(forKey: "autoFix") == true else {
    fail("turn on \"Fix automatically while typing\" in Layout Fixer's window first.")
}
let installed = KeyLayout.installed(ids: ["com.apple.keylayout.ABC", "com.apple.keylayout.Ukrainian-PC"])
guard installed.count == 2 else { fail("needs the ABC and Ukrainian - PC layouts.") }
let english = installed[0], ukrainian = installed[1]

func run(_ script: String) -> String? {
    var error: NSDictionary?
    let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
    if let error { fail("AppleScript: \(error[NSAppleScript.errorMessage] ?? error)") }
    return result?.stringValue
}

func press(_ stroke: KeyStroke) {
    var flags: CGEventFlags = []
    if stroke.modifiers & KeyStroke.shift != 0 { flags.insert(.maskShift) }
    if stroke.modifiers & KeyStroke.option != 0 { flags.insert(.maskAlternate) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    usleep(keyDelay)
}

func meantLayout(_ word: String) -> KeyLayout? {
    if word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return ukrainian }
    if word.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.isASCII }) { return english }
    return nil
}

func currentLayout() -> KeyLayout {
    let id = KeyLayout.currentLayoutID()
    return installed.first { $0.id == id } ?? english
}

enum Scenario: String, CaseIterable {
    case switchesCorrectly = "switches layouts correctly"
    case neverSwitchesFromEnglish = "never switches, starts on English"
    case neverSwitchesFromUkrainian = "never switches, starts on Ukrainian"
}

/// Types every sentence of a scenario into one new TextEdit document, a line each (Return clears Layout Fixer's
/// memory between lines, like separate messages), and returns the document's lines.
func typeScenario(_ sentences: [String], _ scenario: Scenario) -> [String] {
    _ = run("""
        tell application "TextEdit"
            activate
            make new document
        end tell
        """)
    usleep(800_000)
    for sentence in sentences {
        let words = sentence.split(separator: " ").map(String.init)
        let start: KeyLayout
        switch scenario {
        case .switchesCorrectly: start = words.compactMap(meantLayout).first ?? english
        case .neverSwitchesFromEnglish: start = english
        case .neverSwitchesFromUkrainian: start = ukrainian
        }
        start.select()
        usleep(300_000)
        for word in words {
            let meant = meantLayout(word) ?? currentLayout()
            if scenario == .switchesCorrectly, meantLayout(word) != nil, currentLayout().id != meant.id {
                meant.select()
                usleep(200_000)
            }
            for char in word { press(meant.strokeForCharacter[char]!) }
            press(KeyStroke(keyCode: 49, modifiers: 0))
            usleep(afterSpaceDelay)
        }
        press(KeyStroke(keyCode: 36, modifiers: 0))  // Return: next line
        usleep(afterSpaceDelay)
    }
    usleep(settle)
    let text = run("tell application \"TextEdit\" to get text of front document") ?? ""
    return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
}

let everything = CommandLine.arguments.contains("all")
let sentences = everything ? Corpus.all
    : Array(Corpus.ukrainian.prefix(8)) + Array(Corpus.english.prefix(6)) + Array(Corpus.mixed.prefix(10))
let reportURL = URL(fileURLWithPath: "build/e2e-report.txt")
print("e2e: \(sentences.count) sentences × \(Scenario.allCases.count) scenarios, one TextEdit document each.")
print("e2e: don't touch the keyboard or mouse until it says it's done.")
var report = ["Layout Fixer end-to-end test, \(Date())", ""]
var misses = 0
for scenario in Scenario.allCases {
    let lines = typeScenario(sentences, scenario)
    var right = 0
    var details: [String] = []
    for (index, sentence) in sentences.enumerated() {
        let shown = index < lines.count ? lines[index] : "(no line)"
        if shown == sentence { right += 1 } else { details.append("  MISS\n    got:  \(shown)\n    want: \(sentence)") }
    }
    misses += sentences.count - right
    let summary = "\(right)/\(sentences.count)  \(scenario.rawValue)"
    print("e2e: " + summary)
    details.forEach { print($0) }
    report += [summary] + details + [""]
}
try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
print("e2e: done. The documents stay open in TextEdit; the report is in \(reportURL.path).")
exit(misses == 0 ? 0 : 1)
