# Traefik Configuration

K3s comes with **Traefik pre-installed** as the default ingress controller. This directory contains additional Traefik configurations.

## What's Included

- **`middleware.yml`**: Custom middlewares for IP whitelisting and HTTPS redirects
- **`acme-config.yml`**: Example ACME configuration for automatic SSL certificates

## Key Benefits of Using Traefik with K3s

✅ **Zero Setup**: Traefik comes pre-configured with k3s  
✅ **Automatic Service Discovery**: Finds services automatically  
✅ **Built-in ACME Support**: No cert-manager needed  
✅ **Native Kubernetes Support**: CRDs for advanced configuration  
✅ **Lightweight**: Perfect for edge/IoT deployments

## Usage

1. **Apply middlewares**:

   ```bash
   kubectl apply -f kubernetes/traefik/middleware.yml
   ```

2. **Use in ingress resources**:
   ```yaml
   annotations:
     traefik.ingress.kubernetes.io/router.middlewares: default-https-redirect@kubernetescrd
   ```

## ACME/SSL Configuration

For automatic SSL certificates in production:

1. **Configure Traefik ACME** (via k3s server args or Traefik ConfigMap)
2. **Use standard Ingress TLS** - Traefik handles the rest automatically
3. **No cert-manager required** - Traefik has built-in ACME support

This eliminates the complexity of nginx-ingress + cert-manager while providing the same functionality.
