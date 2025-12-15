//! Utility functions for the Efficiency Cockpit.

use chrono::{DateTime, Duration, Local, Utc};
use std::path::Path;

/// Format a duration in a human-readable way.
pub fn format_duration(duration: Duration) -> String {
    let total_seconds = duration.num_seconds();

    if total_seconds < 60 {
        format!("{}s", total_seconds)
    } else if total_seconds < 3600 {
        let minutes = total_seconds / 60;
        let seconds = total_seconds % 60;
        if seconds == 0 {
            format!("{}m", minutes)
        } else {
            format!("{}m {}s", minutes, seconds)
        }
    } else if total_seconds < 86400 {
        let hours = total_seconds / 3600;
        let minutes = (total_seconds % 3600) / 60;
        if minutes == 0 {
            format!("{}h", hours)
        } else {
            format!("{}h {}m", hours, minutes)
        }
    } else {
        let days = total_seconds / 86400;
        let hours = (total_seconds % 86400) / 3600;
        if hours == 0 {
            format!("{}d", days)
        } else {
            format!("{}d {}h", days, hours)
        }
    }
}

/// Format a timestamp relative to now.
pub fn format_relative_time(timestamp: DateTime<Utc>) -> String {
    let now = Utc::now();
    let duration = now.signed_duration_since(timestamp);

    if duration.num_seconds() < 0 {
        return "in the future".to_string();
    }

    if duration.num_seconds() < 60 {
        return "just now".to_string();
    }

    format!("{} ago", format_duration(duration))
}

/// Format a timestamp for display in local timezone.
pub fn format_local_time(timestamp: DateTime<Utc>) -> String {
    let local: DateTime<Local> = timestamp.into();
    local.format("%Y-%m-%d %H:%M:%S").to_string()
}

/// Format a date for display.
pub fn format_date(timestamp: DateTime<Utc>) -> String {
    let local: DateTime<Local> = timestamp.into();
    local.format("%Y-%m-%d").to_string()
}

/// Truncate a string to a maximum length, adding ellipsis if needed.
pub fn truncate_string(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else if max_len <= 3 {
        s.chars().take(max_len).collect()
    } else {
        let truncated: String = s.chars().take(max_len - 3).collect();
        format!("{}...", truncated)
    }
}

/// Get the file extension from a path.
pub fn get_extension(path: &Path) -> Option<String> {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_lowercase())
}

/// Check if a path is a text file based on extension.
pub fn is_text_file(path: &Path) -> bool {
    let text_extensions = [
        "rs", "txt", "md", "json", "toml", "yaml", "yml", "py", "js", "ts",
        "html", "css", "xml", "csv", "sh", "bash", "zsh", "go", "java", "c",
        "cpp", "h", "hpp", "rb", "php", "swift", "kt", "scala", "sql",
    ];

    get_extension(path)
        .map(|ext| text_extensions.contains(&ext.as_str()))
        .unwrap_or(false)
}

/// Calculate a percentage, handling division by zero.
pub fn safe_percentage(numerator: u64, denominator: u64) -> f64 {
    if denominator == 0 {
        0.0
    } else {
        (numerator as f64 / denominator as f64) * 100.0
    }
}

/// Format a byte count in human-readable form.
pub fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}

/// Sanitize a string for use as a filename.
pub fn sanitize_filename(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_duration_seconds() {
        assert_eq!(format_duration(Duration::seconds(45)), "45s");
    }

    #[test]
    fn test_format_duration_minutes() {
        assert_eq!(format_duration(Duration::minutes(5)), "5m");
        assert_eq!(format_duration(Duration::seconds(90)), "1m 30s");
    }

    #[test]
    fn test_format_duration_hours() {
        assert_eq!(format_duration(Duration::hours(2)), "2h");
        assert_eq!(format_duration(Duration::minutes(150)), "2h 30m");
    }

    #[test]
    fn test_format_duration_days() {
        assert_eq!(format_duration(Duration::days(3)), "3d");
        assert_eq!(format_duration(Duration::hours(30)), "1d 6h");
    }

    #[test]
    fn test_format_relative_time() {
        let now = Utc::now();
        assert_eq!(format_relative_time(now), "just now");

        let five_min_ago = now - Duration::minutes(5);
        assert_eq!(format_relative_time(five_min_ago), "5m ago");
    }

    #[test]
    fn test_truncate_string() {
        assert_eq!(truncate_string("hello", 10), "hello");
        assert_eq!(truncate_string("hello world", 8), "hello...");
        assert_eq!(truncate_string("hi", 2), "hi");
    }

    #[test]
    fn test_get_extension() {
        assert_eq!(get_extension(Path::new("/path/file.rs")), Some("rs".to_string()));
        assert_eq!(get_extension(Path::new("/path/file.RS")), Some("rs".to_string()));
        assert_eq!(get_extension(Path::new("/path/file")), None);
    }

    #[test]
    fn test_is_text_file() {
        assert!(is_text_file(Path::new("main.rs")));
        assert!(is_text_file(Path::new("readme.md")));
        assert!(!is_text_file(Path::new("image.png")));
        assert!(!is_text_file(Path::new("binary")));
    }

    #[test]
    fn test_safe_percentage() {
        assert_eq!(safe_percentage(50, 100), 50.0);
        assert_eq!(safe_percentage(0, 100), 0.0);
        assert_eq!(safe_percentage(100, 0), 0.0);
    }

    #[test]
    fn test_format_bytes() {
        assert_eq!(format_bytes(500), "500 B");
        assert_eq!(format_bytes(1024), "1.00 KB");
        assert_eq!(format_bytes(1048576), "1.00 MB");
        assert_eq!(format_bytes(1073741824), "1.00 GB");
    }

    #[test]
    fn test_sanitize_filename() {
        assert_eq!(sanitize_filename("hello world"), "hello_world");
        assert_eq!(sanitize_filename("file/name:bad"), "file_name_bad");
        assert_eq!(sanitize_filename("valid-name_123.txt"), "valid-name_123.txt");
    }
}
