#if os(iOS)
import AVFoundation

/// Configures the shared `AVAudioSession` for live-TV playback. Must be called
/// before VLC's first `play()` so VLC's audio unit attaches to a `.playback`
/// session — otherwise VLC may settle on `.soloAmbient` and audio cuts when
/// the app is backgrounded (incompatible with system PIP).
enum AudioSessionConfigurator {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("[Lucent][AudioSession] activate failed: \(error)")
        }
    }
}
#endif
