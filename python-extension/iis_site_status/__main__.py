"""Dynatrace Extensions 2.0 (Python) extension that reports IIS site status.

Runs locally inside OneAgent on the IIS host. Every minute, `query()` runs the
bundled Get-IISSiteStatus.ps1 script through PowerShell, parses its JSON output
and reports the result as Dynatrace metrics.

Metrics (gauges):
    custom.iis.site.up         dims: site, site_id   1 if Started, else 0
    custom.iis.site.state      dims: site, site_id   0 Starting, 1 Started,
                                                     2 Stopping, 3 Stopped, 4 Unknown
    custom.iis.apppool.up      dims: apppool         same, per app pool
    custom.iis.apppool.state   dims: apppool         (only when include_app_pools is on)
    custom.iis.collector.up    (no dims)             1 if the script ran, 0 if it failed
"""

import json
import subprocess
from pathlib import Path

from dynatrace_extension import Extension, Status, StatusValue

SCRIPT = Path(__file__).parent / "Get-IISSiteStatus.ps1"

# Same mapping as the PowerShell script returns in its State field
STATE_CODES = {"Starting": 0, "Started": 1, "Stopping": 2, "Stopped": 3, "Unknown": 4}


class ExtensionImpl(Extension):
    def query(self):
        """Scheduled automatically every minute by the SDK."""
        # activation_config holds the "pythonLocal" settings from the monitoring configuration
        include_pools = bool(self.activation_config.get("includeAppPools", True))
        timeout = int(self.activation_config.get("timeoutSeconds", 30))

        try:
            items = self._run_script(include_pools, timeout)
        except Exception as e:  # report failure as a metric so it can be alerted on
            self.logger.error(f"IIS status collection failed: {e}")
            self.report_metric("custom.iis.collector.up", 0)
            return

        self.report_metric("custom.iis.collector.up", 1)

        for item in items:
            code = STATE_CODES.get(item.get("State"), 4)
            up = 1 if code == 1 else 0

            if item.get("Type") == "Site":
                dims = {"site": item["Name"], "site_id": str(item["Id"])}
                self.report_metric("custom.iis.site.up", up, dimensions=dims)
                self.report_metric("custom.iis.site.state", code, dimensions=dims)
            elif item.get("Type") == "AppPool":
                dims = {"apppool": item["Name"]}
                self.report_metric("custom.iis.apppool.up", up, dimensions=dims)
                self.report_metric("custom.iis.apppool.state", code, dimensions=dims)

    def _run_script(self, include_pools: bool, timeout: int) -> list:
        """Run the PowerShell collector and return its output as a list of dicts."""
        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", str(SCRIPT),
            "-Json",
        ]
        if include_pools:
            cmd.append("-IncludeAppPools")

        self.logger.debug(f"Running: {' '.join(cmd)}")
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"powershell exited {proc.returncode}: {proc.stderr.strip()}")
        if proc.stderr.strip():
            # The script writes per-machine problems as warnings and still exits 0
            self.logger.warning(proc.stderr.strip())

        out = proc.stdout.strip()
        if not out:
            return []  # no sites found
        data = json.loads(out)
        # ConvertTo-Json emits a bare object, not a list, when there is only one result
        return data if isinstance(data, list) else [data]

    def fastcheck(self) -> Status:
        """Not executed for OneAgent extensions; kept for ActiveGate compatibility."""
        return Status(StatusValue.OK)


def main():
    ExtensionImpl(name="iis_site_status").run()


if __name__ == "__main__":
    main()
