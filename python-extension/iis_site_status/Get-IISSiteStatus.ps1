<#
.SYNOPSIS
    Reports IIS site status (and optionally app pool state) via WMI/CIM.

.DESCRIPTION
    Queries the root\WebAdministration namespace (the IIS WMI provider) and
    returns one object per IIS site, with its current state and bindings.

    How it works:
      1. For each target computer, open a CIM session (skipped for the local machine).
      2. Enumerate the "Site" WMI class to get every IIS site.
      3. Call each site's GetState() method to get its live run state. The state
         is not a property on the class, it can only be read by calling the method.
      4. Translate the numeric state to a name and flatten the bindings to a string.
      5. Optionally repeat steps 2-4 for the "ApplicationPool" class.

    Requirements:
      - IIS "Management Scripts and Tools" feature (Web-Scripting-Tools) on the
        target. This is what registers the root\WebAdministration namespace.
      - An elevated PowerShell session (local admin on the target for remote use).

.PARAMETER ComputerName
    One or more machines to query. Defaults to the local computer.

.PARAMETER Credential
    Credential used for remote machines. Ignored for the local computer.

.PARAMETER IncludeAppPools
    Also report the state of each IIS application pool.

.PARAMETER Json
    Emit JSON instead of PowerShell objects (useful for piping to other tools).

.EXAMPLE
    .\Get-IISSiteStatus.ps1
    .\Get-IISSiteStatus.ps1 -ComputerName web01,web02 -Credential (Get-Credential)
    .\Get-IISSiteStatus.ps1 -IncludeAppPools | Format-Table -AutoSize
    .\Get-IISSiteStatus.ps1 -Json
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [pscredential]$Credential,
    [switch]$IncludeAppPools,
    [switch]$Json
)

# WMI namespace exposed by the IIS WMI provider
$ns = 'root\WebAdministration'

# Site.GetState() / ApplicationPool.GetState() return a numeric code; map it to text
$stateNames = @{ 0 = 'Starting'; 1 = 'Started'; 2 = 'Stopping'; 3 = 'Stopped'; 4 = 'Unknown' }

# Names that mean "this machine", so we can skip creating a remote CIM session
$localNames = @($env:COMPUTERNAME, 'localhost', '.')

$results = foreach ($computer in $ComputerName) {
    $session = $null
    try {
        # Common parameters for every Get-CimInstance call against this computer
        $params = @{ Namespace = $ns; ErrorAction = 'Stop' }

        # Remote machine: open a CIM session (WS-Man) and reuse it for all queries.
        # Local machine: no session needed, query WMI directly.
        if ($computer -notin $localNames) {
            $sessParams = @{ ComputerName = $computer; ErrorAction = 'Stop' }
            if ($Credential) { $sessParams.Credential = $Credential }
            $session = New-CimSession @sessParams
            $params.CimSession = $session
        }

        # --- Sites ---------------------------------------------------------
        foreach ($site in Get-CimInstance @params -ClassName Site) {
            # Run-state is only available by invoking the GetState() method
            $state = Invoke-CimMethod -InputObject $site -MethodName GetState

            # Each binding looks like "http://*:80:example.com"; join them into one string
            $binds = ($site.Bindings | ForEach-Object { "$($_.Protocol)://$($_.BindingInformation)" }) -join '; '

            [pscustomobject]@{
                Computer = $computer
                Type     = 'Site'
                Name     = $site.Name
                Id       = $site.Id
                State    = $stateNames[[int]$state.ReturnValue]
                Bindings = $binds
            }
        }

        # --- Application pools (optional) ----------------------------------
        if ($IncludeAppPools) {
            foreach ($pool in Get-CimInstance @params -ClassName ApplicationPool) {
                $state = Invoke-CimMethod -InputObject $pool -MethodName GetState
                [pscustomobject]@{
                    Computer = $computer
                    Type     = 'AppPool'
                    Name     = $pool.Name
                    Id       = $null      # app pools have no numeric ID
                    State    = $stateNames[[int]$state.ReturnValue]
                    Bindings = $null      # bindings only apply to sites
                }
            }
        }
    }
    catch {
        # One unreachable machine shouldn't stop the others
        Write-Warning "[$computer] $($_.Exception.Message)"
    }
    finally {
        # Always release the remote session
        if ($session) { Remove-CimSession $session }
    }
}

# Output either as objects (default) or JSON
if ($Json) { $results | ConvertTo-Json -Depth 3 } else { $results }
