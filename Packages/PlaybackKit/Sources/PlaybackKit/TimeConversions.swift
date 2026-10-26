#if os(iOS)

import CoreMedia

// MARK: - Time conversions

extension Duration {
    var cmTime: CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

extension CMTime {
    /// `CMTime` models indefinite and unknown durations, which turn into `NaN`
    /// seconds and would poison every calculation downstream.
    var validDuration: Duration? {
        guard isValid, !isIndefinite, seconds.isFinite, seconds >= 0 else { return nil }
        return .seconds(seconds)
    }
}

#endif
