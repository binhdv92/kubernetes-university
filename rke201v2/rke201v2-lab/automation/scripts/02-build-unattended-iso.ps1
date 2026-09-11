# =====================================================================
# Rebuild the Leap 16.0 installer ISO with "inst.auto=label://OEMDRV/
# profile.json" baked into its default GRUB boot entry, so Agama loads
# the unattended profile automatically on its own - no manual GRUB edit
# needed at boot at all.
#
# One patched ISO is built once and reused as the boot DVD for all 3
# VMs; each VM still gets its own separate OEMDRV DVD (built by
# 03-build-oemdrv-isos.ps1) with its own profile.json - only the
# install-time boot parameter is baked in here, nothing role-specific.
#
# Requires oscdimg.exe (Windows ADK "Deployment Tools" feature):
# https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
# =====================================================================

$SourceIsoPath = "C:\HyperV\iso\Leap-16.0-offline-installer-x86_64.install.iso"
$OutputIsoPath = Join-Path $PSScriptRoot "..\patched-iso\leap-16.0-unattended.iso"
$ScratchDir    = Join-Path $PSScriptRoot "..\_scratch\iso-build"
$GrubParam     = "inst.auto=label://OEMDRV/profile.json"

# ---------------------------------------------------------------------
# Locate oscdimg.exe
# ---------------------------------------------------------------------

$OscdimgCandidates = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
)

$Oscdimg = $OscdimgCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $Oscdimg)
{
    $Cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($Cmd) { $Oscdimg = $Cmd.Source }
}

if (-not $Oscdimg)
{
    throw "oscdimg.exe not found. Install the Windows ADK 'Deployment Tools' feature first: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install"
}

Write-Host "Using oscdimg: $Oscdimg"

if (-not (Test-Path $SourceIsoPath))
{
    throw "Source installer ISO not found: $SourceIsoPath"
}

# ---------------------------------------------------------------------
# 1. Extract the El Torito boot images (BIOS + UEFI) directly from the
#    source ISO's own boot catalog, so the rebuilt ISO is bootable the
#    same way the original is - no guessing at file paths.
# ---------------------------------------------------------------------

function Get-ElToritoBootImages
{
    param(
        [Parameter(Mandatory)] [string]$IsoPath,
        [Parameter(Mandatory)] [string]$BiosOutPath,
        [Parameter(Mandatory)] [string]$UefiOutPath
    )

    $SectorSize = 2048
    $Stream = [System.IO.File]::OpenRead($IsoPath)

    try
    {
        function Read-Sector([System.IO.FileStream]$S, [long]$SectorNum)
        {
            $S.Seek($SectorNum * $SectorSize, [System.IO.SeekOrigin]::Begin) | Out-Null
            $Buf = New-Object byte[] $SectorSize
            $S.Read($Buf, 0, $Buf.Length) | Out-Null
            return $Buf
        }

        function Copy-Range([System.IO.FileStream]$S, [long]$Offset, [long]$Length, [string]$OutPath)
        {
            $S.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $Buf = New-Object byte[] $Length
            $TotalRead = 0
            while ($TotalRead -lt $Length)
            {
                $Read = $S.Read($Buf, $TotalRead, $Length - $TotalRead)
                if ($Read -le 0) { break }
                $TotalRead += $Read
            }
            [System.IO.File]::WriteAllBytes($OutPath, $Buf)
        }

        $Brvd = Read-Sector $Stream 17
        $BootSystemId = [System.Text.Encoding]::ASCII.GetString($Brvd, 7, 23)

        if ($BootSystemId -ne "EL TORITO SPECIFICATION")
        {
            throw "Source ISO has no El Torito boot record - cannot rebuild a bootable ISO from it."
        }

        $CatalogLBA = [BitConverter]::ToUInt32($Brvd, 71)
        $Catalog = Read-Sector $Stream $CatalogLBA

        # Default/Initial entry (BIOS), 32 bytes after the 32-byte validation entry
        $DefSectorCount = [BitConverter]::ToUInt16($Catalog, 32 + 6)
        $DefLoadRBA     = [BitConverter]::ToUInt32($Catalog, 32 + 8)
        Copy-Range $Stream ([long]$DefLoadRBA * $SectorSize) ([long]$DefSectorCount * 512) $BiosOutPath

        # Walk section headers looking for platform 0xEF (EFI/UEFI)
        $Pos = 64
        $UefiFound = $false

        while ($Pos -lt $SectorSize)
        {
            $HdrIndicator = $Catalog[$Pos]
            if ($HdrIndicator -ne 0x90 -and $HdrIndicator -ne 0x91) { break }

            $SectionPlatform = $Catalog[$Pos + 1]
            $NumEntries      = [BitConverter]::ToUInt16($Catalog, $Pos + 2)

            if ($SectionPlatform -eq 0xEF -and $NumEntries -ge 1)
            {
                $EntryOff     = $Pos + 32
                $ESectorCount = [BitConverter]::ToUInt16($Catalog, $EntryOff + 6)
                $ELoadRBA     = [BitConverter]::ToUInt32($Catalog, $EntryOff + 8)
                Copy-Range $Stream ([long]$ELoadRBA * $SectorSize) ([long]$ESectorCount * 512) $UefiOutPath
                $UefiFound = $true
            }

            if ($HdrIndicator -eq 0x91) { break }
            $Pos = $Pos + 32 + ($NumEntries * 32)
        }

        if (-not $UefiFound)
        {
            throw "Could not find a UEFI (platform 0xEF) boot entry in the source ISO's boot catalog."
        }
    }
    finally
    {
        $Stream.Close()
    }
}

# Windows' Get-Volume/WMI FileSystemLabel truncates ISO9660 labels to 16
# characters (e.g. "Install-Leap-16." instead of the real
# "Install-Leap-16.0-x86_64"). dracut's live-root detection looks for
# /dev/disk/by-label/<full label>, so an oscdimg rebuild using the
# truncated label produces an ISO dracut can never find, dropping to a
# "dracut:/#" emergency shell. Read the Volume Identifier directly from
# the ISO9660 Primary Volume Descriptor (always at LBA 16, offset 40,
# 32 bytes, space-padded) instead, to get the untruncated label.
function Get-Iso9660VolumeLabel
{
    param(
        [Parameter(Mandatory)] [string]$IsoPath
    )

    $Stream = [System.IO.File]::OpenRead($IsoPath)

    try
    {
        $Stream.Seek(16L * 2048, [System.IO.SeekOrigin]::Begin) | Out-Null
        $Pvd = New-Object byte[] 2048
        $Stream.Read($Pvd, 0, $Pvd.Length) | Out-Null
        return [System.Text.Encoding]::ASCII.GetString($Pvd, 40, 32).TrimEnd(' ')
    }
    finally
    {
        $Stream.Close()
    }
}

if (Test-Path $ScratchDir)
{
    Remove-Item -Recurse -Force $ScratchDir
}

New-Item -ItemType Directory -Force -Path $ScratchDir | Out-Null

$BiosBootImage = Join-Path $ScratchDir "bios-boot.img"
$UefiBootImage = Join-Path $ScratchDir "uefi-boot.img"

Write-Host "Extracting BIOS/UEFI boot images from the source ISO..."
Get-ElToritoBootImages -IsoPath $SourceIsoPath -BiosOutPath $BiosBootImage -UefiOutPath $UefiBootImage

# ---------------------------------------------------------------------
# 2. Extract the full file tree from the source ISO
# ---------------------------------------------------------------------

$StagingDir = Join-Path $ScratchDir "files"
New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

$VolumeLabel = Get-Iso9660VolumeLabel -IsoPath $SourceIsoPath
Write-Host "Source volume label: $VolumeLabel"

Write-Host "Mounting source ISO..."
$Mount = Mount-DiskImage -ImagePath $SourceIsoPath -PassThru
$Volume = $Mount | Get-Volume
$DriveLetter = $Volume.DriveLetter

try
{
    Write-Host "Copying files from ${DriveLetter}: to $StagingDir (large ISO - this can take a while)..."
    $RobocopyArgs = @("${DriveLetter}:\", $StagingDir, "/E", "/COPY:DAT", "/R:1", "/W:1", "/MT:8", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/NP")
    & robocopy @RobocopyArgs | Out-Null

    if ($LASTEXITCODE -ge 8)
    {
        throw "robocopy failed with exit code $LASTEXITCODE while copying the ISO's files."
    }
}
finally
{
    Dismount-DiskImage -ImagePath $SourceIsoPath | Out-Null
}

# ---------------------------------------------------------------------
# 3. Patch the default install entry's kernel command line
# ---------------------------------------------------------------------

$GrubCfgPath = Join-Path $StagingDir "boot\grub2\grub.cfg"

if (-not (Test-Path $GrubCfgPath))
{
    throw "Expected GRUB config not found at $GrubCfgPath - this source ISO's layout may differ from what this script expects."
}

# Files copied out of an ISO come back read-only
Set-ItemProperty -Path $GrubCfgPath -Name IsReadOnly -Value $false

$Content = Get-Content -Path $GrubCfgPath -Raw

if ($Content -match [regex]::Escape($GrubParam))
{
    Write-Host "GRUB config already contains '$GrubParam' - leaving as-is."
}
else
{
    $Pattern = '(linux \(\$root\)/boot/x86_64/loader/linux \$\{extra_cmdline\} \$\{isoboot\} splash=silent)'

    if ($Content -notmatch $Pattern)
    {
        throw "Could not find the expected default install boot line in $GrubCfgPath to patch - the ISO's grub.cfg layout may have changed."
    }

    $NewContent = $Content -replace $Pattern, "`$1 $GrubParam"
    Set-Content -Path $GrubCfgPath -Value $NewContent -NoNewline
    Write-Host "Patched $GrubCfgPath - default install entry now boots with $GrubParam"
}

# ---------------------------------------------------------------------
# 4. Rebuild a hybrid BIOS+UEFI bootable ISO with oscdimg
#
# Plain ISO9660 with long+lowercase names (-n -d), no Joliet, no UDF:
# the source ISO is plain ISO9660 (with Rock Ridge, standard for
# Linux-authored media, giving GRUB/dracut exact lowercase filenames).
# oscdimg can't produce Rock Ridge, so without -n/-d the ISO9660 view
# gets 8.3-mangled all-caps names and GRUB can't find files like
# /boot/0xc28b255e or /boot/grub2/grub.cfg by their real names (drops to
# a "grub>" rescue prompt). -n/-d fix that directly on the primary
# ISO9660 volume - no Joliet needed. This also matters for the volume
# label: dracut's live-root detection looks for
# /dev/disk/by-label/<full label>, but oscdimg caps Joliet's volume
# label at 16 characters (silently truncated by Windows' own
# Get-Volume too), while the primary ISO9660 label allows up to 32 -
# our label is 24 characters, so Joliet would have broken it even if
# used only for filenames.
# ---------------------------------------------------------------------

$OutputDir = Split-Path $OutputIsoPath -Parent
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (Test-Path $OutputIsoPath)
{
    Remove-Item -Force $OutputIsoPath
}

$BootData = "2#p0,e,b`"$BiosBootImage`"#pEF,e,b`"$UefiBootImage`""

$OscdimgArgs = @(
    "-m", "-o", "-n", "-d",
    "-l$VolumeLabel",
    "-bootdata:$BootData",
    $StagingDir,
    $OutputIsoPath
)

Write-Host "Running oscdimg (this can take a few minutes for a multi-GB ISO)..."
& $Oscdimg @OscdimgArgs

if ($LASTEXITCODE -ne 0)
{
    throw "oscdimg failed with exit code $LASTEXITCODE"
}

# oscdimg forces the ISO9660 Primary Volume Descriptor's Volume Identifier
# to uppercase (strict spec compliance), but the real vendor label is
# mixed-case and dracut's live-root search is case-sensitive - so
# surgically overwrite just that 32-byte field (LBA 16, offset 40) with
# the real label. blkid/dracut read this field directly, so this alone
# is enough to fix /dev/disk/by-label/<label> detection; nothing else in
# the volume needs to change.
Write-Host "Restoring exact-case volume label (oscdimg forces uppercase)..."
$LabelBytes = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $LabelBytes[$i] = 0x20 }
$LabelSourceBytes = [System.Text.Encoding]::ASCII.GetBytes($VolumeLabel)
[Array]::Copy($LabelSourceBytes, $LabelBytes, $LabelSourceBytes.Length)

$IsoStream = [System.IO.File]::Open($OutputIsoPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
try
{
    $IsoStream.Seek((16L * 2048) + 40, [System.IO.SeekOrigin]::Begin) | Out-Null
    $IsoStream.Write($LabelBytes, 0, $LabelBytes.Length)
    $IsoStream.Flush()
}
finally
{
    $IsoStream.Close()
}

Remove-Item -Recurse -Force $ScratchDir -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Unattended installer ISO built: $OutputIsoPath"
Write-Host "Next: run 03-build-oemdrv-isos.ps1 (per-VM profile discs), then 04-create-vms-unattended.ps1."
