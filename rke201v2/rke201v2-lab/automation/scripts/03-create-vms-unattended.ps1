# =====================================================================
# Create all 3 rke201v2-lab VMs and boot them toward a fully unattended
# Agama install (no manual installer clicks, no manual hostname/static-IP
# /SSH setup afterwards) - just one GRUB boot-parameter keystroke per VM,
# see the summary this script prints at the end.
#
# Prerequisites (all within this automation/ folder):
#   - Hyper-V switch/NAT already created (00-create-network.ps1)
#   - OEMDRV ISOs already built (02-build-oemdrv-isos.ps1)
#   - Leap 16.0 installer ISO copied to a LOCAL path on this host (see
#     $InstallerIsoPath below - this is environment-specific, adjust it if
#     the ISO lives somewhere else on this machine)
# =====================================================================

$SwitchName = "rke201-network"

# Local path - Hyper-V's VM Management Service runs as a machine identity that
# generally can't authenticate to a remote SMB share (a "double-hop"/logon-type
# failure), even when your own interactive session can reach it fine. Copy the
# ISO here first; see automation/README.md for details.
$InstallerIsoPath = "C:\HyperV\iso\Leap-16.0-offline-installer-x86_64.install.iso"
$OemdrvIsoDir     = Join-Path $PSScriptRoot "..\oemdrv-iso"

# ---------------------------------------------------------------------
# VM Definitions
# ---------------------------------------------------------------------

$VMs = @(
    @{
        Name         = "RKE201-management"
        Role         = "management"
        Hostname     = "management.example.com"
        IP           = "172.30.170.2"
        CPU          = 2
        MemoryGB     = 2
        DiskGB       = 40
        SecondDiskGB = 10
    },
    @{
        Name     = "RKE201-server"
        Role     = "server"
        Hostname = "server.example.com"
        IP       = "172.30.170.3"
        CPU      = 2
        MemoryGB = 6
        DiskGB   = 40
    },
    @{
        Name     = "RKE201-agent"
        Role     = "agent"
        Hostname = "agent.example.com"
        IP       = "172.30.170.4"
        CPU      = 2
        MemoryGB = 6
        DiskGB   = 40
    }
)

# ---------------------------------------------------------------------
# Verify Prerequisites
# ---------------------------------------------------------------------

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue))
{
    throw "Switch '$SwitchName' not found. Run 00-create-network.ps1 first."
}

if (-not (Test-Path $InstallerIsoPath))
{
    throw "Installer ISO not found at $InstallerIsoPath. Copy the Leap 16.0 installer ISO to this local path first (see automation/README.md)."
}

foreach ($VM in $VMs)
{
    $OemdrvIsoPath = Join-Path $OemdrvIsoDir "$($VM.Role)-oemdrv.iso"
    if (-not (Test-Path $OemdrvIsoPath))
    {
        throw "OEMDRV ISO not found: $OemdrvIsoPath. Run 02-build-oemdrv-isos.ps1 first."
    }
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
            -SwitchName $SwitchName `
            -ErrorAction Stop

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
            -EnableSecureBoot Off `
            -SecureBootTemplate "MicrosoftUEFICertificateAuthority" `
            -ErrorAction Stop

        if ($VM.SecondDiskGB)
        {
            $SecondVHDPath = "$VHDPath\$VMName-data.vhdx"
            New-VHD -Path $SecondVHDPath -SizeBytes ($VM.SecondDiskGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null
            Add-VMHardDiskDrive -VMName $VMName -Path $SecondVHDPath -ErrorAction Stop
        }

        # DVD 1: Leap 16.0 installer (boot device)
        Add-VMDvdDrive `
            -VMName $VMName `
            -Path $InstallerIsoPath `
            -ErrorAction Stop

        # DVD 2: OEMDRV volume with the Agama profile.json (needs inst.auto=
        # label://OEMDRV/profile.json typed at the GRUB menu - see below)
        Add-VMDvdDrive `
            -VMName $VMName `
            -Path (Join-Path $OemdrvIsoDir "$($VM.Role)-oemdrv.iso") `
            -ErrorAction Stop

        # Identify the installer drive by path rather than position/order, so a
        # partial attach failure can never silently make the wrong (non-bootable)
        # drive "first" - it fails loudly here instead.
        $InstallerDvd = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $InstallerIsoPath }

        if (-not $InstallerDvd)
        {
            throw "Could not find the installer DVD drive on $VMName after attaching it - Add-VMDvdDrive may have failed."
        }

        Set-VMFirmware `
            -VMName $VMName `
            -FirstBootDevice $InstallerDvd `
            -ErrorAction Stop

        Start-VM -Name $VMName

        Write-Host "$VMName created and booting into the unattended install."
    }
    else
    {
        Write-Host "$VMName already exists - skipping."
    }
}

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "=========================================================="
Write-Host "RKE2 Cluster VMs (unattended)"
Write-Host "=========================================================="

$VMs | ForEach-Object {
    Write-Host ""
    Write-Host "Name      : $($_.Name)"
    Write-Host "Hostname  : $($_.Hostname)"
    Write-Host "IP        : $($_.IP)"
    Write-Host "vCPU      : $($_.CPU)"
    Write-Host "Memory    : $($_.MemoryGB) GB"
    Write-Host "Disk      : $($_.DiskGB) GB$(if ($_.SecondDiskGB) { " + $($_.SecondDiskGB) GB" })"
}

Write-Host ""
Write-Host "Gateway   : 172.30.170.1"
Write-Host "Network   : 172.30.170.0/24"
Write-Host "Switch    : $SwitchName"
Write-Host ""
Write-Host "ACTION NEEDED for each VM: Agama (the Leap 16.0 installer) has no"
Write-Host "auto-detection - connect to each VM's console in Hyper-V Manager,"
Write-Host "and at the GRUB boot menu:"
Write-Host "  1. Press 'e' to edit the default entry"
Write-Host "  2. Append to the end of the 'linux' line:"
Write-Host "       inst.auto=label://OEMDRV/profile.json"
Write-Host "  3. Press Ctrl-X (or F10) to boot"
Write-Host "From that point on the install is fully unattended."
Write-Host ""
Write-Host "Then run 04-wait-for-ssh.ps1 to know when each VM is ready to SSH into."
