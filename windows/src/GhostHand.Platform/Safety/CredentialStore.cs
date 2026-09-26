using System.Runtime.InteropServices;
using System.Text;
using GhostHand.Core.Interfaces;
using Microsoft.Extensions.Logging;

namespace GhostHand.Platform.Safety;

public class CredentialStore : ICredentialStore
{
    private const string TargetName = "GhostHand/AI_GATEWAY_API_KEY";
    private const int CRED_TYPE_GENERIC = 1;
    private const int CRED_PERSIST_LOCAL_MACHINE = 2;

    private readonly ILogger<CredentialStore> _logger;

    public CredentialStore(ILogger<CredentialStore>? logger = null)
    {
        _logger = logger ?? Microsoft.Extensions.Logging.Abstractions.NullLogger<CredentialStore>.Instance;
    }

    public string? GetApiKey()
    {
        // 1. Env var takes precedence
        var envKey = Environment.GetEnvironmentVariable("AI_GATEWAY_API_KEY");
        if (!string.IsNullOrWhiteSpace(envKey))
        {
            return envKey.Trim();
        }

        // 2. Windows Credential Manager
        return ReadCredential(TargetName);
    }

    public bool HasKey()
    {
        var key = GetApiKey();
        return !string.IsNullOrWhiteSpace(key);
    }

    public void SetApiKey(string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            throw new ArgumentException("API key cannot be empty", nameof(apiKey));
        }

        WriteCredential(TargetName, apiKey.Trim());
    }

    public void DeleteApiKey()
    {
        DeleteCredential(TargetName);
    }

    private string? ReadCredential(string target)
    {
        try
        {
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out var credPtr))
            {
                return null;
            }

            try
            {
                var cred = Marshal.PtrToStructure<CREDENTIAL>(credPtr);
                if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0)
                {
                    return null;
                }

                var bytes = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
                
                var result = Encoding.UTF8.GetString(bytes);
                return result;
            }
            finally
            {
                CredFree(credPtr);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read credential for target {Target}", target);
            return null;
        }
    }

    private void WriteCredential(string target, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var blobPtr = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blobPtr, bytes.Length);

            var credential = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = target,
                CredentialBlob = blobPtr,
                CredentialBlobSize = bytes.Length,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = Environment.UserName
            };

            if (!CredWrite(ref credential, 0))
            {
                var error = Marshal.GetLastWin32Error();
                throw new InvalidOperationException($"Failed to write credential to Windows Credential Manager. Error code: {error}");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blobPtr);
        }
    }

    private void DeleteCredential(string target)
    {
        try
        {
            CredDelete(target, CRED_TYPE_GENERIC, 0);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to delete credential for target {Target}", target);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credential);

    [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
    private static extern void CredFree(IntPtr credential);
}
