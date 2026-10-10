using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace GhostHand.Core.Jev;

/// <summary>
/// IJevClient implementation backed by any chat model on OpenRouter (OpenAI-compatible
/// /chat/completions). Translates the Jev evaluate contract (boolean / choice / score questions)
/// into a JSON-mode prompt and maps the model's reply back into an EvaluateResponse, so the
/// decision model and agent loop are unaffected.
/// </summary>
public class OpenRouterJevClient : IJevClient
{
    private readonly HttpClient _httpClient;
    private readonly JevOptions _options;
    private readonly ILogger<OpenRouterJevClient> _logger;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        // Plain quotes instead of \u0022: smaller prompts that models read more reliably
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private const string SystemPrompt =
        "You are the decision engine of a Windows desktop automation agent. " +
        "You receive the current screen STATE as JSON and a set of QUESTIONS. " +
        "Answer every question and reply with ONE JSON object only (no prose, no code fences), " +
        "keyed by question name, using exactly these shapes:\n" +
        "- boolean question: {\"probability\": <number 0..1 that the answer is yes>}\n" +
        "- choice question: {\"choice\": <the option NUMBER you pick, e.g. 3>, \"confidence\": <number 0..1>}\n" +
        "- score question: {\"score\": <integer 1..N where 1 is the first (lowest) level>, \"probabilities\": [<one number per level, summing to 1>]}\n" +
        "Be conservative: prefer the action that most directly advances the task, and never claim a task is done unless the state clearly shows it.";

    public OpenRouterJevClient(HttpClient httpClient, JevOptions options, ILogger<OpenRouterJevClient> logger)
    {
        _httpClient = httpClient;
        _options = options;
        _logger = logger;
    }

    public async Task<EvaluateResponse> EvaluateAsync(EvaluateRequest request, CancellationToken cancellationToken = default)
    {
        var apiKey = _options.ApiKey;
        var isLaya = _options.Provider == JevProvider.Laya;
        if (string.IsNullOrWhiteSpace(apiKey) && !isLaya)
        {
            throw new AuthException(_options.Provider == JevProvider.Groq
                ? "API key is not configured. Set GROQ_API_KEY in .env or environment."
                : "API key is not configured. Set OPENROUTER_API_KEY in .env or environment.");
        }

        // Jev on OpenRouter (~typesafe/jev-latest) is a "decisions" model: it natively answers typed
        // questions via /api/alpha/decisions and is rejected by /chat/completions.
        // Laya (laya-serve) implements the same typed-decisions contract at /v1/systemone
        var decisions = isLaya || (_options.Provider != JevProvider.Groq && IsDecisionsModel(_options.ModelId));
        var url = isLaya
            ? $"{_options.BaseUrl.TrimEnd('/')}/v1/systemone"
            : decisions ? DecisionsUrl(_options.BaseUrl) : $"{_options.BaseUrl.TrimEnd('/')}/chat/completions";
        var requestJson = (decisions ? BuildDecisionsRequest(request) : BuildChatRequest(request)).ToJsonString(JsonOpts);

        var stopwatch = Stopwatch.StartNew();
        int attempts = 0;
        var correctionSent = false;

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            attempts++;

            using var httpRequest = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(requestJson, Encoding.UTF8, "application/json")
            };
            if (!string.IsNullOrWhiteSpace(apiKey))
                httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            httpRequest.Headers.TryAddWithoutValidation("HTTP-Referer", "https://github.com/dushyantzz/Ghosthand");
            httpRequest.Headers.TryAddWithoutValidation("X-Title", "GhostHand");

            HttpResponseMessage response;
            try
            {
                using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(_options.TimeoutSeconds));
                using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
                response = await _httpClient.SendAsync(httpRequest, linkedCts.Token);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                _logger.LogInformation("OpenRouter request was cancelled by kill switch / cancellation token.");
                throw;
            }
            catch (OperationCanceledException ex)
            {
                _logger.LogWarning("OpenRouter request timed out after {Seconds} seconds.", _options.TimeoutSeconds);
                if (attempts <= _options.MaxRetries)
                {
                    await BackoffDelayAsync(attempts, cancellationToken);
                    continue;
                }
                throw new TransientException("Request timed out after max retries.", 408, ex);
            }
            catch (HttpRequestException ex)
            {
                _logger.LogWarning(ex, "HTTP network transport failure on attempt {Attempt}", attempts);
                if (attempts <= _options.MaxRetries)
                {
                    await BackoffDelayAsync(attempts, cancellationToken);
                    continue;
                }
                throw new TransientException($"Network failure: {ex.Message}", 0, ex);
            }

            var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
            var statusCode = (int)response.StatusCode;

            if (response.IsSuccessStatusCode)
            {
                if (decisions)
                {
                    var decided = ParseDecisionsResponse(responseBody, request);
                    _logger.LogInformation("Decision completed in {LatencyMs}ms", stopwatch.ElapsedMilliseconds);
                    return decided;
                }

                var result = ParseChatResponse(responseBody, request, out var unmappedChoices, out var reply);

                // A chat model occasionally names an option that doesn't exist; ask once more, saying why,
                // instead of failing the step with "Could not parse decision"
                if (unmappedChoices.Count > 0 && !correctionSent)
                {
                    correctionSent = true;
                    requestJson = BuildCorrectionRequest(request, reply, unmappedChoices).ToJsonString(JsonOpts);
                    _logger.LogWarning("Model chose an invalid option for {Questions}; asking again.", string.Join(", ", unmappedChoices));
                    continue;
                }

                _logger.LogInformation("Decision completed in {LatencyMs}ms", stopwatch.ElapsedMilliseconds);
                return result;
            }

            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                _logger.LogError("Authentication rejected by OpenRouter (HTTP {StatusCode})", statusCode);
                throw new AuthException(responseBody, statusCode);
            }

            if (statusCode is >= 400 and < 500 and not 429)
            {
                _logger.LogError("Client error from OpenRouter (HTTP {StatusCode}): {Body}", statusCode, responseBody);
                throw new ProtocolException($"Client request rejected (HTTP {statusCode}): {responseBody}");
            }

            if (attempts <= _options.MaxRetries)
            {
                _logger.LogWarning("Transient OpenRouter error (HTTP {StatusCode}). Retrying attempt {NextAttempt}/{MaxRetries}...",
                    statusCode, attempts + 1, _options.MaxRetries);
                await BackoffDelayAsync(attempts, cancellationToken);
                stopwatch.Restart();
                continue;
            }

            throw new TransientException(responseBody, statusCode);
        }
    }

    public static bool IsDecisionsModel(string modelId) =>
        modelId.Contains("/jev", StringComparison.OrdinalIgnoreCase);

    /// <summary>https://openrouter.ai/api/v1 → https://openrouter.ai/api/alpha/decisions</summary>
    private static string DecisionsUrl(string baseUrl)
    {
        var root = baseUrl.TrimEnd('/');
        if (root.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
            root = root[..^3];
        return $"{root}/alpha/decisions";
    }

    private JsonObject BuildDecisionsRequest(EvaluateRequest request)
    {
        var questions = new JsonObject();
        foreach (var (name, q) in request.Questions)
        {
            // OpenRouter names the yes/no question type "noul"; choice and score match the Jev contract
            var node = new JsonObject { ["type"] = q.Type == "boolean" ? "noul" : q.Type };
            if (!string.IsNullOrEmpty(q.Instructions))
                node["instructions"] = q.Instructions;
            if (q.Criteria != null)
                node["criteria"] = JsonSerializer.SerializeToNode(q.Criteria, JsonOpts);
            questions[name] = node;
        }

        var body = new JsonObject
        {
            ["model"] = _options.ModelId,
            ["state"] = JsonSerializer.SerializeToNode(request.State, JsonOpts),
            ["questions"] = questions
        };

        if (_options.Provider == JevProvider.Laya)
        {
            // Laya packs options + state into one encoder sequence; its defaults (192 option tokens,
            // 512-1024 total) would truncate a GhostHand step's 20-60 options and 40 screen controls
            body["max_len"] = _options.LayaMaxLen;
            body["head_max_len"] = _options.LayaHeadMaxLen;
        }

        return body;
    }

    /// <summary>
    /// Maps OpenRouter decisions answers onto the shapes EvaluateResponse reads:
    /// noul → {probability}; choice passes through; score (0..1 plus per-level probabilities keyed "0".."N-1")
    /// → {score: most likely level, 1-based, probabilities: [..]} as the decision model's risk thresholds expect.
    /// </summary>
    public static EvaluateResponse ParseDecisionsResponse(string responseBody, EvaluateRequest request)
    {
        JsonObject root;
        try
        {
            root = JsonNode.Parse(responseBody) as JsonObject ?? throw new ProtocolException("Decisions response was not a JSON object.");
        }
        catch (JsonException ex)
        {
            throw new ProtocolException($"Failed to parse decisions response: {ex.Message}", ex);
        }

        var rawAnswers = root["answers"] as JsonObject ?? new JsonObject();
        var answers = new Dictionary<string, JsonElement>();

        foreach (var (name, q) in request.Questions)
        {
            if (rawAnswers[name] is not JsonObject a)
                continue;

            JsonObject? normalized = null;
            switch (q.Type)
            {
                case "boolean":
                    var p = ReadDouble(a["noul"]) ?? ReadDouble(a["probability"]);
                    if (p != null)
                        normalized = new JsonObject { ["probability"] = Math.Clamp(p.Value, 0, 1) };
                    break;

                case "choice":
                    var choice = a["choice"]?.ToString();
                    if (!string.IsNullOrEmpty(choice) &&
                        (q.Criteria is not Dictionary<string, string> opts || opts.ContainsKey(choice)))
                        normalized = new JsonObject { ["choice"] = choice, ["probabilities"] = a["probabilities"]?.DeepClone() ?? new JsonObject() };
                    break;

                case "score":
                    var probs = new List<double>();
                    if (a["probabilities"] is JsonObject po)
                        probs = po.Select(kv => (Index: int.TryParse(kv.Key, out var i) ? i : int.MaxValue, P: ReadDouble(kv.Value) ?? 0))
                                  .OrderBy(x => x.Index).Select(x => x.P).ToList();
                    else if (a["probabilities"] is JsonArray pa)
                        probs = pa.Select(v => ReadDouble(v) ?? 0).ToList();

                    int level;
                    if (probs.Count > 0)
                        level = probs.IndexOf(probs.Max()) + 1;
                    else if (ReadDouble(a["score"]) is double s && q.Criteria is IReadOnlyList<string> levels && levels.Count > 0)
                        level = (int)Math.Round(Math.Clamp(s, 0, 1) * (levels.Count - 1)) + 1;
                    else
                        break;

                    normalized = new JsonObject { ["score"] = level, ["probabilities"] = new JsonArray(probs.Select(x => (JsonNode?)x).ToArray()) };
                    break;
            }

            if (normalized != null)
                answers[name] = JsonSerializer.SerializeToElement(normalized);
            else
                DebugLog($"Could not map decisions answer for '{name}'\nReply: {a.ToJsonString()}");
        }

        UsageInfo? usage = null;
        if (root["usage"] is JsonObject u)
        {
            var input = (int)(ReadDouble(u["input_tokens"]) ?? 0);
            var output = (int)(ReadDouble(u["output_tokens"]) ?? 0);
            usage = new UsageInfo { PromptTokens = input, CompletionTokens = output, TotalTokens = input + output };
        }

        return new EvaluateResponse
        {
            Answers = answers,
            Usage = usage,
            ProviderMetadata = new ProviderMetadataInfo
            {
                Gateway = new GatewayMetadata
                {
                    Cost = root["usage"]?["cost"] is JsonNode c ? ReadDouble(c) : null,
                    Provider = root["provider"]?.ToString(),
                    Model = root["model"]?.ToString(),
                    GenerationId = root["id"]?.ToString()
                }
            }
        };
    }

    private JsonObject BuildChatRequest(EvaluateRequest request)
    {
        var questions = new JsonObject();
        foreach (var (name, q) in request.Questions)
        {
            var node = new JsonObject { ["type"] = q.Type };
            if (!string.IsNullOrEmpty(q.Instructions))
                node["instructions"] = q.Instructions;
            if (q.Criteria is Dictionary<string, string> options)
            {
                // Numbered options: models reliably return 7 but often mangle long keys like "type_and_enter:e12:..."
                var numbered = new JsonObject();
                int i = 1;
                foreach (var (key, desc) in options)
                    numbered[(i++).ToString()] = string.IsNullOrWhiteSpace(desc) ? key : desc;
                node["options"] = numbered;
                // Screen elements are also numbered (e1..e40); without this, models sometimes answer an element
                // number ("choice": 40) instead of an option number
                node["answer_with"] = $"one option number from 1 to {options.Count} (not an element id)";
            }
            else if (q.Criteria != null)
            {
                node["levels"] = JsonSerializer.SerializeToNode(q.Criteria, JsonOpts);
            }
            questions[name] = node;
        }

        var userContent =
            "STATE:\n" + JsonSerializer.Serialize(request.State, JsonOpts) +
            "\n\nQUESTIONS:\n" + questions.ToJsonString(JsonOpts);

        var body = new JsonObject
        {
            ["model"] = _options.ModelId,
            ["temperature"] = 0,
            ["response_format"] = new JsonObject { ["type"] = "json_object" },
            ["messages"] = new JsonArray
            {
                new JsonObject { ["role"] = "system", ["content"] = SystemPrompt },
                new JsonObject { ["role"] = "user", ["content"] = userContent }
            }
        };

        if (_options.ZeroDataRetention)
        {
            body["provider"] = new JsonObject { ["data_collection"] = "deny" };
        }

        if (_options.ChatReasoning is bool reasoning)
        {
            if (_options.Provider == JevProvider.Groq)
            {
                // Groq's parameter: "none" disables thinking on Qwen 3.x; gpt-oss models can't turn it off,
                // "low" is their minimum
                if (!reasoning)
                    body["reasoning_effort"] = _options.ModelId.Contains("gpt-oss", StringComparison.OrdinalIgnoreCase) ? "low" : "none";
            }
            else
            {
                body["reasoning"] = new JsonObject { ["enabled"] = reasoning };
            }
        }

        if (_options.ZeroDataRetention && _options.Provider == JevProvider.Groq)
        {
            body.Remove("provider"); // OpenRouter-only field
        }

        return body;
    }

    /// <summary>The original request plus the invalid reply and a short correction naming the valid range.</summary>
    private JsonObject BuildCorrectionRequest(EvaluateRequest request, string reply, IReadOnlyList<string> unmappedChoices)
    {
        var body = BuildChatRequest(request);
        var ranges = string.Join("; ", unmappedChoices.Select(name =>
            $"\"{name}\" must be an option number from 1 to {(request.Questions[name].Criteria as Dictionary<string, string>)?.Count ?? 0}"));
        var messages = (JsonArray)body["messages"]!;
        messages.Add(new JsonObject { ["role"] = "assistant", ["content"] = reply });
        messages.Add(new JsonObject
        {
            ["role"] = "user",
            ["content"] = $"That choice is not one of the listed options: {ranges}. Reply again with the same JSON object, using a listed option number."
        });
        return body;
    }

    internal static EvaluateResponse ParseChatResponse(string responseBody, EvaluateRequest request) =>
        ParseChatResponse(responseBody, request, out _, out _);

    internal static EvaluateResponse ParseChatResponse(string responseBody, EvaluateRequest request,
        out List<string> unmappedChoices, out string content)
    {
        UsageInfo? usage = null;
        try
        {
            using var doc = JsonDocument.Parse(responseBody);
            var root = doc.RootElement;
            content = root.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString() ?? string.Empty;

            if (root.TryGetProperty("usage", out var u) && u.ValueKind == JsonValueKind.Object)
            {
                usage = new UsageInfo
                {
                    PromptTokens = u.TryGetProperty("prompt_tokens", out var pt) && pt.TryGetInt32(out var p) ? p : 0,
                    CompletionTokens = u.TryGetProperty("completion_tokens", out var ct) && ct.TryGetInt32(out var c) ? c : 0,
                    TotalTokens = u.TryGetProperty("total_tokens", out var tt) && tt.TryGetInt32(out var t) ? t : 0
                };
            }
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException or IndexOutOfRangeException)
        {
            throw new ProtocolException($"Unexpected OpenRouter response shape: {ex.Message}", ex);
        }

        JsonObject modelAnswers;
        try
        {
            modelAnswers = JsonNode.Parse(ExtractJsonObject(content)) as JsonObject
                ?? throw new ProtocolException("Model reply was not a JSON object.");
        }
        catch (JsonException ex)
        {
            throw new ProtocolException($"Model reply was not valid JSON: {ex.Message}", ex);
        }

        if (modelAnswers["answers"] is JsonObject wrapped && request.Questions.Keys.All(k => modelAnswers[k] == null))
            modelAnswers = wrapped;

        var answers = new Dictionary<string, JsonElement>();
        foreach (var (name, q) in request.Questions)
        {
            var node = modelAnswers[name];
            if (node is JsonValue bare)
            {
                // Bare answers: {"nextAction": 3} / {"done": true} / {"actionRisk": 2}
                node = q.Type switch
                {
                    "choice" => new JsonObject { ["choice"] = bare.ToString() },
                    "score" => new JsonObject { ["score"] = bare.DeepClone() },
                    _ => new JsonObject { ["answer"] = bare.DeepClone() }
                };
            }
            if (node is not JsonObject a)
                continue;

            JsonObject? normalized = q.Type switch
            {
                "boolean" => NormalizeBoolean(a),
                "choice" => NormalizeChoice(a, q),
                "score" => NormalizeScore(a),
                _ => a
            };

            if (normalized != null)
                answers[name] = JsonSerializer.SerializeToElement(normalized);
        }

        var unmapped = request.Questions.Keys.Where(k => modelAnswers[k] != null && !answers.ContainsKey(k)).ToList();
        unmappedChoices = unmapped.Where(k => request.Questions[k].Type == "choice").ToList();
        if (unmapped.Count > 0)
        {
            var optionCounts = string.Join(", ", unmapped.Select(k =>
                $"{k}: {(request.Questions[k].Criteria as Dictionary<string, string>)?.Count ?? 0} options"));
            DebugLog($"Could not map answers for [{optionCounts}]\nReply: {content}");
        }

        return new EvaluateResponse { Answers = answers, Usage = usage };
    }

    private static JsonObject? NormalizeBoolean(JsonObject a)
    {
        var p = ReadDouble(a["probability"]);
        if (p == null)
        {
            // Tolerate {"answer": true} style replies
            var ans = a["answer"] ?? a["value"];
            if (ans is JsonValue v && v.TryGetValue<bool>(out var b))
                p = b ? 1.0 : 0.0;
        }
        return p == null ? null : new JsonObject { ["probability"] = Math.Clamp(p.Value, 0, 1) };
    }

    private static JsonObject? NormalizeChoice(JsonObject a, QuestionDefinition q)
    {
        var raw = (a["choice"] ?? a["option"] ?? a["answer"])?.ToString()?.Trim().Trim('"', '\'', '.', ' ');
        if (string.IsNullOrEmpty(raw))
            return null;

        // Map back to a valid option key; the decision model parses the key structurally
        if (q.Criteria is Dictionary<string, string> options && !options.ContainsKey(raw))
        {
            var keys = options.Keys.ToList();
            string? match = null;

            var number = Regex.Match(raw, @"^(?:option\s*)?#?(\d+)\b", RegexOptions.IgnoreCase);
            if (number.Success && int.TryParse(number.Groups[1].Value, out var n) && n >= 1 && n <= keys.Count)
                match = keys[n - 1];

            match ??= keys.FirstOrDefault(k => string.Equals(k, raw, StringComparison.OrdinalIgnoreCase))
                ?? options.FirstOrDefault(kv => string.Equals(kv.Value, raw, StringComparison.OrdinalIgnoreCase)).Key;

            // An out-of-range number or "e40" / "click:e40" is usually an element id: use that element's action
            if (match == null)
            {
                var element = Regex.Match(raw, @"^(?:click:)?e?(\d+)$", RegexOptions.IgnoreCase);
                if (element.Success)
                {
                    var id = "e" + element.Groups[1].Value;
                    match = keys.FirstOrDefault(k => k.Equals($"click:{id}", StringComparison.OrdinalIgnoreCase))
                        ?? keys.FirstOrDefault(k => k.StartsWith($"type_and_enter:{id}:", StringComparison.OrdinalIgnoreCase))
                        ?? keys.FirstOrDefault(k => k.StartsWith($"type:{id}:", StringComparison.OrdinalIgnoreCase));
                }
            }
            if (match == null)
                return null;
            raw = match;
        }

        var confidence = Math.Clamp(ReadDouble(a["confidence"]) ?? 1.0, 0, 1);
        return new JsonObject
        {
            ["choice"] = raw,
            ["probabilities"] = new JsonObject { [raw] = confidence }
        };
    }

    private static JsonObject? NormalizeScore(JsonObject a)
    {
        var score = ReadDouble(a["score"]);
        if (score == null)
            return null;

        var probs = new JsonArray();
        if (a["probabilities"] is JsonArray arr)
        {
            foreach (var item in arr)
            {
                var d = ReadDouble(item);
                if (d != null) probs.Add(d.Value);
            }
        }

        return new JsonObject { ["score"] = (int)Math.Round(score.Value), ["probabilities"] = probs };
    }

    private static double? ReadDouble(JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<string>(out var s) &&
            double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed))
            return parsed;
        return null;
    }

    /// <summary>Folder for openrouter-debug.log; tests point it elsewhere so they don't write into the user's log.</summary>
    public static string? DebugLogDirectory { get; set; }

    /// <summary>Appends unparseable model replies to %LOCALAPPDATA%\GhostHand\openrouter-debug.log.</summary>
    private static void DebugLog(string message)
    {
        try
        {
            var dir = DebugLogDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GhostHand");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "openrouter-debug.log"), $"[{DateTime.Now:O}] {message}\n\n");
        }
        catch
        {
            // Diagnostics only
        }
    }

    /// <summary>Strips code fences / surrounding prose some models add despite JSON mode.</summary>
    private static string ExtractJsonObject(string content)
    {
        var start = content.IndexOf('{');
        var end = content.LastIndexOf('}');
        return start >= 0 && end > start ? content[start..(end + 1)] : content;
    }

    private static async Task BackoffDelayAsync(int attempt, CancellationToken ct)
    {
        var baseMs = (int)(Math.Pow(2, attempt - 1) * 500);
        var jitter = Random.Shared.Next(0, 250);
        await Task.Delay(baseMs + jitter, ct);
    }
}
