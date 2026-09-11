# Procedure: Setup Rancher to Manage a k3s Kubernetes Cluster

Based on requirements in [README.MD](README.MD):
- 1 master + 2 workers on Hyper-V, Ubuntu 24.04.4 server
- Shared local account: `k3sadmin` / `k3sadmin@123`
- Rancher URL: `https://rancher-mes.firstsolar.com`
- k3s-master1 = `10.10.10.11`, k3s-worker1 = `10.10.10.12`, k3s-worker2 = `10.10.10.13`

Decisions confirmed with user:
- TLS: Rancher-generated self-signed certificate (`ingress.tls.source=rancher`), via cert-manager.
- DNS: not yet configured, no load balancer/VIP in front of the cluster. Traffic will go directly to the master node's IP; hostname resolution handled via `/etc/hosts` (or internal DNS if/when available) rather than a public/DNS01 setup.
- Networking: this is a solo dev/learning lab with no IT support to reserve corporate IPs, and
  the host's real NIC (`Ethernet 4`, DHCP on `10.1.52.0/22`) can't safely be bridged to anyway
  (risk of DHCP/IP conflicts, and corporate 802.1x/NAC port security may block a bridged VM's MAC
  entirely regardless of IP). The original `172.26.140.66` in the README turned out to be an
  artifact of Hyper-V's built-in **Default Switch** NAT (which auto-picks a `172.16.0.0/12`
  subnet) — not a real corporate address. Decision: use a private, host-owned Hyper-V **Internal**
  switch + NAT instead of bridging to the corporate LAN. Trade-off accepted: Rancher and the
  cluster are reachable only from this Windows host, not from other machines on the network.

---

## Phase 0 — Assumptions to confirm before starting

- All 3 VMs already have Ubuntu 24.04.4 installed with the `k3sadmin` account.
- You have local admin/console access to the Hyper-V host (PowerShell as Administrator) to manage switches and NAT.

## Phase 1 — Hyper-V host networking (before VM install)

Create a private Internal switch with its own subnet (`10.10.10.0/24`) and NAT it through the
host, instead of bridging to the corporate LAN. This sidesteps DHCP/IP-conflict risk and
corporate NAC/802.1x port security entirely (no bridged VM MACs ever touch the physical wire),
while still giving the VMs fully stable static IPs and internet access.

**PowerShell (run as Administrator on the host):**
```powershell
# 1. Create the Internal switch (Hyper-V-only, not bridged to any physical NIC)
New-VMSwitch -Name "K3sNatSwitch" -SwitchType Internal

# 2. Give the host's side of that switch the gateway IP (10.10.10.1)
$ifIndex = (Get-NetAdapter | Where-Object { $_.Name -like "*K3sNatSwitch*" }).ifIndex
New-NetIPAddress -IPAddress 10.10.10.1 -PrefixLength 24 -InterfaceIndex $ifIndex

# 3. NAT the private subnet out through the host's real internet connection
New-NetNat -Name "K3sNat" -InternalIPInterfaceAddressPrefix 10.10.10.0/24
# Note: on this host the NAT object ended up named "K3s-NAT-Network" instead (created at a
# different time/session than this doc). Always check the real name before referencing it later
# (e.g. Phase 15's port-forward): `Get-NetNat | Select Name`.

# 4. Attach the 3 VMs to the new switch
Connect-VMNetworkAdapter -VMName "k3s-master1" -SwitchName "K3sNatSwitch"
Connect-VMNetworkAdapter -VMName "k3s-worker1" -SwitchName "K3sNatSwitch"
Connect-VMNetworkAdapter -VMName "k3s-worker2" -SwitchName "K3sNatSwitch"

# 5. Clean up the old misconfigured switch (was bound to a disconnected Wi-Fi adapter)
Remove-VMSwitch -Name "K8sInternalSwitch" -Force
```

Verify after VMs are up and static IPs are set (Phase 2 below):
- From Windows host: `ping 10.10.10.11` / `.12` / `.13`, and `ssh k3sadmin@10.10.10.11`.
- VM-to-VM: from `k3s-master1`, `ping 10.10.10.12` and `10.10.10.13`.
- Internet from inside a VM: `ping 8.8.8.8` and `sudo apt update`.

## Phase 2 — VM base configuration (run on all 3 nodes: master1, worker1, worker2)

1. **Set static IP via netplan** on each VM (skip if already static). Values per node:

   | Node | IP |
   |---|---|
   | k3s-master1 | `10.10.10.11/24` |
   | k3s-worker1 | `10.10.10.12/24` |
   | k3s-worker2 | `10.10.10.13/24` |

   Gateway/nameserver for all 3: `10.10.10.1` (the Windows host's side of `K3sNatSwitch`), which
   forwards DNS/internet out through NAT — plus a public resolver as fallback.

   a. Find the interface name (don't assume `eth0`):
      ```
      ip a
      ```
   b. Find the netplan file (the live-server installer usually creates one):
      ```
      ls /etc/netplan/
      ```
   c. Back it up, then edit it:
      ```
      sudo cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak
      sudo nano /etc/netplan/50-cloud-init.yaml
      ```
   d. Replace its contents (example for `k3s-master1` — swap the `addresses` line per node per the table above):
      ```yaml
      network:
        version: 2
        ethernets:
          eth0:
            dhcp4: no
            addresses:
              - 10.10.10.11/24
            routes:
              - to: default
                via: 10.10.10.1
            nameservers:
              addresses: [10.10.10.1, 8.8.8.8]
      ```
   e. Apply:
      ```
      sudo netplan generate
      sudo netplan apply
      ```
   f. Verify: `ip a show eth0` shows the new static address, `ping 8.8.8.8` and `sudo apt update` work.

   If cloud-init keeps overwriting this file on reboot, disable its network management:
   ```
   sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<< "network: {config: disabled}"
   ```
2. **Install and verify OpenSSH server** (needed to manage each VM remotely from the Windows host once its static IP is set — otherwise you're stuck working through the Hyper-V console window).

   a. Check whether it's already installed/running (the Ubuntu Server ISO offers to install it during setup, so it may already be there):
      ```
      dpkg -l | grep openssh-server
      systemctl status ssh
      ```
   b. If not installed:
      ```
      sudo apt update
      sudo apt install -y openssh-server
      ```
   c. Enable and start it so it survives reboot:
      ```
      sudo systemctl enable --now ssh
      ```
   d. Confirm it's enabled and listening on port 22:
      ```
      sudo systemctl status ssh
      ss -tlnp | grep :22
      ```
   e. From the Windows host, once the VM's static IP (step 1) is set, test it:
      ```
      ssh k3sadmin@10.10.10.11
      ```
      Accept the host key fingerprint prompt on first connect; password is `k3sadmin@123` (shared account per README).
   f. Firewall note: `ufw` gets disabled in step 4 below anyway, so no SSH rule is needed right now. If you re-enable `ufw` later for any reason, allow SSH first so you don't lock yourself out: `sudo ufw allow ssh`.

3. Set unique hostnames (`k3s-master1`, `k3s-worker1`, `k3s-worker2`).
4. Add all cluster nodes + Rancher hostname to `/etc/hosts` on every node:
   ```
   10.10.10.11  k3s-master1
   10.10.10.12  k3s-worker1
   10.10.10.13  k3s-worker2
   10.10.10.11  rancher-mes.firstsolar.com
   ```
5. Disable the firewall (per README step 1):
   ```
   sudo ufw disable
   ```
6. **Disable swap** (k3s/kubelet requirement — kubelet refuses to run reliably with swap on).

   a. Check swap status *before*:
      ```
      free -h
      swapon --show
      ```
      `free -h` shows a nonzero `Swap:` total, and `swapon --show` lists the active swap file/device (e.g. `/swap.img`) if swap is on.

   b. Turn off swap for the current session:
      ```
      sudo swapoff -a
      ```

   c. Check again *after* — `Swap:` should now read `0B` and `swapon --show` should print nothing:
      ```
      free -h
      swapon --show
      ```

   d. `swapoff -a` alone doesn't survive a reboot — `/etc/fstab` still has a line that re-enables swap at boot (Ubuntu's live-server installer creates `/swap.img  none  swap  sw  0  0`). Look at it first:
      ```
      cat /etc/fstab
      ```
      Then comment out that line so it's never re-enabled — anchor on the literal `/swap.img` path at the start of the line rather than matching on surrounding whitespace (fstab commonly uses tab/multi-space alignment, which a `/ swap /`-style pattern can silently fail to match):
      ```
      sudo sed -i 's|^/swap\.img|#/swap.img|' /etc/fstab
      ```
      Always verify:
      ```
      cat /etc/fstab
      ```
      and confirm the swap line now starts with `#`. If your swap entry isn't `/swap.img` (e.g. a swap partition instead of a swap file), match on whatever its actual path/device is instead, or comment it out manually with `sudo nano /etc/fstab`.

   e. Final proof it survives reboot: `sudo reboot`, then after it's back up, `free -h` and `swapon --show` should still show no swap.
7. **Ensure time sync is active** (`timedatectl` / `systemd-timesyncd`) — cert validation and etcd/sqlite are time-sensitive.

   a. Check status *before*:
      ```
      timedatectl status
      ```
      Look for `NTP service: active` and `System clock synchronized: yes`. If both are already true, skip to step d.

   b. If not, enable it:
      ```
      sudo timedatectl set-ntp true
      sudo systemctl enable --now systemd-timesyncd
      ```

   c. Check again *after*:
      ```
      timedatectl status
      ```
      Confirm `NTP service: active` and `System clock synchronized: yes` now.

   d. Confirm the actual sync source/offset:
      ```
      timedatectl timesync-status
      ```
      Shows which NTP server it's synced to (`Server:`) and the `Offset` — should be a small number (well under a second). Right after enabling, it can take up to ~30s to populate; retry if it errors or looks stale.

   e. Sanity-check the wall clock and timezone:
      ```
      date
      timedatectl
      ```
      Confirm the date/time and `Time zone:` line look correct — a synced clock in the wrong timezone can still cause validation problems downstream.
8. `sudo apt update && sudo apt upgrade -y`, then reboot each node.

## Phase 3 — Clone k3s-master1 to create the worker VMs (optional shortcut, done before k3s install)

Instead of building `k3s-worker1`/`k3s-worker2` from scratch, clone the already-configured
`k3s-master1` disk right after Phase 2 — it already has the static IP scheme, OpenSSH,
`/etc/hosts`, disabled firewall/swap, and time sync done. **Do this before Phase 4 installs k3s
on the master**, so the source VM has no k3s server state yet — the clones come up as blank
Ubuntu boxes with no `k3s-uninstall.sh` cleanup needed.

(If you ever clone *after* Phase 4 instead, the clone would carry that server state and you'd
additionally need to run `sudo /usr/local/bin/k3s-uninstall.sh` on each clone before joining it as
an agent. Not needed with this ordering — skip straight to the per-clone fixups below.)

**Shut down `k3s-master1` cleanly (not saved-state) before cloning.**

**Clone via PowerShell (Export + Import with a new VM identity), run once per worker:**
```powershell
Export-VM -Name "k3s-master1" -Path "D:\HyperV\Exports"

Import-VM -Path "D:\HyperV\Exports\k3s-master1\Virtual Machines\<GUID>.vmcx" `
  -Copy -GenerateNewId `
  -VirtualMachinePath "D:\HyperV\VMs\k3s-worker1" `
  -VhdDestinationPath "D:\HyperV\VMs\k3s-worker1\Virtual Hard Disks"

Rename-VM -Name <imported-name> -NewName "k3s-worker1"
```
(`<GUID>.vmcx` — check the exact filename under the exported folder.) Repeat with its own
export/path for `k3s-worker2`.

**Check the MAC address didn't clone identically** — a real conflict on the same switch if so:
```powershell
Get-VMNetworkAdapter -VMName "k3s-master1" | Select MacAddress
Get-VMNetworkAdapter -VMName "k3s-worker1" | Select MacAddress
Get-VMNetworkAdapter -VMName "k3s-worker2" | Select MacAddress
```
If they match:
```powershell
Set-VMNetworkAdapter -VMName "k3s-worker1" -DynamicMacAddress
```

**Attach the clone to `K3sNatSwitch`** (per Phase 1) if it wasn't carried over automatically:
```powershell
Connect-VMNetworkAdapter -VMName "k3s-worker1" -SwitchName "K3sNatSwitch"
```

**Inside the cloned VM, before joining it to the cluster, fix everything a disk clone duplicates:**

1. Hostname:
   ```bash
   sudo hostnamectl set-hostname k3s-worker1
   sudo sed -i 's/k3s-master1/k3s-worker1/' /etc/hosts   # fixes the 127.0.1.1 line if present
   ```
2. Machine ID (duplicates cause weird systemd/DHCP-client-identification behavior):
   ```bash
   sudo rm -f /etc/machine-id
   sudo systemd-machine-id-setup
   sudo reboot
   ```
3. SSH host keys (a disk clone carries the exact same host keys — regenerate per node):
   ```bash
   sudo rm -f /etc/ssh/ssh_host_*
   sudo ssh-keygen -A
   sudo systemctl restart ssh
   ```
4. Static IP — update netplan to this node's IP from the Phase 2 table (`10.10.10.12` for
   worker1, `10.10.10.13` for worker2) and re-apply:
   ```bash
   sudo nano /etc/netplan/50-cloud-init.yaml   # change addresses: to this node's IP
   sudo netplan apply
   ```

Repeat all of the above for `k3s-worker2`, then continue at Phase 4 to install k3s on the master,
and Phase 5 to join both clones as workers.

## Phase 4 — Install k3s master (k3s-master1)

Run this only on the real `k3s-master1` VM — the cloned worker VMs from Phase 3 get k3s installed
separately in Phase 5, not via this step.

1. Install k3s server, **pinned to `v1.35.6+k3s1`** (keeps bundled Traefik as ingress controller,
   since we have no external LB):
   ```
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.35.6+k3s1 sh -
   ```
   **Why pinned, not the default `stable` channel:** the `rancher-latest` Helm chart (Phase 9)
   declares `kubeVersion: < 1.36.0-0`. The `stable` channel install (`curl ... | sh -` with no
   version) currently resolves to `v1.36.2+k3s1`, which is too new and makes `helm install
   rancher` fail with `chart requires kubeVersion: < 1.36.0-0 which is incompatible with
   Kubernetes v1.36.2+k3s1`. `v1.35.6+k3s1` is the newest patch still under that gate. Re-check
   the [Rancher support matrix](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/)
   before reusing this pin on a future rebuild — Rancher's supported range moves forward over
   time and a newer chart may allow (or require) a newer k3s.
2. Verify the node is Ready:
   ```
   sudo k3s kubectl get nodes
   ```
3. Retrieve the join token for workers:
   ```
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```

## Phase 5 — Join worker nodes (k3s-worker1, k3s-worker2)

On each worker (**same pinned version as the master**, per Phase 4 — mismatched versions across
nodes should stay within one minor version of each other):
```
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.35.6+k3s1 K3S_URL=https://10.10.10.11:6443 K3S_TOKEN=<token-from-master> sh -
```

Back on the master, confirm all 3 nodes show `Ready`:
```
sudo k3s kubectl get nodes -o wide
```

**Note:** `k3s kubectl` only works on the **master** (server) node. Agent/worker nodes don't run
the API server and never generate `/etc/rancher/k3s/k3s.yaml`, so running `sudo k3s kubectl ...`
directly on `k3s-worker1`/`k3s-worker2` fails with `dial tcp 127.0.0.1:8080: connect: connection
refused` — that's expected, not a join failure. Always check node status from `k3s-master1`.

## Phase 6 — Set up kubectl/Helm access

Since the `10.10.10.0/24` network is only reachable from this Windows host, run kubectl/Helm
either from inside `k3s-master1` via SSH, or from the Windows host itself (WSL, Git Bash, or
native Windows kubectl/Helm binaries) — there's no separate "admin workstation" reachable here.

1. Copy the kubeconfig off the master:
   ```
   sudo cat /etc/rancher/k3s/k3s.yaml
   ```
2. **If `~/.kube/config` (or `%USERPROFILE%\.kube\config` on Windows) doesn't exist yet**, save
   the copy there as-is (after the `127.0.0.1` → `10.10.10.11` edit below).

   **If it already exists** (e.g. Windows already has `docker-desktop`/`rancher-desktop` entries
   from Docker Desktop / Rancher Desktop), you must **merge**, not overwrite — kubeconfig has
   three separate lists (`clusters:`, `contexts:`, `users:`) tied together by matching `name:`
   fields, plus a single top-level `current-context:`. Merging means:
   - Rename all three `default` entries from the master's file (k3s always names them `default`)
     to something unique, e.g. `k3s-mes-lab`, so they don't collide with an existing or future
     `default` entry.
   - Replace `127.0.0.1` with `10.10.10.11` in the `server:` line.
   - Append the renamed `cluster`/`context`/`user` block **as an additional list item** under
     each of the existing `clusters:`, `contexts:`, `users:` keys — do not paste a second
     `apiVersion:`/`kind:`/`current-context:` line, a kubeconfig can only have one of each.
   - Set `current-context: k3s-mes-lab` (or leave it and pass `--context k3s-mes-lab` per command).
   - **Verify the merge before trusting it**: run `kubectl config view` and check that (a) every
     context you expect is listed, and (b) every `context.cluster` / `context.user` name has a
     matching entry in `clusters:` / `users:` — a context pointing at a cluster name that doesn't
     exist anywhere in the file is a silent mistake that produces the same symptom as no config at
     all: `kubectl` falls back to `localhost:8080` and fails with `connection refused`, with no
     indication of which part of the merge is missing.
3. Confirm access: `kubectl get nodes -o wide` (should list all 3 nodes `Ready`).
4. Install Helm (v3) on whichever machine (host or master) you'll run the Rancher install from.

   a. Check *before* — confirm it's not already installed, and if it is, note the version:
      ```
      helm version
      ```
      (Linux/master) `bash: helm: command not found`, or (Windows PowerShell) `helm: The term
      'helm' is not recognized...` means it's not installed yet. If a version prints, skip to d.

   b. Install (Linux/master — pulls the latest v3 release):
      ```bash
      curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      ```
      **Windows host**, via winget or Chocolatey instead:
      ```powershell
      winget install Helm.Helm
      ```

   c. Open a new shell (so `PATH` picks up the new binary) if the next check fails in the same
      window.

   d. Check *after* — confirm it's on the PATH and reports a `v3.x.x` version:
      ```
      helm version
      ```
   e. Confirm it's pointed at the right cluster (uses the same kubeconfig/context as `kubectl`):
      ```
      helm list -A
      ```
      An empty table (no error) is correct at this point — nothing's been installed via Helm yet.
      A connection error here means Helm isn't picking up the `k3s-mes-lab` context/kubeconfig —
      check `$env:KUBECONFIG` / `kubectl config current-context` as in Phase 6 above.

**If running kubectl/Helm directly on `k3s-master1` (as `k3sadmin`) instead of from the Windows
host,** set up `~/.kube/config` there too rather than prefixing every command with `sudo`:
```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
```
**Gotcha:** `/etc/rancher/k3s/k3s.yaml` is root-owned/`600`, so `kubectl`/`helm` run as `k3sadmin`
without this setup falls back to `localhost:8080` and fails with `connection refused`. Running
commands with `sudo helm ...` "fixes" it inconsistently, since `sudo` doesn't inherit your shell's
`KUBECONFIG` export unless you use `sudo -E` — simplest is the copy above, then run `kubectl`/
`helm` **without** `sudo` from then on.

## Phase 7 — DNS / hostname resolution for Rancher UI

Since the cluster lives on a private NAT subnet only this Windows host can reach, and there's no
internal DNS record for it:
- Add `10.10.10.11  rancher-mes.firstsolar.com` to `C:\Windows\System32\drivers\etc\hosts` on the
  Windows host (requires editing as Administrator). This is the only place this entry is needed,
  since no other machine can route to `10.10.10.0/24` anyway.
- If you later decide to bridge the cluster onto the real corporate LAN (e.g. after getting IT to
  reserve IPs), this phase would change to a real DNS A record or a corporate-wide `/etc/hosts`
  rollout — not needed for the current private-lab setup.

## Phase 8 — Install cert-manager

Required by Rancher when using its self-signed cert generation (`ingress.tls.source=rancher`).
`--context`/`--kube-context` pins every command to `k3s-mes-lab` explicitly rather than trusting
whatever `current-context` happens to be active (the Windows host's kubeconfig also has
`docker-desktop`/`rancher-desktop` sitting in the same file — see Phase 6):
```
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl --context k3s-mes-lab create namespace cert-manager
helm --kube-context k3s-mes-lab install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true
kubectl --context k3s-mes-lab get pods -n cert-manager   # all 3 pods Running
```

## Phase 9 — Install Rancher via Helm

```
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
kubectl --context k3s-mes-lab create namespace cattle-system

helm --kube-context k3s-mes-lab install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=rancher-mes.firstsolar.com \
  --set bootstrapPassword=k3sadmin@123 \
  --set ingress.tls.source=rancher \
  --set replicas=1
```

Notes:
- `replicas=1` because this is a single-master, non-HA cluster (sqlite datastore, not etcd HA).
- Watch rollout: `kubectl --context k3s-mes-lab -n cattle-system rollout status deploy/rancher`

## Phase 10 — First login and bootstrap

1. Confirm all Rancher pods are Running: `kubectl -n cattle-system get pods`.
2. Browse to `https://rancher-mes.firstsolar.com` from the Windows host (the only machine with a route to `10.10.10.0/24` and the `/etc/hosts`-equivalent entry from Phase 7).
3. Accept the browser's self-signed cert warning (expected — this is the chosen TLS approach).
4. Log in with the `bootstrapPassword` set above, then set a permanent admin password when prompted.
5. Confirm the **Server URL** Rancher asks to configure is `https://rancher-mes.firstsolar.com`.

**Forgot the admin login?** The Rancher local-user login is **`admin`** — a separate account from the
VM's OS-level `k3sadmin` — with whatever permanent password you set in step 4 above (which may no
longer be the `bootstrapPassword` from Phase 9, since that step replaces it). If that password is
lost, Rancher ships a built-in reset command run from inside its own pod, no browser access needed:
```
kubectl --context k3s-mes-lab -n cattle-system exec $(kubectl --context k3s-mes-lab -n cattle-system get pods -l app=rancher -o jsonpath='{.items[0].metadata.name}') -- reset-password
```
Prints a new generated password for the `admin` user directly to the terminal. Safe to rerun any
time — it only resets that one local user's password, nothing else in the cluster. Log in with the
printed password, then set a new permanent one when prompted (same as step 4).

## Phase 11 — Verify cluster is managed

1. In the Rancher UI, confirm the `local` cluster (this k3s cluster) shows as **Active** with all 3 nodes visible under Cluster Management.
2. Check workload/pod status matches `kubectl get pods -A` from the CLI.
3. (Optional, future) Use **Import Existing** in Rancher if you later stand up additional k3s/RKE2 clusters to bring them under the same Rancher instance.

## Phase 12 — Deploy a private, TLS-secured container registry

Phase 13b's custom `fastapi-hostname` image is distributed with a manual, unscalable workflow:
build → `docker save` → `scp` to all 3 nodes → SSH into each one individually to `k3s ctr images
import`. That stays in place deliberately as a hands-on "dirty method" reference (see 13b/13c) —
this phase adds the real fix alongside it: a self-hosted registry, so future images are just
`docker push`ed once and pulled automatically by every node.

**Design: reuse `rancher-mes.firstsolar.com` itself** (and its already-working TLS cert) rather
than minting a new hostname/cert. A Traefik `Ingress` rule for the same host at path `/v2` routes
to an in-cluster `registry:2` Service — no prefix-stripping `Middleware` needed (unlike the demo
apps' Ingresses), because the Docker Registry HTTP API v2 spec requires its root to literally be
`/v2/...`, so forwarding the path as-is is exactly correct:
`docker push rancher-mes.firstsolar.com/<image>:<tag>` naturally lands on
`https://rancher-mes.firstsolar.com/v2/<image>/...`.

This was validated against the live cluster, not assumed:
- Rancher's own `Ingress` (`cattle-system/rancher`) only claims `host: rancher-mes.firstsolar.com,
  path: /, pathType: ImplementationSpecific` — nothing collides with `/v2`, and the existing
  nginx-hello/fastapi-hostname Ingresses already prove a more-specific `Host+PathPrefix` rule from a
  separate `Ingress` object in a different namespace correctly wins over this catch-all.
- The TLS cert comes from cert-manager `Issuer` `rancher` (namespaced to `cattle-system`, not a
  ClusterIssuer) via `Certificate`/`Secret` `tls-rancher-ingress`. Reusing the identical hostname
  means Traefik's SNI-keyed cert store serves the same cert automatically — no new Issuer,
  Certificate, or `tls:` block needed.
- The default StorageClass is `local-path` (host-path-backed, single-node bound), so the registry
  Deployment must be `replicas: 1` with `strategy: Recreate` — its PVC binds to one node, never
  spread across nodes like the demo apps.

1. Deploy the registry:
   ```
   kubectl --context k3s-mes-lab apply -f sample-apps/registry/k8s.yaml
   kubectl --context k3s-mes-lab get pods -o wide -l app=registry   # 1 pod, Running
   ```
2. Route it through Traefik on the existing Rancher hostname:
   ```
   kubectl --context k3s-mes-lab apply -f sample-apps/registry/ingress.yaml
   ```
3. **Distribute the CA to all 3 nodes' containerd** (one-time, not per-image). Extract it from the
   same Secret Rancher's own Ingress already uses:
   ```bash
   kubectl --context k3s-mes-lab get secret -n cattle-system tls-rancher-ingress \
     -o jsonpath='{.data.ca\.crt}' | base64 -d > rancher-mes-ca.crt

   scp rancher-mes-ca.crt k3sadmin@10.10.10.11:~
   scp rancher-mes-ca.crt k3sadmin@10.10.10.12:~
   scp rancher-mes-ca.crt k3sadmin@10.10.10.13:~
   ```
   On each of the 3 nodes (**worker nodes need `/etc/rancher/k3s` created first** — k3s only
   auto-creates this directory on the server/master for `k3s.yaml`, `node-token`, etc.; agents never
   write anything there by default, so `mv`/`tee` below fail on `k3s-worker1`/`k3s-worker2` unless
   you make it first):
   ```bash
   sudo mkdir -p /etc/rancher/k3s
   sudo mv ~/rancher-mes-ca.crt /etc/rancher/k3s/registry-ca.crt
   sudo tee /etc/rancher/k3s/registries.yaml <<'EOF'
   mirrors:
     "rancher-mes.firstsolar.com":
       endpoint:
         - "https://rancher-mes.firstsolar.com"
   configs:
     "rancher-mes.firstsolar.com":
       tls:
         ca_file: "/etc/rancher/k3s/registry-ca.crt"
   EOF
   ```
   Restart to apply — `registries.yaml` isn't hot-reloaded:
   ```bash
   sudo systemctl restart k3s          # master only
   sudo systemctl restart k3s-agent    # workers only
   ```
   Confirm all 3 nodes are still `Ready` afterward (`kubectl get nodes`) — the restart doesn't
   affect already-running workloads.
4. **Trust the same CA on the Windows host**, so `docker push` doesn't fail with
   `x509: certificate signed by unknown authority`. Docker Desktop's engine runs inside a Linux VM,
   not directly on Windows — `C:\ProgramData\Docker\certs.d\...` (the native-Windows-Docker-Engine
   convention) does **not** work here and is silently ignored. Use both of these instead:
   ```powershell
   # Primary — Docker Desktop bundles the Windows trusted-root store automatically. Run as Administrator:
   Import-Certificate -FilePath ".\rancher-mes-ca.crt" -CertStoreLocation Cert:\LocalMachine\Root

   # Belt-and-suspenders — Docker Desktop explicitly bridges this specific folder into its VM:
   New-Item -ItemType Directory -Force "$env:USERPROFILE\.docker\certs.d\rancher-mes.firstsolar.com" | Out-Null
   Copy-Item ".\rancher-mes-ca.crt" "$env:USERPROFILE\.docker\certs.d\rancher-mes.firstsolar.com\ca.crt"
   ```
   Then fully quit and relaunch Docker Desktop (tray icon → Quit Docker Desktop, then restart it).
5. Verify end-to-end with a throwaway test image before trusting it for real workloads:
   ```
   docker pull hello-world
   docker tag hello-world rancher-mes.firstsolar.com/hello-world:test
   docker push rancher-mes.firstsolar.com/hello-world:test
   ```
   Success here (no TLS error) proves the CA trust chain is wired correctly end to end — nodes and
   Windows both trust the registry's cert, and Traefik is routing `/v2` correctly.
6. **Inspect the registry's contents directly**, since `registry:2` has no UI — the Docker Registry
   HTTP API v2 is the only interface:
   ```powershell
   curl.exe https://rancher-mes.firstsolar.com/v2/_catalog                    # list all repos
   curl.exe https://rancher-mes.firstsolar.com/v2/hello-world/tags/list       # list tags for one repo
   docker manifest inspect rancher-mes.firstsolar.com/hello-world:test        # layers/config digest, queried live from the registry
   docker image inspect rancher-mes.firstsolar.com/hello-world:test          # local image cache — complements manifest inspect, doesn't hit the network
   ```
   **How to be sure `manifest inspect` really came from *this* registry, not Docker Hub or a local
   cache:** Docker's reference parser treats the first path segment as a registry host only if it
   contains a `.`/`:` or is `localhost` — `rancher-mes.firstsolar.com` has dots, so it can never fall
   back to `docker.io/library/hello-world`. `docker manifest inspect` is also a live registry API
   call (unlike `docker image inspect`), so it can't be silently answered from a local cache. To
   prove it, not just trust the parser:
   - **Tail the registry pod's logs** while re-running the inspect command — you should see the
     `GET /v2/hello-world/manifests/test` request land in real time:
     ```
     kubectl --context k3s-mes-lab logs -f deploy/registry
     ```
   - **Negative test** — scale the registry to 0 and confirm the same command now fails, proving
     there's no other source it could be answering from:
     ```powershell
     kubectl --context k3s-mes-lab scale deploy/registry --replicas=0
     docker manifest inspect rancher-mes.firstsolar.com/hello-world:test   # should now error/timeout
     kubectl --context k3s-mes-lab scale deploy/registry --replicas=1
     ```

**Skipped deliberately:** basic auth (htpasswd) on the registry — the cluster is already fully
NAT-isolated to this one Windows host with no other reachable machine, so it adds complexity with
no real benefit today. See Phase 14 if that changes.

## Phase 13 — Deploy sample workloads to verify cross-node scheduling

### 13a — nginx-hello: one app, reached 8 different ways

A single app — [sample-apps/nginx-hello/](sample-apps/nginx-hello/) — deployed once, then reached
through every layer this lab has built so far (raw IP, node hostname, and two Traefik `Ingress`
routing styles), to make concrete how they all stack on top of each other rather than being
separate things:

```
http://10.10.10.11:30080                        # NodePort, straight to the master's IP
http://10.10.10.12:30080                        # NodePort, straight to worker1's IP
http://10.10.10.13:30080                        # NodePort, straight to worker2's IP
http://k3s-master1:30080                        # NodePort, via the master's hostname
http://k3s-worker1:30080                        # NodePort, via worker1's hostname
http://k3s-worker2:30080                        # NodePort, via worker2's hostname
http://k3s-master1/nginx-hello                  # Traefik Ingress, path-based, plain HTTP
https://rancher-mes.firstsolar.com/nginx-hello  # Traefik Ingress, path-based, reusing Rancher's TLS
```

**1. Deploy the app** (`Deployment` + `Service` + `ConfigMap` — public `nginx:alpine` image, zero
build step; `topologySpreadConstraints` forces one replica per node):
```
kubectl --context k3s-mes-lab apply -f sample-apps/nginx-hello/k8s.yaml
kubectl --context k3s-mes-lab get pods -o wide -l app=nginx-hello   # NODE column: 3 distinct nodes
```
This alone is enough for the first 6 URLs above — `Service.type: NodePort` opens port `30080` on
every node, and `kube-proxy` load-balances across all 3 pods no matter which node's address you
hit (that's Layer 4 — no hostname/path awareness at all, so `k3s-master1:30080` and
`k3s-worker1:30080` are just two doors into the identical pool of pods).

**2. Resolve node hostnames from the Windows host** (needed for the `k3s-master1`/`k3s-worker1`/
`k3s-worker2` URLs — Phase 7 only added `rancher-mes.firstsolar.com`, not the bare node names). Add
to `C:\Windows\System32\drivers\etc\hosts` (as Administrator):
```
10.10.10.11  k3s-master1
10.10.10.12  k3s-worker1
10.10.10.13  k3s-worker2
```

**3. Add path-based Traefik routing** for the last 2 URLs — `/nginx-hello` under both the master's
bare hostname (plain HTTP, port 80) and the existing Rancher hostname (HTTPS, port 443):
```
kubectl --context k3s-mes-lab apply -f sample-apps/nginx-hello/ingress.yaml
```
[sample-apps/nginx-hello/ingress.yaml](sample-apps/nginx-hello/ingress.yaml) defines one
`Middleware` (`stripPrefix: [/nginx-hello]` — nginx-hello's page is built to answer at `/`, so the
prefix has to be stripped before the request reaches the pod) and one `Ingress` with two `host`
rules (`k3s-master1` and `rancher-mes.firstsolar.com`) both pointing at path `/nginx-hello`. Traefik
automatically prefers these more specific `Host + PathPrefix` rules over Rancher's own catch-all
`Host`-only rule for the same hostname, regardless of which `Ingress` object or namespace each
comes from — and no new TLS cert is needed for the `rancher-mes.firstsolar.com` rule, since
Traefik's cert store is keyed by hostname (SNI) and Rancher's own `Ingress` already registered one
for that host.

**4. Verify all 8 URLs**, and watch the **Node name** field in the response body rotate across
`k3s-master1`/`k3s-worker1`/`k3s-worker2` regardless of which URL you used — proof that every path
above ultimately reaches the same load-balanced pool of 3 pods:
```
curl http://10.10.10.11:30080
curl http://10.10.10.12:30080
curl http://10.10.10.13:30080
curl http://k3s-master1:30080
curl http://k3s-worker1:30080
curl http://k3s-worker2:30080
curl http://k3s-master1/nginx-hello
curl -k https://rancher-mes.firstsolar.com/nginx-hello
```

| URL | Layer | Mechanism |
|---|---|---|
| `<node-ip>:30080` (×3) | L4 | `kube-proxy` NodePort, no hostname/path awareness |
| `<node-hostname>:30080` (×3) | L4 | identical to above — hostname only resolves the IP, port 30080 ignores it |
| `k3s-master1/nginx-hello` | L7 | Traefik `Ingress`, `Host`+`Path` match, plain HTTP (port 80) |
| `rancher-mes.firstsolar.com/nginx-hello` | L7 | Traefik `Ingress`, `Host`+`Path` match, HTTPS via Rancher's existing cert |

### 13b — Custom FastAPI hostname/pod-id app (the "dirty method": manual SSH + image import)

Kept intentionally as a hands-on reference for what a real registry (Phase 12) replaces — build
the image locally and load it directly into each node's containerd via `k3s ctr images import`,
no registry involved at all:

1. Build on the Windows host (requires Docker Desktop):
   ```powershell
   docker build -t fastapi-hostname:1.0 sample-apps/fastapi-hostname
   docker save fastapi-hostname:1.0 -o fastapi-hostname.tar
   ```
2. Copy the image tarball to all 3 nodes and import it into each one's containerd:
   ```powershell
   scp fastapi-hostname.tar k3sadmin@10.10.10.11:~
   scp fastapi-hostname.tar k3sadmin@10.10.10.12:~
   scp fastapi-hostname.tar k3sadmin@10.10.10.13:~
   ```
   ```bash
   # run on each of the 3 nodes
   sudo k3s ctr images import ~/fastapi-hostname.tar
   sudo k3s ctr images ls | grep fastapi-hostname   # confirm it's present
   ```
   **Why this step matters:** the Deployment uses `imagePullPolicy: IfNotPresent` — if the image
   isn't already sitting in a node's local containerd store when a pod schedules there, k3s tries
   to pull `fastapi-hostname:1.0` from a real registry (Docker Hub by default) and fails with
   `ErrImagePull`/`ImagePullBackOff`, since no such public image exists. Importing it onto all 3
   nodes first avoids that — this is a one-time step per node, but must be repeated on all 3 (not
   just the master) since each node's containerd store is independent.
3. Deploy and verify:
   ```
   kubectl --context k3s-mes-lab apply -f sample-apps/fastapi-hostname/k8s.yaml
   kubectl --context k3s-mes-lab get pods -o wide -l app=fastapi-hostname   # 3 distinct nodes
   ```
4. Test from the Windows host (NodePort, by IP and by hostname — the node hostname entries from
   13a step 2 already cover this, no new hosts-file edit needed):
   ```
   curl http://10.10.10.11:30090
   curl http://10.10.10.12:30090
   curl http://10.10.10.13:30090
   curl http://k3s-master1:30090
   curl http://k3s-worker1:30090
   curl http://k3s-worker2:30090
   ```
   Each should return JSON with a different `pod_name`/`pod_ip`/`node_name`, confirming the app is
   genuinely running on (and being served from) all 3 nodes.

5. **Same Traefik path-based routing as nginx-hello (13a step 3)**, applied to this app instead —
   `/fastapi-hostname` under both the master's bare hostname and the Rancher hostname, via
   [sample-apps/fastapi-hostname/ingress.yaml](sample-apps/fastapi-hostname/ingress.yaml) (same
   shape as nginx-hello's: one `Middleware` stripping the `/fastapi-hostname` prefix — FastAPI's
   route is defined at `/`, same reasoning as nginx-hello needing `/` — plus one `Ingress` with the
   same two `host` rules, pointed at the `fastapi-hostname` Service on port `8000` instead):
   ```
   kubectl --context k3s-mes-lab apply -f sample-apps/fastapi-hostname/ingress.yaml
   ```
   Test — no new TLS cert needed here either, same reasoning as 13a (Traefik's cert store is keyed
   by hostname, and Rancher's `Ingress` already registered one for `rancher-mes.firstsolar.com`):
   ```
   curl http://k3s-master1/fastapi-hostname
   curl -k https://rancher-mes.firstsolar.com/fastapi-hostname
   ```

### 13c — Same app, deployed the proper way (via the Phase 12 registry)

The exact same `main.py`/`Dockerfile` as 13b, but built and pushed to the registry instead of
saved/scp'd/imported — and deployed as a **separate** Deployment/Service
(`fastapi-hostname-registry`, its own NodePort `30091`) so it can run side-by-side with 13b's for a
direct before/after comparison, rather than replacing it:

1. Build and push (no `docker save`, no `scp`, no SSH into any node):
   ```powershell
   docker build -t rancher-mes.firstsolar.com/fastapi-hostname-registry:1.0 sample-apps/fastapi-hostname
   docker push rancher-mes.firstsolar.com/fastapi-hostname-registry:1.0
   ```
2. Deploy — [sample-apps/fastapi-hostname/k8s-registry.yaml](sample-apps/fastapi-hostname/k8s-registry.yaml)
   uses `imagePullPolicy: Always` (not `IfNotPresent` — with a static tag, `IfNotPresent` would
   silently skip re-pulling an updated push under the same tag, defeating the point of a registry):
   ```
   kubectl --context k3s-mes-lab apply -f sample-apps/fastapi-hostname/k8s-registry.yaml
   kubectl --context k3s-mes-lab get pods -o wide -l app=fastapi-hostname-registry
   ```
   **This is the actual proof the fix works**: all 3 nodes pull the image independently, with zero
   manual per-node steps — compare directly against 13b's Deployment, which required 3 rounds of
   `scp` + SSH to reach the same state.
3. Test side-by-side with 13b (same app, two distribution methods, both should respond):
   ```
   curl http://10.10.10.11:30090   # 13b — dirty method
   curl http://10.10.10.11:30091   # 13c — via registry
   ```
4. **Same Traefik path-based routing as 13b**, applied to this Deployment's Service instead —
   `/fastapi-hostname-registry` under both the master's bare hostname and the Rancher hostname.
   [sample-apps/fastapi-hostname/ingress.yaml](sample-apps/fastapi-hostname/ingress.yaml) now
   defines **two** `Middleware`/`Ingress` pairs in the same file: the original one from 13b (routes
   `/fastapi-hostname` → Service `fastapi-hostname`) plus a second one for 13c (routes
   `/fastapi-hostname-registry` → Service `fastapi-hostname-registry`, port `8000`) — so re-applying
   this one file covers both apps:
   ```
   kubectl --context k3s-mes-lab apply -f sample-apps/fastapi-hostname/ingress.yaml
   ```
   Test — no new TLS cert needed, same reasoning as 13a/13b:
   ```
   curl http://k3s-master1/fastapi-hostname-registry
   curl -k https://rancher-mes.firstsolar.com/fastapi-hostname-registry
   ```

### Cleanup (optional, once verified)

```
kubectl --context k3s-mes-lab delete -f sample-apps/nginx-hello/ingress.yaml
kubectl --context k3s-mes-lab delete -f sample-apps/nginx-hello/k8s.yaml
kubectl --context k3s-mes-lab delete -f sample-apps/fastapi-hostname/ingress.yaml
kubectl --context k3s-mes-lab delete -f sample-apps/fastapi-hostname/k8s.yaml
kubectl --context k3s-mes-lab delete -f sample-apps/fastapi-hostname/k8s-registry.yaml
kubectl --context k3s-mes-lab delete -f sample-apps/registry/ingress.yaml
kubectl --context k3s-mes-lab delete -f sample-apps/registry/k8s.yaml
```

## Phase 14 — Share an endpoint with a teammate (inbound NAT port-forward)

The `10.10.10.0/24` subnet lives behind the host's private Hyper-V Internal switch (Phase 1) — only
this Windows host can reach it. To let a teammate on the corporate network hit a NodePort (e.g.
`nginx-hello` on `30080`) themselves, forward one port through the host's existing NAT, without
bridging any VM's MAC onto the corporate wire (so this sidesteps the 802.1x/NAC risk that ruled out
bridging in Phase 1):

1. Confirm the real NAT object name first — don't assume it matches Plan.md's Phase 1 example
   (`K3sNat`); on this host it's actually `K3s-NAT-Network`:
   ```powershell
   Get-NetNat | Select Name
   ```
2. **In an elevated (Run as Administrator) PowerShell** — a non-elevated session fails with `Access
   is denied`:
   ```powershell
   Add-NetNatStaticMapping -NatName "K3s-NAT-Network" -Protocol TCP `
     -ExternalIPAddress 0.0.0.0 -ExternalPort 30080 `
     -InternalIPAddress 10.10.10.11 -InternalPort 30080

   New-NetFirewallRule -DisplayName "k3s nginx-hello NodePort" -Direction Inbound `
     -Protocol TCP -LocalPort 30080 -Action Allow
   ```
3. Verify the mapping exists:
   ```powershell
   Get-NetNatStaticMapping
   ```
4. Teammate tests it from their own machine, pointed at your host's **corporate-network IP** (not
   `10.10.10.11`):
   ```
   curl http://<your-host-corporate-ip>:30080
   ```
   Works only if your host is reachable on the corporate LAN and no corporate firewall/security
   policy blocks inbound traffic on that port to your machine.

Repeat steps 2–4 (new `-ExternalPort`/`-InternalPort` pair) for any other NodePort you want to
expose (e.g. `30090`/`30091` for `fastapi-hostname`).

**Alternative for a quick one-off look, no host config changes:** just screen-share the demo — this
phase is only needed if the teammate must hit the endpoint from their own machine.

## Phase 15 — Suggested follow-ups (not blocking, flag for later)

- Export/back up the self-signed CA cert so it can be trusted by the browser instead of clicking through warnings each time.
- Install the `rancher-backup` operator and schedule periodic backups of Rancher's local cluster state.
- If this lab ever needs to be reachable from other machines on the corporate network, revisit bridging onto the real LAN — would require IT-reserved IPs (or DHCP reservations by VM MAC) to avoid the conflict/NAC issues that ruled it out this time, plus revisiting TLS/DNS accordingly.
- Consider adding a second master later if HA becomes a requirement (would require migrating sqlite → embedded etcd or external DB).
- The Phase 12 registry has no authentication and its PVC is single-node/`local-path`-bound (no
  redundancy). Fine for a NAT-isolated single-host lab; revisit (htpasswd/OIDC auth, and/or a
  replicated storage backend) if this cluster's network exposure or availability requirements ever
  change.

---

**Please review and approve before I begin execution**, or let me know what to adjust (IP assumptions, TLS/DNS phases, single vs multi-node approach, adjust worker IPs, etc.).
