import Foundation

/// Text cues from one drain batch, inserted into a retained cue array in one merge rather than one
/// `Array.insert` each.
///
/// A catch-up batch can carry thousands of cues (`AetherEngine.subtitleDrainMaxCatchUpPacketsPerTick`).
/// After a seek back, every one of them lands in front of the cues retained from later in the film,
/// so inserting them one at a time moves that whole tail once per cue. The merge moves it once.
///
/// The result is identical to calling `AetherEngine.insertCueSorted` for each cue in decode order:
/// the same dedupe (a cue whose start and flattened text match a retained cue, or one this batch
/// already took, is a re-decode), the same ids stamped in the same order, and the same placement,
/// each cue in front of those already sharing its start, so later cues of a batch sit in front of
/// earlier ones. Bitmap cues and events that trim keep the per-cue path; see `accepts(_:)`.
struct SubtitleCueInsertBatch {
    private var accepted: [SubtitleCue] = []
    private var acceptedTexts: [Double: Set<String>] = [:]

    var isEmpty: Bool { accepted.isEmpty }

    /// Whether every cue of `event` can go through the batch: text only, and nothing that closes
    /// cues already in the array, whose order relative to the inserts would then matter.
    static func accepts(_ event: EmbeddedSubtitleDecoder.SubtitleEvent) -> Bool {
        !event.isPGS && event.pgsTrimAt == nil && event.textTrimAt == nil
            && event.cues.allSatisfy { $0.text != nil }
    }

    /// Takes `cue` unless it re-decodes a cue in `cues` or one this batch already took. Returns
    /// whether it was taken; a taken cue consumes the next id, as `insertCueSorted` would.
    mutating func add(_ cue: SubtitleCue, existing cues: [SubtitleCue], nextID: inout Int) -> Bool {
        guard let text = cue.text else {
            preconditionFailure("SubtitleCueInsertBatch takes text cues only; see accepts(_:)")
        }
        if acceptedTexts[cue.startTime]?.contains(text) == true { return false }
        var index = AetherEngine.lowerBoundByStartTime(cue.startTime, in: cues)
        while index < cues.count, cues[index].startTime == cue.startTime {
            if cues[index].text == text { return false }
            index += 1
        }
        accepted.append(cue.with(id: nextID))
        nextID += 1
        acceptedTexts[cue.startTime, default: []].insert(text)
        return true
    }

    /// Merges the taken cues into `cues` and empties the batch. Returns whether `cues` changed.
    @discardableResult
    mutating func merge(into cues: inout [SubtitleCue]) -> Bool {
        guard !accepted.isEmpty else { return false }
        // Ascending start; within one start, newest first, as successive front inserts leave them.
        let incoming = accepted.enumerated()
            .sorted { $0.element.startTime != $1.element.startTime
                ? $0.element.startTime < $1.element.startTime : $0.offset > $1.offset }
            .map(\.element)
        var merged: [SubtitleCue] = []
        merged.reserveCapacity(cues.count + incoming.count)
        var existing = 0, next = 0
        while existing < cues.count || next < incoming.count {
            if next < incoming.count,
               existing == cues.count || incoming[next].startTime <= cues[existing].startTime {
                merged.append(incoming[next])
                next += 1
            } else {
                merged.append(cues[existing])
                existing += 1
            }
        }
        cues = merged
        accepted = []
        acceptedTexts = [:]
        return true
    }
}
