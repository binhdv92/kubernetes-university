# =====================================================================
# Build one OEMDRV-labeled ISO per Agama profile.
#
# Agama (openSUSE Leap 16.0's installer) does NOT auto-detect an OEMDRV
# volume - it must be told where the profile is via the "inst.auto="
# kernel boot parameter, added manually at the GRUB boot menu (see
# automation/README.md and 03-create-vms-unattended.ps1). Agama's own
# "label://" file reader does
# NOT understand Joliet the way GRUB/the Linux kernel's iso9660 driver
# do - it looks up the exact literal filename in the plain ISO9660 tree.
# The previous IMAPI2FS-based build (ISO9660 + Joliet) wrote the real
# name only in the Joliet tree, leaving a mangled short name like
# "PROFIL~1.JSO;1" in the plain tree - Agama reported "File not found
# /profile.json" as a result, even though the file was genuinely on the
# disc. Building with oscdimg's "-n -d" (long + lowercase names
# directly in the primary ISO9660 tree, no Joliet needed) fixes this,
# exactly like the equivalent fix for the installer ISO's grub.cfg/
# marker file lookups.
#
# Requires oscdimg.exe (Windows ADK "Deployment Tools" feature):
# https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
# =====================================================================

$AgamaDir  = Join-Path $PSScriptRoot "..\agama"
$OutputDir = Join-Path $PSScriptRoot "..\oemdrv-iso"

$Profiles = @(
    @{ Role = "management"; Json = "management.json" },
    @{ Role = "server";     Json = "server.json" },
    @{ Role = "agent";      Json = "agent.json" }
)

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

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function New-OemdrvIso
{
    param(
        [Parameter(Mandatory)] [string]$ProfilePath,
        [Parameter(Mandatory)] [string]$OutputIsoPath
    )

    if (-not (Test-Path $ProfilePath))
    {
        throw "Agama profile not found: $ProfilePath"
    }

    $StagingDir = Join-Path $env:TEMP "oemdrv-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

    try
    {
        Copy-Item -Path $ProfilePath -Destination (Join-Path $StagingDir "profile.json")

        if (Test-Path $OutputIsoPath)
        {
            Remove-Item -Force $OutputIsoPath
        }

        & $Oscdimg -m -n -d -lOEMDRV $StagingDir $OutputIsoPath

        if ($LASTEXITCODE -ne 0)
        {
            throw "oscdimg failed with exit code $LASTEXITCODE while building $OutputIsoPath"
        }
    }
    finally
    {
        Remove-Item -Recurse -Force $StagingDir -ErrorAction SilentlyContinue
    }
}

foreach ($P in $Profiles)
{
    $ProfilePath  = Join-Path $AgamaDir $P.Json
    $OutputIsoPath = Join-Path $OutputDir "$($P.Role)-oemdrv.iso"

    Write-Host "Building $OutputIsoPath from $ProfilePath..."
    New-OemdrvIso -ProfilePath $ProfilePath -OutputIsoPath $OutputIsoPath
    Write-Host "  done."
}

Write-Host ""
Write-Host "OEMDRV ISOs built in: $OutputDir"
Get-ChildItem $OutputDir | Format-Table Name, Length
