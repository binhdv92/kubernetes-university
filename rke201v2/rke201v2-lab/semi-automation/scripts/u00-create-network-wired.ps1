# =====================================================================
# Phase 0 (external, undo) - Remove Hyper-V External Network (wired)
#
# Uninstall counterpart to 00-create-network-wired.ps1. Removing the
# switch automatically un-bridges the physical adapter and restores it
# to normal (non-bridged) operation - there's no gateway IP or NAT to
# clean up separately, unlike the Internal switch teardown.
# =====================================================================

$SwitchName = "rke201-network-wired"

# ---------------------------------------------------------------------
# Remove External Switch
# ---------------------------------------------------------------------

if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)
{
    Write-Host "Removing switch $SwitchName..."
    Write-Host "(the host's network connection may briefly drop while the physical adapter un-bridges)"
    Remove-VMSwitch -Name $SwitchName -Force
}
else
{
    Write-Host "Switch does not exist."
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "===== Validation ====="

Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. $SwitchName has been removed (if it existed)."
