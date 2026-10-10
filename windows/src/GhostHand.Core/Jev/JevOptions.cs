namespace GhostHand.Core.Jev;

public enum JevProvider
{
    VercelGateway,
    OpenRouter,
    /// <summary>Self-hosted Laya (open-source Jev-compatible decision model) via laya-serve.</summary>
    Laya,
    /// <summary>Any chat model on Groq (OpenAI-compatible), answering GhostHand's questions as JSON.</summary>
    Groq
}

public class JevOptions
{
    public const string OpenRouterDefaultBaseUrl = "https://openrouter.ai/api/v1";
    public const string OpenRouterDefaultModel = "openai/gpt-4o-mini";
    public const string LayaDefaultBaseUrl = "http://localhost:8000";
    public const string GroqDefaultBaseUrl = "https://api.groq.com/openai/v1";
    public const string GroqDefaultModel = "qwen/qwen3.8-27b";
    // laya-multilingual reads up to 8,192 tokens; the English checkpoint only 512, too few for a
    // GhostHand step (40 controls + 20-60 action options is ~1.5-3k tokens)
    public const string LayaDefaultModel = "multilingual";

    public JevProvider Provider { get; set; } = JevProvider.VercelGateway;
    public string BaseUrl { get; set; } = "https://ai-gateway.vercel.sh";
    public string ModelId { get; set; } = "typesafe-ai/jev";
    public string? ApiKey { get; set; }
    public bool ZeroDataRetention { get; set; } = false;
    public int TimeoutSeconds { get; set; } = 30;
    public int MaxRetries { get; set; } = 4;
    public double DecisionConfidenceThreshold { get; set; } = 0.0;
    public double RiskConfidenceThreshold { get; set; } = 0.70;

    /// <summary>Laya: token budget for state + options per question (sent as max_len).</summary>
    public int LayaMaxLen { get; set; } = 4096;
    /// <summary>Laya: token budget for the options of one question (sent as head_max_len; library default 192).</summary>
    public int LayaHeadMaxLen { get; set; } = 1024;

    /// <summary>
    /// Chat models only: false asks OpenRouter to skip the model's hidden reasoning ("thinking") pass.
    /// Reasoning models (Qwen 3.x, DeepSeek R1 …) are accurate but take 5-30 s per decision with it on.
    /// </summary>
    public bool? ChatReasoning { get; set; }

    /// <summary>Self-hosted Laya needs no key unless its server sets LAYA_API_KEY.</summary>
    public bool RequiresApiKey => Provider != JevProvider.Laya;

    public static JevOptions FromEnvironment()
    {
        var options = new JevOptions();

        var baseUrl = Environment.GetEnvironmentVariable("AI_GATEWAY_BASE_URL");
        if (!string.IsNullOrWhiteSpace(baseUrl))
            options.BaseUrl = baseUrl;

        var model = Environment.GetEnvironmentVariable("JEV_MODEL");
        if (!string.IsNullOrWhiteSpace(model))
            options.ModelId = model;

        var key = Environment.GetEnvironmentVariable("AI_GATEWAY_API_KEY");
        if (!string.IsNullOrWhiteSpace(key))
            options.ApiKey = key;

        // OpenRouter: selected by AI_PROVIDER=openrouter, or implicitly when only OPENROUTER_API_KEY is set
        var provider = Environment.GetEnvironmentVariable("AI_PROVIDER");
        var openRouterKey = Environment.GetEnvironmentVariable("OPENROUTER_API_KEY");
        if (string.Equals(provider, "openrouter", StringComparison.OrdinalIgnoreCase) ||
            (string.IsNullOrWhiteSpace(provider) && string.IsNullOrWhiteSpace(key) && !string.IsNullOrWhiteSpace(openRouterKey)))
        {
            options.Provider = JevProvider.OpenRouter;
            options.ApiKey = string.IsNullOrWhiteSpace(openRouterKey) ? null : openRouterKey;

            var orBaseUrl = Environment.GetEnvironmentVariable("OPENROUTER_BASE_URL");
            options.BaseUrl = string.IsNullOrWhiteSpace(orBaseUrl) ? OpenRouterDefaultBaseUrl : orBaseUrl;

            var orModel = Environment.GetEnvironmentVariable("OPENROUTER_MODEL");
            options.ModelId = string.IsNullOrWhiteSpace(orModel) ? OpenRouterDefaultModel : orModel;

            if (bool.TryParse(Environment.GetEnvironmentVariable("OPENROUTER_REASONING"), out var reasoning))
                options.ChatReasoning = reasoning;
        }

        // Groq: AI_PROVIDER=groq — chat model in JSON mode; thinking off by default (seconds faster per step)
        if (string.Equals(provider, "groq", StringComparison.OrdinalIgnoreCase))
        {
            options.Provider = JevProvider.Groq;
            var groqKey = Environment.GetEnvironmentVariable("GROQ_API_KEY");
            options.ApiKey = string.IsNullOrWhiteSpace(groqKey) ? null : groqKey;

            var groqUrl = Environment.GetEnvironmentVariable("GROQ_BASE_URL");
            options.BaseUrl = string.IsNullOrWhiteSpace(groqUrl) ? GroqDefaultBaseUrl : groqUrl;

            var groqModel = Environment.GetEnvironmentVariable("GROQ_MODEL");
            options.ModelId = string.IsNullOrWhiteSpace(groqModel) ? GroqDefaultModel : groqModel;

            options.ChatReasoning = bool.TryParse(Environment.GetEnvironmentVariable("GROQ_REASONING"), out var groqReasoning)
                ? groqReasoning
                : false;
        }

        // Laya: AI_PROVIDER=laya, served locally by `laya-serve`
        if (string.Equals(provider, "laya", StringComparison.OrdinalIgnoreCase))
        {
            options.Provider = JevProvider.Laya;
            var layaKey = Environment.GetEnvironmentVariable("LAYA_API_KEY");
            options.ApiKey = string.IsNullOrWhiteSpace(layaKey) ? null : layaKey;

            var layaUrl = Environment.GetEnvironmentVariable("LAYA_BASE_URL");
            options.BaseUrl = string.IsNullOrWhiteSpace(layaUrl) ? LayaDefaultBaseUrl : layaUrl;

            var layaModel = Environment.GetEnvironmentVariable("LAYA_MODEL");
            options.ModelId = string.IsNullOrWhiteSpace(layaModel) ? LayaDefaultModel : layaModel;

            if (int.TryParse(Environment.GetEnvironmentVariable("LAYA_MAX_LEN"), out var maxLen) && maxLen > 0)
                options.LayaMaxLen = maxLen;
            if (int.TryParse(Environment.GetEnvironmentVariable("LAYA_HEAD_MAX_LEN"), out var headMaxLen) && headMaxLen > 0)
                options.LayaHeadMaxLen = headMaxLen;

            // First request after server start may load the checkpoint
            options.TimeoutSeconds = 90;
        }

        if (bool.TryParse(Environment.GetEnvironmentVariable("ZERO_DATA_RETENTION"), out var zeroRetention))
            options.ZeroDataRetention = zeroRetention;

        if (double.TryParse(Environment.GetEnvironmentVariable("DECISION_CONFIDENCE_THRESHOLD"), out var conf))
            options.DecisionConfidenceThreshold = conf;

        if (double.TryParse(Environment.GetEnvironmentVariable("RISK_CONFIDENCE_THRESHOLD"), out var riskConf))
            options.RiskConfidenceThreshold = riskConf;

        return options;
    }
}
