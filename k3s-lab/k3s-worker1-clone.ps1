Export-VM -Name "k3s-master1" -Path "C:\temp"

Import-VM -Path "C:\temp\k3s-master1\Virtual Machines\D4527012-B1B7-4EF6-951D-DF235E3BA8B0.vmcx" `
  -Copy -GenerateNewId `
  -VirtualMachinePath "C:\hyperv\vms\k3s-worker2" `
  -VhdDestinationPath "C:\hyperv\vms\k3s-worker2\Virtual Hard Disks"

Rename-VM -Name "k3s-master1" -NewName "k3s-worker2"