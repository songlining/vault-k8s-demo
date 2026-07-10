# Podman Desktop Migration Guide

This demo has been migrated from Docker Desktop to Podman Desktop in compliance with IBM's container runtime policy.

## Overview

The demo uses `kind` (Kubernetes in Docker) for local Kubernetes clusters. Since kind v0.17.0, Podman is supported as a backend provider through the `KIND_EXPERIMENTAL_PROVIDER` environment variable.

## Migration Impact

**Low effort required.** The migration is minimal because:

1. **No Dockerfiles or docker-compose files** - The repo doesn't build custom images
2. **No direct Docker CLI calls** - Scripts use kubectl/helm, not docker commands
3. **kind abstraction** - kind handles container runtime differences transparently

## Prerequisites

Install Podman Desktop and the CLI:

```bash
# macOS (using Homebrew)
brew install podman

# Initialize Podman machine (required on macOS)
podman machine init
podman machine start

# Verify installation
podman version
```

## Using kind with Podman

### One-time setup (export in your shell profile)

```bash
# Add to ~/.zshrc or ~/.bashrc
export KIND_EXPERIMENTAL_PROVIDER=podman
```

### Per-session setup

```bash
# For current shell session only
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --name vault-lab
```

## Verification

After setting the provider variable, kind will use Podman instead of Docker:

```bash
# Create a test cluster
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --name test

# Verify it works
kubectl get nodes

# Clean up
kind delete cluster --name test
```

## Full Demo Setup with Podman

```bash
# 1. Set Podman as the kind provider
export KIND_EXPERIMENTAL_PROVIDER=podman

# 2. Create the cluster
kind create cluster --name vault-lab
kubectl config use-context kind-vault-lab

# 3. Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# 4. Run the demo setup
make setup
```

## Troubleshooting

### kind cannot connect to Podman

If you get connection errors, ensure Podman machine is running:

```bash
podman machine status
podman machine start  # if stopped
```

### Images not found

Podman maintains separate image storage from Docker. Pre-pull images if needed:

```bash
# kind will auto-pull most images, but you can pre-load:
kind load docker-image nginx:latest --name vault-lab
```

### Performance considerations

- First cluster creation with Podman may be slower as images are downloaded
- Subsequent runs are faster as images are cached in Podman's local storage

## Compatibility

- **kind version**: v0.17.0+ (Podman support requires this or newer)
- **Podman version**: 4.0+ recommended
- **macOS**: Requires `podman machine` (VM-based)
- **Linux**: Native Podman works directly

## Cleanup

```bash
# Delete the demo cluster
kind delete cluster --name vault-lab

# Optional: Stop Podman machine when not in use (macOS only)
podman machine stop
```

## Migration Checklist

- [x] Install Podman Desktop
- [x] Install Podman CLI
- [x] Set `KIND_EXPERIMENTAL_PROVIDER=podman`
- [x] Verify `kind create cluster` works
- [x] Test full demo flow (`make setup` and `make demo`)
- [x] Update documentation references
