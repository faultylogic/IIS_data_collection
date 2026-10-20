# IIS Site Status, OneAgent extension

Extensions 2.0 WMI extension (`custom:iis.site.status`) that runs inside OneAgent on a Windows host and reports per-site IIS metrics every minute.

## Layout

```
iis-site-status-extension/
└── extension/
    └── extension.yaml
```

## Prerequisites

- Windows host with IIS, monitored by OneAgent 1.221+.
- Extension Execution Controller (EEC) enabled for the environment or host (Settings, Preferences, Extension Execution Controller).
- The `dt` CLI (dt-cli) and a developer key pair for signing.

## Build and deploy

```bash
# Create a developer key pair once (CA cert must be uploaded to OneAgent hosts, see Dynatrace docs
# "Sign extensions" / "Upload root certificate")
dt extension genca
dt extension gencert

# From the iis-site-status-extension directory
dt extension assemble
dt extension sign --key ./developer.pem
dt extension upload bundle.zip
```

Then in Dynatrace: Hub or Extensions, `IIS Site Status`, Add monitoring configuration, scope to the host, host group or environment.

## Metrics

All metrics carry the dimension `iis.site` (site name).

| Metric | Meaning |
|---|---|
| `custom.iis.site.uptime` | Seconds since the site started. 0 or no data means stopped. |
| `custom.iis.site.connections` | Current connections |
| `custom.iis.site.bytes_received` | Bytes/sec received |
| `custom.iis.site.bytes_sent` | Bytes/sec sent |
| `custom.iis.site.requests` | Requests/sec |

Alerting suggestion: `custom.iis.site.uptime` below 1 for 3 of 5 minutes, plus a missing-data condition.

## Differences from the PowerShell scripts

The WMI data source runs WQL SELECT queries only, with no method calls. The scripts get exact state (Started, Stopped, ...) from `GetState()`. This extension infers it from the W3SVC performance counters instead, so it has no `Stopping` or `Starting` states and no app pool state. If you need exact state, keep running `Send-IISSiteStatusToOneAgent.ps1` as a scheduled task alongside it.
