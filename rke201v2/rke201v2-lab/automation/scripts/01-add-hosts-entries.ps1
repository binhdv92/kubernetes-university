# =====================================================================
# Phase 0.0 - Add rke201-lab DNS entries to the Windows hosts file
#
# Automates what the main README documents as a manual edit. Idempotent:
# skips if the "# rke201-lab cluster" marker is already present, so
# re-running this never duplicates entries.
# =====================================================================

$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$Marker    = "# rke201-lab cluster"

$Block = @"

$Marker
# IP_ADDRESS FQDN SHORT_NAME
172.30.170.2 	management.example.com		management
172.30.170.3 	server.example.com			server
172.30.170.4	agent.example.com 			agent
"@

$ExistingContent = Get-Content -Path $HostsPath -Raw -ErrorAction SilentlyContinue

if ($ExistingContent -and $ExistingContent.Contains($Marker))
{
    Write-Host "rke201-lab entries already present in $HostsPath - skipping."
}
else
{
    Add-Content -Path $HostsPath -Value $Block
    Write-Host "Added rke201-lab entries to $HostsPath."
}

# ---------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "===== Validation ====="
Resolve-DnsName management -ErrorAction SilentlyContinue
Resolve-DnsName server -ErrorAction SilentlyContinue
Resolve-DnsName agent -ErrorAction SilentlyContinue
