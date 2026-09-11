# =====================================================================
# Remove everything 00-04 created, to get a clean slate on this host.
#
# By default this removes: the 3 VMs (stopped first if running) plus
# their files under C:\HyperV\<name>, and the generated OEMDRV ISOs.
#
# It leaves the Hyper-V switch/NAT and the Windows hosts-file entries in
# place by default, since those can be shared with the manual lab method
# (../scripts/00-create-network.ps1 uses the same switch name) or other
# VMs on this host:
#   -RemoveHostsEntries   also removes the rke201-lab block from the
#                         Windows hosts file (safe/precise - it only
#                         removes the exact lines 01-add-hosts-entries.ps1
#                         added)
#   -RemoveNetwork        also removes the "rke201-network" switch and
#                         "rke201-nat-network" NAT (WARNING: shared -
#                         only pass this if nothing else uses them)
#   -Force                skip the confirmation prompt
#
# Usage:
#   .\99-uninstall.ps1
#   .\99-uninstall.ps1 -RemoveHostsEntries
#   .\99-uninstall.ps1 -RemoveNetwork -RemoveHostsEntries -Force
# =====================================================================

param(
    [switch]$RemoveNetwork,
    [switch]$RemoveHostsEntries,
    [switch]$Force
)

$SwitchName   = "rke201-network"
$NatName      = "rke201-nat-network"
$VMNames      = @("RKE201-management", "RKE201-server", "RKE201-agent")
$OemdrvIsoDir = Join-Path $PSScriptRoot "..\oemdrv-iso"
$HostsPath    = "$env:SystemRoot\System32\drivers\etc\hosts"
$Marker       = "# rke201-lab cluster"

# ---------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------

if (-not $Force)
{
    Write-Host "This will remove:"
    $VMNames | ForEach-Object { Write-Host "  - VM '$_' and C:\HyperV\$_" }
    Write-Host "  - Generated OEMDRV ISOs under $OemdrvIsoDir"

    if ($RemoveHostsEntries)
    {
        Write-Host "  - The rke201-lab block from $HostsPath"
    }

    if ($RemoveNetwork)
    {
        Write-Host "  - Hyper-V switch '$SwitchName' and NAT '$NatName'"
        Write-Host "    WARNING: shared with the manual lab method and any other VM attached to it."
    }

    Write-Host ""
    $Confirm = Read-Host "Type 'yes' to continue"

    if ($Confirm -ne "yes")
    {
        Write-Host "Aborted - nothing was removed."
        return
    }
}

# ---------------------------------------------------------------------
# Remove VMs and their files
# ---------------------------------------------------------------------

foreach ($VMName in $VMNames)
{
    $VM = Get-VM -Name $VMName -ErrorAction SilentlyContinue

    if ($VM)
    {
        if ($VM.State -ne "Off")
        {
            Write-Host "Stopping $VMName..."
            Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Removing VM $VMName..."
        Remove-VM -Name $VMName -Force
    }
    else
    {
        Write-Host "$VMName does not exist - skipping."
    }

    $BasePath = "C:\HyperV\$VMName"

    if (Test-Path $BasePath)
    {
        Write-Host "Deleting $BasePath..."
        Remove-Item -Recurse -Force $BasePath
    }
}

# ---------------------------------------------------------------------
# Remove generated OEMDRV ISOs
# ---------------------------------------------------------------------

if (Test-Path $OemdrvIsoDir)
{
    Write-Host "Deleting $OemdrvIsoDir..."
    Remove-Item -Recurse -Force $OemdrvIsoDir
}
else
{
    Write-Host "$OemdrvIsoDir does not exist - skipping."
}

# ---------------------------------------------------------------------
# Optional: remove hosts-file entries
# ---------------------------------------------------------------------

if ($RemoveHostsEntries)
{
    $Lines = Get-Content -Path $HostsPath -ErrorAction SilentlyContinue

    if ($Lines -and ($Lines -match [regex]::Escape($Marker)))
    {
        Write-Host "Removing rke201-lab entries from $HostsPath..."

        $KnownIPs = @("172.30.170.2", "172.30.170.3", "172.30.170.4")

        $Filtered = $Lines | Where-Object {
            $Line = $_.Trim()
            $IsMarker  = $Line -eq $Marker
            $IsHeader  = $Line -eq "# IP_ADDRESS FQDN SHORT_NAME"
            $IsKnownIP = [bool]($KnownIPs | Where-Object { $Line.StartsWith($_) })
            -not ($IsMarker -or $IsHeader -or $IsKnownIP)
        }

        Set-Content -Path $HostsPath -Value $Filtered
    }
    else
    {
        Write-Host "No rke201-lab entries found in $HostsPath - skipping."
    }
}

# ---------------------------------------------------------------------
# Optional: remove the switch/NAT
# ---------------------------------------------------------------------

if ($RemoveNetwork)
{
    if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)
    {
        Write-Host "Removing NAT $NatName..."
        Remove-NetNat -Name $NatName -Confirm:$false
    }
    else
    {
        Write-Host "NAT $NatName does not exist - skipping."
    }

    if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)
    {
        Write-Host "Removing switch $SwitchName..."
        Remove-VMSwitch -Name $SwitchName -Force
    }
    else
    {
        Write-Host "Switch $SwitchName does not exist - skipping."
    }
}

Write-Host ""
Write-Host "Done. Re-run 00-create-network.ps1 through 05-wait-for-ssh.ps1 for a fresh install."
