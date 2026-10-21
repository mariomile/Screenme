import CoreMedia

/// Maps capture time to file time across pauses, for every track alike. Paused time is cut out,
/// so the file plays as one seamless take.
///
/// A sample is written only when it lies entirely inside the current stretch of recording: one that
/// straddles a pause or a resume is dropped, so no two samples of a track can overlap in the file.
struct PauseTimeline {
    /// Capture time the file starts at.
    let start: CMTime
    /// Capture time the current stretch began at: the session start, or the last resume.
    private var stretchStart: CMTime
    /// Paused time cut out so far.
    private var cut = CMTime.zero
    private var pausedAt: CMTime?

    init(start: CMTime) {
        self.start = start
        stretchStart = start
    }

    var isPaused: Bool { pausedAt != nil }

    mutating func pause(at time: CMTime) {
        guard pausedAt == nil else { return }
        pausedAt = CMTimeMaximum(time, stretchStart)
    }

    mutating func resume(at time: CMTime) {
        guard let pausedAt else { return }
        let now = CMTimeMaximum(time, pausedAt)
        cut = CMTimeAdd(cut, CMTimeSubtract(now, pausedAt))
        stretchStart = now
        self.pausedAt = nil
    }

    /// The file time of a sample captured at `time` that lasts `duration` (zero for a picture),
    /// or nil when it is not entirely inside the current stretch.
    func outputTime(for time: CMTime, duration: CMTime) -> CMTime? {
        guard time >= stretchStart else { return nil }
        if let pausedAt {
            let end = duration.isNumeric ? CMTimeAdd(time, duration) : time
            guard time < pausedAt, end <= pausedAt else { return nil }
        }
        return CMTimeSubtract(time, cut)
    }

    /// Seconds into the video of something that happens at capture time `time`, for the events of a recording.
    /// Nil while paused, so what happens then is left out like the pictures.
    func videoSeconds(at time: CMTime) -> Double? {
        outputTime(for: time, duration: .zero).map { CMTimeSubtract($0, start).seconds }
    }

    /// The file time a recording stopped at `time` ends at. While paused, that is where the pause began.
    func end(at time: CMTime) -> CMTime {
        CMTimeSubtract(pausedAt ?? CMTimeMaximum(time, stretchStart), cut)
    }
}
