using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace GhostHand.Core.Jev;

public static class JevClientFactory
{
    /// <summary>Creates the decision-model client for the provider selected in <see cref="JevOptions.Provider"/>.</summary>
    public static IJevClient Create(HttpClient httpClient, JevOptions options, ILoggerFactory? loggerFactory = null)
    {
        loggerFactory ??= NullLoggerFactory.Instance;
        // Laya speaks the same typed-decisions format as Jev on OpenRouter, so it shares that client
        return options.Provider is JevProvider.OpenRouter or JevProvider.Laya or JevProvider.Groq
            ? new OpenRouterJevClient(httpClient, options, loggerFactory.CreateLogger<OpenRouterJevClient>())
            : new JevClient(httpClient, options, loggerFactory.CreateLogger<JevClient>());
    }
}
