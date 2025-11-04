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

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Video')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Video')]
    [switch]$Video,

    [Parameter(Mandatory, ParameterSetName = 'Audio')]
    [switch]$Audio,

    [Parameter(Mandatory, ParameterSetName = 'Stream')]
    [switch]$Stream,

    [Parameter(Mandatory)]
    [string[]]$Url,

    [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'out'),

    [string]$FileTemplate,

    [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
    [string]$Quality = 'best',

    [string]$Format,

    [string]$Proxy,

    [string]$CookiesFile,

    [switch]$NoPlaylist,

    [int]$MaxParallel = 4,

    [switch]$PassThru,

    [switch]$WhatIf,

    [switch]$Confirm,

    [string]$YtDlpPath,

    [string]$FfmpegPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        IsWindows = [bool]$IsWindows
        IsLinux   = [bool]$IsLinux
        IsMacOS   = [bool]$IsMacOS
        PSVersion = $PSVersionTable.PSVersion.ToString()
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

function Get-UrlList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$InputUrls
    )

    $urls = New-Object System.Collections.Generic.List[string]
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $InputUrls) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        if (Test-Path -LiteralPath $item -PathType Leaf) {
            $lines = Get-Content -LiteralPath $item | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if (-not (Test-UrlFormat -Value $trimmed)) {
                    throw "Invalid URL detected in file '$item': $trimmed"
                }

                if ($set.Add($trimmed)) {
                    $urls.Add($trimmed) | Out-Null
                }
            }
            continue
        }

        if (-not (Test-UrlFormat -Value $item)) {
            throw "Invalid URL provided: $item"
        }

        if ($set.Add($item)) {
            $urls.Add($item) | Out-Null
        }
    }

    return ,$urls.ToArray()
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

        [string]$FfmpegPath
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

        [string]$FfmpegPath
    )

    $streamQuality = if ([string]::IsNullOrWhiteSpace($Quality)) { 'best' } else { $Quality }
    $plan = Get-YtDownloadPlan -Mode 'Video' -Url $Url -OutputDir $OutputDir -Template $Template -Format $Format -Quality $streamQuality -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -FfmpegPath $FfmpegPath
    $plan.Mode = 'Stream'

    $plan.Arguments.Insert(0, '--live-from-start')
    $plan.Arguments.Insert(0, '-c')
    $plan.Arguments.Insert(3, '--min-filesize')
    $plan.Arguments.Insert(4, '5M')
    $plan.Arguments.Insert(5, '--max-filesize')
    $plan.Arguments.Insert(6, '40G')
    $plan.Arguments.Insert(7, '--abort-on-unavailable-fragments')
    $plan.Arguments.Insert(8, '--no-keep-fragments')

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
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Video')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Video')]
        [switch]$Video,

        [Parameter(Mandatory, ParameterSetName = 'Audio')]
        [switch]$Audio,

        [Parameter(Mandatory, ParameterSetName = 'Stream')]
        [switch]$Stream,

        [Parameter(Mandatory)]
        [string[]]$Url,

        [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'out'),

        [string]$FileTemplate,

        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'best',

        [string]$Format,

        [string]$Proxy,

        [string]$CookiesFile,

        [switch]$NoPlaylist,

        [int]$MaxParallel = 4,

        [switch]$PassThru,

        [switch]$WhatIf,

        [switch]$Confirm,

        [string]$YtDlpPath,

        [string]$FfmpegPath
    )

    if ($PSBoundParameters.ContainsKey('WhatIf') -and $WhatIf.IsPresent) {
        $WhatIfPreference = $true
    }

    if ($PSBoundParameters.ContainsKey('Confirm') -and $Confirm.IsPresent) {
        $ConfirmPreference = 'High'
    }

    $platform = Get-PlatformInfo
    Write-Verbose "PowerShell version: $($platform.PSVersion)"

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        Write-Verbose "Creating output directory '$OutputDir'"
        $null = New-Item -ItemType Directory -Path $OutputDir -Force
    }

    $mode = switch ($PSCmdlet.ParameterSetName) {
        'Video'  { 'Video' }
        'Audio'  { 'Audio' }
        'Stream' { 'Stream' }
        default  { throw 'Unable to determine execution mode.' }
    }

    $resolvedYtDlp = Resolve-ToolPath -Name 'yt-dlp' -OverridePath $YtDlpPath -FriendlyName 'yt-dlp' -InstallHint 'https://github.com/yt-dlp/yt-dlp#installation'
    $resolvedFfmpeg = Resolve-ToolPath -Name 'ffmpeg' -OverridePath $FfmpegPath -FriendlyName 'ffmpeg' -InstallHint 'https://ffmpeg.org/download.html'

    $urls = Get-UrlList -InputUrls $Url
    if ($urls.Count -eq 0) {
        Write-Warning 'No valid URLs were supplied. Nothing to do.'
        return
    }

    $template = if ($FileTemplate) { $FileTemplate } else { Get-DefaultTemplate -Mode $mode }

    $plans = @()
    $streamWarningIssued = $false
    for ($i = 0; $i -lt $urls.Count; $i++) {
        $entry = $urls[$i]
        $planOutputDir = $OutputDir
        if ($mode -eq 'Stream') {
            if (-not $streamWarningIssued -and $MaxParallel -gt 1) {
                Write-Warning 'Streaming mode processes URLs sequentially; MaxParallel is ignored.'
                $streamWarningIssued = $true
            }

            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $uniqueSuffix = [System.Guid]::NewGuid().ToString('N').Substring(0, 6)
            $planOutputDir = Join-Path -Path $OutputDir -ChildPath "stream-$timestamp-$uniqueSuffix"
            if (-not (Test-Path -LiteralPath $planOutputDir)) {
                $null = New-Item -ItemType Directory -Path $planOutputDir -Force
            }
        }

        $plan = if ($mode -eq 'Stream') {
            Get-YtStreamPlan -Url $entry -OutputDir $planOutputDir -Template $template -Format $Format -Quality $Quality -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -FfmpegPath $resolvedFfmpeg
        } else {
            Get-YtDownloadPlan -Mode $mode -Url $entry -OutputDir $planOutputDir -Template $template -Format $Format -Quality $Quality -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -FfmpegPath $resolvedFfmpeg
        }

        $plans += $plan
    }

    $operation = switch ($mode) {
        'Video'  { 'Download video' }
        'Audio'  { 'Download audio' }
        'Stream' { 'Record stream' }
    }

    $approvedPlans = @()
    foreach ($plan in $plans) {
        if ($PSCmdlet.ShouldProcess($plan.Url, $operation)) {
            $approvedPlans += $plan
        }
    }

    if ($approvedPlans.Count -eq 0) {
        Write-Verbose 'Operation cancelled by user.'
        return
    }

    $results = @()
    if ($mode -eq 'Stream') {
        foreach ($plan in $approvedPlans) {
            $results += Invoke-YTStream -YtDlpPath $resolvedYtDlp -FfmpegPath $resolvedFfmpeg -Plan $plan -PassThru:$PassThru.IsPresent
        }
    }
    else {
        $useParallel = $false
        if ($MaxParallel -gt 1 -and $approvedPlans.Count -gt 1) {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $useParallel = $true
            }
            else {
                Write-Warning 'Parallel execution requires PowerShell 7 or later. Falling back to sequential processing.'
            }
        }

        if ($useParallel) {
            $invoker = ${function:Invoke-YTTask}
            $results = $approvedPlans | ForEach-Object -Parallel {
                param($innerPlan, $yt, $pass)
                & $using:invoker -YtDlpPath $yt -Plan $innerPlan -PassThru:$pass
            } -ThrottleLimit $MaxParallel -ArgumentList $resolvedYtDlp, $PassThru.IsPresent
        }
        else {
            foreach ($plan in $approvedPlans) {
                $results += Invoke-YTTask -YtDlpPath $resolvedYtDlp -Plan $plan -PassThru:$PassThru.IsPresent
            }
        }
    }

    if ($PassThru) {
        return $results
    }

    return
}

function Start-YTVideo {
    [CmdletBinding(DefaultParameterSetName = 'Video', SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Url,
        [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'out'),
        [string]$FileTemplate,
        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'best',
        [string]$Format,
        [string]$Proxy,
        [string]$CookiesFile,
        [switch]$NoPlaylist,
        [int]$MaxParallel = 4,
        [switch]$PassThru,
        [switch]$WhatIf,
        [switch]$Confirm,
        [string]$YtDlpPath,
        [string]$FfmpegPath
    )

    return Start-YT -Video -Url $Url -OutputDir $OutputDir -FileTemplate $FileTemplate -Quality $Quality -Format $Format -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -MaxParallel $MaxParallel -PassThru:$PassThru.IsPresent -WhatIf:$WhatIf.IsPresent -Confirm:$Confirm.IsPresent -YtDlpPath $YtDlpPath -FfmpegPath $FfmpegPath
}

function Start-YTAudio {
    [CmdletBinding(DefaultParameterSetName = 'Audio', SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Url,
        [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'out'),
        [string]$FileTemplate,
        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'audio-mp3',
        [string]$Format,
        [string]$Proxy,
        [string]$CookiesFile,
        [switch]$NoPlaylist,
        [int]$MaxParallel = 4,
        [switch]$PassThru,
        [switch]$WhatIf,
        [switch]$Confirm,
        [string]$YtDlpPath,
        [string]$FfmpegPath
    )

    return Start-YT -Audio -Url $Url -OutputDir $OutputDir -FileTemplate $FileTemplate -Quality $Quality -Format $Format -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -MaxParallel $MaxParallel -PassThru:$PassThru.IsPresent -WhatIf:$WhatIf.IsPresent -Confirm:$Confirm.IsPresent -YtDlpPath $YtDlpPath -FfmpegPath $FfmpegPath
}

function Start-YTStream {
    [CmdletBinding(DefaultParameterSetName = 'Stream', SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Url,
        [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'out'),
        [string]$FileTemplate,
        [ValidateSet('best', '1080p', '720p', '480p', 'audio-best', 'audio-m4a', 'audio-mp3')]
        [string]$Quality = 'best',
        [string]$Format,
        [string]$Proxy,
        [string]$CookiesFile,
        [switch]$NoPlaylist,
        [int]$MaxParallel = 4,
        [switch]$PassThru,
        [switch]$WhatIf,
        [switch]$Confirm,
        [string]$YtDlpPath,
        [string]$FfmpegPath
    )

    return Start-YT -Stream -Url $Url -OutputDir $OutputDir -FileTemplate $FileTemplate -Quality $Quality -Format $Format -Proxy $Proxy -CookiesFile $CookiesFile -NoPlaylist:$NoPlaylist.IsPresent -MaxParallel $MaxParallel -PassThru:$PassThru.IsPresent -WhatIf:$WhatIf.IsPresent -Confirm:$Confirm.IsPresent -YtDlpPath $YtDlpPath -FfmpegPath $FfmpegPath
}

Set-Alias -Name ytv -Value Start-YTVideo
Set-Alias -Name yta -Value Start-YTAudio
Set-Alias -Name yts -Value Start-YTStream
Set-Alias -Name ytall -Value Start-YT

if ($MyInvocation.InvocationName -ne '.') {
    Start-YT @PSBoundParameters | Out-Null
}
