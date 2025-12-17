import Foundation
import SwiftData

/// Index entry for a file's content (code, docs, notes).
/// Enables full-text search across code, documentation, and notes.
@Model
final class ContentIndex {
    /// Threshold for automatic re-indexing (in seconds). Default: 24 hours.
    static var reindexThresholdSeconds: TimeInterval = 86400

    @Attribute(.unique) var id: UUID

    // MARK: - File Identification

    /// Absolute path to the file
    var filePath: String

    /// Parent project/repo path
    var projectPath: String

    /// Path relative to project root
    var relativePath: String

    /// Just the filename
    var fileName: String

    /// File extension (without dot)
    var fileExtension: String

    // MARK: - Content

    /// Full text content (up to limit)
    var content: String

    /// SHA256 hash for change detection
    var contentHash: String

    /// Number of lines in file
    var lineCount: Int

    // MARK: - Metadata

    /// Type of file: code, documentation, configuration, other
    var fileType: ContentFileType

    /// Programming language if applicable
    var language: String?

    /// When file was last modified
    var lastModified: Date

    /// When we last indexed this file
    var lastIndexed: Date

    // MARK: - Flags

    /// File changed since last index
    var isStale: Bool

    /// Indexing failed for this file
    var indexingFailed: Bool

    /// Reason for indexing failure
    var failureReason: String?

    init(
        id: UUID = UUID(),
        filePath: String,
        projectPath: String,
        content: String,
        contentHash: String,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.filePath = filePath
        self.projectPath = projectPath

        // Calculate relative path
        if filePath.hasPrefix(projectPath) {
            let startIndex = filePath.index(filePath.startIndex, offsetBy: projectPath.count)
            var relative = String(filePath[startIndex...])
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
            self.relativePath = relative
        } else {
            self.relativePath = filePath
        }

        let url = URL(fileURLWithPath: filePath)
        self.fileName = url.lastPathComponent
        let ext = url.pathExtension
        self.fileExtension = ext

        self.content = content
        self.contentHash = contentHash
        self.lineCount = content.components(separatedBy: .newlines).count

        // Use local variable ext instead of self.fileExtension
        self.fileType = ContentFileType.detect(extension: ext)
        self.language = ContentFileType.detectLanguage(extension: ext)
        self.lastModified = lastModified
        self.lastIndexed = Date()

        self.isStale = false
        self.indexingFailed = false
    }

    // MARK: - Computed Properties

    /// Length of content (computed from content string)
    var contentLength: Int {
        content.count
    }

    /// Display-friendly project name
    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// Time since last indexing
    var timeSinceIndexed: TimeInterval {
        Date().timeIntervalSince(lastIndexed)
    }

    /// Whether this file needs re-indexing
    var needsReindex: Bool {
        isStale || timeSinceIndexed > Self.reindexThresholdSeconds
    }
}

// MARK: - Content File Type

enum ContentFileType: String, Codable, CaseIterable {
    case code
    case documentation
    case configuration
    case other

    var displayName: String {
        switch self {
        case .code: return "Code"
        case .documentation: return "Documentation"
        case .configuration: return "Configuration"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .documentation: return "doc.text"
        case .configuration: return "gearshape"
        case .other: return "doc"
        }
    }

    /// Detect file type from extension
    static func detect(extension ext: String) -> ContentFileType {
        let codeExtensions = Set([
            "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs",
            "java", "kt", "rb", "c", "cpp", "h", "hpp", "cs",
            "php", "scala", "clj", "ex", "exs", "hs", "ml",
            "vue", "svelte", "astro", "lua", "r", "jl", "zig",
            "nim", "dart", "groovy", "perl", "sh", "bash", "zsh"
        ])
        let docExtensions = Set([
            "md", "markdown", "txt", "rst", "adoc", "org", "tex",
            "html", "htm", "asciidoc"
        ])
        let configExtensions = Set([
            "json", "yaml", "yml", "toml", "xml", "plist",
            "ini", "conf", "config", "env", "properties",
            "editorconfig", "gitignore", "dockerignore"
        ])

        let lower = ext.lowercased()
        if codeExtensions.contains(lower) { return .code }
        if docExtensions.contains(lower) { return .documentation }
        if configExtensions.contains(lower) { return .configuration }
        return .other
    }

    /// Detect programming language from extension
    static func detectLanguage(extension ext: String) -> String? {
        let mapping: [String: String] = [
            // Languages
            "swift": "Swift",
            "ts": "TypeScript", "tsx": "TypeScript",
            "js": "JavaScript", "jsx": "JavaScript",
            "py": "Python",
            "go": "Go",
            "rs": "Rust",
            "java": "Java",
            "kt": "Kotlin", "kts": "Kotlin",
            "rb": "Ruby",
            "c": "C",
            "cpp": "C++", "cc": "C++", "cxx": "C++",
            "h": "C/C++ Header", "hpp": "C++ Header",
            "cs": "C#",
            "php": "PHP",
            "scala": "Scala",
            "clj": "Clojure", "cljs": "ClojureScript",
            "ex": "Elixir", "exs": "Elixir",
            "hs": "Haskell",
            "ml": "OCaml",
            "vue": "Vue",
            "svelte": "Svelte",
            "lua": "Lua",
            "r": "R",
            "jl": "Julia",
            "zig": "Zig",
            "nim": "Nim",
            "dart": "Dart",
            "groovy": "Groovy",
            "perl": "Perl", "pl": "Perl",
            "sh": "Shell", "bash": "Bash", "zsh": "Zsh",

            // Markup/Data
            "md": "Markdown", "markdown": "Markdown",
            "json": "JSON",
            "yaml": "YAML", "yml": "YAML",
            "toml": "TOML",
            "xml": "XML",
            "html": "HTML", "htm": "HTML",
            "css": "CSS",
            "scss": "SCSS",
            "sass": "Sass",
            "less": "Less"
        ]
        return mapping[ext.lowercased()]
    }
}
