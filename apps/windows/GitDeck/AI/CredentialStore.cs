using System.Runtime.InteropServices;
using System.Text;
using GitDeck.Common;

namespace GitDeck.AI;

/// Windows 凭据管理器中的通用凭据（API Key 等），不写入设置文件（对应 mac 端的钥匙串）。
/// 调试版使用独立的前缀，不会读写正式版的凭据。
public static class CredentialStore
{
    private const int CredTypeGeneric = 1;
    private const int CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    private static string Target(string account) => $"{(AppInfo.IsDebugBuild ? AppInfo.ProductName + ".debug" : AppInfo.ProductName)}.ai/{account}";

    public static string? Read(string account)
    {
        if (!CredRead(Target(account), CredTypeGeneric, 0, out var pointer)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            if (credential.CredentialBlobSize == 0 || credential.CredentialBlob == IntPtr.Zero) return null;
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CredFree(pointer);
        }
    }

    /// 保存；`value` 为空时删除。返回是否成功。
    public static bool Write(string account, string? value)
    {
        var target = Target(account);
        if (string.IsNullOrEmpty(value))
        {
            return CredDelete(target, CredTypeGeneric, 0) || Marshal.GetLastWin32Error() == ErrorNotFound;
        }
        var bytes = Encoding.UTF8.GetBytes(value);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = target,
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blob,
                Persist = CredPersistLocalMachine,
                UserName = account,
            };
            return CredWrite(ref credential, 0);
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
