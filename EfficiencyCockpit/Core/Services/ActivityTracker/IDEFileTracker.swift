import Foundation
import AppKit

/// Tracks file and project information from IDEs
final class IDEFileTracker {

    struct IDEContext {
        let filePath: String?
        let fileName: String?
        let projectPath: String?
        let projectName: String?
        let language: String?
        let ideName: String
        let ideBundleId: String
    }

    // Supported IDEs
    static let supportedIDEs: [String: String] = [
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.microsoft.VSCodeInsiders": "Visual Studio Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.apple.dt.Xcode": "Xcode",
        "com.jetbrains.intellij": "IntelliJ IDEA",
        "com.jetbrains.WebStorm": "WebStorm",
        "com.jetbrains.pycharm": "PyCharm",
        "com.sublimetext.4": "Sublime Text",
        "com.panic.Nova": "Nova",
        "dev.zed.Zed": "Zed"
    ]

    /// Get IDE context from window title
    func getIDEContext(bundleId: String, windowTitle: String?) -> IDEContext? {
        guard let ideName = Self.supportedIDEs[bundleId],
              let title = windowTitle else {
            return nil
        }

        switch bundleId {
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92":
            return parseVSCodeTitle(title, ideName: ideName, bundleId: bundleId)
        case "com.apple.dt.Xcode":
            return parseXcodeTitle(title, bundleId: bundleId)
        case "com.jetbrains.intellij", "com.jetbrains.WebStorm", "com.jetbrains.pycharm":
            return parseJetBrainsTitle(title, ideName: ideName, bundleId: bundleId)
        case "com.sublimetext.4":
            return parseSublimeTitle(title, bundleId: bundleId)
        case "dev.zed.Zed":
            return parseZedTitle(title, bundleId: bundleId)
        default:
            return IDEContext(
                filePath: nil,
                fileName: extractFileName(from: title),
                projectPath: nil,
                projectName: nil,
                language: nil,
                ideName: ideName,
                ideBundleId: bundleId
            )
        }
    }

    // MARK: - VSCode / Cursor

    /// Parse VSCode/Cursor window title
    /// Format: "filename.ext — project-name" or "filename.ext — folder"
    private func parseVSCodeTitle(_ title: String, ideName: String, bundleId: String) -> IDEContext {
        var fileName: String?
        var projectName: String?

        // Split by em-dash (—) which VSCode uses
        if let dashRange = title.range(of: " — ") {
            fileName = String(title[..<dashRange.lowerBound])
            projectName = String(title[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Remove any additional suffixes like "[Extension Development Host]"
            if let proj = projectName, let bracketRange = proj.range(of: " [") {
                projectName = String(proj[..<bracketRange.lowerBound])
            }
        } else {
            fileName = title
        }

        let language = detectLanguage(from: fileName)

        return IDEContext(
            filePath: nil, // Would need file system access to resolve full path
            fileName: fileName,
            projectPath: nil,
            projectName: projectName,
            language: language,
            ideName: ideName,
            ideBundleId: bundleId
        )
    }

    // MARK: - Xcode

    /// Parse Xcode window title
    /// Format: "filename.swift — ProjectName" or "ProjectName — Editing scheme"
    private func parseXcodeTitle(_ title: String, bundleId: String) -> IDEContext {
        var fileName: String?
        var projectName: String?

        if let dashRange = title.range(of: " — ") {
            let leftPart = String(title[..<dashRange.lowerBound])
            let rightPart = String(title[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Check if left part looks like a file
            if leftPart.contains(".") {
                fileName = leftPart
                projectName = rightPart
            } else {
                // Might be "ProjectName — Something else"
                projectName = leftPart
            }
        } else if title.hasSuffix(".xcodeproj") || title.hasSuffix(".xcworkspace") {
            projectName = title
        }

        let language = detectLanguage(from: fileName)

        return IDEContext(
            filePath: nil,
            fileName: fileName,
            projectPath: nil,
            projectName: projectName,
            language: language,
            ideName: "Xcode",
            ideBundleId: bundleId
        )
    }

    // MARK: - JetBrains IDEs

    /// Parse JetBrains IDE window title
    /// Format: "project-name – filename.ext" or "project-name [~/path/to/project]"
    private func parseJetBrainsTitle(_ title: String, ideName: String, bundleId: String) -> IDEContext {
        var fileName: String?
        var projectName: String?
        var projectPath: String?

        // Check for path in brackets
        if let bracketStart = title.range(of: " ["),
           let bracketEnd = title.range(of: "]", range: bracketStart.upperBound..<title.endIndex) {
            projectPath = String(title[bracketStart.upperBound..<bracketEnd.lowerBound])
            projectName = String(title[..<bracketStart.lowerBound])
        }

        // Check for file after en-dash (–)
        if let dashRange = title.range(of: " – ") {
            if projectName == nil {
                projectName = String(title[..<dashRange.lowerBound])
            }
            let afterDash = String(title[dashRange.upperBound...])
            if !afterDash.contains("[") {
                fileName = afterDash.trimmingCharacters(in: .whitespaces)
            }
        }

        let language = detectLanguage(from: fileName)

        return IDEContext(
            filePath: nil,
            fileName: fileName,
            projectPath: projectPath,
            projectName: projectName,
            language: language,
            ideName: ideName,
            ideBundleId: bundleId
        )
    }

    // MARK: - Sublime Text

    private func parseSublimeTitle(_ title: String, bundleId: String) -> IDEContext {
        // Format: "filename.ext - Project Name - Sublime Text" or "filename.ext • edited - Sublime Text"
        var fileName: String?
        var projectName: String?

        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2 {
            fileName = parts[0].replacingOccurrences(of: " •", with: "").trimmingCharacters(in: .whitespaces)
            if parts.count >= 3 && parts[parts.count - 1] == "Sublime Text" {
                projectName = parts[1]
            }
        }

        return IDEContext(
            filePath: nil,
            fileName: fileName,
            projectPath: nil,
            projectName: projectName,
            language: detectLanguage(from: fileName),
            ideName: "Sublime Text",
            ideBundleId: bundleId
        )
    }

    // MARK: - Zed

    private func parseZedTitle(_ title: String, bundleId: String) -> IDEContext {
        // Format: "filename.ext — project-name — Zed"
        var fileName: String?
        var projectName: String?

        let parts = title.components(separatedBy: " — ")
        if parts.count >= 2 {
            fileName = parts[0]
            projectName = parts[1]
        }

        return IDEContext(
            filePath: nil,
            fileName: fileName,
            projectPath: nil,
            projectName: projectName,
            language: detectLanguage(from: fileName),
            ideName: "Zed",
            ideBundleId: bundleId
        )
    }

    // MARK: - Helpers

    private func extractFileName(from title: String) -> String? {
        // Try to extract what looks like a filename
        let parts = title.components(separatedBy: " — ")
        if let first = parts.first, first.contains(".") {
            return first
        }
        return nil
    }

    /// Detect programming language from file extension
    func detectLanguage(from fileName: String?) -> String? {
        guard let name = fileName,
              let ext = name.components(separatedBy: ".").last?.lowercased() else {
            return nil
        }

        let languageMap: [String: String] = [
            // Swift
            "swift": "Swift",
            // JavaScript/TypeScript
            "js": "JavaScript",
            "jsx": "JavaScript",
            "ts": "TypeScript",
            "tsx": "TypeScript",
            // Python
            "py": "Python",
            "pyw": "Python",
            // Rust
            "rs": "Rust",
            // Go
            "go": "Go",
            // Ruby
            "rb": "Ruby",
            // Java/Kotlin
            "java": "Java",
            "kt": "Kotlin",
            "kts": "Kotlin",
            // C/C++
            "c": "C",
            "h": "C",
            "cpp": "C++",
            "cc": "C++",
            "hpp": "C++",
            // C#
            "cs": "C#",
            // PHP
            "php": "PHP",
            // Web
            "html": "HTML",
            "htm": "HTML",
            "css": "CSS",
            "scss": "SCSS",
            "sass": "SASS",
            "less": "LESS",
            // Data
            "json": "JSON",
            "xml": "XML",
            "yaml": "YAML",
            "yml": "YAML",
            "toml": "TOML",
            // Shell
            "sh": "Shell",
            "bash": "Bash",
            "zsh": "Zsh",
            // Markdown
            "md": "Markdown",
            "markdown": "Markdown",
            // SQL
            "sql": "SQL",
            // Other
            "dockerfile": "Dockerfile",
            "makefile": "Makefile"
        ]

        return languageMap[ext]
    }

    /// Check if a file extension indicates code
    func isCodeFile(_ fileName: String?) -> Bool {
        return detectLanguage(from: fileName) != nil
    }
}
