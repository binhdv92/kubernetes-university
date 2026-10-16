# Pi Cluster RKE2

This guide installs a single-server, one-agent RKE2 cluster on the Raspberry Pi
lab machines. It includes the firewall rules and checks that resolved the agent
join issue in this setup.

## Cluster configuration

| VM | vCPU | RAM | Disk | OS | IP | Hostname |
|---|---:|---:|---|---|---|---|
| `pi-management` | 4 | 8 GB | 14 GB + 10 GB (NFS share) | openSUSE Leap 16.0 | `192.168.1.??` | `pi-management.example.com` |
| `pi-server` | 4 | 8 GB | TBD | Raspberry Pi OS 11 (bullseye) | `192.168.1.90/24` | `pi-server.example.com` |
| `pi-agent` | 4 | 8 GB | TBD | Ubuntu 24.04.4 LTS | `192.168.1.91/24` | `pi-agent.example.com` |

Use DHCP reservations or static addresses so the server and agent IPs do not
change. Make sure the nodes can resolve each other's hostnames if using names
instead of IP addresses. Use unique account passwords; do not put account
passwords or the RKE2 join token in this file.

## 1. Install RKE2 on `pi-server`

Run these commands on `pi-server`. Install the same RKE2 release on both nodes.
The version observed in this lab was `v1.36.5+rke2r1`; update the version below
only when intentionally upgrading/reproducing with another supported release.

```bash
sudo curl -sfL https://get.rke2.io -o /tmp/install-rke2.sh
sudo env INSTALL_RKE2_TYPE=server INSTALL_RKE2_VERSION='v1.36.5+rke2r1' \
  sh /tmp/install-rke2.sh
```

Generate a strong join token on the server and keep it private:

```bash
openssl rand -hex 32
```

Copy the generated value into the `token` field on both nodes. Do not commit the
token or paste it into logs/issues.

Create `/etc/rancher/rke2/config.yaml` on the server, substituting the generated
token:

```yaml
token: "REPLACE_WITH_THE_GENERATED_TOKEN"
tls-san:
  - 192.168.1.90
  - pi-server.example.com
```

`tls-san` must include the address/name clients use for the Kubernetes API.
Omit the hostname entry if it is not configured in DNS or `/etc/hosts`. Leave
the CNI at the RKE2 default unless intentionally choosing a different plugin;
check the installed CNI before adding CNI-specific firewall rules.

Start the server:

```bash
sudo systemctl enable --now rke2-server.service
sudo systemctl status rke2-server.service --no-pager -l
sudo ss -lntp | grep -E ':(9345|6443)\b'
```

RKE2's supervisor listens on TCP `9345`; the Kubernetes API listens on TCP
`6443`. The server must be listening before joining the agent.

## 2. Configure the server firewall

This lab uses UFW with incoming traffic denied by default. Allow the agent to
reach the server's supervisor and Kubernetes API ports. Run on `pi-server`:

```bash
sudo ufw allow from 192.168.1.91 to any port 9345 proto tcp
sudo ufw allow from 192.168.1.91 to any port 6443 proto tcp
sudo ufw status verbose
```

If the agent address changes, update these source-address rules. Do not disable
the firewall or add broad `Anywhere` rules to solve a single-port problem.

Check existing rules carefully. In particular, `192.160.1.0/24` is not the
`192.168.1.0/24` lab subnet; correct or remove such a stale/typo rule if it is
present. Use `sudo ufw status numbered` to inspect rule numbers before deleting
a rule.

## 3. Install and join `pi-agent`

First confirm from `pi-agent` that the server's supervisor port is reachable:

```bash
ping -c 3 192.168.1.90
nc -vz -w 3 192.168.1.90 9345
```

Ping only tests ICMP; a successful TCP check to `9345` is the relevant join
connectivity check. Install the same RKE2 release as the server:

```bash
sudo curl -sfL https://get.rke2.io -o /tmp/install-rke2.sh
sudo env INSTALL_RKE2_TYPE=agent INSTALL_RKE2_VERSION='v1.36.5+rke2r1' \
  sh /tmp/install-rke2.sh
```

Create `/etc/rancher/rke2/config.yaml` on the agent, using the same token as the
server:

```yaml
server: https://192.168.1.90:9345
token: "REPLACE_WITH_THE_GENERATED_TOKEN"
```

Join the cluster:

```bash
sudo systemctl enable --now rke2-agent.service
sudo systemctl status rke2-agent.service --no-pager -l
```

The agent may take a few minutes to download/extract images and start
containerd, kubelet, and its networking components. Inspect logs instead of
repeatedly restarting it:

```bash
sudo journalctl -u rke2-agent -b -n 50 --no-pager -o cat
```

Use `-l` when reading journal output in the default format to avoid truncated
messages:

```bash
sudo journalctl -u rke2-agent -b -n 20 --no-pager -l
```

The agent's local load balancer may log requests to `127.0.0.1:6444`. A timeout
there can be caused by an unreachable upstream server; test `192.168.1.90:9345`
and `192.168.1.90:6443` from the agent before treating it as a local-port issue.

## 4. Check the agent firewall and cluster networking

No additional inbound agent firewall rule was needed for the test workload in
this lab: pods successfully started on both nodes after the server allowed
TCP `9345` and `6443` from the agent. Do not infer that every cluster feature
or CNI is covered by that test.

If UFW is enabled on the agent, check its policy with:

```bash
sudo ufw status verbose
```

The server may need to reach the agent's kubelet on TCP `10250` for operations
such as pod logs/exec and kubelet metrics. If those operations fail and UFW
blocks incoming connections, allow only the server:

```bash
sudo ufw allow from 192.168.1.90 to any port 10250 proto tcp
```

Additional node-to-node ports depend on the CNI and its configuration. Find the
actual networking components before changing firewall rules:

```bash
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n kube-system -o wide
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml describe node pi-agent
```

Only add the ports required by the installed CNI. Do not open all ports or
disable UFW as a troubleshooting shortcut.

## 5. Verify the cluster

On `pi-server`, use the RKE2-provided `kubectl` and kubeconfig:

```bash
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes -o wide
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -A -o wide
```

Both nodes should become `Ready`. System pods and any test workloads should
reach `Running`/`Ready`. A newly registered node or pod may briefly be
`NotReady`, `Pending`, or `ContainerCreating` while components start; inspect
the condition/events if it does not recover after a few minutes.

To test scheduling on both machines, deploy or scale a workload to multiple
replicas, then confirm the pod `NODE` and `IP` columns show pods on each node.
Pods on both nodes reaching `Running` with pod IPs confirmed that this lab's
agent joined and its workload networking came up.

If you need to reach a NodePort from another machine, allow that specific
NodePort from the required client subnet on the node(s) serving the traffic.
The assigned NodePort can vary; read it from `kubectl get service` rather than
assuming a fixed value.

## 6. Troubleshooting learned in this setup

### Agent cannot validate the cluster CA

An error like:

```text
failed to get CA certs: Get "https://127.0.0.1:6444/cacerts": context deadline exceeded
```

means the agent did not complete CA retrieval via its local load balancer.
Check connectivity to the server supervisor from `pi-agent`:

```bash
nc -vz -w 3 192.168.1.90 9345
curl -ksS --connect-timeout 3 --max-time 8 -o /dev/null \
  -w 'HTTP %{http_code}\n' https://192.168.1.90:9345/cacerts
```

The CA endpoint returning HTTP `200` confirms it is reachable. If TCP times
out while ping succeeds, inspect firewall/network filtering; on the server,
confirm RKE2 is listening with `ss` and check UFW rules.

### Agent joins but API connectivity is intermittent

Test TCP `6443` separately from `9345` on the agent:

```bash
nc -vz -w 3 192.168.1.90 6443
curl -ksS --connect-timeout 3 --max-time 5 -o /dev/null \
  -w 'HTTP %{http_code}\n' https://192.168.1.90:6443/readyz
```

The server firewall must allow `6443` from the agent as well as `9345`.
ICMP ping does not prove that either TCP port is allowed. On the server, verify
the listener and inspect incoming traffic if needed:

```bash
sudo ss -lntp | grep -E ':(9345|6443)\b'
sudo tcpdump -ni any 'host 192.168.1.91 and (tcp port 9345 or tcp port 6443)'
```

### Node or workload remains NotReady

Check the node conditions, pod events, CNI pods, and recent agent logs:

```bash
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml describe node pi-agent
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -A -o wide
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get events -A \
  --sort-by=.lastTimestamp | tail -n 30
sudo journalctl -u rke2-agent -b -n 50 --no-pager -o cat
```

`Pending` means the pod has not been scheduled or started; `ContainerCreating`
means startup is in progress. `describe pod <pod-name>` shows the relevant
events, which distinguish image-pull failures from CNI/setup issues. A pod
running on the server alone does not prove cross-node networking works; verify
that a pod on the agent gets an IP and reaches `Running`.
