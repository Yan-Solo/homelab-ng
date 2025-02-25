# How to set up my home ops

## Tooling
I use the following tools in creating, managing and using my homelab

* Hypervisor with [proxmox](https://www.proxmox.com/en/) installed
* [kubectl](https://kubernetes.io/docs/tasks/tools/) on your workstation
* [helm](https://helm.sh/docs/intro/install/) on your workstation (optional)
* [ansible](https://docs.ansible.com/ansible/latest/getting_started/index.html) on your workstation

## Overiew

### Hardware
I only have one machine as a hypervisor, this is more than enough for my needs.
|--------|---------------|
| CPU    | Intel i7-8700 |
| RAM    | 24Gb DDR4     |
| Storage| <ul><li>240Gb SSD (Hypervisor boot drive)</li><li>240Gb SSD (Local storage Kubernetes PVCs)</li><li>6Tb HDD (Local storage Kubernetes for media files)</li></ul> |

#### _Disclaimer_
My hardware is a machine that was gifted to me by a friend. It's a _"broken"_ PC.
I got the PC for free because the PC kept bluescreening and all parts except te CPU have been replaced for testing.
So the CPU must be faulty. It kind of is. Whenever the CPU goes into turbo the system freezes completly.
You can't turn off the boost feature in the BIOS. But you can disable it with some params in Linux.
This eliminates the problem for me as I'm not bothered by not having turbo boost on this machine.

I turn off turbo boost using [this ansible task](infra/ansible/roles/common/taks/noturbo.yaml)

**If your machine doesn't have this issue, which it probably doesn't, you don't have to execut this task**

## Getting getting
### Ansible
1. Fill in the IP of your Proxmox hypervisor in `infra/ansible/inventory.ini`
2. Place your public SSH key onto your Proxmox Hypervisor
3. If the matching private key doesn't live under `~/.ssh/id_rsa`, change `infra/ansible/ansible.cfg` accordingly
4. Execute the ansible playbook
```bash
$ cd infra/ansible/
$ ansible-playbook setup-hypervisors.yaml
```

### Creating the VM
This part used to be automated but isn't anymore as it really doesn't take much longer to do by hand, and I won't have to maintain any code.
Simply upload an [Ubuntu 24.04 LTS Server ISO](https://ubuntu.com/download/server#manual-install) to Proxmox. Create a VM with all your available resources (unless you have another VM or container running on the hypervisor machine ofcourse). And go throught the server setup. I personally just make an account for myself on the server.
* Enable microk8s during the server setup *

Once the setup is complete and the server is rebooted you can just copy over your ssh key, mount your volumes (persistently) and that's about it. 

Mounting the volumes is as simple as:
```
mkdir -p /var/mnt/{hdd,ssd}
mount /dev/sdb /var/mnt/hdd
mount /dev/sdb /var/mnt/ssd
```
One pro tip is to put it in `/etc/fstab`

### Creating a microk8s cluster
If you did not enable microk8s during the server setup you can ofcourse still do this 
```
sudo snap install microk8s --classic
```

You can get your kubeconfig using 
```
microk8s config
```
And you can place that on your personal machine under `~/.kube/config` or merge it with an existing config

### Setting up ArgoCD 
Now that you have an empty kubernetes cluster you'll need to install ArgoCD on the cluster
```
helm repo add argo https://argoproj.github.io/argo-helm
helm install my-argo-cd argo/argo-cd --version 7.8.5
```
Ofcourse you can change the version to a more recent version. But at the time of writing this is the latest version. Once installed ArgoCD will keep itself updated.

Once helm is done deploying all the required resources and they have all started correctly, you can deploy the Argo ApplicationSet Manifest
```
kubectl apply -f ./kubernetes/manifests/argocd-seedjobs/manifest-apps.yaml
```

It will take a while for all applications to be synced and a few of them will fail as they require some manual things to be deployed. These are discussed in the next step

### Manual deployment of secrets
A couple of services I run require some secrets to be set, I do this manually, and I know  this is not the correct way to do it. It is the easiest way to do it and I'm fine with that.
* cert-manager: requires a secret with my cloudflare credentials
* tailscale: requires 2 secrets
* lolbot: this requires a configmap that holds an API key. Again, I know that the configmap shouldn't hold the secret and that it should be in a secret mounted sepratly, but I am fine with not having the rest of the configmap in git
