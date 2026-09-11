# =====================================================================
# Build one OEMDRV-labeled ISO per Agama profile.
#
# Agama (openSUSE Leap 16.0's installer) does NOT auto-detect an OEMDRV
# volume - it must be told where the profile is via the "inst.auto="
# kernel boot parameter (see 03-create-vms-unattended.ps1's guidance and
# automation/README.md). Agama does support "label://OEMDRV/profile.json"
# as a location, so we still deliver the profile on an OEMDRV-labeled
# ISO - it's just no longer auto-detected on its own. This script builds
# that small ISO for each role using the built-in IMAPI2FS Windows COM
# API, so no extra tool (oscdimg, ADK, etc.) needs to be installed on
# the Hyper-V host.
# =====================================================================

$AgamaDir  = Join-Path $PSScriptRoot "..\agama"
$OutputDir = Join-Path $PSScriptRoot "..\oemdrv-iso"

$Profiles = @(
    @{ Role = "management"; Json = "management.json" },
    @{ Role = "server";     Json = "server.json" },
    @{ Role = "agent";      Json = "agent.json" }
)

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# IMAPI2FS hands back the finished image as a raw COM IStream. PowerShell's
# late-bound COM wrapper can't marshal that to another COM object (ADODB.Stream
# fails with "method not found"), so pull it out via .NET's interop-defined
# IStream instead - this is the standard, proven technique for this API.
if (-not ("Rke201.IsoFile" -as [type]))
{
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace Rke201
{
    public static class IsoFile
    {
        public static void Create(string path, object imageStream)
        {
            var stream = (IStream)imageStream;
            const int BlockSize = 65536;
            byte[] buffer = new byte[BlockSize];
            IntPtr bytesReadPtr = Marshal.AllocHGlobal(sizeof(int));

            try
            {
                using (var fs = File.Create(path))
                {
                    while (true)
                    {
                        stream.Read(buffer, BlockSize, bytesReadPtr);
                        int bytesRead = Marshal.ReadInt32(bytesReadPtr);
                        if (bytesRead <= 0) break;
                        fs.Write(buffer, 0, bytesRead);
                    }
                    fs.Flush();
                }
            }
            finally
            {
                Marshal.FreeHGlobal(bytesReadPtr);
            }
        }
    }
}
'@
}

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

        $Image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $Image.VolumeName = "OEMDRV"
        $Image.FileSystemsToCreate = 3   # ISO9660 (1) + Joliet (2)

        $Image.Root.AddTree($StagingDir, $false)

        $Result = $Image.CreateResultImage()

        if (Test-Path $OutputIsoPath)
        {
            Remove-Item -Force $OutputIsoPath
        }

        [Rke201.IsoFile]::Create($OutputIsoPath, $Result.ImageStream)
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
