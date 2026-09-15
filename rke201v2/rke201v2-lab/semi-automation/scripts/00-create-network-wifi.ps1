# =====================================================================
# Phase 0 (external) - Create Hyper-V External Networks
#
# Bridges Hyper-V virtual switches directly to physical NICs (wired and
# Wi-Fi) so VMs attached to one get a real IP straight from your
# router's DHCP, instead of going through the rke201-network NAT. Only
# needed if something outside this Hyper-V host must reach a VM
# directly - the existing rke201-nat-network already gives every VM
# outbound internet access without this.
#
# Creates two separate switches, one per physical adapter, so you can
# attach a VM to whichever one is actually connected:
#   rke201-network-wired - bridged to the wired Ethernet adapter
#   rke201-network-wifi  - bridged to the Wi-Fi adapter
#
# Unlike the Internal switch, these need NO gateway IP or NAT config of
# their own - the physical network's router already provides both.
#
# Only an adapter with Status "Up" can actually be bridged - typically
# only one of the two (wired/Wi-Fi) is connected at a time. This script
# skips (warns, doesn't fail) whichever adapter isn't currently up, so
# it still succeeds for whichever one is.
#
# List available adapter names/status with:
#   Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, LinkSpeed, MacAddress -AutoSize
# =====================================================================

$ExternalSwitches = @(
    @{ SwitchName = "rke201-network-wifi";  PhysicalAdapterName = "Wi-Fi" }
)

foreach ($Net in $ExternalSwitches)
{
    $SwitchName          = $Net.SwitchName
    $PhysicalAdapterName = $Net.PhysicalAdapterName

    Write-Host ""
    Write-Host "----- $SwitchName (adapter: '$PhysicalAdapterName') -----"

    if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)
    {
        Write-Host "Switch already exists - skipping."
        continue
    }

    $PhysicalAdapter = Get-NetAdapter -Name $PhysicalAdapterName -ErrorAction SilentlyContinue

    if (-not $PhysicalAdapter)
    {
        Write-Warning "Adapter '$PhysicalAdapterName' not found - skipping $SwitchName. Run Get-NetAdapter to see available names."
        continue
    }

    if ($PhysicalAdapter.Status -ne "Up")
    {
        Write-Warning "Adapter '$PhysicalAdapterName' is not connected (Status: $($PhysicalAdapter.Status)) - skipping $SwitchName."
        continue
    }

    # -AllowManagementOS keeps the host itself online through this adapter
    # (Hyper-V creates a vEthernet adapter for the host to keep using it).
    # Expect a brief (few second) network drop on the host while this runs.
    Write-Host "Creating external switch $SwitchName on '$PhysicalAdapterName'..."
    Write-Host "(the host's network connection may briefly drop during this step)"

    New-VMSwitch `
        -Name $SwitchName `
        -NetAdapterName $PhysicalAdapterName `
        -AllowManagementOS $true
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "===== Validation ====="

foreach ($Net in $ExternalSwitches)
{
    Get-VMSwitch -Name $Net.SwitchName -ErrorAction SilentlyContinue |
        Format-List Name, SwitchType, NetAdapterInterfaceDescription
}

Write-Host ""
Write-Host "Next: attach a VM's network adapter to whichever switch actually got created, e.g.:"
Write-Host "  Get-VMNetworkAdapter -VMName RKE201-management | Connect-VMNetworkAdapter -SwitchName 'rke201-network-wifi'"
Write-Host "Then verify inside the VM: ip address show / ip a"
