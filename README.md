# IIS_data_collection

Ways to collect IIS site status from a Windows host and get it into Dynatrace via OneAgent.

| Folder | What it is | Reports |
|---|---|---|
| [`powershell/`](powershell) | Standalone scripts. `Get-IISSiteStatus.ps1` reads site/app pool state from WMI. `Send-IISSiteStatusToOneAgent.ps1` pushes it to OneAgent's local metric ingest endpoint (`localhost:14499`), run as a scheduled task. | Exact state (Started/Stopped/...) |
| [`wmi-extension/`](wmi-extension) | Extensions 2.0 WMI-data-source extension, runs in OneAgent with no scripts. WQL can't call `GetState()`, so it reads W3SVC performance counters. | Per-site uptime, connections, throughput (state inferred) |
| [`python-extension/`](python-extension) | Extensions 2.0 Python extension, runs in OneAgent and executes the bundled PowerShell script every minute. Includes signing and deployment docs. | Exact state of sites and app pools |

## Which to use

- Want exact state managed from Dynatrace: **`python-extension/`** (recommended).
- Want no scripts and traffic metrics: **`wmi-extension/`**.
- Want the quickest thing with no extension signing: **`powershell/`** plus a scheduled task.

All of these need the IIS **Management Scripts and Tools** feature (`Web-Scripting-Tools`) except the WMI extension, which only needs IIS performance counters.

## Status

Untested on a live Windows/IIS/OneAgent host. The Python extension's packaging and signing were verified with throwaway certificates on macOS. See each folder's README or header comments for details and caveats.

The Python extension bundles its own copy of `Get-IISSiteStatus.ps1`. If you change the script in `powershell/`, copy it into `python-extension/iis_site_status/` too.
