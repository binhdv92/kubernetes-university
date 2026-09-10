# =====================================================================
# Build one OEMDRV-labeled ISO per AutoYaST profile.
#
# openSUSE's installer (YaST) auto-detects a second CD/DVD volume whose
# label is exactly "OEMDRV" and containing an "autoinst.xml" at its root,
# and uses it as the unattended install profile - no boot parameter
# needed. This script builds that small ISO for each role using the
# built-in IMAPI2FS Windows COM API, so no extra tool (oscdimg, ADK, etc.)
# needs to be installed on the Hyper-V host.
# =====================================================================

$AutoyastDir = Join-Path $PSScriptRoot "..\autoyast"
$OutputDir   = Join-Path $PSScriptRoot "..\oemdrv-iso"

$Profiles = @(
    @{ Role = "management"; Xml = "management.xml" },
    @{ Role = "server";     Xml = "server.xml" },
    @{ Role = "agent";      Xml = "agent.xml" }
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
        throw "AutoYaST profile not found: $ProfilePath"
    }

    $StagingDir = Join-Path $env:TEMP "oemdrv-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

    try
    {
        Copy-Item -Path $ProfilePath -Destination (Join-Path $StagingDir "autoinst.xml")

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
    $ProfilePath  = Join-Path $AutoyastDir $P.Xml
    $OutputIsoPath = Join-Path $OutputDir "$($P.Role)-oemdrv.iso"

    Write-Host "Building $OutputIsoPath from $ProfilePath..."
    New-OemdrvIso -ProfilePath $ProfilePath -OutputIsoPath $OutputIsoPath
    Write-Host "  done."
}

Write-Host ""
Write-Host "OEMDRV ISOs built in: $OutputDir"
Get-ChildItem $OutputDir | Format-Table Name, Length
