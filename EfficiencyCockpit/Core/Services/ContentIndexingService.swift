import Foundation
import SwiftData
import CryptoKit

/// Service for indexing code and documentation files for full-text search.
/// Enables searching "where did I use X?" across all indexed content.
@MainActor
final class ContentIndexingService: ObservableObject {
    static let shared = ContentIndexingService()

    @Published var isIndexing = false
    @Published var indexedFileCount = 0
    @Published var lastIndexTime: Date?
    @Published var currentProject: String?

    private var modelContext: ModelContext?

    // Configuration
    private let maxFileSize = 1_000_000      // 1MB max per file
    private let maxContentLength = 100_000   // Store first 100KB of content
    private let maxFilesPerProject = 10_000

    private let indexableExtensions = Set([
        // Code
        "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt",
        "rb", "c", "cpp", "h", "hpp", "cs", "php", "scala", "ex", "exs",
        "vue", "svelte", "lua", "r", "jl", "zig", "nim", "dart",
        "sh", "bash", "zsh",
        // Docs
        "md", "markdown", "txt", "rst", "adoc",
        // Config
        "json", "yaml", "yml", "toml", "xml"
    ])

    private let skipDirectories = Set([
        "node_modules", ".git", ".svn", ".hg", "build", "dist", "target",
        ".build", "DerivedData", "Pods", "vendor", "__pycache__", ".venv",
        "venv", "env", ".idea", ".vscode", ".cache", ".next", ".nuxt",
        "coverage", ".nyc_output", "tmp", "temp", "logs"
    ])

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Project Discovery

    /// Find all git repositories in common locations
    func discoverProjects() -> [String] {
        var projects: [String] = []

        let home = NSHomeDirectory()
        let searchPaths = [
            home + "/Developer",
            home + "/Projects",
            home + "/Code",
            home + "/src",
            home + "/repos",
            home + "/workspace"
        ]

        for basePath in searchPaths {
            projects.append(contentsOf: findGitRepos(in: basePath, maxDepth: 3))
        }

        return projects
    }

    private func findGitRepos(in path: String, maxDepth: Int) -> [String] {
        guard maxDepth > 0 else { return [] }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
            return []
        }

        // Check if this is a git repo
        if contents.contains(".git") {
            return [path]
        }

        // Recurse into subdirectories
        var repos: [String] = []
        for item in contents {
            guard !skipDirectories.contains(item) else { continue }
            guard !item.hasPrefix(".") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                repos.append(contentsOf: findGitRepos(in: fullPath, maxDepth: maxDepth - 1))
            }
        }

        return repos
    }

    // MARK: - Indexing

    /// Index a single project
    func indexProject(_ projectPath: String) async {
        guard let modelContext = modelContext else { return }

        await MainActor.run {
            isIndexing = true
            currentProject = URL(fileURLWithPath: projectPath).lastPathComponent
        }

        defer {
            Task { @MainActor in
                isIndexing = false
                currentProject = nil
            }
        }

        let fm = FileManager.default
        var indexedCount = 0

        // Helper to check for existing indexed file on-demand (avoids loading all at once)
        func getExistingIndex(for path: String) -> ContentIndex? {
            let descriptor = FetchDescriptor<ContentIndex>(
                predicate: #Predicate { $0.filePath == path }
            )
            return try? modelContext.fetch(descriptor).first
        }

        // Walk the project directory
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectPath),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            // Skip directories in skip list
            if skipDirectories.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            // Check if indexable
            guard indexableExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            // Check file size and attributes
            guard let attrs = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  attrs.isRegularFile == true,
                  let size = attrs.fileSize, size <= maxFileSize,
                  let modDate = attrs.contentModificationDate else {
                continue
            }

            let filePath = fileURL.path

            // Check if already indexed and unchanged (on-demand lookup to save memory)
            if let existing = getExistingIndex(for: filePath) {
                if existing.lastModified >= modDate && !existing.isStale {
                    continue  // Already up to date
                }
                // Mark for update - delete old entry
                modelContext.delete(existing)
            }

            // Read and index file
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            let truncatedContent = String(content.prefix(maxContentLength))
            let hash = computeHash(content)

            let indexEntry = ContentIndex(
                filePath: filePath,
                projectPath: projectPath,
                content: truncatedContent,
                contentHash: hash,
                lastModified: modDate
            )

            modelContext.insert(indexEntry)
            indexedCount += 1

            // Batch save every 100 files
            if indexedCount % 100 == 0 {
                try? modelContext.save()
            }

            // Respect limits
            if indexedCount >= maxFilesPerProject {
                break
            }
        }

        try? modelContext.save()

        await MainActor.run {
            self.indexedFileCount += indexedCount
            self.lastIndexTime = Date()
        }
    }

    /// Index all discovered projects
    func indexAllProjects() async {
        let projects = discoverProjects()
        for project in projects {
            await indexProject(project)
        }
    }

    /// Incremental update for a specific file
    func updateFile(_ filePath: String, projectPath: String) async {
        guard let modelContext = modelContext else { return }

        let fm = FileManager.default
        let fileURL = URL(fileURLWithPath: filePath)

        // Delete existing entry
        let descriptor = FetchDescriptor<ContentIndex>(
            predicate: #Predicate { $0.filePath == filePath }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
        }

        // Re-index if file still exists and is within size limit
        guard fm.fileExists(atPath: filePath),
              let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = attrs.fileSize, size <= maxFileSize,
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            try? modelContext.save()
            return
        }

        let truncatedContent = String(content.prefix(maxContentLength))
        let hash = computeHash(content)

        let indexEntry = ContentIndex(
            filePath: filePath,
            projectPath: projectPath,
            content: truncatedContent,
            contentHash: hash
        )

        modelContext.insert(indexEntry)
        try? modelContext.save()
    }

    /// Mark all files in a project as potentially stale (needs re-check)
    func markProjectStale(_ projectPath: String) async {
        guard let modelContext = modelContext else { return }

        let descriptor = FetchDescriptor<ContentIndex>(
            predicate: #Predicate { $0.projectPath == projectPath }
        )

        guard let files = try? modelContext.fetch(descriptor) else { return }

        for file in files {
            file.isStale = true
        }

        try? modelContext.save()
    }

    /// Get indexing statistics
    /// Optimized to avoid loading all files into memory
    func getStats() -> ContentIndexStats {
        guard let modelContext = modelContext else {
            return ContentIndexStats(totalFiles: 0, totalProjects: 0, totalSize: 0, lastIndexed: nil)
        }

        // Get total file count efficiently
        let countDescriptor = FetchDescriptor<ContentIndex>()
        let count = (try? modelContext.fetchCount(countDescriptor)) ?? 0

        // Fetch only projectPath and content.count to minimize memory usage
        // Use a lightweight descriptor that only fetches what we need
        var totalSize = 0
        var projectPaths = Set<String>()

        // Fetch in batches to avoid memory spikes
        let batchSize = 500
        var offset = 0
        var hasMore = true

        while hasMore {
            var descriptor = FetchDescriptor<ContentIndex>()
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset

            guard let batch = try? modelContext.fetch(descriptor) else { break }
            hasMore = batch.count == batchSize

            for file in batch {
                projectPaths.insert(file.projectPath)
                totalSize += file.content.count
            }

            offset += batchSize
        }

        return ContentIndexStats(
            totalFiles: count,
            totalProjects: projectPaths.count,
            totalSize: totalSize,
            lastIndexed: lastIndexTime
        )
    }

    // MARK: - Helpers

    private func computeHash(_ content: String) -> String {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Stats Structure

struct ContentIndexStats {
    let totalFiles: Int
    let totalProjects: Int
    let totalSize: Int
    let lastIndexed: Date?

    var totalSizeFormatted: String {
        let kb = Double(totalSize) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}
