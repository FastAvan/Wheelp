import AVFoundation
import Observation
import UIKit

/// Lectura en voz alta para la versión Visual (guía hablada).
/// Usa síntesis de voz; no requiere permisos de micrófono.
@Observable
final class SpeechAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    var isEnabled = false
    var isSpeaking = false
    /// Velocidad de habla (rate de AVSpeechUtterance). Ajustable desde Ajustes.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    /// Locución vigente: los callbacks de locuciones antiguas canceladas se ignoran,
    /// para que interrumpir un anuncio no borre el `completion` del siguiente.
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Configura la sesión de audio para que la voz suene incluso en silencio.
    func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
    }

    /// Lee el texto y, si se indica, ejecuta `then` cuando termina de hablar.
    func announce(_ text: String, then: (() -> Void)? = nil) {
        guard isEnabled, !text.isEmpty else {
            then?()
            return
        }
        // Con VoiceOver activo, el lector del sistema ya narra la pantalla:
        // no duplicamos voz propia, pero el flujo (p. ej. escuchar después) sigue.
        guard !UIAccessibility.isVoiceOverRunning else {
            then?()
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate = rate
        completion = then
        currentUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Igual que `announce`, pero para contenido que NO tiene ninguna
    /// representación en pantalla — VoiceOver no tiene qué narrar por su
    /// cuenta, así que `announce` normal se calla y deja el flujo mudo. Se
    /// usa solo para lo que de verdad no puede quedar en silencio: pedir
    /// consentimiento antes de compartir datos con un ayudante.
    ///
    /// Antes de este método, con VoiceOver activo la pregunta de
    /// consentimiento nunca se pronunciaba, pero el micrófono se abría igual
    /// para escuchar la respuesta: la persona daba "sí" o "no" a una
    /// pregunta que jamás llegó a oír.
    func announceConsent(_ text: String, then: @escaping () -> Void = {}) {
        guard !text.isEmpty else { then(); return }
        guard !UIAccessibility.isVoiceOverRunning else {
            UIAccessibility.post(notification: .announcement, argument: text)
            // VoiceOver no avisa cuándo termina de hablar el anuncio; un
            // margen proporcional al texto evita abrir el micrófono a mitad
            // de frase.
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(text.count) * 0.06 + 0.6, execute: then)
            return
        }
        announce(text, then: then)
    }

    func stop() {
        completion = nil
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        isSpeaking = false
        currentUtterance = nil
        let callback = completion
        completion = nil
        callback?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        isSpeaking = false
        currentUtterance = nil
        completion = nil
    }
}
