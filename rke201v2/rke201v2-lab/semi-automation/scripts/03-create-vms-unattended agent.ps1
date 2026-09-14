# =====================================================================
# Create all 3 rke201v2-lab VMs and boot them toward the unattended Agama
# install, using the REAL, UNMODIFIED Leap 16.0 installer ISO (no ISO
# rebuild - that approach was tried and abandoned after several
# low-level bugs). One manual step per VM is still required at boot -
# see the instructions this script prints at the end - because Agama
# has no OEMDRV-style auto-detection; it needs an inst.auto= kernel
# boot parameter, and typing it into the installer ISO's GRUB config
# reliably (without editing the ISO itself) isn't possible.
#
# Prerequisites (all within this automation/ folder):
#   - Hyper-V switch/NAT already created (00-create-network.ps1)
#   - Leap 16.0 installer ISO copied to a LOCAL path on this host (see
#     $InstallerIsoPath below - environment-specific, adjust if needed)
#   - OEMDRV ISOs already built (02-build-oemdrv-isos.ps1)
# =====================================================================

$SwitchName = "rke201-network"

# Local path - Hyper-V's VM Management Service runs as a machine identity that
# generally can't authenticate to a remote SMB share (a "double-hop"/logon-type
# failure), even when your own interactive session can reach it fine. Copy the
# ISO here first; see automation/README.md for details.
#
# Resolved via GetFullPath (not just Join-Path) because Hyper-V normalizes
# attached DVD paths internally - Get-VMDvdDrive later returns the collapsed
# form, so comparing against an unresolved "...\..\..." string would never
# match even though the drive attached correctly.
$InstallerIsoPath = [System.IO.Path]::GetFullPath("C:\HyperV\iso\Leap-16.0-offline-installer-x86_64.install.iso")
$OemdrvIsoDir     = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\oemdrv-iso"))

# ---------------------------------------------------------------------
# VM Definitions
# ---------------------------------------------------------------------

$VMs = @(
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

        # DVD 2: OEMDRV volume with the Agama profile.json - still needs the
        # inst.auto=label://OEMDRV/profile.json boot parameter added manually
        # at the GRUB menu (see the instructions this script prints at the end)
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

$BootParam = "inst.auto=label://OEMDRV/profile.json rd.neednet=0 inst.install=1"

try
{
    Set-Clipboard -Value " $BootParam"
    Write-Host ""
    Write-Host "Your clipboard now holds the boot parameter text (see below) -"
    Write-Host "ready to paste via VMConnect's Clipboard menu."
}
catch
{
    Write-Host ""
    Write-Host "Could not set the clipboard automatically ($($_.Exception.Message))."
    Write-Host "Copy this text yourself: $BootParam"
}

Write-Host ""
Write-Host "ACTION NEEDED for each VM - Agama has no OEMDRV auto-detection, so"
Write-Host "connect to each VM's console in Hyper-V Manager and, at the GRUB"
Write-Host "boot menu:"
Write-Host "  1. Select 'Install Leap 16.0 (x86_64)' (the DEFAULT entry, not"
Write-Host "     'Failsafe') and press 'e' to edit it"
Write-Host "  2. Arrow down to the 'linux (...)' line, then press End"
Write-Host "  3. In the VM Connection window's menu bar: Clipboard >"
Write-Host "     Type Clipboard Text  (do NOT use Ctrl+V - it won't work here)"
Write-Host "  4. Press Ctrl-X (or F10) to boot"
Write-Host ""
Write-Host "The pasted text is identical for all 3 VMs - each VM's own OEMDRV"
Write-Host "disc supplies its own profile.json automatically."
Write-Host ""
Write-Host "Then run 04-wait-for-ssh.ps1 to know when each VM is ready to SSH into."
