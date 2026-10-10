using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace GhostHand.Platform.Speech;

/// <summary>
/// Cloud speech-to-text through OpenRouter's /audio/transcriptions endpoint (Deepgram Nova-3 by default).
/// Batch only (no streaming) with ~1–2s round trips, so it's used for the final, more accurate transcript
/// while local Whisper keeps producing the instant live partials.
/// </summary>
/// <remarks>
/// Enabled with GHOSTHAND_STT=deepgram and OPENROUTER_API_KEY. GHOSTHAND_STT_MODEL overrides the model
/// (default deepgram/nova-3).
/// </remarks>
public sealed class OpenRouterDeepgramTranscriber : IDisposable
{
    public const string DefaultModel = "deepgram/nova-3";

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly string _apiKey;
    private readonly string _url;
    private readonly string _model;
    private readonly string? _language;
    private readonly ILogger _logger;

    public OpenRouterDeepgramTranscriber(string apiKey, string? baseUrl = null, string? model = null, string? language = "en", ILogger? logger = null)
    {
        _apiKey = apiKey;
        _url = $"{(string.IsNullOrWhiteSpace(baseUrl) ? "https://openrouter.ai/api/v1" : baseUrl.TrimEnd('/'))}/audio/transcriptions";
        _model = string.IsNullOrWhiteSpace(model) ? DefaultModel : model;
        _language = language is "auto" ? null : language;
        _logger = logger ?? Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance;
    }

    /// <summary>Builds the transcriber from the environment, or null when cloud STT isn't enabled.</summary>
    public static OpenRouterDeepgramTranscriber? FromEnvironment(ILogger? logger = null)
    {
        if (!string.Equals(Environment.GetEnvironmentVariable("GHOSTHAND_STT"), "deepgram", StringComparison.OrdinalIgnoreCase))
            return null;

        var key = Environment.GetEnvironmentVariable("OPENROUTER_API_KEY");
        if (string.IsNullOrWhiteSpace(key))
        {
            logger?.LogWarning("GHOSTHAND_STT=deepgram but OPENROUTER_API_KEY is not set; using local Whisper only.");
            return null;
        }

        var language = Environment.GetEnvironmentVariable("GHOSTHAND_SPEECH_LANGUAGE");
        return new OpenRouterDeepgramTranscriber(
            key,
            Environment.GetEnvironmentVariable("OPENROUTER_BASE_URL"),
            Environment.GetEnvironmentVariable("GHOSTHAND_STT_MODEL"),
            string.IsNullOrWhiteSpace(language) ? "en" : language.Trim(),
            logger);
    }

    /// <summary>Transcribes a WAV (any PCM format Deepgram accepts). Throws on HTTP / protocol failure.</summary>
    public async Task<string> TranscribeAsync(byte[] wav, CancellationToken cancellationToken)
    {
        // OpenRouter rejects .NET's default multipart encoding (unquoted part names, quoted boundary) with
        // "Invalid multipart/form-data body", so the headers are written explicitly
        var boundary = "----GhostHand" + Guid.NewGuid().ToString("N");
        using var form = new MultipartFormDataContent(boundary);
        form.Headers.ContentType = MediaTypeHeaderValue.Parse($"multipart/form-data; boundary={boundary}");

        form.Add(TextPart("model", _model));
        if (!string.IsNullOrEmpty(_language))
            form.Add(TextPart("language", _language));

        var file = new ByteArrayContent(wav);
        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        file.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data") { Name = "\"file\"", FileName = "\"speech.wav\"" };
        form.Add(file);

        using var request = new HttpRequestMessage(HttpMethod.Post, _url) { Content = form };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
        request.Headers.TryAddWithoutValidation("X-Title", "GhostHand");

        using var response = await _http.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"Cloud transcription failed (HTTP {(int)response.StatusCode}): {body[..Math.Min(300, body.Length)]}");

        using var doc = JsonDocument.Parse(body);
        var text = doc.RootElement.TryGetProperty("text", out var t) ? t.GetString() ?? string.Empty : string.Empty;
        _logger.LogInformation("Cloud transcription ({Model}): \"{Text}\"", _model, text);
        return text.Trim();
    }

    private static StringContent TextPart(string name, string value)
    {
        var part = new StringContent(value);
        part.Headers.ContentType = null;
        part.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data") { Name = $"\"{name}\"" };
        return part;
    }

    public void Dispose() => _http.Dispose();
}
