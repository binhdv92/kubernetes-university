# =====================================================================
# Phase 0 (undo) - Remove Hyper-V Internal Network
#
# Uninstall counterpart to 00-create-network_rke201-network.ps1.
# Removes, in reverse dependency order: the NAT, the host-side gateway
# IP, then the internal switch itself.
# =====================================================================

$SwitchName = "rke201-network"
$GatewayIP  = "172.30.170.1"
$NatName    = "rke201-nat-network"

# ---------------------------------------------------------------------
# Remove NAT
# ---------------------------------------------------------------------

if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)
{
    Write-Host "Removing NAT $NatName..."
    Remove-NetNat -Name $NatName -Confirm:$false
}
else
{
    Write-Host "NAT $NatName does not exist - skipping."
}

# ---------------------------------------------------------------------
# Remove Host-side Gateway IP
# ---------------------------------------------------------------------

$AdapterName = "vEthernet ($SwitchName)"

$Adapter = Get-NetAdapter |
    Where-Object Name -eq $AdapterName

if ($Adapter)
{
    if (Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $GatewayIP -ErrorAction SilentlyContinue)
    {
        Write-Host "Removing gateway IP $GatewayIP..."

        Remove-NetIPAddress `
            -InterfaceIndex $Adapter.ifIndex `
            -IPAddress $GatewayIP `
            -Confirm:$false
    }
    else
    {
        Write-Host "Gateway IP not configured - skipping."
    }
}
else
{
    Write-Host "Adapter $AdapterName not found - skipping gateway IP removal."
}

# ---------------------------------------------------------------------
# Remove Internal Switch
# ---------------------------------------------------------------------

if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)
{
    Write-Host "Removing switch $SwitchName..."
    Remove-VMSwitch -Name $SwitchName -Force
}
else
{
    Write-Host "Switch does not exist."
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "===== Validation ====="

Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
Get-NetIPAddress -IPAddress $GatewayIP -ErrorAction SilentlyContinue
Get-NetNat -Name $NatName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. $SwitchName, its gateway IP, and $NatName have been removed (if they existed)."
