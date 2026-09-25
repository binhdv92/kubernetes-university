Here is the complete, step-by-step instruction to finalize your configuration so that the NFS share automatically mounts on reboot on your worker nodes.
Since you are running a Kubernetes/K3s environment, we will use optimized mount options (noatime, _netdev) to prevent the system from hanging if the master node reboots.
## Step 1: Get the Remote Share Details
You have already verified that the following parameters work for a manual mount:

* NFS Server IP: 10.10.10.11 (your k3s-master1 node)
* Server Exported Path: /mnt/nfs_share
* Worker Local Mount Point: /mnt/client_share

## Step 2: Edit the /etc/fstab File on the Worker Nodes
Run this configuration on k3s-worker1 (and k3s-worker2 if applicable).

   1. Open the file system table configuration file using the command-line editor:
   
   sudo nano /etc/fstab
   
   2. Scroll to the very bottom of the file and add the following single line:
   
   10.10.10.11:/mnt/nfs_share   /mnt/client_share   nfs   defaults,noatime,_netdev,timeo=14,intr   0   0
   
   3. Save the file and exit the editor (Ctrl+O, Enter, then Ctrl+X).

## Mount Options Decoded for K3s/Cluster Stability:

* defaults: Applies standard permissions (read/write, async execution, etc.).
* noatime: Stops the system from writing a timestamp to the storage every single time a file is read. This significantly improves cluster performance and reduces network overhead.
* _netdev: Critical for networked VMs. Forces the operating system to wait until the network interface is fully up and running before trying to mount the share, preventing boot errors.
* timeo=14 & intr: Sets a reasonable timeout (1.4 seconds) and allows cluster operations to interrupt hung requests if the master node goes offline momentarily.

------------------------------
## Step 3: Test the Automount Configuration
Before rebooting your system, always verify that your /etc/fstab file doesn't have any syntax errors.

   1. Unmount your existing manual connection:
   
   sudo umount /mnt/client_share
   
   2. Tell systemd to reload its daemon configurations and mount everything listed inside your updated /etc/fstab file:
   
   sudo systemctl daemon-reload
   sudo mount -a
   
   3. Confirm that the share mounted successfully from the configuration file without outputting any syntax errors:
   
   df -h | grep nfs
   
   
If df -h shows your network share attached back onto /mnt/client_share, your automation is safe and ready. Your worker nodes will seamlessly reconnect to the master storage on every subsequent reboot.
Now that your shared storage is persistently mounted across your VMs, are you planning to configure this path as a Kubernetes Local PersistentVolume (PV), or are you installing an automated NFS Provisioner inside K3s to dynamically manage storage for your cluster workloads?

