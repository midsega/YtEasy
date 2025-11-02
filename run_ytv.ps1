yt-dlp -U
Set-Location 'G:\yt-dlp\Video'
$url = Read-Host "Extract Video From This URL"
yt-dlp -f best -v $url
