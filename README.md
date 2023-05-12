# How to set up my home ops

## Tooling
I use the following tools in creating, managing and using my homelab

* Hypervisor with [proxmox](https://www.proxmox.com/en/) installed
* [talosctl](https://www.talos.dev/v1.0/introduction/getting-started/#prerequisites) on your workstation
* [kubectl](https://kubernetes.io/docs/tasks/tools/) on your workstation
* [helm](https://helm.sh/docs/intro/install/) on your workstation (optional)
* [ansible](https://docs.ansible.com/ansible/latest/getting_started/index.html) on your workstation
* [terraform](https://developer.hashicorp.com/terraform/downloads?product_intent=terraform) on your workstation

## Overiew

### Hardware
I only have one machine as a hypervisor, this is more than enough for my needs.
|        |               |
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

### Terraform

