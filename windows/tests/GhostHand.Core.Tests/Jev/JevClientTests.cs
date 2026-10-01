using System.Net;
using System.Net.Http;
using System.Text.Json;
using FluentAssertions;
using GhostHand.Core.Jev;
using GhostHand.Core.Models;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Moq.Protected;
using Xunit;

namespace GhostHand.Core.Tests.Jev;

public class JevClientTests
{
    private readonly JevOptions _options = new()
    {
        ApiKey = "vck_test_secret_key_12345678",
        BaseUrl = "https://ai-gateway.vercel.sh",
        ModelId = "typesafe-ai/jev",
        TimeoutSeconds = 5,
        MaxRetries = 2
    };

    [Fact]
    public void JV01_RequestJson_MatchesSchema()
    {
        var request = new EvaluateRequest
        {
            Model = "typesafe-ai/jev",
            State = new { goal = "search for Adele", app = "Spotify" },
            Questions = new Dictionary<string, QuestionDefinition>
            {
                ["done"] = QuestionDefinition.Boolean("Has task finished?"),
                ["action"] = QuestionDefinition.Choice(new Dictionary<string, string>
                {
                    ["click:e1"] = "Click search",
                    ["type:e2"] = "Type text"
                })
            },
            ProviderOptions = new GatewayProviderOptions
            {
                Gateway = new GatewayOptions { ZeroDataRetention = true }
            }
        };

        var json = JsonSerializer.Serialize(request, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });

        json.Should().Contain("\"model\":\"typesafe-ai/jev\"");
        json.Should().Contain("\"state\":{");
        json.Should().Contain("\"questions\":{");
        json.Should().Contain("\"type\":\"boolean\"");
        json.Should().Contain("\"type\":\"choice\"");
        json.Should().Contain("\"zeroDataRetention\":true");
    }

    [Fact]
    public void JV02_BooleanChoiceScore_AnswersParseCorrectly()
    {
        var jsonResponse = """
        {
            "answers": {
                "goalDone": {
                    "type": "boolean",
                    "probability": 0.88
                },
                "nextOp": {
                    "type": "choice",
                    "choice": "click:btn_search",
                    "probabilities": {
                        "click:btn_search": 0.91,
                        "press:enter": 0.09
                    }
                },
                "riskLevel": {
                    "type": "score",
                    "score": 1,
                    "probabilities": [0.10, 0.85, 0.05]
                }
            },
            "usage": {
                "promptTokens": 100,
                "completionTokens": 20,
                "totalTokens": 120
            },
            "providerMetadata": {
                "gateway": {
                    "cost": 0.000045,
                    "provider": "typesafe-ai"
                }
            }
        }
        """;

        var response = JsonSerializer.Deserialize<EvaluateResponse>(jsonResponse, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        response.Should().NotBeNull();

        // 1. Boolean
        response!.TryGetBooleanAnswer("goalDone", out var prob, out var isTrue).Should().BeTrue();
        prob.Should().Be(0.88);
        isTrue.Should().BeTrue();

        // 2. Choice
        response.TryGetChoiceAnswer("nextOp", out var choice, out var confidence, out var probs).Should().BeTrue();
        choice.Should().Be("click:btn_search");
        confidence.Should().Be(0.91);
        probs["press:enter"].Should().Be(0.09);

        // 3. Score
        response.TryGetScoreAnswer("riskLevel", out var score, out var scoreProbs).Should().BeTrue();
        score.Should().Be(1);
        scoreProbs.Should().HaveCount(3);
        scoreProbs[1].Should().Be(0.85);

        // Metadata
        response.Usage?.TotalTokens.Should().Be(120);
        response.ProviderMetadata?.Gateway?.Cost.Should().Be(0.000045);
    }

    [Fact]
    public async Task JV03_401Unauthorized_ThrowsAuthException_WithoutRetrying()
    {
        int callCount = 0;
        var handlerMock = new Mock<HttpMessageHandler>();
        handlerMock.Protected()
            .Setup<Task<HttpResponseMessage>>(
                "SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .ReturnsAsync(() =>
            {
                callCount++;
                return new HttpResponseMessage(HttpStatusCode.Unauthorized)
                {
                    Content = new StringContent("Invalid API key")
                };
            });

        using var httpClient = new HttpClient(handlerMock.Object);
        var client = new JevClient(httpClient, _options, NullLogger<JevClient>.Instance);

        var request = new EvaluateRequest
        {
            Model = "typesafe-ai/jev",
            State = new { },
            Questions = new Dictionary<string, QuestionDefinition>()
        };

        var act = () => client.EvaluateAsync(request);

        await act.Should().ThrowAsync<AuthException>()
            .Where(e => e.StatusCode == 401);

        // Must not retry on 401
        callCount.Should().Be(1);
    }

    [Fact]
    public async Task JV04_500InternalError_RetriesWithBackoff_ThenThrowsTransientException()
    {
        int callCount = 0;
        var handlerMock = new Mock<HttpMessageHandler>();
        handlerMock.Protected()
            .Setup<Task<HttpResponseMessage>>(
                "SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .ReturnsAsync(() =>
            {
                callCount++;
                return new HttpResponseMessage(HttpStatusCode.InternalServerError)
                {
                    Content = new StringContent("Internal server error")
                };
            });

        using var httpClient = new HttpClient(handlerMock.Object);
        var options = new JevOptions
        {
            ApiKey = "vck_secret",
            MaxRetries = 2
        };
        var client = new JevClient(httpClient, options, NullLogger<JevClient>.Instance);

        var request = new EvaluateRequest
        {
            Model = "typesafe-ai/jev",
            State = new { },
            Questions = new Dictionary<string, QuestionDefinition>()
        };

        var act = () => client.EvaluateAsync(request);

        await act.Should().ThrowAsync<TransientException>()
            .Where(e => e.StatusCode == 500);

        // Initial attempt + 2 retries = 3 attempts total
        callCount.Should().Be(3);
    }

    [Fact]
    public async Task JV05_Cancellation_IsHonouredPromptly()
    {
        var handlerMock = new Mock<HttpMessageHandler>();
        handlerMock.Protected()
            .Setup<Task<HttpResponseMessage>>(
                "SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .Returns<HttpRequestMessage, CancellationToken>(async (_, ct) =>
            {
                await Task.Delay(10000, ct);
                return new HttpResponseMessage(HttpStatusCode.OK);
            });

        using var httpClient = new HttpClient(handlerMock.Object);
        var client = new JevClient(httpClient, _options, NullLogger<JevClient>.Instance);

        using var cts = new CancellationTokenSource();
        cts.CancelAfter(50);

        var request = new EvaluateRequest
        {
            Model = "typesafe-ai/jev",
            State = new { },
            Questions = new Dictionary<string, QuestionDefinition>()
        };

        var act = () => client.EvaluateAsync(request, cts.Token);

        await act.Should().ThrowAsync<OperationCanceledException>();
    }

    [Fact]
    public void JV06_ApiKey_NeverAppearsInExceptionMessages()
    {
        var secret = "vck_live_secret_key_abcdef123456";
        var rawMessage = $"Bearer {secret} resulted in failure with key {secret}";

        var authEx = new AuthException(rawMessage, 401);
        authEx.Message.Should().NotContain(secret);
        authEx.Message.Should().Contain("[REDACTED]");

        var transEx = new TransientException(rawMessage, 500);
        transEx.Message.Should().NotContain(secret);
        transEx.Message.Should().Contain("[REDACTED]");
    }

    [Fact]
    public async Task JV07_MalformedJson_ThrowsProtocolException()
    {
        var handlerMock = new Mock<HttpMessageHandler>();
        handlerMock.Protected()
            .Setup<Task<HttpResponseMessage>>(
                "SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .ReturnsAsync(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("This is not valid JSON at all")
            });

        using var httpClient = new HttpClient(handlerMock.Object);
        var client = new JevClient(httpClient, _options, NullLogger<JevClient>.Instance);

        var request = new EvaluateRequest
        {
            Model = "typesafe-ai/jev",
            State = new { },
            Questions = new Dictionary<string, QuestionDefinition>()
        };

        var act = () => client.EvaluateAsync(request);

        await act.Should().ThrowAsync<ProtocolException>();
    }

    [Fact]
    public async Task JV08_ExecutesTopAction_EvenWithLowConfidence_WithoutThresholdBlock()
    {
        var clientMock = new Mock<IJevClient>();

        // Mock response with top choice having 0.45 probability across multiple choices
        var mockResponseJson = """
        {
            "answers": {
                "nextAction": {
                    "type": "choice",
                    "choice": "click:btn1",
                    "probabilities": {
                        "click:btn1": 0.45,
                        "press:enter": 0.35,
                        "done": 0.20
                    }
                },
                "goalAchieved": {
                    "type": "boolean",
                    "probability": 0.10
                }
            }
        }
        """;
        var mockResponse = JsonSerializer.Deserialize<EvaluateResponse>(mockResponseJson)!;

        clientMock.Setup(c => c.EvaluateAsync(It.IsAny<EvaluateRequest>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(mockResponse);

        var model = new JevDecisionModel(clientMock.Object, _options, NullLogger<JevDecisionModel>.Instance);

        var target = new AppTarget
        {
            ProcessId = 1234,
            ProcessName = "Notepad",
            WindowTitle = "Untitled"
        };
        var elements = new List<AccessibilityElement>
        {
            new() { Id = "btn1", Role = "Button", Label = "Search" }
        };

        var decision = await model.DecideNextActionAsync("Search for test", target, elements, Array.Empty<string>());

        decision.Operation.Should().Be(AgentOperation.Click);
        decision.TargetId.Should().Be("btn1");
        decision.TargetLabel.Should().Be("Search");
    }
}
