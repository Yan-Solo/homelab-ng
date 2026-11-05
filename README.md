# How to set up my home ops

## Tooling
I use the following tools in creating, managing and using my homelab

* [kubectl](https://kubernetes.io/docs/tasks/tools/) on your workstation
* [helm](https://helm.sh/docs/intro/install/) on your workstation (optional)

## Setting up

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
* pocket-id: requires a secret holding the encryption key. Keep a copy of the key, the data on the volume can't be decrypted without it
```
kubectl create secret generic pocket-id -n apps --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)"
```
* argocd: requires a secret holding the client secret of the `argocd` OIDC client in Pocket ID. Argo CD only reads it with the label set
```
read -rs CLIENT_SECRET
kubectl create secret generic argocd-oidc -n argocd --from-literal=clientSecret="$CLIENT_SECRET"
kubectl label secret argocd-oidc -n argocd app.kubernetes.io/part-of=argocd
```
* sonarr: requires a secret holding the client secret of the `sonarr` OIDC client in Pocket ID (callback URL `https://sonarr.sunnyvale.be/oauth2/callback`). Envoy Gateway uses it to authenticate requests before they reach Sonarr
```
read -rs CLIENT_SECRET
kubectl create secret generic sonarr-oidc -n media --from-literal=client-secret="$CLIENT_SECRET"
```
* radarr: same as sonarr, with a `radarr` OIDC client (callback URL `https://radarr.sunnyvale.be/oauth2/callback`)
```
read -rs CLIENT_SECRET
kubectl create secret generic radarr-oidc -n media --from-literal=client-secret="$CLIENT_SECRET"
```
* prowlarr: same as sonarr, with a `prowlarr` OIDC client (callback URL `https://prowlarr.sunnyvale.be/oauth2/callback`)
```
read -rs CLIENT_SECRET
kubectl create secret generic prowlarr-oidc -n media --from-literal=client-secret="$CLIENT_SECRET"
```
* bazarr: same as sonarr, with a `bazarr` OIDC client (callback URL `https://bazarr.sunnyvale.be/oauth2/callback`). Bazarr's own auth is set to none in its settings
```
read -rs CLIENT_SECRET
kubectl create secret generic bazarr-oidc -n media --from-literal=client-secret="$CLIENT_SECRET"
```
* sabnzbd: same as sonarr, with a `sabnzbd` OIDC client (callback URL `https://sabnzbd.sunnyvale.be/oauth2/callback`). SABnzbd's own web login is left empty in its settings
```
read -rs CLIENT_SECRET
kubectl create secret generic sabnzbd-oidc -n media --from-literal=client-secret="$CLIENT_SECRET"
```
* qbittorrent: same as sonarr, with a `qbittorrent` OIDC client (callback URL `https://qbit.sunnyvale.be/oauth2/callback`). qBittorrent's own login is bypassed for the pod network `10.1.0.0/16` in its Web UI settings
```
read -rs CLIENT_SECRET
kubectl create secret generic qbittorrent-oidc -n media --from-literal=client-secret="$CLIENT_SECRET"
```
* omniroute: requires a secret with its encryption keys and the dashboard password. Keep a copy of all values, changing them later makes the stored provider keys, the issued gateway keys and the sessions unusable. In-cluster apps such as barpath call `http://omniroute.ai.svc:20128/v1` with their own gateway key
```
read -rs DASHBOARD_PASSWORD
kubectl create secret generic omniroute -n ai \
  --from-literal=STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
  --from-literal=API_KEY_SECRET="$(openssl rand -hex 32)" \
  --from-literal=JWT_SECRET="$(openssl rand -base64 48)" \
  --from-literal=INITIAL_PASSWORD="$DASHBOARD_PASSWORD"
```

  The dashboard additionally requires a secret holding the client secret of the `omniroute` OIDC client in Pocket ID (callback URL `https://omniroute.sunnyvale.be/oauth2/callback`). Envoy Gateway uses it to authenticate requests before they reach OmniRoute, which also keeps `/v1` closed from outside the cluster. Limit the client to an admin group in Pocket ID
```
read -rs CLIENT_SECRET
kubectl create secret generic omniroute-oidc -n ai --from-literal=client-secret="$CLIENT_SECRET"
```
* open-webui: requires a secret holding the client secret of the `open-webui` OIDC client in Pocket ID (callback URL `https://chat.sunnyvale.be/oauth/oidc/callback`), the OmniRoute gateway key issued for Open WebUI, and a session key. Limit the client to a group in Pocket ID, everyone in that group can use the chatbot. Sign in yourself first, the first account becomes the admin
```
read -rs CLIENT_SECRET
read -rs GATEWAY_KEY
kubectl create secret generic open-webui -n ai \
  --from-literal=OAUTH_CLIENT_SECRET="$CLIENT_SECRET" \
  --from-literal=OPENAI_API_KEY="$GATEWAY_KEY" \
  --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
```
* lolbot: this requires a configmap that holds an API key. Again, I know that the configmap shouldn't hold the secret and that it should be in a secret mounted sepratly, but I am fine with not having the rest of the configmap in git
