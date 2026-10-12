import Foundation

/// Small text checks the voice layer uses while Lofer is speaking. They only decide whether
/// to STOP THE AUDIO. What actually happens (pausing the device, ending a session) is still
/// decided by the care flow from the final transcript, through the usual safety logic.
enum VoiceInterrupts {
    /// Words that must cut Lofer off straight away: stopping, pausing, or discomfort.
    private static let urgent = "\\b(stop|pause|wait|hold on|enough|hurts?|hurting|pain|painful|sore|too (strong|much|hot|intense)|ouch|ow|burn(s|ing)?|sting(s|ing)?|tingl(e|es|ing)|numb)\\b"

    static func isUrgent(_ text: String) -> Bool {
        text.lowercased().range(of: urgent, options: .regularExpression) != nil
    }

    /// True when what the microphone heard is most likely Lofer's own voice coming back
    /// through the speaker: almost every word heard is a word of the line being spoken.
    /// (iOS echo cancellation removes most of it; this catches what slips through.)
    ///
    /// One urgent word on its own ("stop", "pain") is NEVER treated as an echo, even if Lofer's
    /// line contains it: if in doubt, stopping is the safe mistake. Longer phrases that copy the
    /// line ("numbness, tingling") are echoes, so Lofer's own safety question can't be heard
    /// as the user reporting warning signs.
    static func isEcho(_ heard: String, of line: String?) -> Bool {
        guard let line else { return false }
        let heardWords = Array(Set(words(heard))), lineWords = Set(words(line))
        guard !heardWords.isEmpty, !lineWords.isEmpty else { return false }
        if heardWords.count == 1 { return !isUrgent(heard) && lineWords.contains(heardWords[0]) }
        let matched = heardWords.filter(lineWords.contains).count
        return Double(matched) / Double(heardWords.count) >= 0.8
    }

    /// Enough real speech to count as the user talking over Lofer (not a cough or one stray word).
    static func isBargeIn(_ heard: String) -> Bool { words(heard).count >= 2 }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
}
