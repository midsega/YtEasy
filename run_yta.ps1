# --- YtEasy banner (ASCII typewriter) ---
$full = 'YtEasy MP3 Downloader'
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
yt-dlp -U
$dest = 'G:\yt-dlp\Audio'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Set-Location $dest
$url = Read-Host 'Paste URL and press Enter'
if ([string]::IsNullOrWhiteSpace($url)) { Write-Host 'No URL provided.'; exit 1 }
yt-dlp -x --audio-format mp3 --audio-quality 0 `
  --add-metadata --embed-thumbnail `
  -o "%(title)s.%(ext)s" "$url"