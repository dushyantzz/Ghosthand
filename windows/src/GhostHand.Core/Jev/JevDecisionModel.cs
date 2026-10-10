using System.Text.RegularExpressions;
using GhostHand.Core.Agent;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using GhostHand.Core.Safety;
using Microsoft.Extensions.Logging;

namespace GhostHand.Core.Jev;

public class JevDecisionModel : IDecisionModel
{
    private readonly IJevClient _jevClient;
    private readonly JevOptions _options;
    private readonly ILogger<JevDecisionModel> _logger;

    public JevDecisionModel(IJevClient jevClient, JevOptions options, ILogger<JevDecisionModel> logger)
    {
        _jevClient = jevClient;
        _options = options;
        _logger = logger;
    }

    public async Task<AgentDecision> DecideNextActionAsync(
        string goal,
        AppTarget target,
        IReadOnlyList<AccessibilityElement> elements,
        IReadOnlyList<string> history,
        CancellationToken cancellationToken = default)
    {
        // 0. Calculations are checked exactly: once the expression was typed and the app shows its value, done
        var expression = ExtractMathExpression(goal);
        var expected = expression != null ? EvaluateExpression(expression) : null;
        if (expected != null &&
            history.Any(h => h.StartsWith($"{AgentOperation.TypeKeys}:", StringComparison.OrdinalIgnoreCase)) &&
            ScreenShowsNumber(elements, expected.Value))
        {
            return new AgentDecision
            {
                Operation = AgentOperation.Done,
                Reason = $"Calculation result {FormatNumber(expected.Value)} is shown",
                Confidence = 1.0
            };
        }

        // 1. Build candidate action choices deterministically
        var candidateChoices = BuildCandidateChoices(goal, target, elements, history);

        // 2. Build compact state object (text-only, no secrets)
        var state = new
        {
            task = Truncate(goal, 4000),
            app = Truncate(target.ProcessName, 100),
            window = Truncate(target.WindowTitle, 150),
            step = history.Count + 1,
            actionAttempts = history.Count > 0 ? history.TakeLast(8).ToList() : new List<string> { "nothing yet" },
            elementCount = elements.Count,
            mediaStatus = DescribeMediaStatus(elements),
            expectedCalculationResult = expected != null ? FormatNumber(expected.Value) : null,
            elements = elements.Take(40).Select(e => new
            {
                id = e.Id,
                role = e.DisplayRole,
                label = Truncate(e.DisplayLabel, 160),
                enabled = e.Enabled,
                focused = e.Focused,
                source = e.Source
            }).ToList()
        };

        // 3. Build questions: Call A
        var questions = new Dictionary<string, QuestionDefinition>
        {
            ["nextAction"] = QuestionDefinition.Choice(
                candidateChoices,
                $"Select the single best next action to advance toward: \"{goal}\""),
            ["goalAchieved"] = QuestionDefinition.Boolean(
                $"Has the user's task \"{goal}\" already been completely fulfilled by the current screen state? {CompletionHint}")
        };

        var request = new EvaluateRequest
        {
            Model = _options.ModelId,
            State = state,
            Questions = questions,
            ProviderOptions = new GatewayProviderOptions
            {
                Gateway = new GatewayOptions
                {
                    ZeroDataRetention = _options.ZeroDataRetention ? true : null,
                    Only = new List<string> { "typesafe-ai" }
                }
            }
        };

        var response = await _jevClient.EvaluateAsync(request, cancellationToken);

        // Check if goal is already completed
        if (!JustFailedDone(history) &&
            response.TryGetBooleanAnswer("goalAchieved", out var goalProb, out var isAchieved) && isAchieved)
        {
            return new AgentDecision
            {
                Operation = AgentOperation.Done,
                Reason = $"Goal achieved (confidence: {goalProb:P0})",
                Confidence = goalProb
            };
        }

        // Parse next action choice
        if (!response.TryGetChoiceAnswer("nextAction", out var chosenKey, out var confidence, out var probabilities))
        {
            _logger.LogWarning("Failed to parse nextAction choice from Jev response. Asking user.");
            return new AgentDecision { Operation = AgentOperation.AskUser, Reason = "Could not parse decision" };
        }

        // Execute chosen action directly as decided by the Jev model
        _logger.LogInformation("Jev selected action: '{Choice}' (probability: {Conf:P0})", chosenKey, confidence);
        return ParseActionDecision(chosenKey, confidence, elements);
    }

    public async Task<bool> VerifyCompletionAsync(
        string goal,
        AppTarget target,
        IReadOnlyList<AccessibilityElement> elements,
        IReadOnlyList<string> history,
        CancellationToken cancellationToken = default)
    {
        var state = new
        {
            task = Truncate(goal, 4000),
            app = Truncate(target.ProcessName, 100),
            window = Truncate(target.WindowTitle, 150),
            actionAttempts = history.TakeLast(6).ToList(),
            mediaStatus = DescribeMediaStatus(elements),
            visibleControls = elements.Take(30).Select(e => $"{e.DisplayRole}: \"{e.DisplayLabel}\"").ToList()
        };

        var request = new EvaluateRequest
        {
            Model = _options.ModelId,
            State = state,
            Questions = new Dictionary<string, QuestionDefinition>
            {
                ["done"] = QuestionDefinition.Boolean(
                    $"Are ALL requirements of the task \"{goal}\" completely satisfied based on visible controls and recorded actions? {CompletionHint}")
            },
            ProviderOptions = new GatewayProviderOptions
            {
                Gateway = new GatewayOptions { ZeroDataRetention = _options.ZeroDataRetention ? true : null }
            }
        };

        var response = await _jevClient.EvaluateAsync(request, cancellationToken);
        if (response.TryGetBooleanAnswer("done", out var prob, out var isDone))
        {
            return isDone;
        }

        return false;
    }

    public async Task<ActionRiskScore> EvaluateActionRiskAsync(
        string goal,
        AppTarget target,
        AgentDecision decision,
        AccessibilityElement? targetElement,
        CancellationToken cancellationToken = default)
    {
        // Benign agent control flow actions are harmless
        if (decision.Operation is AgentOperation.Done or AgentOperation.AskUser or AgentOperation.Wait)
        {
            return ActionRiskScore.Harmless;
        }

        var state = new
        {
            task = Truncate(goal, 4000),
            app = Truncate(target.ProcessName, 100),
            window = Truncate(target.WindowTitle, 150),
            proposedAction = new
            {
                operation = decision.Operation.ToString(),
                targetId = decision.TargetId,
                targetRole = targetElement?.DisplayRole ?? "Unknown",
                targetLabel = Truncate(targetElement?.DisplayLabel ?? decision.TargetLabel ?? "None", 200),
                textValue = decision.TextValue != null ? Truncate(decision.TextValue, 100) : null
            }
        };

        var request = new EvaluateRequest
        {
            Model = _options.ModelId,
            State = state,
            Questions = new Dictionary<string, QuestionDefinition>
            {
                ["actionRisk"] = QuestionDefinition.Score(
                    new List<string> { "harmless", "reversible edit", "irreversible or external effect" },
                    "Rate the risk of this proposed user-interface action from lowest (harmless UI navigation) to highest (irreversible external effect, submission, payment, deletion, or external data transmission).")
            },
            ProviderOptions = new GatewayProviderOptions
            {
                Gateway = new GatewayOptions { ZeroDataRetention = _options.ZeroDataRetention ? true : null }
            }
        };

        try
        {
            var response = await _jevClient.EvaluateAsync(request, cancellationToken);
            if (response.TryGetScoreAnswer("actionRisk", out var score, out var probabilities))
            {
                _logger.LogInformation("Jev evaluated action risk: Score {Score}, probabilities: [{Probs}]",
                    score, string.Join(", ", probabilities.Select(p => $"{p:P0}")));

                if (score >= 3 || (score == 2 && probabilities.Count == 3 && probabilities[2] >= 0.5))
                {
                    return ActionRiskScore.IrreversibleOrExternalEffect;
                }
                else if (score == 2 || score == 1)
                {
                    return ActionRiskScore.ReversibleEdit;
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to evaluate action risk via Jev. Defaulting to ReversibleEdit.");
            return ActionRiskScore.ReversibleEdit;
        }

        return ActionRiskScore.Harmless;
    }

    /// <summary>
    /// Buttons whose second press repeats a real-world effect (a second photo, a second message or order)
    /// are offered only once per task.
    /// </summary>
    private static bool IsOneShot(string? label) =>
        Regex.IsMatch(label ?? string.Empty,
            @"^(?:take (?:a )?(?:photo|picture|video)|capture|shutter|start recording|send|post|submit|publish|pay|buy|place order|call)\b",
            RegexOptions.IgnoreCase);

    private static bool JustFailedDone(IReadOnlyList<string> history) =>
        history.Count > 0 && history[^1].StartsWith($"{AgentOperation.Done}:", StringComparison.OrdinalIgnoreCase);

    private const string CompletionHint =
        "For play/listen tasks: if mediaStatus says something is playing (a Pause control is visible), the task is done — do not search again.";

    /// <summary>A visible "Pause" control is the standard signal that media is currently playing.</summary>
    private static string DescribeMediaStatus(IReadOnlyList<AccessibilityElement> elements)
    {
        var pause = elements.FirstOrDefault(e =>
            Regex.IsMatch(e.DisplayLabel ?? string.Empty, @"^pause\b", RegexOptions.IgnoreCase));
        if (pause != null)
            return $"PLAYING (a \"{pause.DisplayLabel}\" control is visible)";

        var play = elements.FirstOrDefault(e =>
            Regex.IsMatch(e.DisplayLabel ?? string.Empty, @"^(?:play|resume)\b", RegexOptions.IgnoreCase));
        return play != null ? $"not playing (a \"{play.DisplayLabel}\" control is visible)" : "unknown";
    }

    private static Dictionary<string, string> BuildCandidateChoices(string goal, AppTarget target, IReadOnlyList<AccessibilityElement> elements, IReadOnlyList<string> history)
    {
        var choices = new Dictionary<string, string>();

        // Repeat guard: the model can re-pick an action that "succeeded" without visibly changing
        // anything (re-typing the same search, re-launching an app) forever. Drop an action once it
        // has been done twice on the same control; media toggles only once, since a second press pauses.
        bool AlreadyTried(AgentOperation op, string target, int limit = 2) =>
            history.Count(h => h.StartsWith($"{op}:{target} ", StringComparison.OrdinalIgnoreCase)) >= limit;
        bool AlreadyDoneOn(AgentOperation op, string? label, int limit = 2) =>
            history.Count(h => h.StartsWith($"{op}:", StringComparison.OrdinalIgnoreCase) &&
                               h.Contains($" ({label ?? string.Empty}) ->", StringComparison.OrdinalIgnoreCase)) >= limit;

        // 0. App Launch & URL candidates
        var appCandidates = ExtractAppLaunchCandidates(goal);
        foreach (var app in appCandidates)
        {
            if (AlreadyTried(AgentOperation.OpenApp, app)) continue;
            choices[$"open_app:{app}"] = $"Launch or switch to application \"{app}\"";
        }

        // Synthesized search URLs follow the app the user is in ("play X" while in Spotify → Spotify, not YouTube).
        // Inside the Spotify desktop app a web URL would only open a browser, so use the in-app search instead.
        var inSpotifyDesktop = target.ProcessName.Equals("spotify", StringComparison.OrdinalIgnoreCase);
        var urlCandidates = inSpotifyDesktop && !goal.Contains("http", StringComparison.OrdinalIgnoreCase)
            ? Array.Empty<Uri>()
            : UrlLauncherValidator.ExtractWebUrls(goal, $"{target.ProcessName} {target.WindowTitle}");
        foreach (var url in urlCandidates)
        {
            if (AlreadyTried(AgentOperation.OpenUrl, url.ToString())) continue;
            choices[$"open_url:{url}"] = $"Open web URL \"{url}\" in browser";
        }

        // Extract search/literal candidate phrases from user goal
        var textCandidates = ExtractCandidatePhrases(goal);

        // For "play X" tasks: clicking Pause undoes the goal, and once any play/pause toggle has been
        // used, a further Space/Play key press would pause what just started.
        var isPlayTask = Regex.IsMatch(goal, @"\b(?:play|listen|stream)\b", RegexOptions.IgnoreCase);
        var toggledPlayback = history.Any(h =>
            h.StartsWith($"{AgentOperation.PressSpace}:", StringComparison.OrdinalIgnoreCase) ||
            h.StartsWith($"{AgentOperation.PressMediaPlay}:", StringComparison.OrdinalIgnoreCase) ||
            Regex.IsMatch(h, @"^Click:\S* \((?:play|pause|resume)\b", RegexOptions.IgnoreCase));

        // Calculations are typed in one go (keys: option below). Clicking keypad buttons as well mixes the two
        // inputs: "Three", "Four", then typing "3+4" made Calculator compute 343+4
        var mathExpression = ExtractMathExpression(goal);
        var keysTries = history.Count(h => h.StartsWith($"{AgentOperation.TypeKeys}:", StringComparison.OrdinalIgnoreCase));
        var hideKeypad = mathExpression != null && keysTries < 2;

        int clickCount = 0;
        foreach (var el in elements)
        {
            if (!el.Enabled) continue;
            if (hideKeypad && IsKeypadButton(el)) continue;
            if (isPlayTask && Regex.IsMatch(el.DisplayLabel ?? string.Empty, @"^pause\b", RegexOptions.IgnoreCase)) continue;

            if (IsClickable(el.Role) && clickCount < 25 &&
                !AlreadyDoneOn(AgentOperation.Click, el.DisplayLabel, limit: IsOneShot(el.DisplayLabel) ? 1 : 2))
            {
                clickCount++;
                var key = $"click:{el.Id}";
                var desc = $"Click {el.DisplayRole} \"{el.DisplayLabel}\"";
                choices[key] = desc;
            }

            var typedHere = AlreadyDoneOn(AgentOperation.TypeAndEnter, el.DisplayLabel) || AlreadyDoneOn(AgentOperation.TypeText, el.DisplayLabel);
            if (IsTypeable(el.Role) && textCandidates.Count > 0 && !typedHere)
            {
                foreach (var textCandidate in textCandidates.Take(3))
                {
                    // If element already contains this exact text, avoid looping!
                    if (!string.IsNullOrEmpty(el.Value) && el.Value.Contains(textCandidate, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    var keyEnter = $"type_and_enter:{el.Id}:{textCandidate}";
                    var descEnter = $"Type \"{textCandidate}\" into {el.DisplayRole} \"{el.DisplayLabel}\" and press Enter";
                    choices[keyEnter] = descEnter;

                    var key = $"type:{el.Id}:{textCandidate}";
                    var desc = $"Type \"{textCandidate}\" into {el.DisplayRole} \"{el.DisplayLabel}\"";
                    choices[key] = desc;
                }
            }
        }

        // Keyboard entry for a calculation ("do 450 + 40", "what is 12 times 8"): apps like Calculator have
        // no text box to type into, and clicking digit buttons one step at a time is slow and error-prone
        if (mathExpression != null && keysTries < 2)
        {
            choices[$"keys:{mathExpression}"] = $"Clear, type \"{mathExpression}\" on the keyboard and press Enter (enters the whole calculation into the focused app)";
        }

        // Standard actions
        choices["press:enter"] = "Press Enter/Return key";
        if (!toggledPlayback)
        {
            choices["press:space"] = "Press Spacebar to play/pause or select";
            choices["press:media_play"] = "Press Media Play key to toggle playback";
        }
        choices["press:tab"] = "Press Tab key to advance focus";
        choices["press:escape"] = "Press Escape key to dismiss dialog/menu";
        // Three scrolls in a row that changed nothing useful: stop offering scrolling
        var recentScrolls = history.TakeLast(3).Count(h =>
            h.StartsWith($"{AgentOperation.ScrollDown}:", StringComparison.OrdinalIgnoreCase) ||
            h.StartsWith($"{AgentOperation.ScrollUp}:", StringComparison.OrdinalIgnoreCase));
        if (recentScrolls < 3)
        {
            choices["scroll:down"] = "Scroll down to reveal more controls";
            choices["scroll:up"] = "Scroll up";
        }
        choices["wait"] = "Wait 1 second for UI to update";
        // Right after a "done" that failed verification, force a real action instead of claiming done again
        if (!JustFailedDone(history))
            choices["done"] = "Task is completely finished";
        choices["ask_user"] = "Need human guidance or clarification";

        return choices;
    }

    private static AgentDecision ParseActionDecision(string key, double confidence, IReadOnlyList<AccessibilityElement> elements)
    {
        if (key.StartsWith("keys:", StringComparison.OrdinalIgnoreCase))
        {
            var keys = key[5..];
            return new AgentDecision
            {
                Operation = AgentOperation.TypeKeys,
                TextValue = keys,
                Confidence = confidence,
                Reason = $"Type '{keys}' on the keyboard"
            };
        }

        if (key.StartsWith("open_app:", StringComparison.OrdinalIgnoreCase))
        {
            var appName = key[9..].Trim();
            return new AgentDecision
            {
                Operation = AgentOperation.OpenApp,
                TargetId = appName,
                TargetLabel = appName,
                Confidence = confidence,
                Reason = $"Launch application '{appName}'"
            };
        }

        if (key.StartsWith("open_url:", StringComparison.OrdinalIgnoreCase))
        {
            var url = key[9..].Trim();
            return new AgentDecision
            {
                Operation = AgentOperation.OpenUrl,
                TargetId = url,
                TargetLabel = url,
                TextValue = url,
                Confidence = confidence,
                Reason = $"Open web URL '{url}'"
            };
        }

        if (key.StartsWith("click:", StringComparison.OrdinalIgnoreCase))
        {
            var elementId = key[6..];
            var el = elements.FirstOrDefault(e => e.Id == elementId);
            return new AgentDecision
            {
                Operation = AgentOperation.Click,
                TargetId = elementId,
                TargetLabel = el?.DisplayLabel,
                Confidence = confidence,
                Reason = $"Click element {elementId}"
            };
        }

        if (key.StartsWith("type_and_enter:", StringComparison.OrdinalIgnoreCase))
        {
            var parts = key.Split(':', 3);
            var elementId = parts.Length > 1 ? parts[1] : string.Empty;
            var text = parts.Length > 2 ? parts[2] : string.Empty;
            var el = elements.FirstOrDefault(e => e.Id == elementId);

            return new AgentDecision
            {
                Operation = AgentOperation.TypeAndEnter,
                TargetId = elementId,
                TargetLabel = el?.DisplayLabel,
                TextValue = text,
                Confidence = confidence,
                Reason = $"Type '{text}' into {elementId} and press Enter"
            };
        }

        if (key.StartsWith("type:", StringComparison.OrdinalIgnoreCase))
        {
            var parts = key.Split(':', 3);
            var elementId = parts.Length > 1 ? parts[1] : string.Empty;
            var text = parts.Length > 2 ? parts[2] : string.Empty;
            var el = elements.FirstOrDefault(e => e.Id == elementId);

            return new AgentDecision
            {
                Operation = AgentOperation.TypeText,
                TargetId = elementId,
                TargetLabel = el?.DisplayLabel,
                TextValue = text,
                Confidence = confidence,
                Reason = $"Type '{text}' into {elementId}"
            };
        }

        return key.ToLowerInvariant() switch
        {
            "press:enter" => new AgentDecision { Operation = AgentOperation.PressReturn, Confidence = confidence },
            "press:space" => new AgentDecision { Operation = AgentOperation.PressSpace, Confidence = confidence },
            "press:media_play" => new AgentDecision { Operation = AgentOperation.PressMediaPlay, Confidence = confidence },
            "press:tab" => new AgentDecision { Operation = AgentOperation.PressTab, Confidence = confidence },
            "press:escape" => new AgentDecision { Operation = AgentOperation.PressEscape, Confidence = confidence },
            "scroll:down" => new AgentDecision { Operation = AgentOperation.ScrollDown, Confidence = confidence },
            "scroll:up" => new AgentDecision { Operation = AgentOperation.ScrollUp, Confidence = confidence },
            "wait" => new AgentDecision { Operation = AgentOperation.Wait, Confidence = confidence },
            "done" => new AgentDecision { Operation = AgentOperation.Done, Confidence = confidence },
            _ => new AgentDecision { Operation = AgentOperation.AskUser, Confidence = confidence }
        };
    }

    private static bool IsClickable(string role) =>
        role.Equals("Button", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("MenuItem", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("TabItem", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("Hyperlink", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("CheckBox", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("RadioButton", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("ComboBox", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("ListItem", StringComparison.OrdinalIgnoreCase);

    private static bool IsTypeable(string role) =>
        role.Equals("Edit", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("Document", StringComparison.OrdinalIgnoreCase) ||
        role.Equals("ComboBox", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The arithmetic in a goal as keyboard input: "do 450 + 40" → "450+40", "what is 12 times 8" → "12*8",
    /// "100 divided by 4" → "100/4". Null when the goal contains no calculation.
    /// </summary>
    public static string? ExtractMathExpression(string goal)
    {
        if (string.IsNullOrWhiteSpace(goal)) return null;

        var text = goal.ToLowerInvariant();
        text = Regex.Replace(text, @"\bmultiplied\s+by\b|\btimes\b|\binto\b|[x×]\s*(?=\d)", " * ");
        text = Regex.Replace(text, @"\bdivided\s+by\b|÷|\bover\b", " / ");
        text = Regex.Replace(text, @"\bplus\b|\band\s+add\b", " + ");
        text = Regex.Replace(text, @"\bminus\b", " - ");
        text = Regex.Replace(text, @"(?<=\d),(?=\d{3}\b)", ""); // 1,200 → 1200

        var match = Regex.Match(text, @"\(?\s*\d+(?:\.\d+)?(?:\s*\)?\s*[-+*/%]\s*\(?\s*\d+(?:\.\d+)?\s*\)?)+");
        if (!match.Success) return null;

        var expression = Regex.Replace(match.Value, @"\s+", "");
        return Regex.IsMatch(expression, @"[-+*/%]") ? expression : null;
    }

    private static readonly Regex KeypadLabel = new(
        @"^(?:zero|one|two|three|four|five|six|seven|eight|nine|plus|minus|multiply by|divide by|equals|decimal separator|positive negative|percent|[0-9]|[-+*/=.×÷])$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static bool IsKeypadButton(AccessibilityElement el) =>
        el.Role.Equals("Button", StringComparison.OrdinalIgnoreCase) && KeypadLabel.IsMatch((el.DisplayLabel ?? string.Empty).Trim());

    /// <summary>Value of a simple expression ("450*2+90" → 990), or null if it can't be evaluated.</summary>
    public static decimal? EvaluateExpression(string expression)
    {
        try
        {
            var value = new System.Data.DataTable().Compute(expression.Replace("%", "/100*"), null);
            return value is DBNull or null ? null : Convert.ToDecimal(value, System.Globalization.CultureInfo.InvariantCulture);
        }
        catch
        {
            return null;
        }
    }

    private static string FormatNumber(decimal value) =>
        Math.Round(value, 10).ToString("0.##########", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>Whether a text on screen shows this number ("Display is 1,234", "990"), ignoring thousands separators.</summary>
    private static bool ScreenShowsNumber(IReadOnlyList<AccessibilityElement> elements, decimal value)
    {
        var target = Math.Round(value, 6);
        foreach (var el in elements)
        {
            if (el.Role.Equals("Button", StringComparison.OrdinalIgnoreCase)) continue;
            var text = $"{el.Label} {el.Value}";
            foreach (Match m in Regex.Matches(text, @"-?\d[\d,\s]*(?:\.\d+)?"))
            {
                var digits = Regex.Replace(m.Value, @"[,\s]", "");
                if (decimal.TryParse(digits, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var shown) &&
                    Math.Round(shown, 6) == target)
                    return true;
            }
        }
        return false;
    }

    public static List<string> ExtractCandidatePhrases(string goal)
    {
        var candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // Speech-to-text punctuation ("write, hello", "search: weather") would hide the text from the verbs below
        goal = Regex.Replace(goal, @"\b(write|type|enter|insert|put|search|find|play|stream|calculate|compute)\s*[,:]\s*", "$1 ", RegexOptions.IgnoreCase);

        // 1. Quoted text: "Adele", 'Hello World'
        foreach (Match m in Regex.Matches(goal, @"[""']([^""']+)[""']"))
        {
            var val = m.Groups[1].Value.Trim();
            if (!string.IsNullOrEmpty(val)) candidates.Add(val);
        }

        // 2. Action verbs with target hints: "write/type/enter/insert/put <text> in/into/there/..."
        var writeMatch = Regex.Match(goal, @"(?:write|type|enter|insert|put)\s+(?:the\s+text\s+)?(?:[""']?)(.+?)(?:[""']?)(?:\s+(?:in|into|there|here|on|to)\b|$|\.)", RegexOptions.IgnoreCase);
        if (writeMatch.Success)
        {
            var val = writeMatch.Groups[1].Value.Trim();
            val = Regex.Replace(val, @"\s+(?:in|into|to|on)\s+(?:notepad|document|file|editor|app|browser|search|bar|box).*$", "", RegexOptions.IgnoreCase).Trim();
            if (!string.IsNullOrEmpty(val) && !val.Equals("there", StringComparison.OrdinalIgnoreCase))
                candidates.Add(val);
        }

        // 3. Search queries: "search/look up/find/google/query [for/about/on] <text>"
        var searchMatches = Regex.Matches(
            goal,
            @"(?:search|look\s+up|find|google|query)(?:\s+(?:for|about|on|regarding|the\s+web\s+for))?\s+(?:[""']?)(.+?)(?:[""']?)(?:\s+(?:on|in|using|with)\s+[a-zA-Z0-9_\-]+|\.|$|\band\b)",
            RegexOptions.IgnoreCase);
        foreach (Match m in searchMatches)
        {
            var val = m.Groups[1].Value.Trim();
            val = Regex.Replace(val, @"^(?:for|about|on)\s+", "", RegexOptions.IgnoreCase).Trim();
            if (!string.IsNullOrEmpty(val))
                candidates.Add(val);
        }

        // 4. Play / Listen / Stream queries: "play/listen to [any song of/by/music by] <text>"
        var playMatches = Regex.Matches(
            goal,
            @"(?:play|listen\s+to|stream)(?:\s+(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|tracks?\s+(?:of|by)))?\s+(?:[""']?)(.+?)(?:[""']?)(?:\s+(?:on|in|using|with)\s+[a-zA-Z0-9_\-]+|\.|$|\band\b)",
            RegexOptions.IgnoreCase);
        foreach (Match m in playMatches)
        {
            var val = m.Groups[1].Value.Trim();
            val = Regex.Replace(val, @"^(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|track\s+(?:of|by))\s+", "", RegexOptions.IgnoreCase).Trim();
            if (!string.IsNullOrEmpty(val))
                candidates.Add(val);
        }

        // 5. Calculations: "calculate/compute <expression>"
        var calcMatch = Regex.Match(goal, @"(?:calculate|calc|compute)\s+(.+)$", RegexOptions.IgnoreCase);
        if (calcMatch.Success)
        {
            var val = calcMatch.Groups[1].Value.Trim();
            if (!string.IsNullOrEmpty(val)) candidates.Add(val);
        }

        // 6. Fallback: If no candidate extracted yet, see if goal is a direct short phrase
        if (candidates.Count == 0 && !goal.StartsWith("click", StringComparison.OrdinalIgnoreCase) && !goal.StartsWith("scroll", StringComparison.OrdinalIgnoreCase))
        {
            var cleaned = Regex.Replace(goal, @"^(?:please\s+|can\s+you\s+|i\s+want\s+to\s+)", "", RegexOptions.IgnoreCase).Trim();
            if (cleaned.Length > 0 && cleaned.Length <= 40)
            {
                candidates.Add(cleaned);
            }
        }

        return candidates.ToList();
    }

    public static List<string> ExtractAppLaunchCandidates(string goal)
    {
        var candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(goal)) return candidates.ToList();

        // Extract app name dynamically from user goal intent:
        // e.g. "open notepad", "launch vlc", "start calculator", "switch to discord", "go to chrome"
        var match = Regex.Match(
            goal,
            @"(?:open|launch|start|run|switch\s+to|go\s+to|focus)\s+(?:the\s+app\s+)?([a-zA-Z0-9\-_ ]+?)(?:\s+(?:and|to|then|in|with)\b|$|\.)",
            RegexOptions.IgnoreCase);

        if (match.Success)
        {
            var app = NormalizeAppName(match.Groups[1].Value);
            string[] stopWords = ["menu", "tab", "link", "window", "dialog", "document", "file", "page", "browser", "app", "application"];
            if (!stopWords.Contains(app, StringComparer.OrdinalIgnoreCase) && app.Length > 0)
            {
                candidates.Add(app);
            }
        }

        // Well-known apps named anywhere in the goal ("play X on spotify") are also launch candidates
        foreach (Match m in Regex.Matches(goal, @"\b(?:on|in|using|with)\s+([a-zA-Z0-9\-_]+)", RegexOptions.IgnoreCase))
        {
            var app = NormalizeAppName(m.Groups[1].Value);
            if (KnownApps.Contains(app))
                candidates.Add(app);
        }

        return candidates.ToList();
    }

    private static readonly HashSet<string> KnownApps = new(StringComparer.OrdinalIgnoreCase)
    {
        "spotify", "chrome", "msedge", "firefox", "brave", "opera", "notepad", "calculator",
        "discord", "slack", "teams", "whatsapp", "telegram", "vlc", "outlook", "word", "excel", "powerpoint"
    };

    // Common spoken names / misspellings → launchable app names
    private static readonly Dictionary<string, string> AppAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["crome"] = "chrome",
        ["chrom"] = "chrome",
        ["chorme"] = "chrome",
        ["google chrome"] = "chrome",
        ["edge"] = "msedge",
        ["microsoft edge"] = "msedge",
        ["mozilla firefox"] = "firefox",
        ["fire fox"] = "firefox",
        ["spotfy"] = "spotify",
        ["spotify music"] = "spotify",
        ["calc"] = "calculator",
        ["vs code"] = "visual studio code",
        ["vscode"] = "visual studio code",
        ["note pad"] = "notepad"
    };

    /// <summary>"the crome browser" → "chrome": drops articles and generic suffixes, then applies aliases.</summary>
    private static string NormalizeAppName(string raw)
    {
        var app = raw.Trim();
        app = Regex.Replace(app, @"^(?:the|a|an|my)\s+", "", RegexOptions.IgnoreCase).Trim();
        var stripped = Regex.Replace(app, @"\s+(?:browser|app|application|program)$", "", RegexOptions.IgnoreCase).Trim();
        if (stripped.Length > 0)
            app = stripped;
        return AppAliases.TryGetValue(app, out var alias) ? alias : app;
    }

    private static string Truncate(string text, int maxChars)
    {
        if (string.IsNullOrEmpty(text) || text.Length <= maxChars) return text;
        return text[..maxChars];
    }
}
