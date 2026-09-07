import Foundation
import FlowCloneCore

/// Writing-tone presets applied by the cleanup LLM. The preset data lives in
/// FlowCloneCore (`TonePreset`, shared with iOS); this alias keeps every macOS
/// call site reading `Tone.all` / `Tone.current` unchanged.
typealias Tone = TonePreset

extension TonePreset {
    /// The preset selected in Settings, falling back to the faithful default.
    static var current: TonePreset { preset(id: Settings.tone) }
}
