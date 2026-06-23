import Cocoa
import Foundation
import SQLite3
import Carbon.HIToolbox
import AVFoundation
import Speech
import UniformTypeIdentifiers
import Network

struct TokenUsage: Codable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheReadInputTokens: Int

    static let zero = TokenUsage(inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0)

    var total: Int {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    var completenessScore: Int {
        [inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens].filter { $0 > 0 }.count
    }

    mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheCreationInputTokens += other.cacheCreationInputTokens
        cacheReadInputTokens += other.cacheReadInputTokens
    }

    func subtracting(_ previous: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: max(inputTokens - previous.inputTokens, 0),
            outputTokens: max(outputTokens - previous.outputTokens, 0),
            cacheCreationInputTokens: max(cacheCreationInputTokens - previous.cacheCreationInputTokens, 0),
            cacheReadInputTokens: max(cacheReadInputTokens - previous.cacheReadInputTokens, 0)
        )
    }
}

struct UsageRecord: Codable {
    let source: String
    let timestamp: Date
    let projectPath: String
    let model: String
    let sessionId: String
    let requestId: String
    let messageId: String
    let sourceFile: String
    let usage: TokenUsage
}

struct SourceFileSnapshot {
    let path: String
    let size: Int64
    let modifiedAt: Double
}

struct SummaryRow {
    let name: String
    let usage: TokenUsage
    var cost: Double = 0
}

final class UsageCache {
    private static let schemaVersion = 5
    private var db: OpaquePointer?
    private let dbURL: URL

    init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AI工具助手", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        self.dbURL = supportURL.appendingPathComponent("usage-cache.sqlite")

        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            execute("PRAGMA journal_mode = WAL")
            execute("PRAGMA synchronous = NORMAL")
            createTables()
            migrateIfNeeded()
        }
    }

    deinit {
        sqlite3_close(db)
    }

    var path: String {
        dbURL.path
    }

    var isAvailable: Bool {
        db != nil
    }

    func replaceChangedFiles(_ changedFiles: [URL], allFiles: [SourceFileSnapshot], parser: (URL) -> [UsageRecord]) {
        guard db != nil else { return }

        let currentPaths = Set(allFiles.map(\.path))
        let cachedPaths = Set(loadSourceFiles().keys)
        let removedPaths = cachedPaths.subtracting(currentPaths)

        beginTransaction()
        for path in removedPaths {
            deleteSourceFile(path)
        }

        for fileURL in changedFiles {
            deleteSourceFile(fileURL.path)
            for record in parser(fileURL) {
                upsert(record)
            }
        }

        for snapshot in allFiles {
            upsert(snapshot)
        }
        commitTransaction()
    }

    func loadRecords() -> [UsageRecord] {
        var records: [UsageRecord] = []
        let sql = """
        SELECT timestamp, project_path, model, session_id, request_id, message_id, source_file,
               source, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens
        FROM usage_records
        ORDER BY timestamp ASC
        """

        query(sql) { statement in
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let record = UsageRecord(
                source: stringColumn(statement, 7),
                timestamp: timestamp,
                projectPath: stringColumn(statement, 1),
                model: stringColumn(statement, 2),
                sessionId: stringColumn(statement, 3),
                requestId: stringColumn(statement, 4),
                messageId: stringColumn(statement, 5),
                sourceFile: stringColumn(statement, 6),
                usage: TokenUsage(
                    inputTokens: Int(sqlite3_column_int64(statement, 8)),
                    outputTokens: Int(sqlite3_column_int64(statement, 9)),
                    cacheCreationInputTokens: Int(sqlite3_column_int64(statement, 10)),
                    cacheReadInputTokens: Int(sqlite3_column_int64(statement, 11))
                )
            )
            records.append(record)
        }

        return records
    }

    func loadSourceFiles() -> [String: SourceFileSnapshot] {
        var files: [String: SourceFileSnapshot] = [:]
        query("SELECT path, size, modified_at FROM source_files") { statement in
            let path = stringColumn(statement, 0)
            files[path] = SourceFileSnapshot(
                path: path,
                size: sqlite3_column_int64(statement, 1),
                modifiedAt: sqlite3_column_double(statement, 2)
            )
        }
        return files
    }

    func loadSourceFilesWithRecords(since date: Date) -> Set<String> {
        var paths = Set<String>()
        let sql = "SELECT DISTINCT source_file FROM usage_records WHERE timestamp >= ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return paths }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        while sqlite3_step(statement) == SQLITE_ROW {
            paths.insert(stringColumn(statement, 0))
        }

        return paths
    }

    private func createTables() {
        execute("""
        CREATE TABLE IF NOT EXISTS cache_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """)

        execute("""
        CREATE TABLE IF NOT EXISTS source_files (
            path TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            scanned_at REAL NOT NULL
        )
        """)

        execute("""
        CREATE TABLE IF NOT EXISTS usage_records (
            dedupe_key TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            project_path TEXT NOT NULL,
            model TEXT NOT NULL,
            session_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            source_file TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'Claude',
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_creation_input_tokens INTEGER NOT NULL,
            cache_read_input_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            completeness_score INTEGER NOT NULL
        )
        """)

        execute("CREATE INDEX IF NOT EXISTS idx_usage_source_file ON usage_records(source_file)")
        execute("CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_records(timestamp)")
        execute("CREATE INDEX IF NOT EXISTS idx_usage_source ON usage_records(source)")
    }

    private func migrateIfNeeded() {
        let current = metaValue("schema_version").flatMap(Int.init) ?? 0
        guard current != UsageCache.schemaVersion else { return }

        if current > 0 && current < 3 {
            execute("ALTER TABLE usage_records ADD COLUMN source TEXT NOT NULL DEFAULT 'Claude'")
        }

        execute("DELETE FROM usage_records")
        execute("DELETE FROM source_files")
        setMetaValue(String(UsageCache.schemaVersion), for: "schema_version")
    }

    private func metaValue(_ key: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM cache_meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return stringColumn(statement, 0)
    }

    private func setMetaValue(_ value: String, for key: String) {
        bindAndRun("""
        INSERT INTO cache_meta(key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [key, value])
    }

    private func deleteSourceFile(_ path: String) {
        bindAndRun("DELETE FROM usage_records WHERE source_file = ?", [path])
        bindAndRun("DELETE FROM source_files WHERE path = ?", [path])
    }

    private func upsert(_ snapshot: SourceFileSnapshot) {
        bindAndRun("""
        INSERT INTO source_files(path, size, modified_at, scanned_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            size = excluded.size,
            modified_at = excluded.modified_at,
            scanned_at = excluded.scanned_at
        """, [snapshot.path, snapshot.size, snapshot.modifiedAt, Date().timeIntervalSince1970])
    }

    private func upsert(_ record: UsageRecord) {
        let dedupeKey = UsageCache.dedupeKey(for: record)
        bindAndRun("""
        INSERT INTO usage_records(
            dedupe_key, timestamp, project_path, model, session_id, request_id, message_id, source_file, source,
            input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens,
            total_tokens, completeness_score
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(dedupe_key) DO UPDATE SET
            timestamp = excluded.timestamp,
            project_path = excluded.project_path,
            model = excluded.model,
            session_id = excluded.session_id,
            request_id = excluded.request_id,
            message_id = excluded.message_id,
            source_file = excluded.source_file,
            source = excluded.source,
            input_tokens = excluded.input_tokens,
            output_tokens = excluded.output_tokens,
            cache_creation_input_tokens = excluded.cache_creation_input_tokens,
            cache_read_input_tokens = excluded.cache_read_input_tokens,
            total_tokens = excluded.total_tokens,
            completeness_score = excluded.completeness_score
        WHERE excluded.completeness_score > usage_records.completeness_score
           OR (excluded.completeness_score = usage_records.completeness_score AND excluded.total_tokens > usage_records.total_tokens)
        """, [
            dedupeKey,
            record.timestamp.timeIntervalSince1970,
            record.projectPath,
            record.model,
            record.sessionId,
            record.requestId,
            record.messageId,
            record.sourceFile,
            record.source,
            record.usage.inputTokens,
            record.usage.outputTokens,
            record.usage.cacheCreationInputTokens,
            record.usage.cacheReadInputTokens,
            record.usage.total,
            record.usage.completenessScore
        ])
    }

    private func beginTransaction() {
        execute("BEGIN IMMEDIATE TRANSACTION")
    }

    private func commitTransaction() {
        execute("COMMIT")
    }

    private func execute(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func query(_ sql: String, row: (OpaquePointer?) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    private func bindAndRun(_ sql: String, _ values: [Any]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let sqliteIndex = Int32(index + 1)
            if let string = value as? String {
                sqlite3_bind_text(statement, sqliteIndex, string, -1, SQLITE_TRANSIENT)
            } else if let int = value as? Int {
                sqlite3_bind_int64(statement, sqliteIndex, sqlite3_int64(int))
            } else if let int64 = value as? Int64 {
                sqlite3_bind_int64(statement, sqliteIndex, sqlite3_int64(int64))
            } else if let double = value as? Double {
                sqlite3_bind_double(statement, sqliteIndex, double)
            } else {
                sqlite3_bind_null(statement, sqliteIndex)
            }
        }

        sqlite3_step(statement)
    }

    private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private static func dedupeKey(for record: UsageRecord) -> String {
        makeDedupeKey(for: record)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func formatExactNumber(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func formatCompactNumber(_ value: Int) -> String {
    var scaled = Double(value)
    let units = ["", "K", "M", "B", "T"]
    var unitIndex = 0

    while abs(scaled) >= 1000 && unitIndex < units.count - 1 {
        scaled /= 1000
        unitIndex += 1
    }

    if unitIndex == 0 {
        return formatExactNumber(value)
    }

    let decimals: Int
    if abs(scaled) >= 100 {
        decimals = 0
    } else if abs(scaled) >= 10 {
        decimals = 1
    } else {
        decimals = 2
    }

    return String(format: "%.\(decimals)f%@", scaled, units[unitIndex])
}

func makeDedupeKey(for record: UsageRecord) -> String {
    let usage = usageSignature(record.usage)

    if !record.messageId.isEmpty {
        let requestPart = record.requestId.isEmpty ? "no-request" : record.requestId
        return [record.source, "message", requestPart, record.messageId].joined(separator: "|")
    }

    if !record.requestId.isEmpty {
        return [record.source, "request-usage", record.requestId, usage].joined(separator: "|")
    }

    return [
        record.source,
        "fallback",
        record.sourceFile,
        record.sessionId,
        record.model,
        String(record.timestamp.timeIntervalSince1970),
        usage
    ].joined(separator: "|")
}

func usageSignature(_ usage: TokenUsage) -> String {
    [
        String(usage.inputTokens),
        String(usage.outputTokens),
        String(usage.cacheCreationInputTokens),
        String(usage.cacheReadInputTokens)
    ].joined(separator: ",")
}

// 成本估算：定价（USD / 百万 token）可在 pricing.json 中编辑覆盖，缺失时用内置默认
struct ModelPrice: Codable {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double
}

// 一条定价规则：模型名（小写）包含 match 子串即命中，按数组顺序优先匹配
struct PricingRule: Codable {
    let match: String
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double
    var price: ModelPrice { ModelPrice(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead) }
}

struct PricingConfig: Codable {
    let rules: [PricingRule]
    let fallback: ModelPrice
}

// 内置默认定价（注意 "gemini" 含子串 "mini"，故只匹配 "4o-mini"；顺序即匹配优先级）
let defaultPricingConfig = PricingConfig(
    rules: [
        PricingRule(match: "opus", input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5),
        PricingRule(match: "sonnet", input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3),
        PricingRule(match: "haiku", input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1),
        PricingRule(match: "4o-mini", input: 0.15, output: 0.6, cacheWrite: 0, cacheRead: 0.075),
        PricingRule(match: "4o", input: 2.5, output: 10, cacheWrite: 0, cacheRead: 1.25),
        PricingRule(match: "gpt-4.1", input: 2, output: 8, cacheWrite: 0, cacheRead: 0.5),
        PricingRule(match: "o3", input: 2, output: 8, cacheWrite: 0, cacheRead: 0.5),
        PricingRule(match: "o1", input: 15, output: 60, cacheWrite: 0, cacheRead: 7.5),
        PricingRule(match: "codex", input: 1.25, output: 10, cacheWrite: 0, cacheRead: 0.125),
        PricingRule(match: "gpt-5", input: 1.25, output: 10, cacheWrite: 0, cacheRead: 0.125),
        PricingRule(match: "gpt", input: 2.5, output: 10, cacheWrite: 0, cacheRead: 1.25),
        PricingRule(match: "2.5-pro", input: 1.25, output: 10, cacheWrite: 0, cacheRead: 0.31),
        PricingRule(match: "flash", input: 0.3, output: 2.5, cacheWrite: 0, cacheRead: 0.075),
        PricingRule(match: "gemini", input: 0.3, output: 2.5, cacheWrite: 0, cacheRead: 0.075)
    ],
    fallback: ModelPrice(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
)

// 当前生效定价（启动时由 loadPricing() 从 pricing.json 加载，否则为默认）
var activePricing: PricingConfig = defaultPricingConfig

// 一次性迁移：把旧「AI 用量统计」数据目录改名为「AI工具助手」，保留缓存与 pricing.json
func migrateSupportDirIfNeeded() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let old = base.appendingPathComponent("AI 用量统计", isDirectory: true)
    let new = base.appendingPathComponent("AI工具助手", isDirectory: true)
    if FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: new.path) {
        try? FileManager.default.moveItem(at: old, to: new)
    }
}

func appSupportDirURL() -> URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("AI工具助手", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func pricingConfigURL() -> URL {
    appSupportDirURL().appendingPathComponent("pricing.json")
}

// MARK: - 项目管理数据模型与持久化

struct ProjectPrompt: Codable {
    var id: String = UUID().uuidString
    var text: String
    var favorite: Bool = false
}

struct Project: Codable {
    var id: String = UUID().uuidString
    var name: String
    var background: String = ""   // 项目背景信息
    var materials: String = ""    // 项目资料
    var prompts: [ProjectPrompt] = []
}

// 项目库：SQLite 持久化于 ~/Library/Application Support/AI工具助手/projects.sqlite
// （与用量缓存一致用 sqlite3；公开 API 不变，便于后续 SQL 搜索历史提示词复用）
final class ProjectStore {
    static let shared = ProjectStore()
    private(set) var projects: [Project] = []
    private var db: OpaquePointer?

    init() {
        let dbURL = appSupportDirURL().appendingPathComponent("projects.sqlite")
        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            exec("PRAGMA journal_mode = WAL")
            exec("CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, background TEXT NOT NULL DEFAULT '', materials TEXT NOT NULL DEFAULT '', sort_order INTEGER NOT NULL DEFAULT 0)")
            exec("CREATE TABLE IF NOT EXISTS prompts (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, text TEXT NOT NULL, favorite INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0)")
            exec("CREATE INDEX IF NOT EXISTS idx_prompts_project ON prompts(project_id)")
            importJSONIfNeeded()
        }
        load()
    }

    deinit { sqlite3_close(db) }

    func load() {
        var result: [Project] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, name, background, materials FROM projects ORDER BY sort_order ASC, name ASC", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                var project = Project(name: col(stmt, 1))
                project.id = col(stmt, 0)
                project.background = col(stmt, 2)
                project.materials = col(stmt, 3)
                result.append(project)
            }
        }
        sqlite3_finalize(stmt)

        for index in result.indices {
            result[index].prompts = loadPrompts(projectId: result[index].id)
        }
        projects = result
    }

    private func loadPrompts(projectId: String) -> [ProjectPrompt] {
        var prompts: [ProjectPrompt] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, text, favorite FROM prompts WHERE project_id = ? ORDER BY sort_order ASC", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, projectId, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var prompt = ProjectPrompt(text: col(stmt, 1))
                prompt.id = col(stmt, 0)
                prompt.favorite = sqlite3_column_int64(stmt, 2) != 0
                prompts.append(prompt)
            }
        }
        sqlite3_finalize(stmt)
        return prompts
    }

    @discardableResult
    func addProject(name: String) -> Project {
        let project = Project(name: name)
        run("INSERT INTO projects (id, name, background, materials, sort_order) VALUES (?,?,?,?,?)",
            [project.id, project.name, project.background, project.materials, projects.count])
        load()
        return project
    }

    func update(_ project: Project) {
        run("UPDATE projects SET name=?, background=?, materials=? WHERE id=?",
            [project.name, project.background, project.materials, project.id])
        run("DELETE FROM prompts WHERE project_id=?", [project.id])
        for (index, prompt) in project.prompts.enumerated() {
            run("INSERT INTO prompts (id, project_id, text, favorite, sort_order) VALUES (?,?,?,?,?)",
                [prompt.id, project.id, prompt.text, prompt.favorite ? 1 : 0, index])
        }
        load()
    }

    func delete(id: String) {
        run("DELETE FROM prompts WHERE project_id=?", [id])
        run("DELETE FROM projects WHERE id=?", [id])
        load()
    }

    // 复制项目（连同背景/资料/提示词，分配新 UUID），返回新项目
    @discardableResult
    func duplicate(id: String) -> Project? {
        guard let src = project(id: id) else { return nil }
        let newId = UUID().uuidString
        run("INSERT INTO projects (id, name, background, materials, sort_order) VALUES (?,?,?,?,?)",
            [newId, src.name + " 副本", src.background, src.materials, projects.count])
        for (i, prompt) in src.prompts.enumerated() {
            run("INSERT INTO prompts (id, project_id, text, favorite, sort_order) VALUES (?,?,?,?,?)",
                [UUID().uuidString, newId, prompt.text, prompt.favorite ? 1 : 0, i])
        }
        load()
        return project(id: newId)
    }

    func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    // 导出全部项目为 JSON（Project Codable，含提示词）
    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try? encoder.encode(projects)
    }

    // 从 JSON 导入项目（追加，分配新 id 避免覆盖现有），返回导入数量
    // 兼容 [Project] 数组与单个 Project 对象两种格式
    @discardableResult
    func importJSON(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        var list: [Project] = []
        if let arr = try? decoder.decode([Project].self, from: data) {
            list = arr
        } else if let single = try? decoder.decode(Project.self, from: data) {
            list = [single]
        }
        // 过滤名称为空的无效项
        list = list.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !list.isEmpty else { return 0 }
        let base = projects.count
        for (pi, project) in list.enumerated() {
            let newId = UUID().uuidString
            run("INSERT INTO projects (id, name, background, materials, sort_order) VALUES (?,?,?,?,?)",
                [newId, project.name, project.background, project.materials, base + pi])
            for (qi, prompt) in project.prompts.enumerated() {
                run("INSERT INTO prompts (id, project_id, text, favorite, sort_order) VALUES (?,?,?,?,?)",
                    [UUID().uuidString, newId, prompt.text, prompt.favorite ? 1 : 0, qi])
            }
        }
        load()
        return list.count
    }

    // 跨项目搜索提示词（SQL LIKE，供"查找历史提示词复用"）
    func searchPrompts(_ query: String) -> [(projectName: String, prompt: ProjectPrompt)] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        var results: [(String, ProjectPrompt)] = []
        var stmt: OpaquePointer?
        let sql = "SELECT pr.id, pr.text, pr.favorite, pj.name FROM prompts pr JOIN projects pj ON pr.project_id = pj.id WHERE pr.text LIKE ? ORDER BY pr.favorite DESC LIMIT 200"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, "%\(keyword)%", -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var prompt = ProjectPrompt(text: col(stmt, 1))
                prompt.id = col(stmt, 0)
                prompt.favorite = sqlite3_column_int64(stmt, 2) != 0
                results.append((col(stmt, 3), prompt))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    // MARK: - sqlite helpers

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func col(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func run(_ sql: String, _ values: [Any]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            if let s = value as? String {
                sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT)
            } else if let n = value as? Int {
                sqlite3_bind_int64(stmt, i, sqlite3_int64(n))
            } else {
                sqlite3_bind_null(stmt, i)
            }
        }
        sqlite3_step(stmt)
    }

    // 旧 JSON 数据一次性迁移到 SQLite（仅当表为空且存在 projects.json）
    private func importJSONIfNeeded() {
        let jsonURL = appSupportDirURL().appendingPathComponent("projects.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return }
        var count = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM projects", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)
        guard count == 0,
              let data = try? Data(contentsOf: jsonURL),
              let list = try? JSONDecoder().decode([Project].self, from: data) else { return }
        for (pi, project) in list.enumerated() {
            run("INSERT OR REPLACE INTO projects (id, name, background, materials, sort_order) VALUES (?,?,?,?,?)",
                [project.id, project.name, project.background, project.materials, pi])
            for (qi, prompt) in project.prompts.enumerated() {
                run("INSERT OR REPLACE INTO prompts (id, project_id, text, favorite, sort_order) VALUES (?,?,?,?,?)",
                    [prompt.id, project.id, prompt.text, prompt.favorite ? 1 : 0, qi])
            }
        }
        try? FileManager.default.moveItem(at: jsonURL, to: jsonURL.appendingPathExtension("imported"))
    }
}

func writeDefaultPricingTemplate() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let data = try? encoder.encode(defaultPricingConfig) {
        try? data.write(to: pricingConfigURL())
    }
}

// 读取 pricing.json 覆盖定价；文件不存在则写出默认模板供编辑
@discardableResult
func loadPricing() -> Bool {
    let url = pricingConfigURL()
    if let data = try? Data(contentsOf: url),
       let config = try? JSONDecoder().decode(PricingConfig.self, from: data) {
        activePricing = config
        return true
    }
    activePricing = defaultPricingConfig
    if !FileManager.default.fileExists(atPath: url.path) {
        writeDefaultPricingTemplate()
    }
    return false
}

func modelPrice(for model: String) -> ModelPrice {
    let m = model.lowercased()
    for rule in activePricing.rules where !rule.match.isEmpty && m.contains(rule.match.lowercased()) {
        return rule.price
    }
    return activePricing.fallback
}

func estimatedCostUSD(_ usage: TokenUsage, model: String) -> Double {
    let pr = modelPrice(for: model)
    return Double(usage.inputTokens) / 1_000_000 * pr.input
        + Double(usage.outputTokens) / 1_000_000 * pr.output
        + Double(usage.cacheCreationInputTokens) / 1_000_000 * pr.cacheWrite
        + Double(usage.cacheReadInputTokens) / 1_000_000 * pr.cacheRead
}

enum DateScope: Int {
    case today = 0
    case week = 1
    case month = 2
    case all = 3
}

enum Grouping: Int {
    case date = 0
    case project = 1
    case model = 2
    case session = 3
    case source = 4
}

enum SourceScope: Int {
    case all = 0
    case claude = 1
    case codex = 2
    case gemini = 3
    case openCode = 4
}

final class ClaudeUsageScanner {
    private let claudeRootURL: URL
    private let codexRootURL: URL
    private let geminiRootURL: URL
    private let openCodeStorageURL: URL
    private let cache: UsageCache
    private let decoderFormatter: ISO8601DateFormatter
    private let dayFormatter: DateFormatter

    init(
        claudeRootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
        codexRootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        geminiRootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp"),
        openCodeStorageURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/storage")
    ) {
        self.claudeRootURL = claudeRootURL
        self.codexRootURL = codexRootURL
        self.geminiRootURL = geminiRootURL
        self.openCodeStorageURL = openCodeStorageURL
        self.cache = UsageCache()
        self.decoderFormatter = ISO8601DateFormatter()
        self.decoderFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dayFormatter = DateFormatter()
        self.dayFormatter.calendar = Calendar(identifier: .gregorian)
        self.dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    var cachePath: String {
        cache.path
    }

    func scan(forceRefresh: Bool = false) -> [UsageRecord] {
        guard cache.isAvailable else {
            return fullScanWithoutCache()
        }

        let snapshots = listJSONLFiles()
        let cachedFiles = forceRefresh ? [:] : cache.loadSourceFiles()
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayTimestamp = todayStart.timeIntervalSince1970
        let filesWithTodayRecords = forceRefresh ? Set<String>() : cache.loadSourceFilesWithRecords(since: todayStart)
        let changedFiles = snapshots.compactMap { snapshot -> URL? in
            guard !forceRefresh, let cached = cachedFiles[snapshot.path] else {
                return URL(fileURLWithPath: snapshot.path)
            }

            if filesWithTodayRecords.contains(snapshot.path) || snapshot.modifiedAt >= todayTimestamp {
                return URL(fileURLWithPath: snapshot.path)
            }

            if cached.size != snapshot.size || cached.modifiedAt != snapshot.modifiedAt {
                return URL(fileURLWithPath: snapshot.path)
            }

            return nil
        }

        cache.replaceChangedFiles(changedFiles, allFiles: snapshots) { fileURL in
            self.parseFile(fileURL)
        }

        return cache.loadRecords()
    }

    func fullScanWithoutCache() -> [UsageRecord] {
        let records = listJSONLFiles().flatMap { parseFile(URL(fileURLWithPath: $0.path)) }
        var bestByKey: [String: UsageRecord] = [:]
        for record in records {
            let key = dedupeKey(for: record)
            if let existing = bestByKey[key] {
                if isMoreComplete(record, than: existing) {
                    bestByKey[key] = record
                }
            } else {
                bestByKey[key] = record
            }
        }
        return bestByKey.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func fullClaudeScanWithoutCache() -> [UsageRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: claudeRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var bestByKey: [String: UsageRecord] = [:]

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            content.enumerateLines { line, _ in
                guard let record = self.parseLine(line, sourceFile: fileURL.path) else { return }
                let key = self.dedupeKey(for: record)

                if let existing = bestByKey[key] {
                    if self.isMoreComplete(record, than: existing) {
                        bestByKey[key] = record
                    }
                } else {
                    bestByKey[key] = record
                }
            }
        }

        return bestByKey.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func listJSONLFiles() -> [SourceFileSnapshot] {
        listJSONLFiles(in: claudeRootURL) + listJSONLFiles(in: codexRootURL) + listGeminiFiles() + listOpenCodeMessageFiles()
    }

    private func listJSONLFiles(in rootURL: URL) -> [SourceFileSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var snapshots: [SourceFileSnapshot] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            snapshots.append(SourceFileSnapshot(
                path: fileURL.path,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }

        return snapshots
    }

    private func listGeminiFiles() -> [SourceFileSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: geminiRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var snapshots: [SourceFileSnapshot] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "json",
                  fileURL.path.contains("/chats/session-") else {
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            snapshots.append(SourceFileSnapshot(
                path: fileURL.path,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }

        return snapshots
    }

    private func listOpenCodeMessageFiles() -> [SourceFileSnapshot] {
        let messageURL = openCodeStorageURL.appendingPathComponent("message", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: messageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var snapshots: [SourceFileSnapshot] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "json" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            snapshots.append(SourceFileSnapshot(
                path: fileURL.path,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }

        return snapshots
    }

    private func parseFile(_ fileURL: URL) -> [UsageRecord] {
        if fileURL.path.hasPrefix(openCodeStorageURL.appendingPathComponent("message", isDirectory: true).path) {
            return parseOpenCodeMessageFile(fileURL)
        }

        if fileURL.path.hasPrefix(geminiRootURL.path) {
            return parseGeminiFile(fileURL)
        }

        if fileURL.path.hasPrefix(codexRootURL.path) {
            return parseCodexFile(fileURL)
        }

        return parseClaudeFile(fileURL)
    }

    private func parseClaudeFile(_ fileURL: URL) -> [UsageRecord] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }

        var bestByKey: [String: UsageRecord] = [:]
        content.enumerateLines { line, _ in
            guard let record = self.parseLine(line, sourceFile: fileURL.path) else { return }
            let key = self.dedupeKey(for: record)

            if let existing = bestByKey[key] {
                if self.isMoreComplete(record, than: existing) {
                    bestByKey[key] = record
                }
            } else {
                bestByKey[key] = record
            }
        }

        return Array(bestByKey.values)
    }

    private func parseCodexFile(_ fileURL: URL) -> [UsageRecord] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }

        var records: [UsageRecord] = []
        var currentProject = ""
        var currentModel = ""
        var previousTotal = TokenUsage.zero
        let sessionId = fileURL.deletingPathExtension().lastPathComponent

        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = self.parseDate(json["timestamp"] as? String ?? ""),
                  let type = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any] else {
                return
            }

            if type == "turn_context" {
                currentProject = payload["cwd"] as? String ?? currentProject
                currentModel = payload["model"] as? String ?? currentModel
                return
            }

            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsageJSON = info["total_token_usage"] as? [String: Any] else {
                return
            }

            let cumulative = self.parseCodexUsage(totalUsageJSON)
            let didReset = cumulative.inputTokens < previousTotal.inputTokens
                || cumulative.outputTokens < previousTotal.outputTokens
                || cumulative.cacheReadInputTokens < previousTotal.cacheReadInputTokens
            let delta = didReset ? cumulative : cumulative.subtracting(previousTotal)
            previousTotal = cumulative

            guard delta.total > 0 else { return }

            records.append(UsageRecord(
                source: "Codex",
                timestamp: timestamp,
                projectPath: currentProject,
                model: currentModel,
                sessionId: sessionId,
                requestId: "",
                messageId: "",
                sourceFile: fileURL.path,
                usage: delta
            ))
        }

        return records
    }

    private func parseGeminiFile(_ fileURL: URL) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return []
        }

        let sessionId = json["sessionId"] as? String ?? fileURL.deletingPathExtension().lastPathComponent
        let projectPath = json["projectHash"] as? String ?? ""

        return messages.compactMap { message -> UsageRecord? in
            guard let tokens = message["tokens"] as? [String: Any],
                  let timestamp = parseDate(message["timestamp"] as? String ?? "") else {
                return nil
            }

            let input = intValue(tokens["input"])
            let cached = intValue(tokens["cached"])
            let output = intValue(tokens["output"])
            let thoughts = intValue(tokens["thoughts"])
            let tool = intValue(tokens["tool"])
            let usage = TokenUsage(
                inputTokens: max(input - cached, 0),
                outputTokens: output + thoughts + tool,
                cacheCreationInputTokens: 0,
                cacheReadInputTokens: cached
            )

            guard usage.total > 0 else { return nil }

            return UsageRecord(
                source: "Gemini",
                timestamp: timestamp,
                projectPath: projectPath,
                model: message["model"] as? String ?? "",
                sessionId: sessionId,
                requestId: "",
                messageId: message["id"] as? String ?? "",
                sourceFile: fileURL.path,
                usage: usage
            )
        }
    }

    private func parseOpenCodeMessageFile(_ fileURL: URL) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["role"] as? String == "assistant",
              let tokens = json["tokens"] as? [String: Any] else {
            return []
        }

        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let usage = TokenUsage(
            inputTokens: intValue(tokens["input"]),
            outputTokens: intValue(tokens["output"]) + intValue(tokens["reasoning"]),
            cacheCreationInputTokens: intValue(cache["write"]),
            cacheReadInputTokens: intValue(cache["read"])
        )

        guard usage.total > 0 else { return [] }

        let timeJSON = json["time"] as? [String: Any] ?? [:]
        guard let timestamp = parseMillisecondsDate(timeJSON["completed"]) ?? parseMillisecondsDate(timeJSON["created"]) else {
            return []
        }

        let pathJSON = json["path"] as? [String: Any] ?? [:]
        let provider = json["providerID"] as? String ?? ""
        let model = json["modelID"] as? String ?? ""
        let modelName = provider.isEmpty ? model : "\(provider)/\(model)"

        return [UsageRecord(
            source: "OpenCode",
            timestamp: timestamp,
            projectPath: pathJSON["cwd"] as? String ?? pathJSON["root"] as? String ?? "",
            model: modelName,
            sessionId: json["sessionID"] as? String ?? fileURL.deletingLastPathComponent().lastPathComponent,
            requestId: "",
            messageId: json["id"] as? String ?? fileURL.deletingPathExtension().lastPathComponent,
            sourceFile: fileURL.path,
            usage: usage
        )]
    }

    func filter(_ records: [UsageRecord], scope: DateScope) -> [UsageRecord] {
        let calendar = Calendar.current
        let now = Date()

        return records.filter { record in
            switch scope {
            case .today:
                return calendar.isDate(record.timestamp, inSameDayAs: now)
            case .week:
                let todayStart = calendar.startOfDay(for: now)
                guard let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) else { return true }
                return record.timestamp >= weekStart
            case .month:
                let nowParts = calendar.dateComponents([.year, .month], from: now)
                let recordParts = calendar.dateComponents([.year, .month], from: record.timestamp)
                return nowParts.year == recordParts.year && nowParts.month == recordParts.month
            case .all:
                return true
            }
        }
    }

    func filter(_ records: [UsageRecord], sourceScope: SourceScope) -> [UsageRecord] {
        switch sourceScope {
        case .all:
            return records
        case .claude:
            return records.filter { $0.source == "Claude" }
        case .codex:
            return records.filter { $0.source == "Codex" }
        case .gemini:
            return records.filter { $0.source == "Gemini" }
        case .openCode:
            return records.filter { $0.source == "OpenCode" }
        }
    }

    func summarize(_ records: [UsageRecord], grouping: Grouping) -> [SummaryRow] {
        var buckets: [String: TokenUsage] = [:]
        var costs: [String: Double] = [:]

        for record in records {
            let key: String
            switch grouping {
            case .date:
                key = dayFormatter.string(from: record.timestamp)
            case .project:
                key = record.projectPath.isEmpty ? "(unknown project)" : record.projectPath
            case .model:
                key = record.model.isEmpty ? "(unknown model)" : record.model
            case .session:
                key = record.sessionId.isEmpty ? "(unknown session)" : record.sessionId
            case .source:
                key = record.source
            }

            var usage = buckets[key, default: .zero]
            usage.add(record.usage)
            buckets[key] = usage
            // 成本须按每条记录各自模型定价累加，混合模型分组才不失真
            costs[key, default: 0] += estimatedCostUSD(record.usage, model: record.model)
        }

        return buckets.map { SummaryRow(name: $0.key, usage: $0.value, cost: costs[$0.key] ?? 0) }
            .sorted {
                if $0.usage.total == $1.usage.total { return $0.name < $1.name }
                return $0.usage.total > $1.usage.total
            }
    }

    func total(_ records: [UsageRecord]) -> TokenUsage {
        records.reduce(into: TokenUsage.zero) { result, record in
            result.add(record.usage)
        }
    }

    private func parseLine(_ line: String, sourceFile: String) -> UsageRecord? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let usageJSON = message["usage"] as? [String: Any] else {
            return nil
        }

        if let type = json["type"] as? String, type != "assistant" {
            return nil
        }

        let usage = TokenUsage(
            inputTokens: intValue(usageJSON["input_tokens"]),
            outputTokens: intValue(usageJSON["output_tokens"]),
            cacheCreationInputTokens: intValue(usageJSON["cache_creation_input_tokens"]),
            cacheReadInputTokens: intValue(usageJSON["cache_read_input_tokens"])
        )

        guard usage.total > 0 else { return nil }

        let timestampString = json["timestamp"] as? String ?? ""
        guard let timestamp = parseDate(timestampString) else { return nil }

        return UsageRecord(
            source: "Claude",
            timestamp: timestamp,
            projectPath: json["cwd"] as? String ?? json["projectPath"] as? String ?? "",
            model: message["model"] as? String ?? json["model"] as? String ?? "",
            sessionId: json["sessionId"] as? String ?? "",
            requestId: json["requestId"] as? String ?? message["requestId"] as? String ?? "",
            messageId: message["id"] as? String ?? json["messageId"] as? String ?? "",
            sourceFile: sourceFile,
            usage: usage
        )
    }

    private func parseCodexUsage(_ json: [String: Any]) -> TokenUsage {
        let input = intValue(json["input_tokens"])
        let cachedInput = intValue(json["cached_input_tokens"])
        return TokenUsage(
            inputTokens: max(input - cachedInput, 0),
            outputTokens: intValue(json["output_tokens"]),
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: cachedInput
        )
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = decoderFormatter.date(from: value) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private func parseMillisecondsDate(_ value: Any?) -> Date? {
        let milliseconds = intValue(value)
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func dedupeKey(for record: UsageRecord) -> String {
        makeDedupeKey(for: record)
    }

    private func isMoreComplete(_ candidate: UsageRecord, than existing: UsageRecord) -> Bool {
        if candidate.usage.completenessScore != existing.usage.completenessScore {
            return candidate.usage.completenessScore > existing.usage.completenessScore
        }

        return candidate.usage.total > existing.usage.total
    }
}

// 来源占比堆叠条：按比例分段着色，随宽度自适应布局，段间留小间隙
final class StackedBarView: NSView {
    private var segments: [(color: NSColor, value: Double)] = []

    func setSegments(_ segments: [(color: NSColor, value: Double)]) {
        self.segments = segments
        needsLayout = true
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerRadius = bounds.height / 2
        layer?.masksToBounds = true
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let total = segments.reduce(0.0) { $0 + $1.value }
        guard total > 0 else {
            let empty = CALayer()
            empty.frame = bounds
            empty.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            layer?.addSublayer(empty)
            return
        }

        let gap: CGFloat = 2
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let width = CGFloat(segment.value / total) * bounds.width
            let drawWidth = isLast ? bounds.width - x : max(width - gap, 1)
            let sub = CALayer()
            sub.frame = CGRect(x: x, y: 0, width: drawWidth, height: bounds.height)
            sub.backgroundColor = segment.color.cgColor
            layer?.addSublayer(sub)
            x += width
        }
    }
}

// 近7天趋势迷你柱状图：归一化高度，末柱（今天）用强调色
final class TrendBarView: NSView, NSViewToolTipOwner {
    private var bars: [Double] = []
    private var tips: [String] = []   // 每根柱的悬停提示（日期 + 数值）
    var highlightColor: NSColor = .controlAccentColor
    var normalColor: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.32)

    func setBars(_ values: [Double], tips: [String] = []) {
        bars = values
        self.tips = tips
        needsLayout = true
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        removeAllToolTips()
        guard !bars.isEmpty, bounds.width > 0 else { return }

        let maxValue = max(bars.max() ?? 0, 1)
        let count = bars.count
        // 柱多时间隙更小，避免每根柱过细
        let gap: CGFloat = count > 14 ? 2 : 4
        let barWidth = max((bounds.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
        let minHeight: CGFloat = 3

        for (index, value) in bars.enumerated() {
            let height = max(CGFloat(value / maxValue) * bounds.height, minHeight)
            let x = CGFloat(index) * (barWidth + gap)
            let sub = CALayer()
            sub.frame = CGRect(x: x, y: 0, width: barWidth, height: height)
            sub.cornerRadius = min(barWidth / 2, 3)
            sub.cornerCurve = .continuous
            let isToday = index == count - 1
            sub.backgroundColor = (isToday ? highlightColor : normalColor).cgColor
            layer?.addSublayer(sub)
            // 整列(含柱上方空白)可悬停，提示该日数值
            if index < tips.count {
                let colRect = NSRect(x: x, y: 0, width: barWidth + gap, height: bounds.height)
                addToolTip(colRect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        let idx = (userData.map { Int(bitPattern: $0) } ?? 0) - 1
        return (idx >= 0 && idx < tips.count) ? tips[idx] : ""
    }
}

// 文件级玻璃面板助手（供版本管理窗口复用主界面同款液态玻璃风格）
// 可拉伸的圆角矩形遮罩图（9-part），用于裁剪 NSVisualEffectView 的材质到圆角，
// 且允许图层投影（masksToBounds=false 时阴影不被裁掉）。
func roundedMaskImage(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 2
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

// 把 SF Symbol 渲染成指定纯色的图（用 sourceAtop 仅给符号本身上色）
func tintedSymbolImage(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)) else { return nil }
    let img = NSImage(size: base.size)
    img.lockFocus()
    let rect = NSRect(origin: .zero, size: base.size)
    base.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}

// 「当前」实心胶囊徽标（tint 底 + 白色对勾 + 白字），版本管理/配置档案复用。
// 返回的 pill 已含内部约束；调用方负责加到父视图并约束 trailing/centerY。
func makeCurrentPill(tint: NSColor) -> NSView {
    let pill = NSView()
    pill.wantsLayer = true
    pill.layer?.backgroundColor = tint.cgColor
    pill.layer?.cornerRadius = 9
    pill.layer?.cornerCurve = .continuous
    pill.translatesAutoresizingMaskIntoConstraints = false
    let check = NSImageView()
    check.image = tintedSymbolImage("checkmark.circle.fill", color: .white, pointSize: 10)
    check.translatesAutoresizingMaskIntoConstraints = false
    let badgeLabel = NSTextField(labelWithString: "当前")
    badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
    badgeLabel.textColor = .white
    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
    pill.addSubview(check); pill.addSubview(badgeLabel)
    NSLayoutConstraint.activate([
        pill.heightAnchor.constraint(equalToConstant: 18),
        check.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
        check.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        check.widthAnchor.constraint(equalToConstant: 11),
        check.heightAnchor.constraint(equalToConstant: 11),
        badgeLabel.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 3),
        badgeLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
        badgeLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
    ])
    return pill
}

// 代码生成 app 图标：蓝→靛渐变圆角方 + 白色 sparkles，设为 NSApp.applicationIconImage（Dock/关于窗）
func makeAppIcon() -> NSImage {
    let side: CGFloat = 512
    let size = NSSize(width: side, height: side)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(x: 26, y: 26, width: side - 52, height: side - 52)
    let path = NSBezierPath(roundedRect: rect, xRadius: 112, yRadius: 112)
    if let gradient = NSGradient(colors: [NSColor.systemBlue, NSColor.systemIndigo]) {
        gradient.draw(in: path, angle: -90)
    } else {
        NSColor.systemBlue.setFill(); path.fill()
    }
    if let glyph = tintedSymbolImage("sparkles", color: .white, pointSize: 250) {
        let gw = glyph.size.width, gh = glyph.size.height
        glyph.draw(in: NSRect(x: (side - gw) / 2, y: (side - gh) / 2, width: gw, height: gh))
    }
    image.unlockFocus()
    return image
}

func makeGlassEffectView(radius: CGFloat, material: NSVisualEffectView.Material) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .withinWindow
    view.state = .active
    // 用 maskImage 把材质裁成圆角（而非 masksToBounds），从而图层仍可投影
    view.maskImage = roundedMaskImage(radius: radius)
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = false
    // App Store 卡片式极淡投影：在同材质背景上拉开层次，避免硬灰方框
    view.layer?.shadowColor = NSColor.black.cgColor
    view.layer?.shadowOpacity = 0.12
    view.layer?.shadowRadius = 7
    view.layer?.shadowOffset = CGSize(width: 0, height: -1)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

// 面板头部：强调色圆角图标徽标 + 标题，返回 (badge, titleLabel)。文件级复用（三个 cvm 模块共用）
@discardableResult
func makePanelHeader(title: String, symbol: String, tint: NSColor, in panel: NSView) -> (NSView, NSTextField) {
    let badge = NSView()
    badge.wantsLayer = true
    badge.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
    badge.layer?.cornerRadius = 7
    badge.layer?.cornerCurve = .continuous
    badge.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(badge)

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.contentTintColor = tint
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    icon.translatesAutoresizingMaskIntoConstraints = false
    badge.addSubview(icon)

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .labelColor
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(titleLabel)

    NSLayoutConstraint.activate([
        badge.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
        badge.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
        badge.widthAnchor.constraint(equalToConstant: 24),
        badge.heightAnchor.constraint(equalToConstant: 24),
        icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
        icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        titleLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 9)
    ])
    return (badge, titleLabel)
}

// 只读文本面板（玻璃 + 头部徽标 + 滚动文本视图）。文件级复用
func makeTextPanel(title: String, symbol: String, tint: NSColor) -> (NSView, NSTextView) {
    let panel = makeGlassEffectView(radius: 18, material: .contentBackground)
    let (badge, _) = makePanelHeader(title: title, symbol: symbol, tint: tint, in: panel)

    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.textContainerInset = NSSize(width: 8, height: 8)

    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(scroll)

    NSLayoutConstraint.activate([
        scroll.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 10),
        scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
        scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
        scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12)
    ])
    return (panel, textView)
}

// shell 单引号转义，安全嵌入用户输入（URL / api-key / 版本号等）
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// cvm 桥接：source ~/.cvm/cvm.sh 后执行子命令，返回去掉 ANSI 的输出
enum CVMRunner {
    // 串行队列：所有 cvm 调用顺序执行，杜绝并发 spawn bash 进程引发的内存竞态/崩溃
    static let queue = DispatchQueue(label: "ai-helper.cvm.runner", qos: .userInitiated)

    static var scriptPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".cvm/cvm.sh")
    }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: scriptPath)
    }

    static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*m") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // 同步执行（调用方应放后台队列）；command 例如 "cvm installed"
    static func run(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "source \"$HOME/.cvm/cvm.sh\" 2>/dev/null && \(command) 2>&1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return stripANSI(String(data: data, encoding: .utf8) ?? "")
        } catch {
            return "执行失败：\(error.localizedDescription)"
        }
    }
}

// cvm 未安装时的友好引导覆盖层（版本/配置/档案 三模块共用）
func makeCVMMissingOverlay(retry: @escaping () -> Void) -> NSView {
    let overlay = NSVisualEffectView()
    overlay.material = .windowBackground
    overlay.blendingMode = .behindWindow
    overlay.state = .active
    overlay.translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
    icon.contentTintColor = .tertiaryLabelColor
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
    icon.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: "未检测到 cvm")
    title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
    title.alignment = .center
    title.translatesAutoresizingMaskIntoConstraints = false

    let body = NSTextField(labelWithString: "版本管理 / 配置管理 / 配置档案 依赖 cvm（Claude Code & Codex CLI 版本管理器）。\n请先安装 cvm、确保 ~/.cvm/cvm.sh 存在，然后点「重试检测」。\n用量统计、项目管理、AI 工作台、语音输入 不依赖 cvm，可正常使用。")
    body.font = NSFont.systemFont(ofSize: 12)
    body.textColor = .secondaryLabelColor
    body.alignment = .center
    body.maximumNumberOfLines = 5
    body.translatesAutoresizingMaskIntoConstraints = false

    let retryButton = ClosureButton(title: "重试检测", symbol: "arrow.clockwise", tint: .controlAccentColor, onClick: retry)
    retryButton.controlSize = .large
    retryButton.translatesAutoresizingMaskIntoConstraints = false
    let pathButton = ClosureButton(title: "复制 cvm.sh 预期路径", symbol: "doc.on.doc", tint: .systemGray) {
        ClipboardStore.copy(CVMRunner.scriptPath)
    }
    pathButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [icon, title, body, retryButton, pathButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.setCustomSpacing(8, after: icon)
    stack.setCustomSpacing(18, after: body)
    stack.setCustomSpacing(8, after: retryButton)
    stack.translatesAutoresizingMaskIntoConstraints = false
    overlay.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24)
    ])
    return overlay
}

private let cvmOverlayID = NSUserInterfaceItemIdentifier("cvmMissingOverlay")

// 在模块视图上显示 cvm 缺失覆盖层（用 identifier 复用，免去各控制器加属性）
func showCVMMissingOverlay(in moduleView: NSView, retry: @escaping () -> Void) {
    if let existing = moduleView.subviews.first(where: { $0.identifier == cvmOverlayID }) {
        moduleView.addSubview(existing)   // 置于最前
        existing.isHidden = false
        return
    }
    let overlay = makeCVMMissingOverlay(retry: retry)
    overlay.identifier = cvmOverlayID
    moduleView.addSubview(overlay)
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: moduleView.topAnchor),
        overlay.leadingAnchor.constraint(equalTo: moduleView.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: moduleView.trailingAnchor),
        overlay.bottomAnchor.constraint(equalTo: moduleView.bottomAnchor)
    ])
}

func hideCVMMissingOverlay(in moduleView: NSView) {
    moduleView.subviews.first(where: { $0.identifier == cvmOverlayID })?.isHidden = true
}

// 点击穿透的标签（用作 NSTextView 占位提示，点击落到下方文本视图聚焦）
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

func makePlaceholderLabel(_ text: String) -> NSTextField {
    let l = PassthroughLabel(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: 13)
    l.textColor = .placeholderTextColor
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

// 带闭包回调的按钮（用于动态生成的列表行内操作按钮）
final class ClosureButton: NSButton {
    private var onClick: (() -> Void)?

    init(title: String, symbol: String?, tint: NSColor, onClick: @escaping () -> Void) {
        super.init(frame: .zero)
        self.onClick = onClick
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = NSFont.systemFont(ofSize: 11, weight: .medium)
        if let symbol = symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            self.image = image
            imagePosition = .imageLeading
            contentTintColor = tint
        }
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func fire() { onClick?() }
}

// App Store / 系统设置 风侧边栏行：彩色图标 + 标签；选中＝实心强调色圆角 + 白字白图标
final class SidebarRow: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let iconColor: NSColor
    var onClick: (() -> Void)?

    init(title: String, symbol: String, iconColor: NSColor) {
        self.iconColor = iconColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        setSelected(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func clicked() { onClick?() }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = (selected ? NSColor.controlAccentColor : .clear).cgColor
        iconView.contentTintColor = selected ? .white : iconColor
        label.textColor = selected ? .white : .labelColor
        label.font = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
    }
}

// 独立「版本管理」窗口：展示 cvm 已装版本与安装检测（Phase A 只读）
final class CVMWindowController: NSObject {
    let moduleView = NSView()
    private var built = false
    private var claudeVersionsStack: NSStackView!
    private var codexVersionsStack: NSStackView!
    private var detectTextView: NSTextView!
    private var resultTextView: NSTextView!
    private var claudeField: NSTextField!
    private var codexField: NSTextField!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!
    private var opButtons: [NSButton] = []
    private var rowButtons: [NSButton] = []  // 动态版本行内按钮，执行时一并禁用

    // 首次显示时构建 UI 并加载数据（嵌入主窗口内容区，不再独立窗口）
    func activate() {
        if !built {
            moduleView.translatesAutoresizingMaskIntoConstraints = false
            buildUI(into: moduleView)
            built = true
        }
        if !CVMRunner.isInstalled {
            showCVMMissingOverlay(in: moduleView) { [weak self] in self?.activate() }
            return
        }
        hideCVMMissingOverlay(in: moduleView)
        refresh()
    }

    private func buildUI(into content: NSView) {
        let title = NSTextField(labelWithString: "版本管理")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "通过 cvm 管理 Claude Code 与 Codex CLI 的本地版本 · 安装 / 切换 / 卸载 / 更新")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        if let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") {
            refreshButton.image = image
            refreshButton.imagePosition = .imageLeading
        }
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let doctorButton = opButton("诊断", "stethoscope", .systemBlue, #selector(runDoctor))
        let selfUpdateButton = opButton("更新 cvm", "arrow.triangle.2.circlepath", .systemIndigo, #selector(runSelfUpdate))
        opButtons.append(contentsOf: [doctorButton, selfUpdateButton])

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let claudePanel = makeToolPanel(title: "Claude Code", symbol: "cube.fill", tint: .systemOrange, isCodex: false)
        let codexPanel = makeToolPanel(title: "Codex CLI", symbol: "chevron.left.forwardslash.chevron.right", tint: .systemGreen, isCodex: true)
        let (detectPanel, detectTV) = makeTextPanel(title: "安装来源检测", symbol: "magnifyingglass", tint: .systemBlue)
        detectTextView = detectTV
        let (resultPanel, resultTV) = makeTextPanel(title: "操作结果", symbol: "terminal.fill", tint: .systemPurple)
        resultTextView = resultTV
        resultTextView.string = "在上方输入版本号后点击操作按钮，结果显示在此。"

        let views: [NSView] = [title, subtitle, doctorButton, selfUpdateButton, refreshButton, statusLabel, claudePanel, codexPanel, detectPanel, resultPanel]
        for view in views {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            refreshButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            selfUpdateButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            selfUpdateButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            doctorButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            doctorButton.trailingAnchor.constraint(equalTo: selfUpdateButton.leadingAnchor, constant: -8),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: doctorButton.leadingAnchor, constant: -12),

            statusLabel.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: doctorButton.leadingAnchor, constant: -12),

            claudePanel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            claudePanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            claudePanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            claudePanel.heightAnchor.constraint(equalToConstant: 188),

            codexPanel.topAnchor.constraint(equalTo: claudePanel.bottomAnchor, constant: 14),
            codexPanel.leadingAnchor.constraint(equalTo: claudePanel.leadingAnchor),
            codexPanel.trailingAnchor.constraint(equalTo: claudePanel.trailingAnchor),
            codexPanel.heightAnchor.constraint(equalToConstant: 188),

            detectPanel.topAnchor.constraint(equalTo: codexPanel.bottomAnchor, constant: 14),
            detectPanel.leadingAnchor.constraint(equalTo: claudePanel.leadingAnchor),
            detectPanel.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5, constant: -32),
            detectPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),

            resultPanel.topAnchor.constraint(equalTo: detectPanel.topAnchor),
            resultPanel.leadingAnchor.constraint(equalTo: detectPanel.trailingAnchor, constant: 16),
            resultPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            resultPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
    }

    // 工具面板：可操作的版本行列表（每行带「切换/卸载」+ 当前标记）+ 底部「安装新版本/更新」
    private func makeToolPanel(title: String, symbol: String, tint: NSColor, isCodex: Bool) -> NSView {
        let panel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (badge, titleLabel) = makePanelHeader(title: "\(title) 已装版本", symbol: symbol, tint: tint, in: panel)

        let versionsStack = NSStackView()
        versionsStack.orientation = .vertical
        versionsStack.spacing = 6
        versionsStack.alignment = .leading
        versionsStack.translatesAutoresizingMaskIntoConstraints = false
        if isCodex { codexVersionsStack = versionsStack } else { claudeVersionsStack = versionsStack }

        let scroll = NSScrollView()
        scroll.documentView = versionsStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)

        let field = NSTextField()
        field.placeholderString = "安装新版本，如 " + (isCodex ? "0.141.0" : "2.1.185")
        field.font = NSFont.systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(field)
        if isCodex { codexField = field } else { claudeField = field }

        let install = opButton("安装", "arrow.down.circle", tint, isCodex ? #selector(codexInstall) : #selector(claudeInstall))
        let update = opButton("更新到最新", "arrow.up.circle", tint, isCodex ? #selector(codexUpdate) : #selector(claudeUpdate))
        opButtons.append(contentsOf: [install, update])

        let buttonStack = NSStackView(views: [install, update])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: field.topAnchor, constant: -10),

            versionsStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            versionsStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            versionsStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            versionsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            field.widthAnchor.constraint(equalToConstant: 200),
            field.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),

            buttonStack.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            buttonStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            buttonStack.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -14)
        ])
        return panel
    }

    // 单个版本行：版本号 + 来源 + 「当前」标记 + 行内「切换/卸载」按钮
    private func makeVersionRow(version: String, source: String, isCurrent: Bool, isCodex: Bool, tint: NSColor) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = (isCurrent ? tint.withAlphaComponent(0.12) : NSColor.separatorColor.withAlphaComponent(0.10)).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let versionLabel = NSTextField(labelWithString: version)
        versionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(versionLabel)

        let sourceLabel = NSTextField(labelWithString: source)
        sourceLabel.font = NSFont.systemFont(ofSize: 10)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(sourceLabel)

        let deleteButton = ClosureButton(title: "卸载", symbol: "trash", tint: .systemRed) { [weak self] in
            let cmd = isCodex ? "cvm codex uninstall \(shellQuote(version))" : "cvm uninstall \(shellQuote(version))"
            self?.runAction(cmd, confirm: "卸载 \(isCodex ? "Codex" : "Claude") \(version)？")
        }
        rowButtons.append(deleteButton)
        row.addSubview(deleteButton)

        var trailingControl: NSView = deleteButton
        if isCurrent {
            let pill = makeCurrentPill(tint: tint)
            row.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
                pill.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            trailingControl = pill
        } else {
            let useButton = ClosureButton(title: "切换", symbol: "arrow.left.arrow.right.circle", tint: tint) { [weak self] in
                let cmd = isCodex ? "cvm codex use \(shellQuote(version))" : "cvm use \(shellQuote(version))"
                self?.runAction(cmd, confirm: "切换 \(isCodex ? "Codex" : "Claude") 当前版本为 \(version)？")
            }
            rowButtons.append(useButton)
            row.addSubview(useButton)
            NSLayoutConstraint.activate([
                useButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -6),
                useButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            trailingControl = useButton
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            versionLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            versionLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sourceLabel.leadingAnchor.constraint(equalTo: versionLabel.trailingAnchor, constant: 10),
            sourceLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingControl.leadingAnchor, constant: -8),
            deleteButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func parseInstalledVersions(_ text: String) -> [(version: String, source: String)] {
        var result: [(String, String)] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("✔") || line.hasPrefix("•") || line.hasPrefix("-") else { continue }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { !$0.isEmpty }
            guard let version = parts.first, version.first?.isNumber == true else { continue }
            result.append((version, parts.dropFirst().joined(separator: " ")))
        }
        return result
    }

    private func parseCurrentVersion(fromDetect text: String) -> String? {
        for raw in text.split(separator: "\n") where raw.contains("PATH") {
            for token in raw.split(separator: " ").map(String.init).reversed() {
                if token.hasPrefix("v"), let second = token.dropFirst().first, second.isNumber {
                    return String(token.dropFirst())
                }
            }
        }
        return nil
    }

    // 列表区加载占位（cvm 读取期间，避免空白）
    private func showVersionsLoading(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: "正在读取已装版本 …")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(label)
    }

    private func populateVersions(_ stack: NSStackView, _ versions: [(version: String, source: String)], current: String?, isCodex: Bool, tint: NSColor) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !versions.isEmpty else {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
            icon.contentTintColor = .tertiaryLabelColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            let empty = NSTextField(labelWithString: "暂无已安装版本\n在下方输入版本号「安装」，或「更新到最新」")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 2
            let box = NSStackView(views: [icon, empty])
            box.orientation = .vertical
            box.spacing = 7
            box.alignment = .centerX
            box.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 8, right: 0)
            box.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }
        for entry in versions {
            let row = makeVersionRow(version: entry.version, source: entry.source, isCurrent: entry.version == current, isCodex: isCodex, tint: tint)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func opButton(_ title: String, _ symbol: String, _ tint: NSColor, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageLeading
            button.contentTintColor = tint
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // 面板头部：强调色圆角图标徽标 + 标题，返回 (badge, titleLabel) 供布局衔接
    // MARK: - 操作

    private func version(from field: NSTextField) -> String? {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let alert = NSAlert()
            alert.messageText = "请先输入版本号"
            alert.runModal()
            return nil
        }
        return value
    }

    private func runAction(_ command: String, confirm: String? = nil) {
        if let message = confirm {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "命令：\(command)"
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setControlsEnabled(false)
        statusLabel.stringValue = "执行中…"
        resultTextView.string = "$ \(command)\n\n执行中，请稍候…（安装 / 更新可能需要联网下载，耗时较长）"
        CVMRunner.queue.async {
            let output = CVMRunner.run(command)
            DispatchQueue.main.async {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.resultTextView.string = "$ \(command)\n\n" + (trimmed.isEmpty ? "（无输出）" : trimmed)
                self.setControlsEnabled(true)
                self.refresh()
            }
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        refreshButton.isEnabled = enabled
        opButtons.forEach { $0.isEnabled = enabled }
        rowButtons.forEach { $0.isEnabled = enabled }
    }

    @objc private func claudeInstall() { if let v = version(from: claudeField) { runAction("cvm install \(v)") } }
    @objc private func claudeUpdate() { runAction("claude-update", confirm: "更新全局 Claude Code 到最新版本？") }
    @objc private func codexInstall() { if let v = version(from: codexField) { runAction("cvm codex install \(v)") } }
    @objc private func codexUpdate() { runAction("codex-update", confirm: "更新 Codex 到最新版本？") }
    @objc private func runDoctor() { runAction("cvm doctor") }
    @objc private func runSelfUpdate() { runAction("cvm self-update", confirm: "更新 cvm 自身到最新版本？") }

    @objc private func refreshClicked() {
        refresh()
    }

    private func refresh() {
        guard CVMRunner.isInstalled else {
            detectTextView.string = "未检测到 cvm（~/.cvm/cvm.sh）。\n\n安装方式：\n  bash <(curl -fsSL https://raw.githubusercontent.com/DoBestone/claude-codex-version-manager/main/install.sh)\n  source ~/.cvm/cvm.sh\n\n安装后点击「刷新」。"
            populateVersions(claudeVersionsStack, [], current: nil, isCodex: false, tint: .systemOrange)
            populateVersions(codexVersionsStack, [], current: nil, isCodex: true, tint: .systemGreen)
            statusLabel.stringValue = "cvm 未安装"
            setControlsEnabled(false)
            refreshButton.isEnabled = true
            return
        }
        statusLabel.stringValue = "正在读取 …"
        setControlsEnabled(false)
        refreshButton.isEnabled = false
        showVersionsLoading(claudeVersionsStack)
        showVersionsLoading(codexVersionsStack)
        CVMRunner.queue.async {
            let claudeInstalled = CVMRunner.run("cvm installed")
            let codexInstalled = CVMRunner.run("cvm codex installed")
            let claudeDetect = CVMRunner.run("cvm detect claude")
            let codexDetect = CVMRunner.run("cvm detect codex")
            DispatchQueue.main.async {
                self.rowButtons.removeAll()
                let claudeCurrent = self.parseCurrentVersion(fromDetect: claudeDetect)
                let codexCurrent = self.parseCurrentVersion(fromDetect: codexDetect)
                self.populateVersions(self.claudeVersionsStack, self.parseInstalledVersions(claudeInstalled), current: claudeCurrent, isCodex: false, tint: .systemOrange)
                self.populateVersions(self.codexVersionsStack, self.parseInstalledVersions(codexInstalled), current: codexCurrent, isCodex: true, tint: .systemGreen)
                self.detectTextView.string = (claudeDetect + "\n" + codexDetect).trimmingCharacters(in: .whitespacesAndNewlines)
                self.statusLabel.stringValue = "已更新"
                self.setControlsEnabled(true)
            }
        }
    }
}

// 独立「配置管理」窗口：cvm config 脱敏读取 + 显示密钥 + set/clear
final class CVMConfigWindowController: NSObject {
    let moduleView = NSView()
    private var built = false
    private var claudeFieldsStack: NSStackView!
    private var codexFieldsStack: NSStackView!
    private var resultTextView: NSTextView!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!
    private var opButtons: [NSButton] = []
    private var rowButtons: [NSButton] = []
    private var claudeShowSecrets = false
    private var codexShowSecrets = false

    // 首次显示时构建 UI 并加载（嵌入主窗口内容区）
    func activate() {
        if !built {
            moduleView.translatesAutoresizingMaskIntoConstraints = false
            buildUI(into: moduleView)
            built = true
        }
        if !CVMRunner.isInstalled {
            showCVMMissingOverlay(in: moduleView) { [weak self] in self?.activate() }
            return
        }
        hideCVMMissingOverlay(in: moduleView)
        refresh()
    }

    private func buildUI(into content: NSView) {
        let title = NSTextField(labelWithString: "配置管理")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "查看与修改 Claude Code / Codex 的 API URL、API Key、模型（敏感值默认脱敏）")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        if let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") {
            refreshButton.image = image
            refreshButton.imagePosition = .imageLeading
        }
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let claudePanel = makeConfigPanel(title: "Claude Code", symbol: "cube.fill", tint: .systemOrange, isCodex: false)
        let codexPanel = makeConfigPanel(title: "Codex CLI", symbol: "chevron.left.forwardslash.chevron.right", tint: .systemGreen, isCodex: true)
        let (resultPanel, resultTV) = makeTextPanel(title: "操作结果", symbol: "terminal.fill", tint: .systemPurple)
        resultTextView = resultTV
        resultTextView.string = "点字段行上的「编辑 / 清除」修改配置，结果显示在此。开启「显示密钥」可查看 API Key 原值。"

        let views: [NSView] = [title, subtitle, refreshButton, statusLabel, claudePanel, codexPanel, resultPanel]
        for view in views { content.addSubview(view) }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            refreshButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),

            claudePanel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            claudePanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            claudePanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            claudePanel.heightAnchor.constraint(equalToConstant: 210),

            codexPanel.topAnchor.constraint(equalTo: claudePanel.bottomAnchor, constant: 14),
            codexPanel.leadingAnchor.constraint(equalTo: claudePanel.leadingAnchor),
            codexPanel.trailingAnchor.constraint(equalTo: claudePanel.trailingAnchor),
            codexPanel.heightAnchor.constraint(equalToConstant: 210),

            resultPanel.topAnchor.constraint(equalTo: codexPanel.bottomAnchor, constant: 14),
            resultPanel.leadingAnchor.constraint(equalTo: claudePanel.leadingAnchor),
            resultPanel.trailingAnchor.constraint(equalTo: claudePanel.trailingAnchor),
            resultPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
    }

    private func makeConfigPanel(title: String, symbol: String, tint: NSColor, isCodex: Bool) -> NSView {
        let panel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (badge, titleLabel) = makePanelHeader(title: title, symbol: symbol, tint: tint, in: panel)

        let secretsToggle = NSButton(checkboxWithTitle: "显示密钥", target: self,
                                     action: isCodex ? #selector(codexToggleSecrets(_:)) : #selector(claudeToggleSecrets(_:)))
        secretsToggle.font = NSFont.systemFont(ofSize: 12)
        secretsToggle.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(secretsToggle)

        let fieldsStack = NSStackView()
        fieldsStack.orientation = .vertical
        fieldsStack.spacing = 6
        fieldsStack.alignment = .leading
        fieldsStack.translatesAutoresizingMaskIntoConstraints = false
        if isCodex { codexFieldsStack = fieldsStack } else { claudeFieldsStack = fieldsStack }

        let scroll = NSScrollView()
        scroll.documentView = fieldsStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)

        NSLayoutConstraint.activate([
            secretsToggle.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            secretsToggle.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: secretsToggle.leadingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),

            fieldsStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            fieldsStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            fieldsStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            fieldsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return panel
    }

    // 单个配置字段行：标签 + 当前值(脱敏) + （可设字段）行内「编辑/清除」
    private func makeConfigFieldRow(label: String, value: String, key: String?, tool: String) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.10).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelLabel = NSTextField(labelWithString: label)
        labelLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        labelLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labelLabel)

        let display = value.hasPrefix("未配置") ? "未配置" : value
        let valueLabel = NSTextField(labelWithString: display)
        valueLabel.font = NSFont.systemFont(ofSize: 11)
        valueLabel.textColor = display == "未配置" ? .tertiaryLabelColor : .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(valueLabel)

        var leadingOfButtons: NSLayoutXAxisAnchor = row.trailingAnchor
        var buttonInset: CGFloat = 0
        if let key = key {
            let editButton = ClosureButton(title: "编辑", symbol: "pencil", tint: .controlAccentColor) { [weak self] in
                self?.editConfigField(tool: tool, key: key, label: label)
            }
            rowButtons.append(editButton)
            row.addSubview(editButton)
            editButton.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
            if display == "未配置" {
                // 未配置：无可清除，仅显示「编辑」，去掉无意义的「清除」
                editButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10).isActive = true
            } else {
                let clearButton = ClosureButton(title: "清除", symbol: "xmark.circle", tint: .systemRed) { [weak self] in
                    self?.runAction("cvm config clear \(tool) \(key)", confirm: "清除 \(tool) 的 \(label)？")
                }
                rowButtons.append(clearButton)
                row.addSubview(clearButton)
                NSLayoutConstraint.activate([
                    clearButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                    clearButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    editButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6)
                ])
            }
            leadingOfButtons = editButton.leadingAnchor
            buttonInset = -8
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            labelLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            labelLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labelLabel.widthAnchor.constraint(equalToConstant: 64),
            valueLabel.leadingAnchor.constraint(equalTo: labelLabel.trailingAnchor, constant: 8),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: leadingOfButtons, constant: buttonInset)
        ])
        return row
    }

    private func editConfigField(tool: String, key: String, label: String) {
        let alert = NSAlert()
        alert.messageText = "设置 \(tool) 的 \(label)"
        alert.informativeText = "命令：cvm config set \(tool) \(key) <值>"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = label
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.layout(); alert.window.initialFirstResponder = input   // 弹窗即聚焦输入框
        if alert.runModal() == .alertFirstButtonReturn {
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            runAction("cvm config set \(tool) \(key) \(shellQuote(value))")
        }
    }

    private func parseConfigFields(_ text: String) -> [(label: String, value: String, key: String?)] {
        var result: [(String, String, String?)] = []
        var inCore = false
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.contains("当前核心配置") { inCore = true; continue }
            guard inCore else { continue }
            if line.contains("目录:") || line.contains("settings.json") || line.contains("config.toml") || line.contains("───") { break }
            guard let colon = line.range(of: ":") else { continue }
            let left = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty else { continue }
            let label = left.split(separator: " ").map(String.init).filter { !$0.contains("_") }.joined(separator: " ")
            var key: String? = nil
            if left.contains("_MODEL") { key = "model" }
            else if left.contains("_BASE_URL") { key = "api-url" }
            else if left.contains("_API_KEY") { key = "api-key" }
            result.append((label.isEmpty ? left : label, value, key))
        }
        return result
    }

    // 字段区加载占位（cvm 读取期间，避免空白）
    private func showConfigLoading(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: "正在读取配置 …")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(label)
    }

    private func populateConfigFields(_ stack: NSStackView, _ fields: [(label: String, value: String, key: String?)], tool: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !fields.isEmpty else {
            let empty = NSTextField(labelWithString: "（无法读取配置）")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        for field in fields {
            let row = makeConfigFieldRow(label: field.label, value: field.value, key: field.key, tool: tool)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: - 操作

    private func setControlsEnabled(_ enabled: Bool) {
        refreshButton.isEnabled = enabled
        opButtons.forEach { $0.isEnabled = enabled }
        rowButtons.forEach { $0.isEnabled = enabled }
    }

    private func runAction(_ command: String, confirm: String? = nil) {
        if let message = confirm {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "命令：\(command)"
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setControlsEnabled(false)
        statusLabel.stringValue = "执行中…"
        resultTextView.string = "$ \(command)\n\n执行中…"
        CVMRunner.queue.async {
            let output = CVMRunner.run(command)
            DispatchQueue.main.async {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.resultTextView.string = "$ \(command)\n\n" + (trimmed.isEmpty ? "（无输出）" : trimmed)
                self.setControlsEnabled(true)
                self.refresh()
            }
        }
    }

    @objc private func claudeToggleSecrets(_ sender: NSButton) { claudeShowSecrets = sender.state == .on; refresh() }
    @objc private func codexToggleSecrets(_ sender: NSButton) { codexShowSecrets = sender.state == .on; refresh() }

    @objc private func refreshClicked() { refresh() }

    private func refresh() {
        guard CVMRunner.isInstalled else {
            populateConfigFields(claudeFieldsStack, [], tool: "claude")
            populateConfigFields(codexFieldsStack, [], tool: "codex")
            statusLabel.stringValue = "cvm 未安装"
            setControlsEnabled(false)
            refreshButton.isEnabled = true
            return
        }
        statusLabel.stringValue = "正在读取 …"
        setControlsEnabled(false)
        showConfigLoading(claudeFieldsStack)
        showConfigLoading(codexFieldsStack)
        let claudeSecrets = claudeShowSecrets
        let codexSecrets = codexShowSecrets
        CVMRunner.queue.async {
            let claude = CVMRunner.run("cvm config claude" + (claudeSecrets ? " --show-secrets" : ""))
            let codex = CVMRunner.run("cvm config codex" + (codexSecrets ? " --show-secrets" : ""))
            DispatchQueue.main.async {
                self.rowButtons.removeAll()
                self.populateConfigFields(self.claudeFieldsStack, self.parseConfigFields(claude), tool: "claude")
                self.populateConfigFields(self.codexFieldsStack, self.parseConfigFields(codex), tool: "codex")
                self.statusLabel.stringValue = "已更新"
                self.setControlsEnabled(true)
            }
        }
    }
}

// 「配置档案」模块：cvm profile 多套 API 配置档案管理（list/add/use/delete）
final class CVMProfileWindowController: NSObject {
    let moduleView = NSView()
    private var built = false
    private var toolSegmented: NSSegmentedControl!
    private var profilesStack: NSStackView!
    private var resultTV: NSTextView!
    private var nameField: NSTextField!
    private var urlField: NSTextField!
    private var keyField: NSTextField!
    private var modelField: NSTextField!
    private var proxyField: NSTextField!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!
    private var opButtons: [NSButton] = []
    private var rowButtons: [NSButton] = []

    private var tool: String { (toolSegmented?.selectedSegment ?? 0) == 1 ? "codex" : "claude" }

    func activate() {
        if !built {
            moduleView.translatesAutoresizingMaskIntoConstraints = false
            buildUI(into: moduleView)
            built = true
        }
        if !CVMRunner.isInstalled {
            showCVMMissingOverlay(in: moduleView) { [weak self] in self?.activate() }
            return
        }
        hideCVMMissingOverlay(in: moduleView)
        refresh()
    }

    private func buildUI(into content: NSView) {
        let title = NSTextField(labelWithString: "配置档案")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "管理多套 API 配置档案（名称 / URL / Key / 模型 / 代理），一键切换")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        if let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") {
            refreshButton.image = image
            refreshButton.imagePosition = .imageLeading
        }
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        toolSegmented = NSSegmentedControl(labels: ["Claude", "Codex"], trackingMode: .selectOne, target: self, action: #selector(toolChanged))
        toolSegmented.selectedSegment = 0
        toolSegmented.segmentStyle = .rounded
        toolSegmented.translatesAutoresizingMaskIntoConstraints = false

        // 档案列表（可操作行：行内 切换/删除 + 当前标记）
        let listPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (listBadge, _) = makePanelHeader(title: "档案列表", symbol: "list.bullet.rectangle.fill", tint: .systemBlue, in: listPanel)
        profilesStack = NSStackView()
        profilesStack.orientation = .vertical
        profilesStack.spacing = 6
        profilesStack.alignment = .leading
        profilesStack.translatesAutoresizingMaskIntoConstraints = false
        let listScroll = NSScrollView()
        listScroll.documentView = profilesStack
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listPanel.addSubview(listScroll)

        // 新增档案表单
        let addPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (addBadge, _) = makePanelHeader(title: "新增档案", symbol: "plus.circle.fill", tint: .systemGreen, in: addPanel)
        nameField = makeField("名称，如 work")
        urlField = makeField("API URL，如 https://api.example.com")
        keyField = makeField("API Key，如 sk-ant-...")
        modelField = makeField("模型，如 claude-opus-4-7")
        proxyField = makeField("代理（可选），http:// 或 socks5://")
        let addButton = opButton("添加档案", "plus", .systemGreen, #selector(addProfile))
        opButtons.append(addButton)
        for field in [nameField!, urlField!, keyField!, modelField!, proxyField!, addButton] { addPanel.addSubview(field) }

        let (resultPanel, resultText) = makeTextPanel(title: "操作结果", symbol: "terminal.fill", tint: .systemPurple)
        resultTV = resultText
        resultTV.string = "点档案行上的「切换/删除」操作，或在下方新增档案，结果显示在此。"

        let panels: [NSView] = [title, subtitle, refreshButton, statusLabel, toolSegmented, listPanel, addPanel, resultPanel]
        for view in panels {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            refreshButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 0),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),

            toolSegmented.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            toolSegmented.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            toolSegmented.widthAnchor.constraint(equalToConstant: 200),

            listPanel.topAnchor.constraint(equalTo: toolSegmented.bottomAnchor, constant: 12),
            listPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            listPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 0),
            listPanel.heightAnchor.constraint(equalToConstant: 168),

            listScroll.topAnchor.constraint(equalTo: listBadge.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 14),
            listScroll.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -14),
            listScroll.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: -12),
            profilesStack.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            profilesStack.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            profilesStack.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            profilesStack.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),

            addPanel.topAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: 12),
            addPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            addPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 0),
            addPanel.heightAnchor.constraint(equalToConstant: 232),

            resultPanel.topAnchor.constraint(equalTo: addPanel.bottomAnchor, constant: 12),
            resultPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            resultPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 0),
            resultPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),

            // 新增表单：5 个字段竖排 + 添加按钮
            nameField.topAnchor.constraint(equalTo: addBadge.bottomAnchor, constant: 10),
            nameField.leadingAnchor.constraint(equalTo: addPanel.leadingAnchor, constant: 14),
            nameField.trailingAnchor.constraint(equalTo: addPanel.trailingAnchor, constant: -14),
            urlField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            urlField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            urlField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            keyField.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 6),
            keyField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            modelField.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 6),
            modelField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            modelField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            proxyField.topAnchor.constraint(equalTo: modelField.bottomAnchor, constant: 6),
            proxyField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            proxyField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            addButton.topAnchor.constraint(equalTo: proxyField.bottomAnchor, constant: 10),
            addButton.trailingAnchor.constraint(equalTo: addPanel.trailingAnchor, constant: -14),
            addButton.bottomAnchor.constraint(lessThanOrEqualTo: addPanel.bottomAnchor, constant: -12)
        ])
    }

    // 单个档案行：名称 + 模型/URL 摘要 + 「当前」标记 + 行内「切换/删除」
    private func makeProfileRow(name: String, model: String, url: String, isCurrent: Bool, tool: String) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = (isCurrent ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.separatorColor.withAlphaComponent(0.10)).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(nameLabel)

        var detail = model.isEmpty ? "" : model
        if !url.isEmpty && url != "默认" { detail += (detail.isEmpty ? "" : "  ") + url }
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(detailLabel)

        let deleteButton = ClosureButton(title: "删除", symbol: "trash", tint: .systemRed) { [weak self] in
            self?.runAction("cvm profile delete \(tool) \(shellQuote(name))", confirm: "删除 \(tool) 的档案「\(name)」？")
        }
        rowButtons.append(deleteButton)
        row.addSubview(deleteButton)

        var trailingControl: NSView = deleteButton
        if isCurrent {
            let pill = makeCurrentPill(tint: .controlAccentColor)
            row.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
                pill.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            trailingControl = pill
        } else {
            let useButton = ClosureButton(title: "切换", symbol: "checkmark.circle", tint: .systemBlue) { [weak self] in
                self?.runAction("cvm profile use \(tool) \(shellQuote(name))", confirm: "切换 \(tool) 到档案「\(name)」？")
            }
            rowButtons.append(useButton)
            row.addSubview(useButton)
            NSLayoutConstraint.activate([
                useButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -6),
                useButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            trailingControl = useButton
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 38),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingControl.leadingAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingControl.leadingAnchor, constant: -8),
            deleteButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func parseProfiles(_ text: String) -> [(name: String, model: String, url: String, isCurrent: Bool)] {
        var result: [(String, String, String, Bool)] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let paren = line.range(of: ")") else { continue }
            guard Int(line[..<paren.lowerBound].trimmingCharacters(in: .whitespaces)) != nil else { continue }
            var rest = String(line[paren.upperBound...]).trimmingCharacters(in: .whitespaces)
            var isCurrent = false
            if rest.hasPrefix("*") {
                isCurrent = true
                rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let tokens = rest.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard let name = tokens.first, !name.contains("=") else { continue }
            let model = tokens.first(where: { $0.hasPrefix("model=") }).map { String($0.dropFirst(6)) } ?? ""
            let url = tokens.first(where: { $0.hasPrefix("url=") }).map { String($0.dropFirst(4)) } ?? ""
            result.append((name, model == "未配置" ? "" : model, url, isCurrent))
        }
        return result
    }

    private func populateProfiles(_ profiles: [(name: String, model: String, url: String, isCurrent: Bool)], tool: String) {
        profilesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !profiles.isEmpty else {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
            icon.contentTintColor = .tertiaryLabelColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
            let empty = NSTextField(labelWithString: "暂无 \(tool) 配置档案\n在下方「新增档案」创建一套 API 配置，可一键切换")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 2
            let box = NSStackView(views: [icon, empty])
            box.orientation = .vertical
            box.spacing = 8
            box.alignment = .centerX
            box.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 10, right: 0)
            box.translatesAutoresizingMaskIntoConstraints = false
            profilesStack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: profilesStack.widthAnchor).isActive = true
            return
        }
        for profile in profiles {
            let row = makeProfileRow(name: profile.name, model: profile.model, url: profile.url, isCurrent: profile.isCurrent, tool: tool)
            profilesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: profilesStack.widthAnchor).isActive = true
        }
    }

    private func makeField(_ placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func opButton(_ title: String, _ symbol: String, _ tint: NSColor, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageLeading
            button.contentTintColor = tint
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func setControlsEnabled(_ enabled: Bool) {
        refreshButton.isEnabled = enabled
        toolSegmented.isEnabled = enabled
        opButtons.forEach { $0.isEnabled = enabled }
        rowButtons.forEach { $0.isEnabled = enabled }
    }

    private func runAction(_ command: String, confirm: String? = nil) {
        if let message = confirm {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "命令：\(command)"
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setControlsEnabled(false)
        statusLabel.stringValue = "执行中…"
        resultTV.string = "$ \(command)\n\n执行中…"
        CVMRunner.queue.async {
            let output = CVMRunner.run(command)
            DispatchQueue.main.async {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.resultTV.string = "$ \(command)\n\n" + (trimmed.isEmpty ? "（无输出）" : trimmed)
                self.setControlsEnabled(true)
                self.refresh()
            }
        }
    }

    @objc private func addProfile() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxy = proxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty, !key.isEmpty, !model.isEmpty else {
            let alert = NSAlert(); alert.messageText = "名称、API URL、API Key、模型 均为必填"; alert.runModal(); return
        }
        var command = "cvm profile add \(tool) \(shellQuote(name)) \(shellQuote(url)) \(shellQuote(key)) \(shellQuote(model))"
        if !proxy.isEmpty { command += " \(shellQuote(proxy))" }
        runAction(command)
    }

    @objc private func toolChanged() { refresh() }
    @objc private func refreshClicked() { refresh() }

    private func refresh() {
        let currentTool = tool
        guard CVMRunner.isInstalled else {
            populateProfiles([], tool: currentTool)
            statusLabel.stringValue = "cvm 未安装"
            setControlsEnabled(false)
            refreshButton.isEnabled = true
            toolSegmented.isEnabled = true
            return
        }
        statusLabel.stringValue = "正在读取 …"
        setControlsEnabled(false)
        profilesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let loading = NSTextField(labelWithString: "正在读取配置档案 …")
        loading.font = NSFont.systemFont(ofSize: 11)
        loading.textColor = .tertiaryLabelColor
        profilesStack.addArrangedSubview(loading)
        CVMRunner.queue.async {
            let list = CVMRunner.run("cvm profile list \(currentTool)")
            DispatchQueue.main.async {
                self.rowButtons.removeAll()
                self.populateProfiles(self.parseProfiles(list), tool: currentTool)
                self.statusLabel.stringValue = "已更新"
                self.setControlsEnabled(true)
            }
        }
    }
}

// 全局快捷键回调（C 函数指针不能捕获上下文，转发到单例）
private func voiceHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { VoiceFloatingController.shared.toggle() }
    return noErr
}

// 「语音输入」悬浮面板：全局快捷键 ⌥⌘Space 唤出；转写文本可编辑 → AI 矫正 / 复制 / 送入工作台
// （本阶段先搭面板+快捷键+联通，SFSpeechRecognizer 转写下一步接入）
final class VoiceFloatingController: NSObject, NSTextViewDelegate {
    static let shared = VoiceFloatingController()
    private var panel: NSPanel?
    private var transcriptTextView: NSTextView!
    private var transcriptCountLabel: NSTextField!
    private var transcriptPlaceholder: NSTextField!
    private var transcriptActionButtons: [NSButton] = []   // 依赖转写非空才可用（矫正/复制/粘贴/工作台）
    private var correctSpinner: NSProgressIndicator!       // AI 矫正中的忙碌指示
    private var hintLabel: NSTextField?                     // 标题栏快捷键提示（随自定义热键更新）
    private var recordButton: NSButton!
    private var openSettingsButton: NSButton!
    private var statusLabel: NSTextField!
    private var pendingSettingsURL: String?
    private var hotKeyRef: EventHotKeyRef?
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false
    private weak var previousApp: NSRunningApplication?

    private var handlerInstalled = false

    // 注册全局快捷键（Carbon，无需辅助功能权限）。从 UserDefaults 读取自定义键，默认 ⌥⌘Space
    func installHotKey() {
        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), voiceHotKeyHandler, 1, &eventType, nil, nil)
            handlerInstalled = true
        }
        reregisterHotKey()
    }

    // 注销旧热键并按当前设置重新注册（快捷键自定义后调用）
    func reregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let d = UserDefaults.standard
        let code = UInt32(d.object(forKey: "voice.hotKeyCode") as? Int ?? Int(kVK_Space))
        let mods = UInt32(d.object(forKey: "voice.hotKeyMods") as? Int ?? Int(cmdKey | optionKey))
        let hotKeyID = EventHotKeyID(signature: OSType(0x41495643), id: 1) // 'AIVC'
        RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // 当前快捷键的显示文本（供配置页）
    static var hotKeyLabel: String {
        UserDefaults.standard.string(forKey: "voice.hotKeyLabel") ?? "⌥⌘Space"
    }

    func toggle() {
        if panel == nil { build() }
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            // 记录唤出前的前台 App，便于「粘贴到前台」回填
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = front
            }
            positionPanel()
            updateTranscriptCount()   // 同步动作按钮可用态（空转写时禁用）
            hintLabel?.stringValue = "\(Self.hotKeyLabel) 唤出 / 隐藏"   // 反映当前（可能自定义的）热键
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func show() { if panel?.isVisible != true { toggle() } }

    private func positionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let frame = panel.frame
        let x = screen.visibleFrame.midX - frame.width / 2
        let y = screen.visibleFrame.maxY - frame.height - 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 230),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "语音输入"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.cornerCurve = .continuous
        p.contentView = content

        let titleLabel = NSTextField(labelWithString: "语音输入")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "\(Self.hotKeyLabel) 唤出 / 隐藏")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hintLabel = hint

        recordButton = NSButton(title: "  开始录音", target: self, action: #selector(toggleRecord))
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        if let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "录音") {
            recordButton.image = img; recordButton.imagePosition = .imageLeading; recordButton.contentTintColor = .systemRed
        }
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        openSettingsButton = NSButton(title: "去系统设置开启", target: self, action: #selector(openPrivacySettings))
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.controlSize = .regular
        openSettingsButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openSettingsButton.contentTintColor = .systemOrange
        openSettingsButton.isHidden = true
        openSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        transcriptTextView = textView
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        transcriptPlaceholder = makePlaceholderLabel("点「开始录音」说话，或直接输入文字…")
        content.addSubview(transcriptPlaceholder)
        NSLayoutConstraint.activate([
            transcriptPlaceholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            transcriptPlaceholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 10),
            transcriptPlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -8)
        ])

        let correctButton = ClosureButton(title: "AI 矫正", symbol: "wand.and.stars", tint: .systemPurple) { [weak self] in self?.aiCorrect() }
        let copyButton = ClosureButton(title: "复制", symbol: "doc.on.doc", tint: .controlAccentColor) { [weak self] in self?.copyText() }
        let pasteButton = ClosureButton(title: "粘贴", symbol: "arrow.down.doc", tint: .systemBlue) { [weak self] in self?.pasteToFrontmost() }
        let workbenchButton = ClosureButton(title: "工作台", symbol: "arrow.up.forward.app", tint: .systemGreen) { [weak self] in self?.sendToWorkbench() }
        let clearButton = ClosureButton(title: "清空", symbol: "xmark", tint: .systemGray) { [weak self] in self?.clearTranscript() }
        for b in [correctButton, copyButton, pasteButton, workbenchButton, clearButton] { b.translatesAutoresizingMaskIntoConstraints = false }
        transcriptActionButtons = [correctButton, copyButton, pasteButton, workbenchButton]
        let actionStack = NSStackView(views: [correctButton, copyButton, pasteButton, workbenchButton, clearButton])
        actionStack.orientation = .horizontal
        actionStack.spacing = 6
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        transcriptTextView.delegate = self
        transcriptCountLabel = NSTextField(labelWithString: "0 字")
        transcriptCountLabel.font = NSFont.systemFont(ofSize: 10)
        transcriptCountLabel.textColor = .tertiaryLabelColor
        transcriptCountLabel.translatesAutoresizingMaskIntoConstraints = false

        correctSpinner = NSProgressIndicator()
        correctSpinner.style = .spinning
        correctSpinner.controlSize = .small
        correctSpinner.isDisplayedWhenStopped = false
        correctSpinner.translatesAutoresizingMaskIntoConstraints = false

        let panelViews: [NSView] = [titleLabel, hint, recordButton, openSettingsButton, scroll, actionStack, correctSpinner, statusLabel, transcriptCountLabel]
        for v in panelViews { content.addSubview(v) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            recordButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            recordButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            openSettingsButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            openSettingsButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 70),

            actionStack.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            actionStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            actionStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            actionStack.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: correctSpinner.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: transcriptCountLabel.leadingAnchor, constant: -8),
            correctSpinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            correctSpinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            correctSpinner.widthAnchor.constraint(equalToConstant: 12),
            correctSpinner.heightAnchor.constraint(equalToConstant: 12),
            transcriptCountLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            transcriptCountLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
        ])
        panel = p
    }

    func textDidChange(_ notification: Notification) { updateTranscriptCount() }
    private func updateTranscriptCount() {
        transcriptCountLabel?.stringValue = "\(transcriptTextView.string.count) 字"
        transcriptPlaceholder?.isHidden = !transcriptTextView.string.isEmpty
        // 无转写内容时禁用 矫正/复制/粘贴/工作台
        let hasText = !transcriptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        transcriptActionButtons.forEach { $0.isEnabled = hasText }
    }

    @objc private func toggleRecord() {
        if isRecording { stopRecording(); return }
        openSettingsButton.isHidden = true
        // 先查当前授权状态：已被拒/受限则直接引导去系统设置，不再触发系统弹窗
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .denied || speechStatus == .restricted {
            showPermissionDenied(message: "语音识别权限被拒，无法转写", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            showPermissionDenied(message: "麦克风权限被拒，无法录音", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            return
        }
        // 未决定/已授权：请求语音识别权限 + 麦克风权限（首次会弹系统框）
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard authStatus == .authorized else {
                    self.showPermissionDenied(message: "语音识别未授权，无法转写", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.showPermissionDenied(message: "麦克风未授权，无法录音", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                            return
                        }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    private func showPermissionDenied(message: String, url: String) {
        statusLabel.stringValue = message
        pendingSettingsURL = url
        openSettingsButton.isHidden = false
    }

    @objc private func openPrivacySettings() {
        if let urlString = pendingSettingsURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func beginRecording() {
        let localeId = UserDefaults.standard.string(forKey: "voice.locale") ?? "zh-CN"
        let rec = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer()
        guard let rec = rec, rec.isAvailable else {
            statusLabel.stringValue = "语音识别当前不可用（检查网络/语言支持）"
            return
        }
        recognizer = rec

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        // 用硬件真实输入格式；无效(采样率/声道为 0，常见于无可用输入设备或刚授权未就绪)时
        // 直接 installTap 会抛 NSException 致 abort，先校验避免崩溃
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            statusLabel.stringValue = "麦克风未就绪：未检测到输入设备。请连接麦克风后重试（Mac mini 无内置麦克风；或检查 系统设置→声音→输入）"
            recognitionRequest = nil
            return
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            statusLabel.stringValue = "录音启动失败：\(error.localizedDescription)"
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            recognitionTask = nil
            return
        }

        recognitionTask = rec.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let result = result {
                    self.transcriptTextView.string = result.bestTranscription.formattedString
                    self.updateTranscriptCount()
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stopRecording()
                }
            }
        }

        isRecording = true
        recordButton.title = "  停止"
        recordButton.contentTintColor = .systemRed
        if let img = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "停止") {
            recordButton.image = img
        }
        statusLabel.stringValue = "聆听中…（说话后点「停止」）"
    }

    private func stopRecording() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        recordButton.title = "  开始录音"
        if let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "录音") {
            recordButton.image = img
        }
        recordButton.contentTintColor = .systemRed
        if statusLabel.stringValue.hasPrefix("聆听中") { statusLabel.stringValue = "已停止" }
        // 偏好开启「自动 AI 矫正」时，停止后稍候自动矫正转写
        if UserDefaults.standard.bool(forKey: "voice.autoCorrect"),
           !transcriptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.aiCorrect() }
        }
    }

    // 复制到剪贴板 → 激活之前的前台 App → 模拟 Cmd+V 粘贴
    private func pasteToFrontmost() {
        let text = transcriptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "无文本可粘贴"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        panel?.orderOut(nil)
        previousApp?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let key = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        statusLabel.stringValue = "已复制并尝试粘贴（若未生效请在 辅助功能 授权本 App 后手动 Cmd+V）"
    }

    private func aiCorrect() {
        let text = transcriptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "无文本可矫正"; return }
        guard AIConfig.isConfigured else { statusLabel.stringValue = "未配置 API Key（菜单 AI 设置）"; return }
        statusLabel.stringValue = "AI 矫正中…"
        transcriptActionButtons.forEach { $0.isEnabled = false }   // 矫正期间禁用按钮，避免重复点击
        correctSpinner?.startAnimation(nil)
        let system = "你是文字校对助手。修正下面这段语音转写文本的错别字、标点和明显识别错误，使其通顺自然，保持原意与原语言。只输出修正后的文本，不要解释、不要加引号。"
        AIClient.complete(system: system, user: text) { [weak self] result, error in
            guard let self = self else { return }
            self.correctSpinner?.stopAnimation(nil)
            if let result = result { self.transcriptTextView.string = result; self.statusLabel.stringValue = "已矫正" }
            else { self.statusLabel.stringValue = error ?? "矫正失败" }
            self.updateTranscriptCount()   // 恢复按钮可用态（按转写非空）
        }
    }

    private func copyText() {
        let text = transcriptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ClipboardStore.copy(text)
        statusLabel.stringValue = "已复制到剪贴板"
    }

    private func clearTranscript() {
        transcriptTextView.string = ""
        updateTranscriptCount()
        statusLabel.stringValue = "已清空转写"
    }

    private func sendToWorkbench() {
        let text = transcriptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        AIWorkbenchWindowController.shared.show(seedText: text)
    }
}

// MARK: - AI 配置与客户端（独立于 cvm，用于 AI 优化提示词 / 中译英 / 语音矫正）

// 剪贴板历史：app 内复制(AI 结果/语音转写/项目提示词)时记录，最近 20 条存 UserDefaults
enum ClipboardStore {
    private static let key = "clipboard.history"
    private static let maxItems = 20
    static var items: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func record(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = items.filter { $0 != t }
        list.insert(t, at: 0)
        if list.count > maxItems { list = Array(list.prefix(maxItems)) }
        UserDefaults.standard.set(list, forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
    // 同时写系统剪贴板 + 记录历史
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        record(text)
    }
}

enum AIConfig {
    // provider: "anthropic"(/v1/messages, x-api-key) 或 "openai"(/v1/chat/completions, Bearer)
    static var provider: String { UserDefaults.standard.string(forKey: "ai.provider").flatMap { $0.isEmpty ? nil : $0 } ?? "anthropic" }
    static var isOpenAI: Bool { provider == "openai" }
    static var baseURL: String {
        if let v = UserDefaults.standard.string(forKey: "ai.baseURL"), !v.isEmpty { return v }
        return isOpenAI ? "https://api.openai.com" : "https://api.anthropic.com"
    }
    static var apiKey: String { UserDefaults.standard.string(forKey: "ai.apiKey") ?? "" }
    static var model: String {
        if let v = UserDefaults.standard.string(forKey: "ai.model"), !v.isEmpty { return v }
        return isOpenAI ? "gpt-4o" : "claude-sonnet-4-6"
    }
    static var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    static func save(provider: String, baseURL: String, apiKey: String, model: String) {
        let d = UserDefaults.standard
        d.set(provider, forKey: "ai.provider")
        d.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.baseURL")
        d.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.apiKey")
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.model")
    }
}

enum AIClient {
    // 按 provider 调 Anthropic(/v1/messages) 或 OpenAI 兼容(/v1/chat/completions)，completion 在主线程返回 (文本, 错误)
    static func complete(system: String, user: String, completion: @escaping (String?, String?) -> Void) {
        guard AIConfig.isConfigured else { completion(nil, "未配置 API Key，请先在「AI 设置」填写"); return }
        var base = AIConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // 缺协议时自动补 https://，去掉末尾斜杠
        if !base.lowercased().hasPrefix("http://"), !base.lowercased().hasPrefix("https://") {
            base = "https://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        let openAI = AIConfig.isOpenAI
        let path = openAI ? "/v1/chat/completions" : "/v1/messages"
        guard let url = URL(string: base + path), url.host != nil else { completion(nil, "API 端点无效：\(base)"); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any]
        if openAI {
            request.setValue("Bearer \(AIConfig.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": AIConfig.model,
                "max_tokens": 1024,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
            ]
        } else {
            request.setValue(AIConfig.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": AIConfig.model,
                "max_tokens": 1024,
                "system": system,
                "messages": [["role": "user", "content": user]]
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error { completion(nil, "网络错误：\(error.localizedDescription)"); return }
                guard let http = response as? HTTPURLResponse, let data = data else { completion(nil, "无响应数据"); return }
                guard http.statusCode == 200 else {
                    // 优先提取 JSON 里的 error.message（Anthropic/OpenAI 通用），否则取原始体
                    var detail = ""
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = json["error"] as? [String: Any], let m = err["message"] as? String {
                        detail = m
                    } else {
                        detail = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let hint: String
                    switch http.statusCode {
                    case 401, 403: hint = "（API Key 无效或无权限）"
                    case 404: hint = "（端点或模型不存在，检查 端点/模型）"
                    case 429: hint = "（请求过于频繁或额度不足）"
                    case 500...599: hint = "（服务端错误，稍后重试）"
                    default: hint = ""
                    }
                    completion(nil, "HTTP \(http.statusCode)\(hint)：\(detail.prefix(240))")
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(nil, "无法解析返回内容"); return
                }
                // 解析出的文本若为空（模型偶尔返回空内容），按可重试错误处理，避免「已生成」却空白
                func deliver(_ text: String) {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        completion(nil, "AI 返回了空内容，可点「重新生成」重试")
                    } else { completion(text, nil) }
                }
                if openAI {
                    if let choices = json["choices"] as? [[String: Any]],
                       let message = choices.first?["message"] as? [String: Any],
                       let text = message["content"] as? String {
                        deliver(text)
                    } else { completion(nil, "无法解析 OpenAI 返回") }
                } else {
                    if let content = json["content"] as? [[String: Any]],
                       let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
                        deliver(text)
                    } else { completion(nil, "无法解析 Anthropic 返回") }
                }
            }
        }.resume()
    }
}

// 「AI 设置」小窗：填写独立的 API 端点 / Key / 模型
final class AISettingsWindowController: NSObject, NSTextFieldDelegate {
    private var window: NSWindow!
    private var baseField: NSTextField!
    private var keyField: NSSecureTextField!
    private var modelField: NSComboBox!
    private var providerPopup: NSPopUpButton!
    private var providerHintLabel: NSTextField!
    private var resetEndpointButton: ClosureButton!
    private var testStatusLabel: NSTextField!
    private var testButton: NSButton!

    // 模型下拉常用预设（可编辑，仍可手填任意模型）
    static func modelPresets(openAI: Bool) -> [String] {
        openAI
            ? ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o1", "o3-mini", "deepseek-chat", "deepseek-reasoner"]
            : ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
    }

    // 当前 provider 的请求格式提示
    static func providerHint(openAI: Bool) -> String {
        openAI
            ? "请求 端点 + /v1/chat/completions · 鉴权 Authorization: Bearer · 兼容 OpenAI / DeepSeek / 本地等"
            : "请求 端点 + /v1/messages · 鉴权 x-api-key + anthropic-version"
    }
    private var testSpinner: NSProgressIndicator!

    func show() {
        if window == nil { build() }
        providerPopup.selectItem(at: AIConfig.isOpenAI ? 1 : 0)
        providerHintLabel.stringValue = Self.providerHint(openAI: AIConfig.isOpenAI)
        modelField.removeAllItems()
        modelField.addItems(withObjectValues: Self.modelPresets(openAI: AIConfig.isOpenAI))
        baseField.stringValue = AIConfig.baseURL
        keyField.stringValue = AIConfig.apiKey
        modelField.stringValue = AIConfig.model
        if AIConfig.apiKey.isEmpty {
            testStatusLabel.stringValue = ""
        } else {
            testStatusLabel.textColor = .systemGreen
            testStatusLabel.stringValue = "✓ 已配置 API Key（已脱敏，可「测试连接」验证）"
        }
        updateTestEnabled()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 聚焦端点框（普通文本框）：可立即编辑，且避免聚焦密钥框触发 macOS 密码自动填充浮窗；Key 一个 Tab 即达
        window.makeFirstResponder(baseField)
    }

    private var selectedProvider: String { providerPopup.indexOfSelectedItem == 1 ? "openai" : "anthropic" }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 432),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI 设置"
        window.isReleasedWhenClosed = false
        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        let title = NSTextField(labelWithString: "AI 设置")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "用于 AI 优化提示词 / 中译英 / 语音矫正，独立于 cvm 配置")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: ["Anthropic（Claude）", "OpenAI 兼容（Bearer）"])
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false

        providerHintLabel = NSTextField(labelWithString: "")
        providerHintLabel.font = NSFont.systemFont(ofSize: 10)
        providerHintLabel.textColor = .tertiaryLabelColor
        providerHintLabel.lineBreakMode = .byTruncatingTail
        providerHintLabel.translatesAutoresizingMaskIntoConstraints = false

        baseField = NSTextField(); baseField.placeholderString = "API 端点"
        resetEndpointButton = ClosureButton(title: "", symbol: "arrow.counterclockwise", tint: .systemBlue) { [weak self] in self?.resetEndpoint() }
        resetEndpointButton.toolTip = "恢复为当前提供商的默认端点"
        resetEndpointButton.translatesAutoresizingMaskIntoConstraints = false
        keyField = NSSecureTextField(); keyField.placeholderString = "API Key"
        modelField = NSComboBox()
        modelField.placeholderString = "模型"
        modelField.isEditable = true
        modelField.completes = true
        for f in [baseField!, modelField!] { f.font = NSFont.systemFont(ofSize: 12); f.translatesAutoresizingMaskIntoConstraints = false }
        keyField.font = NSFont.systemFont(ofSize: 12); keyField.translatesAutoresizingMaskIntoConstraints = false
        baseField.delegate = self; keyField.delegate = self   // 端点/Key 变化时刷新「测试连接」可用态

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            l.translatesAutoresizingMaskIntoConstraints = false; return l
        }
        let providerLabel = label("提供商"), baseLabel = label("API 端点"), keyLabel = label("API Key"), modelLabel = label("模型")

        let saveButton = ClosureButton(title: "保存", symbol: "checkmark.circle", tint: .systemGreen) { [weak self] in
            guard let self = self else { return }
            AIConfig.save(provider: self.selectedProvider, baseURL: self.baseField.stringValue, apiKey: self.keyField.stringValue, model: self.modelField.stringValue)
            self.testStatusLabel.textColor = .systemGreen
            self.testStatusLabel.stringValue = "✓ 已保存设置"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.window.close() }
        }
        saveButton.controlSize = .regular
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let getKeyButton = ClosureButton(title: "获取 API Key", symbol: "arrow.up.right.square", tint: .systemBlue) { [weak self] in self?.openKeyConsole() }
        getKeyButton.toolTip = "在浏览器打开当前提供商的 API Key 控制台"
        getKeyButton.translatesAutoresizingMaskIntoConstraints = false

        testButton = ClosureButton(title: "测试连接", symbol: "bolt.horizontal.circle", tint: .controlAccentColor) { [weak self] in self?.testConnection() }
        testButton.controlSize = .regular
        testButton.translatesAutoresizingMaskIntoConstraints = false

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = NSFont.systemFont(ofSize: 11)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.lineBreakMode = .byTruncatingTail
        testStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        testSpinner = NSProgressIndicator()
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        testSpinner.translatesAutoresizingMaskIntoConstraints = false

        let views: [NSView] = [title, subtitle, providerLabel, providerPopup, providerHintLabel, baseLabel, baseField, resetEndpointButton, keyLabel, keyField, modelLabel, modelField, testButton, testSpinner, testStatusLabel, getKeyButton, saveButton]
        for v in views { content.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            providerLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            providerLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            providerLabel.widthAnchor.constraint(equalToConstant: 64),
            providerPopup.centerYAnchor.constraint(equalTo: providerLabel.centerYAnchor),
            providerPopup.leadingAnchor.constraint(equalTo: providerLabel.trailingAnchor, constant: 10),
            providerPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            providerHintLabel.topAnchor.constraint(equalTo: providerPopup.bottomAnchor, constant: 5),
            providerHintLabel.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            providerHintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            baseLabel.topAnchor.constraint(equalTo: providerHintLabel.bottomAnchor, constant: 14),
            baseLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            baseLabel.widthAnchor.constraint(equalToConstant: 64),
            baseField.centerYAnchor.constraint(equalTo: baseLabel.centerYAnchor),
            baseField.leadingAnchor.constraint(equalTo: baseLabel.trailingAnchor, constant: 10),
            baseField.trailingAnchor.constraint(equalTo: resetEndpointButton.leadingAnchor, constant: -6),
            resetEndpointButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            resetEndpointButton.centerYAnchor.constraint(equalTo: baseField.centerYAnchor),

            keyLabel.topAnchor.constraint(equalTo: baseLabel.bottomAnchor, constant: 16),
            keyLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            keyField.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),
            keyField.leadingAnchor.constraint(equalTo: baseField.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: baseField.trailingAnchor),

            modelLabel.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 16),
            modelLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            modelField.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            modelField.leadingAnchor.constraint(equalTo: baseField.leadingAnchor),
            modelField.trailingAnchor.constraint(equalTo: baseField.trailingAnchor),

            testButton.topAnchor.constraint(equalTo: modelField.bottomAnchor, constant: 20),
            testButton.leadingAnchor.constraint(equalTo: baseField.leadingAnchor),
            testSpinner.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            testSpinner.leadingAnchor.constraint(equalTo: testButton.trailingAnchor, constant: 12),
            testSpinner.widthAnchor.constraint(equalToConstant: 16),
            testStatusLabel.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            testStatusLabel.leadingAnchor.constraint(equalTo: testSpinner.trailingAnchor, constant: 8),
            testStatusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            saveButton.topAnchor.constraint(equalTo: testButton.bottomAnchor, constant: 20),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            getKeyButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            getKeyButton.leadingAnchor.constraint(equalTo: baseField.leadingAnchor)
        ])
    }

    // 切换提供商：更新模型预设与端点占位
    // 在浏览器打开当前提供商的 API Key 控制台（便于新用户获取密钥）
    @objc private func openKeyConsole() {
        let urlStr = selectedProvider == "openai"
            ? "https://platform.openai.com/api-keys"
            : "https://console.anthropic.com/settings/keys"
        if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
    }

    // 把端点恢复为当前提供商默认（用户改错端点时一键复位）
    @objc private func resetEndpoint() {
        let openAI = selectedProvider == "openai"
        let def = openAI ? "https://api.openai.com" : "https://api.anthropic.com"
        baseField.stringValue = def
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.stringValue = "已恢复默认端点：\(def)"
    }

    @objc private func providerChanged() {
        let openAI = selectedProvider == "openai"
        providerHintLabel.stringValue = Self.providerHint(openAI: openAI)
        modelField.removeAllItems()
        modelField.addItems(withObjectValues: Self.modelPresets(openAI: openAI))
        baseField.placeholderString = openAI ? "API 端点，默认 https://api.openai.com（兼容端点可改）" : "API 端点，默认 https://api.anthropic.com"
        keyField.placeholderString = openAI ? "API Key（Bearer）" : "API Key（x-api-key）"
        if baseField.stringValue.isEmpty || baseField.stringValue == "https://api.anthropic.com" || baseField.stringValue == "https://api.openai.com" {
            baseField.stringValue = openAI ? "https://api.openai.com" : "https://api.anthropic.com"
        }
        modelField.stringValue = openAI ? "gpt-4o" : "claude-sonnet-4-6"
        updateTestEnabled()
    }

    // 发一条极短 ping 验证 提供商/端点/Key/模型 是否可用（先保存当前填写值）
    func controlTextDidChange(_ obj: Notification) { updateTestEnabled() }

    // 端点与 Key 都非空才允许「测试连接」（避免点了才报错）
    private func updateTestEnabled() {
        let ok = !baseField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        testButton?.isEnabled = ok
    }

    private func testConnection() {
        AIConfig.save(provider: selectedProvider, baseURL: baseField.stringValue, apiKey: keyField.stringValue, model: modelField.stringValue)
        guard AIConfig.isConfigured else {
            testStatusLabel.textColor = .systemRed
            testStatusLabel.stringValue = "请先填写 API Key"
            return
        }
        testButton.isEnabled = false
        testSpinner.startAnimation(nil)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.stringValue = "测试中…"
        AIClient.complete(system: "你是连通性测试，只回复 OK。", user: "ping") { [weak self] text, error in
            guard let self = self else { return }
            self.testButton.isEnabled = true
            self.testSpinner.stopAnimation(nil)
            if text != nil {
                self.testStatusLabel.textColor = .systemGreen
                self.testStatusLabel.stringValue = "✓ 连接成功，模型「\(AIConfig.model)」可用"
            } else {
                self.testStatusLabel.textColor = .systemRed
                self.testStatusLabel.stringValue = "✗ " + (error ?? "连接失败")
            }
        }
    }
}

// 「AI 提示词工作台」：输入 → AI 优化/中译英 → 可编辑结果 → 复制/存为提示词（可关联项目读资料）
final class AIWorkbenchWindowController: NSObject, NSMenuDelegate, NSTextViewDelegate {
    static let shared = AIWorkbenchWindowController()
    private var window: NSWindow!
    private var projectPopup: NSPopUpButton!
    private var contextBadge: NSTextField!
    private var lastSystem: String?   // 上次 AI 动作的 system，供「重新生成」
    private var historySearchField: NSSearchField!
    private var inputTextView: NSTextView!
    private var resultTextView: NSTextView!
    private var statusLabel: NSTextField!
    private var actionButtons: [NSButton] = []
    private var resultActionButtons: [NSButton] = []   // 依赖结果非空才可用的按钮
    private var inputActionButtons: [NSButton] = []     // 依赖输入非空才可用（优化/中译英）
    private var busySpinner: NSProgressIndicator!       // AI 生成中的忙碌指示
    private var morePopup: NSPopUpButton!
    private var clipHistoryPopup: NSPopUpButton!
    private var inputCountLabel: NSTextField!
    private var resultCountLabel: NSTextField!
    private var inputPlaceholder: NSTextField!
    private var resultPlaceholder: NSTextField!
    private var keyMonitor: Any?
    private var projectIds: [String] = []   // 与 popup 项对应（index 0 = 不关联）

    func show(seedText: String = "", projectId: String? = nil) {
        if window == nil { build() }
        // 显式传入则用之，否则沿用上次关联的项目（语音/菜单进入时延续上下文）
        let preselect = projectId ?? UserDefaults.standard.string(forKey: "ai.lastProjectId")
        reloadProjects(select: preselect)
        if !seedText.isEmpty {
            inputTextView.string = seedText
        } else if inputTextView.string.isEmpty,
                  let draft = UserDefaults.standard.string(forKey: "ai.inputDraft"), !draft.isEmpty {
            inputTextView.string = draft   // 恢复上次未处理的输入草稿（跨会话/重启）
        }
        if resultTextView.string.isEmpty,
           let rDraft = UserDefaults.standard.string(forKey: "ai.resultDraft"), !rDraft.isEmpty {
            resultTextView.string = rDraft   // 恢复上次 AI 结果，避免重复调用 API
        }
        updateCounts()
        updateContextHint()
        window.makeKeyAndOrderFront(nil)   // 位置/尺寸由 setFrameAutosaveName 持久化恢复，不再每次居中
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(inputTextView)   // 开窗即聚焦输入区，可直接打字
    }

    private func reloadProjects(select: String?) {
        projectPopup.removeAllItems()
        projectPopup.addItem(withTitle: "（不关联项目）")
        projectIds = [""]
        for p in ProjectStore.shared.projects {
            projectPopup.addItem(withTitle: p.name)
            projectIds.append(p.id)
        }
        if let select = select, let idx = projectIds.firstIndex(of: select) {
            projectPopup.selectItem(at: idx)
        }
    }

    private var selectedProjectId: String? {
        let idx = projectPopup.indexOfSelectedItem
        guard idx > 0, idx < projectIds.count else { return nil }
        return projectIds[idx]
    }

    @objc private func projectChanged() {
        UserDefaults.standard.set(selectedProjectId ?? "", forKey: "ai.lastProjectId")
        updateContextHint()
    }

    // 让用户清楚关联项目后 AI 会读到哪些上下文（statusLabel 临时 + contextBadge 持久）
    private func updateContextHint() {
        var msg: String
        var badgeText: String
        var badgeSymbol: String
        var badgeColor: NSColor
        if let pid = selectedProjectId, let project = ProjectStore.shared.project(id: pid) {
            let bg = project.background.trimmingCharacters(in: .whitespacesAndNewlines).count
            let mat = project.materials.trimmingCharacters(in: .whitespacesAndNewlines).count
            if bg == 0 && mat == 0 {
                msg = "已关联「\(project.name)」：暂无背景/资料，AI 无额外上下文"
                badgeText = "\(project.name) · 无背景/资料"
                badgeColor = .secondaryLabelColor
            } else {
                msg = "已关联「\(project.name)」：背景 \(bg) 字 + 资料 \(mat) 字 将作为 AI 上下文"
                badgeText = "\(project.name) · 背景 \(bg) · 资料 \(mat)"
                badgeColor = .controlAccentColor
            }
            badgeSymbol = "link"
        } else {
            msg = "未关联项目，AI 不读取项目资料"
            badgeText = "未关联项目 · AI 不读项目资料"
            badgeSymbol = "link.badge.plus"
            badgeColor = .tertiaryLabelColor
        }
        if !AIConfig.isConfigured { msg += " · 未配置 API Key" }
        statusLabel.stringValue = msg
        setContextBadge(symbol: badgeSymbol, text: badgeText, color: badgeColor)
    }

    // 持久上下文徽标：SF Symbol + 文字（不会被动作状态覆盖）
    private func setContextBadge(symbol: String, text: String, color: NSColor) {
        guard contextBadge != nil else { return }
        let result = NSMutableAttributedString()
        if let img = tintedSymbolImage(symbol, color: color, pointSize: 11) {
            let attach = NSTextAttachment()
            attach.image = img
            let bounds = NSRect(x: 0, y: -1.5, width: img.size.width, height: img.size.height)
            attach.bounds = bounds
            result.append(NSAttributedString(attachment: attach))
            result.append(NSAttributedString(string: "  "))
        }
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color
        ]))
        contextBadge.attributedStringValue = result
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 640),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AI 提示词工作台"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 520)
        // 记住用户调整的窗口尺寸+位置（跨重启）；仅首次（无保存 frame）居中
        let hadSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame AIWorkbenchWindow") != nil
        window.setFrameAutosaveName("AIWorkbenchWindow")
        if !hadSavedFrame { window.center() }
        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        // 快捷键：Cmd+Return 优化 / Cmd+T 中译英 / Cmd+S 存为提示词（仅工作台为 key window 时响应）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isKeyWindow == true,
                  event.modifierFlags.contains(.command) else { return event }
            switch event.keyCode {
            case 36, 76: self.runAI(.optimize); return nil   // Return / 小键盘 Enter
            case 17: self.runAI(.translate); return nil       // T
            case 1: self.saveResultAsPrompt(); return nil     // S
            case 15: self.regenerateLast(); return nil        // R 重新生成上一动作
            case 45: self.resetSession(); return nil          // N 新会话（清空输入与结果）
            default: return event
            }
        }

        let title = NSTextField(labelWithString: "AI 提示词工作台")
        title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let projectLabel = NSTextField(labelWithString: "关联项目")
        projectLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.translatesAutoresizingMaskIntoConstraints = false
        contextBadge = NSTextField(labelWithString: "")
        contextBadge.lineBreakMode = .byTruncatingTail
        contextBadge.translatesAutoresizingMaskIntoConstraints = false
        projectPopup = NSPopUpButton()
        projectPopup.target = self
        projectPopup.action = #selector(projectChanged)
        projectPopup.translatesAutoresizingMaskIntoConstraints = false

        let settingsButton = ClosureButton(title: "AI 设置", symbol: "gearshape", tint: .controlAccentColor) {
            (NSApp.delegate as? AppDelegate)?.openAISettingsExternally()
        }
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        // 剪贴板历史下拉（pull-down）：列最近复制内容，选中插入输入区
        clipHistoryPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        clipHistoryPopup.addItem(withTitle: "剪贴板历史")
        clipHistoryPopup.menu?.delegate = self
        clipHistoryPopup.translatesAutoresizingMaskIntoConstraints = false

        historySearchField = NSSearchField()
        historySearchField.placeholderString = "搜索历史提示词复用…（回车）"
        historySearchField.target = self
        historySearchField.action = #selector(historySearch)
        historySearchField.translatesAutoresizingMaskIntoConstraints = false

        let (inputPanel, inputTV, inputPH) = makeEditableAIPanel(title: "原始提示词", symbol: "text.cursor", tint: .systemBlue, placeholder: "在此输入或粘贴提示词…（语音/项目/剪贴板也可填入）")
        inputTextView = inputTV
        inputTextView.delegate = self
        inputPlaceholder = inputPH
        inputCountLabel = makeCountLabel()
        inputPanel.addSubview(inputCountLabel)
        let clearInputButton = ClosureButton(title: "清空", symbol: "xmark", tint: .systemGray) { [weak self] in self?.clearInput() }
        clearInputButton.translatesAutoresizingMaskIntoConstraints = false
        inputPanel.addSubview(clearInputButton)
        let (resultPanel, resultTV, resultPH) = makeEditableAIPanel(title: "AI 结果（可编辑）", symbol: "sparkles", tint: .systemPurple, placeholder: "AI 优化 / 中译英 / 扩写… 的结果将显示在此，可编辑")
        resultTextView = resultTV
        resultTextView.delegate = self
        resultPlaceholder = resultPH
        resultCountLabel = makeCountLabel()
        resultPanel.addSubview(resultCountLabel)
        // 结果区右上角：存入资料(追加到关联项目资料) / 替换输入(把结果填回输入继续迭代) / 清空
        let saveToMaterialsButton = ClosureButton(title: "存入资料", symbol: "doc.badge.plus", tint: .systemTeal) { [weak self] in self?.saveResultToMaterials() }
        saveToMaterialsButton.toolTip = "把结果追加到关联项目的「项目资料」"
        let replaceInputButton = ClosureButton(title: "替换输入", symbol: "arrow.up.to.line", tint: .systemBlue) { [weak self] in self?.replaceInputWithResult() }
        replaceInputButton.toolTip = "把结果填回输入区继续迭代"
        let clearResultButton = ClosureButton(title: "清空", symbol: "xmark", tint: .systemGray) { [weak self] in self?.clearResult() }
        for b in [saveToMaterialsButton, replaceInputButton, clearResultButton] { b.translatesAutoresizingMaskIntoConstraints = false; resultPanel.addSubview(b) }
        NSLayoutConstraint.activate([
            clearInputButton.trailingAnchor.constraint(equalTo: inputPanel.trailingAnchor, constant: -12),
            clearInputButton.topAnchor.constraint(equalTo: inputPanel.topAnchor, constant: 12),
            inputCountLabel.trailingAnchor.constraint(equalTo: clearInputButton.leadingAnchor, constant: -10),
            inputCountLabel.centerYAnchor.constraint(equalTo: clearInputButton.centerYAnchor),
            clearResultButton.trailingAnchor.constraint(equalTo: resultPanel.trailingAnchor, constant: -12),
            clearResultButton.topAnchor.constraint(equalTo: resultPanel.topAnchor, constant: 12),
            replaceInputButton.trailingAnchor.constraint(equalTo: clearResultButton.leadingAnchor, constant: -6),
            replaceInputButton.centerYAnchor.constraint(equalTo: clearResultButton.centerYAnchor),
            saveToMaterialsButton.trailingAnchor.constraint(equalTo: replaceInputButton.leadingAnchor, constant: -6),
            saveToMaterialsButton.centerYAnchor.constraint(equalTo: clearResultButton.centerYAnchor),
            resultCountLabel.trailingAnchor.constraint(equalTo: saveToMaterialsButton.leadingAnchor, constant: -10),
            resultCountLabel.centerYAnchor.constraint(equalTo: replaceInputButton.centerYAnchor)
        ])

        let optimizeButton = ClosureButton(title: "AI 优化", symbol: "wand.and.stars", tint: .systemPurple) { [weak self] in self?.runAI(.optimize) }
        optimizeButton.toolTip = "AI 优化（⌘↩）"
        let translateButton = ClosureButton(title: "中译英", symbol: "character.bubble", tint: .systemBlue) { [weak self] in self?.runAI(.translate) }
        translateButton.toolTip = "中译英（⌘T）"
        // 更多动作下拉（pull-down）：扩写/缩写/总结/改语气
        morePopup = NSPopUpButton(frame: .zero, pullsDown: true)
        morePopup.translatesAutoresizingMaskIntoConstraints = false
        morePopup.addItem(withTitle: "更多动作")   // pull-down 首项为标题
        let moreItems = ["英译中", "扩写", "缩写", "总结", "改语气·正式", "改语气·口语"]
        for (i, name) in moreItems.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(moreAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            morePopup.menu?.addItem(item)
        }
        morePopup.menu?.addItem(.separator())
        let customItem = NSMenuItem(title: "自定义指令…", action: #selector(customAction), keyEquivalent: "")
        customItem.target = self
        morePopup.menu?.addItem(customItem)
        let regenItem = NSMenuItem(title: "重新生成上一动作（⌘R）", action: #selector(regenerateLast), keyEquivalent: "")
        regenItem.target = self
        morePopup.menu?.addItem(regenItem)
        morePopup.menu?.addItem(.separator())
        let resetItem = NSMenuItem(title: "新会话（清空输入与结果 ⌘N）", action: #selector(resetSession), keyEquivalent: "")
        resetItem.target = self
        morePopup.menu?.addItem(resetItem)
        let copyButton = ClosureButton(title: "复制结果", symbol: "doc.on.doc", tint: .controlAccentColor) { [weak self] in self?.copyResult() }
        copyButton.toolTip = "复制 AI 结果到剪贴板（同时记入剪贴板历史）"
        let saveButton = ClosureButton(title: "存为提示词", symbol: "bookmark", tint: .systemGreen) { [weak self] in self?.saveResultAsPrompt() }
        saveButton.toolTip = "存为提示词（⌘S）"
        actionButtons = [optimizeButton, translateButton, copyButton, saveButton]
        resultActionButtons = [copyButton, saveButton, saveToMaterialsButton, replaceInputButton]
        inputActionButtons = [optimizeButton, translateButton]   // 依赖输入非空才可用
        for b in actionButtons { b.translatesAutoresizingMaskIntoConstraints = false }
        let actionStack = NSStackView(views: [optimizeButton, translateButton, morePopup, copyButton, saveButton])
        actionStack.orientation = .horizontal
        actionStack.spacing = 8
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        busySpinner = NSProgressIndicator()
        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.isDisplayedWhenStopped = false
        busySpinner.translatesAutoresizingMaskIntoConstraints = false

        let wbViews: [NSView] = [title, projectLabel, projectPopup, contextBadge, historySearchField, clipHistoryPopup, settingsButton, inputPanel, actionStack, resultPanel, statusLabel, busySpinner]
        for v in wbViews { content.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            settingsButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            clipHistoryPopup.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            clipHistoryPopup.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),

            projectLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            projectLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            projectPopup.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            projectPopup.leadingAnchor.constraint(equalTo: projectLabel.trailingAnchor, constant: 10),
            projectPopup.widthAnchor.constraint(equalToConstant: 240),

            historySearchField.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            historySearchField.leadingAnchor.constraint(equalTo: projectPopup.trailingAnchor, constant: 14),
            historySearchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            contextBadge.topAnchor.constraint(equalTo: projectLabel.bottomAnchor, constant: 10),
            contextBadge.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            contextBadge.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            inputPanel.topAnchor.constraint(equalTo: contextBadge.bottomAnchor, constant: 10),
            inputPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            inputPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            inputPanel.heightAnchor.constraint(equalToConstant: 150),

            actionStack.topAnchor.constraint(equalTo: inputPanel.bottomAnchor, constant: 12),
            actionStack.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            actionStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            actionStack.heightAnchor.constraint(equalToConstant: 28),

            resultPanel.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 12),
            resultPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            resultPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            resultPanel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: busySpinner.trailingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            busySpinner.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            busySpinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            busySpinner.widthAnchor.constraint(equalToConstant: 14),
            busySpinner.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private func makeEditableAIPanel(title: String, symbol: String, tint: NSColor, placeholder: String) -> (NSView, NSTextView, NSTextField) {
        let panel = makeGlassEffectView(radius: 16, material: .contentBackground)
        let (badge, _) = makePanelHeader(title: title, symbol: symbol, tint: tint, in: panel)
        let textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)
        let placeholderLabel = makePlaceholderLabel(placeholder)
        panel.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
            placeholderLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 13),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -8)
        ])
        return (panel, textView, placeholderLabel)
    }

    private func makeCountLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "0 字")
        l.font = NSFont.systemFont(ofSize: 10)
        l.textColor = .tertiaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    // 文本编辑时实时更新字数
    func textDidChange(_ notification: Notification) { updateCounts() }

    private func updateCounts() {
        inputCountLabel?.stringValue = "\(inputTextView.string.count) 字"
        resultCountLabel?.stringValue = "\(resultTextView.string.count) 字"
        inputPlaceholder?.isHidden = !inputTextView.string.isEmpty
        resultPlaceholder?.isHidden = !resultTextView.string.isEmpty
        UserDefaults.standard.set(inputTextView.string, forKey: "ai.inputDraft")     // 持久化输入草稿
        UserDefaults.standard.set(resultTextView.string, forKey: "ai.resultDraft")   // 持久化结果草稿
        // 无结果时禁用依赖结果的按钮（复制结果/存为提示词/存入资料/替换输入）
        let hasResult = !resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        resultActionButtons.forEach { $0.isEnabled = hasResult }
        // 无输入时禁用依赖输入的按钮（AI 优化/中译英）；更多动作里的 AI 项由 validateMenuItem 处理
        let hasInput = !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        inputActionButtons.forEach { $0.isEnabled = hasInput }
    }

    // 「更多动作」菜单项按状态自动启停：AI 动作需输入、重新生成需有过动作、新会话恒可用
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasInput = !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch item.action {
        case #selector(moreAction(_:)), #selector(customAction): return hasInput
        case #selector(regenerateLast): return lastSystem != nil
        default: return true
        }
    }

    private enum AIAction { case optimize, translate, translateZh, expand, condense, summarize, toneFormal, toneCasual }

    @objc private func moreAction(_ sender: NSMenuItem) {
        let actions: [AIAction] = [.translateZh, .expand, .condense, .summarize, .toneFormal, .toneCasual]
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        runAI(actions[sender.tag])
    }

    // 剪贴板历史下拉打开前重建菜单
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === clipHistoryPopup.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "剪贴板历史", action: nil, keyEquivalent: "")   // pull-down 首项=标题
        let items = ClipboardStore.items
        if items.isEmpty {
            let empty = NSMenuItem(title: "（暂无记录）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for (i, clip) in items.enumerated() {
            let preview = clip.replacingOccurrences(of: "\n", with: " ")
            let title = preview.count > 48 ? String(preview.prefix(48)) + "…" : preview
            let item = NSMenuItem(title: title, action: #selector(insertClip(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "清空历史", action: #selector(clearClipHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    @objc private func insertClip(_ sender: NSMenuItem) {
        let items = ClipboardStore.items
        guard sender.tag >= 0, sender.tag < items.count else { return }
        inputTextView.string = items[sender.tag]
        updateCounts()
        statusLabel.stringValue = "已从剪贴板历史载入原始提示词"
    }

    @objc private func clearClipHistory() {
        ClipboardStore.clear()
        statusLabel.stringValue = "剪贴板历史已清空"
    }

    private func runAI(_ action: AIAction) {
        var system: String
        switch action {
        case .optimize:
            system = "你是提示词优化专家。在保持原意的前提下，把用户给的提示词改写得更清晰、结构化、便于 AI 准确执行。只输出优化后的提示词本身，不要解释、不要加引号。"
        case .translate:
            system = "你是专业翻译。把用户给的内容准确、自然地翻译成英文。只输出英文译文，不要解释、不要加引号。"
        case .translateZh:
            system = "你是专业翻译。把用户给的内容准确、自然地翻译成简体中文。只输出中文译文，不要解释、不要加引号。"
        case .expand:
            system = "你是写作助手。在保持原意与风格的前提下，把用户内容扩写得更详尽、有细节、有逻辑层次。只输出扩写后的文本，不要解释。"
        case .condense:
            system = "你是写作助手。把用户内容精简浓缩，保留关键信息、去除冗余，更凝练。只输出精简后的文本，不要解释。"
        case .summarize:
            system = "你是总结助手。用简洁的要点或一段话总结用户内容的核心。只输出总结，不要解释、不要寒暄。"
        case .toneFormal:
            system = "你是文字润色助手。把用户内容改写成更正式、专业、书面的语气，保持原意。只输出改写后的文本，不要解释。"
        case .toneCasual:
            system = "你是文字润色助手。把用户内容改写成更轻松、口语、自然的语气，保持原意。只输出改写后的文本，不要解释。"
        }
        runWithSystem(system)
    }

    // 自定义指令：用户一句话描述要 AI 做什么（不限于预设动作）
    @objc private func customAction() {
        let input = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { statusLabel.stringValue = "请先输入原始提示词"; return }
        let alert = NSAlert()
        alert.messageText = "自定义指令"
        alert.informativeText = "用一句话描述你想让 AI 做什么，上方「原始提示词」作为处理对象。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "例如：翻译成日语 / 改写成营销文案 / 提取要点"
        alert.accessoryView = field
        alert.addButton(withTitle: "执行")
        alert.addButton(withTitle: "取消")
        alert.layout(); alert.window.initialFirstResponder = field   // 弹窗即聚焦输入框
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let instruction = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { statusLabel.stringValue = "未输入指令"; return }
        runWithSystem("你是 AI 助手。严格按用户指令处理其提供的内容。指令：\(instruction)。只输出处理后的结果，不要解释、不要寒暄、不要加引号。")
    }

    // 新会话：清空输入与结果（含草稿），开始全新任务
    @objc private func resetSession() {
        inputTextView.string = ""
        resultTextView.string = ""
        lastSystem = nil
        updateCounts()   // 同步字数/占位/草稿(存空)/结果按钮禁用态
        statusLabel.stringValue = "已开始新会话（输入与结果已清空）"
    }

    // 重新生成上一次动作（结果不满意时一键重跑同一动作，沿用当前输入/项目上下文）
    @objc private func regenerateLast() {
        guard let last = lastSystem else { statusLabel.stringValue = "请先执行一次 AI 动作"; return }
        runWithSystem(last)
    }

    // AI 调用核心：拼接项目上下文 + 调 AIClient，结果写入结果区（runAI / customAction / 重新生成 共用）
    private func runWithSystem(_ baseSystem: String) {
        let input = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { statusLabel.stringValue = "请先输入原始提示词"; return }
        guard AIConfig.isConfigured else {
            statusLabel.stringValue = "未配置 API Key，点「AI 设置」"
            return
        }
        lastSystem = baseSystem   // 记住本次动作，供「重新生成」
        var system = baseSystem
        if let pid = selectedProjectId, let project = ProjectStore.shared.project(id: pid) {
            let ctx = [project.background, project.materials].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !ctx.isEmpty { system += "\n\n以下是关联项目「\(project.name)」的背景与资料，供理解上下文参考（不要照抄进结果）：\n\(ctx)" }
        }
        setBusy(true)
        statusLabel.stringValue = "AI 生成中…"
        AIClient.complete(system: system, user: input) { [weak self] text, error in
            guard let self = self else { return }
            self.setBusy(false)
            if let text = text {
                self.resultTextView.string = text
                self.statusLabel.stringValue = "已生成"
            } else {
                self.statusLabel.stringValue = error ?? "生成失败"
            }
            self.updateCounts()   // 同步结果区按钮可用态（成功/失败都刷新）
        }
    }

    private func setBusy(_ busy: Bool) {
        actionButtons.forEach { $0.isEnabled = !busy }
        morePopup?.isEnabled = !busy
        if busy { busySpinner?.startAnimation(nil) } else { busySpinner?.stopAnimation(nil) }
    }

    private func replaceInputWithResult() {
        let text = resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "结果为空"; return }
        inputTextView.string = text
        resultTextView.string = ""
        updateCounts()
        statusLabel.stringValue = "已把结果填回输入区，可继续 AI 处理"
    }

    private func clearInput() {
        inputTextView.string = ""
        updateCounts()
        statusLabel.stringValue = "已清空输入"
    }

    private func clearResult() {
        resultTextView.string = ""
        updateCounts()
        statusLabel.stringValue = "已清空结果"
    }

    private func copyResult() {
        let text = resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "结果为空，无可复制"; return }
        ClipboardStore.copy(text)
        statusLabel.stringValue = "结果已复制到剪贴板（已记入剪贴板历史）"
    }

    // 把 AI 结果追加到关联项目的「项目资料」（构建 AI 产出→项目上下文 的知识闭环）
    private func saveResultToMaterials() {
        let text = resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "结果为空，无可保存"; return }
        guard let pid = selectedProjectId, var project = ProjectStore.shared.project(id: pid) else {
            statusLabel.stringValue = "请先在上方「关联项目」选择项目，结果将追加到其资料"
            return
        }
        let existing = project.materials.trimmingCharacters(in: .whitespacesAndNewlines)
        project.materials = existing.isEmpty ? text : (existing + "\n\n" + text)
        ProjectStore.shared.update(project)
        updateContextHint()
        statusLabel.stringValue = "已把结果追加到项目「\(project.name)」的资料"
    }

    private func saveResultAsPrompt() {
        let text = resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "结果为空，无可保存"; return }
        guard let pid = selectedProjectId, var project = ProjectStore.shared.project(id: pid) else {
            // 无关联项目：一个项目都没有时引导新建并存入（去掉死路），否则提示去上方选择
            if ProjectStore.shared.projects.isEmpty {
                let alert = NSAlert()
                alert.messageText = "新建项目并存入提示词"
                alert.informativeText = "还没有任何项目。输入项目名，把当前结果存为它的第一条提示词。"
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                input.placeholderString = "项目名称"
                alert.accessoryView = input
                alert.addButton(withTitle: "创建并存入")
                alert.addButton(withTitle: "取消")
                alert.layout(); alert.window.initialFirstResponder = input   // 弹窗即聚焦输入框
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { statusLabel.stringValue = "项目名称不能为空，未创建"; return }
                var newProject = ProjectStore.shared.addProject(name: name)
                newProject.prompts.append(ProjectPrompt(text: text))
                ProjectStore.shared.update(newProject)
                reloadProjects(select: newProject.id)
                updateContextHint()
                statusLabel.stringValue = "已新建项目「\(name)」并存入提示词"
            } else {
                statusLabel.stringValue = "请先在上方「关联项目」选择要存入的项目"
            }
            return
        }
        project.prompts.append(ProjectPrompt(text: text))
        ProjectStore.shared.update(project)
        statusLabel.stringValue = "已存入项目「\(project.name)」的提示词库"
    }

    // 历史提示词复用：SQL 跨项目搜索 → 下拉菜单 → 选中填入输入区
    @objc private func historySearch() {
        let query = historySearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { statusLabel.stringValue = "输入关键词搜索历史提示词"; return }
        let results = ProjectStore.shared.searchPrompts(query)
        let menu = NSMenu()
        if results.isEmpty {
            // 与剪贴板历史一致：弹出含禁用提示的菜单，比纯状态栏更易发现
            let empty = NSMenuItem(title: "未找到匹配「\(query)」的历史提示词", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            let hint = NSMenuItem(title: "提示：在项目提示词库点「⭐收藏 / 存为提示词」积累历史", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            statusLabel.stringValue = "未找到匹配「\(query)」的历史提示词"
        } else {
            for (projectName, prompt) in results.prefix(40) {
                let star = prompt.favorite ? "⭐ " : ""
                let preview = prompt.text.replacingOccurrences(of: "\n", with: " ")
                let clipped = preview.count > 52 ? String(preview.prefix(52)) + "…" : preview
                let item = NSMenuItem(title: "\(star)[\(projectName)] \(clipped)", action: #selector(pickHistoryPrompt(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = prompt.text
                menu.addItem(item)
            }
            statusLabel.stringValue = "命中 \(results.count) 条，选择一条填入输入区"
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: historySearchField.bounds.height + 4), in: historySearchField)
    }

    @objc private func pickHistoryPrompt(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        inputTextView.string = text
        updateCounts()
        statusLabel.stringValue = "已载入历史提示词，可继续 AI 优化 / 中译英 / 复制"
    }
}

// 「语音输入」配置页（嵌入侧边栏模块）：快捷键说明 + 权限状态/引导 + AI 矫正开关 + 打开悬浮窗
final class VoiceSettingsController: NSObject {
    let moduleView = NSView()
    private var built = false
    private var permissionLabel: NSTextField!
    private var permissionButton: ClosureButton!
    private var pendingSettingsURL: String?
    private var hotkeyRecordButton: NSButton!
    private var hotkeyMonitor: Any?

    func activate() {
        if !built {
            moduleView.translatesAutoresizingMaskIntoConstraints = false
            buildUI(into: moduleView)
            built = true
        }
        refreshPermission()
    }

    private func buildUI(into content: NSView) {
        let title = NSTextField(labelWithString: "语音输入")
        title.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "语音转文字 → 可编辑/AI 矫正 → 进剪贴板或粘贴到前台输入框（非输入法）")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // 卡片①：唤出方式（全局快捷键可自定义）
        let hotkeyPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (hotkeyBadge, _) = makePanelHeader(title: "唤出方式", symbol: "command", tint: .systemBlue, in: hotkeyPanel)
        let hotkeyText = NSTextField(labelWithString: "全局快捷键（任意 App 中唤出/隐藏悬浮面板）")
        hotkeyText.font = NSFont.systemFont(ofSize: 13)
        hotkeyText.translatesAutoresizingMaskIntoConstraints = false
        hotkeyRecordButton = NSButton(title: VoiceFloatingController.hotKeyLabel, target: self, action: #selector(startRecordHotkey))
        hotkeyRecordButton.bezelStyle = .rounded
        hotkeyRecordButton.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        hotkeyRecordButton.translatesAutoresizingMaskIntoConstraints = false
        let openButton = ClosureButton(title: "打开语音悬浮窗", symbol: "mic.fill", tint: .systemRed) {
            VoiceFloatingController.shared.show()
        }
        openButton.controlSize = .large
        openButton.translatesAutoresizingMaskIntoConstraints = false
        hotkeyPanel.addSubview(hotkeyText); hotkeyPanel.addSubview(hotkeyRecordButton); hotkeyPanel.addSubview(openButton)

        // 卡片②：权限状态
        let permPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (permBadge, _) = makePanelHeader(title: "权限状态", symbol: "lock.shield", tint: .systemOrange, in: permPanel)
        permissionLabel = NSTextField(labelWithString: "")
        permissionLabel.font = NSFont.systemFont(ofSize: 13)
        permissionLabel.lineBreakMode = .byWordWrapping
        permissionLabel.maximumNumberOfLines = 3
        permissionLabel.translatesAutoresizingMaskIntoConstraints = false
        let refreshButton = ClosureButton(title: "刷新", symbol: "arrow.clockwise", tint: .controlAccentColor) { [weak self] in self?.refreshPermission() }
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        permissionButton = ClosureButton(title: "去系统设置", symbol: "gearshape", tint: .systemOrange) { [weak self] in self?.openSettings() }
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        permissionButton.isHidden = true
        permPanel.addSubview(permissionLabel); permPanel.addSubview(refreshButton); permPanel.addSubview(permissionButton)

        // 卡片③：识别语言
        let langPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (langBadge, _) = makePanelHeader(title: "识别语言", symbol: "globe", tint: .systemTeal, in: langPanel)
        let langText = NSTextField(labelWithString: "语音转文字使用的识别语言（SFSpeechRecognizer）")
        langText.font = NSFont.systemFont(ofSize: 13)
        langText.translatesAutoresizingMaskIntoConstraints = false
        let langPopup = NSPopUpButton()
        for (name, _) in VoiceSettingsController.locales { langPopup.addItem(withTitle: name) }
        let currentLocale = UserDefaults.standard.string(forKey: "voice.locale") ?? "zh-CN"
        if let idx = VoiceSettingsController.locales.firstIndex(where: { $0.1 == currentLocale }) { langPopup.selectItem(at: idx) }
        langPopup.target = self
        langPopup.action = #selector(changeLocale(_:))
        langPopup.translatesAutoresizingMaskIntoConstraints = false
        langPanel.addSubview(langText); langPanel.addSubview(langPopup)

        // 卡片④：AI 矫正
        let aiPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (aiBadge, _) = makePanelHeader(title: "AI 矫正", symbol: "wand.and.stars", tint: .systemPurple, in: aiPanel)
        let aiText = NSTextField(labelWithString: "录音停止后自动用 AI 矫正转写（标点/错别字/识别错误）")
        aiText.font = NSFont.systemFont(ofSize: 13)
        aiText.lineBreakMode = .byWordWrapping
        aiText.maximumNumberOfLines = 2
        aiText.translatesAutoresizingMaskIntoConstraints = false
        let autoSwitch = NSSwitch()
        autoSwitch.state = UserDefaults.standard.bool(forKey: "voice.autoCorrect") ? .on : .off
        autoSwitch.target = self
        autoSwitch.action = #selector(toggleAutoCorrect(_:))
        autoSwitch.translatesAutoresizingMaskIntoConstraints = false
        let aiHint = NSTextField(labelWithString: "需在「AI 助手 → AI 设置」配置 API Key")
        aiHint.font = NSFont.systemFont(ofSize: 11)
        aiHint.textColor = .tertiaryLabelColor
        aiHint.translatesAutoresizingMaskIntoConstraints = false
        aiPanel.addSubview(aiText); aiPanel.addSubview(autoSwitch); aiPanel.addSubview(aiHint)

        let cards: [NSView] = [title, subtitle, hotkeyPanel, permPanel, langPanel, aiPanel]
        for v in cards { content.addSubview(v) }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            hotkeyPanel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            hotkeyPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hotkeyPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hotkeyPanel.heightAnchor.constraint(equalToConstant: 124),
            hotkeyText.leadingAnchor.constraint(equalTo: hotkeyPanel.leadingAnchor, constant: 16),
            hotkeyText.topAnchor.constraint(equalTo: hotkeyBadge.bottomAnchor, constant: 12),
            hotkeyRecordButton.leadingAnchor.constraint(equalTo: hotkeyPanel.leadingAnchor, constant: 16),
            hotkeyRecordButton.topAnchor.constraint(equalTo: hotkeyText.bottomAnchor, constant: 10),
            hotkeyRecordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            openButton.trailingAnchor.constraint(equalTo: hotkeyPanel.trailingAnchor, constant: -16),
            openButton.centerYAnchor.constraint(equalTo: hotkeyRecordButton.centerYAnchor),

            permPanel.topAnchor.constraint(equalTo: hotkeyPanel.bottomAnchor, constant: 14),
            permPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            permPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            permPanel.heightAnchor.constraint(equalToConstant: 120),
            refreshButton.trailingAnchor.constraint(equalTo: permPanel.trailingAnchor, constant: -14),
            refreshButton.topAnchor.constraint(equalTo: permPanel.topAnchor, constant: 12),
            permissionLabel.leadingAnchor.constraint(equalTo: permPanel.leadingAnchor, constant: 16),
            permissionLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),
            permissionLabel.topAnchor.constraint(equalTo: permBadge.bottomAnchor, constant: 12),
            permissionButton.leadingAnchor.constraint(equalTo: permPanel.leadingAnchor, constant: 16),
            permissionButton.bottomAnchor.constraint(equalTo: permPanel.bottomAnchor, constant: -14),

            langPanel.topAnchor.constraint(equalTo: permPanel.bottomAnchor, constant: 14),
            langPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            langPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            langPanel.heightAnchor.constraint(equalToConstant: 92),
            langText.leadingAnchor.constraint(equalTo: langPanel.leadingAnchor, constant: 16),
            langText.topAnchor.constraint(equalTo: langBadge.bottomAnchor, constant: 14),
            langPopup.trailingAnchor.constraint(equalTo: langPanel.trailingAnchor, constant: -16),
            langPopup.centerYAnchor.constraint(equalTo: langText.centerYAnchor),
            langPopup.widthAnchor.constraint(equalToConstant: 180),

            aiPanel.topAnchor.constraint(equalTo: langPanel.bottomAnchor, constant: 14),
            aiPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            aiPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            aiPanel.heightAnchor.constraint(equalToConstant: 110),
            autoSwitch.trailingAnchor.constraint(equalTo: aiPanel.trailingAnchor, constant: -16),
            autoSwitch.centerYAnchor.constraint(equalTo: aiText.centerYAnchor),
            aiText.leadingAnchor.constraint(equalTo: aiPanel.leadingAnchor, constant: 16),
            aiText.topAnchor.constraint(equalTo: aiBadge.bottomAnchor, constant: 14),
            aiText.trailingAnchor.constraint(equalTo: autoSwitch.leadingAnchor, constant: -12),
            aiHint.leadingAnchor.constraint(equalTo: aiText.leadingAnchor),
            aiHint.topAnchor.constraint(equalTo: aiText.bottomAnchor, constant: 8)
        ])
    }

    // 识别语言（显示名, locale 标识）
    static let locales: [(String, String)] = [
        ("中文（普通话）", "zh-CN"), ("English (US)", "en-US"),
        ("日本語", "ja-JP"), ("한국어", "ko-KR"), ("中文（粤语）", "yue-CN")
    ]

    @objc private func toggleAutoCorrect(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "voice.autoCorrect")
    }

    @objc private func changeLocale(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < VoiceSettingsController.locales.count else { return }
        UserDefaults.standard.set(VoiceSettingsController.locales[idx].1, forKey: "voice.locale")
    }

    // MARK: - 全局快捷键录制

    @objc private func startRecordHotkey() {
        if hotkeyMonitor != nil { endRecordHotkey(); return }
        hotkeyRecordButton.title = "请按下组合键…（Esc 取消）"
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureHotkey(event)
            return nil   // 录制中吞掉按键
        }
    }

    private func captureHotkey(_ event: NSEvent) {
        if event.keyCode == 53 { endRecordHotkey(); return }   // Esc 取消
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            hotkeyRecordButton.title = "需含 ⌘/⌥/⌃，请重按"
            return
        }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        let label = VoiceSettingsController.hotkeyDisplay(flags: flags, keyCode: event.keyCode, chars: event.charactersIgnoringModifiers ?? "")
        let d = UserDefaults.standard
        d.set(Int(event.keyCode), forKey: "voice.hotKeyCode")
        d.set(Int(carbon), forKey: "voice.hotKeyMods")
        d.set(label, forKey: "voice.hotKeyLabel")
        VoiceFloatingController.shared.reregisterHotKey()
        endRecordHotkey()
    }

    private func endRecordHotkey() {
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
        hotkeyRecordButton.title = VoiceFloatingController.hotKeyLabel
    }

    static func hotkeyDisplay(flags: NSEvent.ModifierFlags, keyCode: UInt16, chars: String) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName(keyCode: keyCode, chars: chars)
    }

    static func keyName(keyCode: UInt16, chars: String) -> String {
        let map: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let n = map[keyCode] { return n }
        let c = chars.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? "Key\(keyCode)" : c.uppercased()
    }

    private func refreshPermission() {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        func speechText(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
            switch s { case .authorized: return "已授权"; case .denied: return "已拒绝"; case .restricted: return "受限"; default: return "未决定（首次录音时申请）" }
        }
        func micText(_ s: AVAuthorizationStatus) -> String {
            switch s { case .authorized: return "已授权"; case .denied: return "已拒绝"; case .restricted: return "受限"; default: return "未决定（首次录音时申请）" }
        }
        permissionLabel.stringValue = "语音识别：\(speechText(speech))\n麦克风：\(micText(mic))"
        if speech == .denied || speech == .restricted {
            pendingSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            permissionButton.isHidden = false
        } else if mic == .denied || mic == .restricted {
            pendingSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            permissionButton.isHidden = false
        } else {
            permissionButton.isHidden = true
        }
    }

    private func openSettings() {
        if let s = pendingSettingsURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

// 「项目管理」模块：项目列表 + 背景/资料编辑 + 提示词库（收藏/复用/删除）
final class ProjectWindowController: NSObject, NSTextViewDelegate, NSSearchFieldDelegate {
    let moduleView = NSView()
    private var built = false
    private var projectListStack: NSStackView!
    private var projectFilterField: NSSearchField!
    private var projectFilter: String = ""
    private var nameField: NSTextField!
    private var backgroundTextView: NSTextView!
    private var materialsTextView: NSTextView!
    private var backgroundCountLabel: NSTextField!
    private var materialsCountLabel: NSTextField!
    private var promptCountLabel: NSTextField!
    private var promptsStack: NSStackView!
    private var promptSearchField: NSSearchField!
    private var statusLabel: NSTextField!
    private var detailViews: [NSView] = []      // 选中项目后才显示的详情控件
    private var emptyStateView: NSStackView!    // 未选项目时的居中占位
    private var rowButtons: [NSButton] = []
    private var selectedProjectId: String?

    func activate() {
        if !built {
            moduleView.translatesAutoresizingMaskIntoConstraints = false
            buildUI(into: moduleView)
            built = true
        }
        ProjectStore.shared.load()
        if selectedProjectId == nil { selectedProjectId = ProjectStore.shared.projects.first?.id }
        reloadProjectList()
        loadDetail()
    }

    private func buildUI(into content: NSView) {
        let title = NSTextField(labelWithString: "项目管理")
        title.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let newButton = ClosureButton(title: "新增项目", symbol: "plus", tint: .controlAccentColor) { [weak self] in self?.newProject() }
        newButton.controlSize = .regular
        newButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        newButton.translatesAutoresizingMaskIntoConstraints = false

        let exportButton = ClosureButton(title: "导出", symbol: "square.and.arrow.up", tint: .systemGray) { [weak self] in self?.exportProjects() }
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        let importButton = ClosureButton(title: "导入", symbol: "square.and.arrow.down", tint: .systemGray) { [weak self] in self?.importProjects() }
        importButton.translatesAutoresizingMaskIntoConstraints = false

        // 左：项目列表
        let listPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (listBadge, _) = makePanelHeader(title: "项目", symbol: "folder.fill", tint: .systemBlue, in: listPanel)
        projectFilterField = NSSearchField()
        projectFilterField.placeholderString = "筛选项目…"
        projectFilterField.controlSize = .small
        projectFilterField.font = NSFont.systemFont(ofSize: 11)
        projectFilterField.delegate = self
        projectFilterField.translatesAutoresizingMaskIntoConstraints = false
        listPanel.addSubview(projectFilterField)
        projectListStack = NSStackView()
        projectListStack.orientation = .vertical
        projectListStack.spacing = 4
        projectListStack.alignment = .leading
        projectListStack.translatesAutoresizingMaskIntoConstraints = false
        let listScroll = NSScrollView()
        listScroll.documentView = projectListStack
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listPanel.addSubview(listScroll)

        // 右：详情
        nameField = NSTextField()
        nameField.placeholderString = "项目名称"
        nameField.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = ClosureButton(title: "保存", symbol: "checkmark.circle", tint: .systemGreen) { [weak self] in self?.saveCurrent() }
        saveButton.controlSize = .regular
        saveButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let copyMDButton = ClosureButton(title: "复制 MD", symbol: "doc.richtext", tint: .systemBlue) { [weak self] in self?.copyProjectAsMarkdown() }
        copyMDButton.controlSize = .regular
        copyMDButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        copyMDButton.toolTip = "把当前项目（背景/资料/提示词）复制为 Markdown"
        copyMDButton.translatesAutoresizingMaskIntoConstraints = false

        let (bgPanel, bgTV, bgCount) = makeEditableTextPanel(title: "背景信息", symbol: "text.alignleft", tint: .systemOrange)
        backgroundTextView = bgTV
        backgroundCountLabel = bgCount
        let (matPanel, matTV, matCount) = makeEditableTextPanel(title: "项目资料", symbol: "doc.text.fill", tint: .systemTeal)
        materialsTextView = matTV
        materialsCountLabel = matCount

        let promptsPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (_, promptsTitle) = makePanelHeader(title: "提示词库", symbol: "text.quote", tint: .systemPurple, in: promptsPanel)
        promptCountLabel = NSTextField(labelWithString: "")
        promptCountLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        promptCountLabel.textColor = .tertiaryLabelColor
        promptCountLabel.translatesAutoresizingMaskIntoConstraints = false
        promptsPanel.addSubview(promptCountLabel)
        NSLayoutConstraint.activate([
            promptCountLabel.leadingAnchor.constraint(equalTo: promptsTitle.trailingAnchor, constant: 8),
            promptCountLabel.centerYAnchor.constraint(equalTo: promptsTitle.centerYAnchor)
        ])
        let addPromptButton = ClosureButton(title: "添加提示词", symbol: "plus", tint: .systemPurple) { [weak self] in self?.addPrompt() }
        addPromptButton.translatesAutoresizingMaskIntoConstraints = false
        promptsPanel.addSubview(addPromptButton)
        let copyAllButton = ClosureButton(title: "全部复制", symbol: "doc.on.doc.fill", tint: .controlAccentColor) { [weak self] in self?.copyAllPrompts() }
        copyAllButton.translatesAutoresizingMaskIntoConstraints = false
        promptsPanel.addSubview(copyAllButton)
        promptSearchField = NSSearchField()
        promptSearchField.placeholderString = "跨项目搜索历史提示词复用…（回车）"
        promptSearchField.target = self
        promptSearchField.action = #selector(promptSearch)
        promptSearchField.controlSize = .small
        promptSearchField.font = NSFont.systemFont(ofSize: 11)
        promptSearchField.translatesAutoresizingMaskIntoConstraints = false
        promptsPanel.addSubview(promptSearchField)
        promptsStack = NSStackView()
        promptsStack.orientation = .vertical
        promptsStack.spacing = 6
        promptsStack.alignment = .leading
        promptsStack.translatesAutoresizingMaskIntoConstraints = false
        let promptsScroll = NSScrollView()
        promptsScroll.documentView = promptsStack
        promptsScroll.hasVerticalScroller = true
        promptsScroll.drawsBackground = false
        promptsScroll.borderType = .noBorder
        promptsScroll.translatesAutoresizingMaskIntoConstraints = false
        promptsPanel.addSubview(promptsScroll)

        detailViews = [nameField, saveButton, copyMDButton, bgPanel, matPanel, promptsPanel, addPromptButton, promptSearchField, copyAllButton]

        // 未选项目时的居中空状态占位
        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        let emptyTitle = NSTextField(labelWithString: "还没有选择项目")
        emptyTitle.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        let emptyHint = NSTextField(labelWithString: "新增一个项目，或从左侧选择一个开始\n管理背景信息、项目资料与提示词库")
        emptyHint.font = NSFont.systemFont(ofSize: 12)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        emptyHint.maximumNumberOfLines = 2
        let emptyButton = ClosureButton(title: "新增项目", symbol: "plus", tint: .controlAccentColor) { [weak self] in self?.newProject() }
        emptyButton.controlSize = .regular
        emptyStateView = NSStackView(views: [emptyIcon, emptyTitle, emptyHint, emptyButton])
        emptyStateView.orientation = .vertical
        emptyStateView.spacing = 12
        emptyStateView.alignment = .centerX
        emptyStateView.setCustomSpacing(8, after: emptyTitle)
        emptyStateView.setCustomSpacing(18, after: emptyHint)
        emptyStateView.isHidden = true
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let topViews: [NSView] = [title, statusLabel, newButton, exportButton, importButton, listPanel, nameField, saveButton, copyMDButton, bgPanel, matPanel, promptsPanel, emptyStateView]
        for view in topViews {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            newButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            newButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            importButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -8),
            exportButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -6),
            statusLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -12),

            listPanel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            listPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            listPanel.widthAnchor.constraint(equalToConstant: 240),
            listPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            projectFilterField.topAnchor.constraint(equalTo: listBadge.bottomAnchor, constant: 8),
            projectFilterField.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 12),
            projectFilterField.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -12),
            listScroll.topAnchor.constraint(equalTo: projectFilterField.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 12),
            listScroll.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -12),
            listScroll.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: -12),
            projectListStack.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            projectListStack.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            projectListStack.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            projectListStack.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),

            nameField.topAnchor.constraint(equalTo: listPanel.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: copyMDButton.leadingAnchor, constant: -10),
            copyMDButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            copyMDButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            saveButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            bgPanel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            bgPanel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            bgPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bgPanel.heightAnchor.constraint(equalToConstant: 132),

            matPanel.topAnchor.constraint(equalTo: bgPanel.bottomAnchor, constant: 12),
            matPanel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            matPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            matPanel.heightAnchor.constraint(equalToConstant: 132),

            emptyStateView.centerXAnchor.constraint(equalTo: bgPanel.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.leadingAnchor),

            promptsPanel.topAnchor.constraint(equalTo: matPanel.bottomAnchor, constant: 12),
            promptsPanel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            promptsPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            promptsPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            addPromptButton.topAnchor.constraint(equalTo: promptsPanel.topAnchor, constant: 12),
            addPromptButton.trailingAnchor.constraint(equalTo: promptsPanel.trailingAnchor, constant: -14),
            promptSearchField.centerYAnchor.constraint(equalTo: addPromptButton.centerYAnchor),
            promptSearchField.trailingAnchor.constraint(equalTo: addPromptButton.leadingAnchor, constant: -10),
            promptSearchField.widthAnchor.constraint(equalToConstant: 240),
            copyAllButton.centerYAnchor.constraint(equalTo: addPromptButton.centerYAnchor),
            copyAllButton.trailingAnchor.constraint(equalTo: promptSearchField.leadingAnchor, constant: -8),
            promptsScroll.topAnchor.constraint(equalTo: addPromptButton.bottomAnchor, constant: 8),
            promptsScroll.leadingAnchor.constraint(equalTo: promptsPanel.leadingAnchor, constant: 12),
            promptsScroll.trailingAnchor.constraint(equalTo: promptsPanel.trailingAnchor, constant: -12),
            promptsScroll.bottomAnchor.constraint(equalTo: promptsPanel.bottomAnchor, constant: -12),
            promptsStack.topAnchor.constraint(equalTo: promptsScroll.contentView.topAnchor),
            promptsStack.leadingAnchor.constraint(equalTo: promptsScroll.contentView.leadingAnchor),
            promptsStack.trailingAnchor.constraint(equalTo: promptsScroll.contentView.trailingAnchor),
            promptsStack.widthAnchor.constraint(equalTo: promptsScroll.contentView.widthAnchor)
        ])
    }

    private func makeEditableTextPanel(title: String, symbol: String, tint: NSColor) -> (NSView, NSTextView, NSTextField) {
        let panel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (badge, _) = makePanelHeader(title: title, symbol: symbol, tint: tint, in: panel)
        let textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)
        let countLabel = NSTextField(labelWithString: "0 字")
        countLabel.font = NSFont.systemFont(ofSize: 10)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(countLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
            countLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            countLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return (panel, textView, countLabel)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        if tv === backgroundTextView { backgroundCountLabel?.stringValue = "\(backgroundTextView.string.count) 字" }
        else if tv === materialsTextView { materialsCountLabel?.stringValue = "\(materialsTextView.string.count) 字" }
    }

    private func updateDetailCounts() {
        backgroundCountLabel?.stringValue = "\(backgroundTextView.string.count) 字"
        materialsCountLabel?.stringValue = "\(materialsTextView.string.count) 字"
    }

    // 项目筛选框实时过滤列表
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === projectFilterField else { return }
        projectFilter = projectFilterField.stringValue.trimmingCharacters(in: .whitespaces)
        reloadProjectList()
    }

    // MARK: - 列表与详情

    private func reloadProjectList() {
        projectListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = ProjectStore.shared.projects
        let projects = projectFilter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(projectFilter) }
        if projects.isEmpty {
            let empty = NSTextField(labelWithString: all.isEmpty ? "（暂无项目，点右上「新增项目」）" : "（无匹配「\(projectFilter)」的项目）")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 2
            projectListStack.addArrangedSubview(empty)
            return
        }
        for project in projects {
            let row = makeProjectRow(project)
            projectListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: projectListStack.widthAnchor).isActive = true
        }
    }

    private func makeProjectRow(_ project: Project) -> NSView {
        let selected = project.id == selectedProjectId
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 7
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .clear).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: project.name)
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        nameLabel.textColor = selected ? .controlAccentColor : .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(nameLabel)

        let dup = ClosureButton(title: "", symbol: "plus.square.on.square", tint: .systemGray) { [weak self] in self?.duplicateProject(project.id) }
        dup.toolTip = "另存为副本"
        dup.translatesAutoresizingMaskIntoConstraints = false
        rowButtons.append(dup)
        row.addSubview(dup)

        let delete = ClosureButton(title: "", symbol: "trash", tint: .systemRed) { [weak self] in self?.deleteProject(project.id) }
        delete.translatesAutoresizingMaskIntoConstraints = false
        rowButtons.append(delete)
        row.addSubview(delete)

        let click = NSClickGestureRecognizer(target: self, action: #selector(projectRowClicked(_:)))
        row.addGestureRecognizer(click)
        objc_setAssociatedObject(row, &ProjectWindowController.rowIdKey, project.id, .OBJC_ASSOCIATION_RETAIN)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 30),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dup.leadingAnchor, constant: -6),
            dup.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -4),
            dup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            delete.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            delete.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func duplicateProject(_ id: String) {
        guard let copy = ProjectStore.shared.duplicate(id: id) else { statusLabel.stringValue = "复制失败"; return }
        selectedProjectId = copy.id
        reloadProjectList()
        loadDetail()
        statusLabel.stringValue = "已创建副本：\(copy.name)"
    }

    private static var rowIdKey: UInt8 = 0

    @objc private func projectRowClicked(_ sender: NSClickGestureRecognizer) {
        guard let row = sender.view,
              let id = objc_getAssociatedObject(row, &ProjectWindowController.rowIdKey) as? String else { return }
        saveCurrent()           // 切换前自动保存当前编辑
        selectedProjectId = id
        reloadProjectList()
        loadDetail()
    }

    private func loadDetail() {
        guard let id = selectedProjectId, let project = ProjectStore.shared.project(id: id) else {
            nameField.stringValue = ""
            backgroundTextView.string = ""
            materialsTextView.string = ""
            updateDetailCounts()
            promptCountLabel?.stringValue = ""
            promptsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            setDetailEnabled(false)
            statusLabel.stringValue = "未选择项目"
            return
        }
        setDetailEnabled(true)
        nameField.stringValue = project.name
        backgroundTextView.string = project.background
        materialsTextView.string = project.materials
        updateDetailCounts()
        reloadPrompts(project)
        statusLabel.stringValue = "已选择：\(project.name)"
    }

    private func setDetailEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        backgroundTextView.isEditable = enabled
        materialsTextView.isEditable = enabled
        // 未选项目时隐藏详情、显示居中空状态占位，避免右侧空荡
        detailViews.forEach { $0.isHidden = !enabled }
        emptyStateView.isHidden = enabled
    }

    private func reloadPrompts(_ project: Project) {
        promptsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let favs = project.prompts.filter { $0.favorite }.count
        promptCountLabel?.stringValue = project.prompts.isEmpty ? "" : (favs > 0 ? "\(project.prompts.count) 条 · \(favs) ⭐" : "\(project.prompts.count) 条")
        guard !project.prompts.isEmpty else {
            let empty = NSTextField(labelWithString: "（暂无提示词，点「添加提示词」或从语音/AI 优化保存）")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            promptsStack.addArrangedSubview(empty)
            return
        }
        // 收藏优先
        let ordered = project.prompts.enumerated().sorted { ($0.element.favorite ? 0 : 1, $0.offset) < ($1.element.favorite ? 0 : 1, $1.offset) }
        for (index, prompt) in ordered {
            let row = makePromptRow(prompt, index: index)
            promptsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: promptsStack.widthAnchor).isActive = true
        }
    }

    private func makePromptRow(_ prompt: ProjectPrompt, index: Int) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.10).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let textLabel = NSTextField(labelWithString: prompt.text)
        textLabel.font = NSFont.systemFont(ofSize: 11)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 2
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textLabel)

        let favButton = ClosureButton(title: "", symbol: prompt.favorite ? "star.fill" : "star", tint: .systemYellow) { [weak self] in self?.toggleFavorite(promptId: prompt.id) }
        let aiButton = ClosureButton(title: "AI", symbol: "wand.and.stars", tint: .systemPurple) { [weak self] in
            AIWorkbenchWindowController.shared.show(seedText: prompt.text, projectId: self?.selectedProjectId)
        }
        let copyButton = ClosureButton(title: "复制", symbol: "doc.on.doc", tint: .controlAccentColor) { [weak self] in self?.copyPrompt(prompt.text) }
        let editButton = ClosureButton(title: "", symbol: "pencil", tint: .systemBlue) { [weak self] in self?.editPrompt(promptId: prompt.id, current: prompt.text) }
        editButton.toolTip = "编辑提示词"
        let delButton = ClosureButton(title: "", symbol: "trash", tint: .systemRed) { [weak self] in self?.deletePrompt(promptId: prompt.id) }
        for b in [favButton, aiButton, copyButton, editButton, delButton] { b.translatesAutoresizingMaskIntoConstraints = false; rowButtons.append(b); row.addSubview(b) }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            textLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            textLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            textLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: favButton.leadingAnchor, constant: -8),
            delButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            delButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: delButton.leadingAnchor, constant: -6),
            editButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            aiButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
            aiButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            favButton.trailingAnchor.constraint(equalTo: aiButton.leadingAnchor, constant: -6),
            favButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func editPrompt(promptId: String, current: String) {
        guard let pid = selectedProjectId, var project = ProjectStore.shared.project(id: pid),
              let idx = project.prompts.firstIndex(where: { $0.id == promptId }) else { return }
        let alert = NSAlert()
        alert.messageText = "编辑提示词"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        input.stringValue = current
        input.usesSingleLineMode = false
        input.cell?.wraps = true
        input.cell?.isScrollable = false
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.layout(); alert.window.initialFirstResponder = input   // 弹窗即聚焦输入框
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "提示词内容不能为空"; return }
        project.prompts[idx].text = text
        ProjectStore.shared.update(project)
        reloadPrompts(project)
        statusLabel.stringValue = "已更新提示词"
    }

    // MARK: - 操作

    private func newProject() {
        let alert = NSAlert()
        alert.messageText = "新增项目"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "项目名称"
        alert.accessoryView = input
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        alert.layout(); alert.window.initialFirstResponder = input   // 弹窗即聚焦输入框
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusLabel.stringValue = "项目名称不能为空，未创建"; return }
        let project = ProjectStore.shared.addProject(name: name)
        selectedProjectId = project.id
        reloadProjectList()
        loadDetail()
        statusLabel.stringValue = "已新增项目：\(project.name)"
    }

    private func exportProjects() {
        guard !ProjectStore.shared.projects.isEmpty, let data = ProjectStore.shared.exportJSON() else {
            statusLabel.stringValue = "暂无项目可导出"; return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "projects-export.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            statusLabel.stringValue = "已导出 \(ProjectStore.shared.projects.count) 个项目"
        } catch {
            statusLabel.stringValue = "导出失败：\(error.localizedDescription)"
        }
    }

    private func importProjects() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let count = ProjectStore.shared.importJSON(data)
        guard count > 0 else { statusLabel.stringValue = "导入失败或文件无有效项目"; return }
        if selectedProjectId == nil { selectedProjectId = ProjectStore.shared.projects.first?.id }
        reloadProjectList()
        loadDetail()
        statusLabel.stringValue = "已导入 \(count) 个项目（追加，不覆盖现有）"
    }

    // 把当前项目导出为 Markdown（名称/背景/资料/提示词）到剪贴板，便于分享/贴文档
    private func copyProjectAsMarkdown() {
        guard let id = selectedProjectId, let project = ProjectStore.shared.project(id: id) else {
            statusLabel.stringValue = "请先选择一个项目"; return
        }
        var md = "# \(project.name)\n"
        let bg = project.background.trimmingCharacters(in: .whitespacesAndNewlines)
        let mat = project.materials.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bg.isEmpty { md += "\n## 背景信息\n\n\(bg)\n" }
        if !mat.isEmpty { md += "\n## 项目资料\n\n\(mat)\n" }
        if !project.prompts.isEmpty {
            md += "\n## 提示词库（\(project.prompts.count)）\n\n"
            for p in project.prompts {
                let star = p.favorite ? "⭐ " : ""
                md += "- \(star)\(p.text.replacingOccurrences(of: "\n", with: " "))\n"
            }
        }
        copyPrompt(md)
        statusLabel.stringValue = "已复制项目「\(project.name)」为 Markdown 到剪贴板"
    }

    private func saveCurrent() {
        guard let id = selectedProjectId, var project = ProjectStore.shared.project(id: id) else { return }
        let nameWasEmpty = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        project.name = nameWasEmpty ? project.name : nameField.stringValue
        project.background = backgroundTextView.string
        project.materials = materialsTextView.string
        ProjectStore.shared.update(project)
        if nameWasEmpty { nameField.stringValue = project.name }   // 回填原名，避免输入框留空误导
        reloadProjectList()
        statusLabel.stringValue = nameWasEmpty ? "项目名不能为空，已保留原名称「\(project.name)」（背景/资料已保存）" : "已保存：\(project.name)"
    }

    private func deleteProject(_ id: String) {
        guard let project = ProjectStore.shared.project(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "删除项目「\(project.name)」？"
        alert.informativeText = "项目的背景、资料、提示词都会被删除，不可恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProjectStore.shared.delete(id: id)
        if selectedProjectId == id { selectedProjectId = ProjectStore.shared.projects.first?.id }
        reloadProjectList()
        loadDetail()
    }

    private func addPrompt() {
        guard let id = selectedProjectId, var project = ProjectStore.shared.project(id: id) else {
            let a = NSAlert(); a.messageText = "请先选择或新增一个项目"; a.runModal(); return
        }
        let alert = NSAlert()
        alert.messageText = "添加提示词"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 72))
        input.placeholderString = "提示词内容"
        input.usesSingleLineMode = false
        alert.accessoryView = input
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.layout(); alert.window.initialFirstResponder = input   // 弹窗即聚焦输入框
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLabel.stringValue = "提示词内容不能为空"; return }
        project.prompts.append(ProjectPrompt(text: text))
        ProjectStore.shared.update(project)
        reloadPrompts(project)
        statusLabel.stringValue = "已添加提示词到「\(project.name)」"
    }

    // 跨项目搜索历史提示词 → 下拉选中 → 复用到当前项目（无选中项目则复制到剪贴板）
    @objc private func promptSearch() {
        let query = promptSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { statusLabel.stringValue = "输入关键词搜索历史提示词"; return }
        let results = ProjectStore.shared.searchPrompts(query)
        guard !results.isEmpty else { statusLabel.stringValue = "未找到匹配「\(query)」的提示词"; return }
        let menu = NSMenu()
        for (projectName, prompt) in results.prefix(40) {
            let star = prompt.favorite ? "⭐ " : ""
            let preview = prompt.text.replacingOccurrences(of: "\n", with: " ")
            let clipped = preview.count > 50 ? String(preview.prefix(50)) + "…" : preview
            let item = NSMenuItem(title: "\(star)[\(projectName)] \(clipped)", action: #selector(pickFoundPrompt(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = prompt.text
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: promptSearchField.bounds.height + 4), in: promptSearchField)
        statusLabel.stringValue = "命中 \(results.count) 条，选择一条复用到当前项目"
    }

    @objc private func pickFoundPrompt(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        if let id = selectedProjectId, var project = ProjectStore.shared.project(id: id) {
            // 避免重复加入
            if project.prompts.contains(where: { $0.text == text }) {
                statusLabel.stringValue = "该提示词已在当前项目库中"
            } else {
                project.prompts.append(ProjectPrompt(text: text))
                ProjectStore.shared.update(project)
                reloadPrompts(project)
                statusLabel.stringValue = "已复用到当前项目「\(project.name)」"
            }
        } else {
            ClipboardStore.copy(text)
            statusLabel.stringValue = "未选项目，已复制到剪贴板"
        }
    }

    private func toggleFavorite(promptId: String) {
        guard let id = selectedProjectId, var project = ProjectStore.shared.project(id: id),
              let idx = project.prompts.firstIndex(where: { $0.id == promptId }) else { return }
        project.prompts[idx].favorite.toggle()
        ProjectStore.shared.update(project)
        reloadPrompts(project)
    }

    private func deletePrompt(promptId: String) {
        guard let id = selectedProjectId, var project = ProjectStore.shared.project(id: id) else { return }
        project.prompts.removeAll { $0.id == promptId }
        ProjectStore.shared.update(project)
        reloadPrompts(project)
    }

    private func copyPrompt(_ text: String) {
        ClipboardStore.copy(text)
        statusLabel.stringValue = "提示词已复制到剪贴板"
    }

    // 把当前项目所有提示词拼接(编号+空行)复制到剪贴板
    private func copyAllPrompts() {
        guard let id = selectedProjectId, let project = ProjectStore.shared.project(id: id) else {
            statusLabel.stringValue = "请先选择项目"; return
        }
        guard !project.prompts.isEmpty else { statusLabel.stringValue = "该项目暂无提示词"; return }
        // 与列表一致：收藏优先排序，收藏项标 ⭐
        let ordered = project.prompts.enumerated()
            .sorted { ($0.element.favorite ? 0 : 1, $0.offset) < ($1.element.favorite ? 0 : 1, $1.offset) }
            .map { $0.element }
        let joined = ordered.enumerated()
            .map { "\($0.offset + 1). \($0.element.favorite ? "⭐ " : "")\($0.element.text)" }
            .joined(separator: "\n\n")
        ClipboardStore.copy(joined)
        statusLabel.stringValue = "已复制 \(project.prompts.count) 条提示词到剪贴板"
    }
}

// MARK: - 供应商管理（多供应商 API 配置 · 中枢网关聚合/故障转移/优先级）

/// 一套供应商 API 配置：既可作为某 CLI 工具的可切换档案，也被中枢网关聚合做故障转移。
struct Provider: Codable, Equatable {
    var id: String
    var name: String        // 显示名，如「DeepSeek 官方」
    var tool: String        // 适配工具：claude / codex / gemini / gateway(通用·仅网关)
    var apiType: String     // 协议：anthropic / openai
    var baseURL: String
    var apiKey: String
    var model: String
    var priority: Int       // 中枢网关故障转移优先级（小=先用）
    var enabled: Bool

    static let tools: [(String, String)] = [("Claude Code", "claude"), ("Codex", "codex"), ("Gemini", "gemini"), ("通用 / 网关", "gateway")]
    static let apiTypes: [(String, String)] = [("Anthropic 协议", "anthropic"), ("OpenAI 协议", "openai")]
    static func toolLabel(_ t: String) -> String { tools.first { $0.1 == t }?.0 ?? t }
    static func toolTint(_ t: String) -> NSColor {
        switch t { case "claude": return .systemOrange; case "codex": return .systemGreen; case "gemini": return .systemBlue; default: return .systemPurple }
    }
    static func apiTypeLabel(_ t: String) -> String { apiTypes.first { $0.1 == t }?.0 ?? t }
}

/// 供应商持久化（UserDefaults JSON）+ 网关故障转移链计算。
final class ProviderStore {
    static let shared = ProviderStore()
    private let key = "providers.v1"
    private(set) var providers: [Provider] = []
    private init() { load() }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Provider].self, from: data) { providers = list }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(providers) { UserDefaults.standard.set(data, forKey: key) }
    }
    func add(_ p: Provider) { providers.append(p); persist() }
    func update(_ p: Provider) { if let i = providers.firstIndex(where: { $0.id == p.id }) { providers[i] = p; persist() } }
    func delete(id: String) { providers.removeAll { $0.id == id }; persist() }
    func setEnabled(_ id: String, _ on: Bool) { if let i = providers.firstIndex(where: { $0.id == id }) { providers[i].enabled = on; persist() } }
    func provider(id: String) -> Provider? { providers.first { $0.id == id } }
    /// 在按优先级排序的链上移/下移一位
    func reprioritize(_ id: String, up: Bool) {
        var sorted = providers.sorted { $0.priority < $1.priority }
        guard let idx = sorted.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard target >= 0, target < sorted.count else { return }
        sorted.swapAt(idx, target)
        for (i, var p) in sorted.enumerated() { p.priority = i; if let j = providers.firstIndex(where: { $0.id == p.id }) { providers[j] = p } }
        persist()
    }
    /// 中枢网关故障转移链：启用的供应商，按优先级升序
    func gatewayChain() -> [Provider] { providers.filter { $0.enabled }.sorted { $0.priority < $1.priority } }
    var nextPriority: Int { (providers.map { $0.priority }.max() ?? -1) + 1 }
    // 每个工具的「当前供应商」（供应商管理里切换；写入工具配置另见应用逻辑）
    func currentId(tool: String) -> String? { UserDefaults.standard.string(forKey: "provider.current.\(tool)") }
    func setCurrent(tool: String, id: String) { UserDefaults.standard.set(id, forKey: "provider.current.\(tool)") }
}

/// 「供应商管理」模块：供应商 CRUD（启用/优先级）+ 中枢网关聚合状态。
final class ProviderWindowController: NSObject {
    let moduleView = NSView()
    private var built = false
    private var listStack: NSStackView!
    private var statusLabel: NSTextField!
    private var nameField: NSTextField!
    private var toolPopup: NSPopUpButton!
    private var apiTypePopup: NSPopUpButton!
    private var baseField: NSTextField!
    private var keyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var submitButton: ClosureButton!
    private var editingId: String?

    func activate() {
        if !built { moduleView.translatesAutoresizingMaskIntoConstraints = false; buildUI(into: moduleView); built = true }
        refresh()
    }

    private func buildUI(into content: NSView) {
        let title = NSTextField(labelWithString: "供应商管理")
        title.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "管理多供应商 API 配置（Claude / Codex / Gemini）· 中枢网关聚合多供应商做故障转移与优先级路由")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // 供应商列表卡片
        let listPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (listBadge, _) = makePanelHeader(title: "供应商", symbol: "server.rack", tint: .systemTeal, in: listPanel)
        listStack = NSStackView()
        listStack.orientation = .vertical; listStack.alignment = .leading; listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false; listScroll.borderType = .noBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack); listScroll.documentView = doc
        listPanel.addSubview(listScroll)

        // 新增 / 编辑表单
        let formPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (formBadge, _) = makePanelHeader(title: "添加供应商", symbol: "plus.circle", tint: .systemBlue, in: formPanel)
        nameField = NSTextField(); nameField.placeholderString = "显示名，如 DeepSeek 官方"
        toolPopup = NSPopUpButton(); for (n, _) in Provider.tools { toolPopup.addItem(withTitle: n) }
        apiTypePopup = NSPopUpButton(); for (n, _) in Provider.apiTypes { apiTypePopup.addItem(withTitle: n) }
        apiTypePopup.target = self; apiTypePopup.action = #selector(apiTypeChanged)
        baseField = NSTextField(); baseField.placeholderString = "API 端点，如 https://api.deepseek.com"
        keyField = NSSecureTextField(); keyField.placeholderString = "API Key"
        modelField = NSTextField(); modelField.placeholderString = "模型，如 deepseek-chat"
        for f in [nameField!, baseField!, modelField!] { f.font = NSFont.systemFont(ofSize: 12); f.translatesAutoresizingMaskIntoConstraints = false }
        keyField.font = NSFont.systemFont(ofSize: 12); keyField.translatesAutoresizingMaskIntoConstraints = false
        toolPopup.translatesAutoresizingMaskIntoConstraints = false
        apiTypePopup.translatesAutoresizingMaskIntoConstraints = false
        submitButton = ClosureButton(title: "添加", symbol: "checkmark.circle", tint: .systemGreen) { [weak self] in self?.submit() }
        submitButton.translatesAutoresizingMaskIntoConstraints = false
        let cancelEdit = ClosureButton(title: "清空", symbol: "xmark.circle", tint: .systemGray) { [weak self] in self?.resetForm() }
        cancelEdit.translatesAutoresizingMaskIntoConstraints = false
        func fl(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11, weight: .medium); l.textColor = .secondaryLabelColor; l.translatesAutoresizingMaskIntoConstraints = false; return l }
        let nameL = fl("名称"), toolL = fl("工具"), typeL = fl("协议"), baseL = fl("端点"), keyL = fl("Key"), modelL = fl("模型")
        for v in [nameL, nameField!, toolL, toolPopup!, typeL, apiTypePopup!, baseL, baseField!, keyL, keyField!, modelL, modelField!, submitButton!, cancelEdit] { formPanel.addSubview(v) }

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11); statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        for v in [title, subtitle, listPanel, formPanel, statusLabel] as [NSView] { content.addSubview(v) }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            listPanel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            listPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            listPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listPanel.heightAnchor.constraint(equalToConstant: 220),
            listScroll.topAnchor.constraint(equalTo: listBadge.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 14),
            listScroll.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -14),
            listScroll.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: -12),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: listScroll.widthAnchor),
            doc.bottomAnchor.constraint(equalTo: listStack.bottomAnchor),

            formPanel.topAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: 14),
            formPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            formPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            nameL.topAnchor.constraint(equalTo: formBadge.bottomAnchor, constant: 10),
            nameL.leadingAnchor.constraint(equalTo: formPanel.leadingAnchor, constant: 16),
            nameField.centerYAnchor.constraint(equalTo: nameL.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameL.trailingAnchor, constant: 8),
            nameField.widthAnchor.constraint(equalToConstant: 200),
            toolL.centerYAnchor.constraint(equalTo: nameL.centerYAnchor),
            toolL.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 14),
            toolPopup.centerYAnchor.constraint(equalTo: nameL.centerYAnchor),
            toolPopup.leadingAnchor.constraint(equalTo: toolL.trailingAnchor, constant: 8),
            typeL.centerYAnchor.constraint(equalTo: nameL.centerYAnchor),
            typeL.leadingAnchor.constraint(equalTo: toolPopup.trailingAnchor, constant: 14),
            apiTypePopup.centerYAnchor.constraint(equalTo: nameL.centerYAnchor),
            apiTypePopup.leadingAnchor.constraint(equalTo: typeL.trailingAnchor, constant: 8),

            baseL.topAnchor.constraint(equalTo: nameL.bottomAnchor, constant: 14),
            baseL.leadingAnchor.constraint(equalTo: nameL.leadingAnchor),
            baseField.centerYAnchor.constraint(equalTo: baseL.centerYAnchor),
            baseField.leadingAnchor.constraint(equalTo: baseL.trailingAnchor, constant: 8),
            baseField.widthAnchor.constraint(equalToConstant: 260),
            keyL.centerYAnchor.constraint(equalTo: baseL.centerYAnchor),
            keyL.leadingAnchor.constraint(equalTo: baseField.trailingAnchor, constant: 14),
            keyField.centerYAnchor.constraint(equalTo: baseL.centerYAnchor),
            keyField.leadingAnchor.constraint(equalTo: keyL.trailingAnchor, constant: 8),
            keyField.trailingAnchor.constraint(equalTo: formPanel.trailingAnchor, constant: -16),

            modelL.topAnchor.constraint(equalTo: baseL.bottomAnchor, constant: 14),
            modelL.leadingAnchor.constraint(equalTo: nameL.leadingAnchor),
            modelField.centerYAnchor.constraint(equalTo: modelL.centerYAnchor),
            modelField.leadingAnchor.constraint(equalTo: modelL.trailingAnchor, constant: 8),
            modelField.widthAnchor.constraint(equalToConstant: 200),
            submitButton.centerYAnchor.constraint(equalTo: modelL.centerYAnchor),
            submitButton.leadingAnchor.constraint(equalTo: modelField.trailingAnchor, constant: 14),
            cancelEdit.centerYAnchor.constraint(equalTo: modelL.centerYAnchor),
            cancelEdit.leadingAnchor.constraint(equalTo: submitButton.trailingAnchor, constant: 8),
            modelL.bottomAnchor.constraint(equalTo: formPanel.bottomAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: formPanel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor)
        ])
    }

    @objc private func apiTypeChanged() {}

    private func refresh() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let sorted = ProviderStore.shared.providers.sorted { $0.priority < $1.priority }
        if sorted.isEmpty {
            let empty = NSTextField(labelWithString: "还没有供应商。在下方添加一个，启用后即纳入中枢网关故障转移链。")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(empty)
        } else {
            for p in sorted { listStack.addArrangedSubview(makeRow(p)) }
        }
    }

    private func makeRow(_ p: Provider) -> NSView {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let isCurrent = ProviderStore.shared.currentId(tool: p.tool) == p.id
        let dot = NSView(); dot.wantsLayer = true; dot.layer?.backgroundColor = Provider.toolTint(p.tool).cgColor
        dot.layer?.cornerRadius = 4; dot.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: p.name.isEmpty ? "(未命名)" : p.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold); name.translatesAutoresizingMaskIntoConstraints = false
        let meta = NSTextField(labelWithString: "\(Provider.toolLabel(p.tool)) · \(p.apiType) · \(maskURL(p.baseURL)) · \(p.model.isEmpty ? "默认模型" : p.model)")
        meta.font = .systemFont(ofSize: 11); meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingMiddle; meta.translatesAutoresizingMaskIntoConstraints = false
        let switchBtn = ClosureButton(title: isCurrent ? "当前" : "切换", symbol: isCurrent ? "checkmark.seal.fill" : "arrow.left.arrow.right", tint: isCurrent ? .systemGreen : .systemBlue) { [weak self] in self?.switchTo(p) }
        switchBtn.isEnabled = !isCurrent && p.tool != "gateway"
        let edit = ClosureButton(title: "", symbol: "pencil", tint: .systemBlue) { [weak self] in self?.beginEdit(p) }
        let del = ClosureButton(title: "", symbol: "trash", tint: .systemRed) { [weak self] in ProviderStore.shared.delete(id: p.id); self?.refresh(); self?.statusLabel.stringValue = "已删除「\(p.name)」" }
        for b in [switchBtn, edit, del] { b.translatesAutoresizingMaskIntoConstraints = false }
        for v in [dot, name, meta, switchBtn, edit, del] { row.addSubview(v) }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 40),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
            meta.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            meta.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: switchBtn.leadingAnchor, constant: -8),
            switchBtn.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -6),
            switchBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            edit.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -2),
            edit.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            del.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            del.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func switchTo(_ p: Provider) {
        ProviderStore.shared.setCurrent(tool: p.tool, id: p.id)
        statusLabel.stringValue = "已切换「\(p.name)」为 \(Provider.toolLabel(p.tool)) 当前供应商（写入工具配置：实现中）"
        refresh()
    }

    private func maskURL(_ s: String) -> String {
        guard let u = URL(string: s), let h = u.host else { return s.isEmpty ? "(无端点)" : s }
        return h
    }

    private func beginEdit(_ p: Provider) {
        editingId = p.id
        nameField.stringValue = p.name
        if let i = Provider.tools.firstIndex(where: { $0.1 == p.tool }) { toolPopup.selectItem(at: i) }
        if let i = Provider.apiTypes.firstIndex(where: { $0.1 == p.apiType }) { apiTypePopup.selectItem(at: i) }
        baseField.stringValue = p.baseURL
        keyField.stringValue = p.apiKey
        modelField.stringValue = p.model
        submitButton.title = "保存修改"
        statusLabel.stringValue = "正在编辑「\(p.name)」"
    }

    private func resetForm() {
        editingId = nil
        nameField.stringValue = ""; baseField.stringValue = ""; keyField.stringValue = ""; modelField.stringValue = ""
        toolPopup.selectItem(at: 0); apiTypePopup.selectItem(at: 0)
        submitButton.title = "添加"
        statusLabel.stringValue = ""
    }

    private func submit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { statusLabel.stringValue = "请填写名称"; return }
        let tool = Provider.tools[max(0, toolPopup.indexOfSelectedItem)].1
        let apiType = Provider.apiTypes[max(0, apiTypePopup.indexOfSelectedItem)].1
        if let id = editingId, var p = ProviderStore.shared.provider(id: id) {
            p.name = name; p.tool = tool; p.apiType = apiType
            p.baseURL = baseField.stringValue.trimmingCharacters(in: .whitespaces)
            p.apiKey = keyField.stringValue; p.model = modelField.stringValue.trimmingCharacters(in: .whitespaces)
            ProviderStore.shared.update(p)
            statusLabel.stringValue = "已保存「\(name)」"
        } else {
            let p = Provider(id: UUID().uuidString, name: name, tool: tool, apiType: apiType,
                             baseURL: baseField.stringValue.trimmingCharacters(in: .whitespaces),
                             apiKey: keyField.stringValue, model: modelField.stringValue.trimmingCharacters(in: .whitespaces),
                             priority: ProviderStore.shared.nextPriority, enabled: true)
            ProviderStore.shared.add(p)
            statusLabel.stringValue = "已添加「\(name)」，已纳入网关链"
        }
        resetForm()
        refresh()
    }
}

/// 中枢网关本地服务（自研）：监听 127.0.0.1:端口，把任意工具的请求按优先级路由到供应商，
/// 自动协议互转(Anthropic↔OpenAI) + 模型名映射，实现「一个工具打通所有模型/供应商」。
/// v1：真实可启停的本地服务 + 状态响应；转发/协议互转/模型映射 在后续迭代接入。
final class GatewayServer {
    static let shared = GatewayServer()
    private(set) var isRunning = false
    private(set) var port: UInt16
    private var listener: NWListener?
    var onLog: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    private init() {
        let p = UserDefaults.standard.integer(forKey: "gateway.port")
        port = (p > 0 && p < 65536) ? UInt16(p) : 8787
    }
    func start(port: UInt16) {
        stop()
        self.port = port
        UserDefaults.standard.set(Int(port), forKey: "gateway.port")
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { log("端口无效"); return }
        do {
            let l = try NWListener(using: .tcp, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch state {
                    case .ready: self.isRunning = true; self.log("✅ 网关已启动 http://127.0.0.1:\(port)"); self.onStateChange?()
                    case .failed(let e): self.isRunning = false; self.listener = nil; self.log("❌ 启动失败：\(e.localizedDescription)"); self.onStateChange?()
                    case .cancelled: self.isRunning = false; self.onStateChange?()
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            log("❌ 无法监听 :\(port) — \(error.localizedDescription)")
        }
    }
    func stop() {
        listener?.cancel(); listener = nil
        if isRunning { isRunning = false; DispatchQueue.main.async { self.onStateChange?() } }
    }
    private func log(_ s: String) { DispatchQueue.main.async { self.onLog?(s) } }
    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receive(conn, buffer: Data())
    }
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf.subdata(in: buf.startIndex..<r.lowerBound), encoding: .utf8) ?? ""
                self.route(conn: conn, head: head, body: buf.subdata(in: r.upperBound..<buf.endIndex))
            } else if isComplete || error != nil {
                self.route(conn: conn, head: String(data: buf, encoding: .utf8) ?? "", body: Data())
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }
    private func route(conn: NWConnection, head: String, body: Data) {
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let chain = ProviderStore.shared.gatewayChain()
        log("← \(firstLine.isEmpty ? "(空请求)" : firstLine)")
        let payload = "{\"gateway\":\"AI工具助手 中枢网关\",\"status\":\"ok\",\"providers\":\(chain.count),\"chain\":[\(chain.map { "\"\($0.name)\"" }.joined(separator: ","))],\"note\":\"协议互转+模型映射+转发 实现中\"}"
        let bodyData = Data(payload.utf8)
        var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(bodyData)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// 「中枢网关」独立模块：启停本地网关 + 故障转移链（在此设启用/优先级）+ 模型映射(后续) + 实时日志。
final class GatewayWindowController: NSObject {
    let moduleView = NSView()
    private var built = false
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var portField: NSTextField!
    private var toggleButton: ClosureButton!
    private var chainStack: NSStackView!
    private var logView: NSTextView!

    func activate() {
        if !built { moduleView.translatesAutoresizingMaskIntoConstraints = false; buildUI(into: moduleView); built = true }
        GatewayServer.shared.onLog = { [weak self] s in self?.appendLog(s) }
        GatewayServer.shared.onStateChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func buildUI(into content: NSView) {
        let title = NSTextField(labelWithString: "中枢网关")
        title.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "本地通用网关 · 协议自动互转（Anthropic ↔ OpenAI）· 模型名映射 · 按优先级故障转移——一个工具打通所有模型/供应商")
        subtitle.font = NSFont.systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping; subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // 状态卡片
        let statusPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (statusBadge, _) = makePanelHeader(title: "服务状态", symbol: "antenna.radiowaves.left.and.right", tint: .systemPurple, in: statusPanel)
        statusDot = NSView(); statusDot.wantsLayer = true; statusDot.layer?.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium); statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let portLabel = NSTextField(labelWithString: "端口")
        portLabel.font = .systemFont(ofSize: 12); portLabel.textColor = .secondaryLabelColor
        portLabel.translatesAutoresizingMaskIntoConstraints = false
        portField = NSTextField(); portField.stringValue = String(GatewayServer.shared.port)
        portField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        portField.translatesAutoresizingMaskIntoConstraints = false
        toggleButton = ClosureButton(title: "启动网关", symbol: "play.circle", tint: .systemGreen) { [weak self] in self?.toggleServer() }
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.addSubview(statusDot); statusPanel.addSubview(statusLabel)
        statusPanel.addSubview(portLabel); statusPanel.addSubview(portField); statusPanel.addSubview(toggleButton)

        // 故障转移链卡片
        let chainPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (chainBadge, _) = makePanelHeader(title: "故障转移链", symbol: "arrow.triangle.branch", tint: .systemTeal, in: chainPanel)
        let chainHint = NSTextField(labelWithString: "勾选纳入网关的供应商，按优先级从上到下故障转移（上移=更优先）。")
        chainHint.font = .systemFont(ofSize: 11); chainHint.textColor = .tertiaryLabelColor
        chainHint.translatesAutoresizingMaskIntoConstraints = false
        chainStack = NSStackView(); chainStack.orientation = .vertical; chainStack.alignment = .leading; chainStack.spacing = 6
        chainStack.translatesAutoresizingMaskIntoConstraints = false
        let chainScroll = NSScrollView(); chainScroll.hasVerticalScroller = true; chainScroll.drawsBackground = false; chainScroll.borderType = .noBorder
        chainScroll.translatesAutoresizingMaskIntoConstraints = false
        let cdoc = NSView(); cdoc.translatesAutoresizingMaskIntoConstraints = false
        cdoc.addSubview(chainStack); chainScroll.documentView = cdoc
        chainPanel.addSubview(chainHint); chainPanel.addSubview(chainScroll)

        // 日志卡片
        let logPanel = makeGlassEffectView(radius: 18, material: .contentBackground)
        let (logBadge, _) = makePanelHeader(title: "请求日志", symbol: "list.bullet.rectangle", tint: .systemGray, in: logPanel)
        let logScroll = NSScrollView(); logScroll.hasVerticalScroller = true; logScroll.borderType = .noBorder; logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logView = NSTextView(); logView.isEditable = false; logView.drawsBackground = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logScroll.documentView = logView
        logPanel.addSubview(logScroll)

        for v in [title, subtitle, statusPanel, chainPanel, logPanel] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            statusPanel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            statusPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusDot.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 16),
            statusDot.topAnchor.constraint(equalTo: statusBadge.bottomAnchor, constant: 12),
            statusDot.widthAnchor.constraint(equalToConstant: 10), statusDot.heightAnchor.constraint(equalToConstant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),
            portLabel.leadingAnchor.constraint(equalTo: statusDot.leadingAnchor),
            portLabel.topAnchor.constraint(equalTo: statusDot.bottomAnchor, constant: 14),
            portLabel.bottomAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: -16),
            portField.leadingAnchor.constraint(equalTo: portLabel.trailingAnchor, constant: 8),
            portField.centerYAnchor.constraint(equalTo: portLabel.centerYAnchor),
            portField.widthAnchor.constraint(equalToConstant: 90),
            toggleButton.leadingAnchor.constraint(equalTo: portField.trailingAnchor, constant: 16),
            toggleButton.centerYAnchor.constraint(equalTo: portLabel.centerYAnchor),

            chainPanel.topAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: 12),
            chainPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            chainPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chainPanel.heightAnchor.constraint(equalToConstant: 190),
            chainHint.topAnchor.constraint(equalTo: chainBadge.bottomAnchor, constant: 8),
            chainHint.leadingAnchor.constraint(equalTo: chainPanel.leadingAnchor, constant: 16),
            chainScroll.topAnchor.constraint(equalTo: chainHint.bottomAnchor, constant: 6),
            chainScroll.leadingAnchor.constraint(equalTo: chainPanel.leadingAnchor, constant: 14),
            chainScroll.trailingAnchor.constraint(equalTo: chainPanel.trailingAnchor, constant: -14),
            chainScroll.bottomAnchor.constraint(equalTo: chainPanel.bottomAnchor, constant: -12),
            chainStack.topAnchor.constraint(equalTo: cdoc.topAnchor),
            chainStack.leadingAnchor.constraint(equalTo: cdoc.leadingAnchor),
            chainStack.trailingAnchor.constraint(equalTo: cdoc.trailingAnchor),
            cdoc.widthAnchor.constraint(equalTo: chainScroll.widthAnchor),
            cdoc.bottomAnchor.constraint(equalTo: chainStack.bottomAnchor),

            logPanel.topAnchor.constraint(equalTo: chainPanel.bottomAnchor, constant: 12),
            logPanel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            logPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            logPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            logScroll.topAnchor.constraint(equalTo: logBadge.bottomAnchor, constant: 8),
            logScroll.leadingAnchor.constraint(equalTo: logPanel.leadingAnchor, constant: 14),
            logScroll.trailingAnchor.constraint(equalTo: logPanel.trailingAnchor, constant: -14),
            logScroll.bottomAnchor.constraint(equalTo: logPanel.bottomAnchor, constant: -12)
        ])
    }

    private func toggleServer() {
        if GatewayServer.shared.isRunning {
            GatewayServer.shared.stop()
            appendLog("⏹ 网关已停止")
        } else {
            let p = UInt16(portField.stringValue) ?? 8787
            GatewayServer.shared.start(port: p)
        }
        refresh()
    }

    private func appendLog(_ s: String) {
        guard logView != nil else { return }
        logView.string += (logView.string.isEmpty ? "" : "\n") + s
        logView.scrollToEndOfDocument(nil)
    }

    private func refresh() {
        guard statusDot != nil else { return }
        let running = GatewayServer.shared.isRunning
        statusDot.layer?.backgroundColor = (running ? NSColor.systemGreen : NSColor.systemGray).cgColor
        statusLabel.stringValue = running ? "运行中 · http://127.0.0.1:\(GatewayServer.shared.port)" : "已停止"
        toggleButton.title = running ? "停止网关" : "启动网关"
        chainStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = ProviderStore.shared.providers.sorted { $0.priority < $1.priority }
        if all.isEmpty {
            let empty = NSTextField(labelWithString: "先到「供应商管理」添加供应商，再在此组建故障转移链。")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            chainStack.addArrangedSubview(empty)
        } else {
            for (i, p) in all.enumerated() { chainStack.addArrangedSubview(makeChainRow(p, order: i)) }
        }
    }

    private func makeChainRow(_ p: Provider, order: Int) -> NSView {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let sw = NSSwitch(); sw.state = p.enabled ? .on : .off
        sw.identifier = NSUserInterfaceItemIdentifier(p.id)
        sw.target = self; sw.action = #selector(toggleChain(_:))
        sw.translatesAutoresizingMaskIntoConstraints = false
        let ord = NSTextField(labelWithString: p.enabled ? "\(chainPosition(p))" : "—")
        ord.font = .monospacedSystemFont(ofSize: 12, weight: .bold); ord.textColor = p.enabled ? Provider.toolTint(p.tool) : .tertiaryLabelColor
        ord.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: p.name.isEmpty ? "(未命名)" : p.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold); name.translatesAutoresizingMaskIntoConstraints = false
        let meta = NSTextField(labelWithString: "\(Provider.toolLabel(p.tool)) · \(p.apiType) · \(p.model.isEmpty ? "默认模型" : p.model)")
        meta.font = .systemFont(ofSize: 10); meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingMiddle; meta.translatesAutoresizingMaskIntoConstraints = false
        let up = ClosureButton(title: "", symbol: "chevron.up", tint: .systemGray) { [weak self] in ProviderStore.shared.reprioritize(p.id, up: true); self?.refresh() }
        let down = ClosureButton(title: "", symbol: "chevron.down", tint: .systemGray) { [weak self] in ProviderStore.shared.reprioritize(p.id, up: false); self?.refresh() }
        for b in [up, down] { b.translatesAutoresizingMaskIntoConstraints = false }
        for v in [sw, ord, name, meta, up, down] { row.addSubview(v) }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            sw.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            sw.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ord.leadingAnchor.constraint(equalTo: sw.trailingAnchor, constant: 10),
            ord.centerYAnchor.constraint(equalTo: row.centerYAnchor), ord.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: ord.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            meta.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            meta.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: up.leadingAnchor, constant: -8),
            up.trailingAnchor.constraint(equalTo: down.leadingAnchor, constant: -2),
            up.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            down.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            down.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func chainPosition(_ p: Provider) -> Int {
        (ProviderStore.shared.gatewayChain().firstIndex { $0.id == p.id } ?? 0) + 1
    }

    @objc private func toggleChain(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        ProviderStore.shared.setEnabled(id, sender.state == .on)
        refresh()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let scanner = ClaudeUsageScanner()
    private var allRecords: [UsageRecord] = []
    private var visibleRows: [SummaryRow] = []
    private var visibleTotalSum: Int = 0   // 当前 scope 总 token，用于「总计」列占比

    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var totalLabel: NSTextField!
    private var totalValueLabel: NSTextField!
    private var scopeSummaryLabel: NSTextField!
    private var topGroupLabel: NSTextField!
    private var recordValueLabel: NSTextField!
    private var inputValueLabel: NSTextField!
    private var outputValueLabel: NSTextField!
    private var cacheCreateValueLabel: NSTextField!
    private var cacheReadValueLabel: NSTextField!
    private var costValueLabel: NSTextField!
    private var sourceControl: NSSegmentedControl!
    private var scopeControl: NSSegmentedControl!
    private var groupingControl: NSSegmentedControl!
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var autoRefreshTimer: Timer?
    private var autoRefreshToggle: NSButton!
    private var sourceBarView: StackedBarView!
    private var sourceLegendLabel: NSTextField!
    private var trendChart: TrendBarView!
    private var trendCaptionLabel: NSTextField!
    private var emptyStateView: NSStackView!
    private var emptyStateLabel: NSTextField!
    private var emptyStateIcon: NSImageView!
    private var deltaLabel: NSTextField!
    private var trendDays = 7
    private weak var appearanceMenuRef: NSMenu?
    private var statusItem: NSStatusItem?
    private var statusOverviewItem: NSMenuItem?
    private var cvmController: CVMWindowController?
    private var cvmConfigController: CVMConfigWindowController?
    private var cvmProfileController: CVMProfileWindowController?
    private var providerController: ProviderWindowController?
    private var gatewayController: GatewayWindowController?
    private var projectController: ProjectWindowController?
    private var voiceSettingsController: VoiceSettingsController?
    private var voiceModuleView: NSView!
    private let aiSettingsController = AISettingsWindowController()
    private var navVoiceItem: SidebarRow!
    private var navWorkbenchItem: SidebarRow!
    private var navAISettingsItem: SidebarRow!
    // 多模块导航：用量统计视图整组 与 嵌入的项目/版本/配置/档案模块切换
    private var usageViews: [NSView] = []
    private var versionModuleView: NSView!
    private var configModuleView: NSView!
    private var profileModuleView: NSView!
    private var providerModuleView: NSView!
    private var gatewayModuleView: NSView!
    private var projectModuleView: NSView!
    private var navUsageItem: SidebarRow!
    private var navProjectItem: SidebarRow!
    private var navVersionItem: SidebarRow!
    private var navConfigItem: SidebarRow!
    private var navProfileItem: SidebarRow!
    private var navProviderItem: SidebarRow!
    private var navGatewayItem: SidebarRow!

    private let sourceOrder = ["Claude", "Codex", "Gemini", "OpenCode"]
    private let sourceColors: [String: NSColor] = [
        "Claude": .systemOrange,
        "Codex": .systemGreen,
        "Gemini": .systemBlue,
        "OpenCode": .systemPink
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = makeAppIcon()
        loadPricing()
        buildMenu()
        buildStatusItem()
        buildWindow()
        reloadData()
        VoiceFloatingController.shared.installHotKey()
    }

    @objc private func openVoicePanel() { VoiceFloatingController.shared.show() }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "—"
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        // 菜单栏 sparkles 图标（template 自适应明暗），图标在文字左侧
        if let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI工具助手")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)) {
            icon.isTemplate = true
            item.button?.image = icon
            item.button?.imagePosition = .imageLeading
            item.button?.imageHugsTitle = true
        }

        let menu = NSMenu()
        let overview = NSMenuItem(title: "今日用量加载中…", action: nil, keyEquivalent: "")
        overview.isEnabled = false
        menu.addItem(overview)
        statusOverviewItem = overview
        menu.addItem(withTitle: "复制今日摘要", action: #selector(copyTodaySummary), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "AI 提示词工作台", action: #selector(openAIWorkbench), keyEquivalent: "")
        menu.addItem(withTitle: "语音输入", action: #selector(openVoicePanel), keyEquivalent: "")
        menu.addItem(withTitle: "项目管理", action: #selector(openProjectManager), keyEquivalent: "")
        menu.addItem(withTitle: "AI 设置", action: #selector(openAISettings), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "刷新", action: #selector(refreshClicked), keyEquivalent: "")
        menu.addItem(withTitle: "退出 AI工具助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item
    }

    @objc private func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 模块导航按钮：当前模块高亮，其余点击切换/打开
    // 侧边栏分组小标题（App Store / 系统设置风）
    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private enum Module { case usage, project, voice, version, config, profile, providers, gateway }

    private func showModule(_ module: Module) {
        usageViews.forEach { $0.isHidden = module != .usage }
        projectModuleView.isHidden = module != .project
        voiceModuleView.isHidden = module != .voice
        versionModuleView.isHidden = module != .version
        configModuleView.isHidden = module != .config
        profileModuleView.isHidden = module != .profile
        providerModuleView.isHidden = module != .providers
        gatewayModuleView.isHidden = module != .gateway
        if module == .project { projectController?.activate() }
        if module == .voice { voiceSettingsController?.activate() }
        if module == .version { cvmController?.activate() }
        if module == .config { cvmConfigController?.activate() }
        if module == .profile { cvmProfileController?.activate() }
        if module == .providers { providerController?.activate() }
        if module == .gateway { gatewayController?.activate() }
        navUsageItem.setSelected(module == .usage)
        navProjectItem.setSelected(module == .project)
        navVoiceItem.setSelected(module == .voice)
        navVersionItem.setSelected(module == .version)
        navConfigItem.setSelected(module == .config)
        navProfileItem.setSelected(module == .profile)
        navProviderItem.setSelected(module == .providers)
        navGatewayItem.setSelected(module == .gateway)
    }

    @objc private func openProviderManager() {
        window.makeKeyAndOrderFront(nil)
        showModule(.providers)
    }

    @objc private func openGatewayManager() {
        window.makeKeyAndOrderFront(nil)
        showModule(.gateway)
    }

    @objc private func openVoiceSettings() {
        window.makeKeyAndOrderFront(nil)
        showModule(.voice)
    }

    @objc private func openProjectManager() {
        window.makeKeyAndOrderFront(nil)
        showModule(.project)
    }

    @objc private func openAISettings() { aiSettingsController.show() }
    func openAISettingsExternally() { aiSettingsController.show() }
    @objc private func openAIWorkbench() { AIWorkbenchWindowController.shared.show() }

    @objc private func openVersionManager() {
        window.makeKeyAndOrderFront(nil)
        showModule(.version)
    }

    @objc private func openConfigManager() {
        window.makeKeyAndOrderFront(nil)
        showModule(.config)
    }

    @objc private func openProfileManager() {
        window.makeKeyAndOrderFront(nil)
        showModule(.profile)
    }

    @objc private func showScanScope() {
        let alert = NSAlert()
        alert.messageText = "用量扫描范围"
        alert.informativeText = """
        离线读取以下本地日志统计 token 用量（只读，不联网、不上传）：

        • Claude Code： ~/.claude/projects/**/*.jsonl
        • Codex CLI：   ~/.codex/sessions/**/*.jsonl
        • Gemini CLI：  ~/.gemini/tmp/*/chats/session-*.json
        • OpenCode：    ~/.local/share/opencode/storage/message/**/*.json

        按 message.id / requestId / usage 签名分层去重。
        今日数据每次刷新重扫，历史走 SQLite 缓存。
        某工具无数据多因其未产生日志或路径不同。
        """
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openDataFolder() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AI工具助手", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        statusLabel.stringValue = "已在访达打开数据文件夹（含 SQLite 缓存 / 项目库 / 定价配置）"
    }

    @objc private func editPricingClicked() {
        // 确保模板存在再打开，方便用户直接编辑
        if !FileManager.default.fileExists(atPath: pricingConfigURL().path) {
            writeDefaultPricingTemplate()
        }
        NSWorkspace.shared.open(pricingConfigURL())
    }

    @objc private func reloadPricingClicked() {
        let ok = loadPricing()
        statusLabel.stringValue = ok ? "已重新加载定价配置 pricing.json" : "未找到有效 pricing.json，已使用内置默认定价"
        rebuildVisibleRows()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App 菜单（关于 / 退出）
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 AI工具助手", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "快捷键参考", action: #selector(showShortcuts), keyEquivalent: "/")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 AI工具助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 数据菜单（刷新 / 重建 / 导出 / 搜索）
        let dataItem = NSMenuItem()
        mainMenu.addItem(dataItem)
        let dataMenu = NSMenu(title: "数据")
        dataItem.submenu = dataMenu
        dataMenu.addItem(withTitle: "刷新", action: #selector(refreshClicked), keyEquivalent: "r")
        let rebuildItem = dataMenu.addItem(withTitle: "重建缓存", action: #selector(rebuildClicked), keyEquivalent: "r")
        rebuildItem.keyEquivalentModifierMask = [.command, .shift]
        dataMenu.addItem(NSMenuItem.separator())
        dataMenu.addItem(withTitle: "复制用量报告", action: #selector(copyUsageReport), keyEquivalent: "")
        dataMenu.addItem(withTitle: "导出 CSV", action: #selector(exportCSVClicked), keyEquivalent: "e")
        let exportJSONItem = dataMenu.addItem(withTitle: "导出 JSON", action: #selector(exportJSONClicked), keyEquivalent: "e")
        exportJSONItem.keyEquivalentModifierMask = [.command, .shift]
        dataMenu.addItem(NSMenuItem.separator())
        dataMenu.addItem(withTitle: "搜索分组", action: #selector(focusSearch), keyEquivalent: "f")
        dataMenu.addItem(withTitle: "重置筛选", action: #selector(resetFilters), keyEquivalent: "")
        dataMenu.addItem(NSMenuItem.separator())
        dataMenu.addItem(withTitle: "项目管理…", action: #selector(openProjectManager), keyEquivalent: "j")
        dataMenu.addItem(withTitle: "语音输入设置…", action: #selector(openVoiceSettings), keyEquivalent: "")
        dataMenu.addItem(withTitle: "语音输入悬浮窗（⌥⌘Space）", action: #selector(openVoicePanel), keyEquivalent: "")
        dataMenu.addItem(withTitle: "AI 提示词工作台…", action: #selector(openAIWorkbench), keyEquivalent: "i")
        dataMenu.addItem(withTitle: "AI 设置…", action: #selector(openAISettings), keyEquivalent: "")
        dataMenu.addItem(withTitle: "版本管理…", action: #selector(openVersionManager), keyEquivalent: "m")
        dataMenu.addItem(withTitle: "配置管理…", action: #selector(openConfigManager), keyEquivalent: "k")
        dataMenu.addItem(withTitle: "配置档案…", action: #selector(openProfileManager), keyEquivalent: "p")
        dataMenu.addItem(withTitle: "供应商管理…", action: #selector(openProviderManager), keyEquivalent: "g")
        dataMenu.addItem(withTitle: "中枢网关…", action: #selector(openGatewayManager), keyEquivalent: "")
        dataMenu.addItem(NSMenuItem.separator())
        dataMenu.addItem(withTitle: "扫描范围说明…", action: #selector(showScanScope), keyEquivalent: "")
        dataMenu.addItem(withTitle: "打开数据文件夹…", action: #selector(openDataFolder), keyEquivalent: "")
        dataMenu.addItem(withTitle: "编辑定价配置…", action: #selector(editPricingClicked), keyEquivalent: "")
        dataMenu.addItem(withTitle: "重新加载定价", action: #selector(reloadPricingClicked), keyEquivalent: "")

        // 视图 / 外观 子菜单（跟随系统 / 浅色 / 深色，单选打勾）
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        viewItem.submenu = viewMenu
        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        viewMenu.addItem(appearanceItem)
        let appearanceMenu = NSMenu(title: "外观")
        appearanceItem.submenu = appearanceMenu
        for (index, title) in ["跟随系统", "浅色", "深色"].enumerated() {
            let item = appearanceMenu.addItem(withTitle: title, action: #selector(appearanceChanged(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
        }
        appearanceMenuRef = appearanceMenu

        // 编辑菜单（让搜索框/表格支持标准 复制/全选/剪切/粘贴）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "快捷键参考"
        alert.informativeText = """
        全局
        ⌥⌘Space   唤出 / 隐藏语音输入面板（可在语音配置自定义）

        模块切换
        ⌘M  版本管理      ⌘K  配置管理      ⌘P  配置档案
        ⌘J  项目管理      ⌘I  AI 工作台

        AI 工作台
        ⌘↩  AI 优化       ⌘T  中译英       ⌘S  存为提示词
        ⌘R  重新生成上一动作              ⌘N  新会话（清空）

        文本编辑（所有输入框）
        ⌘Z / ⇧⌘Z  撤销 / 重做     ⌘X / C / V  剪切 / 复制 / 粘贴     ⌘A  全选
        """
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showAbout() {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 3
        para.lineSpacing = 1
        let body = "多功能本地 macOS AI 工具助手 · 纯 AppKit 单文件 · 无第三方依赖\n\n"
            + "• 用量统计：离线统计 Claude / Codex / Gemini / OpenCode 的 token 与成本\n"
            + "• 项目管理：背景 / 资料 / 提示词库（SQLite，可导出导入）\n"
            + "• AI 工作台：优化 / 中英互译 / 扩缩写 / 总结 / 改语气 / 自定义指令，关联项目读上下文、存回提示词或资料\n"
            + "• 语音输入：⌥⌘Space 转写 + AI 矫正 → 剪贴板 / 粘贴到前台\n"
            + "• cvm：Claude / Codex 版本 · 配置 · 档案管理\n\n"
            + "数据全部本地存储 · AI 与 cvm 配置独立 · 支持 Anthropic / OpenAI 兼容 · ⌘/ 查看全部快捷键"
        let credits = NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "AI工具助手",
            .applicationVersion: "1.0.0",
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func focusSearch() {
        window.makeFirstResponder(searchField)
    }

    // 给工具按钮加 SF Symbol 图标，符号不可用时静默降级为纯文字
    private func decorate(_ button: NSButton, symbol: String) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title) {
            button.image = image
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
    }

    @objc private func toggleTrendDays() {
        trendDays = (trendDays == 7) ? 30 : 7
        UserDefaults.standard.set(trendDays, forKey: DefaultsKey.trendDays)
        trendCaptionLabel.stringValue = "近 \(trendDays) 天"
        updateTrend()
    }

    @objc private func appearanceChanged(_ sender: NSMenuItem) {
        applyAppearance(sender.tag)
        UserDefaults.standard.set(sender.tag, forKey: DefaultsKey.appearance)
    }

    // 0=跟随系统 1=浅色 2=深色
    private func applyAppearance(_ mode: Int) {
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        appearanceMenuRef?.items.forEach { $0.state = ($0.tag == mode) ? .on : .off }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AI工具助手"
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // 关闭窗口恢复，避免异常退出后弹出"重新打开窗口"系统提示
        window.isRestorable = false
        window.minSize = NSSize(width: 980, height: 640)
        // 记住并恢复窗口尺寸/位置（在 center 之后，已保存的 frame 会覆盖居中）
        window.setFrameAutosaveName("AIUsageMainWindow")

        window.isOpaque = false
        window.backgroundColor = .clear

        // Liquid Glass 底层即 contentView：作为内容视图才能被窗口圆角正确裁切
        let content = NSVisualEffectView()
        content.material = .underWindowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        // 内容区大标题（用量统计模块标题，App Store 风大字）
        let title = NSTextField(labelWithString: "用量统计")
        title.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "正在读取本地缓存")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // ===== 左侧 vibrant 侧边栏（App Store / 系统设置风）=====
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        // 右侧内容区干净底（App Store 双层质感：vibrant 侧栏 + 干净内容面板）
        let contentBackdrop = NSVisualEffectView()
        contentBackdrop.material = .contentBackground
        contentBackdrop.blendingMode = .behindWindow
        contentBackdrop.state = .active
        contentBackdrop.translatesAutoresizingMaskIntoConstraints = false

        // app 图标徽标（圆角强调色方块 + 符号，无图标资源时的品牌占位）
        let appIcon = NSView()
        appIcon.wantsLayer = true
        appIcon.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        appIcon.layer?.cornerRadius = 7
        appIcon.layer?.cornerCurve = .continuous
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        let appIconGlyph = NSImageView()
        appIconGlyph.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        appIconGlyph.contentTintColor = .white
        appIconGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        appIconGlyph.translatesAutoresizingMaskIntoConstraints = false
        appIcon.addSubview(appIconGlyph)

        let appName = NSTextField(labelWithString: "AI工具助手")
        appName.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        appName.translatesAutoresizingMaskIntoConstraints = false

        let overviewHeader = makeSectionHeader("工作区")
        let aiHeader = makeSectionHeader("语音助手")
        let manageHeader = makeSectionHeader("CLI 管理")

        navUsageItem = SidebarRow(title: "用量统计", symbol: "chart.bar.xaxis", iconColor: .systemBlue)
        navUsageItem.onClick = { [weak self] in self?.showModule(.usage) }
        navProjectItem = SidebarRow(title: "项目管理", symbol: "folder.fill", iconColor: .systemIndigo)
        navProjectItem.onClick = { [weak self] in self?.showModule(.project) }
        navVoiceItem = SidebarRow(title: "语音输入", symbol: "mic.fill", iconColor: .systemRed)
        navVoiceItem.onClick = { [weak self] in self?.showModule(.voice) }
        navWorkbenchItem = SidebarRow(title: "AI 工作台", symbol: "wand.and.stars", iconColor: .systemPurple)
        navWorkbenchItem.onClick = { AIWorkbenchWindowController.shared.show() }
        navAISettingsItem = SidebarRow(title: "AI 设置", symbol: "gearshape.2.fill", iconColor: .systemTeal)
        navAISettingsItem.onClick = { [weak self] in self?.aiSettingsController.show() }
        navVersionItem = SidebarRow(title: "版本管理", symbol: "shippingbox.fill", iconColor: .systemOrange)
        navVersionItem.onClick = { [weak self] in self?.showModule(.version) }
        navConfigItem = SidebarRow(title: "配置管理", symbol: "gearshape.fill", iconColor: .systemGray)
        navConfigItem.onClick = { [weak self] in self?.showModule(.config) }
        navProfileItem = SidebarRow(title: "配置档案", symbol: "person.crop.rectangle.stack.fill", iconColor: .systemPurple)
        navProfileItem.onClick = { [weak self] in self?.showModule(.profile) }
        navProviderItem = SidebarRow(title: "供应商管理", symbol: "server.rack", iconColor: .systemPink)
        navProviderItem.onClick = { [weak self] in self?.showModule(.providers) }
        navGatewayItem = SidebarRow(title: "中枢网关", symbol: "point.3.connected.trianglepath.dotted", iconColor: .systemPurple)
        navGatewayItem.onClick = { [weak self] in self?.showModule(.gateway) }
        navUsageItem.setSelected(true)

        let versionFootnote = NSTextField(labelWithString: "v1.0.0 · 本地离线")
        versionFootnote.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        versionFootnote.textColor = .tertiaryLabelColor
        versionFootnote.translatesAutoresizingMaskIntoConstraints = false

        for view in [appIcon, appName, overviewHeader, aiHeader, manageHeader, navUsageItem!, navProjectItem!, navVoiceItem!, navWorkbenchItem!, navAISettingsItem!, navVersionItem!, navConfigItem!, navProfileItem!, navProviderItem!, navGatewayItem!, versionFootnote] as [NSView] {
            sidebar.addSubview(view)
        }

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        decorate(refreshButton, symbol: "arrow.clockwise")

        autoRefreshToggle = NSButton(checkboxWithTitle: "自动刷新", target: self, action: #selector(autoRefreshToggled(_:)))
        autoRefreshToggle.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        autoRefreshToggle.toolTip = "每 60 秒自动重扫当天数据并刷新"
        autoRefreshToggle.translatesAutoresizingMaskIntoConstraints = false

        let rebuildButton = NSButton(title: "重建缓存", target: self, action: #selector(rebuildClicked))
        rebuildButton.bezelStyle = .rounded
        rebuildButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        rebuildButton.translatesAutoresizingMaskIntoConstraints = false
        decorate(rebuildButton, symbol: "arrow.triangle.2.circlepath")

        let exportCSVButton = NSButton(title: "导出 CSV", target: self, action: #selector(exportCSVClicked))
        exportCSVButton.bezelStyle = .rounded
        exportCSVButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        exportCSVButton.translatesAutoresizingMaskIntoConstraints = false
        decorate(exportCSVButton, symbol: "square.and.arrow.up")

        let exportJSONButton = NSButton(title: "导出 JSON", target: self, action: #selector(exportJSONClicked))
        exportJSONButton.bezelStyle = .rounded
        exportJSONButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        exportJSONButton.translatesAutoresizingMaskIntoConstraints = false
        decorate(exportJSONButton, symbol: "curlybraces")

        sourceControl = NSSegmentedControl(labels: ["全部", "Claude", "Codex", "Gemini", "OpenCode"], trackingMode: .selectOne, target: self, action: #selector(filterChanged))
        sourceControl.selectedSegment = SourceScope.all.rawValue
        sourceControl.segmentStyle = .rounded
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        scopeControl = NSSegmentedControl(labels: ["今天", "近 7 天", "本月", "全部"], trackingMode: .selectOne, target: self, action: #selector(filterChanged))
        scopeControl.selectedSegment = DateScope.today.rawValue
        scopeControl.segmentStyle = .rounded
        scopeControl.translatesAutoresizingMaskIntoConstraints = false

        groupingControl = NSSegmentedControl(labels: ["日期", "项目", "模型", "会话", "来源"], trackingMode: .selectOne, target: self, action: #selector(filterChanged))
        groupingControl.selectedSegment = Grouping.date.rawValue
        groupingControl.segmentStyle = .rounded
        groupingControl.translatesAutoresizingMaskIntoConstraints = false

        searchField = NSSearchField()
        searchField.placeholderString = "搜索分组"
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        totalLabel = NSTextField(labelWithString: "")
        totalLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        totalLabel.textColor = .secondaryLabelColor
        totalLabel.translatesAutoresizingMaskIntoConstraints = false

        sourceBarView = StackedBarView()
        sourceBarView.translatesAutoresizingMaskIntoConstraints = false
        sourceBarView.toolTip = "各来源 token 总量占比"

        sourceLegendLabel = NSTextField(labelWithString: "")
        sourceLegendLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sourceLegendLabel.translatesAutoresizingMaskIntoConstraints = false

        let insightPanel = makeGlassPanel(radius: 18, material: .hudWindow)

        let insightTitle = NSTextField(labelWithString: "当前范围总计")
        insightTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        insightTitle.textColor = .secondaryLabelColor
        insightTitle.translatesAutoresizingMaskIntoConstraints = false

        totalValueLabel = NSTextField(labelWithString: "0")
        totalValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        totalValueLabel.textColor = .labelColor
        totalValueLabel.lineBreakMode = .byTruncatingTail
        totalValueLabel.translatesAutoresizingMaskIntoConstraints = false

        scopeSummaryLabel = NSTextField(labelWithString: "今天 / 按日期")
        scopeSummaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        scopeSummaryLabel.textColor = .secondaryLabelColor
        scopeSummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        deltaLabel = NSTextField(labelWithString: "较昨日 —")
        deltaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        deltaLabel.textColor = .tertiaryLabelColor
        deltaLabel.toolTip = "今日 token 总量相较昨日的变化（受来源筛选影响）"
        deltaLabel.translatesAutoresizingMaskIntoConstraints = false

        topGroupLabel = NSTextField(labelWithString: "最高分组：暂无")
        topGroupLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        topGroupLabel.textColor = .labelColor
        topGroupLabel.alignment = .right
        topGroupLabel.lineBreakMode = .byTruncatingMiddle
        topGroupLabel.translatesAutoresizingMaskIntoConstraints = false

        trendChart = TrendBarView()
        trendChart.translatesAutoresizingMaskIntoConstraints = false

        trendCaptionLabel = NSTextField(labelWithString: "近 7 天")
        trendCaptionLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        trendCaptionLabel.textColor = .tertiaryLabelColor
        trendCaptionLabel.alignment = .right
        trendCaptionLabel.toolTip = "点击切换 7 天 / 30 天区间"
        let trendTap = NSClickGestureRecognizer(target: self, action: #selector(toggleTrendDays))
        trendCaptionLabel.addGestureRecognizer(trendTap)
        trendCaptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let tableTitle = NSTextField(labelWithString: "分组明细")
        tableTitle.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        tableTitle.textColor = .labelColor
        tableTitle.translatesAutoresizingMaskIntoConstraints = false

        let summaryStack = NSStackView()
        summaryStack.orientation = .horizontal
        summaryStack.spacing = 14
        summaryStack.distribution = .fillEqually
        summaryStack.translatesAutoresizingMaskIntoConstraints = false

        // 冷色协调系（蓝→青→靛→紫）+ 中性灰 + 金钱绿，替代原先的高饱和彩虹色
        let recordCard = makeMetricCard(title: "记录数", symbol: "number", accent: NSColor.systemGray)
        recordValueLabel = recordCard.valueLabel
        let inputCard = makeMetricCard(title: "输入", symbol: "arrow.down.circle.fill", accent: NSColor.systemBlue)
        inputValueLabel = inputCard.valueLabel
        let outputCard = makeMetricCard(title: "输出", symbol: "arrow.up.circle.fill", accent: NSColor.systemTeal)
        outputValueLabel = outputCard.valueLabel
        let cacheCreateCard = makeMetricCard(title: "缓存写入", symbol: "square.and.arrow.down.fill", accent: NSColor.systemIndigo)
        cacheCreateValueLabel = cacheCreateCard.valueLabel
        let cacheReadCard = makeMetricCard(title: "缓存读取", symbol: "square.and.arrow.up.fill", accent: NSColor.systemPurple)
        cacheReadValueLabel = cacheReadCard.valueLabel
        let costCard = makeMetricCard(title: "估算花费", symbol: "dollarsign.circle.fill", accent: NSColor.systemGreen)
        costValueLabel = costCard.valueLabel

        for card in [recordCard.view, inputCard.view, outputCard.view, cacheCreateCard.view, cacheReadCard.view, costCard.view] {
            summaryStack.addArrangedSubview(card)
        }

        let controlsPanel = makeGlassPanel(radius: 18, material: .menu)

        let sourceLabel = NSTextField(labelWithString: "来源")
        sourceLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false

        let scopeLabel = NSTextField(labelWithString: "时间")
        scopeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false

        let groupingLabel = NSTextField(labelWithString: "分组方式")
        groupingLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        groupingLabel.textColor = .secondaryLabelColor
        groupingLabel.translatesAutoresizingMaskIntoConstraints = false

        let searchLabel = NSTextField(labelWithString: "搜索")
        searchLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        searchLabel.textColor = .secondaryLabelColor
        searchLabel.translatesAutoresizingMaskIntoConstraints = false

        let controlViews: [NSView] = [sourceLabel, sourceControl, scopeLabel, scopeControl, groupingLabel, groupingControl, searchLabel, searchField]
        for view in controlViews {
            controlsPanel.addSubview(view)
        }

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 38
        tableView.gridStyleMask = []
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 8, height: 6)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.backgroundColor = .clear

        let rowMenu = NSMenu()
        rowMenu.addItem(withTitle: "复制该行", action: #selector(copyRowClicked), keyEquivalent: "")
        rowMenu.addItem(withTitle: "复制全部可见行", action: #selector(copyAllRowsClicked), keyEquivalent: "")
        tableView.menu = rowMenu
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        addColumn("name", "分组", 260, minWidth: 160, maxWidth: 360)
        addColumn("input", "输入", 120, minWidth: 96, maxWidth: 140)
        addColumn("output", "输出", 120, minWidth: 96, maxWidth: 140)
        addColumn("cacheCreate", "缓存写入", 130, minWidth: 110, maxWidth: 150)
        addColumn("cacheRead", "缓存读取", 130, minWidth: 110, maxWidth: 150)
        addColumn("total", "总计", 130, minWidth: 110, maxWidth: 150)
        addColumn("cost", "成本", 110, minWidth: 90, maxWidth: 140)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tablePanel = makeGlassPanel(radius: 18, material: .hudWindow)
        tablePanel.addSubview(scrollView)

        for view in [insightTitle, totalValueLabel, scopeSummaryLabel, deltaLabel, topGroupLabel, trendCaptionLabel, trendChart] as [NSView] {
            insightPanel.addSubview(view)
        }

        tablePanel.addSubview(tableTitle)

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        let emptyText = NSTextField(labelWithString: "当前范围暂无数据")
        emptyText.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyText.textColor = .tertiaryLabelColor
        emptyText.alignment = .center
        emptyText.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel = emptyText
        emptyStateIcon = emptyIcon
        emptyStateView = NSStackView(views: [emptyIcon, emptyText])
        emptyStateView.orientation = .vertical
        emptyStateView.spacing = 10
        emptyStateView.alignment = .centerX
        emptyStateView.isHidden = true
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        tablePanel.addSubview(emptyStateView)

        let views: [NSView] = [sidebar, contentBackdrop, title, statusLabel, autoRefreshToggle, refreshButton, rebuildButton, exportCSVButton, exportJSONButton, summaryStack, controlsPanel, insightPanel, totalLabel, sourceBarView, sourceLegendLabel, tablePanel]
        for view in views {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            // ===== 侧边栏 =====
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),

            contentBackdrop.topAnchor.constraint(equalTo: content.topAnchor),
            contentBackdrop.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentBackdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentBackdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            appIcon.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 42),
            appIcon.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            appIcon.widthAnchor.constraint(equalToConstant: 26),
            appIcon.heightAnchor.constraint(equalToConstant: 26),
            appIconGlyph.centerXAnchor.constraint(equalTo: appIcon.centerXAnchor),
            appIconGlyph.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            appName.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            appName.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 9),
            appName.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),

            overviewHeader.topAnchor.constraint(equalTo: appIcon.bottomAnchor, constant: 20),
            overviewHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),

            navUsageItem.topAnchor.constraint(equalTo: overviewHeader.bottomAnchor, constant: 6),
            navUsageItem.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navUsageItem.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            navProjectItem.topAnchor.constraint(equalTo: navUsageItem.bottomAnchor, constant: 2),
            navProjectItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navProjectItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),

            aiHeader.topAnchor.constraint(equalTo: navProjectItem.bottomAnchor, constant: 16),
            aiHeader.leadingAnchor.constraint(equalTo: overviewHeader.leadingAnchor),
            navVoiceItem.topAnchor.constraint(equalTo: aiHeader.bottomAnchor, constant: 6),
            navVoiceItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navVoiceItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),
            navWorkbenchItem.topAnchor.constraint(equalTo: navVoiceItem.bottomAnchor, constant: 2),
            navWorkbenchItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navWorkbenchItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),
            navAISettingsItem.topAnchor.constraint(equalTo: navWorkbenchItem.bottomAnchor, constant: 2),
            navAISettingsItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navAISettingsItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),

            manageHeader.topAnchor.constraint(equalTo: navAISettingsItem.bottomAnchor, constant: 16),
            manageHeader.leadingAnchor.constraint(equalTo: overviewHeader.leadingAnchor),

            navVersionItem.topAnchor.constraint(equalTo: manageHeader.bottomAnchor, constant: 6),
            navVersionItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navVersionItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),
            navConfigItem.topAnchor.constraint(equalTo: navVersionItem.bottomAnchor, constant: 2),
            navConfigItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navConfigItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),
            navProfileItem.topAnchor.constraint(equalTo: navConfigItem.bottomAnchor, constant: 2),
            navProfileItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navProfileItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),

            navProviderItem.topAnchor.constraint(equalTo: navProfileItem.bottomAnchor, constant: 2),
            navProviderItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navProviderItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),

            navGatewayItem.topAnchor.constraint(equalTo: navProviderItem.bottomAnchor, constant: 2),
            navGatewayItem.leadingAnchor.constraint(equalTo: navUsageItem.leadingAnchor),
            navGatewayItem.trailingAnchor.constraint(equalTo: navUsageItem.trailingAnchor),

            versionFootnote.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            versionFootnote.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),

            // ===== 内容区头部 =====
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),

            autoRefreshToggle.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            autoRefreshToggle.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -16),
            refreshButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: rebuildButton.leadingAnchor, constant: -10),
            rebuildButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            rebuildButton.trailingAnchor.constraint(equalTo: exportCSVButton.leadingAnchor, constant: -10),
            exportCSVButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            exportCSVButton.trailingAnchor.constraint(equalTo: exportJSONButton.leadingAnchor, constant: -10),
            exportJSONButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            exportJSONButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            statusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),

            summaryStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            summaryStack.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),
            summaryStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            summaryStack.heightAnchor.constraint(equalToConstant: 100),

            controlsPanel.topAnchor.constraint(equalTo: summaryStack.bottomAnchor, constant: 16),
            controlsPanel.leadingAnchor.constraint(equalTo: summaryStack.leadingAnchor),
            controlsPanel.trailingAnchor.constraint(equalTo: summaryStack.trailingAnchor),
            controlsPanel.heightAnchor.constraint(equalToConstant: 98),

            sourceLabel.leadingAnchor.constraint(equalTo: controlsPanel.leadingAnchor, constant: 16),
            sourceLabel.topAnchor.constraint(equalTo: controlsPanel.topAnchor, constant: 16),
            sourceControl.centerYAnchor.constraint(equalTo: sourceLabel.centerYAnchor),
            sourceControl.leadingAnchor.constraint(equalTo: sourceLabel.trailingAnchor, constant: 10),
            sourceControl.widthAnchor.constraint(equalToConstant: 520),
            sourceControl.trailingAnchor.constraint(lessThanOrEqualTo: controlsPanel.trailingAnchor, constant: -16),

            scopeLabel.leadingAnchor.constraint(equalTo: controlsPanel.leadingAnchor, constant: 16),
            scopeLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 18),
            scopeControl.centerYAnchor.constraint(equalTo: scopeLabel.centerYAnchor),
            scopeControl.leadingAnchor.constraint(equalTo: scopeLabel.trailingAnchor, constant: 10),
            scopeControl.widthAnchor.constraint(equalToConstant: 220),

            groupingLabel.centerYAnchor.constraint(equalTo: scopeLabel.centerYAnchor),
            groupingLabel.leadingAnchor.constraint(equalTo: scopeControl.trailingAnchor, constant: 20),
            groupingControl.centerYAnchor.constraint(equalTo: scopeLabel.centerYAnchor),
            groupingControl.leadingAnchor.constraint(equalTo: groupingLabel.trailingAnchor, constant: 10),
            groupingControl.widthAnchor.constraint(equalToConstant: 250),

            searchLabel.centerYAnchor.constraint(equalTo: scopeLabel.centerYAnchor),
            searchLabel.leadingAnchor.constraint(equalTo: groupingControl.trailingAnchor, constant: 20),
            searchField.centerYAnchor.constraint(equalTo: scopeLabel.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchLabel.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: controlsPanel.trailingAnchor, constant: -16),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            insightPanel.topAnchor.constraint(equalTo: controlsPanel.bottomAnchor, constant: 16),
            insightPanel.leadingAnchor.constraint(equalTo: summaryStack.leadingAnchor),
            insightPanel.trailingAnchor.constraint(equalTo: summaryStack.trailingAnchor),
            insightPanel.heightAnchor.constraint(equalToConstant: 118),

            insightTitle.topAnchor.constraint(equalTo: insightPanel.topAnchor, constant: 18),
            insightTitle.leadingAnchor.constraint(equalTo: insightPanel.leadingAnchor, constant: 18),

            totalValueLabel.topAnchor.constraint(equalTo: insightTitle.bottomAnchor, constant: 8),
            totalValueLabel.leadingAnchor.constraint(equalTo: insightPanel.leadingAnchor, constant: 18),
            totalValueLabel.trailingAnchor.constraint(lessThanOrEqualTo: topGroupLabel.leadingAnchor, constant: -24),

            scopeSummaryLabel.leadingAnchor.constraint(equalTo: totalValueLabel.trailingAnchor, constant: 14),
            scopeSummaryLabel.firstBaselineAnchor.constraint(equalTo: totalValueLabel.firstBaselineAnchor),
            scopeSummaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: topGroupLabel.leadingAnchor, constant: -24),

            deltaLabel.leadingAnchor.constraint(equalTo: totalValueLabel.leadingAnchor),
            deltaLabel.topAnchor.constraint(equalTo: totalValueLabel.bottomAnchor, constant: 2),

            topGroupLabel.topAnchor.constraint(equalTo: insightPanel.topAnchor, constant: 18),
            topGroupLabel.trailingAnchor.constraint(equalTo: insightPanel.trailingAnchor, constant: -18),
            topGroupLabel.widthAnchor.constraint(equalToConstant: 320),

            trendCaptionLabel.trailingAnchor.constraint(equalTo: insightPanel.trailingAnchor, constant: -18),
            trendCaptionLabel.bottomAnchor.constraint(equalTo: trendChart.topAnchor, constant: -3),

            trendChart.trailingAnchor.constraint(equalTo: insightPanel.trailingAnchor, constant: -18),
            trendChart.bottomAnchor.constraint(equalTo: insightPanel.bottomAnchor, constant: -16),
            trendChart.widthAnchor.constraint(equalToConstant: 168),
            trendChart.heightAnchor.constraint(equalToConstant: 34),

            totalLabel.topAnchor.constraint(equalTo: insightPanel.bottomAnchor, constant: 10),
            totalLabel.leadingAnchor.constraint(equalTo: summaryStack.leadingAnchor),
            totalLabel.trailingAnchor.constraint(equalTo: summaryStack.trailingAnchor),

            sourceBarView.topAnchor.constraint(equalTo: totalLabel.bottomAnchor, constant: 10),
            sourceBarView.leadingAnchor.constraint(equalTo: summaryStack.leadingAnchor),
            sourceBarView.trailingAnchor.constraint(equalTo: summaryStack.trailingAnchor),
            sourceBarView.heightAnchor.constraint(equalToConstant: 10),

            sourceLegendLabel.topAnchor.constraint(equalTo: sourceBarView.bottomAnchor, constant: 7),
            sourceLegendLabel.leadingAnchor.constraint(equalTo: summaryStack.leadingAnchor),
            sourceLegendLabel.trailingAnchor.constraint(equalTo: summaryStack.trailingAnchor),

            tablePanel.topAnchor.constraint(equalTo: sourceLegendLabel.bottomAnchor, constant: 12),
            tablePanel.leadingAnchor.constraint(equalTo: summaryStack.leadingAnchor),
            tablePanel.trailingAnchor.constraint(equalTo: summaryStack.trailingAnchor),
            tablePanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),

            tableTitle.topAnchor.constraint(equalTo: tablePanel.topAnchor, constant: 14),
            tableTitle.leadingAnchor.constraint(equalTo: tablePanel.leadingAnchor, constant: 16),
            tableTitle.trailingAnchor.constraint(lessThanOrEqualTo: tablePanel.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: tableTitle.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: tablePanel.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: tablePanel.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: tablePanel.bottomAnchor, constant: -10),

            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        // 多模块：收集用量统计视图组（整组显隐切换，约束保持不变）
        usageViews = [title, statusLabel, autoRefreshToggle, refreshButton, rebuildButton, exportCSVButton, exportJSONButton,
                      summaryStack, controlsPanel, insightPanel, totalLabel, sourceBarView, sourceLegendLabel, tablePanel]

        // 嵌入模块视图，叠加在内容区（侧边栏右侧）同一区域，默认隐藏
        if cvmController == nil { cvmController = CVMWindowController() }
        if cvmConfigController == nil { cvmConfigController = CVMConfigWindowController() }
        if cvmProfileController == nil { cvmProfileController = CVMProfileWindowController() }
        if projectController == nil { projectController = ProjectWindowController() }
        if voiceSettingsController == nil { voiceSettingsController = VoiceSettingsController() }
        voiceModuleView = voiceSettingsController!.moduleView
        versionModuleView = cvmController!.moduleView
        configModuleView = cvmConfigController!.moduleView
        profileModuleView = cvmProfileController!.moduleView
        if providerController == nil { providerController = ProviderWindowController() }
        providerModuleView = providerController!.moduleView
        if gatewayController == nil { gatewayController = GatewayWindowController() }
        gatewayModuleView = gatewayController!.moduleView
        projectModuleView = projectController!.moduleView
        for moduleView in [versionModuleView!, configModuleView!, profileModuleView!, projectModuleView!, voiceModuleView!, providerModuleView!, gatewayModuleView!] {
            moduleView.translatesAutoresizingMaskIntoConstraints = false
            moduleView.isHidden = true
            content.addSubview(moduleView)
            NSLayoutConstraint.activate([
                moduleView.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
                moduleView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
                moduleView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                moduleView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
            ])
        }

        restoreState()
        // 在所有子视图（含 tableView）创建完成后再设委托，避免早期 resize 回调访问未初始化的 tableView
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            self.fitTableColumns()
        }
    }

    private enum DefaultsKey {
        static let source = "filter.source"
        static let scope = "filter.scope"
        static let grouping = "filter.grouping"
        static let autoRefresh = "autoRefresh.on"
        static let appearance = "appearance.mode"
        static let trendDays = "trend.days"
    }

    private func saveState() {
        let defaults = UserDefaults.standard
        defaults.set(sourceControl.selectedSegment, forKey: DefaultsKey.source)
        defaults.set(scopeControl.selectedSegment, forKey: DefaultsKey.scope)
        defaults.set(groupingControl.selectedSegment, forKey: DefaultsKey.grouping)
        defaults.set(autoRefreshToggle.state == .on, forKey: DefaultsKey.autoRefresh)
    }

    private func restoreState() {
        let defaults = UserDefaults.standard
        func apply(_ key: String, to control: NSSegmentedControl) {
            if let value = defaults.object(forKey: key) as? Int, value >= 0, value < control.segmentCount {
                control.selectedSegment = value
            }
        }
        apply(DefaultsKey.source, to: sourceControl)
        apply(DefaultsKey.scope, to: scopeControl)
        apply(DefaultsKey.grouping, to: groupingControl)
        applyAppearance(defaults.object(forKey: DefaultsKey.appearance) as? Int ?? 0)
        let savedDays = defaults.object(forKey: DefaultsKey.trendDays) as? Int ?? 7
        trendDays = (savedDays == 30) ? 30 : 7
        trendCaptionLabel.stringValue = "近 \(trendDays) 天"
        if defaults.bool(forKey: DefaultsKey.autoRefresh) {
            autoRefreshToggle.state = .on
            startAutoRefresh()
        }
    }

    private func addColumn(_ identifier: String, _ title: String, _ width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.width = width
        column.minWidth = minWidth
        column.maxWidth = maxWidth
        // 克制的表头：小号中等字重 + 次级色（App Store 风）
        column.headerCell.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        // 数值列表头右对齐，与右对齐的单元格数值垂直对齐，便于扫读
        if identifier != "name" {
            column.headerCell.alignment = .right
        }
        // 点击表头排序：分组名首点升序，数值列首点降序（大在前）
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: identifier == "name")
        tableView.addTableColumn(column)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        fitTableColumns()
    }

    func windowDidResize(_ notification: Notification) {
        fitTableColumns()
    }

    private func fitTableColumns() {
        // tableView 在 buildWindow 中途才创建，窗口早期的 resize 回调可能在此之前触发
        guard let tableView = tableView, tableView.tableColumns.count == 7 else { return }

        let numberColumnsWidth: CGFloat = 120 + 120 + 130 + 130 + 130 + 110
        // 间距需覆盖 7 列 intercell spacing(8×7)、垂直滚动条、.inset 样式左右边距，避免成本列被挤出
        let spacing: CGFloat = 112
        let available = max(tableView.bounds.width - numberColumnsWidth - spacing, 180)
        let groupWidth = min(max(available, 180), 320)

        tableView.tableColumns[0].width = groupWidth
        tableView.tableColumns[1].width = 120
        tableView.tableColumns[2].width = 120
        tableView.tableColumns[3].width = 130
        tableView.tableColumns[4].width = 130
        tableView.tableColumns[5].width = 130
        tableView.tableColumns[6].width = 110
    }

    // Liquid Glass 玻璃面板：半透明材质 + 连续大圆角 + 玻璃边缘高光，随系统外观自适应
    private func makeGlassPanel(radius: CGFloat, material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func makeMetricCard(title: String, symbol: String, accent: NSColor) -> (view: NSView, valueLabel: NSTextField) {
        let card = makeGlassPanel(radius: 18, material: .hudWindow)

        // 柔和强调色图标徽标（与各模块面板徽标统一视觉语言，替代刺眼粗色带）
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        badge.layer?.cornerRadius = 7
        badge.layer?.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: "0")
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(badge)
        card.addSubview(titleLabel)
        card.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            badge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            titleLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -10),

            valueLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            valueLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            valueLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])

        return (card, valueLabel)
    }

    @objc private func refreshClicked() {
        reloadData()
    }

    @objc private func autoRefreshToggled(_ sender: NSButton) {
        if sender.state == .on {
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
        saveState()
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        // .common 模式：拖拽/缩放窗口时仍能触发；窗口关闭后进程退出，Timer 随之失效
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.reloadData()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    @objc private func rebuildClicked() {
        reloadData(forceRefresh: true)
    }

    @objc private func filterChanged() {
        saveState()
        rebuildVisibleRows()
    }

    // 一键把 来源/时间/分组/搜索 复位为默认（全部来源 · 今日 · 按日期）
    @objc private func resetFilters() {
        sourceControl.selectedSegment = 0
        scopeControl.selectedSegment = 0
        groupingControl.selectedSegment = 0
        searchField.stringValue = ""
        filterChanged()
        statusLabel.stringValue = "已重置筛选（全部来源 · 今日 · 按日期）"
    }

    @objc private func exportJSONClicked() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claude-用量统计.json"
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let records = filteredRecords()
            if let data = try? encoder.encode(records) {
                try? data.write(to: url)
            }
        }
    }

    @objc private func exportCSVClicked() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claude-分组明细.csv"
        panel.allowedContentTypes = [.commaSeparatedText]

        if panel.runModal() == .OK, let url = panel.url {
            let csv = makeCSV(rows: visibleRows)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func reloadData(forceRefresh: Bool = false) {
        statusLabel.stringValue = forceRefresh ? "正在强制重建 SQLite 缓存 ..." : "正在更新今日记录并读取历史缓存 ..."
        DispatchQueue.global(qos: .userInitiated).async {
            let records = self.scanner.scan(forceRefresh: forceRefresh)
            DispatchQueue.main.async {
                self.allRecords = records
                let action = forceRefresh ? "已重建缓存并载入" : "已更新今日记录并载入"
                self.statusLabel.stringValue = "\(action) \(records.count) 条去重后的用量记录"
                self.statusLabel.toolTip = "本地缓存：\(self.scanner.cachePath)"
                self.rebuildVisibleRows()
            }
        }
    }

    private func rebuildVisibleRows() {
        let records = filteredRecords()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarizedRows = scanner.summarize(records, grouping: currentGrouping())
        if query.isEmpty {
            visibleRows = summarizedRows
        } else {
            visibleRows = summarizedRows.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        visibleRows = sortRows(visibleRows)
        let total = scanner.total(records)
        visibleTotalSum = total.total
        recordValueLabel.stringValue = formatCount(records.count)
        inputValueLabel.stringValue = formatTokens(total.inputTokens)
        outputValueLabel.stringValue = formatTokens(total.outputTokens)
        cacheCreateValueLabel.stringValue = formatTokens(total.cacheCreationInputTokens)
        cacheReadValueLabel.stringValue = formatTokens(total.cacheReadInputTokens)
        let totalCost = records.reduce(0.0) { $0 + estimatedCostUSD($1.usage, model: $1.model) }
        costValueLabel.stringValue = formatUSD(totalCost)
        costValueLabel.toolTip = "按内置近似模型定价估算，仅供参考"
        totalValueLabel.stringValue = "\(formatTokens(total.total)) tokens"
        scopeSummaryLabel.stringValue = "\(sourceTitle(currentSourceScope())) / \(scopeTitle(currentScope())) / \(groupingTitle(currentGrouping()))"

        if let topRow = visibleRows.max(by: { $0.usage.total < $1.usage.total }) {
            topGroupLabel.stringValue = "最高分组：\(topRow.name) · \(formatTokens(topRow.usage.total))"
            topGroupLabel.toolTip = "\(topRow.name)\n精确总量：\(formatExact(topRow.usage.total))"
        } else {
            topGroupLabel.stringValue = "最高分组：暂无"
            topGroupLabel.toolTip = nil
        }

        updateSourceShare(records)
        updateTrend()
        updateStatusItem()

        let shown = query.isEmpty ? "分组：\(visibleRows.count)" : "匹配分组：\(visibleRows.count) / \(summarizedRows.count)"
        totalLabel.stringValue = "记录：\(formatCount(records.count))    \(shown)    精确总量：\(formatExact(total.total)) tokens    缓存策略：今日重扫，历史缓存"
        emptyStateView.isHidden = !visibleRows.isEmpty
        if visibleRows.isEmpty {
            if !query.isEmpty {
                emptyStateIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                emptyStateLabel.stringValue = "无匹配「\(query)」的分组\n试试清空搜索或更换关键词"
            } else {
                emptyStateIcon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
                emptyStateLabel.stringValue = "「\(scopeTitle(currentScope()))」范围暂无用量记录\n换个时间范围或来源筛选试试"
            }
            emptyStateLabel.maximumNumberOfLines = 2
        }
        fitTableColumns()
        tableView.reloadData()
    }

    // 菜单栏状态项显示今日（全部来源）token 总量 + 下拉概览(含成本)
    private func updateStatusItem() {
        let todayRecords = scanner.filter(allRecords, scope: .today)
        let total = scanner.total(todayRecords).total
        let cost = todayRecords.reduce(0.0) { $0 + estimatedCostUSD($1.usage, model: $1.model) }
        statusItem?.button?.title = "今日 " + formatTokens(total)
        statusItem?.button?.toolTip = "AI工具助手 · 今日 \(formatExact(total)) tokens · 约 \(formatUSD(cost))"
        statusOverviewItem?.title = "今日 \(formatTokens(total)) tokens · 约 \(formatUSD(cost))"
    }

    // 复制当前范围用量报告（尊重 时间/来源/分组/搜索 的人类可读报告）到剪贴板
    @objc private func copyUsageReport() {
        let records = filteredRecords()
        let total = scanner.total(records)
        let cost = records.reduce(0.0) { $0 + estimatedCostUSD($1.usage, model: $1.model) }
        var lines = [
            "AI 用量报告 · \(sourceTitle(currentSourceScope())) / \(scopeTitle(currentScope())) / \(groupingTitle(currentGrouping()))",
            "记录 \(formatCount(records.count)) 条 · 总计 \(formatExact(total.total)) tokens · 约 \(formatUSD(cost))",
            ""
        ]
        let rows = visibleRows
        if rows.isEmpty {
            lines.append("（当前范围无数据）")
        } else {
            for r in rows.prefix(50) {
                let pct = visibleTotalSum > 0 ? Double(r.usage.total) / Double(visibleTotalSum) * 100 : 0
                lines.append("· \(r.name)：\(formatTokens(r.usage.total)) tokens（\(String(format: "%.0f%%", pct))）· \(formatUSD(r.cost))")
            }
            if rows.count > 50 { lines.append("…（共 \(rows.count) 个分组，仅列前 50）") }
        }
        copyToPasteboard(lines.joined(separator: "\n"))
        statusLabel.stringValue = "已复制用量报告到剪贴板（\(rows.count) 个分组）"
    }

    // 复制今日用量摘要（总量 + 成本 + 按来源明细）到剪贴板，便于分享/记录
    @objc private func copyTodaySummary() {
        let todayRecords = scanner.filter(allRecords, scope: .today)
        let total = scanner.total(todayRecords).total
        let cost = todayRecords.reduce(0.0) { $0 + estimatedCostUSD($1.usage, model: $1.model) }
        var lines = ["AI 用量摘要 · 今日", "总计：\(formatExact(total)) tokens · 约 \(formatUSD(cost))"]
        let bySource = scanner.summarize(todayRecords, grouping: .source)
        if !bySource.isEmpty {
            lines.append("按来源：")
            for r in bySource.sorted(by: { $0.usage.total > $1.usage.total }) {
                lines.append("· \(r.name)：\(formatTokens(r.usage.total)) tokens · \(formatUSD(r.cost))")
            }
        }
        let summary = lines.joined(separator: "\n")
        copyToPasteboard(summary)
        statusLabel.stringValue = "已复制今日用量摘要到剪贴板（\(bySource.count) 个来源）"
    }

    // 近7天每日 token 总量趋势（仅受来源筛选影响，与时间范围无关，便于纵览近期走势）
    private func updateTrend() {
        let sourceFiltered = scanner.filter(allRecords, sourceScope: currentSourceScope())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var dayTotals: [Date: Int] = [:]
        for record in sourceFiltered {
            let day = calendar.startOfDay(for: record.timestamp)
            dayTotals[day, default: 0] += record.usage.total
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        var values: [Double] = []
        var tips: [String] = []
        for offset in stride(from: trendDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let total = dayTotals[day] ?? 0
            values.append(Double(total))
            tips.append("\(formatter.string(from: day))  \(formatExact(total)) tokens")
        }
        trendChart.setBars(values, tips: tips)
        trendChart.toolTip = nil   // 改为每根柱独立 hover 提示

        // 今日较昨日环比：上升用警示橙、下降用柔和绿、无昨日数据中性灰
        let todayTotal = dayTotals[today] ?? 0
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let yesterdayTotal = yesterday.flatMap { dayTotals[$0] } ?? 0
        if yesterdayTotal == 0 {
            deltaLabel.stringValue = "较昨日 —"
            deltaLabel.textColor = .tertiaryLabelColor
        } else {
            let pct = Double(todayTotal - yesterdayTotal) / Double(yesterdayTotal) * 100
            let arrow = pct > 0 ? "↑" : (pct < 0 ? "↓" : "→")
            deltaLabel.stringValue = String(format: "较昨日 %@ %.0f%%", arrow, abs(pct))
            deltaLabel.textColor = pct > 0 ? .systemOrange : (pct < 0 ? .systemGreen : .tertiaryLabelColor)
        }
    }

    // 计算各来源 token 占比，更新堆叠条与彩色图例
    private func updateSourceShare(_ records: [UsageRecord]) {
        var totals: [String: Int] = [:]
        for record in records {
            totals[record.source, default: 0] += record.usage.total
        }
        let grandTotal = totals.values.reduce(0, +)

        let segments: [(color: NSColor, value: Double)] = sourceOrder.compactMap { source in
            let value = totals[source] ?? 0
            guard value > 0 else { return nil }
            return ((sourceColors[source] ?? .systemGray), Double(value))
        }
        sourceBarView.setSegments(segments)

        guard grandTotal > 0 else {
            sourceLegendLabel.stringValue = "暂无数据"
            sourceLegendLabel.textColor = .secondaryLabelColor
            return
        }

        let legend = NSMutableAttributedString()
        for source in sourceOrder {
            let value = totals[source] ?? 0
            guard value > 0 else { continue }
            let pct = Double(value) / Double(grandTotal) * 100
            let color = sourceColors[source] ?? .systemGray
            legend.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: color]))
            legend.append(NSAttributedString(
                string: String(format: "%@ %.1f%%    ", source, pct),
                attributes: [.foregroundColor: NSColor.labelColor]
            ))
        }
        sourceLegendLabel.attributedStringValue = legend
    }

    private func makeCSV(rows: [SummaryRow]) -> String {
        var lines = ["分组,输入,输出,缓存写入,缓存读取,总计,成本(USD)"]
        for row in rows {
            let values: [String] = [
                row.name,
                String(row.usage.inputTokens),
                String(row.usage.outputTokens),
                String(row.usage.cacheCreationInputTokens),
                String(row.usage.cacheReadInputTokens),
                String(row.usage.total),
                String(format: "%.4f", row.cost)
            ]
            lines.append(values.map(escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func tsvLine(_ row: SummaryRow) -> String {
        [
            row.name,
            String(row.usage.inputTokens),
            String(row.usage.outputTokens),
            String(row.usage.cacheCreationInputTokens),
            String(row.usage.cacheReadInputTokens),
            String(row.usage.total),
            String(format: "%.4f", row.cost)
        ].joined(separator: "\t")
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // 复制单行 + 反馈（双击 / 右键复制该行 / Cmd+C 共用）
    private func copyRow(at index: Int) {
        guard index >= 0, index < visibleRows.count else { statusLabel.stringValue = "请先选中要复制的分组行"; return }
        let item = visibleRows[index]
        copyToPasteboard(tsvLine(item))
        statusLabel.stringValue = "已复制「\(item.name)」：总计 \(formatTokens(item.usage.total)) tokens · \(formatUSD(item.cost))"
    }

    @objc private func copyRowClicked() {
        copyRow(at: tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow)
    }

    // 双击分组行：复制该行数据并给出反馈
    @objc private func rowDoubleClicked() {
        copyRow(at: tableView.clickedRow)
    }

    @objc private func copyAllRowsClicked() {
        guard !visibleRows.isEmpty else { statusLabel.stringValue = "当前无可复制的分组"; return }
        let header = "分组\t输入\t输出\t缓存写入\t缓存读取\t总计\t成本(USD)"
        let body = visibleRows.map(tsvLine).joined(separator: "\n")
        copyToPasteboard(header + "\n" + body)
        statusLabel.stringValue = "已复制全部 \(visibleRows.count) 个分组（含表头，TSV 可粘贴到表格软件）"
    }

    // 响应链 copy:：表格为第一响应者且有选中行时，Cmd+C 复制该行 TSV
    // （搜索框聚焦时其字段编辑器先处理 copy:，不受影响）
    @objc func copy(_ sender: Any?) {
        let index = tableView?.selectedRow ?? -1
        guard index >= 0, index < visibleRows.count else { return }
        copyRow(at: index)
    }

    private func currentScope() -> DateScope {
        DateScope(rawValue: scopeControl.selectedSegment) ?? .today
    }

    private func currentSourceScope() -> SourceScope {
        SourceScope(rawValue: sourceControl.selectedSegment) ?? .all
    }

    private func currentGrouping() -> Grouping {
        Grouping(rawValue: groupingControl.selectedSegment) ?? .date
    }

    private func filteredRecords() -> [UsageRecord] {
        let sourceFiltered = scanner.filter(allRecords, sourceScope: currentSourceScope())
        return scanner.filter(sourceFiltered, scope: currentScope())
    }

    // 按当前表头排序状态对分组行排序；无排序时沿用 summarize 的默认（总计降序）
    private func sortRows(_ rows: [SummaryRow]) -> [SummaryRow] {
        guard let descriptor = tableView?.sortDescriptors.first, let key = descriptor.key else {
            return rows
        }
        let asc = descriptor.ascending
        func by<T: Comparable>(_ value: @escaping (SummaryRow) -> T) -> [SummaryRow] {
            rows.sorted { asc ? value($0) < value($1) : value($0) > value($1) }
        }
        switch key {
        case "name": return by { $0.name }
        case "input": return by { $0.usage.inputTokens }
        case "output": return by { $0.usage.outputTokens }
        case "cacheCreate": return by { $0.usage.cacheCreationInputTokens }
        case "cacheRead": return by { $0.usage.cacheReadInputTokens }
        case "total": return by { $0.usage.total }
        case "cost": return by { $0.cost }
        default: return rows
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        visibleRows = sortRows(visibleRows)
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visibleRows.count, let identifier = tableColumn?.identifier.rawValue else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("cell-\(identifier)")
        let textField: NSTextField

        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField {
            textField = reused
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = cellId
            textField.lineBreakMode = .byTruncatingMiddle
            textField.font = identifier == "name" ? NSFont.systemFont(ofSize: 12) : NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        let item = visibleRows[row]
        switch identifier {
        case "name":
            textField.alignment = .left
            textField.toolTip = item.name
            // 按来源分组时，名称前加该来源代表色圆点
            if currentGrouping() == .source, let color = sourceColors[item.name] {
                let dot = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
                dot.append(NSAttributedString(string: item.name, attributes: [.foregroundColor: NSColor.labelColor]))
                textField.attributedStringValue = dot
            } else {
                textField.stringValue = item.name
            }
        case "input":
            textField.stringValue = formatTokens(item.usage.inputTokens)
            textField.alignment = .right
            textField.toolTip = "\(formatExact(item.usage.inputTokens)) tokens"
        case "output":
            textField.stringValue = formatTokens(item.usage.outputTokens)
            textField.alignment = .right
            textField.toolTip = "\(formatExact(item.usage.outputTokens)) tokens"
        case "cacheCreate":
            textField.stringValue = formatTokens(item.usage.cacheCreationInputTokens)
            textField.alignment = .right
            textField.toolTip = "\(formatExact(item.usage.cacheCreationInputTokens)) tokens"
        case "cacheRead":
            textField.stringValue = formatTokens(item.usage.cacheReadInputTokens)
            textField.alignment = .right
            textField.toolTip = "\(formatExact(item.usage.cacheReadInputTokens)) tokens"
        case "total":
            textField.alignment = .right
            let totalStr = formatTokens(item.usage.total)
            if visibleTotalSum > 0 {
                let pct = Double(item.usage.total) / Double(visibleTotalSum) * 100
                let attr = NSMutableAttributedString(string: totalStr, attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                ])
                let pctStr = pct >= 1 ? String(format: "  %.0f%%", pct) : String(format: "  %.1f%%", pct)
                attr.append(NSAttributedString(string: pctStr, attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                ]))
                textField.attributedStringValue = attr
            } else {
                textField.stringValue = totalStr
            }
            textField.toolTip = "\(formatExact(item.usage.total)) tokens · 占 scope 总量 \(visibleTotalSum > 0 ? String(format: "%.1f%%", Double(item.usage.total) / Double(visibleTotalSum) * 100) : "—")"
        case "cost":
            textField.stringValue = formatUSD(item.cost)
            textField.alignment = .right
            textField.toolTip = "按内置近似模型定价估算"
        default:
            textField.stringValue = ""
            textField.toolTip = nil
        }

        return textField
    }

    private func formatExact(_ value: Int) -> String {
        formatExactNumber(value)
    }

    private func formatCount(_ value: Int) -> String {
        formatCompactNumber(value)
    }

    private func formatTokens(_ value: Int) -> String {
        formatCompactNumber(value)
    }

    private func formatUSD(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        formatter.minimumFractionDigits = value >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func scopeTitle(_ scope: DateScope) -> String {
        switch scope {
        case .today:
            return "今天"
        case .week:
            return "近 7 天"
        case .month:
            return "本月"
        case .all:
            return "全部"
        }
    }

    private func groupingTitle(_ grouping: Grouping) -> String {
        switch grouping {
        case .date:
            return "按日期"
        case .project:
            return "按项目"
        case .model:
            return "按模型"
        case .session:
            return "按会话"
        case .source:
            return "按来源"
        }
    }

    private func sourceTitle(_ source: SourceScope) -> String {
        switch source {
        case .all:
            return "全部来源"
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini"
        case .openCode:
            return "OpenCode"
        }
    }
}

func runCLI() {
    loadPricing()
    let scanner = ClaudeUsageScanner()
    let records = scanner.scan(forceRefresh: CommandLine.arguments.contains("--rescan"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    if CommandLine.arguments.contains("--json") {
        if let data = try? encoder.encode(records), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }

    let total = scanner.total(records)
    print("记录：\(formatCompactNumber(records.count))（\(formatExactNumber(records.count))）")
    print("输入：\(formatCompactNumber(total.inputTokens)) tokens（\(formatExactNumber(total.inputTokens))）")
    print("输出：\(formatCompactNumber(total.outputTokens)) tokens（\(formatExactNumber(total.outputTokens))）")
    print("缓存写入：\(formatCompactNumber(total.cacheCreationInputTokens)) tokens（\(formatExactNumber(total.cacheCreationInputTokens))）")
    print("缓存读取：\(formatCompactNumber(total.cacheReadInputTokens)) tokens（\(formatExactNumber(total.cacheReadInputTokens))）")
    print("总计：\(formatCompactNumber(total.total)) tokens（\(formatExactNumber(total.total))）")
    print("缓存库：\(scanner.cachePath)")

    let bySource = scanner.summarize(records, grouping: .source)
    if !bySource.isEmpty {
        print("按来源：")
        for row in bySource {
            print("- \(row.name)：\(formatCompactNumber(row.usage.total)) tokens（\(formatExactNumber(row.usage.total))）")
        }
    }
}

// 语音/麦克风 TCC 授权要求 App 以 LaunchServices 上下文运行（responsible process = 自身）。
// 直接执行 bundle 内二进制时父进程是终端/父 App，责任进程错位 → SFSpeechRecognizer.requestAuthorization
// 触发 TCC SIGABRT 硬崩溃（无法在代码里 catch）。此处检测到该情形则用 open 以正确上下文重启 .app 并退出当前进程。
func relaunchViaLaunchServicesIfNeeded() {
    if ProcessInfo.processInfo.environment["AITOOLS_NO_RELAUNCH"] != nil { return }  // 逃生阀：调试/CI 跳过
    if getppid() == 1 { return }                       // 父进程=launchd ⇒ 已是 Finder/open 正常启动
    let bundlePath = Bundle.main.bundlePath
    guard bundlePath.hasSuffix(".app") else { return } // 非 .app 包（裸编译产物）无从重启，照常运行
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", bundlePath]
    do {
        try task.run()
        task.waitUntilExit()
        exit(0)                                        // 交棒给经 open 以正确上下文启动的新实例
    } catch {
        // 重启失败则继续以当前上下文运行（语音可能不可用，其余功能正常）
    }
}

migrateSupportDirIfNeeded()
if CommandLine.arguments.contains("--cli") {
    runCLI()
} else {
    relaunchViaLaunchServicesIfNeeded()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
