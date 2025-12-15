//! CLI output helpers with colorization.
//!
//! This module provides utilities for colorized terminal output.

use colored::Colorize;

/// Print a success message in green.
pub fn success(message: &str) {
    println!("{}", message.green());
}

/// Print an info message in blue.
pub fn info(message: &str) {
    println!("{}", message.blue());
}

/// Print a warning message in yellow.
pub fn warning(message: &str) {
    println!("{}", message.yellow());
}

/// Print an error message in red.
pub fn error(message: &str) {
    eprintln!("{}", message.red());
}

/// Print a header/title in bold cyan.
pub fn header(message: &str) {
    println!("{}", message.cyan().bold());
}

/// Print a section label in bold.
pub fn label(message: &str) {
    print!("{}", message.bold());
}

/// Format a key-value pair for display.
pub fn key_value(key: &str, value: &str) {
    println!("  {}: {}", key.bold(), value);
}

/// Format a status indicator.
pub fn status(label: &str, is_ok: bool) {
    let indicator = if is_ok {
        "[OK]".green()
    } else {
        "[MISSING]".red()
    };
    println!("    - {} {}", label, indicator);
}

/// Format a priority indicator for nudges.
pub fn priority_badge(priority: &str) -> String {
    match priority.to_uppercase().as_str() {
        "HIGH" => "[HIGH]".red().bold().to_string(),
        "MEDIUM" => "[MEDIUM]".yellow().bold().to_string(),
        "LOW" => "[LOW]".blue().to_string(),
        _ => format!("[{}]", priority),
    }
}

/// Format a score with color gradient.
pub fn score(value: f32) -> String {
    let formatted = format!("{:.2}", value);
    if value >= 0.8 {
        formatted.green().to_string()
    } else if value >= 0.5 {
        formatted.yellow().to_string()
    } else {
        formatted.red().to_string()
    }
}

/// Print a divider line.
pub fn divider() {
    println!("{}", "─".repeat(40).dimmed());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_priority_badge_high() {
        let badge = priority_badge("HIGH");
        assert!(badge.contains("HIGH"));
    }

    #[test]
    fn test_priority_badge_medium() {
        let badge = priority_badge("MEDIUM");
        assert!(badge.contains("MEDIUM"));
    }

    #[test]
    fn test_priority_badge_low() {
        let badge = priority_badge("LOW");
        assert!(badge.contains("LOW"));
    }

    #[test]
    fn test_score_high() {
        let s = score(0.9);
        assert!(s.contains("0.90"));
    }

    #[test]
    fn test_score_medium() {
        let s = score(0.6);
        assert!(s.contains("0.60"));
    }

    #[test]
    fn test_score_low() {
        let s = score(0.3);
        assert!(s.contains("0.30"));
    }
}
