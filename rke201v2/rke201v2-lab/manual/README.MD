# Introduction to `rke201v2-lab`
- This project is aim to setup a group of rke2 clusters named `rke201v2-lab`.

# Lab Environment Overview
## Lab Environment Information
This lab environment consists of two virtual linux machines running on an isolated network:
- Lab name: `rke201v2-lab`
- **RKE201-management**: This virtual machine (VM) provides services required for the Lab environment, such as DNS, NFS, and NTP. It is used as the entry point for the other VMs by providing a GUI.
    - 2vCPUs
    - 2GB RAM
    - 2 hard disks:
        - System hard disk: 40GB
        - NFS shared hard disk: 10GB
    - OS: openSUSE Leap 16.0 - GUI (similar: SUSE Linux Enterprise 16)
    - IP address: 172.30.170.2
    - Hostname: management.example.com
    - Iso file: \\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install.iso
- **RKE201-server**: The RKE2 server (control-plan) node.
    - 2vCPUs
    - 6GB RAM
    - 1 hard disk:
        - System hard disk: 40GB
    - IP address: 172.30.170.3
    - OS: openSUSE Leap 16.0 - headless (similar: SUSE Linux Enterprise 16)
    - Hostname: server.example.com
    - Iso file: \\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install.iso
- **RKE201-agent**: The RKE2 agent (worker) node.
    - 2vCPUs
    - 6GB RAM
    - 1 hard disk:
        - System hard disk: 40GB
    - IP address: 172.30.170.4
    - OS: openSUSE Leap 16.0 - headless (similar: SUSE Linux Enterprise 16)
    - Hostname: agent.example.com
    - Iso file: \\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install.iso

## Lab Environment Hardware/Software Requirements
The rke201v2-lab environment has been tested on a host:
- Host OS: Windows 11 Enterprise 23H2 (OS build 22631.7376)
- 12th Gen Intel Core i5-12500
- Cores: 6
- Logical processors: 12
- RAM: 32GB
- Hard Disk: 250 GB SSD
- Required at least:
    14GB of RAM (6 x 2 + 2)
    135GB of Hard disk space (40 x 3 + 10)
    
## Shared Account:
- fullname: `Tux Penguins`
- username: `tux`
- password: `linux`
    
## Required Minimum Product Version:
- Rancher Kubernetes Engine 2 (RKE2) v1.33
- Rancher Kubernetes Engine 2 (RKE2) v1.34 (practice upgrade)

## Network:
- SwitchName: `rke201-network`, internal isolated network.
- NAT Network Name: `rke201-nat-network` (acess)
- Isolated network 
- DHCP service is enabled and provided by the management VM. 
- DNS service is enabled and provided by the management VM. 
- NTP service is enabled and provided by the management VM. 
- Network address: 172.30.170.0/24 
- DHCP range: 172.30.170.2-172.30.170.254

# Phase 0: Virtual Machine Preparation
## Phase 0.0: Create DNS name at host windows machine.
- adding the below content to `C:\Windows\System32\drivers\etc\hosts` file on the Host Windows machine.
```ini
# rke201-lab cluster
# IP_ADDRESS FQDN SHORT_NAME
172.30.170.2 	management.example.com		management
172.30.170.3 	server.example.com			server
172.30.170.4	agent.example.com 			agent
```

### Verify: DNS Resolve
After saving hosts:
```ps1
ping server
ping server.example.com

ping agent
ping agent.example.com
```

You can also verify DNS resolution without pinging:
```ps1
Resolve-DnsName server
Resolve-DnsName server.example.com

```

## Phase 0.1: Create Virtual Network (Windows Host machine)
Create a private Internal switch with its own subnet (172.30.170.0/24) and NAT it through the host, instead of bridging to the corporate LAN. This sidesteps DHCP/IP-conflict risk and corporate NAC/802.1x port security entirely (no bridged VM MACs ever touch the physical wire), while still giving the VMs fully stable static IPs and internet access.
*Run once on the Hyper-V host*
**PowerShell (run as Administrator on the host):**
```ps1
# =====================================================================
# Phase 0 - Create Hyper-V Internal Network
# =====================================================================

$SwitchName = "rke201-network"
$GatewayIP  = "172.30.170.1"
$Subnet     = "172.30.170.0/24"
$NatName    = "rke201-nat-network"

# ---------------------------------------------------------------------
# Create Internal Switch
# ---------------------------------------------------------------------

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue))
{
    Write-Host "Creating switch $SwitchName..."
    New-VMSwitch -Name $SwitchName -SwitchType Internal
}
else
{
    Write-Host "Switch already exists."
}

# ---------------------------------------------------------------------
# Configure Host-side Gateway
# ---------------------------------------------------------------------

$AdapterName = "vEthernet ($SwitchName)"

$Adapter = Get-NetAdapter |
    Where-Object Name -eq $AdapterName

if (-not $Adapter)
{
    throw "Unable to locate adapter $AdapterName"
}

if (-not (Get-NetIPAddress -IPAddress $GatewayIP -ErrorAction SilentlyContinue))
{
    Write-Host "Configuring gateway IP $GatewayIP..."

    New-NetIPAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -IPAddress $GatewayIP `
        -PrefixLength 24
}
else
{
    Write-Host "Gateway already configured."
}

# ---------------------------------------------------------------------
# Configure NAT
# ---------------------------------------------------------------------

if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue))
{
    Write-Host "Creating NAT..."

    New-NetNat `
        -Name $NatName `
        -InternalIPInterfaceAddressPrefix $Subnet
}
else
{
    Write-Host "NAT already exists."
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "===== Validation ====="

Get-VMSwitch -Name $SwitchName

Get-NetIPAddress |
    Where-Object IPAddress -eq $GatewayIP

Get-NetNat -Name $NatName

Write-Host ""
Write-Host "Gateway: $GatewayIP"
Write-Host "Subnet : $Subnet"
```

### Verify: check virtual network created?
```ps1
Get-VMSwitch -Name "rke201-network"
Get-NetIPAddress | Where-Object IPAddress -eq "172.30.170.1"
Get-NetNat -Name "rke201-nat-network"
```

## Phase 0.2: Create All Linux RKE2 VMs on Hyper-V
### Method 1: Automate using powershell script.
**Hyper-V VM Creation Script**
```ps1
# =====================================================================
# Phase 1 - Create RKE2 VMs
# =====================================================================

$SwitchName = "rke201-network"

$ISOPath = "\\fs-22175.fs.local\d$\ISO\Leap-16.0-offline-installer-x86_64.install.iso"

# ---------------------------------------------------------------------
# VM Definitions
# ---------------------------------------------------------------------

$VMs = @(
    @{
        Name     = "RKE201-server"
        Hostname = "server.example.com"
        IP       = "172.30.170.3"
        CPU      = 2
        MemoryGB = 6
        DiskGB   = 40
    },
    @{
        Name     = "RKE201-agent"
        Hostname = "agent.example.com"
        IP       = "172.30.170.4"
        CPU      = 2
        MemoryGB = 6
        DiskGB   = 40
    }
)

# ---------------------------------------------------------------------
# Verify Network Exists
# ---------------------------------------------------------------------

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue))
{
    throw "Switch '$SwitchName' not found. Run Phase 0 first."
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
            -SwitchName $SwitchName

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
            -EnableSecureBoot On `
            -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

        Add-VMDvdDrive `
            -VMName $VMName `
            -Path $ISOPath

        $DVD = Get-VMDvdDrive -VMName $VMName

        Set-VMFirmware `
            -VMName $VMName `
            -FirstBootDevice $DVD

        Start-VM -Name $VMName

        Write-Host "$VMName created successfully."
    }
    else
    {
        Write-Host "$VMName already exists."
    }
}

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "=========================================================="
Write-Host "RKE2 Cluster VMs"
Write-Host "=========================================================="

$VMs | ForEach-Object {
    Write-Host ""
    Write-Host "Name      : $($_.Name)"
    Write-Host "Hostname  : $($_.Hostname)"
    Write-Host "IP        : $($_.IP)"
    Write-Host "vCPU      : $($_.CPU)"
    Write-Host "Memory    : $($_.MemoryGB) GB"
    Write-Host "Disk      : $($_.DiskGB) GB"
}

Write-Host ""
Write-Host "Gateway   : 172.30.170.1"
Write-Host "Network   : 172.30.170.0/24"
Write-Host "Switch    : $SwitchName"
```

### Issue: Failed to install the ISO Linux VM on Hyper-V under Generation-2.
**Solution:** To fix a Hyper-V virtual machine failing to boot or install from an LINUX ISO, disable Secure Boot in the VM's settings or switch to the Microsoft UEFI Certificate Authority template.
- Fix Secure Boot Issues (Generation 2 VMs):
    - Most installation failures on Generation 2 VMs happen because Secure Boot is turned on by default using a Windows template that blocks unsigned Linux bootloaders. 
        - Open Hyper-V Manager and turn off the virtual machine.
        - Right-click the VM and select Settings.
        - Go to Security under the hardware list.
        - Either uncheck "Enable Secure Boot" OR change the Secure Boot template from Microsoft Windows to Microsoft UEFI Certificate Authority.
        - Click Apply and start the virtual machine again.

### Verify: Checking if all VMs created:
```ps1
Get-VM
```

output:
```ps1
PS C:\repo-mes\kubernetes-university> Get-VM

Name          State   CPUUsage(%) MemoryAssigned(M) Uptime           Status             Version
----          -----   ----------- ----------------- ------           ------             -------
opensuse-leap Off     0           0                 00:00:00         Operating normally 11.0   
RKE201-agent  Running 0           6144              00:14:25.9710000 Operating normally 11.0   
RKE201-server Running 0           6144              00:14:05.5100000 Operating normally 11.0   


PS C:\repo-mes\kubernetes-university> 
```

## Phase 0.3: Buil the based OS VM
### 0.3.1 Start boosting and install the based OS linux of openSUSE.
-  rke201-server
    - hostname: `server`
    - fqdn: `server.example.com`
    - ip address: 172.30.170.3
    - fullname: `Tux Penguins`
    - username: `tux`
    - password: `linux`
    - Timezone: Americas-Detroit (America/Detroit UTC-4)
-  rke201-agent
    - hostname: `agent`
    - fqdn: `agent.example.com`
    - ip address: 172.30.170.4
    - fullname: `Tux Penguins`
    - username: `tux`
    - password: `linux`
### 0.3.2 Validate and Check hostname
1. Set and validate `hostname` and FQND full qualified domain name.
- Check host name `> hostnamectl`
```bash
tux@server:~> hostnamectl 
 Static hostname: server
       Icon name: computer-vm
         Chassis: vm 🖴
      Machine ID: 0982055bbbf74d08a82a957d11ebcea3
         Boot ID: d42610a938084988a09741067f751f2d
  Virtualization: microsoft
Operating System: openSUSE Leap 16.0              
     CPE OS Name: cpe:/o:opensuse:leap:16.0
          Kernel: Linux 6.12.0-160000.35-default
    Architecture: x86-64
 Hardware Vendor: Microsoft Corporation
  Hardware Model: Virtual Machine
Firmware Version: Hyper-V UEFI Release v4.1
   Firmware Date: Wed 2025-12-03
    Firmware Age: 9month 1w
tux@server:~> 
```

- check hostname domain: `> cat /etc/hosts`
```ini
tux@server:~> cat /etc/hosts
#
# hosts         This file describes a number of hostname-to-address
#               mappings for the TCP/IP subsystem.  It is mostly
#               used at boot time, when no name servers are running.
#               On small systems, this file can be used instead of a
#               "named" name server.
# Syntax:
#    
# IP-Address  Full-Qualified-Hostname  Short-Hostname
#

127.0.0.1       localhost localhost.localdomain
::1             localhost localhost.localdomain ipv6-localhost ipv6-loopback

# special IPv6 addresses
fe00::0         ipv6-localnet

ff00::0         ipv6-mcastprefix
ff02::1         ipv6-allnodes
ff02::2         ipv6-allrouters
ff02::3         ipv6-allhosts

172.30.170.2 management.example.com     management
172.30.170.3 server.example.com         server
172.30.170.4 agent.example.com          agent

tux@server:~> 
```
### 0.3.3 Set Static IP Address
#### Verify `IP Address` and `Network Connection name`
- Find the `network connection name` by command 
```bash
nmcli connection show
```
**What to looking for:** expect to see `Wired Connection 1 ... ethernet eth0`

```bash
tux@server:~> nmcli connection show
NAME                UUID                                  TYPE      DEVICE 
Wired connection 1  8a184382-23fb-30b7-8782-d2de6159bc6d  ethernet  eth0   
lo                  8d120563-7030-4ee8-8aeb-6437c1fa5ee7  loopback  lo     
tux@server:~> 
```

- Find the IP address by command 
```bash
ip address show # or `ip a`
```
**What to look for:** expect to see `2: eth0: ... inet 172.30.170.3/24` or the corresponding IP.

**Example:**
```bash
tux@server:~> ip address show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host noprefixroute 
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:15:5d:34:57:0b brd ff:ff:ff:ff:ff:ff
    altname enx00155d34570b
    inet 172.30.170.3/24 brd 172.30.170.255 scope global noprefixroute eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::d4be:5d05:2d75:bed5/64 scope link noprefixroute 
       valid_lft forever preferred_lft forever
tux@server:~> 
```

#### Method 1: Using the Command Line (nmcli)
- Command to change to a static IP
- rke201-server: 172.30.170.3
- rke201-agent: 172.30.170.4
```sh
sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 172.30.170.3/24 \
  ipv4.gateway 172.30.170.1 \
  ipv4.dns "8.8.8.8,8.8.4.4"
```
- Apply the change
```bash
sudo nmcli connection up "Wired connection 1"
```

#### Method 2: Using the Text-Based User Interface (`nmtui`)
If you prefer a visual menu inside the terminal, you can use the built-in NetworkManager utility. 
- Open the utility by running: 
```bash
sudo nmtui
```

- Select Edit a connection using the arrow keys and press Enter.
- Choose your network interface from the list and select Edit.
- Go down to IPv4 CONFIGURATION and switch it from <Automatic> to <Manual> (or vice versa).
- Select <Show> next to IPv4 configuration to fill out your Addresses, Gateway, and DNS servers.Scroll down, select <OK>, and then select <Back>.
- Choose Activate a connection, select your interface, and hit Enter twice to deactivate and reactivate it to apply the new IP.

#### Method 3: Editing the Configuration File Directly
NetworkManager in openSUSE Leap 16.0 stores connection parameters as `.nmconnection` files.
1. Navigate to the connections directory:
```bash
cd /etc/NetworkManager/system-connections/
```

2. Locate the file corresponding to your connection (e.g., `Wired connection 1.nmconnection`) and open it with a text editor:
```bash
sudo nano "Wired connection 1.nmconnection"
```

3. Locate the `[ipv4]` section. Modify it to match either a manual configuration or automatic DHCP:For Static IP:
```ini
[ipv4]
method=manual
address1=192.168.1.100/24,192.168.1.1
dns=8.8.8.8;8.8.4.4;
```

For DHCP:
```ini
[ipv4]
method=auto

```

4. Save the file (Ctrl+O, then Ctrl+X in nano) and reload NetworkManager to apply:
```bash
sudo systemctl reload NetworkManager
```

5. Verify:
```bash
ip address show
ip a
```

### 0.3.4 Install and verify OpenSSH server
needed to manage each VM remotely from the Windows host once its static IP is set — otherwise you're stuck working through the Hyper-V console window.
- Check if `openSSH` installed?
```bash
systemctl status sshd
```

```bash
tux@server:~> systemctl status sshd
sshd.service - OpenSSH Daemon
    Loaded: loaded (/usr/lib/systemd/system/sshd.service; disabled; preset: disabled)
    Active: inactived (dead)
```

- Install `openSSH` if missing
```bash
sudo zypper install openssh
```

- Start the openSSH Daemon:
```bash
sudo systemctl enable --now sshd
```

**What to look for:** A status showing Loaded: loaded... confirms the software installation. If it says Active: `active (running) since ...`, the service is currently running

### Add all cluster nodes + hostname to `/etc/hosts`
```ini
# rke201-lab cluster
# IP_ADDRESS FQDN SHORT_NAME
172.30.170.2 	management.example.com		management
172.30.170.3 	server.example.com			server
172.30.170.4	agent.example.com 			agent
```

### Vefify: Checking all Linux OS setup successfully.
from host Windows machine
1. check DNS resolve
```ps1
Resolve-Dnsname server
Resolve-Dnsname agent
```

2. check ssh
```ps1
ssh tux@server
ssh tux@agent
```



