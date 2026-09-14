# =====================================================================
# Phase 0 - Create Hyper-V Internal Network
#
# Standalone copy of ../../scripts/00-create-network.ps1, duplicated here
# so this automation/ folder has no runtime dependency on the manual
# lab's scripts folder.
# =====================================================================

$SwitchName = "rke201-network"
$GatewayIP  = "172.30.170.1"
$Subnet     = "172.30.170.0/24"
$NatName    = "rke201-nat-network"

# ---------------------------------------------------------------------
# Create Internal Switch
# ---------------------------------------------------------------------

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue))
{
    Write-Host "Creating switch $SwitchName..."
    New-VMSwitch -Name $SwitchName -SwitchType Internal
}
else
{
    Write-Host "Switch already exists."
}

# ---------------------------------------------------------------------
# Configure Host-side Gateway
# ---------------------------------------------------------------------

$AdapterName = "vEthernet ($SwitchName)"

$Adapter = Get-NetAdapter |
    Where-Object Name -eq $AdapterName

if (-not $Adapter)
{
    throw "Unable to locate adapter $AdapterName"
}

if (-not (Get-NetIPAddress -IPAddress $GatewayIP -ErrorAction SilentlyContinue))
{
    Write-Host "Configuring gateway IP $GatewayIP..."

    New-NetIPAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -IPAddress $GatewayIP `
        -PrefixLength 24
}
else
{
    Write-Host "Gateway already configured."
}

# ---------------------------------------------------------------------
# Configure NAT
# ---------------------------------------------------------------------

if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue))
{
    Write-Host "Creating NAT..."

    New-NetNat `
        -Name $NatName `
        -InternalIPInterfaceAddressPrefix $Subnet
}
else
{
    Write-Host "NAT already exists."
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "===== Validation ====="

Get-VMSwitch -Name $SwitchName

Get-NetIPAddress |
    Where-Object IPAddress -eq $GatewayIP

Get-NetNat -Name $NatName

Write-Host ""
Write-Host "Gateway: $GatewayIP"
Write-Host "Subnet : $Subnet"
