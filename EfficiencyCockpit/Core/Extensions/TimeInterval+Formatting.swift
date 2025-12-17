import Foundation

extension TimeInterval {
    /// Format duration as "Xh Ym" or "Xm" for shorter durations
    var formattedDuration: String {
        let hours = Int(self) / 3600
        let minutes = (Int(self) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Format duration with seconds for short durations: "Xm Ys" or "Xs"
    var formattedDurationWithSeconds: String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
