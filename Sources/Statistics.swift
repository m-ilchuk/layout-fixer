import Foundation

/// How many words Layout Fixer changed, per day: counts only, never any text.
struct Statistics: Codable, Equatable {
    enum Kind { case autoFixed, converted, undone }

    struct Counts: Codable, Equatable {
        /// Words fixed while typing.
        var autoFixed = 0
        /// Words converted with right ⌥ (the last word or a selection).
        var converted = 0
        /// Automatic fixes undone right after (right ⌥, ⌘Z, or erased and typed again as before).
        var undone = 0

        init(autoFixed: Int = 0, converted: Int = 0, undone: Int = 0) {
            (self.autoFixed, self.converted, self.undone) = (autoFixed, converted, undone)
        }

        /// A counter added later reads as 0 from what an older version saved.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            autoFixed = try values.decodeIfPresent(Int.self, forKey: .autoFixed) ?? 0
            converted = try values.decodeIfPresent(Int.self, forKey: .converted) ?? 0
            undone = try values.decodeIfPresent(Int.self, forKey: .undone) ?? 0
        }

        static func + (a: Counts, b: Counts) -> Counts {
            Counts(autoFixed: a.autoFixed + b.autoFixed, converted: a.converted + b.converted, undone: a.undone + b.undone)
        }

        /// The share of automatic fixes that were kept, nil before the first one.
        var keptRate: Double? {
            guard autoFixed > 0 else { return nil }
            return min(1, max(0, 1 - Double(undone) / Double(autoFixed)))
        }
    }

    struct Summary: Equatable {
        let today: Counts
        /// Today and the six days before it.
        let lastSevenDays: Counts
        let allTime: Counts
        let since: Date
    }

    static let windowDays = 7
    static let defaultsKey = "statistics"
    /// Days on the Gregorian calendar in the Mac's time zone, whatever calendar the Mac shows.
    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Keyed by the day on the Mac's calendar, "2026-11-20".
    private(set) var days: [String: Counts] = [:]
    private(set) var since: Date

    init(since: Date) { self.since = since }

    mutating func record(_ kind: Kind, words: Int, at date: Date, calendar: Calendar = Statistics.localCalendar) {
        guard words > 0 else { return }
        let key = Self.dayKey(date, calendar: calendar)
        var counts = days[key] ?? Counts()
        switch kind {
        case .autoFixed: counts.autoFixed += words
        case .converted: counts.converted += words
        case .undone: counts.undone += words
        }
        days[key] = counts
    }

    func summary(now: Date, calendar: Calendar = Statistics.localCalendar) -> Summary {
        let today = days[Self.dayKey(now, calendar: calendar)] ?? Counts()
        let week = (0..<Self.windowDays).reduce(Counts()) { total, back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { return total }
            return total + (days[Self.dayKey(day, calendar: calendar)] ?? Counts())
        }
        let all = days.values.reduce(Counts(), +)
        return Summary(today: today, lastSevenDays: week, allTime: all, since: since)
    }

    mutating func reset(now: Date) {
        days.removeAll()
        since = now
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Statistics saved under `defaultsKey`; fresh ones (counting from `now`) when there are none or they can't
    /// be read. What can't be read is kept aside under "<key>.unreadable", not lost.
    static func load(from defaults: UserDefaults, now: Date) -> Statistics {
        guard let data = defaults.data(forKey: defaultsKey) else { return Statistics(since: now) }
        guard let saved = try? JSONDecoder().decode(Statistics.self, from: data) else {
            defaults.set(data, forKey: defaultsKey + ".unreadable")
            return Statistics(since: now)
        }
        return saved
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Statistics.defaultsKey)
    }
}
