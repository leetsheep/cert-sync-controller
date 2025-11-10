# cert-sync-controller

A Kubernetes controller that automatically discovers TLS certificates from Ingress resources and syncs them to remote servers (e.g. edge proxies) via SSH. Works with any remote server setup (Traefik, Nginx, HAProxy, etc.). I personally recommend using cert-manager in cluster with Traefik as remote, as this image offers automatic domain configuration for hot reloading - best for fully automating a proxy in DMZ. Please read the *security warning* carefully!

## How It Works

1. **Discovery**: Scans Ingress resources with TLS configuration
2. **Hash Check**: Compares certificate hash with previous sync
3. **Sync**: If changed, copies certificate to remote server via SCP
4. **Config**: Creates/updates dynamic configuration file for proxy
5. **Permissions**: Sets cert file permissions on remote server
6. **Repeat**: Waits for reconciliation interval and repeats

## Security Warning

**IMPORTANT:** You should only use internal or management networks to copy certificates over SSH. Use an IDS (e.g. Suricata) and/or NSM (e.g. Zeek) in production environments.

**RBAC Security:** By default, the manual deployment uses ClusterRole with cluster-wide secret access. For production, use the Helm chart with `rbac.mode=namespaced` to restrict access to specific namespaces only.

## Quick Start

The image is available pre-built at https://hub.docker.com/leetsheep/cert-sync-controller.

## Kubernetes Deployment

### Install via Helm Chart (Recommended)

The Helm chart provides namespace-scoped RBAC for better security. See [helm/cert-sync-controller/README.md](helm/cert-sync-controller/README.md) for full documentation.

```bash
# Add Helm repository
helm repo add cert-sync https://leetsheep.github.io/cert-sync-controller
helm repo update

# Quick install with namespace-scoped permissions
helm install cert-sync cert-sync/cert-sync-controller \
  --namespace cert-sync \
  --create-namespace \
  --set remote.ip=192.168.100.123 \
  --set rbac.mode=namespaced \
  --set rbac.allowedNamespaces='{cert-manager,traefik}'
```

### Manual deployment

#### 1. Create namespace and RBAC

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-sync
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-sync
  namespace: cert-sync
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-sync
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["cert-manager.io"]
  resources: ["certificates"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-sync
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-sync
subjects:
- kind: ServiceAccount
  name: cert-sync
  namespace: cert-sync
```

#### 2. Create SSH key secret

```bash
# Generate SSH key pair (or use existing)
ssh-keygen -t rsa -b 4096 -f cert-sync-key -N ""

# Create secret
kubectl create secret generic cert-sync-ssh-key \
  -n cert-sync \
  --from-file=id_rsa=cert-sync-key

# Copy public key to remote server
ssh-copy-id -i cert-sync-key.pub user@remote-server
```

#### 3. Deploy controller

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cert-sync-controller
  namespace: cert-sync
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cert-sync-controller
  template:
    metadata:
      labels:
        app: cert-sync-controller
    spec:
      serviceAccountName: cert-sync
      containers:
      - name: controller
        image: leetsheep/cert-sync-controller:latest
        env:
        - name: PROXY_IP
          value: "192.168.100.123"  # REQUIRED: Your remote server IP
        - name: REMOTE_USER
          value: "cert-sync"  # Optional: SSH user (default: cert-sync)
        - name: REMOTE_CERT_DIR
          value: "/opt/traefik/certs"  # Optional: Remote cert directory
        - name: REMOTE_CONFIG_DIR
          value: "/etc/traefik/config"  # Optional: Remote config directory
        - name: RECONCILE_INTERVAL
          value: "30"  # Optional: Sync interval in seconds
        - name: DEBUG
          value: "false"  # Optional: Enable debug logging
        volumeMounts:
        - name: ssh-key
          mountPath: /secrets
          readOnly: true
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
      volumes:
      - name: ssh-key
        secret:
          secretName: cert-sync-ssh-key
          defaultMode: 0600
```

## Remote Server Setup

### For Traefik

1. Create user and directories:

```bash
# Create cert-sync user
sudo useradd -m -s /bin/bash cert-sync

# Create directories
sudo mkdir -p /opt/traefik/certs /etc/traefik/config
sudo chown -R cert-sync:cert-sync /opt/traefik/certs /etc/traefik/config

# Add SSH public key
sudo mkdir -p /home/cert-sync/.ssh
sudo nano /home/cert-sync/.ssh/authorized_keys  # Paste public key
sudo chown -R cert-sync:cert-sync /home/cert-sync/.ssh
sudo chmod 700 /home/cert-sync/.ssh
sudo chmod 600 /home/cert-sync/.ssh/authorized_keys
```

2. Configure Traefik to watch the config directory:

```yaml
# traefik.yml
providers:
  file:
    directory: /etc/traefik/config
    watch: true
```

### For Nginx

If you're using Nginx, you can skip the Traefik config generation:

```yaml
env:
- name: PROXY_IP
  value: "nginx-server.example.com"
- name: REMOTE_USER
  value: "nginx"
- name: REMOTE_CERT_DIR
  value: "/etc/nginx/certs"
- name: SKIP_CONFIG_GENERATION
  value: "true"  # Only copy certificates, no config files
```

Then configure Nginx to use the synced certificates:

```nginx
server {
    listen 443 ssl;
    server_name example.com;

    ssl_certificate /etc/nginx/certs/example.com/tls.crt;
    ssl_certificate_key /etc/nginx/certs/example.com/tls.key;

    # ... rest of config
}
```

### For HAProxy or other proxies

Same approach - skip config generation and manually configure your proxy:

```yaml
env:
- name: REMOTE_CERT_DIR
  value: "/etc/haproxy/certs"
- name: SKIP_CONFIG_GENERATION
  value: "true"
```

## Monitoring

### Prometheus Metrics

Available at `:9090/metrics`:

```
cert_sync_controller_up 1
cert_sync_total_syncs 42
cert_sync_success_syncs 40
cert_sync_failed_syncs 2
cert_sync_last_sync_timestamp 1699564823
```

### Health Check

Available at `:8080/`:

- Returns `200 OK` if healthy (last sync < 2 minutes ago)
- Returns `503 Service Unavailable` if stale or not initialized

## Troubleshooting

### Enable debug logging

```yaml
env:
- name: DEBUG
  value: "true"
```

### Check logs

```bash
kubectl logs -n cert-sync deployment/cert-sync-controller -f
```

### Test SSH connection

```bash
kubectl exec -it -n cert-sync deployment/cert-sync-controller -- \
  ssh -i ~/.ssh/id_rsa user@remote-server "echo OK"
```

### Verify certificates

```bash
# On remote server
ls -la /opt/traefik/certs/
cat /etc/traefik/config/example.com.yml
```

## License

MIT 
