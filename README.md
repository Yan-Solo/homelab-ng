# How to set up my home ops

## Tooling
I use the following tools in creating, managing and using my homelab

* [kubectl](https://kubernetes.io/docs/tasks/tools/) on your workstation
* [helm](https://helm.sh/docs/intro/install/) on your workstation (optional)

## Overiew

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
helm install argocd argo/argo-cd --version 7.8.18
```

Once helm is done deploying all the required resources and they have all started correctly, you can deploy the Argo ApplicationSet Manifest
```
kubectl apply -f ./kubernetes/manifests/argocd-seedjobs/manifest-apps.yaml
```

It will take a while for all applications to be synced and a few of them will fail as they require some manual things to be deployed. These are discussed in the next step

### Manual deployment of secrets
A couple of services I run require some secrets to be set, I do this manually, and I know  this is not the correct way to do it. It is the easiest way to do it and I'm fine with that.
* tailscale: requires 2 secrets
* lolbot: this requires a configmap that holds an API key. Again, I know that the configmap shouldn't hold the secret and that it should be in a secret mounted sepratly, but I am fine with not having the rest of the configmap in git
