
# 03 Kubernetes Distributions by SUSE
- Distinguish core features: Differences between RKE, RKE2 and K3S
    - SUSE Kubernetes distributions include RKE, RKE2 and K3S
    - RKE is the solution for traditional data centers using Docker
    - RKE2 is the solution for industries needing top security
    - K3S is the lightweight solution for Edge, IoT, or small devices
- Execute a basic deployment: Install an RKE2 cluster
    - RKE2 can be installed using three methods: Tarball, RPM and manually
    - The Tarball installation method consists of downloading and executing an installation script
    - Version and node role can be set by passsing parameters to the installation script
    - After installing RKE2 using the Tarball method, additional steps are required before using the RKE2 Kubernetes cluster:
        - Setting configuration parameters
        - Enabling the RKE2 service
        - Symlinking the `kubectl` command

# 04 Kubernetes Adminstration with RKE2
- Kubernetes is a container orchestrator (open-source, init by Google and currently own by CNCF) 
- K8S Features:
    - Scheduling
    - Self-Healing
    - Scaling
    - Rollout and Rollbacks
    - Service Discovery: K8S provides a networking model that helps containers communicate with each other and expose the application running in them to the external world.
- K8S Objects:
    namespace (ns).
    Pod: one or more container in a pod.
    Pod management: sts, job, ds,hpa, deploy, rs.
    Storage: pvc, pv, vol
    IAM: sa, crb, role, rb, c.role
    Configuration: secret, cm
    Networking and Exposure: ep, svc, netpol, ing
    Resource mangaement: limits, quota.
   ![alt text](image.png)
