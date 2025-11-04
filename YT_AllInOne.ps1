# yt_live_dl.ps1
# run_ytv.ps1
# run_yta.ps1
<#
.SYNOPSIS
Unified YtEasy script for livestream recording, video downloads, and audio extractions.

.DESCRIPTION
Combines the original YtEasy_Stream.ps1, run_ytv.ps1, and run_yta.ps1 behavior into one cross-platform PowerShell entry point.
Provides validation, safe defaults, logging, and optional parallel execution when PowerShell 7+ is available.

.LINK
https://github.com/yt-dlp/yt-dlp
https://ffmpeg.org/

.EXAMPLE
PS> .\YT_AllInOne.ps1 -Video -Url https://youtu.be/dQw4w9WgXcQ -Verbose
Downloads the video in best quality to the default output directory with verbose diagnostics.

.EXAMPLE
PS> .\YT_AllInOne.ps1 -Audio -Url https://youtu.be/dQw4w9WgXcQ -Quality audio-mp3
Extracts an MP3 audio file while embedding metadata and thumbnails.

.EXAMPLE
PS> .\YT_AllInOne.ps1 -Stream -Url https://youtu.be/dQw4w9WgXcQ
Records the livestream with resume support, remuxing to MP4 when complete.

.EXAMPLE
PS> .\YT_AllInOne.ps1 -Video -Url .\list.txt -MaxParallel 6 -NoPlaylist
Reads URLs from the provided text file, deduplicates them, and downloads in parallel when PowerShell 7+ is present.

.EXAMPLE
PS> .\YT_AllInOne.ps1 -Video -Url https://youtu.be/example -Format "bv[ext=mp4]+ba[ext=m4a]/b[ext=mp4]" -CookiesFile .\cookies.txt
Uses a custom yt-dlp format expression while authenticating with cookies from disk.

.NOTES
Original scripts: YtEasy_Stream.ps1, run_ytv.ps1, run_yta.ps1.
#>
#Requires -Version 5.1
# PowerShell 7+ is recommended for parallel downloads.

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Video', 'Audio', 'Stream')]
    [string]$Mode,

    [string]$Url,

    [string]$OutputDir,

    [string]$FileTemplate,

    [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
    [string]$Quality = 'best',

    [string]$Format,

    [string]$Proxy,

    [string]$CookiesFile,

    [switch]$NoPlaylist,

    [int]$MaxParallel = 1,

    [switch]$PassThru,

    [switch]$Interactive,

    [Parameter(DontShow = $true)]
    [string[]]$ExtraArgs,

    [string]$YtDlpPath,

    [string]$FfmpegPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Banner {
    Write-Host "=== YT Easy AIO ===" -ForegroundColor Cyan
    Write-Host "yt-dlp + ffmpeg helper  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkCyan
}

function Resolve-OutputDir {
    param(
        [string]$OutputDir,
        [string]$DefaultName = 'out'
    )

    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = (Get-Location).Path
    }

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $OutputDir = Join-Path -Path $root -ChildPath $DefaultName
    }
    elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
        $OutputDir = Join-Path -Path (Get-Location).Path -ChildPath $OutputDir
    }

    try {
        $resolved = Resolve-Path -LiteralPath $OutputDir -ErrorAction Stop
        return $resolved.Path
    }
    catch {
        return [System.IO.Path]::GetFullPath($OutputDir)
    }
}

function Resolve-ToolPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$OverridePath,

        [Parameter(Mandatory)]
        [string]$FriendlyName,

        [Parameter(Mandatory)]
        [string]$InstallHint
    )

    if ($OverridePath) {
        if (-not (Test-Path -LiteralPath $OverridePath)) {
            throw "The specified $FriendlyName path '$OverridePath' does not exist."
        }

        return (Resolve-Path -LiteralPath $OverridePath).ProviderPath
    }

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Cannot locate $FriendlyName. Ensure it is available on PATH or install it from $InstallHint, or supply -$($FriendlyName.Replace(' ', ''))Path."
    }

    return $command.Source
}

function Get-PlatformInfo {
    $isWin = $false
    $isLinux = $false
    $isMac = $false

    try {
        $ri = [System.Runtime.InteropServices.RuntimeInformation]
        if ($ri::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            $isWin = $true
        }
        elseif ($ri::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
            $isLinux = $true
        }
        elseif ($ri::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
            $isMac = $true
        }
    }
    catch {
        $plat = [System.Environment]::OSVersion.Platform
        switch ($plat) {
            'Win32NT' { $isWin = $true }
            4         { $isLinux = $true }
            6         { $isMac = $true }
            default   { $isWin = $true }
        }

        if (-not ($isWin -or $isMac)) {
            $isLinux = $true
        }
    }

    [PSCustomObject]@{
        IsWindows = $isWin
        IsLinux   = $isLinux
        IsMacOS   = $isMac
    }
}

function Test-UrlFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $pattern = '^(https?|ftp)://\S+$'
    return [regex]::IsMatch($Value, $pattern)
}

function Get-ValidatedUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputUrl
    )

    if ([string]::IsNullOrWhiteSpace($InputUrl)) {
        throw 'A URL value is required.'
    }

    $trimmed = $InputUrl.Trim()
    if (-not (Test-UrlFormat -Value $trimmed)) {
        throw "Invalid URL provided: $trimmed"
    }

    return $trimmed
}

function Get-DefaultTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Mode
    )

    switch ($Mode) {
        'Video'  { return '%(uploader)s/%(title)s [%(id)s].%(ext)s' }
        'Audio'  { return 'audio/%(title)s [%(id)s].%(ext)s' }
        'Stream' { return '%(title)s [%(id)s].%(ext)s' }
        default  { throw "Unknown mode '$Mode'" }
    }
}

function Get-YtDlpFormatExpression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$Quality
    )

    $map = @{
        'best'       = 'bestvideo*+bestaudio/best'
        '1080p'      = 'bv*[height<=1080]+ba/b[height<=1080]'
        '720p'       = 'bv*[height<=720]+ba/b[height<=720]'
        '480p'       = 'bv*[height<=480]+ba/b[height<=480]'
        'audio-best' = 'bestaudio/bestaudio*'
        'audio-m4a'  = 'bestaudio[ext=m4a]/bestaudio'
        'audio-mp3'  = 'bestaudio/bestaudio*'
    }

    if (-not $map.ContainsKey($Quality)) {
        throw "Unsupported quality preset '$Quality'."
    }

    if ($Mode -ne 'Audio' -and $Quality -like 'audio-*') {
        return $map['best']
    }

    if ($Mode -eq 'Audio' -and $Quality -notlike 'audio-*') {
        return $map['audio-best']
    }

    return $map[$Quality]
}

function Get-YtDownloadPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$OutputDir,

        [Parameter(Mandatory)]
        [string]$Template,

        [string]$Format,

        [string]$Quality,

        [string]$Proxy,

        [string]$CookiesFile,

        [switch]$NoPlaylist,

        [string]$FfmpegPath,

        [string[]]$ExtraArgs
    )

    $plan = [PSCustomObject]@{
        Url = $Url
        Arguments = [System.Collections.Generic.List[string]]::new()
        Mode = $Mode
        OutputDir = $OutputDir
    }

    $targetPath = Join-Path -Path $OutputDir -ChildPath $Template
    $plan.Arguments.Add('--newline') | Out-Null
    $plan.Arguments.Add('--no-color') | Out-Null
    $plan.Arguments.Add('--ignore-config') | Out-Null
    $plan.Arguments.Add('-o') | Out-Null
    $plan.Arguments.Add($targetPath) | Out-Null

    $formatExpression = if ($Format) { $Format } else { Get-YtDlpFormatExpression -Mode $Mode -Quality $Quality }
    $plan.Arguments.Add('-f') | Out-Null
    $plan.Arguments.Add($formatExpression) | Out-Null

    if ($Mode -eq 'Audio') {
        $plan.Arguments.Add('-x') | Out-Null
        $plan.Arguments.Add('--add-metadata') | Out-Null
        $plan.Arguments.Add('--embed-thumbnail') | Out-Null

        switch ($Quality) {
            'audio-m4a' { $plan.Arguments.Add('--audio-format') | Out-Null; $plan.Arguments.Add('m4a') | Out-Null }
            'audio-mp3' { $plan.Arguments.Add('--audio-format') | Out-Null; $plan.Arguments.Add('mp3') | Out-Null }
        }
    }

    if ($NoPlaylist.IsPresent) {
        $plan.Arguments.Add('--no-playlist') | Out-Null
    }

    if ($CookiesFile) {
        $plan.Arguments.Add('--cookies') | Out-Null
        $plan.Arguments.Add((Resolve-Path -LiteralPath $CookiesFile).ProviderPath) | Out-Null
    }

    if ($Proxy) {
        $plan.Arguments.Add('--proxy') | Out-Null
        $plan.Arguments.Add($Proxy) | Out-Null
    }

    if ($FfmpegPath) {
        $plan.Arguments.Add('--ffmpeg-location') | Out-Null
        $plan.Arguments.Add($FfmpegPath) | Out-Null
    }

    if ($ExtraArgs) {
        foreach ($arg in $ExtraArgs) {
            if (-not [string]::IsNullOrWhiteSpace($arg)) {
                $plan.Arguments.Add($arg) | Out-Null
            }
        }
    }

    $plan.Arguments.Add($Url) | Out-Null
    return $plan
}

function Get-YtStreamPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$OutputDir,

        [string]$Template,

        [string]$Format,

        [string]$Quality,

        [string]$Proxy,

        [string]$CookiesFile,

        [switch]$NoPlaylist,

        [string]$FfmpegPath,

        [string[]]$ExtraArgs
    )

    $streamQuality = if ([string]::IsNullOrWhiteSpace($Quality)) { 'best' } else { $Quality }
    $plan = Get-YtDownloadPlan -Mode 'Video' -Url $Url -OutputDir $OutputDir -Template $Template -Format $Format -Quality $streamQuality -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -FfmpegPath $FfmpegPath -ExtraArgs $ExtraArgs
    $plan.Mode = 'Stream'

    $plan.Arguments.Insert(0, '-c')
    $plan.Arguments.Insert(1, '--min-filesize')
    $plan.Arguments.Insert(2, '5M')
    $plan.Arguments.Insert(3, '--max-filesize')
    $plan.Arguments.Insert(4, '40G')
    $plan.Arguments.Insert(5, '--abort-on-unavailable-fragments')
    $plan.Arguments.Insert(6, '--no-keep-fragments')

    return $plan
}

function Invoke-YTTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$YtDlpPath,

        [Parameter(Mandatory)]
        [PSCustomObject]$Plan,

        [switch]$PassThru
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = 0
    $success = $false
    $message = 'Completed'

    try {
        Write-Verbose "yt-dlp $($Plan.Arguments -join ' ')"
        & $YtDlpPath @($Plan.Arguments.ToArray())
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "yt-dlp exited with code $exitCode"
        }
        $success = $true
    }
    catch {
        $message = $_.Exception.Message
        Write-Error -Message "Failed to process '$($Plan.Url)': $message"
        if ($LASTEXITCODE -ne $null) {
            $exitCode = $LASTEXITCODE
        }
    }
    finally {
        $stopwatch.Stop()
    }

    if ($PassThru) {
        return [PSCustomObject]@{
            Url        = $Plan.Url
            Mode       = $Plan.Mode
            OutputPath = $Plan.OutputDir
            Success    = $success
            DurationMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            ExitCode   = $exitCode
            Message    = $message
        }
    }

    if ($success) {
        Write-Information "[$($Plan.Mode)] $($Plan.Url) completed." -InformationAction Continue
    }

    return
}

function Invoke-YTStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$YtDlpPath,

        [Parameter(Mandatory)]
        [string]$FfmpegPath,

        [Parameter(Mandatory)]
        [PSCustomObject]$Plan,

        [switch]$PassThru
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = 0
    $success = $false
    $message = 'Completed'

    try {
        Write-Verbose "yt-dlp $($Plan.Arguments -join ' ')"
        & $YtDlpPath @($Plan.Arguments.ToArray())
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "yt-dlp exited with code $exitCode"
        }

        $files = Get-ChildItem -LiteralPath $Plan.OutputDir -File | Where-Object { $_.Extension -ne '.mp4' -and $_.Name -notlike '*.part' }
        foreach ($file in $files) {
            $destination = [System.IO.Path]::ChangeExtension($file.FullName, '.mp4')
            Write-Verbose "Remuxing '$($file.FullName)' to '$destination'"
            & $FfmpegPath -hide_banner -loglevel error -y -i $file.FullName -c copy -movflags +faststart $destination
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "Stream copy failed for '$($file.Name)'. Re-encoding."
                & $FfmpegPath -hide_banner -loglevel error -y -i $file.FullName -c:v libx264 -preset medium -crf 20 -c:a aac -b:a 192k -movflags +faststart $destination
                if ($LASTEXITCODE -ne 0) {
                    throw "ffmpeg failed to convert '$($file.Name)'"
                }
            }
        }

        $success = $true
    }
    catch {
        $message = $_.Exception.Message
        Write-Error -Message "Streaming for '$($Plan.Url)' failed: $message"
        if ($LASTEXITCODE -ne $null) {
            $exitCode = $LASTEXITCODE
        }
    }
    finally {
        $stopwatch.Stop()
    }

    if ($PassThru) {
        return [PSCustomObject]@{
            Url        = $Plan.Url
            Mode       = 'Stream'
            OutputPath = $Plan.OutputDir
            Success    = $success
            DurationMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            ExitCode   = $exitCode
            Message    = $message
        }
    }

    if ($success) {
        Write-Information "[Stream] $($Plan.Url) completed." -InformationAction Continue
    }

    return
}

function Start-YT {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet('Video', 'Audio', 'Stream')]
        [string]$Mode,

        [string]$Url,

        [string]$OutputDir,

        [string]$FileTemplate,

        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'best',

        [string]$Format,

        [string]$Proxy,

        [string]$CookiesFile,

        [switch]$NoPlaylist,

        [int]$MaxParallel = 1,

        [switch]$PassThru,

        [Parameter(DontShow = $true)]
        [string[]]$ExtraArgs,

        [string]$YtDlpPath,

        [string]$FfmpegPath
    )

    $platform = Get-PlatformInfo
    Write-Verbose "PowerShell version: $($PSVersionTable.PSVersion)"
    Write-Verbose "Platform: Windows=$($platform.IsWindows) Linux=$($platform.IsLinux) MacOS=$($platform.IsMacOS)"

    if ($MaxParallel -gt 1) {
        Write-Warning 'MaxParallel is ignored in single-URL mode.'
    }

    if (-not $Mode) {
        throw 'A mode of Video, Audio, or Stream must be specified.'
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw 'Url is required when not in interactive mode.'
    }

    $resolvedUrl = Get-ValidatedUrl -InputUrl $Url

    $OutputDir = Resolve-OutputDir -OutputDir $OutputDir -DefaultName 'out'

    $operation = "Run yt-dlp ($Mode)"

    if (-not $PSCmdlet.ShouldProcess($resolvedUrl, $operation)) {
        Write-Verbose 'Operation cancelled by user.'
        return
    }

    $template = if ($FileTemplate) { $FileTemplate } else { Get-DefaultTemplate -Mode $Mode }

    $planOutputDir = $OutputDir
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        if ($PSCmdlet.ShouldProcess($OutputDir, 'Create output directory')) {
            Write-Verbose "Creating output directory '$OutputDir'"
            $null = New-Item -ItemType Directory -Path $OutputDir -Force
        }
    }

    if ($Mode -eq 'Stream') {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $uniqueSuffix = [System.Guid]::NewGuid().ToString('N').Substring(0, 6)
        $planOutputDir = Join-Path -Path $OutputDir -ChildPath "stream-$timestamp-$uniqueSuffix"
        if (-not (Test-Path -LiteralPath $planOutputDir)) {
            if ($PSCmdlet.ShouldProcess($planOutputDir, 'Create stream output directory')) {
                $null = New-Item -ItemType Directory -Path $planOutputDir -Force
            }
        }
    }

    $ytCommandName = if ($platform.IsWindows) { 'yt-dlp.exe' } else { 'yt-dlp' }
    $ffmpegCommandName = if ($platform.IsWindows) { 'ffmpeg.exe' } else { 'ffmpeg' }

    $resolvedYtDlp = Resolve-ToolPath -Name $ytCommandName -OverridePath $YtDlpPath -FriendlyName 'yt-dlp' -InstallHint 'https://github.com/yt-dlp/yt-dlp#installation'
    $resolvedFfmpeg = Resolve-ToolPath -Name $ffmpegCommandName -OverridePath $FfmpegPath -FriendlyName 'ffmpeg' -InstallHint 'https://ffmpeg.org/download.html'

    $plan = if ($Mode -eq 'Stream') {
        Get-YtStreamPlan -Url $resolvedUrl -OutputDir $planOutputDir -Template $template -Format $Format -Quality $Quality -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -FfmpegPath $resolvedFfmpeg -ExtraArgs $ExtraArgs
    }
    else {
        Get-YtDownloadPlan -Mode $Mode -Url $resolvedUrl -OutputDir $planOutputDir -Template $template -Format $Format -Quality $Quality -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -FfmpegPath $resolvedFfmpeg -ExtraArgs $ExtraArgs
    }

    $result = if ($Mode -eq 'Stream') {
        Invoke-YTStream -YtDlpPath $resolvedYtDlp -FfmpegPath $resolvedFfmpeg -Plan $plan -PassThru:$PassThru.IsPresent
    }
    else {
        Invoke-YTTask -YtDlpPath $resolvedYtDlp -Plan $plan -PassThru:$PassThru.IsPresent
    }

    if ($PassThru) {
        return $result
    }

    return
}

function Start-YTVideo {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$OutputDir,
        [string]$FileTemplate,
        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'best',
        [string]$Format,
        [string]$Proxy,
        [string]$CookiesFile,
        [switch]$NoPlaylist,
        [int]$MaxParallel = 1,
        [switch]$PassThru,
        [string]$YtDlpPath,
        [string]$FfmpegPath
    )

    return Start-YT -Mode 'Video' -Url $Url -OutputDir $OutputDir -FileTemplate $FileTemplate -Quality $Quality -Format $Format -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -MaxParallel $MaxParallel -PassThru:$PassThru.IsPresent -YtDlpPath $YtDlpPath -FfmpegPath $FfmpegPath
}

function Start-YTAudio {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$OutputDir,
        [string]$FileTemplate,
        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'audio-mp3',
        [string]$Format,
        [string]$Proxy,
        [string]$CookiesFile,
        [switch]$NoPlaylist,
        [int]$MaxParallel = 1,
        [switch]$PassThru,
        [string]$YtDlpPath,
        [string]$FfmpegPath
    )

    return Start-YT -Mode 'Audio' -Url $Url -OutputDir $OutputDir -FileTemplate $FileTemplate -Quality $Quality -Format $Format -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -MaxParallel $MaxParallel -PassThru:$PassThru.IsPresent -YtDlpPath $YtDlpPath -FfmpegPath $FfmpegPath
}

function Start-YTStream {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$OutputDir,
        [string]$FileTemplate,
        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'best',
        [string]$Format,
        [string]$Proxy,
        [string]$CookiesFile,
        [switch]$NoPlaylist,
        [int]$MaxParallel = 1,
        [switch]$PassThru,
        [string]$YtDlpPath,
        [string]$FfmpegPath
    )

    return Start-YT -Mode 'Stream' -Url $Url -OutputDir $OutputDir -FileTemplate $FileTemplate -Quality $Quality -Format $Format -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -MaxParallel $MaxParallel -PassThru:$PassThru.IsPresent -YtDlpPath $YtDlpPath -FfmpegPath $FfmpegPath
}

function Invoke-InteractiveFlow {
    Show-Banner

    do {
        $u = Read-Host 'Enter URL'
    } while ([string]::IsNullOrWhiteSpace($u) -or ($u -notmatch '^https?://'))

    $url = $u.Trim()

    $modeKey = Read-Host '[A]udio, [V]ideo, or [S]tream?'
    switch ($modeKey.ToUpper()) {
        'A' { $mode = 'Audio' }
        'V' { $mode = 'Video' }
        'S' { $mode = 'Stream' }
        default { Write-Host 'Invalid choice' -ForegroundColor Red; return }
    }

    $quality = $null
    $extra = New-Object System.Collections.Generic.List[string]

    if ($mode -eq 'Video') {
        $q = Read-Host 'Quality: [1] best  [2] 1080p  [3] 720p  [4] 480p'
        $quality = switch ($q) {
            '2' { '1080p' }
            '3' { '720p' }
            '4' { '480p' }
            default { 'best' }
        }

        if ((Read-Host 'Convert to MP4? (Y/N)').ToUpper() -eq 'Y') {
            $extra.Add('--recode-video') | Out-Null
            $extra.Add('mp4') | Out-Null
        }
    }
    elseif ($mode -eq 'Audio') {
        $a = Read-Host 'Audio format: [1] best  [2] m4a  [3] mp3'
        $quality = switch ($a) {
            '2' { 'audio-m4a' }
            '3' { 'audio-mp3' }
            default { 'audio-best' }
        }
    }
    else {
        if ((Read-Host 'Start from beginning? (Y/N)').ToUpper() -eq 'Y') {
            $extra.Add('--live-from-start') | Out-Null
        }
    }

    if (-not $quality) {
        $quality = 'best'
    }

    Write-Host "Starting $mode for $url" -ForegroundColor Green

    $startParams = @{
        Mode    = $mode
        Url     = $url
        Quality = $quality
    }

    if ($extra.Count -gt 0) {
        $startParams['ExtraArgs'] = $extra.ToArray()
    }

    Start-YT @startParams
}

Set-Alias -Name ytv -Value Start-YTVideo
Set-Alias -Name yta -Value Start-YTAudio
Set-Alias -Name yts -Value Start-YTStream
Set-Alias -Name ytall -Value Start-YT

if ($MyInvocation.InvocationName -ne '.') {
    $common = @(
        'WhatIf','Confirm','Verbose','Debug','ErrorAction','WarningAction',
        'InformationAction','OutVariable','OutBuffer','PipelineVariable'
    )

    $boundNonCommon = @($PSBoundParameters.Keys | Where-Object { $_ -notin $common })
    $isInteractive = ($boundNonCommon.Count -eq 0) -or $Interactive.IsPresent

    if ($isInteractive) {
        Invoke-InteractiveFlow
    }
    else {
        Show-Banner
        $OutputDir = Resolve-OutputDir -OutputDir $OutputDir -DefaultName 'out'
        if ($PSCmdlet.ShouldProcess($OutputDir, 'Ensure output directory')) {
            if (-not (Test-Path -LiteralPath $OutputDir)) {
                New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
            }
        }

        $invokeParams = @{}
        foreach ($key in $PSBoundParameters.Keys) {
            if ($key -eq 'Interactive') {
                continue
            }

            if ($key -eq 'OutputDir') {
                $invokeParams[$key] = $OutputDir
            }
            else {
                $invokeParams[$key] = $PSBoundParameters[$key]
            }
        }

        if (-not $invokeParams.ContainsKey('OutputDir')) {
            $invokeParams['OutputDir'] = $OutputDir
        }

        Start-YT @invokeParams
    }
}
