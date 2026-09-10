# Introduction
- This project is aim to setup a group of rke2 clusters.

# Virtual Machines
- iso:
    - openSUSE Leap 16.0 (similar: SUSE Linux Enterprise 16)
    - iso file: Leap-16.0-offline-installer-x86_64.install 
    - \\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install
- shared account:
    - username: `tux`
    - password: `linux`
- Hyper-V VMs 
    - RKE201-management
        2vCPUs
        2GB RAM
        2 hard disks:
            System hard disk: 40GB
            NFS shared hard disk: 10GB
        OS: openSUSE Leap 16.0 (similar: SUSE Linux Enterprise 16)
        IP address: 172.30.170.2
        Hostname: management.example.com
    - RKE201-server: The RKE2 server (control-plan) node.
        2vCPUs
        6GB RAM
        1 hard disk:
            System hard disk: 40GB
        IP address: 172.30.170.3
        OS: openSUSE Leap 16.0 - headless (similar: SUSE Linux Enterprise 16)
        Hostname: server.example.com
        Iso file: \\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install.iso

    - RKE201-agent: The RKE2 agent (worker) node.
        2vCPUs
        6GB RAM
        1 hard disk:
            System hard disk: 40GB
        IP address: 172.30.170.4
        OS: openSUSE Leap 16.0 - headless (similar: SUSE Linux Enterprise 16)
        Hostname: agent.example.com
        Iso file: \\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install.iso

## Required Minimum Product Version
- Rancher Kubernetes Engine 2 (RKE2) v1.33
- Rancher Kubernetes Engine 2 (RKE2) v1.34 (practice upgrade)

## Network:
- rke201-network 
- Isolated network 
- DHCP service is enabled and provided by the management VM. 
- DNS service is enabled and provided by the management VM. 
- NTP service is enabled and provided by the management VM. 
- Network address: 172.30.170.0/24 
- DHCP range: 172.30.170.2-172.30.170.254


# Phase 0: Create Internal Network + NAT
Create a private Internal switch with its own subnet (172.30.170.0/24) and NAT it through the host, instead of bridging to the corporate LAN. This sidesteps DHCP/IP-conflict risk and corporate NAC/802.1x port security entirely (no bridged VM MACs ever touch the physical wire), while still giving the VMs fully stable static IPs and internet access.
*Run once on the Hyper-V host*
**PowerShell (run as Administrator on the host):**
```ps1
# =====================================================================
# Phase 0 - Create Hyper-V Internal Network
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
```

# Phase 1: Create All RKE2 VMs on Hyper-V
## Method 1: Automate using powershell script.
**Hyper-V VM Creation Script**
```ps1
# =====================================================================
# Phase 1 - Create RKE2 VMs
# =====================================================================

$SwitchName = "rke201-network"

$ISOPath = "\\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install.iso"

# ---------------------------------------------------------------------
# VM Definitions
# ---------------------------------------------------------------------

$VMs = @(
    @{
        Name     = "RKE201-server"
        Hostname = "server.example.com"
        IP       = "172.30.170.3"
        CPU      = 2
        MemoryGB = 6
        DiskGB   = 40
    },
    @{
        Name     = "RKE201-agent"
        Hostname = "agent.example.com"
        IP       = "172.30.170.4"
        CPU      = 2
        MemoryGB = 6
        DiskGB   = 40
    }
)

# ---------------------------------------------------------------------
# Verify Network Exists
# ---------------------------------------------------------------------

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue))
{
    throw "Switch '$SwitchName' not found. Run Phase 0 first."
}

# ---------------------------------------------------------------------
# Create VMs
# ---------------------------------------------------------------------

foreach ($VM in $VMs)
{
    $VMName = $VM.Name

    Write-Host ""
    Write-Host "Creating $VMName..."

    $BasePath     = "C:\HyperV\$VMName"
    $SnapshotPath = Join-Path $BasePath "Snapshots"
    $VHDPath      = Join-Path $BasePath "Virtual Hard Disks"
    $VMPath       = Join-Path $BasePath "Virtual Machines"

    New-Item -ItemType Directory -Force -Path $SnapshotPath | Out-Null
    New-Item -ItemType Directory -Force -Path $VHDPath      | Out-Null
    New-Item -ItemType Directory -Force -Path $VMPath       | Out-Null

    if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue))
    {
        New-VM `
            -Name $VMName `
            -Generation 2 `
            -MemoryStartupBytes ($VM.MemoryGB * 1GB) `
            -Path $VMPath `
            -NewVHDPath "$VHDPath\$VMName.vhdx" `
            -NewVHDSizeBytes ($VM.DiskGB * 1GB) `
            -SwitchName $SwitchName

        Set-VMProcessor `
            -VMName $VMName `
            -Count $VM.CPU

        Set-VMMemory `
            -VMName $VMName `
            -DynamicMemoryEnabled $false

        Set-VM `
            -Name $VMName `
            -CheckpointType Disabled

        Set-VM `
            -Name $VMName `
            -AutomaticStopAction ShutDown

        Set-VMFirmware `
            -VMName $VMName `
            -EnableSecureBoot On `
            -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

        Add-VMDvdDrive `
            -VMName $VMName `
            -Path $ISOPath

        $DVD = Get-VMDvdDrive -VMName $VMName

        Set-VMFirmware `
            -VMName $VMName `
            -FirstBootDevice $DVD

        Start-VM -Name $VMName

        Write-Host "$VMName created successfully."
    }
    else
    {
        Write-Host "$VMName already exists."
    }
}

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "=========================================================="
Write-Host "RKE2 Cluster VMs"
Write-Host "=========================================================="

$VMs | ForEach-Object {
    Write-Host ""
    Write-Host "Name      : $($_.Name)"
    Write-Host "Hostname  : $($_.Hostname)"
    Write-Host "IP        : $($_.IP)"
    Write-Host "vCPU      : $($_.CPU)"
    Write-Host "Memory    : $($_.MemoryGB) GB"
    Write-Host "Disk      : $($_.DiskGB) GB"
}

Write-Host ""
Write-Host "Gateway   : 172.30.170.1"
Write-Host "Network   : 172.30.170.0/24"
Write-Host "Switch    : $SwitchName"
```

## Issue: Failed to install the ISO Linux VM on Hyper-V under Generation-2.
**Solution:** To fix a Hyper-V virtual machine failing to boot or install from an LINUX ISO, disable Secure Boot in the VM's settings or switch to the Microsoft UEFI Certificate Authority template.
- Fix Secure Boot Issues (Generation 2 VMs):
    - Most installation failures on Generation 2 VMs happen because Secure Boot is turned on by default using a Windows template that blocks unsigned Linux bootloaders. 
        - Open Hyper-V Manager and turn off the virtual machine.
        - Right-click the VM and select Settings.
        - Go to Security under the hardware list.
        - Either uncheck "Enable Secure Boot" OR change the Secure Boot template from Microsoft Windows to Microsoft UEFI Certificate Authority.
        - Click Apply and start the virtual machine again.
