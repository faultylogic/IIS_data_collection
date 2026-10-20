<#
.SYNOPSIS
    Collects IIS site (and optionally app pool) status via WMI and pushes it
    to the local Dynatrace OneAgent metric ingest endpoint.

.DESCRIPTION
    How it works:
      1. Query the IIS WMI provider (root\WebAdministration) for all sites, and
         call GetState() on each one to get its live run state.
      2. Convert each state into Dynatrace metric line protocol, e.g.
             iis.site.up,site="Default Web Site",site_id=1 gauge,1
      3. POST all lines in a single request to OneAgent's local ingest API
         (http://localhost:14499/metrics/ingest). OneAgent forwards them to
         Dynatrace and attaches them to the host entity automatically.
      4. Check OneAgent's response and warn about any lines it rejected.
      5. Either exit (run once, for Task Scheduler) or sleep and repeat
         (-IntervalSeconds).

    The local OneAgent endpoint needs no API token. No timestamp is sent, so
    OneAgent stamps each value with the time it was received.

    Metrics emitted (all gauges):
      iis.site.up       dims: site, site_id   1 if Started, otherwise 0
      iis.site.state    dims: site, site_id   0 Starting, 1 Started, 2 Stopping,
                                              3 Stopped, 4 Unknown
      iis.apppool.up    dims: apppool         same meaning, per app pool
      iis.apppool.state dims: apppool         (only with -IncludeAppPools)

    Requirements:
      - Run on the monitored host, in an elevated session.
      - OneAgent installed with metric ingestion enabled (default on current versions).
      - IIS "Management Scripts and Tools" feature (Web-Scripting-Tools), which
        provides the root\WebAdministration WMI namespace.

.PARAMETER Endpoint
    OneAgent metric ingest URL. Change only if the default local port differs.

.PARAMETER IncludeAppPools
    Also send metrics for each IIS application pool.

.PARAMETER IntervalSeconds
    0 (default) = collect and send once, then exit. Greater than 0 = loop forever,
    sleeping this many seconds between runs.

.PARAMETER DryRun
    Print the metric lines to the console instead of sending them. Use this to
    validate output before pointing it at OneAgent.

.EXAMPLE
    .\Send-IISSiteStatusToOneAgent.ps1 -DryRun
    .\Send-IISSiteStatusToOneAgent.ps1 -IncludeAppPools
    .\Send-IISSiteStatusToOneAgent.ps1 -IncludeAppPools -IntervalSeconds 60
#>
[CmdletBinding()]
param(
    [string]$Endpoint = 'http://localhost:14499/metrics/ingest',
    [switch]$IncludeAppPools,
    [int]$IntervalSeconds = 0,
    [switch]$DryRun
)

# WMI namespace exposed by the IIS WMI provider
$ns = 'root\WebAdministration'

function ConvertTo-DimValue([string]$v) {
    # Dimension values may contain spaces and punctuation (e.g. "Default Web Site"),
    # so wrap them in double quotes and escape backslashes and quotes inside.
    '"' + ($v -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Get-MetricLines {
    # Builds the list of metric lines for the current IIS state.
    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($site in Get-CimInstance -Namespace $ns -ClassName Site -ErrorAction Stop) {
        # Live run state is only available by calling GetState()
        $code = [int](Invoke-CimMethod -InputObject $site -MethodName GetState).ReturnValue
        $dims = "site=$(ConvertTo-DimValue $site.Name),site_id=$($site.Id)"

        # "up" is a simple 0/1 you can alert on; "state" keeps the full detail
        $lines.Add("iis.site.up,$dims gauge,$([int]($code -eq 1))")
        $lines.Add("iis.site.state,$dims gauge,$code")
    }

    if ($IncludeAppPools) {
        foreach ($pool in Get-CimInstance -Namespace $ns -ClassName ApplicationPool -ErrorAction Stop) {
            $code = [int](Invoke-CimMethod -InputObject $pool -MethodName GetState).ReturnValue
            $dims = "apppool=$(ConvertTo-DimValue $pool.Name)"
            $lines.Add("iis.apppool.up,$dims gauge,$([int]($code -eq 1))")
            $lines.Add("iis.apppool.state,$dims gauge,$code")
        }
    }
    $lines
}

function Send-Metrics([string[]]$Lines) {
    # One metric per line, newline separated, sent as a single plain-text POST
    $body = $Lines -join "`n"

    if ($DryRun) { Write-Host $body; return }

    # OneAgent replies 202 with {linesOk, linesInvalid, error}. Non-2xx throws.
    $resp = Invoke-RestMethod -Uri $Endpoint -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'text/plain; charset=utf-8' -ErrorAction Stop

    if ($resp.linesInvalid -gt 0) {
        Write-Warning "OneAgent rejected $($resp.linesInvalid) line(s): $($resp | ConvertTo-Json -Depth 5 -Compress)"
    } else {
        Write-Verbose "Sent $($resp.linesOk) line(s)."
    }
}

# Main loop: runs once when IntervalSeconds is 0, otherwise repeats until stopped.
do {
    try {
        $lines = @(Get-MetricLines)
        if ($lines.Count -eq 0) {
            Write-Warning 'No IIS sites found.'
        } else {
            Send-Metrics $lines
            Write-Host "$(Get-Date -Format s) pushed $($lines.Count) metric line(s)."
        }
    }
    catch {
        # Log and keep looping so a transient failure doesn't kill the collector
        Write-Error "Collection/push failed: $($_.Exception.Message)"
    }
    if ($IntervalSeconds -gt 0) { Start-Sleep -Seconds $IntervalSeconds }
} while ($IntervalSeconds -gt 0)
