import Foundation
import SQLite3
import Darwin

private enum FBCountError: Error, CustomStringConvertible {
    case database(String)
    case missingDatabase(String)
    case usage

    var description: String {
        switch self {
        case .usage: "Usage: fbc [--missing | --help]"
        case .database(let message): message
        case .missingDatabase(let path): "Feedback database not found at \(path)"
        }
    }
}

private final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FBCountError.missingDatabase(path)
        }
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(handle)
            throw FBCountError.database(message)
        }
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String, consume: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FBCountError.database(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try consume(statement)
            case SQLITE_DONE: return
            default: throw FBCountError.database(errorMessage)
            }
        }
    }

    func integer(_ sql: String) throws -> Int {
        var value = 0
        try rows(sql) { value = Int(sqlite3_column_int64($0, 0)) }
        return value
    }

    func text(_ sql: String) throws -> String {
        var value = ""
        try rows(sql) { value = Self.text($0, column: 0) ?? "" }
        return value
    }

    static func integer(_ statement: OpaquePointer, column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    static func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
    }
}

private enum Platform: String, CaseIterable {
    case iOS, macOS, iPadOS, watchOS, tvOS, visionOS
}

private struct Feedback {
    let area: String
    let remoteID: Int64
    let isClosed: Bool
    let responseID: Int64?
    let createdAt: Double
    let stub: Data?
}

private struct Category {
    let name: String
    let open: Int
    let closed: Int

    var total: Int { open + closed }
}

private struct Counts {
    var open = 0
    var closed = 0

    var total: Int { open + closed }
    var closedPercent: Double {
        total == 0 ? 0 : Double(closed) * 100 / Double(total)
    }

    mutating func add(isClosed: Bool) {
        if isClosed {
            closed += 1
        } else {
            open += 1
        }
    }
}

private func decodedPlatform(in data: Data) -> Platform? {
    guard let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) else {
        return nil
    }
    return findPlatform(in: propertyList)
}

private func feedbackType(for answer: String) -> String? {
    switch answer {
    case "Suggestion", "Enhancement Request": return "Suggestion"
    case "Incorrect/Unexpected Behavior", "Error or issue using a feature",
         "Application Crash", "Application Slow/Unresponsive",
         "Crash", "Crash/Hang/Data Loss", "Bug Report": return "Bug"
    default: return nil
    }
}

@objc(FBCCachedQuestion)
private final class CachedQuestion: NSObject, NSCoding {
    let text: String?
    let answer: String?

    required init?(coder: NSCoder) {
        text = coder.decodeObject(forKey: "question_text") as? String
        answer = coder.decodeObject(forKey: "answer_text") as? String
    }

    func encode(with coder: NSCoder) {}
}

@objc(FBCCachedQuestionGroup)
private final class CachedQuestionGroup: NSObject, NSCoding {
    let questions: [CachedQuestion]

    required init?(coder: NSCoder) {
        questions = coder.decodeObject(forKey: "questions") as? [CachedQuestion] ?? []
    }

    func encode(with coder: NSCoder) {}
}

private func cachedQuestions(in data: Data) -> [CachedQuestion]? {
    guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    defer { decoder.finishDecoding() }
    decoder.requiresSecureCoding = false
    decoder.decodingFailurePolicy = .setErrorAndReturn
    decoder.setClass(CachedQuestion.self, forClassName: "FBKQuestionAnswerPair")
    decoder.setClass(CachedQuestionGroup.self, forClassName: "FBKQuestionGroupStub")
    guard let groups = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        as? [CachedQuestionGroup] else { return nil }
    let questions = groups.flatMap(\.questions)
    guard decoder.error == nil, !questions.isEmpty,
          questions.allSatisfy({ $0.text != nil }) else { return nil }
    return questions
}

private func decodedStubFeedbackType(in data: Data) -> String? {
    guard let questions = cachedQuestions(in: data) else { return nil }
    let types = Set(questions.compactMap { question -> String? in
        guard let text = question.text,
              ["What type of feedback are you reporting?", "What type of issue are you reporting?"]
                .contains(text),
              let answer = question.answer else { return nil }
        return feedbackType(for: answer)
    })
    return types.count == 1 ? types.first : nil
}

private enum MissingFieldState: String {
    case needsHydration
    case unavailable = "not provided by cached form"
    case unanswered = "no answer in cached form"
    case unrecognized = "unrecognized cached answer"
    case unreadable = "cached form could not be decoded"

    var isUnspecified: Bool { self == .unavailable || self == .unanswered }
}

private func missingFieldState(_ field: String, stub: Data?) -> MissingFieldState {
    guard let stub else { return .needsHydration }
    guard let questions = cachedQuestions(in: stub) else { return .unreadable }
    let matching = questions.filter { question in
        guard let text = question.text else { return false }
        if field == "type" {
            return ["What type of feedback are you reporting?", "What type of issue are you reporting?"]
                .contains(text)
        }
        return text == "Which platform is most relevant for your report?"
    }
    guard !matching.isEmpty else { return .unavailable }
    return matching.contains { !($0.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ? .unrecognized : .unanswered
}

private func decodedFeedbackType(in data: Data) -> String? {
    guard let answers = try? NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [NSArray.self, NSString.self], from: data
    ) as? [String], answers.count == 1 else { return nil }
    return feedbackType(for: answers[0])
}

private func findPlatform(in value: Any) -> Platform? {
    if let string = value as? String, let platform = Platform(rawValue: string) {
        return platform
    }
    if let array = value as? [Any] {
        return array.lazy.compactMap(findPlatform).first
    }
    if let dictionary = value as? [AnyHashable: Any] {
        return dictionary.values.lazy.compactMap(findPlatform).first
    }
    if let set = value as? Set<AnyHashable> {
        return set.lazy.compactMap(findPlatform).first
    }
    return nil
}

private func split(_ value: String, expectedCount: Int) throws -> [String] {
    let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == expectedCount else {
        throw FBCountError.database("Unexpected aggregate result: \(value)")
    }
    return parts
}

private let feedbackAssistantIcon = [
    "      ▄▄▄▄████████████████████▄▄▄▄",
    "   ▄████████████████████████████████▄",
    "  ████████████████████████████████████",
    " ██████████████████████████████████████",
    "█████████                      █████████",
    "███████                          ███████",
    "██████                            ██████",
    "██████             ██             ██████",
    "██████             ██             ██████",
    "██████             ██             ██████",
    "██████             ██             ██████",
    "██████             ██             ██████",
    "██████                            ██████",
    "██████            ▄██▄            ██████",
    "███████                          ███████",
    " ████████████       ███████████████████",
    " ████████████     █████████████████████",
    "  ████████████  ██████████████████████",
    "   ▀████████████████████████████████▀",
    "      ▀▀▀▀████████████████████▀▀▀▀",
]

private func printDashboard(_ statsLines: [String]) {
    let usesColor = isatty(STDOUT_FILENO) != 0
    let purple = usesColor ? "\u{001B}[38;5;99m" : ""
    let reset = usesColor ? "\u{001B}[0m" : ""
    let iconWidth = feedbackAssistantIcon.map(\.count).max() ?? 0
    let leftLines = feedbackAssistantIcon
    let lineCount = max(leftLines.count, statsLines.count)

    for index in 0..<lineCount {
        let rawLeft = index < leftLines.count ? leftLines[index] : ""
        let paddedLeft = rawLeft.padding(toLength: iconWidth, withPad: " ", startingAt: 0)
        let left = index < feedbackAssistantIcon.count
            ? purple + paddedLeft + reset
            : paddedLeft
        let right = index < statsLines.count ? statsLines[index] : ""
        print(right.isEmpty ? left : left + "    " + right)
    }
}

private func section(_ title: String) -> String {
    let usesColor = isatty(STDOUT_FILENO) != 0
    let style = usesColor ? "\u{001B}[1;38;5;99m" : ""
    let reset = usesColor ? "\u{001B}[0m" : ""
    return style + title + reset
}

private func header(_ value: String, width: Int) -> String {
    let usesColor = isatty(STDOUT_FILENO) != 0
    let purple = usesColor ? "\u{001B}[38;5;99m" : ""
    let reset = usesColor ? "\u{001B}[0m" : ""
    return purple + value + reset
        + String(repeating: " ", count: max(0, width - value.count))
}

private func row(_ label: String, _ value: String, indent: Int = 2, labelWidth: Int = 18) -> String {
    let prefix = String(repeating: " ", count: indent)
    let availableLabelWidth = max(1, labelWidth - indent)
    return prefix + label.padding(toLength: availableLabelWidth, withPad: " ", startingAt: 0) + value
}

private func leftAligned(_ value: String, width: Int) -> String {
    value + String(repeating: " ", count: max(0, width - value.count))
}

private func sectionLabel(_ title: String, labelWidth: Int) -> String {
    let prefix = "  "
    let availableLabelWidth = max(1, labelWidth - prefix.count)
    return prefix + section(title)
        + String(repeating: " ", count: max(0, availableLabelWidth - title.count))
}

private func countHeader(_ title: String, labelWidth: Int = 18) -> String {
    sectionLabel(title, labelWidth: labelWidth)
        + header("Open", width: 7)
        + header("Closed", width: 8)
        + header("Total", width: 7)
        + header("Closed %", width: 11)
}

private func activityHeader(labelWidth: Int = 18) -> String {
    sectionLabel("Activity", labelWidth: labelWidth)
        + header("FBs", width: 7)
        + header("Date", width: 14)
}

private func activityRow(_ label: String, feedbackCount: String, date: String, labelWidth: Int = 18) -> String {
    let prefix = "  "
    let availableLabelWidth = max(1, labelWidth - prefix.count)
    return prefix + label.padding(toLength: availableLabelWidth, withPad: " ", startingAt: 0)
        + leftAligned(feedbackCount, width: 7)
        + leftAligned(date, width: 14)
}

private func streakHeader(labelWidth: Int = 18) -> String {
    sectionLabel("Streaks", labelWidth: labelWidth)
        + header("Days", width: 7)
        + header("FBs", width: 7)
        + header("Range", width: 27)
}

private func streakRow(
    _ label: String,
    days: String,
    feedbackCount: String,
    start: String,
    end: String,
    labelWidth: Int = 18
) -> String {
    let prefix = "  "
    let availableLabelWidth = max(1, labelWidth - prefix.count)
    let range = start.isEmpty || end.isEmpty ? "—" : "\(start) → \(end)"
    return prefix + label.padding(toLength: availableLabelWidth, withPad: " ", startingAt: 0)
        + leftAligned(days, width: 7)
        + leftAligned(feedbackCount, width: 7)
        + leftAligned(range, width: 27)
}

private func countRow(_ label: String, counts: Counts, indent: Int = 2, labelWidth: Int = 18) -> String {
    let prefix = String(repeating: " ", count: indent)
    let availableLabelWidth = max(1, labelWidth - indent)
    return prefix + label.padding(toLength: availableLabelWidth, withPad: " ", startingAt: 0)
        + leftAligned("\(counts.open)", width: 7)
        + leftAligned("\(counts.closed)", width: 8)
        + leftAligned("\(counts.total)", width: 7)
        + leftAligned(String(format: "%.1f%%", counts.closedPercent), width: 11)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
        print("Usage: fbc [--missing | --help]")
        print("  --missing  List reports with missing or unreadable details.")
        return
    }
    guard arguments.isEmpty || arguments == ["--missing"] else { throw FBCountError.usage }
    let showsMissing = arguments == ["--missing"]
    let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.feedback/Library/Application Support/feedback.sqlite")
        .path
    let database = try Database(path: databasePath)

    let total = try database.integer("SELECT COUNT(*) FROM ZCONTENTITEM WHERE ZTYPE = 4;")
    let closed = try database.integer("SELECT COUNT(*) FROM ZCONTENTITEM WHERE ZTYPE = 4 AND ZCLOSED = 1;")
    let summaryCounts = Counts(open: total - closed, closed: closed)

    var categories: [Category] = []
    try database.rows("""
        SELECT ZAREA,
               SUM(CASE WHEN ZCLOSED = 1 THEN 0 ELSE 1 END) AS open_count,
               SUM(CASE WHEN ZCLOSED = 1 THEN 1 ELSE 0 END) AS closed_count,
               COUNT(*) AS feedback_count
        FROM ZCONTENTITEM
        WHERE ZTYPE = 4 AND ZAREA IS NOT NULL AND trim(ZAREA) != ''
        GROUP BY ZAREA
        ORDER BY feedback_count DESC, ZAREA
        LIMIT 3;
        """) { statement in
            guard let name = Database.text(statement, column: 0) else { return }
            categories.append(Category(
                name: name,
                open: Int(Database.integer(statement, column: 1) ?? 0),
                closed: Int(Database.integer(statement, column: 2) ?? 0)
            ))
        }

    var feedback: [Feedback] = []
    try database.rows("""
        WITH top_areas AS (
          SELECT ZAREA FROM ZCONTENTITEM
          WHERE ZTYPE = 4 AND ZAREA IS NOT NULL AND trim(ZAREA) != ''
          GROUP BY ZAREA ORDER BY COUNT(*) DESC, ZAREA LIMIT 3
        )
        SELECT ZCONTENTITEM.ZAREA, ZCONTENTITEM.ZREMOTEID, ZCONTENTITEM.ZCLOSED,
               ZCONTENTITEM.ZFORMRESPONSE, ZCONTENTITEM.ZCREATEDAT,
               ZFORMRESPONSESTUB.ZQUESTIONGROUPSTUBS
        FROM ZCONTENTITEM
        LEFT JOIN ZFORMRESPONSESTUB
          ON ZFORMRESPONSESTUB.Z_PK = ZCONTENTITEM.ZFORMRESPONSESTUB
        WHERE ZCONTENTITEM.ZTYPE = 4
          AND ZCONTENTITEM.ZAREA IN (SELECT ZAREA FROM top_areas);
        """) { statement in
            guard let area = Database.text(statement, column: 0) else { return }
            feedback.append(Feedback(
                area: area,
                remoteID: Database.integer(statement, column: 1) ?? 0,
                isClosed: (Database.integer(statement, column: 2) ?? 0) == 1,
                responseID: Database.integer(statement, column: 3),
                createdAt: sqlite3_column_double(statement, 4),
                stub: Database.data(statement, column: 5)
            ))
        }

    var answerPlatforms: [Int64: Platform] = [:]
    try database.rows("""
        WITH top_areas AS (
          SELECT ZAREA FROM ZCONTENTITEM
          WHERE ZTYPE = 4 AND ZAREA IS NOT NULL AND trim(ZAREA) != ''
          GROUP BY ZAREA ORDER BY COUNT(*) DESC, ZAREA LIMIT 3
        )
        SELECT ZANSWER.ZFORMRESPONSE, ZANSWER.ZVALUES
        FROM ZANSWER
        JOIN ZFORMRESPONSE ON ZFORMRESPONSE.Z_PK = ZANSWER.ZFORMRESPONSE
        JOIN ZCONTENTITEM ON ZCONTENTITEM.Z_PK = ZFORMRESPONSE.ZCONTENTITEM
        WHERE ZCONTENTITEM.ZTYPE = 4
          AND ZCONTENTITEM.ZAREA IN (SELECT ZAREA FROM top_areas);
        """) { statement in
            guard let responseID = Database.integer(statement, column: 0),
                  answerPlatforms[responseID] == nil,
                  let data = Database.data(statement, column: 1),
                  let platform = decodedPlatform(in: data) else { return }
            answerPlatforms[responseID] = platform
        }

    var platformCounts: [String: [Platform: Counts]] = [:]
    var unspecifiedPlatforms: [String: Counts] = [:]
    var unknown: [String: [Feedback]] = [:]
    for item in feedback {
        let platform = item.stub.flatMap(decodedPlatform)
            ?? item.responseID.flatMap { answerPlatforms[$0] }
        if let platform {
            platformCounts[item.area, default: [:]][platform, default: Counts()].add(isClosed: item.isClosed)
        } else if missingFieldState("platform", stub: item.stub).isUnspecified {
            unspecifiedPlatforms[item.area, default: Counts()].add(isClosed: item.isClosed)
        } else {
            unknown[item.area, default: []].append(item)
        }
    }

    var missingMetadata: [Int64: Set<String>] = [:]
    var cachedMetadataIssues: [Int64: Set<String>] = [:]
    func recordMissingField(_ field: String, remoteID: Int64, stub: Data?) {
        guard remoteID > 0 else { return }
        let state = missingFieldState(field, stub: stub)
        guard !state.isUnspecified else { return }
        if state == .needsHydration {
            missingMetadata[remoteID, default: []].insert(field)
        } else {
            cachedMetadataIssues[remoteID, default: []].insert("\(field): \(state.rawValue)")
        }
    }
    var feedbackTypes: [String: Counts] = [:]
    var answerTypes: [Int64: Set<String>] = [:]
    try database.rows("""
        SELECT a.ZFORMRESPONSE, a.ZVALUES
        FROM ZANSWER a
        LEFT JOIN ZQUESTION q ON q.Z_PK = a.ZQUESTION
        WHERE q.ZROLE = ':type_req'
           OR q.ZTEXT IN ('What type of feedback are you reporting?', 'What type of issue are you reporting?')
           OR a.ZQUESTION IS NULL;
        """) { statement in
            guard let responseID = Database.integer(statement, column: 0),
                  let data = Database.data(statement, column: 1),
                  let type = decodedFeedbackType(in: data) else { return }
            answerTypes[responseID, default: []].insert(type)
        }
    try database.rows("""
        SELECT c.ZCLOSED, c.ZFORMRESPONSE, s.ZQUESTIONGROUPSTUBS, c.ZSUBTITLE, c.ZREMOTEID
        FROM ZCONTENTITEM c
        LEFT JOIN ZFORMRESPONSESTUB s ON s.Z_PK = c.ZFORMRESPONSESTUB
        WHERE c.ZTYPE = 4;
        """) { statement in
            // Dedicated report forms identify their type in the cached list subtitle.
            let subtitle = Database.text(statement, column: 3) ?? ""
            let formType = ["Crash Report", "Share Feedback"].first {
                subtitle.hasSuffix(" — " + $0)
            }.map { $0 == "Share Feedback" ? "Other" : "Bug" }
            let type = formType
                ?? Database.data(statement, column: 2).flatMap(decodedStubFeedbackType)
                ?? Database.integer(statement, column: 1).flatMap { responseID in
                    let types = answerTypes[responseID, default: []]
                    return types.count == 1 ? types.first : nil
                }
                ?? "Unknown"
            let displayedType = type == "Unknown"
                && missingFieldState("type", stub: Database.data(statement, column: 2)).isUnspecified
                ? "Unspecified" : type
            feedbackTypes[displayedType, default: Counts()].add(
                isClosed: Database.integer(statement, column: 0) == 1
            )
            if displayedType == "Unknown", let remoteID = Database.integer(statement, column: 4), remoteID > 0 {
                recordMissingField("type", remoteID: remoteID, stub: Database.data(statement, column: 2))
            }
        }

    var years: [(String, Counts)] = []
    try database.rows("""
        SELECT strftime('%Y', ZCREATEDAT + 978307200, 'unixepoch', 'localtime') AS year,
               SUM(CASE WHEN ZCLOSED = 1 THEN 0 ELSE 1 END) AS open_count,
               SUM(CASE WHEN ZCLOSED = 1 THEN 1 ELSE 0 END) AS closed_count
        FROM ZCONTENTITEM
        WHERE ZTYPE = 4
        GROUP BY year
        ORDER BY year DESC;
        """) { statement in
            guard let year = Database.text(statement, column: 0) else { return }
            years.append((
                year,
                Counts(
                    open: Int(Database.integer(statement, column: 1) ?? 0),
                    closed: Int(Database.integer(statement, column: 2) ?? 0)
                )
            ))
        }

    let today = try database.integer("""
        SELECT COUNT(*) FROM ZCONTENTITEM
        WHERE ZTYPE = 4
          AND date(ZCREATEDAT + 978307200, 'unixepoch', 'localtime') = date('now', 'localtime');
        """)
    let todayDate = try database.text("SELECT date('now', 'localtime');")
    let currentStreak = try split(database.text("""
        WITH RECURSIVE streak(day) AS (
          SELECT date('now', 'localtime') WHERE EXISTS (
            SELECT 1 FROM ZCONTENTITEM WHERE ZTYPE = 4
              AND date(ZCREATEDAT + 978307200, 'unixepoch', 'localtime') = date('now', 'localtime')
          )
          UNION ALL
          SELECT date(day, '-1 day') FROM streak WHERE EXISTS (
            SELECT 1 FROM ZCONTENTITEM WHERE ZTYPE = 4
              AND date(ZCREATEDAT + 978307200, 'unixepoch', 'localtime') = date(day, '-1 day')
          )
        )
        SELECT COALESCE(MIN(day), '') || '|' || COALESCE(MAX(day), '') || '|' || COUNT(*) || '|' || (
          SELECT COUNT(*) FROM ZCONTENTITEM WHERE ZTYPE = 4
            AND date(ZCREATEDAT + 978307200, 'unixepoch', 'localtime') IN (SELECT day FROM streak)
        ) FROM streak;
        """), expectedCount: 4)
    let bestDay = try split(database.text("""
        SELECT date(ZCREATEDAT + 978307200, 'unixepoch', 'localtime') || '|' || COUNT(*)
        FROM ZCONTENTITEM WHERE ZTYPE = 4
        GROUP BY date(ZCREATEDAT + 978307200, 'unixepoch', 'localtime')
        ORDER BY COUNT(*) DESC LIMIT 1;
        """), expectedCount: 2)
    let streaksCTE = """
        WITH daily AS (
          SELECT date(ZCREATEDAT + 978307200, 'unixepoch', 'localtime') AS day,
                 COUNT(*) AS feedback_count
          FROM ZCONTENTITEM WHERE ZTYPE = 4
          GROUP BY day
        ), numbered AS (
          SELECT day, feedback_count,
                 julianday(day) - ROW_NUMBER() OVER (ORDER BY day) AS grp
          FROM daily
        ), streaks AS (
          SELECT MIN(day) AS start_day, MAX(day) AS end_day,
                 COUNT(*) AS day_count, SUM(feedback_count) AS feedback_count
          FROM numbered GROUP BY grp
        )
        """
    let bestDurationStreak = try split(database.text(streaksCTE + """
        SELECT start_day || '|' || end_day || '|' || day_count || '|' || feedback_count
        FROM streaks
        ORDER BY day_count DESC, feedback_count DESC, end_day DESC
        LIMIT 1;
        """), expectedCount: 4)
    let bestVolumeStreak = try split(database.text(streaksCTE + """
        SELECT start_day || '|' || end_day || '|' || day_count || '|' || feedback_count
        FROM streaks
        ORDER BY feedback_count DESC, day_count DESC, end_day DESC
        LIMIT 1;
        """), expectedCount: 4)

    var statsLines: [String] = []
    statsLines.append(countHeader("Summary"))
    statsLines.append(countRow("Total", counts: summaryCounts))

    statsLines.append("")
    let categoryLabelWidth = max(unspecifiedPlatforms.isEmpty ? 18 : 20,
                                 categories.map { $0.name.count + 2 }.max() ?? 18)
    statsLines.append(countHeader("Top categories", labelWidth: categoryLabelWidth))
    for category in categories {
        statsLines.append(countRow(
            category.name,
            counts: Counts(open: category.open, closed: category.closed),
            labelWidth: categoryLabelWidth
        ))
        let categoryPlatforms = platformCounts[category.name, default: [:]]
        let sortedPlatforms = categoryPlatforms
            .filter({ $0.value.total > 0 })
            .sorted(by: {
                $0.value.total == $1.value.total
                    ? $0.key.rawValue < $1.key.rawValue
                    : $0.value.total > $1.value.total
            })
        let unknownItems = unknown[category.name, default: []]
        let unspecifiedCounts = unspecifiedPlatforms[category.name, default: Counts()]
        let showsUnknown = !unknownItems.isEmpty
        let showsUnspecified = (!categoryPlatforms.isEmpty || showsUnknown) && unspecifiedCounts.total > 0
        let childCount = sortedPlatforms.count + (showsUnknown ? 1 : 0) + (showsUnspecified ? 1 : 0)

        for (index, entry) in sortedPlatforms.enumerated() {
            let connector = index == childCount - 1 ? "└─" : "├─"
            statsLines.append(countRow(
                "\(connector) \(entry.key.rawValue)",
                counts: entry.value,
                indent: 4,
                labelWidth: categoryLabelWidth
            ))
        }
        if showsUnspecified {
            let connector = showsUnknown ? "├─" : "└─"
            statsLines.append(countRow("\(connector) Unspecified", counts: unspecifiedCounts,
                                       indent: 4, labelWidth: categoryLabelWidth))
        }
        if showsUnknown {
            var unknownCounts = Counts()
            unknownItems.forEach { unknownCounts.add(isClosed: $0.isClosed) }
            statsLines.append(countRow("└─ Unknown*", counts: unknownCounts, indent: 4, labelWidth: categoryLabelWidth))
            for item in unknownItems where item.remoteID > 0 {
                recordMissingField("platform", remoteID: item.remoteID, stub: item.stub)
            }
        }
    }

    statsLines.append("")
    let typeLabelWidth = max(18, feedbackTypes.keys.map { $0.count + 4 }.max() ?? 18)
    statsLines.append(countHeader("By type", labelWidth: typeLabelWidth))
    for type in ["Bug", "Suggestion", "Other", "Unspecified", "Unknown"] {
        if let counts = feedbackTypes[type], counts.total > 0 {
            statsLines.append(countRow(type == "Unknown" ? "Unknown*" : type,
                                       counts: counts, labelWidth: typeLabelWidth))
        }
    }

    statsLines.append("")
    statsLines.append(countHeader("By year"))
    for (year, counts) in years {
        statsLines.append(countRow(year, counts: counts))
    }

    statsLines.append("")
    statsLines.append(activityHeader())
    statsLines.append(activityRow("Today", feedbackCount: "\(today)", date: todayDate))
    statsLines.append(activityRow("Best day", feedbackCount: bestDay[1], date: bestDay[0]))

    statsLines.append("")
    statsLines.append(streakHeader())
    statsLines.append(streakRow(
        "Current",
        days: currentStreak[2],
        feedbackCount: currentStreak[3],
        start: currentStreak[0],
        end: currentStreak[1]
    ))
    statsLines.append(streakRow(
        "Best duration",
        days: bestDurationStreak[2],
        feedbackCount: bestDurationStreak[3],
        start: bestDurationStreak[0],
        end: bestDurationStreak[1]
    ))
    statsLines.append(streakRow(
        "Best volume",
        days: bestVolumeStreak[2],
        feedbackCount: bestVolumeStreak[3],
        start: bestVolumeStreak[0],
        end: bestVolumeStreak[1]
    ))

    if showsMissing {
        if missingMetadata.isEmpty && cachedMetadataIssues.isEmpty {
            print("No missing report details.")
            return
        }
        if !missingMetadata.isEmpty {
            print(section("Reports with uncached details · \(missingMetadata.count)"))
            print("  Open reports in Feedback Assistant while online to populate these fields.")
            print("")
            for remoteID in missingMetadata.keys.sorted(by: >) {
                let fields = missingMetadata[remoteID, default: []].sorted().joined(separator: ", ")
                print("  FB\(remoteID)  ·  \(fields)")
            }
        }
        if !cachedMetadataIssues.isEmpty {
            if !missingMetadata.isEmpty { print("") }
            print(section("Unreadable cached details · \(cachedMetadataIssues.count)"))
            for remoteID in cachedMetadataIssues.keys.sorted(by: >) {
                let reasons = cachedMetadataIssues[remoteID, default: []].sorted().joined(separator: "; ")
                print("  FB\(remoteID)  ·  \(reasons)")
            }
        }
    } else {
        printDashboard(statsLines)
        if !missingMetadata.isEmpty || !cachedMetadataIssues.isEmpty {
            print("")
            if !missingMetadata.isEmpty {
                print("* \(missingMetadata.count) reports have details that aren’t cached locally.")
                print("  Open reports in Feedback Assistant while online to populate them.")
            }
            if !cachedMetadataIssues.isEmpty {
                print("\(missingMetadata.isEmpty ? "*" : " ") \(cachedMetadataIssues.count) reports have cached details fbc couldn’t recognize.")
            }
            print("  Run fbc --missing to list affected reports.")
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fbc: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
