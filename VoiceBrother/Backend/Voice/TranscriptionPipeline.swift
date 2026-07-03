import Foundation

/// Turns captured audio (or a cloud-streaming result) into injected text:
/// ASR → filler/ITN/replacement processing → optional LLM polish → keystroke
/// injection → history. Recording-lifecycle state (state / session / timing /
/// asrEngine / in-flight transcribe task) lives on `VoiceService`; this pipeline
/// reads and writes it through a weak back-reference so behaviour is unchanged.
@MainActor
final class TranscriptionPipeline {

    private weak var voice: VoiceService?
    private let configManager: ConfigManager
    private let historyStore: HistoryStore
    private let chunkStore: VoiceAudioChunkStore
    private let feedbackPlayer: FeedbackSoundPlayer

    /// Hard ceiling on a single transcribe call before we surface "timeout"
    /// to the user. Normal latency is well under 1 s even on the 1.7B model;
    /// 15 s gives a generous margin for legitimate post-idle slow paths.
    private static let transcribeTimeoutSeconds: UInt64 = 15

    init(voice: VoiceService,
         configManager: ConfigManager,
         historyStore: HistoryStore,
         chunkStore: VoiceAudioChunkStore,
         feedbackPlayer: FeedbackSoundPlayer) {
        self.voice = voice
        self.configManager = configManager
        self.historyStore = historyStore
        self.chunkStore = chunkStore
        self.feedbackPlayer = feedbackPlayer
    }

    // MARK: - Transcription

    /// Process cloud streaming result and inject text.
    func processAndInject(text: String, chunks: [Data]) async {
        // No hide() here — handleKeyRelease already hid the overlay the
        // instant the user let go. Error paths re-show via showBriefMessage.

        let session = voice?.currentSessionID
        ASRLogger.shared.event(.finalReceived, sessionID: session,
                               props: ["engine": "volcano", "len": text.count])

        guard !text.isEmpty else {
            ASRLogger.shared.event(.asrFinished, sessionID: session,
                                   props: ["empty": true])
            voice?.state = .ready
            return
        }

        // Learned correction rules (自学习纠错) are merged AFTER the user's
        // manual rules. If the learning subsystem is empty/disabled this is
        // just the manual list — behaviour is unchanged.
        CorrectionLearningEngine.shared.noteTranscription(rawText: text)
        ASRLogger.shared.event(.processStarted, sessionID: session)
        var processedText = TextProcessor.process(
            text: text,
            removeFillers: configManager.removeFillers,
            rules: configManager.replacements + CorrectionLearningEngine.shared.activeRules
        )
        ASRLogger.shared.event(.processCompleted, sessionID: session,
                               props: ["len": processedText.count])

        guard !processedText.isEmpty else {
            voice?.state = .ready
            return
        }

        voice?.state = .ready

        // LLM polish
        let notes = configManager.localLLMNotes
        let polisher: (any TextPolisher)?

        if configManager.cloudLLMEnabled,
           let provider = LLMProvider(rawValue: configManager.llmProvider),
           provider != .none {
            let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
            // 抄豆包：把场景 + 最近历史 + 热词 + 自学习词 + 英文术语都喂给 LLM polish。
            let polishContext = await buildPolishContext(notes: notes)
            polisher = LLMClient(provider: provider, credentials: creds, polishContext: polishContext)
        } else {
            polisher = nil
        }

        if let polisher, polisher.shouldPolish(processedText) {
            let polishStart = Date()
            ASRLogger.shared.event(.llmPolishStarted, sessionID: session,
                                   props: ["provider": configManager.llmProvider])
            do {
                let polished = try await polisher.polish(processedText)
                let changed = !polished.isEmpty && polished != processedText
                if changed { processedText = polished }
                ASRLogger.shared.event(.llmPolishCompleted, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "changed": changed])
            } catch {
                // Polish failure shouldn't block injection — the raw (but
                // already filler-removed + replacements-applied) text is still
                // useful. But we surface the error so debugging is possible
                // instead of silently dropping the call.
                debugWarn("Polish failed: \(error.localizedDescription)")
                print("[VoiceService] LLM polish failed: \(error)")
                ASRLogger.shared.event(.llmPolishFailed, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "error": "\(error.localizedDescription)"])
            }
        }

        // 句尾标点处理：关闭时去掉尾部标点换成空格
        if !configManager.trailingPunctuation {
            processedText = TextProcessor.stripTrailingPunctuation(processedText)
        }

        await injectFinalText(processedText, session: session, engineName: "volcano")
        feedbackPlayer.playEndSound()

        let duration = voice?.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        // Keep raw ASR alongside processed output — the self-learning engine
        // diffs (raw → user edit) so it learns ASR mistakes, not LLM polish.
        let record = TranscriptionRecord(text: processedText, duration: duration, rawText: text, model: voice?.loadedModelLabel ?? "")
        Task { await historyStore.insert(record) }
        // Voice input just completed — History tab opens on this segment next.
        configManager.lastHistoryKind = "voice"
    }

    /// Final-text injection with mode-aware dispatch. `typewriterMode == true`
    /// rolls the text out one character at a time via CGEvent unicode keystrokes
    /// (clipboard untouched); `false` keeps the existing single Cmd+V paste.
    /// Centralised here so both the cloud-streaming path and the local-batch
    /// path share identical sequencing — same ASRLogger events, same dispatch.
    private func injectFinalText(_ processed: String,
                                 session: UUID?,
                                 engineName: String) async {
        ASRLogger.shared.event(.injectStarted, sessionID: session,
                               props: ["len": processed.count,
                                       "mode": configManager.typewriterMode ? "typewriter" : "paste",
                                       "engine": engineName])
        if configManager.typewriterMode {
            // 浮窗只显示波形,不预览识别文字。它从松手一直留到这里,
            // 键盘逐字键入完成后隐藏。
            await Task.detached(priority: .userInitiated) {
                TextInjector.typeTextProgressive(processed)
            }.value
            voice?.overlay.hide()
            ASRLogger.shared.event(.panelHidden, sessionID: session,
                                   props: ["reason": "typewriter_done"])
        } else {
            TextInjector.typeText(processed, preserveClipboard: configManager.preserveClipboard)
        }
        ASRLogger.shared.event(.injectCompleted, sessionID: session)
    }

    func transcribeAndInject(chunks: [Data]) async {
        // No defer { hide() } — the overlay was already hidden the moment
        // the user released the key. Only the error paths below need to
        // re-surface it via showBriefMessage.

        debugLog("transcribeAndInject: chunks=\(chunks.count), totalBytes=\(chunks.reduce(0) { $0 + $1.count })")

        guard !chunks.isEmpty else {
            debugLog("transcribeAndInject SKIPPED: chunks empty — mic delivered no audio")
            voice?.overlay.showBriefMessage("麦克风无输入，可能被其他 app 占用")
            voice?.state = .ready
            return
        }

        guard let engine = voice?.asrEngine else {
            debugLog("transcribeAndInject SKIPPED: asrEngine is nil")
            voice?.state = .error("模型未加载")
            return
        }

        var allSamples = chunkStore.mergeAudioSamples(from: chunks)

        guard !allSamples.isEmpty else {
            debugLog("transcribeAndInject SKIPPED: allSamples empty after merge (skipSamples=\(chunkStore.skipSamples))")
            voice?.overlay.showBriefMessage("录音过短，没捕获到声音")
            voice?.state = .ready
            return
        }

        // Hard floor: below 0.15s we can't realistically transcribe anything —
        // even single Chinese syllables take ~0.2s to articulate. This catches
        // accidental key-touches without rejecting genuine quick utterances.
        // (Was 8000 / 0.5s, which silently rejected words like "好" or "对"
        // when said quickly.)
        guard allSamples.count >= 2400 else {
            debugLog("transcribeAndInject SKIPPED: too short, samples=\(allSamples.count) (need ≥2400)")
            voice?.overlay.showBriefMessage("录音过短（不到 0.15 秒）")
            voice?.state = .ready
            return
        }

        // Skip transcription if audio is mostly silence/background noise.
        // Distinguish between:
        //   - RMS exactly 0.0 → hardware delivered all-zero buffers (mic likely
        //     held exclusively by another app feeding silence through the shared
        //     CoreAudio device). Point the user at the real cause.
        //   - RMS > 0 but below threshold → genuine quiet / too-far-from-mic.
        let rms = sqrt(allSamples.reduce(0) { $0 + $1 * $1 } / Float(allSamples.count))
        // Reject only genuinely-dead input (RMS ~0 = the mic delivered all-zero
        // buffers, e.g. held by another app feeding silence). Quiet speech — a
        // built-in mic is naturally low-level — is NOT rejected here; it gets
        // normalised up just below.
        guard rms > 0.0002 else {
            debugLog("transcribeAndInject SKIPPED: silent audio, RMS=\(rms), samples=\(allSamples.count)")
            voice?.overlay.showBriefMessage("麦克风无输入，可能被其他 app 占用")
            voice?.state = .ready
            return
        }

        // Software AGC — replaces the VPIO/AGC path, which cost ~hundreds of ms
        // of cold-start latency on every key press. The built-in mic delivers a
        // very low-level signal (~-56 dBFS); scale the whole utterance up by peak
        // so the ASR model gets a healthy level. The gain is capped so we never
        // clip, and an already-hot signal (AirPods) is left essentially untouched
        // (gain ≈ 1, and we never attenuate).
        let peak = allSamples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 {
            let gain = min(Float(0.6) / peak, Float(40))
            if gain > 1.05 {
                for i in allSamples.indices { allSamples[i] *= gain }
                debugLog("Software AGC: peak=\(String(format: "%.4f", peak)) → gain=\(String(format: "%.1f", gain))x")
            }
        }
        let gainedRMS = sqrt(allSamples.reduce(0) { $0 + $1 * $1 } / Float(allSamples.count))
        debugLog("transcribeAndInject: samples=\(allSamples.count), RMS=\(String(format: "%.4f", rms))→\(String(format: "%.4f", gainedRMS)), duration=\(String(format: "%.1f", Double(allSamples.count) / 16000.0))s")

        // Build hotwords context string
        let hotwords = configManager.hotwords
        let capturedContext = Self.buildHotwordContext(hotwords, appName: voice?.recordingAppContext)

        // Apple's recognizer is locale-bound and cannot auto-detect, so pass the
        // user's chosen voice-input language. Qwen3-ASR is multilingual — keep
        // nil so it auto-detects (pinning a hint forced Japanese/English speech
        // into Mandarin homophone mode).
        let asrLanguage: String? = (engine is AppleASREngine || engine is OpenAIWhisperASREngine)
            ? configManager.voiceInputLanguage.asrLanguageHint
            : nil

        let session = voice?.currentSessionID
        let engineName = String(describing: type(of: engine))
        ASRLogger.shared.event(.asrStarted, sessionID: session,
                               props: ["engine": engineName,
                                       "samples": allSamples.count,
                                       "lang": asrLanguage ?? "auto"])
        let asrStart = Date()
        // Run transcription on background thread to keep UI responsive.
        let transcribeTask = Task.detached { [engine] in
            let result = engine.transcribe(
                audio: allSamples,
                sampleRate: 16000,
                language: asrLanguage,
                context: capturedContext
            )
            // Drop MLX intermediate buffers from the recycle pool. Variable
            // audio lengths produce variable-shape intermediates that the pool
            // cannot reuse, so without this they accumulate indefinitely.
            MLXMemoryGovernor.reclaim()
            return result
        }
        voice?.currentTranscribeTask = transcribeTask

        // Race the transcribe against a hard timeout. The MLX call itself is
        // synchronous and not cancellable, so when the timeout wins we just
        // abandon the orphan task — it will finish on its own and its result
        // is discarded.
        let timeoutNs = Self.transcribeTimeoutSeconds * 1_000_000_000
        let textOpt: String? = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { await transcribeTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let text = textOpt else {
            voice?.currentTranscribeTask = nil
            ASRLogger.shared.event(.asrFailed, sessionID: session,
                                   props: ["engine": engineName,
                                           "dur_ms": ASRLogger.durMs(since: asrStart),
                                           "reason": "timeout",
                                           "timeout_s": Self.transcribeTimeoutSeconds])
            debugError("transcribeAndInject TIMEOUT after \(Self.transcribeTimeoutSeconds)s — MLX likely wedged (long idle?). Reload model to recover.")
            voice?.overlay.showBriefMessage("识别超时，请重新切换模型试试")
            voice?.state = .ready
            return
        }
        voice?.currentTranscribeTask = nil

        ASRLogger.shared.event(.finalReceived, sessionID: session,
                               props: ["engine": engineName,
                                       "dur_ms": ASRLogger.durMs(since: asrStart),
                                       "len": text.count,
                                       "empty": text.isEmpty])
        debugLog("ASR raw result: \"\(text)\" (empty=\(text.isEmpty)) — \(MLXMemoryGovernor.snapshotDescription())")

        // Process text (Layer 1 filler removal + Layer 2 ITN + replacements).
        // Learned correction rules (自学习纠错) are merged after the user's
        // manual rules; an empty/failed learning store leaves behaviour unchanged.
        CorrectionLearningEngine.shared.noteTranscription(rawText: text)
        ASRLogger.shared.event(.processStarted, sessionID: session)
        var processedText = TextProcessor.process(
            text: text,
            removeFillers: configManager.removeFillers,
            rules: configManager.replacements + CorrectionLearningEngine.shared.activeRules
        )
        ASRLogger.shared.event(.processCompleted, sessionID: session,
                               props: ["len": processedText.count])
        debugLog("After TextProcessor: \"\(processedText)\"")

        // Defense-in-depth: the model sometimes appends the entire hotword
        // priming list to the tail of real speech (prompt leakage on trailing
        // silence). Strip a long trailing run of consecutive hotword tokens —
        // real dictation never ends with 10+ bare proper nouns in a row.
        if let cleaned = Self.stripTrailingHotwordEcho(processedText, hotwords: hotwords),
           cleaned != processedText {
            debugLog("Stripped trailing hotword echo: \"\(processedText)\" → \"\(cleaned)\"")
            processedText = cleaned
        }

        let isHotwordHallucination = Self.isLikelyHotwordHallucination(processedText, hotwords: hotwords)
        let isSilenceHallucination = Self.isLikelySilenceHallucination(processedText)

        guard !processedText.isEmpty, !isHotwordHallucination, !isSilenceHallucination else {
            debugLog("transcribeAndInject SKIPPED: processedText empty=\(processedText.isEmpty), isHotwordHallucination=\(isHotwordHallucination), isSilenceHallucination=\(isSilenceHallucination)")
            let msg = isSilenceHallucination
                ? "没识别到有效语音，请检查麦克风"
                : (processedText.isEmpty ? "没识别到内容，请重试" : "识别异常，请重试")
            voice?.overlay.showBriefMessage(msg)
            voice?.state = .ready
            return
        }

        // Restore state so user can start a new recording immediately.
        voice?.state = .ready

        // Layer 3: LLM polish
        let notes = configManager.localLLMNotes
        let polisher: (any TextPolisher)?

        if configManager.cloudLLMEnabled,
           let provider = LLMProvider(rawValue: configManager.llmProvider),
           provider != .none {
            let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
            NSLog("[VoiceService] LLM polish (cloud/%@): input=\"%@\", notes=\"%@\"", provider.rawValue, processedText, notes)
            // 把当前场景 + 最近 3 条历史 + 热词 + 自学习词 + 英文术语词典一并喂给 LLM。
            let polishContext = await buildPolishContext(notes: notes)
            polisher = LLMClient(provider: provider, credentials: creds, polishContext: polishContext)
        } else {
            polisher = nil
            NSLog("[VoiceService] LLM polish: skipped (not configured or model not ready)")
        }

        if let polisher, polisher.shouldPolish(processedText) {
            let polishStart = Date()
            ASRLogger.shared.event(.llmPolishStarted, sessionID: session,
                                   props: ["provider": configManager.llmProvider])
            do {
                let polished = try await polisher.polish(processedText)
                let changed = !polished.isEmpty && polished != processedText
                if changed {
                    NSLog("[VoiceService] LLM polish: output=\"%@\"", polished)
                    processedText = polished
                } else {
                    NSLog("[VoiceService] LLM polish: no change")
                }
                ASRLogger.shared.event(.llmPolishCompleted, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "changed": changed])
            } catch {
                NSLog("[VoiceService] LLM polish failed: %@", String(describing: error))
                ASRLogger.shared.event(.llmPolishFailed, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "error": "\(error.localizedDescription)"])
            }
        }

        // 句尾标点处理：关闭时去掉尾部标点换成空格
        if !configManager.trailingPunctuation {
            processedText = TextProcessor.stripTrailingPunctuation(processedText)
        }

        // Inject text. In typewriter mode the overlay (waveform only) was kept
        // open since key-release; injectFinalText hides it once typing finishes.
        await injectFinalText(processedText, session: session, engineName: engineName)
        feedbackPlayer.playEndSound()

        // Record to history (keep raw ASR alongside processed output so the
        // self-learning engine has a real "before" side for diffing).
        let duration = voice?.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration, rawText: text, model: voice?.loadedModelLabel ?? "")
        Task { await historyStore.insert(record) }
        // Voice input just completed — History tab opens on this segment next.
        configManager.lastHistoryKind = "voice"
    }

    // MARK: - Hotword Context

    /// Wrap hotwords in a Chinese descriptive phrase so the model treats them as
    /// reference vocabulary rather than priming itself to echo them as the
    /// transcription. Passing a raw space-joined word list (the previous behavior)
    /// causes the model to regurgitate hotwords verbatim on short/silent audio.
    /// Hard cap on how many hotwords we inject as ASR priming context. Long
    /// lists make Qwen3-ASR echo the whole list verbatim on trailing silence
    /// (prompt leakage). The full list still reaches LLM polish via
    /// buildPolishContext — only the echo-prone ASR context is capped. Manual
    /// words sit first in storage, so prefix() keeps the user-curated terms.
    static let asrContextHotwordCap = 30

    static func buildHotwordContext(_ hotwords: [String], appName: String? = nil) -> String? {
        let cleaned = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(asrContextHotwordCap)

        var parts: [String] = []
        if let appName, !appName.isEmpty {
            parts.append("用户正在使用 \(appName)")
        }
        if !cleaned.isEmpty {
            parts.append("可能出现以下专有名词：" + cleaned.joined(separator: "、"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "。") + "。"
    }

    /// 给云端 LLM polish 打包当前上下文：场景、最近历史、热词、自学习词、英文术语词典。
    /// 历史只取最近 3 条 polished 文本——HistoryStore.fetchAll 拿到的就是 polished 版本，
    /// prompt 里标注「可能含错」让 LLM 不被过往错字强化。空历史不会留空段。
    private func buildPolishContext(notes: String) async -> PolishContext {
        let recent = await historyStore.fetchAll(limit: 3)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // 自学习词取 active rules 的目标词（`to`）——用户实际想要的拼写。
        let learned = CorrectionLearningEngine.shared.activeRules.map { $0.to }
        return PolishContext(
            userNotes: notes,
            appContext: voice?.recordingAppContext,
            recentHistory: recent,
            hotwords: configManager.hotwords,
            learnedTerms: learned,
            techLexicon: TechLexicon.defaults
        )
    }

    /// Phrases that only appear inside our hotword priming prompt. If the ASR
    /// output contains any of these, the model is echoing the context verbatim
    /// — the user definitely did not speak this. Catches the failure mode
    /// where the user holds the trigger key but stays silent: the model
    /// regurgitates the whole "音频中可能出现以下专有名词：…" prompt.
    private static let hotwordPromptMarkers: [String] = [
        "音频中可能出现以下专有名词",
        "音频中可能出现",
        "以下专有名词",
        "可能出现以下专有名词",
        "用户正在使用"
    ]

    /// Detect when the ASR output is dominated by hotword content — a sign the
    /// model hallucinated from in-context priming. Catches:
    ///   1. Output containing the literal priming prompt prefix.
    ///   2. Output that is *only* hotwords + punctuation.
    ///   3. Output that is almost entirely hotwords with a few stray characters.
    static func isLikelyHotwordHallucination(_ text: String, hotwords: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hotwords.isEmpty else { return false }

        // (1) Definitive: the output echoes our prompt prefix. No real speaker
        // says "音频中可能出现以下专有名词" out loud — that's our scaffolding text.
        for marker in hotwordPromptMarkers where trimmed.contains(marker) {
            return true
        }

        var hotwordTokens = Set<String>()
        for word in hotwords {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { continue }
            hotwordTokens.insert(w)
            for token in w.split(separator: " ").map(String.init) where !token.isEmpty {
                hotwordTokens.insert(token)
            }
        }

        var remaining = trimmed
        for token in hotwordTokens.sorted(by: { $0.count > $1.count }) {
            remaining = remaining.replacingOccurrences(of: token, with: "")
        }
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        // Strict: nothing but hotwords + punctuation.
        if remaining.isEmpty { return true }

        // Loose: hotwords account for ≥80% of the output AND ≤18 stray bytes left.
        // Use UTF-8 byte count so the threshold treats Chinese (~3 bytes/char) and
        // English (~1 byte/char) on equal footing — counting characters would unfairly
        // flag short Chinese phrases as hallucinations while letting long English
        // ones through.
        let trimmedBytes = trimmed.utf8.count
        let remainingBytes = remaining.utf8.count
        guard trimmedBytes > 0 else { return false }
        let strippedRatio = 1.0 - Double(remainingBytes) / Double(trimmedBytes)
        if strippedRatio >= 0.8 && remainingBytes <= 18 { return true }

        return false
    }

    // MARK: - Trailing hotword echo

    /// Separators the model uses when it dumps the hotword list (enumeration
    /// comma, regular commas, semicolons, slashes, spaces).
    private static let echoSeparators: Set<Character> = ["、", "，", ",", ";", "；", "/", " ", "\t"]
    /// Terminal punctuation/whitespace to peel off the tail before scanning.
    private static let echoTerminators: Set<Character> = ["。", ".", "!", "?", "！", "？", " ", "\t", "\n"]
    /// Minimum consecutive trailing hotword tokens that we treat as a leaked
    /// priming list rather than spoken content. Natural dictation never ends
    /// with this many bare proper nouns strung together by separators; the
    /// leaked list is far longer (up to asrContextHotwordCap).
    private static let trailingEchoThreshold = 10

    /// Strip a long trailing run of consecutive hotword tokens from `text`.
    /// Returns the cleaned string, or nil when no qualifying run exists (the
    /// caller leaves the text untouched). Walks from the tail, matching the
    /// longest hotword each step and requiring a separator boundary before each
    /// match — so a hotword that is merely the suffix of a real word (e.g.
    /// 「记忆系统」at the end of 「的记忆系统」) is never clipped.
    static func stripTrailingHotwordEcho(_ text: String, hotwords: [String]) -> String? {
        guard !hotwords.isEmpty else { return nil }

        var tokens = Set<String>()
        for word in hotwords {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !w.isEmpty else { continue }
            tokens.insert(w)
            for part in w.split(separator: " ").map(String.init) where !part.isEmpty {
                tokens.insert(part)
            }
        }
        guard !tokens.isEmpty else { return nil }
        let ordered = tokens.sorted { $0.count > $1.count }   // longest-first match

        var s = text
        while let last = s.last, echoTerminators.contains(last) { s.removeLast() }

        var stripped = 0
        outer: while true {
            while let last = s.last, echoSeparators.contains(last) { s.removeLast() }
            guard !s.isEmpty else { break }
            let lower = s.lowercased()   // 1:1 length for ASCII/CJK, so offsets align with `s`
            for token in ordered where lower.hasSuffix(token) {
                let cut = s.index(s.endIndex, offsetBy: -token.count)
                // Require a separator boundary (or string start) before the
                // match so we only clip enumerated list items, never a hotword
                // embedded in a real word.
                if cut == s.startIndex || echoSeparators.contains(s[s.index(before: cut)]) {
                    s = String(s[..<cut])
                    stripped += 1
                    continue outer
                }
            }
            break
        }

        guard stripped >= trailingEchoThreshold else { return nil }
        while let last = s.last, echoSeparators.contains(last) || echoTerminators.contains(last) {
            s.removeLast()
        }
        return s
    }

    /// Phrases Qwen3-ASR tends to output when the audio is too quiet, too short,
    /// or the mic captured background noise only. These are verbatim model
    /// fallbacks, never things the user actually said — treat them as failures
    /// and tell the user the mic didn't pick up their voice.
    private static let silenceHallucinationPhrases: Set<String> = [
        "没有任何声音", "没有任何声音。",
        "没有声音", "没有声音。",
        "没声音", "没声音。",
        "无声", "无声。",
        "听不清", "听不清。",
        "听不见", "听不见。",
        "没有说话", "没有说话。",
        "没人说话", "没人说话。",
        "没有人说话", "没有人说话。",
        "（无声）", "(无声)",
        "（静音）", "(静音)"
    ]

    static func isLikelySilenceHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return silenceHallucinationPhrases.contains(trimmed)
    }

    // MARK: - Debug

    // Keep the `[VoiceService]` log prefix so existing log greps/monitors are unaffected.
    private func debugLog(_ message: String) {
        DebugLog.write("[VoiceService] \(message)")
    }

    private func debugWarn(_ message: String) {
        DebugLog.warn("[VoiceService] \(message)")
    }

    private func debugError(_ message: String) {
        DebugLog.error("[VoiceService] \(message)")
    }
}
