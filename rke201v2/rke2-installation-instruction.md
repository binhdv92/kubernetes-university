# Intro: Installing RKE2 on the rke201v2-lab

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

### 1.2. Setting Configuration and join the nodes
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

- Create symbolic link and add kubectl access on the server.
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

6. Grab the join token for the agent
```bash
sudo cat /var/lib/rancher/rke2/server/node-token
```

### allow the firewall on `server.example.com` to allow connection.
```bash
sudo firewall-cmd --zone=trusted --add-source=172.30.170.0/24 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.43.0.0/16 --permanent
sudo firewall-cmd --reload
sudo firewall-cmd --list-all-zones | grep -A5 "trusted"
```

## install rke2 on agent.example.com
- ssh to agent.example.com  `ssh tux@agent`
- on server.example.com execute below:
```bash
sudo zypper install -y tar
sudo curl -sfL https://get.rke2.io -o install.sh
sudo chmod 777 install.sh # or sudo chmod +x install.sh
sudo INSTALL_RKE2_TYPE=agent INSTALL_RKE2_CHANNEL=v1.28 ./install.sh
```

### Setting Configuration for `agent` node and join to `server`
1. on `agent.example.com`, create `/etc/rancher/rke2/config.yaml` with below content (different like `server` node).
```yaml
server: https://172.30.170.3:9345 # this is server.example.com IP address
token: kubeadmincourse
```
2. enable the agent by running the below command:
```bash
sudo systemctl enable --now rke2-agent.service
```
**verify**: `sudo systemctl status rke2-agent.service`


## Config `management.example.com` (kubectl)
- /usr/local/bin/kubectl (@server:/usr/local/bin/kubectl)
- ~/.kube/config (@server:/etc/rancher/rke2/rke2.yaml)

## usefull comand
- find the node is `server` or `agent` type?
```bash
kubectl describe node <node-name from kubectl get nodes> | grep -A 3 "rke2.io/node-args"
kubectl describe node server | grep -A 3 "rke2.io/node-args"
```