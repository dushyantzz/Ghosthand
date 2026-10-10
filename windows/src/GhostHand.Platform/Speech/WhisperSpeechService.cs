using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using GhostHand.Core.Interfaces;
using Microsoft.Extensions.Logging;
using NAudio.CoreAudioApi;
using NAudio.Utils;
using NAudio.Wave;
using Whisper.net;
using Whisper.net.Ggml;

namespace GhostHand.Platform.Speech;

/// <summary>
/// Local Whisper.net speech-to-text service using NAudio microphone capture.
/// Streams live partial transcripts while the user is still speaking (re-transcribing the audio so far
/// every <see cref="PartialIntervalMs"/>), and stops on end-of-speech silence, <see cref="RequestStop"/>,
/// or cancellation. Because the last partial usually already covers the whole utterance, the final
/// transcript is ready the moment the user stops talking.
/// No Windows privacy policy required - runs entirely offline using the local Whisper model.
/// </summary>
/// <remarks>
/// Environment overrides: GHOSTHAND_WHISPER_MODEL = tiny | base | small (default tiny; base is noticeably
/// more accurate for accents and song names), GHOSTHAND_SPEECH_LANGUAGE = en | auto | hi | ... (default en).
/// </remarks>
public class WhisperSpeechService : ISpeechInput
{
    private readonly ILogger<WhisperSpeechService> _logger;
    private readonly ISpeechInput? _fallbackService;
    private readonly string _modelsDir;
    private readonly string _modelPath;
    private readonly GgmlType _modelType;
    private readonly string _language;
    private WhisperFactory? _factory;
    private WhisperProcessor? _processor;
    private readonly SemaphoreSlim _initLock = new(1, 1);
    private readonly SemaphoreSlim _transcribeLock = new(1, 1);
    private TaskCompletionSource<bool>? _stopSignal;
    private bool _disposed;

    // End-of-utterance: stop after this much silence following speech
    private const int SilenceThresholdMs = 1000;
    // Minimum absolute RMS treated as speech; the effective threshold adapts to the room's noise floor
    private const float MinSpeechRms = 0.008f;
    // Consecutive loud 100ms chunks needed before a recording counts as speech
    private const int SpeechOnsetChunks = 3;
    // Upper bound for the adaptive threshold, so a loud room never makes normal speech count as silence
    private const float MaxSpeechThreshold = 0.04f;
    // Minimum recording time before silence detection kicks in
    private const int MinRecordingMs = 500;
    // How often a live partial transcript is produced while speaking
    private const int PartialIntervalMs = 350;
    private const int MaxRecordingSeconds = 30;
    // Pause length that starts the speculative cloud transcription, and how long the final waits for it
    private const int CloudPauseMs = 300;
    private const int CloudFinalTimeoutMs = 3000;

    private static readonly WaveFormat WhisperFormat = new(16000, 16, 1); // 16kHz, 16-bit mono - required by Whisper

    public event Action<string>? SpeechRecognizing;

    /// <summary>
    /// Optional cloud transcriber (e.g. Deepgram via OpenRouter) for the final transcript. It's started the
    /// moment the user pauses, so its round trip overlaps the end-of-speech wait; local Whisper still drives
    /// the live partials, and is the fallback if the cloud call fails or is slow.
    /// </summary>
    public Func<byte[], CancellationToken, Task<string>>? CloudTranscriber { get; set; }

    /// <summary>Overrides the microphone (tests / diagnostics can replay a recording in real time).</summary>
    public Func<IWaveIn>? CaptureFactory { get; set; }

    public WhisperSpeechService(
        ISpeechInput? fallbackService = null,
        string? customModelDir = null,
        ILogger<WhisperSpeechService>? logger = null)
    {
        _fallbackService = fallbackService;
        _logger = logger ?? Microsoft.Extensions.Logging.Abstractions.NullLogger<WhisperSpeechService>.Instance;

        // Default base: with audio-context sizing it transcribes a command in ~0.2s, and is clearly more
        // accurate than tiny for accents and song names
        (_modelType, var modelName) = (Environment.GetEnvironmentVariable("GHOSTHAND_WHISPER_MODEL") ?? "base").Trim().ToLowerInvariant() switch
        {
            "tiny" => (GgmlType.Tiny, "tiny"),
            "small" => (GgmlType.Small, "small"),
            _ => (GgmlType.Base, "base")
        };
        var language = Environment.GetEnvironmentVariable("GHOSTHAND_SPEECH_LANGUAGE");
        // Default English: "auto" often detects Indian-accented English as Hindi and writes Devanagari,
        // which breaks commands and search. Set GHOSTHAND_SPEECH_LANGUAGE=auto (or hi, ...) to override.
        _language = string.IsNullOrWhiteSpace(language) ? "en" : language.Trim();

        _modelsDir = customModelDir ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "GhostHand",
            "models");
        _modelPath = Path.Combine(_modelsDir, $"ggml-{modelName}.bin");
    }

    /// <summary>Loads (and on first run downloads) the model in the background so the first mic press is instant.</summary>
    public async Task WarmUpAsync()
    {
        try
        {
            await EnsureInitializedAsync(CancellationToken.None);

            // The first inference on each processor pays a one-off ~5s setup cost; pay it now, on silence
            foreach (var seconds in new[] { 1, 5 }) // the <4s and <8s buckets cover almost every command
            {
                var silence = new byte[WhisperFormat.AverageBytesPerSecond * seconds];
                await TranscribePcmAsync(silence, WhisperFormat, CancellationToken.None);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Whisper warm-up failed; will retry on first use.");
        }
    }

    /// <summary>Finish listening now and return what was said (unlike cancellation, which discards it).</summary>
    public void RequestStop() => _stopSignal?.TrySetResult(true);

    public static bool HasMicrophone()
    {
        try
        {
            if (WaveInEvent.DeviceCount > 0)
                return true;

            using var enumerator = new MMDeviceEnumerator();
            return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).Count > 0;
        }
        catch
        {
            return WaveInEvent.DeviceCount > 0;
        }
    }

    public async Task<string> TranscribeAsync(CancellationToken cancellationToken = default)
    {
        // 1. Check if any microphone / audio recording device is available
        if (CaptureFactory == null && !HasMicrophone())
        {
            _logger.LogWarning("No microphone/audio recording device found.");
            if (_fallbackService != null)
            {
                return await _fallbackService.TranscribeAsync(cancellationToken);
            }
            throw new InvalidOperationException(
                "No active microphone detected. Connect your Bluetooth headphones (e.g. OnePlus Bullets), plug in a headset/mic, or check Windows Settings → Privacy & Security → Microphone.");
        }

        // 2. Initialize Whisper model (downloads it on first run if missing)
        try
        {
            await EnsureInitializedAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return string.Empty;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Whisper model initialization failed.");
            if (_fallbackService != null)
            {
                _logger.LogInformation("Attempting fallback speech service...");
                return await _fallbackService.TranscribeAsync(cancellationToken);
            }
            throw new InvalidOperationException(
                "Could not load speech model. Check your internet connection for first-time model download: " + ex.Message, ex);
        }

        // 3. Record, producing live partial transcripts until end-of-speech / stop / cancel
        var pcm = new MemoryStream();
        var pcmLock = new object();
        var recordingStoppedTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopSignal = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _stopSignal = stopSignal;

        var recordingStarted = DateTime.UtcNow;
        var lastSpeechAt = DateTime.UtcNow;
        bool hasSpeech = false;
        float noiseFloor = 0.003f;
        int loudRun = 0;

        string partialText = string.Empty;
        long partialCoveredBytes = 0;

        var cloud = CloudTranscriber;
        using var cloudCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<string>? cloudTask = null;
        DateTime cloudForSpeechAt = default; // lastSpeechAt the in-flight cloud request covers

        IWaveIn? waveIn = null;
        WaveFormat captureFormat = WhisperFormat;
        try
        {
            waveIn = CaptureFactory?.Invoke() ?? (WaveInEvent.DeviceCount > 0
                ? new WaveInEvent { WaveFormat = WhisperFormat, BufferMilliseconds = 100 }
                : new WasapiCapture());
            captureFormat = waveIn.WaveFormat;
            var format = captureFormat;

            waveIn.DataAvailable += (s, e) =>
            {
                if (e.BytesRecorded <= 0) return;

                lock (pcmLock)
                {
                    pcm.Write(e.Buffer, 0, e.BytesRecorded);
                }

                // Speech vs silence, relative to an adaptive noise floor so a noisy room still ends the utterance.
                // The floor drops quickly to quiet gaps but rises only very slowly, so soft syllables mid-sentence
                // can't drag it up to speech level and cut the user off (which truncated "…and write hello").
                float rms = ComputeRms(e.Buffer, e.BytesRecorded, format);
                var threshold = Math.Clamp(noiseFloor * 3f, MinSpeechRms, MaxSpeechThreshold);
                var loud = rms >= threshold;
                // A click or bump is one loud chunk; speech only starts after ~300ms of sustained sound
                loudRun = loud ? loudRun + 1 : 0;
                if (loud && (hasSpeech || loudRun >= SpeechOnsetChunks))
                {
                    if (!hasSpeech) VoiceDebug($"speech onset (rms {rms:F4}, threshold {threshold:F4})");
                    hasSpeech = true;
                    lastSpeechAt = DateTime.UtcNow;
                }
                noiseFloor = rms < noiseFloor
                    ? noiseFloor * 0.7f + rms * 0.3f
                    : noiseFloor * 0.998f + rms * 0.002f;

                var elapsed = (DateTime.UtcNow - recordingStarted).TotalMilliseconds;
                var silence = (DateTime.UtcNow - lastSpeechAt).TotalMilliseconds;
                VoiceDebug($"t={elapsed,6:F0} rms={rms:F4} thr={threshold:F4} floor={noiseFloor:F4} {(loud ? "LOUD" : "    ")} speech={hasSpeech} silence={silence:F0}");

                // Speculative cloud final: fire once per pause; if speech resumes, the next pause fires again
                if (cloud != null && hasSpeech && silence >= CloudPauseMs && cloudForSpeechAt != lastSpeechAt)
                {
                    cloudForSpeechAt = lastSpeechAt;
                    byte[] snapshot;
                    lock (pcmLock) snapshot = pcm.ToArray();
                    VoiceDebug($"cloud request started ({snapshot.Length / (double)format.AverageBytesPerSecond:F1}s audio)");
                    cloudTask = StartCloud(cloud, snapshot, format, cloudCts.Token);
                }
                if (hasSpeech && elapsed >= MinRecordingMs && silence >= SilenceThresholdMs)
                {
                    try { waveIn?.StopRecording(); } catch { /* ignore */ }
                }
            };

            waveIn.RecordingStopped += (s, e) =>
            {
                if (e.Exception != null)
                    recordingStoppedTcs.TrySetException(e.Exception);
                else
                    recordingStoppedTcs.TrySetResult(true);
            };

            _logger.LogInformation("Starting microphone recording (live transcription, auto-stops after silence)...");
            recordingStarted = DateTime.UtcNow;
            lastSpeechAt = DateTime.UtcNow;
            waveIn.StartRecording();

            using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(MaxRecordingSeconds));
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            var minNewBytes = captureFormat.AverageBytesPerSecond / 5; // re-transcribe once >=200ms of new audio exists

            while (!recordingStoppedTcs.Task.IsCompleted && !stopSignal.Task.IsCompleted && !linkedCts.IsCancellationRequested)
            {
                try
                {
                    await Task.WhenAny(recordingStoppedTcs.Task, stopSignal.Task, Task.Delay(PartialIntervalMs, linkedCts.Token));
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                if (!hasSpeech || recordingStoppedTcs.Task.IsCompleted || stopSignal.Task.IsCompleted)
                    continue;

                byte[] snapshot;
                lock (pcmLock)
                {
                    if (pcm.Length - partialCoveredBytes < minNewBytes) continue;
                    snapshot = pcm.ToArray();
                }

                try
                {
                    var text = await TranscribePcmAsync(snapshot, captureFormat, linkedCts.Token);
                    partialCoveredBytes = snapshot.Length;
                    partialText = text;
                    VoiceDebug($"partial ({snapshot.Length / (double)captureFormat.AverageBytesPerSecond:F1}s audio): \"{text}\"");
                    if (text.Length > 0)
                        SpeechRecognizing?.Invoke(text);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Partial transcription failed; continuing to record.");
                }
            }

            try { waveIn.StopRecording(); } catch { /* ignore */ }
            try { await recordingStoppedTcs.Task.WaitAsync(TimeSpan.FromSeconds(3)); } catch (TimeoutException) { /* ignore */ }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Microphone recording error.");
            if (_fallbackService != null)
            {
                return await _fallbackService.TranscribeAsync(cancellationToken);
            }
            throw new InvalidOperationException(
                "Microphone recording failed. Check microphone permissions in Windows Settings → Privacy & Security → Microphone. " + ex.Message, ex);
        }
        finally
        {
            _stopSignal = null;
            waveIn?.Dispose();
        }

        if (cancellationToken.IsCancellationRequested)
        {
            _logger.LogInformation("Voice recording cancelled by user.");
            return string.Empty;
        }

        byte[] allAudio;
        lock (pcmLock)
        {
            allAudio = pcm.ToArray();
        }

        if (allAudio.Length == 0 || !hasSpeech)
        {
            _logger.LogInformation("No speech detected in recording.");
            return string.Empty;
        }

        // 4a. Cloud final (more accurate). Usually already in flight since the pause began.
        if (cloud != null)
        {
            if (cloudTask == null || cloudForSpeechAt != lastSpeechAt)
                cloudTask = StartCloud(cloud, allAudio, captureFormat, cloudCts.Token); // e.g. Stop pressed mid-speech

            var waitStart = DateTime.UtcNow;
            try
            {
                var cloudText = CleanTranscript(await cloudTask.WaitAsync(TimeSpan.FromMilliseconds(CloudFinalTimeoutMs), cancellationToken));
                VoiceDebug($"cloud final after extra {(DateTime.UtcNow - waitStart).TotalMilliseconds:F0}ms: \"{cloudText}\"");
                if (cloudText.Length > 0)
                {
                    SpeechRecognizing?.Invoke(cloudText);
                    return cloudText;
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return string.Empty;
            }
            catch (Exception ex)
            {
                VoiceDebug($"cloud final failed ({ex.GetType().Name}: {ex.Message}); using local Whisper");
                _logger.LogWarning(ex, "Cloud transcription failed or timed out; using local Whisper result.");
            }
        }

        // 4b. Local final. If the last partial already covered everything except trailing silence,
        // reuse it so the command is ready instantly.
        var trailingSilenceBytes = (long)captureFormat.AverageBytesPerSecond * (SilenceThresholdMs + 300) / 1000;
        if (partialText.Length > 0 && allAudio.Length - partialCoveredBytes <= trailingSilenceBytes)
        {
            _logger.LogInformation("Using live transcript as final: \"{Result}\"", partialText);
            return partialText;
        }

        try
        {
            var result = await TranscribePcmAsync(allAudio, captureFormat, cancellationToken);
            if (result.Length > 0)
                SpeechRecognizing?.Invoke(result);
            _logger.LogInformation("Whisper transcription result: \"{Result}\"", result);
            return result;
        }
        catch (OperationCanceledException)
        {
            _logger.LogInformation("Whisper transcription cancelled.");
            return string.Empty;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Whisper transcription failed.");
            if (_fallbackService != null)
            {
                return await _fallbackService.TranscribeAsync(cancellationToken);
            }
            throw new InvalidOperationException("Speech transcription failed: " + ex.Message, ex);
        }
    }

    private Task<string> StartCloud(Func<byte[], CancellationToken, Task<string>> cloud, byte[] pcm, WaveFormat format, CancellationToken token)
    {
        using var wav = ToWhisperWav(pcm, format);
        var bytes = wav.ToArray();
        return Task.Run(() => cloud(bytes, token), token);
    }

    private async Task<string> TranscribePcmAsync(byte[] rawBytes, WaveFormat captureFormat, CancellationToken cancellationToken)
    {
        if (_processor == null)
            throw new InvalidOperationException("Whisper processor is not ready.");

        var seconds = rawBytes.Length / (double)captureFormat.AverageBytesPerSecond;

        // Whisper processors aren't safe for concurrent use (e.g. warm-up still running when the mic is pressed)
        var waitStart = DateTime.UtcNow;
        await _transcribeLock.WaitAsync(cancellationToken);
        var runStart = DateTime.UtcNow;
        try
        {
            var processor = GetProcessorFor(seconds);
            using var wavStream = ToWhisperWav(rawBytes, captureFormat);
            var sb = new StringBuilder();
            await foreach (var segment in processor.ProcessAsync(wavStream, cancellationToken))
            {
                if (!string.IsNullOrWhiteSpace(segment.Text))
                    sb.Append(segment.Text.Trim()).Append(' ');
            }

            VoiceDebug($"whisper {seconds:F1}s audio: waited {(runStart - waitStart).TotalMilliseconds:F0}ms, ran {(DateTime.UtcNow - runStart).TotalMilliseconds:F0}ms");
            var text = CleanTranscript(sb.ToString());
            return _language == "en" ? StripNonLatin(text) : text;
        }
        finally
        {
            _transcribeLock.Release();
        }
    }

    /// <summary>Wraps captured PCM as a 16kHz 16-bit mono WAV stream (resampling when needed).</summary>
    private MemoryStream ToWhisperWav(byte[] rawBytes, WaveFormat captureFormat)
    {
        var wavStream = new MemoryStream();
        try
        {
            if (captureFormat.SampleRate == 16000 && captureFormat.BitsPerSample == 16 && captureFormat.Channels == 1)
            {
                // IgnoreDisposeStream: WaveFileWriter closes its target on dispose, which previously left
                // wavStream closed and made every transcription throw ObjectDisposedException
                using var writer = new WaveFileWriter(new IgnoreDisposeStream(wavStream), WhisperFormat);
                writer.Write(rawBytes, 0, rawBytes.Length);
            }
            else
            {
                using var rawStream = new MemoryStream(rawBytes);
                using var rawReader = new RawSourceWaveStream(rawStream, captureFormat);
                using var resampler = new MediaFoundationResampler(rawReader, WhisperFormat) { ResamplerQuality = 60 };
                WaveFileWriter.WriteWavFileToStream(new IgnoreDisposeStream(wavStream), resampler);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Audio resampling failed, falling back to direct PCM header write.");
            wavStream.SetLength(0);
            using var writer = new WaveFileWriter(new IgnoreDisposeStream(wavStream), WhisperFormat);
            writer.Write(rawBytes, 0, rawBytes.Length);
        }

        wavStream.Position = 0;
        return wavStream;
    }

    private static readonly bool VoiceDebugEnabled = Environment.GetEnvironmentVariable("GHOSTHAND_VOICE_DEBUG") == "1";
    private static readonly object VoiceDebugLock = new();

    /// <summary>With GHOSTHAND_VOICE_DEBUG=1, traces mic levels and transcripts to %LOCALAPPDATA%\GhostHand\voice-debug.log.</summary>
    private static void VoiceDebug(string message)
    {
        if (!VoiceDebugEnabled) return;
        try
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GhostHand", "voice-debug.log");
            lock (VoiceDebugLock)
                File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {message}\n");
        }
        catch
        {
            // Diagnostics only
        }
    }

    /// <summary>Drops Whisper's non-speech markers such as [BLANK_AUDIO], (music), *coughs*.</summary>
    public static string CleanTranscript(string text)
    {
        var cleaned = Regex.Replace(text, @"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*", " ");
        cleaned = Regex.Replace(cleaned, @"\s+", " ").Trim();

        // Whisper loops on audio cut mid-word: "open chrome and search open chrome and search ..." → once.
        // Only multi-word phrases collapse, so real repeated words in titles ("Dooron Dooron") survive.
        return Regex.Replace(cleaned, @"\b(\S+(?:\s+\S+)+?)(?:[\s,.]+\1(?!\w))+", "$1", RegexOptions.IgnoreCase);
    }

    /// <summary>In English mode, drops stray non-Latin glyphs Whisper emits on partial audio ("opensp叫").</summary>
    public static string StripNonLatin(string text)
    {
        var cleaned = Regex.Replace(text, @"[^\u0000-ɏ‘-”]", " ");
        return Regex.Replace(cleaned, @"\s+", " ").Trim();
    }

    /// <summary>Compute RMS (volume) of audio buffer.</summary>
    private static float ComputeRms(byte[] buffer, int bytesRecorded, WaveFormat format)
    {
        if (bytesRecorded < 2) return 0f;

        if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
        {
            int floatCount = bytesRecorded / 4;
            double sum = 0;
            for (int i = 0; i < bytesRecorded - 3; i += 4)
            {
                float sample = BitConverter.ToSingle(buffer, i);
                sum += sample * sample;
            }
            return (float)Math.Sqrt(sum / Math.Max(1, floatCount));
        }
        else
        {
            int sampleCount = bytesRecorded / 2;
            double sum = 0;
            for (int i = 0; i < bytesRecorded - 1; i += 2)
            {
                short sample = (short)(buffer[i] | (buffer[i + 1] << 8));
                double normalized = sample / 32768.0;
                sum += normalized * normalized;
            }
            return (float)Math.Sqrt(sum / Math.Max(1, sampleCount));
        }
    }

    // Whisper's encoder always runs over a padded 30s window (1500 frames, 50/s) unless audio_ctx is reduced.
    // Commands are 1–5s, so sizing the context to the audio makes each (live) transcription several times
    // faster. Processors are cached per bucket; the last bucket is the full 30s window.
    private static readonly int[] AudioBucketsSeconds = [4, 8, 15];
    private readonly Dictionary<int, WhisperProcessor> _bucketProcessors = new();

    // Biases recognition toward the vocabulary of desktop commands (app names, verbs)
    private const string CommandPrompt =
        "Voice commands for a Windows assistant: open Spotify and play a song, open Chrome and search, " +
        "launch Notepad, play on YouTube, switch to Discord.";

    private WhisperProcessor GetProcessorFor(double seconds)
    {
        foreach (var bucket in AudioBucketsSeconds)
        {
            if (seconds <= bucket - 0.5)
            {
                if (!_bucketProcessors.TryGetValue(bucket, out var processor))
                {
                    processor = BuildProcessor(audioContextSize: bucket * 50 + 50, maxTokens: bucket * 8);
                    _bucketProcessors[bucket] = processor;
                }
                return processor;
            }
        }
        return _processor!;
    }

    // More threads than this gains nothing for short commands (4 measured as fast as 6-8 on a 16-core machine)
    // and leaves cores free for audio capture and the UI. GHOSTHAND_WHISPER_THREADS overrides.
    private static int WhisperThreads =>
        int.TryParse(Environment.GetEnvironmentVariable("GHOSTHAND_WHISPER_THREADS"), out var t) && t > 0
            ? t
            : Math.Clamp(Environment.ProcessorCount / 4, 1, 4);

    private WhisperProcessor BuildProcessor(int? audioContextSize, int maxTokens = 200)
    {
        var builder = _factory!.CreateBuilder()
            .WithLanguage(_language)
            .WithThreads(WhisperThreads)
            .WithPrompt(CommandPrompt)
            .WithNoContext()
            .WithSingleSegment()
            // Audio cut mid-word (every live partial) can send the decoder into a repetition loop that runs to
            // the 448-token limit, and low confidence triggers re-decoding at higher temperatures: one 1.5s clip
            // took 27s. Speech is ~4 tokens/s, so cap tokens to the bucket length (a loop is cut after ~8/s)
            // and decode once, greedily.
            .WithMaxTokensPerSegment(maxTokens)
            .WithTemperature(0f)
            .WithTemperatureInc(0f);
        if (audioContextSize is int ctx)
            builder = builder.WithAudioContextSize(ctx);
        return builder.Build();
    }

    private async Task EnsureInitializedAsync(CancellationToken cancellationToken)
    {
        if (_processor != null) return;

        await _initLock.WaitAsync(cancellationToken);
        try
        {
            if (_processor != null) return;

            Directory.CreateDirectory(_modelsDir);

            if (!File.Exists(_modelPath))
            {
                _logger.LogInformation("Whisper model not found. Downloading {Model} on first run...", _modelType);
                await DownloadModelAsync(_modelPath, cancellationToken);
            }

            _logger.LogInformation("Loading Whisper model from {Path}...", _modelPath);
            _factory = WhisperFactory.FromPath(_modelPath);
            _processor = BuildProcessor(audioContextSize: null);
            GetProcessorFor(3); // pre-build the short-command bucket used by live partials

            _logger.LogInformation("Whisper processor initialized successfully.");
        }
        finally
        {
            _initLock.Release();
        }
    }

    private async Task DownloadModelAsync(string destinationPath, CancellationToken cancellationToken)
    {
        var tempPath = destinationPath + ".downloading";
        using var httpClient = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        try
        {
            _logger.LogInformation("Downloading Whisper {Model} model...", _modelType);
            Stream modelStream;
            try
            {
                modelStream = await WhisperGgmlDownloader.GetGgmlModelAsync(_modelType, cancellationToken: cancellationToken);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "WhisperGgmlDownloader failed, trying HuggingFace direct download...");
                modelStream = await httpClient.GetStreamAsync(
                    $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{Path.GetFileName(destinationPath)}",
                    cancellationToken);
            }

            using (modelStream)
            using (var fileStream = File.Create(tempPath))
            {
                await modelStream.CopyToAsync(fileStream, cancellationToken);
            }

            if (File.Exists(destinationPath)) File.Delete(destinationPath);
            File.Move(tempPath, destinationPath);
            _logger.LogInformation("Whisper model downloaded to {Path}", destinationPath);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _disposed = true;
            foreach (var p in _bucketProcessors.Values) p.Dispose();
            _processor?.Dispose();
            _factory?.Dispose();
            _initLock.Dispose();
            _transcribeLock.Dispose();
            _fallbackService?.Dispose();
        }
    }
}
