# =====================================================================
# Poll each VM's static IP on port 22 until SSH answers, so you know
# the unattended AutoYaST install (partition, install, reboot) has
# finished without having to watch the Hyper-V console the whole time.
# =====================================================================

param(
    [int]$TimeoutMinutes = 30,
    [int]$PollIntervalSeconds = 15
)

$Targets = @(
    @{ Name = "RKE201-management"; IP = "172.30.170.2" },
    @{ Name = "RKE201-server";     IP = "172.30.170.3" },
    @{ Name = "RKE201-agent";      IP = "172.30.170.4" }
)

$Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$Pending  = $Targets.Clone()

Write-Host "Waiting for SSH (port 22) on: $($Pending.Name -join ', ')"

while ($Pending.Count -gt 0 -and (Get-Date) -lt $Deadline)
{
    foreach ($Target in @($Pending))
    {
        $Result = Test-NetConnection -ComputerName $Target.IP -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet

        if ($Result)
        {
            Write-Host "$($Target.Name) ($($Target.IP)) is reachable on port 22."
            $Pending = $Pending | Where-Object { $_.Name -ne $Target.Name }
        }
    }

    if ($Pending.Count -gt 0)
    {
        Write-Host "Still waiting on: $($Pending.Name -join ', ') ..."
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

Write-Host ""
if ($Pending.Count -eq 0)
{
    Write-Host "All VMs are reachable over SSH. Try:"
    Write-Host "  ssh tux@management"
    Write-Host "  ssh tux@server"
    Write-Host "  ssh tux@agent"
}
else
{
    Write-Host "Timed out after $TimeoutMinutes minute(s) waiting on: $($Pending.Name -join ', ')"
    Write-Host "Check the Hyper-V console for each VM - it may still be mid-install, or a manual prompt may be blocking it."
}
