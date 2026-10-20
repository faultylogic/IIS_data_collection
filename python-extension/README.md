# IIS Site Status, OneAgent Python extension

Dynatrace Extensions 2.0 **Python** extension (`custom:iis-site-status`) that runs **locally inside OneAgent** on a Windows IIS host. Every minute it runs a bundled PowerShell script (`Get-IISSiteStatus.ps1`), which asks the IIS WMI provider for the exact state of every site and app pool, and reports the results as metrics.

```
OneAgent -> Extension Execution Controller (EEC) -> Python extension
         -> powershell.exe Get-IISSiteStatus.ps1 -Json -> WMI (root\WebAdministration)
         -> report_metric(...) -> Dynatrace
```

## Metrics

| Metric | Dimensions | Meaning |
|---|---|---|
| `custom.iis.site.up` | `site`, `site_id` | 1 if Started, else 0 |
| `custom.iis.site.state` | `site`, `site_id` | 0 Starting, 1 Started, 2 Stopping, 3 Stopped, 4 Unknown |
| `custom.iis.apppool.up` | `apppool` | 1 if Started, else 0 (when app pools are enabled) |
| `custom.iis.apppool.state` | `apppool` | same codes as site state |
| `custom.iis.collector.up` | none | 1 if the script ran, 0 if it failed or timed out |

Suggested alerts: `custom.iis.site.up` < 1 for 3 of 5 minutes, and `custom.iis.collector.up` < 1.

Configuration (per monitoring configuration): **Include application pools** (default on) and **PowerShell timeout** (5 to 55 seconds, default 30).

## Layout

```
iis_site_status/
├── extension/
│   ├── extension.yaml          # name, version, python runtime, metric metadata
│   └── activationSchema.json   # settings shown in the monitoring configuration UI
├── iis_site_status/
│   ├── __main__.py             # extension code (runs script, parses JSON, reports metrics)
│   └── Get-IISSiteStatus.ps1   # collector, packaged inside the extension
├── activation.json             # used only by `dt-sdk run` simulation, not bundled
└── setup.py
```

## Prerequisites

On the **IIS host**:
- Windows with IIS and the **Management Scripts and Tools** feature: `Install-WindowsFeature Web-Scripting-Tools`. This provides the `root\WebAdministration` WMI namespace.
- OneAgent **1.285 or later** (Python extensions on OneAgent), with the **Extension Execution Controller (EEC)** enabled for the environment or host (Settings > Preferences > Extension Execution Controller).
- The EEC runs as LOCAL SYSTEM, which has the rights the script needs. PowerShell script execution is bypassed by the extension (`-ExecutionPolicy Bypass`), so no machine policy change is needed unless Group Policy enforces a policy.
- The filesystem holding OneAgent must not be mounted `noexec` (Linux only, not relevant on Windows).

On your **build machine**:
- Python 3.10 or 3.14 (Dynatrace recommends building with 3.14 as 3.10 reaches end of life in October 2026).
- `pip install "dt-extensions-sdk[cli]" dt`. The SDK's `build` and `gencerts` commands call the `dt` CLI, so `dt` must be on your PATH.
- A Dynatrace API token with **Write extensions** (`extensions.write`) and, to activate/configure through the API, **Read/Write extension monitoring configuration** scopes.

## 1. Create certificates (one time)

Dynatrace only runs **signed** extensions. You create your own certificate authority and use it to sign a developer certificate.

```bash
dt-sdk gencerts            # writes to ~/.dynatrace/certificates/
```

This produces:

| File | Purpose | Keep secret? |
|---|---|---|
| `ca.pem` | Root certificate, distributed to Dynatrace and OneAgent hosts | No |
| `ca.key` | Root private key, only needed to issue new developer certs | **Yes** |
| `developer.pem` | Developer certificate **and private key** (fused), used to sign builds | **Yes** |

Store `ca.key` and `developer.pem` somewhere safe (not in git). If `developer.pem` leaks, anyone can sign extensions your hosts will trust.

## 2. Trust the root certificate

The root certificate (`ca.pem`) must be trusted in two places. Do both before uploading or the upload and/or the host will reject the extension.

### 2a. In Dynatrace (credential vault)

1. Go to **Settings > Credential vault** (or the Credential vault app).
2. **Add new credential**, type **Public certificate**.
3. Scope: **Extension validation**.
4. Upload `ca.pem` and save.

Do this per environment (dev, prod, ...).

### 2b. On every OneAgent host that will run the extension

Copy `ca.pem` into the OneAgent certificate directory. It is commonly named `root.pem` in the docs, but any `.pem` filename works.

Windows (PowerShell, elevated):

```powershell
$dir = "$env:PROGRAMDATA\dynatrace\oneagent\agent\config\certificates"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item .\ca.pem "$dir\root.pem"
```

Linux equivalent (not needed for this IIS extension): `/var/lib/dynatrace/oneagent/agent/config/certificates/`.

The EEC runs as LOCAL SYSTEM and must be able to read the file. Default ProgramData permissions are usually fine. No OneAgent restart should be needed, but if the extension does not start, restart the OneAgent service once.

> Tip: roll this file out with your normal tooling (GPO, SCCM/Intune, Ansible) so new hosts get it automatically.

## 3. Build and sign

From the extension project folder (the one containing `setup.py`):

```bash
dt-sdk build . --python-version 3.10 --extra-platform win_amd64
# add  -k /path/to/developer.pem  if it is not in ~/.dynatrace/certificates/
```

- `--extra-platform win_amd64` downloads Windows wheels for dependencies. When building on a Mac or Linux box, add `--only-extra-platforms` to build only for Windows. This extension has no compiled dependencies beyond the SDK, so builds are small.
- `--python-version` is the Python version the wheels are downloaded for. It must match a Python that OneAgent's EEC bundles (3.10 or newer).
- The build creates the wheel, downloads dependencies, zips them with `extension.yaml` and `activationSchema.json`, then signs the archive.
- Output: `dist/custom_iis-site-status-0.0.1.zip` (the zip plus its signature).

**Increase `version:` in `extension/extension.yaml` for every change** (for example `0.0.2`). Dynatrace will not replace an already uploaded version.

I verified the build and signing end to end on a Mac using throwaway certificates (output zip contained the wheel with the PowerShell script, the SDK wheel, `extension.yaml` and `activationSchema.json`). I have not run it on a real Windows host with OneAgent.

## 4. Upload

```bash
export DT_API_URL="https://<environment-id>.live.dynatrace.com"   # or your Managed/ActiveGate URL
export DT_API_TOKEN="dt0c01.xxxxx"                                # token with extensions.write
dt-sdk upload dist/custom_iis-site-status-0.0.1.zip
```

If the upload fails with a signature or certificate error, 2a was not completed (or the zip was signed with a certificate that was not issued by the uploaded root).

## 5. Activate and configure

1. In Dynatrace open **Extensions** (Hub > Manage > Extensions), find **custom:iis-site-status**, and select **Add monitoring configuration**.
2. Pick the scope: individual hosts, a host group, a management zone, or the entire environment. Scope to your IIS hosts (a **host group** like `iis-servers` is the easiest to manage).
3. Set **Include application pools** and **PowerShell timeout**.
4. Save. The EEC on each in-scope host starts the extension within a few minutes.

## 6. Verify

- Data Explorer, query `custom.iis.site.up` split by `site`. Or run the DQL: `timeseries up = avg(custom.iis.site.up), by:{site, dt.entity.host}`.
- `custom.iis.collector.up` should be 1. If it is 0, check the EEC log on the host:
  `%PROGRAMDATA%\dynatrace\oneagent\log\extensions\` (the extension's log is under `extensions\...`, look for `iis_site_status`). The error from the script, including the PowerShell exit code and stderr, is logged there.
- Test by stopping a site (`Stop-Website -Name "Default Web Site"`) and confirm `custom.iis.site.up` drops to 0 within about 2 minutes. Start it again afterwards.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Upload rejected, signature invalid | Root certificate not in the credential vault with Extension validation scope, or signed by a different CA |
| Extension uploaded but never starts on the host | `ca.pem` missing from the host certificate directory, EEC disabled, or OneAgent older than 1.285 |
| `custom.iis.collector.up` = 0 | Script failed. Common: `Web-Scripting-Tools` not installed (`Invalid namespace` error), or timeout too short |
| No `custom.iis.*` data at all | Host out of the configuration scope, or the extension is waiting for the first minute to elapse |
| Metrics appear without a host entity | Check that OneAgent monitors the host in full-stack/infra mode |

## Local simulation

`dt-sdk run` runs the extension against `activation.json`. It needs `powershell.exe`, so it only produces data on Windows.

## Upgrading

1. Edit code, bump `version` in `extension/extension.yaml`.
2. `dt-sdk build .` then `dt-sdk upload dist/<new zip>`.
3. In the extension's page, update the monitoring configuration to the new version.

## Known unverified points

- I have not confirmed in Dynatrace documentation that a **local-only** Python extension may omit the `remote` activation block and the `pythonRemote` schema type. Community answers say this is valid. If the upload is rejected for a schema validation error, restore the `remote:` block in `extension.yaml` and a `pythonRemote` type in `activationSchema.json` from `dt-sdk create`'s template.
- The log location above is the usual OneAgent path. Verify it on your hosts.
