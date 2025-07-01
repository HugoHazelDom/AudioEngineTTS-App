import SwiftUI
import AVFoundation
import Foundation
import Combine

// Codable structs for decoding Gemini TTS response
struct GeminiTTSResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let responseType: String?
                let inlineData: InlineData?
                struct InlineData: Decodable {
                    let data: String
                }
            }
            let parts: [Part]
        }
        let content: Content
    }
    let candidates: [Candidate]
}

// MARK: - Briefing Model

struct Briefing: Codable, Identifiable, Equatable {
    let id: UUID
    let topic: String
    let date: Date
    let filename: String
}

// MARK: - Briefings Library

class BriefingsLibraryModel: ObservableObject {
    @Published private(set) var briefings: [Briefing] = []
    private let saveURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        saveURL = docs.appendingPathComponent("briefings.json")
        load()
    }

    func add(topic: String, data: Data) throws {
        let id = UUID()
        let filename = "briefing-\(id).mp3"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent(filename)
        try data.write(to: fileURL)
        let newBriefing = Briefing(id: id, topic: topic, date: Date(), filename: filename)
        briefings.insert(newBriefing, at: 0)
        save()
    }

    func delete(_ briefing: Briefing) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent(briefing.filename)
        try? FileManager.default.removeItem(at: fileURL)
        if let idx = briefings.firstIndex(of: briefing) {
            briefings.remove(at: idx)
            save()
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: saveURL)
            let decoded = try JSONDecoder().decode([Briefing].self, from: data)
            briefings = decoded
        } catch {
            briefings = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(briefings)
            try data.write(to: saveURL)
        } catch {
            print("Failed to save briefings: \(error)")
        }
    }
}

// ✅ Ready to proceed with AVStreamPlayer replacement? Type yes to continue.

// MARK: - Audio Playback Model

class AudioPlaybackModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isReady: Bool = false
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 1
    private var timer: Timer?
    private(set) var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private(set) var lastLoadedData: Data?

    func setAudio(_ data: Data, onFinish: (() -> Void)? = nil) throws {
        // Explicitly hint that this is MP3 content
        player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        player?.delegate = self
        isReady = true
        isPlaying = false
        duration = player?.duration ?? 1
        currentTime = 0
        self.onFinish = onFinish
        lastLoadedData = data
        stopTimer()
    }

    func setAudio(url: URL, onFinish: (() -> Void)? = nil) throws {
        player = try AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        isReady = true
        isPlaying = false
        duration = player?.duration ?? 1
        currentTime = 0
        self.onFinish = onFinish
        lastLoadedData = try? Data(contentsOf: url)
        stopTimer()
    }

    func play() {
        guard isReady, let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        guard isReady, let player else { return }
        player.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        isReady = false
        currentTime = 0
        stopTimer()
    }

    func seek(to progress: Double) {
        guard isReady, let player else { return }
        let newTime = duration * progress
        player.currentTime = newTime
        currentTime = newTime
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        currentTime = duration
        onFinish?()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            if self.currentTime >= self.duration {
                self.currentTime = self.duration
                self.isPlaying = false
                self.stopTimer()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - ContentView

struct ContentView: View {
    // Prompt states
    @State private var topic = ""
    @State private var isLoading = false
    @State private var selectedLength: Int = 60  // seconds, default
    @State private var selectedTone: String = "Professional"
    @State private var showCustomTopicInput = false
    @State private var customTopic = ""
    @StateObject private var playbackModel = AudioPlaybackModel()
    @StateObject private var briefingsModel = BriefingsLibraryModel()
    @State private var generatedScript: String = ""

    /// Words spoken per minute used when estimating script length
    private let wordsPerMinute = 150
    var openAIKey: String {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_KEY"], !key.isEmpty else {
            fatalError("Missing OPENAI_KEY in environment")
        }
        return key
    }

    let trendingTopics = ["Market News", "Quick Tips", "Motivation", "Tech Trends", "Insurance 101"]
    let lengthOptions = [30, 60, 180]
    let tones = ["Professional", "Motivational", "Fun", "Calm"]

    // Add your computed property here:
    var geminiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "API_KEY") as? String ?? ""
    }
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.18),
                    Color(.systemIndigo).opacity(0.17),
                    Color(.systemGray6)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 32) {
                    HStack {
                        Spacer()
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .foregroundColor(.blue)
                            .shadow(color: Color.blue.opacity(0.3), radius: 10, y: 2)
                        Spacer()
                    }
                    .padding(.top, 4)

                    Text("AI Audio Briefing")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
                        .padding(.bottom, 0)

                    Text("Create a custom, spoken update in seconds.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    // -- Upgraded: Topic chips + custom input --
                    VStack(spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(trendingTopics, id: \.self) { chip in
                                    Button {
                                        topic = chip
                                    } label: {
                                        Text(chip)
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 8)
                                            .background(topic == chip ? Color.blue : Color.gray.opacity(0.13))
                                            .foregroundColor(topic == chip ? .white : .primary)
                                            .font(.headline)
                                            .cornerRadius(18)
                                    }
                                }
                                Button {
                                    topic = ""
                                    showCustomTopicInput = true
                                } label: {
                                    HStack {
                                        Image(systemName: "square.and.pencil")
                                        Text("Custom")
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(topic.isEmpty ? Color.orange.opacity(0.18) : Color.gray.opacity(0.13))
                                    .cornerRadius(18)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        // If custom topic dialog is up, show a sheet
                        .sheet(isPresented: $showCustomTopicInput) {
                            VStack(spacing: 18) {
                                Text("Enter your topic")
                                    .font(.title2)
                                TextField("Custom topic", text: $customTopic)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .padding()
                                Button("Use Topic") {
                                    topic = customTopic
                                    showCustomTopicInput = false
                                }
                                .disabled(customTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                        }
                    }

                    // -- Quick length selector --
                    HStack {
                        ForEach(lengthOptions, id: \.self) { secs in
                            Button {
                                selectedLength = secs
                            } label: {
                                VStack {
                                    Text(secs == 180 ? "3 min" : "\(secs)s")
                                    Text("~\(wordsForLength(secs)) words")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(selectedLength == secs ? Color.indigo : Color.gray.opacity(0.13))
                                .foregroundColor(selectedLength == secs ? .white : .primary)
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    // -- Tone selector --
                    HStack {
                        ForEach(tones, id: \.self) { tone in
                            Button {
                                selectedTone = tone
                            } label: {
                                Text(tone)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(selectedTone == tone ? Color.green.opacity(0.8) : Color.gray.opacity(0.11))
                                    .foregroundColor(selectedTone == tone ? .white : .primary)
                                    .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.bottom, 2)

                    // --- Generate button ---
                    Button {
                        Task { await runFlow() }
                    } label: {
                        HStack(spacing: 10) {
                            if isLoading {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "bolt.fill")
                                    .font(.title2)
                                Text("Generate & Speak")
                                    .font(.system(size: 20, weight: .bold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(LinearGradient(
                            colors: [Color.blue, Color.indigo],
                            startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(18)
                        .shadow(color: .blue.opacity(0.18), radius: 8, y: 4)
                        .scaleEffect(isLoading ? 0.97 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isLoading)
                    }
                    .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                    .padding(.horizontal, 12)

                    // -- Playback/progress UI --
                    if playbackModel.isReady {
                        VStack(spacing: 16) {
                            HStack {
                                Text(timeString(playbackModel.currentTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                Slider(value: Binding(
                                    get: {
                                        playbackModel.duration > 0 ? playbackModel.currentTime / playbackModel.duration : 0
                                    },
                                    set: { newValue in
                                        playbackModel.seek(to: newValue)
                                    }
                                ), in: 0...1)
                                Text(timeString(playbackModel.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)

                            HStack(spacing: 36) {
                                Button {
                                    playbackModel.play()
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundColor(playbackModel.isPlaying ? .gray : .blue)
                                        .shadow(color: .blue.opacity(0.1), radius: 4, y: 2)
                                }
                                .disabled(playbackModel.isPlaying)

                                Button {
                                    playbackModel.pause()
                                } label: {
                                    Image(systemName: "pause.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundColor(playbackModel.isPlaying ? .blue : .gray)
                                        .shadow(color: .blue.opacity(0.1), radius: 4, y: 2)
                                }
                                .disabled(!playbackModel.isPlaying)

                                if !isLoading {
                                    Button {
                                        saveCurrentBriefing()
                                    } label: {
                                        Image(systemName: "tray.and.arrow.down.fill")
                                            .font(.system(size: 32))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    if !generatedScript.isEmpty {
                        ScrollView {
                            Text(generatedScript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(maxHeight: 150)
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(12)
                        .padding(.top, 8)
                    }
                }
                .padding(34)
                .background(
                    Color.white.opacity(0.92)
                )
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: .blue.opacity(0.22), radius: 30, x: 0, y: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(Color.blue.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 18)
                Spacer()

                // SAVED BRIEFINGS LIST
                if !briefingsModel.briefings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved Briefings")
                            .font(.headline)
                            .padding(.leading, 18)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(briefingsModel.briefings) { briefing in
                                    SavedBriefingRow(
                                        briefing: briefing,
                                        playbackModel: playbackModel,
                                        onDelete: {
                                            briefingsModel.delete(briefing)
                                        }
                                    )
                                    .background(Color.white.opacity(0.85))
                                    .cornerRadius(16)
                                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                            }
                        }.frame(maxHeight: 210)
                    }
                }
            }
        }
        .onDisappear {
            playbackModel.stop()
        }
    }

    func saveCurrentBriefing() {
        guard let data = playbackModel.lastLoadedData, !topic.isEmpty else { return }
        do {
            try briefingsModel.add(topic: topic, data: data)
        } catch {
            print("Error saving briefing: \(error)")
        }
    }

    func timeString(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }

    /// Calculate roughly how many words fit in the given number of seconds
    func wordsForLength(_ seconds: Int) -> Int {
        Int((Double(seconds) / 60.0) * Double(wordsPerMinute))
    }

    func runFlow() async {
        isLoading = true
        playbackModel.stop()
        generatedScript = ""
        defer { isLoading = false }
        do {
            let briefing = try await fetchOpenAIBriefing(topic: topic, length: selectedLength, tone: selectedTone)
            generatedScript = briefing
            let audio = try await fetchGoogleTTS(from: briefing)
            try playbackModel.setAudio(audio)
            playbackModel.play()
        } catch {
            print("❌ Error in runFlow:", error)
        }
    }

    func fetchOpenAIBriefing(topic: String, length: Int, tone: String) async throws -> String {
        let wordCount = wordsForLength(length)
        let reqBody: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                [
                    "role": "system",
                    "content": """
                    You are a voice briefing assistant. Your job is to generate short audio scripts that are spoken aloud directly, without any music, intro, or filler. Do not include any greetings, sign-offs, or transitional sounds. Speak naturally and get straight to the point, like an expert delivering useful insights in a podcast clip.
                    """
                ],
                [
                    "role": "user",
                    "content": """
                    Write a ready-to-speak script on the topic: \(topic).
                    Use a \(tone.lowercased()) tone.
                    The script should be around \(wordCount) words (about \(length) seconds).
                    Begin immediately with useful spoken content.
                    Use short, conversational sentences and pause naturally between ideas.
                    Do not include music, intro lines like 'Welcome', or sign-offs.
                    """
                ]
            ]
        ]

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: reqBody)

        let (data, _) = try await URLSession.shared.data(for: req)
        let dec = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return dec.choices.first?.message.content ?? ""
    }


    struct OpenAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    // MARK: - Gemini TTS with Timeout

    private let ttsSession: URLSession = {
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForRequest = 120
      config.timeoutIntervalForResource = 180
      return URLSession(configuration: config)
    }()


    // MARK: - Gemini / Google TTS

    /// Fetches TTS audio from Gemini, converts raw PCM → WAV, and returns ready-to-play data.
    /// Throws if the network call, JSON parsing, or audio decoding fails.
    func fetchGoogleTTS(from text: String) async throws -> Data {
        // 1. Get your API key from environment
        guard let apiKey = ProcessInfo.processInfo.environment["GOOGLE_TTS_KEY"],
              !apiKey.isEmpty else {
            throw NSError(domain: "GoogleTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "GOOGLE_TTS_KEY not set"])
        }

        let url = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize?key=\(apiKey)")!

        // 2. Construct valid request body for MP3
        let body: [String: Any] = [
            "input": [
                "text": text
            ],
            "voice": [
                "languageCode": "en-US",
                "name": "en-US-Wavenet-D"
            ],
            "audioConfig": [
                "audioEncoding": "MP3"
            ]
        ]

        // 3. Set up POST request
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 4. Use custom timeout session
        let (data, resp) = try await ttsSession.data(for: req)

        guard let httpResponse = resp as? HTTPURLResponse else {
            throw NSError(domain: "GoogleTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GoogleTTS",
                          code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }


        // 5. Parse response and decode base64 audio content
        struct TTSResponse: Decodable {
            let audioContent: String
        }

        let decoded = try JSONDecoder().decode(TTSResponse.self, from: data)

        guard let audioData = Data(base64Encoded: decoded.audioContent) else {
            throw NSError(domain: "GoogleTTS", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Base64 decoding failed"])
        }

        print("✅ Google TTS MP3 audio received: \(audioData.count) bytes")
        return audioData
    }






}
import Foundation   // nothing else needed

/// Wrap raw 16-bit 24 kHz mono PCM in a WAV container.
func pcmToWav(_ pcm: Data,
              sampleRate: Int = 24_000,
              channels: Int = 1,
              bitsPerSample: Int = 16) -> Data {

    let byteRate   = sampleRate * channels * bitsPerSample / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize   = UInt32(pcm.count)
    let riffSize   = UInt32(pcm.count + 36)

    var header = Data()
    header.append("RIFF".data(using: .ascii)!)
    header.append(riffSize.littleEndian.data)
    header.append("WAVE".data(using: .ascii)!)

    header.append("fmt ".data(using: .ascii)!)
    header.append(UInt32(16).littleEndian.data)          // fmt chunk size
    header.append(UInt16(1).littleEndian.data)           // PCM
    header.append(UInt16(channels).littleEndian.data)
    header.append(UInt32(sampleRate).littleEndian.data)
    header.append(UInt32(byteRate).littleEndian.data)
    header.append(UInt16(blockAlign).littleEndian.data)
    header.append(UInt16(bitsPerSample).littleEndian.data)

    header.append("data".data(using: .ascii)!)
    header.append(dataSize.littleEndian.data)

    return header + pcm
}

private extension FixedWidthInteger {
    var data: Data { withUnsafeBytes(of: self) { Data($0) } }
}

// MARK: - SavedBriefingRow

struct SavedBriefingRow: View {
    let briefing: Briefing
    @ObservedObject var playbackModel: AudioPlaybackModel
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(briefing.topic)
                    .font(.headline)
                    .lineLimit(1)
                Text(DateFormatter.localizedString(from: briefing.date, dateStyle: .short, timeStyle: .short))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                playBriefing()
            } label: {
                Image(systemName: "play.circle")
                    .font(.title)
                    .foregroundColor(.blue)
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    func playBriefing() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(briefing.filename)
        do {
            try playbackModel.setAudio(url: url)
            playbackModel.play()
        } catch {
            print("Playback error: \(error)")
        }
    }
}



