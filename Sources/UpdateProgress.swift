import Foundation

/// How far an in-app update has got, read from the installer's log: get.sh writes "Downloading", "Building", the
/// build's "==> " steps and "Built in Ns". Compiling reports nothing while it runs, so its share of the bar grows
/// with the time spent against how long the last build took, and stops just short until the next step shows.
enum UpdateProgress {
    struct State: Equatable {
        let fraction: Double
        let step: String
        var percent: Int { Int((fraction * 100).rounded()) }
    }

    static let compileShare = (from: 0.10, to: 0.88)
    static let compileStep = "Compiling"

    static func state(log: String, compilingFor seconds: TimeInterval, expectedCompile: TimeInterval) -> State {
        if builtSeconds(log: log) != nil { return State(fraction: 0.97, step: "Restarting…") }
        let step = log.split(separator: "\n").last { $0.hasPrefix("==> ") }.map { String($0.dropFirst(4)) }
        switch step {
        case let step? where step.hasPrefix("Installing"):
            return State(fraction: 0.94, step: "Installing…")
        case let step? where step.hasPrefix("Signing"):
            return State(fraction: 0.90, step: "Signing…")
        case let step? where step.hasPrefix(compileStep):
            let done = min(max(seconds / max(expectedCompile, 1), 0), 0.98)
            let fraction = compileShare.from + (compileShare.to - compileShare.from) * done
            return State(fraction: fraction, step: step + "…")
        default:
            if log.contains("Building") { return State(fraction: 0.08, step: "Building…") }
            if log.contains("Downloading") { return State(fraction: 0.04, step: "Downloading…") }
            return State(fraction: 0.01, step: "Starting…")
        }
    }

    static func isCompiling(log: String) -> Bool {
        log.split(separator: "\n").last { $0.hasPrefix("==> ") }?.dropFirst(4).hasPrefix(compileStep) == true
    }

    /// "Built in 41s" → 41: how long the next build will likely take.
    static func builtSeconds(log: String) -> Int? {
        guard let line = log.split(separator: "\n").last(where: { $0.hasPrefix("Built in ") }) else { return nil }
        return Int(line.dropFirst("Built in ".count).prefix { $0.isNumber })
    }
}
