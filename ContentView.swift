import SwiftUI
import AVFoundation
import Foundation
import Combine

// MARK: - Codable structs for Gemini TTS response

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

@MainActor
class BriefingsLibraryModel: ObservableObject {
    @Published private(set) var briefings: [Briefing] = []
    private let saveURL: URL

    private let docs: URL

    init() {
        docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        saveURL = docs.appendingPathComponent("briefings.json")
        load()
    }

    func add(topic: String, data: Data) throws {
        let id = UUID()
        let filename = "briefing-\(id).m4a"
        let fileURL = docs.appendingPathComponent(filename)
        try data.write(to: fileURL)
        let newBriefing = Briefing(id: id, topic: topic, date: Date(), filename: filename)
        briefings.insert(newBriefing, at: 0)
        save()
    }

    func delete(_ briefing: Briefing) {
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

// MARK: - AVPlayer-based Audio Playback

@MainActor
class AVPlayerModel: ObservableObject {
    @Published var isReady = false
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1

    private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private weak var observerPlayer: AVPlayer?
    private var finishObserver: Any?
    private(set) var lastLoadedURL: URL?

    func setAudio(url: URL) {
        // Clean up previous time observer safely
        removeTimeObserverIfNeeded()

        self.lastLoadedURL = url
        self.playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: playerItem)
        self.isReady = true
        self.isPlaying = false
        self.currentTime = 0
        self.duration = 1

        if let player = player {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                guard let self = self else { return }
                self.currentTime = time.seconds
                if let d = self.player?.currentItem?.duration.seconds, d > 0 {
                    self.duration = d
                }
            }
            observerPlayer = player
        }

        finishObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: self.playerItem, queue: .main) { [weak self] _ in
            self?.isPlaying = false
            self?.currentTime = self?.duration ?? 0
        }
    }

    func play() {
        guard isReady else { return }
        player?.play()
        isPlaying = true
    }

    func pause() {
        guard isReady else { return }
        player?.pause()
        isPlaying = false
    }

    func seek(to progress: Double) {
        guard isReady, let player = player else { return }
        let newTime = CMTime(seconds: duration * progress, preferredTimescale: 600)
        player.seek(to: newTime)
        self.currentTime = duration * progress
    }

    func stop() {
        player?.pause()
        isPlaying = false
        isReady = false
        currentTime = 0
    }

    private func removeTimeObserverIfNeeded() {
        if let observer = timeObserver, let player = observerPlayer {
            player.removeTimeObserver(observer)
            timeObserver = nil
            observerPlayer = nil
        }
    }

    deinit {
        removeTimeObserverIfNeeded()
        if let finishObs = finishObserver { NotificationCenter.default.removeObserver(finishObs) }
    }
}


// MARK: - ContentView

struct ContentView: View {
    @State private var topic = ""
    @State private var isLoading = false
    @State private var loadingStage = ""
    @State private var selectedLength: Int = 60
    @State private var selectedTone: String = "Professional"
    @State private var showCustomTopicInput = false
    @State private var customTopic = ""
    @State private var errorMsg = ""
    @StateObject private var playbackModel = AVPlayerModel()
    @StateObject private var briefingsModel = BriefingsLibraryModel()

    var openAIKey: String? {
        let key = ProcessInfo.processInfo.environment["OPENAI_KEY"]
        return key?.isEmpty == false ? key : nil
    }
    let trendingTopics = ["Market News", "Quick Tips", "Motivation", "Tech Trends", "Insurance 101"]
    let lengthOptions = [30, 60, 180]
    let tones = ["Professional", "Motivational", "Fun", "Calm"]

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

                    TopicPickerView(topic: $topic,
                                   showCustomInput: $showCustomTopicInput,
                                   customTopic: $customTopic,
                                   trending: trendingTopics)

                    // -- Quick length selector --
                    LengthPickerView(selected: $selectedLength, options: lengthOptions)
                        .padding(.vertical, 2)

                    // -- Tone selector --
                    TonePickerView(selected: $selectedTone, tones: tones)
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

                    if !errorMsg.isEmpty {
                        Text(errorMsg)
                            .foregroundColor(.red)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }

                    // -- Progress Indicator for async stages --
                    if isLoading {
                        if !loadingStage.isEmpty {
                            Text(loadingStage)
                                .foregroundColor(.gray)
                                .font(.callout)
                        }
                    }

                    // -- Playback/progress UI --
                    if playbackModel.isReady {
                        PlaybackControlsView(
                            playbackModel: playbackModel,
                            isLoading: isLoading,
                            saveAction: saveCurrentBriefing)
                            .padding(.top, 4)
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
        guard let url = playbackModel.lastLoadedURL, !topic.isEmpty else { return }
        do {
            let data = try Data(contentsOf: url)
            try briefingsModel.add(topic: topic, data: data)
        } catch {
            errorMsg = "Error saving briefing: \(error.localizedDescription)"
        }
    }

    func timeString(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }

    /// Generate the briefing, synthesize audio and begin playback.
    @MainActor
    func runFlow() async {
        isLoading = true
        errorMsg = ""
        loadingStage = "Generating script..."
        playbackModel.stop()
        defer { isLoading = false; loadingStage = "" }
        do {
            let briefing = try await fetchOpenAIBriefing(topic: topic, length: selectedLength, tone: selectedTone)
            loadingStage = "Synthesizing audio..."
            let ttsPCMData = try await fetchGoogleTTS(from: briefing)
            loadingStage = "Encoding audio..."
            let m4aURL = try await convertPCMToM4A(ttsPCMData)
            playbackModel.setAudio(url: m4aURL)
            playbackModel.play()
        } catch {
            errorMsg = "Error: \(error.localizedDescription)"
        }
    }

    func fetchOpenAIBriefing(topic: String, length: Int, tone: String) async throws -> String {
        let reqBody: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": "You are a briefing assistant."],
                ["role": "user", "content": """
                Generate a spoken audio script on the topic: \(topic).
                Use a \(tone.lowercased()) tone.
                Make it suitable for an audio update of about \(length) seconds.
                Use short, conversational sentences.
                """]
            ]
        ]
        guard let key = openAIKey else {
            throw NSError(domain: "OpenAI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "OPENAI_KEY not set"])
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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

    func fetchGoogleTTS(from text: String) async throws -> Data {
        guard let apiKey = ProcessInfo.processInfo.environment["GOOGLE_TTS_KEY"],
              !apiKey.isEmpty else {
            throw NSError(domain: "GoogleTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "GOOGLE_TTS_KEY not set"])
        }

        let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/" +
            "gemini-2.5-flash-preview-tts:generateContent?key=\(apiKey)")!

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": text]]
                ]
            ],
            "generationConfig": [
                "response_modalities": ["AUDIO"],
                "speech_config": [
                    "voice_config": [
                        "prebuilt_voice_config": ["voice_name": "zephyr"]
                    ]
                ],
                "temperature": 0.0
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await ttsSession.data(for: req)

        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GeminiTTS",
                          code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }

        let response = try JSONDecoder().decode(GeminiTTSResponse.self, from: data)

        guard
            let base64 = response.candidates.first?
                              .content.parts.first?
                              .inlineData?.data,
            let pcm    = Data(base64Encoded: base64)
        else {
            throw NSError(domain: "GeminiTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No valid audio data"])
        }
        return pcm
    }

    // PCM to M4A Pipeline

    func convertPCMToM4A(_ pcmData: Data) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let wavURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        let m4aURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")

        try pcmToWav(pcmData).write(to: wavURL)
        // Use AVAssetExportSession for conversion:
        let asset = AVURLAsset(url: wavURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Audio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export session failed."])
        }
        export.outputURL = m4aURL
        export.outputFileType = .m4a

        return try await withCheckedThrowingContinuation { continuation in
            export.exportAsynchronously {
                defer { try? FileManager.default.removeItem(at: wavURL) }
                if export.status == .completed {
                    continuation.resume(returning: m4aURL)
                } else {
                    let error = export.error ?? NSError(domain: "Audio", code: -2, userInfo: nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - PCM to WAV Helper

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
    @ObservedObject var playbackModel: AVPlayerModel
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
        playbackModel.setAudio(url: url)
        playbackModel.play()
    }
}

// MARK: - Subviews

struct TopicPickerView: View {
    @Binding var topic: String
    @Binding var showCustomInput: Bool
    @Binding var customTopic: String
    let trending: [String]

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(trending, id: \.self) { chip in
                        Button { topic = chip } label: {
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
                        showCustomInput = true
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
            .sheet(isPresented: $showCustomInput) {
                VStack(spacing: 18) {
                    Text("Enter your topic")
                        .font(.title2)
                    TextField("Custom topic", text: $customTopic)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    Button("Use Topic") {
                        topic = customTopic
                        showCustomInput = false
                    }
                    .disabled(customTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }
}

struct LengthPickerView: View {
    @Binding var selected: Int
    let options: [Int]

    var body: some View {
        HStack {
            ForEach(options, id: \.self) { secs in
                Button { selected = secs } label: {
                    Text(secs == 180 ? "3 min" : "\(secs)s")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(selected == secs ? Color.indigo : Color.gray.opacity(0.13))
                        .foregroundColor(selected == secs ? .white : .primary)
                        .cornerRadius(12)
                }
            }
        }
    }
}

struct TonePickerView: View {
    @Binding var selected: String
    let tones: [String]

    var body: some View {
        HStack {
            ForEach(tones, id: \.self) { tone in
                Button { selected = tone } label: {
                    Text(tone)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(selected == tone ? Color.green.opacity(0.8) : Color.gray.opacity(0.11))
                        .foregroundColor(selected == tone ? .white : .primary)
                        .cornerRadius(12)
                }
            }
        }
    }
}

struct PlaybackControlsView: View {
    @ObservedObject var playbackModel: AVPlayerModel
    var isLoading: Bool
    var saveAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(timeString(playbackModel.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Slider(value: Binding(
                    get: {
                        playbackModel.duration > 0 ? playbackModel.currentTime / playbackModel.duration : 0
                    },
                    set: { playbackModel.seek(to: $0) }
                ), in: 0...1)
                Text(timeString(playbackModel.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 36) {
                Button { playbackModel.play() } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(playbackModel.isPlaying ? .gray : .blue)
                        .shadow(color: .blue.opacity(0.1), radius: 4, y: 2)
                }
                .disabled(playbackModel.isPlaying)

                Button { playbackModel.pause() } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(playbackModel.isPlaying ? .blue : .gray)
                        .shadow(color: .blue.opacity(0.1), radius: 4, y: 2)
                }
                .disabled(!playbackModel.isPlaying)

                if !isLoading {
                    Button(action: saveAction) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                    }
                }
            }
        }
    }

    private func timeString(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
}
