<#
CAMECRACK - install / update the no-SD scripts + AP (hotspot) mode on the camera.

Pushes the files of installer/no-sd to /etc/config/camecrack/ over the camera's
passwordless telnet (port 24) + busybox nc, then checks every MD5.
Prerequisite: the no-SD mode v1 is already installed (boot hook in sensor_driver.sh).
Never pushes wifi.conf (credentials stay on the camera).

  .\installer\no-sd\install-ap.ps1 -CamHost <camera-ip>
#>
param([Parameter(Mandatory=$true)][string]$CamHost, [int]$TelnetPort = 24, [int]$NcPort = 5555,
      [string[]]$Only)    # e.g. -Only boot.sh,ap_mode.sh ; default: everything
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = '/etc/config/camecrack'
$toPush = 'boot.sh', 'extras.sh', 'wifi_up.sh', 'webcfg.sh', 'webcfg_handler.sh',
          'uninstall.sh', 'ap_mode.sh', 'button_watch.sh', 'ap-bin.tar.xz'
if ($Only) { $toPush = $Only }
# Files too big to keep two copies of in the 256 KB jffs2: delete the old one first
# (if the push then fails, only AP mode is unavailable; nothing else depends on it).
$big = @('ap-bin.tar.xz')

function Invoke-Cam([string]$Cmd, [int]$WaitMs = 4000) {
  $c = New-Object Net.Sockets.TcpClient
  $c.Connect($CamHost, $TelnetPort)
  $s = $c.GetStream()
  Start-Sleep -Milliseconds 400
  $buf = New-Object byte[] 65536
  while ($s.DataAvailable) { [void]$s.Read($buf, 0, $buf.Length) }
  # quotes split the marker so the echoed command line can never match it
  $b = [Text.Encoding]::ASCII.GetBytes("$Cmd; echo __E''ND__`n")
  $s.Write($b, 0, $b.Length)
  $out = New-Object Text.StringBuilder
  $deadline = (Get-Date).AddMilliseconds($WaitMs)
  while ((Get-Date) -lt $deadline) {
    if ($s.DataAvailable) {
      $n = $s.Read($buf, 0, $buf.Length)
      [void]$out.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
      if ($out.ToString() -match "(?m)^__END__") { break }
    } else { Start-Sleep -Milliseconds 100 }
  }
  $c.Close()
  return $out.ToString()
}

function Send-File([string]$Local, [string]$Remote) {
  $bytes = [IO.File]::ReadAllBytes($Local)
  if ($Local -like '*.sh') { $bytes = [byte[]]($bytes | Where-Object { $_ -ne 13 }) }  # force LF
  # The listener must run in the foreground of a LIVE telnet session (a background
  # job left behind by a closed session gets killed), hence the PowerShell job.
  $job = Start-Job -ScriptBlock {
    param($h, $p, $np, $r)
    $c = New-Object Net.Sockets.TcpClient; $c.Connect($h, $p); $s = $c.GetStream()
    Start-Sleep -Milliseconds 400
    $b = [Text.Encoding]::ASCII.GetBytes("nc -l -p $np > '$r'; echo __E''ND__`n")
    $s.Write($b, 0, $b.Length)
    $buf = New-Object byte[] 4096; $o = ''
    $dl = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $dl -and $o -notmatch "(?m)^__END__") {
      if ($s.DataAvailable) { $n = $s.Read($buf, 0, 4096); $o += [Text.Encoding]::ASCII.GetString($buf, 0, $n) }
      else { Start-Sleep -Milliseconds 100 }
    }
    $c.Close()
  } -ArgumentList $CamHost, $TelnetPort, $NcPort, $Remote
  $c = $null
  for ($i = 0; $i -lt 40 -and -not $c; $i++) {
    Start-Sleep -Milliseconds 500
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect($CamHost, $NcPort) } catch { $c = $null }
  }
  if (-not $c) { Stop-Job $job; throw "nc listener on ${CamHost}:$NcPort never came up" }
  $s = $c.GetStream(); $s.Write($bytes, 0, $bytes.Length); $s.Flush()
  $c.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
  Start-Sleep -Milliseconds 800; $c.Close()
  Wait-Job $job -Timeout 130 | Out-Null; Remove-Job $job -Force
  $md5 = [BitConverter]::ToString(
    [Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
  return $md5
}

Write-Host "Camera $CamHost : checking no-SD install..."
$chk = Invoke-Cam "ls $dst/boot.sh && grep -c camecrack /etc/config/sensor_driver.sh; df /etc/config | tail -1"
if ($chk -notmatch "$dst/boot.sh") { throw "no-SD mode v1 not installed on the camera (missing $dst/boot.sh)" }
Write-Host $chk

# Space check: /etc/config is a 256 KB jffs2; keep >= 8 KB free after install.
$df = [regex]::Match($chk, '(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s+/etc/config')
if ($df.Success) {
  $freeKB = [int]$df.Groups[3].Value
  $existing = Invoke-Cam "ls -l $dst/ap-bin.tar.xz 2>/dev/null"
  $m = [regex]::Match($existing, '\s(\d+)\s+\w{3}\s+\d+\s+[\d:]+\s+\S*ap-bin')
  $oldKB = if ($m.Success) { [int]([int]$m.Groups[1].Value / 1024) } else { 0 }
  $newKB = [int]((Get-Item "$src\ap-bin.tar.xz").Length / 1024) + 2
  if ($freeKB + $oldKB - $newKB -lt 8) { throw "not enough room in /etc/config ($freeKB KB free, need ~$newKB KB)" }
}

foreach ($f in $toPush) {
  $local = Join-Path $src $f
  if (-not (Test-Path $local)) { throw "missing $local" }
  $tmp = "$dst/.$f.new"
  if ($big -contains $f) { [void](Invoke-Cam "rm -f '$dst/$f' '$tmp'; sync") }
  $want = Send-File $local $tmp
  $got = Invoke-Cam "md5sum '$tmp'"
  if ($got -notmatch $want) { throw "MD5 mismatch for $f (want $want)`n$got" }
  # atomic replace; scripts executable
  [void](Invoke-Cam "mv '$tmp' '$dst/$f' && chmod 755 '$dst/$f'")
  Write-Host ("  {0,-20} OK  {1}" -f $f, $want)
}
Write-Host (Invoke-Cam "sync; df /etc/config | tail -1; ls -l $dst")
Write-Host "Done. Changes apply at the next boot (no SD card)."
