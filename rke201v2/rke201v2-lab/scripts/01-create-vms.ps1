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