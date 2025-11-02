# yt_live_dl.ps1
# --- YtEasy banner (ASCII typewriter) ---
$full = 'YtEasy Livestream Downloader'
for ($i=1; $i -le $full.Length; $i++) {
  Clear-Host
  $txt = $full.Substring(0,$i)
  $inner = ' ' + $txt + ' '
  $top =  '+' + ('-' * $inner.Length) + '+'
  $mid =  '|' +  $inner                 + '|'
  $bot =  '+' + ('-' * $inner.Length) + '+'
  Write-Host $top; Write-Host $mid; Write-Host $bot
  Start-Sleep -Milliseconds 40
}
# --- end banner ---

# Requires: yt-dlp and ffmpeg in PATH
$ErrorActionPreference = "Stop"

# --- A) Check for yt-dlp update ---
if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) { Write-Error "yt-dlp not found in PATH"; exit 1 }
try { & yt-dlp -U | Out-Host } catch { Write-Host "Update check failed or not supported; continuing." }

# ffmpeg is mandatory for remux/transcode
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Error "ffmpeg not found in PATH"; exit 1 }

# --- B) Create timestamped folder and cd into it ---
$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$null = New-Item -ItemType Directory -Path $stamp -Force
Set-Location $stamp

# --- E) Ask user for URL ---
$url = Read-Host "Stream URL"
if ([string]::IsNullOrWhiteSpace($url)) { Write-Error "No URL provided"; exit 1 }

# Common settings
$outTmpl = "%(title)s.%(ext)s"
$minSize = "5M"     # F) --min-filesize
$maxSize = "40G"    # G) --max-filesize

# --- C, D, F, G, H, I ---
# Start from beginning, auto-resume, size bounds, abort on missing fragments, don't keep fragments.
# Use best quality; container decided by site. MP4 handling is done after download (J).
$ydlArgs = @(
  "-c",
  "--live-from-start",
  "--min-filesize", $minSize,
  "--max-filesize", $maxSize,
  "--abort-on-unavailable-fragments",
  "--no-keep-fragments",
  "-f", 'bestvideo*+bestaudio/best',
  "-o", $outTmpl,
  $url
)

& yt-dlp @ydlArgs

# --- J) Convert to MP4 after download if not already MP4 ---
# 1) Try remux (stream copy). 2) If remux fails, transcode to H.264/AAC.
Get-ChildItem -File | Where-Object {
  $_.Extension -ne ".mp4" -and $_.Name -notlike "*.part"
} | ForEach-Object {
  $src  = $_.FullName
  $base = [System.IO.Path]::Combine($_.DirectoryName, [System.IO.Path]::GetFileNameWithoutExtension($_.Name))
  $dst  = "$base.mp4"

  # Try stream copy
  & ffmpeg -hide_banner -loglevel error -y -i "$src" -c copy -movflags +faststart "$dst"
  if ($LASTEXITCODE -ne 0) {
    # Fallback to transcode
    & ffmpeg -hide_banner -loglevel error -y -i "$src" -c:v libx264 -preset medium -crf 20 -c:a aac -b:a 192k -movflags +faststart "$dst"
  }
}

Write-Host "Done. Saved to: $(Get-Location)"
