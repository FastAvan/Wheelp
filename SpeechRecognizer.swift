import Speech
import AVFoundation
import Observation

/// Reconocimiento de voz (entrada) para la versión Visual.
/// Transcribe en español lo que el usuario dice por el micrófono.
@MainActor
@Observable
final class SpeechRecognizer {
    enum Status { case idle, listening, denied, unavailable }

    var transcript = ""
    var status: Status = .idle

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { status == .listening }

    /// Pide permisos de reconocimiento de voz y micrófono.
    func requestAuthorization() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus == .authorized)
            }
        }
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        let granted = speechGranted && micGranted
        if !granted { status = .denied }
        return granted
    }

    /// Empieza a escuchar y transcribir.
    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            status = .unavailable
            return
        }

        // Limpia cualquier sesión anterior.
        task?.cancel()
        task = nil
        transcript = ""

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        status = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        }
    }

    /// Detiene la escucha (el texto queda en `transcript`).
    func stop() {
        guard status == .listening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        status = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
