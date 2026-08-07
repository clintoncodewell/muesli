import FluidAudio
import Foundation
import MuesliCore

enum TranscriptFormatter {
    /// Backward-compatible merge without diarization.
    static func merge(micSegments: [SpeechSegment], systemSegments: [SpeechSegment], meetingStart: Date) -> String {
        merge(micSegments: micSegments, systemSegments: systemSegments, diarizationSegments: nil, meetingStart: meetingStart)
    }

    /// Merge with optional speaker diarization for system audio.
    static func merge(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        meetingStart: Date
    ) -> String {
        // The formatter is intentionally source-agnostic: upstream capture decides
        // which mic/system segments are valid, then this layer only labels/merges.
        let displayMicSegments = micSegments
        let taggedMic = displayMicSegments.map { TaggedSegment(segment: $0, speaker: "You") }

        let taggedSystem: [TaggedSegment]
        if let diarizationSegments, !diarizationSegments.isEmpty {
            // Build speaker label map: raw ID → "Speaker 1", "Speaker 2", etc. in first-appearance order
            var speakerLabelMap: [String: String] = [:]
            var nextSpeakerNumber = 1
            for seg in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                if speakerLabelMap[seg.speakerId] == nil {
                    speakerLabelMap[seg.speakerId] = "Speaker \(nextSpeakerNumber)"
                    nextSpeakerNumber += 1
                }
            }

            taggedSystem = systemSegments.map { segment in
                let speaker = findSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
                return TaggedSegment(segment: segment, speaker: speaker)
            }
        } else {
            taggedSystem = systemSegments.map { TaggedSegment(segment: $0, speaker: "Others") }
        }

        let tagged = (taggedMic + taggedSystem).sorted { $0.segment.start < $1.segment.start }

        // Consolidate consecutive segments from the same speaker into single lines
        let consolidated = consolidate(tagged)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        return consolidated.map { taggedSegment in
            let timestamp = meetingStart.addingTimeInterval(taggedSegment.segment.start)
            let text = taggedSegment.segment.text.trimmingCharacters(in: .whitespaces)
            return "[\(formatter.string(from: timestamp))] \(taggedSegment.speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// Merge consecutive segments from the same speaker into single entries,
    /// but only when they're temporally close (within 2s). This prevents
    /// token-level fragmentation while preserving chronological ordering —
    /// segments from the same speaker that are far apart in time stay separate
    /// so they interleave correctly with other speakers.
    private static let consolidationGapThreshold: TimeInterval = 2.0

    private static func consolidate(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TaggedSegment] = []
        var currentSpeaker = segments[0].speaker
        var currentStart = segments[0].segment.start
        var currentEnd = segments[0].segment.end
        var currentText = segments[0].segment.text

        for seg in segments.dropFirst() {
            let gap = max(0, seg.segment.start - currentEnd)
            if seg.speaker == currentSpeaker && gap <= consolidationGapThreshold {
                // Same speaker, temporally close — accumulate text
                currentText = appendText(currentText, seg.segment.text, gap: gap)
                currentEnd = max(currentEnd, seg.segment.end)
            } else {
                // Different speaker or too far apart — emit and start new segment
                result.append(TaggedSegment(
                    segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
                    speaker: currentSpeaker
                ))
                currentSpeaker = seg.speaker
                currentStart = seg.segment.start
                currentEnd = seg.segment.end
                currentText = seg.segment.text
            }
        }
        // Emit last segment
        result.append(TaggedSegment(
            segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
            speaker: currentSpeaker
        ))

        return result
    }

    /// Find the best-matching speaker for an ASR segment by time overlap with diarization segments.
    private static func findSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> String {
        if labelMap.count == 1 {
            return labelMap.values.first ?? "Others"
        }

        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1)) // ensure non-zero duration

        var bestOverlap: Float = 0
        var bestSpeakerId: String?

        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerId = diarSeg.speakerId
            }
        }

        if let bestSpeakerId, bestOverlap > 0, let label = labelMap[bestSpeakerId] {
            return label
        }

        // The old 2s limit made a third of this user's system segments fall back to "Others",
        // so one transcript carried both "Others" and "Speaker N" for the same human. Widened,
        // but deliberately still bounded: with no limit at all, a meeting where diarization only
        // covered the opening minutes would attribute every later segment to whoever happened to
        // be nearest, which is confidently wrong rather than honestly unknown. Misattributing a
        // quote is worse than declining to name the speaker.
        if let nearestSpeakerId = nearestSpeaker(
            for: segment,
            in: diarizationSegments,
            maxGapSeconds: unattributedSpeakerGapSeconds
        ), let label = labelMap[nearestSpeakerId] {
            return label
        }
        return "Others"
    }

    /// How far a transcript segment may sit from the nearest diarized speech before we stop
    /// guessing who it was.
    private static let unattributedSpeakerGapSeconds: Float = 10


    private static func nearestSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        maxGapSeconds: Float
    ) -> String? {
        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1))
        let segMidpoint = (segStart + segEnd) / 2

        let nearest = diarizationSegments.min { lhs, rhs in
            temporalGap(between: segMidpoint, and: lhs) < temporalGap(between: segMidpoint, and: rhs)
        }

        guard let nearest else { return nil }
        return temporalGap(between: segMidpoint, and: nearest) <= maxGapSeconds ? nearest.speakerId : nil
    }

    private static func temporalGap(
        between point: Float,
        and diarizationSegment: TimedSpeakerSegment
    ) -> Float {
        if point < diarizationSegment.startTimeSeconds {
            return diarizationSegment.startTimeSeconds - point
        }
        if point > diarizationSegment.endTimeSeconds {
            return point - diarizationSegment.endTimeSeconds
        }
        return 0
    }

    private static func appendText(_ lhs: String, _ rhs: String, gap: TimeInterval) -> String {
        if shouldConcatenateDirectly(lhs, rhs, gap: gap) {
            return lhs + rhs
        }
        if shouldRejoinSplitWord(lhs, rhs, gap: gap), joinProducesExpectedWord(lhs, rhs) {
            return lhs + rhs
        }
        return joinText(lhs, rhs)
    }

    /// A trailing token that must never be glued to what follows.
    ///
    /// Only applies to one and two character tokens, so genuine sub-word consolidation of the
    /// recogniser's own token stream ("Hel" + "lo", "wor" + "ld") is untouched.
    private static func isUnsafeJoinFragment(_ token: String) -> Bool {
        guard visibleLength(of: token) <= 2, token.allSatisfy(\.isLetter) else { return false }
        // A real short word: "A" + "lot" must not become "Alot".
        if standaloneShortWords.contains(token.lowercased()) { return true }
        // A two-letter acronym: this user's transcripts are full of "AI opens", "AZ corner".
        if token.count == 2 && token.allSatisfy(\.isUppercase) { return true }
        return false
    }

    /// The joined token must be a word we actually expect to see split by an utterance onset.
    ///
    /// Casing and length heuristics are not enough on their own: initials ("Bob J" + "smith"),
    /// spelled letters ("X" + "ray", which would need a hyphen anyway), technical terms
    /// ("Vitamin B" + "complex") and other languages ("Y" + "entonces") all look identical to a
    /// real split. Rewriting the user's words wrongly is worse than leaving an artifact, so this
    /// is a positive allowlist of the repairs actually observed rather than a negative list of
    /// exceptions, which can never be complete.
    private static func joinProducesExpectedWord(_ lhs: String, _ rhs: String) -> Bool {
        let lhsLastToken = String(lhs.split(whereSeparator: \.isWhitespace).last ?? "")
        let rhsFirstToken = String(rhs.prefix { !$0.isWhitespace })
        let joined = (lhsLastToken + rhsFirstToken).filter(\.isLetter).lowercased()
        return expectedSplitRepairs.contains(joined)
    }

    /// Short discourse words the recogniser splits at an utterance onset. Measured from real
    /// transcripts: "Y ep", "Y es", "Ye ah", "B oth".
    private static let expectedSplitRepairs: Set<String> = [
        "yep", "yes", "yeah", "yup", "yay", "nope", "nah", "okay", "both", "right", "sure",
        "true", "well", "exactly", "correct", "maybe", "sorry", "thanks", "hello", "great",
        "good", "fine", "cool", "agreed", "perfect", "absolutely", "definitely",
    ]

    /// A word split across a chunk boundary, where the following chunk carries a whole phrase.
    ///
    /// The recogniser emits the first phoneme of an utterance as its own token when the chunk
    /// rotates mid-word, producing "Y" + "ep, that works for me" -> "Y ep, that works for me".
    /// `shouldConcatenateDirectly` was written for this but only fires when the ENTIRE next
    /// segment is one token, which is almost never true in a meeting, so the repair never ran.
    ///
    /// Deliberately narrow: the fragment must be CAPITALISED and the continuation lowercase.
    /// That is the unambiguous utterance-onset signature ("Y ep", "B oth", "O tree", "Ye ah").
    /// Lowercase fragments ("th there", "l lens", "od but") are left alone — those are duplicated
    /// onsets or tails of the previous word, and joining them would produce "ththere".
    /// Real short words are excluded so "A lot" and "I think" survive untouched.
    private static func shouldRejoinSplitWord(_ lhs: String, _ rhs: String, gap: TimeInterval) -> Bool {
        guard gap <= 0.35, !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else { return false }
        guard !lhsLast.isWhitespace, !rhsFirst.isWhitespace, !rhsFirst.isPunctuation else { return false }
        guard rhsFirst.isLowercase else { return false }

        let lhsLastToken = String(lhs.split(whereSeparator: \.isWhitespace).last ?? "")
        guard visibleLength(of: lhsLastToken) <= 2 else { return false }
        guard lhsLastToken.allSatisfy(\.isLetter) else { return false }
        guard let fragmentFirst = lhsLastToken.first, fragmentFirst.isUppercase else { return false }
        // A two-letter all-caps token is an acronym, not half a word. This user's transcripts are
        // full of "AI opens", "AZ corner", "RI is" — joining those would produce "AIopens".
        // "Ye" (mixed case, from "Ye ah") is still a split and still joins.
        guard !(lhsLastToken.count == 2 && lhsLastToken.allSatisfy(\.isUppercase)) else { return false }
        guard !standaloneShortWords.contains(lhsLastToken.lowercased()) else { return false }
        return true
    }

    /// One and two letter strings that are real words, so a following lowercase token is a new
    /// word rather than the rest of a split one.
    private static let standaloneShortWords: Set<String> = [
        "a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it",
        "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we",
    ]

    private static func shouldConcatenateDirectly(_ lhs: String, _ rhs: String, gap: TimeInterval) -> Bool {
        guard gap <= 0.35 else { return false }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard !rhs.contains(where: \.isWhitespace) else { return false }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else { return false }
        guard !lhsLast.isWhitespace, !rhsFirst.isWhitespace, !rhsFirst.isPunctuation else { return false }

        let lhsLastToken = lhs.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? lhs
        guard !lhsLastToken.contains(where: \.isWhitespace) else { return false }
        // This path fires on any short single-token continuation, which is right for the
        // recogniser's sub-word tokens but wrong for a real word or acronym at a chunk seam.
        guard !isUnsafeJoinFragment(lhsLastToken) else { return false }

        let lhsVisibleLength = visibleLength(of: lhsLastToken)
        let rhsVisibleLength = visibleLength(of: rhs)
        return lhsVisibleLength + rhsVisibleLength <= 8
    }

    private static func joinText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return lhs + rhs
        }

        if lhsLast.isWhitespace || rhsFirst.isWhitespace || rhsFirst.isPunctuation {
            return lhs + rhs
        }

        if lhsLast.isPunctuation {
            return lhs + " " + rhs
        }

        return lhs + " " + downcasingStrayCapital(rhs)
    }

    /// Each chunk is punctuated and capitalised independently, so a sentence continuing across a
    /// chunk boundary gets a capital in the middle of it: "the data is Are those numbers ours".
    /// Only rewrites a small set of function words — anything not on the list (proper nouns,
    /// acronyms, "I") is left exactly as the recogniser produced it.
    private static func downcasingStrayCapital(_ rhs: String) -> String {
        guard let first = rhs.first, first.isUppercase else { return rhs }
        let tokens = rhs.split(whereSeparator: \.isWhitespace)
        guard let firstToken = tokens.first else { return rhs }
        let bare = firstToken.filter(\.isLetter).lowercased()
        guard midSentenceFunctionWords.contains(bare) else { return rhs }
        // A capitalised word following it means this is probably a title or a name, not a stray
        // seam capital — "The Who", "That Sarah mentioned". Leave those alone.
        if let second = tokens.dropFirst().first, let secondFirst = second.first, secondFirst.isUppercase {
            return rhs
        }
        // Preserve the rest of the token verbatim; only the leading character changes.
        return first.lowercased() + rhs.dropFirst()
    }

    /// Deliberately excludes words that commonly open a genuine sentence the recogniser failed to
    /// punctuate ("It", "This", "There", "They", "He", "She"): lowercasing those hides a real
    /// sentence boundary, which changes how the transcript reads.
    private static let midSentenceFunctionWords: Set<String> = [
        "the", "a", "an", "and", "but", "or", "of", "to", "in", "on", "at", "for", "with", "as",
        "by", "from", "if", "not", "is", "are", "was", "were", "be", "been", "being", "has",
        "have", "had", "than", "then", "because", "just", "about", "into", "over", "which",
        "whether", "while", "though", "although", "unless", "until", "onto", "upon",
    ]

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }

}

private struct TaggedSegment {
    let segment: SpeechSegment
    let speaker: String
}
