import Foundation

/// Which optional effects an edit uses. All are off for a new take, and every effect is
/// behind its flag, so an edit that uses none renders exactly as before they existed.
struct RenderFeatures: Equatable {
    /// Text that rises, pops, focuses or types on (fade is the original behaviour).
    var animatedText = false
    var cutTransitions = false
    var speedRamps = false
    /// Fades at cuts, or muting sped-up parts.
    var audioEnvelope = false
    var cameraMoves = false

    init(
        animatedText: Bool = false,
        cutTransitions: Bool = false,
        speedRamps: Bool = false,
        audioEnvelope: Bool = false,
        cameraMoves: Bool = false
    ) {
        self.animatedText = animatedText
        self.cutTransitions = cutTransitions
        self.speedRamps = speedRamps
        self.audioEnvelope = audioEnvelope
        self.cameraMoves = cameraMoves
    }

    init(settings: ProjectEditSettings) {
        self.init(
            animatedText: settings.textOverlays.contains { $0.animation != .fade },
            cutTransitions: settings.cutTransition != nil,
            speedRamps: settings.timeline?.hasSpeedRamps ?? false,
            audioEnvelope: settings.audio.cutFades || settings.audio.muteSpedUp,
            cameraMoves: false
        )
    }

    /// No optional effect at all.
    var isEmpty: Bool {
        self == RenderFeatures()
    }
}
