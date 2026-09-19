# Intro: Installing RKE2 on the rke201v2-lab

## 0. Prerequisite of the rke201v2-lab VM cluster
Before installing RKE2 itself, the 3-VM cluster (`management`, `server`, `agent`) must already exist, be networked (`172.30.170.0/24`), and be SSH-reachable. Pick one of the two paths below to get there:
- [`rke201v2-lab/manual/README.MD`](rke201v2-lab/manual/README.MD) — the primary, learn-by-doing path: create the Hyper-V network, create the VMs, install the OS by hand through the installer wizard, set static IPs, enable SSH.
- [`rke201v2-lab/semi-automation/README.md`](rke201v2-lab/semi-automation/README.md) — a faster, scripted alternative (Agama JSON profiles + OEMDRV ISOs) that gets all 3 VMs to a ready-to-SSH state with only one manual GRUB boot-parameter step per VM.
### Cluster configuration overview
Shared account on every VM: fullname `Tux Penguins`, username `tux`, password `linux`.

| VM | vCPU | RAM | Disk | OS | IP | Hostname |
|---|---|---|---|---|---|---|
| `rke201-management` | 2 | 2GB | 40GB + 10GB (NFS share) | openSUSE Leap 16.0 | 172.30.170.2 | `management.example.com` |
| `rke201-server` | 2 | 6GB | 40GB | openSUSE Leap 16.0 | 172.30.170.3 | `server.example.com` |
| `rke201-agent` | 2 | 6GB | 40GB | openSUSE Leap 16.0 | 172.30.170.4 | `agent.example.com` |

## 1. `server.example.com`

### 1.1. Install rke2 on `server.example.com` VM
1. ssh to server.example.com  `ssh tux@server`
2. on server.example.com execute below:
```bash
sudo zypper install -y tar
sudo curl -sfL https://get.rke2.io -o install.sh
sudo chmod 777 install.sh # or sudo chmod +x install.sh
sudo INSTALL_RKE2_TYPE=server INSTALL_RKE2_CHANNEL=v1.28 ./install.sh
```

### 1.2. Setting configuration and start the service
- Setting configuration parameters for rke2 before first start.
- Create `/etc/rancher/rke2/config.yaml` on `server.example.com`. This will help to set the alternative name of the node in the cluster:

```yaml
token: kubeadmincourse # token required for other node/agent to join the cluster.
tls-san: # subject alternative names to Kubernetes cluster certificate.
  - server.example.com
cni: canal # set the network implementation for the k8s cluster.
ingress-controller: ingress-nginx # RKE2 only supports ingress-nginx (not traefik, which is k3s's default).
```

- Start and enable the server service (First time)
```bash
sudo systemctl enable rke2-server.service --now
```
Watch it come up (first start pulls container images, takes a minute or two):

- Useful command
```bash
sudo systemctl restart rke2-server.service
sudo journalctl -u rke2-server -f # find log of the systemctl 
```

### 1.3. Allow the firewall on `server.example.com` to allow connection
`firewalld` is enabled by default and blocks the Kubernetes API/cluster ports until you trust the node, pod, and service networks. Do this before joining the agent or configuring remote `kubectl` access, since both depend on it:
```bash
sudo firewall-cmd --zone=trusted --add-source=172.30.170.0/24 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.43.0.0/16 --permanent
sudo firewall-cmd --reload
sudo firewall-cmd --list-all-zones | grep -A5 "trusted"
```

### 1.4. Create symbolic link and add kubectl access on the server
```bash
sudo ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
mkdir -p ~/.kube
sudo ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) /etc/rancher/rke2/rke2.yaml
```
This makes `kubectl` available in every new shell/login without needing to `export PATH` or `export KUBECONFIG` each time. Verify with:
```bash
kubectl get nodes
```

### 1.5. Grab the join token for the agent
```bash
sudo cat /var/lib/rancher/rke2/server/node-token
```

## 2. `agent.example.com`

### 2.1. Install rke2 on `agent.example.com`
- ssh to agent.example.com  `ssh tux@agent`
- on agent.example.com execute below:
```bash
sudo zypper install -y tar
sudo curl -sfL https://get.rke2.io -o install.sh
sudo chmod 777 install.sh # or sudo chmod +x install.sh
sudo INSTALL_RKE2_TYPE=agent INSTALL_RKE2_CHANNEL=v1.28 ./install.sh
```

### 2.2. Setting configuration for `agent` node and join to `server`
1. on `agent.example.com`, create `/etc/rancher/rke2/config.yaml` with below content (different from `server` node).
```yaml
server: https://172.30.170.3:9345 # this is server.example.com IP address
token: kubeadmincourse
```
2. enable the agent by running the below command:
```bash
sudo systemctl enable --now rke2-agent.service
```
**verify**: `sudo systemctl status rke2-agent.service`

### 2.3. Allow the firewall on `agent.example.com` to allow connection
Worker-to-server traffic (kubelet, CNI, `kubectl exec`/`logs`/`port-forward`, metrics scraping) needs the same trust rules as the server:
```bash
sudo firewall-cmd --zone=trusted --add-source=172.30.170.0/24 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.43.0.0/16 --permanent
sudo firewall-cmd --reload
```

# for `rke201-lab-mac`
```bash
sudo firewall-cmd --zone=trusted --add-source=192.168.64.0/24 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.43.0.0/16 --permanent
sudo firewall-cmd --reload
```

**verify:** the IP addresses will appear at `source: ip1 ip2 ip3`
```bash
sudo firewall-cmd --zone=trusted --list-all
```

## 3. `management.example.com` (kubectl-only client)
`management` does not run RKE2 at all — it's just a workstation configured to run `kubectl` against the API server on `server.example.com`.

1. Copy the kubectl binary from the server (there's no local RKE2 install to symlink from here, so this has to be a real copy):
```bash
scp tux@server:/var/lib/rancher/rke2/bin/kubectl /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl
```
2. Copy the kubeconfig from the server:
```bash
mkdir -p ~/.kube
scp tux@server:/etc/rancher/rke2/rke2.yaml ~/.kube/config
chmod 600 ~/.kube/config
```
3. RKE2 writes `server: https://127.0.0.1:6443` in the kubeconfig by default, which only works when run *on* the server itself. Point it at the real server address instead:
```bash
sed -i 's/127.0.0.1/172.30.170.3/' ~/.kube/config
```
4. Verify:
```bash
kubectl get nodes
```

**Note:** this is a static snapshot, not a live link — if the server's kubeconfig/certs ever get regenerated, re-copy this file.

## 4. Useful commands
- find whether a node is `server` or `agent` type:
```bash
kubectl describe node <node-name from kubectl get nodes> | grep -A 3 "rke2.io/node-args"
kubectl describe node server | grep -A 3 "rke2.io/node-args"
```

## 5. Lesson Learned

### 5.1. Symlink `/usr/local/bin/kubectl` where possible, copy only where you must
Config/kubeconfig files under `/etc/rancher/rke2/`:

| File | server | agent | management | Why |
|---|---|---|---|---|
| `config.yaml` | ✅ own keys: `token`, `tls-san`, `cni`, `ingress-controller` | ✅ own keys: `server`, `token` | ❌ | Same filename/mechanism, different keys per role. `management` never runs RKE2 at all — it's just a kubectl client, not a cluster member. |
| `rke2.yaml` (kubeconfig) | ✅ auto-generated | ❌ never generated | ❌ never generated | Only exists where `kube-apiserver` actually runs — that's server-only. |
| `rke2-pss.yaml` | ✅ | ✅ | ❌ | Written on every RKE2 node regardless of role — unrelated to the server/agent split. |

Binary — `/var/lib/rancher/rke2/bin/kubectl`:

| server | agent | management |
|---|---|---|
| ✅ RKE2-managed, version-matched | ✅ RKE2-managed, version-matched | ❌ no local RKE2 install at all |

What `/usr/local/bin/kubectl` should be on each node:

| Node | Ideal | Notes |
|---|---|---|
| server | symlink → `/var/lib/rancher/rke2/bin/kubectl` | Auto-follows RKE2 upgrades — no need to recreate after an update. |
| agent | symlink → `/var/lib/rancher/rke2/bin/kubectl` | Same reasoning as server — keep it a symlink, not a copy. |
| management | real copied file | No local RKE2 install to link to — copying is the only option here. |

### 5.2. `~/.kube/config` follows the same rule
What `~/.kube/config` should be on each node:

| Node | Ideal | Notes |
|---|---|---|
| server | symlink → `/etc/rancher/rke2/rke2.yaml` | Its own, live, auto-generated kubeconfig. |
| agent | real copied file (from server, `server:` field edited to the real IP) | No local kubeconfig is ever generated on an agent — nothing to link to. |
| management | same as agent — real copied file | Same reasoning as agent. |

**The one rule that explains both 5.1 and 5.2:** you can only symlink to something generated *locally, live, on that same machine*. That only happens on the server (the only node running `kube-apiserver`, and the only one RKE2 auto-generates a kubeconfig for). Everywhere else, a real copied file is the correct answer, not a workaround — just remember copies are static snapshots that need re-copying if the server's credentials ever rotate.

### 5.3. RKE2 only supports `ingress-nginx`, never Traefik
Traefik is k3s's default. Setting `ingress-controller: traefik` in `config.yaml` crash-loops the server with a hard `fatal` error on startup.

### 5.4. `firewalld` blocks the Kubernetes API by default on SUSE
`kubectl` works locally on `server` (loopback bypasses the firewall) but fails from every other host until you `firewall-cmd --zone=trusted --add-source=...` the node, pod, and service CIDRs.

### 5.5. A local lab subnet can collide with a corporate VPN's split-tunnel routes
Our `172.30.170.0/24` Hyper-V network happened to match a real internal range on First Solar's network, so GlobalProtect silently hijacked traffic to it whenever the VPN was connected. Diagnosed via TTL/round-trip-time clues and `route print`/`Get-NetRoute`; fixed by disconnecting the VPN, winning the route-metric tie-break, or renumbering the lab network.

### 5.6. `ROLES` in `kubectl get nodes` is just labels, not ground truth
A production node labeled `postgres` was still a plain worker underneath. The `rke2.io/node-args` node annotation (literally `["server",...]` or `["agent",...]`) is the authoritative way to tell server vs. agent.

### 5.7. Small typos cause big, confusing failures
A missing `2` in `INSTALL_RKE_TYPE`, an auto-"smart-quoted" en dash instead of `--`, and `ls -s` instead of `ln -s` each silently broke a step without an obvious error message pointing at the real cause.

### 5.8 Kubernetes CLI auto-completion
Auto-Completion for the kubectl command
```bash
echo 'source <(kubectl completion bash)' >>~/.bashrc
source ~/.bashrc
```

Auto-Completion for the k alias for the kubectl command
```bash
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -o default -F __start_kubectl k' >>~/.bashrc
```
