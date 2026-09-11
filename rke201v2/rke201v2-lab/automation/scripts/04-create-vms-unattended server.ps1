# =====================================================================
# Create all 3 rke201v2-lab VMs and boot them into a fully unattended
# Agama install - zero manual interaction, since the installer ISO
# already has inst.auto=label://OEMDRV/profile.json baked into its
# default GRUB entry (see 02-build-unattended-iso.ps1).
#
# Prerequisites (all within this automation/ folder):
#   - Hyper-V switch/NAT already created (00-create-network.ps1)
#   - Unattended installer ISO already built (02-build-unattended-iso.ps1)
#   - OEMDRV ISOs already built (03-build-oemdrv-isos.ps1)
# =====================================================================

$SwitchName = "rke201-network"

# Built by 02-build-unattended-iso.ps1 from the real Leap 16.0 installer
# ISO, with the inst.auto= boot parameter already baked in - see that
# script and automation/README.md for details.
#
# Resolved via GetFullPath (not just Join-Path) because Hyper-V normalizes
# attached DVD paths internally - Get-VMDvdDrive later returns the collapsed
# form, so comparing against an unresolved "...\..\..." string would never
# match even though the drive attached correctly.
$InstallerIsoPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\patched-iso\leap-16.0-unattended.iso"))
$OemdrvIsoDir     = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\oemdrv-iso"))

# ---------------------------------------------------------------------
# VM Definitions
# ---------------------------------------------------------------------

$VMs = @(
    @{
        Name     = "RKE201-server"
        Role     = "server"
        Hostname = "server.example.com"
        IP       = "172.30.170.3"
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
    throw "Unattended installer ISO not found at $InstallerIsoPath. Run 02-build-unattended-iso.ps1 first."
}

foreach ($VM in $VMs)
{
    $OemdrvIsoPath = Join-Path $OemdrvIsoDir "$($VM.Role)-oemdrv.iso"
    if (-not (Test-Path $OemdrvIsoPath))
    {
        throw "OEMDRV ISO not found: $OemdrvIsoPath. Run 03-build-oemdrv-isos.ps1 first."
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

        # DVD 2: OEMDRV volume with the Agama profile.json - the boot DVD's
        # own GRUB config already points inst.auto= at this, no typing needed
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
Write-Host "No manual interaction needed - the installer ISO already boots"
Write-Host "straight into the unattended Agama install for each VM."
Write-Host ""
Write-Host "Then run 05-wait-for-ssh.ps1 to know when each VM is ready to SSH into."
