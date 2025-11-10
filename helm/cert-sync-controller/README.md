# cert-sync-controller Helm Chart

Helm chart for deploying cert-sync-controller, a Kubernetes controller that automatically syncs TLS certificates from Ingress resources to remote servers.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- SSH access to remote server

## Installation

### 1. Create SSH key secret

```bash
# Generate SSH key pair
ssh-keygen -t rsa -b 4096 -f cert-sync-key -N ""

# Copy public key to remote server
ssh-copy-id -i cert-sync-key.pub cert-sync@192.168.100.123

# Create Kubernetes secret
kubectl create namespace cert-sync
kubectl create secret generic cert-sync-ssh-key \
  -n cert-sync \
  --from-file=id_rsa=cert-sync-key

# Clean up local key
rm cert-sync-key cert-sync-key.pub
```

### 2. Install chart

#### From OCI registry (Recommended)

```bash
helm install cert-sync-controller \
  oci://ghcr.io/leetsheep/cert-sync-controller \
  --namespace cert-sync \
  --create-namespace \
  --set remote.ip=192.168.100.123 \
  --set rbac.mode=namespaced \
  --set rbac.allowedNamespaces='{cert-manager,traefik}'
```

Or with a values file:

```bash
helm install cert-sync-controller \
  oci://ghcr.io/leetsheep/cert-sync-controller \
  --namespace cert-sync \
  --create-namespace \
  -f my-values.yaml
```

#### From local source

```bash
git clone https://github.com/leetsheep/cert-sync-controller.git
cd cert-sync-controller

helm install cert-sync ./helm/cert-sync-controller \
  --namespace cert-sync \
  --create-namespace \
  --set remote.ip=192.168.100.123 \
  --set rbac.mode=namespaced \
  --set rbac.allowedNamespaces='{cert-manager,traefik}'
```

## Configuration

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `rbac.mode` | RBAC mode: `namespaced` (recommended) or `cluster` | `namespaced` |
| `rbac.allowedNamespaces` | Namespaces where secrets can be read (only for `namespaced` mode) | `[cert-manager, traefik, default]` |
| `remote.ip` | IP address of remote server | `192.168.100.123` |
| `remote.user` | SSH user on remote server | `cert-sync` |
| `remote.certDir` | Remote certificate directory | `/opt/traefik/certs` |
| `remote.configDir` | Remote config directory | `/etc/traefik/config` |
| `remote.skipConfigGeneration` | Skip Traefik config generation (for Nginx, HAProxy, etc.) | `false` |
| `controller.reconcileInterval` | Sync interval in seconds | `30` |
| `controller.debug` | Enable debug logging | `false` |
| `ssh.existingSecret` | Name of existing secret with SSH key | `cert-sync-ssh-key` |

### Example: Secure Production Deployment

```yaml
# production-values.yaml
rbac:
  mode: namespaced
  allowedNamespaces:
    - cert-manager
    - traefik

remote:
  ip: "192.168.100.123"
  user: "cert-sync"
  certDir: "/opt/traefik/certs"
  configDir: "/etc/traefik/config"

controller:
  reconcileInterval: 60
  debug: false

resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"

serviceMonitor:
  enabled: true
```

### Example: Nginx Backend

```yaml
# nginx-values.yaml
rbac:
  mode: namespaced
  allowedNamespaces:
    - default

remote:
  ip: "nginx-server.example.com"
  user: "nginx"
  certDir: "/etc/nginx/certs"
  skipConfigGeneration: true  # No Traefik config needed

controller:
  reconcileInterval: 120
```

## Security Modes

### Namespaced Mode (Recommended)

```yaml
rbac:
  mode: namespaced
  allowedNamespaces:
    - cert-manager
    - traefik
```

- Controller can only read secrets from specified namespaces
- Uses RoleBindings per namespace
- Recommended for production environments
- Minimizes attack surface if controller is compromised

### Cluster Mode (Not Recommended)

```yaml
rbac:
  mode: cluster
```

- Controller can read secrets from ALL namespaces
- Uses ClusterRoleBinding
- Security risk: compromised controller has access to all secrets
- Only use in development/testing environments

## Upgrading

### From OCI registry

```bash
helm upgrade cert-sync-controller \
  oci://ghcr.io/leetsheep/cert-sync-controller \
  --namespace cert-sync \
  -f my-values.yaml
```

### From local source

```bash
git pull
helm upgrade cert-sync ./helm/cert-sync-controller \
  --namespace cert-sync \
  -f my-values.yaml
```

## Uninstallation

```bash
helm uninstall cert-sync-controller --namespace cert-sync

# Optionally delete the namespace
kubectl delete namespace cert-sync
```

## Monitoring

### Prometheus Metrics

If Prometheus Operator is installed, enable ServiceMonitor:

```yaml
serviceMonitor:
  enabled: true
  interval: 30s
```

Available metrics:
- `cert_sync_controller_up`: Controller status (1=up, 0=down)
- `cert_sync_total_syncs`: Total number of sync operations
- `cert_sync_success_syncs`: Successful sync operations
- `cert_sync_failed_syncs`: Failed sync operations
- `cert_sync_last_sync_timestamp`: Unix timestamp of last sync

### Health Checks

The controller exposes health checks on port 8080:

```bash
kubectl port-forward -n cert-sync svc/cert-sync-controller 8080:8080
curl http://localhost:8080/
```

Returns:
- `200 OK` - Healthy (last sync < 2 minutes ago)
- `503 Service Unavailable` - Stale or not initialized

## Troubleshooting

### View logs

```bash
kubectl logs -n cert-sync -l app.kubernetes.io/name=cert-sync-controller -f
```

### Enable debug logging

```bash
helm upgrade cert-sync ./cert-sync-controller \
  --namespace cert-sync \
  --reuse-values \
  --set controller.debug=true
```

### Test SSH connection

```bash
kubectl exec -it -n cert-sync deployment/cert-sync-controller -- \
  ssh -i /secrets/id_rsa cert-sync@192.168.100.123 "echo OK"
```

### Check RBAC permissions

```bash
# Check if controller can read secrets in allowed namespaces
kubectl auth can-i get secrets \
  --as=system:serviceaccount:cert-sync:cert-sync \
  -n cert-manager
```

## License

MIT
