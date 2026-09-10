
# Instroduction
- This project is aim to setup a group of kubernetes (k3s) and managed by Rancher.

# Architecture

rancher url: https://rancher-mes.firstsolar.com


## virtual machines
- iso: ubuntu-24.04.4-live-server-amd64.iso
- shared account:
    - fullname: k3sadmin
    - username: k3sadmin
    - password: k3sadmin@123
- Hyper-V VMs (12 GB of RAM, 8 CPU cores)
    k3s-master1, 4GB RAM, 4 CPUs, 40GB
        IPv4: 10.10.10.11
    k3s-worker1, 4GB RAM, 2 CPUs, 40GB
        IPv4: 10.10.10.12
    k3s-worker2, 4GB RAM, 2 CPUs, 40GB
        IPv4: 10.10.10.13

## networking
- Dev lab cluster, no IT-assigned IPs. VMs live on a private Hyper-V **Internal** switch
  (`10.10.10.0/24`) NAT'd through the Windows host — not bridged to the corporate LAN.
- Host's internal-switch gateway IP: `10.10.10.1`
- Rancher UI and the cluster are reachable only from this Windows host (not from other machines
  on the corporate network) — see [plan.md](plan.md) Phase 1 for the NAT switch setup.



# Steps by Steps
1. Disable ufw disable
> sudo ufw disable