<#
.SYNOPSIS
  Windows version of probe.sh — measure downtime while a deployment runs.
.EXAMPLE
  .\deploy\scripts\probe.ps1 -Url http://<ec2-public-dns>/ready -Seconds 120 -IntervalMs 200
#>
param(
    [string]$Url = 'http://localhost/ready',
    [int]$Seconds = 60,
    [int]$IntervalMs = 200
)

$total = 0; $failed = 0; $seen = @{}
$deadline = (Get-Date).AddSeconds($Seconds)

while ((Get-Date) -lt $deadline) {
    $total++
    try {
        $r = Invoke-WebRequest -Uri $Url -TimeoutSec 2 -UseBasicParsing
        $json = $null
        try { $json = $r.Content | ConvertFrom-Json } catch {}
        $key = if ($json -and $json.version) { "$($json.version) ($($json.color))" } else { 'n/a' }
        if ($seen.ContainsKey($key)) { $seen[$key]++ } else { $seen[$key] = 1 }
    } catch {
        $failed++
        Write-Warning ("{0:HH:mm:ss} FAIL {1}" -f (Get-Date), $_.Exception.Message)
    }
    Start-Sleep -Milliseconds $IntervalMs
}

"requests     : $total"
"failed       : $failed"
if ($total -gt 0) { "availability : {0:N3}%" -f ((($total - $failed) * 100.0) / $total) }
"answered by  :"
$seen.GetEnumerator() | ForEach-Object { "  {0,-32} {1}" -f $_.Key, $_.Value }
