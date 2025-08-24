# Traefik Configuration

K3s comes with **Traefik pre-installed** as the default ingress controller. This directory contains Traefik-specific configurations.

## What's Included

- **`middleware.yml`**: Custom middlewares for IP whitelisting and HTTPS redirects
- **`global-https-redirect.yml`**: Global HTTP→HTTPS redirect enforcement

## Benefits

✅ **Zero Setup**: Traefik comes pre-configured with k3s  
✅ **Automatic Service Discovery**: Finds services automatically  
✅ **Self-signed TLS**: Automatic certificates for local development  
✅ **HTTPS Enforcement**: Global redirects for security

## Usage

Middlewares are applied automatically via `make apps` command.
