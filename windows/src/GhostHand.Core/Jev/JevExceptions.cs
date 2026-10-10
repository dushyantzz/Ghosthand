namespace GhostHand.Core.Jev;

public abstract class JevException : Exception
{
    protected JevException(string message, Exception? innerException = null) 
        : base(Sanitize(message), innerException)
    {
    }

    protected static string Sanitize(string message)
    {
        // Redact any potential API key patterns (vck_..., bearer tokens, etc.)
        if (string.IsNullOrEmpty(message)) return message;

        var sanitized = System.Text.RegularExpressions.Regex.Replace(
            message,
            @"(?i)(bearer\s+)([a-zA-Z0-9_\-\.]{8,})",
            "$1[REDACTED]");

        sanitized = System.Text.RegularExpressions.Regex.Replace(
            sanitized,
            @"(vck_[a-zA-Z0-9_\-]{8,})",
            "[REDACTED]");

        sanitized = System.Text.RegularExpressions.Regex.Replace(
            sanitized,
            @"(sk-or-[a-zA-Z0-9_\-]{8,})",
            "[REDACTED]");

        return sanitized;
    }
}

public class AuthException : JevException
{
    public int StatusCode { get; }

    public AuthException(string message, int statusCode = 401, Exception? inner = null) 
        : base($"Authentication failed (HTTP {statusCode}): {message}", inner)
    {
        StatusCode = statusCode;
    }
}

public class TransientException : JevException
{
    public int StatusCode { get; }

    public TransientException(string message, int statusCode, Exception? inner = null) 
        : base($"Transient gateway error (HTTP {statusCode}): {message}", inner)
    {
        StatusCode = statusCode;
    }
}

public class ProtocolException : JevException
{
    public ProtocolException(string message, Exception? inner = null) 
        : base($"Protocol / serialization error: {message}", inner)
    {
    }
}
