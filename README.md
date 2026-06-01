# LAU Cloud Deploy

Deployment and configuration layer for the **SuperInstance/LAU** compute stack. Hardware profiles, container configs, Kubernetes orchestration, and one-command deployment across Oracle Cloud, NVIDIA Jetson, and local workstations.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SuperInstance / LAU Stack                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │   Go     │  │  Chapel  │  │    C     │  │  Python  │  │  Shell   │ │
│  │ Service  │  │ Runtime  │  │ Library  │  │ Scripts  │  │   CLI    │ │
│  │ (API)    │  │ (HPC)    │  │ (GPU)    │  │ (ML/AI)  │  │ (Glue)   │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘ │
│       │              │              │              │              │       │
│       └──────────────┴──────────────┴──────────────┴──────────────┘       │
│                                  │                                      │
│                    ┌─────────────┴─────────────┐                         │
│                    │    Shared Compute Layer    │                         │
│                    │   (libcompute.so / CUDA)   │                         │
│                    └─────────────┬─────────────┘                         │
│                                  │                                      │
├──────────────────────────────────┼──────────────────────────────────────┤
│         DEPLOYMENT LAYER (this repo)│                                   │
│                                  │                                      │
│  ┌─────────────┐  ┌─────────────┴─────────────┐  ┌─────────────┐       │
│  │  Profiles   │  │      Containers (Docker)    │  │    K8s /    │       │
│  │  (Hardware) │  │  .gpu  .cpu  .edge          │  │ Terraform   │       │
│  └──────┬──────┘  └─────────────┬───────────────┘  └──────┬──────┘       │
│         │                      │                          │              │
│         └──────────────────────┴──────────────────────────┘              │
│                                │                                        │
├────────────────────────────────┼────────────────────────────────────────┤
│                         TARGET PLATFORMS                                │
│                                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │Workstation│  │ Oracle   │  │ Oracle   │  │  Jetson  │               │
│  │RTX 4050  │  │ Cloud VM │  │ Cloud ARM│  │   Edge   │               │
│  │(x86+GPU) │  │(x86+GPU) │  │(Free Tier│  │(ARM+GPU) │               │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Auto-detect platform and deploy
./scripts/deploy.sh

# Build for specific target
./scripts/deploy.sh oracle-arm --build-only

# Deploy to Kubernetes
./scripts/deploy.sh oracle-vm

# Provision infrastructure
./scripts/deploy.sh --terraform

# Run benchmarks
./scripts/benchmark.sh all
```

## Directory Structure

```
lau-cloud-deploy/
├── profiles/               # Hardware profile definitions
│   ├── oracle.json         # OCI compute shapes (E4.Flex, A1.Flex, BM.E4.128, GPU)
│   ├── jetson.json         # Jetson family (Nano, Orin Nano, Orin NX, AGX Orin)
│   └── workstation.json    # Local dev workstation (Ryzen AI 9 + RTX 4050)
├── docker/                 # Multi-architecture container builds
│   ├── Dockerfile.gpu      # Full stack with CUDA (x86_64 + GPU)
│   ├── Dockerfile.cpu      # CPU-only for Oracle ARM free tier (aarch64)
│   └── Dockerfile.edge     # Minimal Jetson build (ARM64 + CUDA, no Go/Chapel)
├── k8s/
│   ├── base/               # Platform-agnostic Kubernetes manifests
│   │   ├── namespace.yaml
│   │   ├── configmap.yaml  # Hardware profiles as config
│   │   ├── secret.yaml     # API keys (template)
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml        # Horizontal pod autoscaler
│   └── oracle/             # Oracle Cloud specific
│       ├── loadbalancer.yaml  # OCI flexible load balancer
│       └── oke-cluster.yaml   # OKE cluster reference config
├── terraform/              # Infrastructure as Code
│   ├── main.tf             # VCN, subnets, compute instances, GPU shapes
│   ├── variables.tf        # Variable definitions
│   └── terraform.tfvars.example
├── scripts/
│   ├── deploy.sh           # One-command deploy (detect → build → push → deploy)
│   └── benchmark.sh        # Hardware benchmark suite with profile comparison
└── README.md
```

## Target Platforms

### 1. Local Workstation (RTX 4050)

| Component | Spec |
|-----------|------|
| CPU | AMD Ryzen AI 9 HX 370 (12C/24T) |
| GPU | NVIDIA RTX 4050 Laptop (6GB VRAM, sm_89) |
| RAM | 32GB LPDDR5X |
| CUDA | 12.5 |

**Deploy:** `./scripts/deploy.sh local`

Uses `Dockerfile.gpu` with CUDA 12.5, AVX-512, and the full Go + Chapel + C stack.

### 2. Oracle Cloud — ARM Free Tier (A1.Flex)

| Component | Spec |
|-----------|------|
| CPU | Ampere Altra (ARM Neoverse N1) |
| OCPUs | 4 (free) |
| RAM | 24GB (free) |
| GPU | None |

**Deploy:** `./scripts/deploy.sh oracle-arm`

Uses `Dockerfile.cpu` — Go and Chapel cross-compiled for ARM64, CPU-only C library with NEON optimizations. **Free forever.**

### 3. Oracle Cloud — GPU Shapes

| Shape | GPU | VRAM | OCPUs |
|-------|-----|------|-------|
| VM.GPU.A10.1 | 1x A10 | 24GB | 15 |
| BM.GPU4.8 | 8x A100 | 320GB | 64 |

**Deploy:** `./scripts/deploy.sh oracle-gpu`

### 4. NVIDIA Jetson (Edge)

| Device | GPU | RAM | Power |
|--------|-----|-----|-------|
| Jetson Nano | Maxwell 128-core | 4GB | 5W/10W |
| Orin Nano | Ampere 1024-core | 8GB | 7W/15W |
| Orin NX | Ampere 1024-core | 16GB | 10W/25W |
| AGX Orin | Ampere 2048-core | 64GB | 15W/60W |

**Deploy:** `./scripts/deploy.sh jetson`

Uses `Dockerfile.edge` — minimal C + CUDA only, no Go or Chapel runtime overhead.

## Container Images

| Image | Target | Arch | GPU | Stack |
|-------|--------|------|-----|-------|
| `lau-stack:gpu` | Workstation, OCI GPU | x86_64 | ✅ | Go + Chapel + C + CUDA |
| `lau-stack:cpu` | OCI VM, bare metal | x86_64 | ❌ | Go + Chapel + C |
| `lau-stack:cpu-arm64` | OCI A1.Flex | arm64 | ❌ | Go + Chapel + C (NEON) |
| `lau-stack:edge` | Jetson family | arm64 | ✅ | C + CUDA only |

## Kubernetes Deployment

```bash
# Apply all base manifests
kubectl apply -f k8s/base/

# For Oracle Cloud deployments
kubectl apply -f k8s/oracle/

# Update platform target
kubectl patch configmap lau-hardware-profiles \
  -n lau-stack \
  --type merge \
  -p '{"data":{"TARGET_PLATFORM":"oracle-arm"}}'
```

### GPU Scheduling

For GPU nodes, add the `nvidia.com/gpu` resource limit to the deployment:

```yaml
resources:
  limits:
    nvidia.com/gpu: "1"
```

And ensure the NVIDIA device plugin is installed on the cluster.

## Terraform (Oracle Cloud)

```bash
cd terraform/

# Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OCI credentials

# Plan & apply
terraform init
terraform plan
terraform apply
```

Provisions:
- VCN with public/private subnets
- Internet gateway and route tables
- Security lists (SSH, HTTP, HTTPS, internal)
- A1.Flex ARM instance (free tier) with Docker pre-installed
- Optional: GPU and bare-metal instances (uncomment in main.tf)

## Benchmarking

```bash
# Full benchmark suite
./scripts/benchmark.sh all

# Specific benchmarks
./scripts/benchmark.sh cpu
./scripts/benchmark.sh gpu
./scripts/benchmark.sh memory

# Quick benchmark (CPU + GPU only)
./scripts/benchmark.sh quick
```

Results are saved to `benchmark-results/` as JSON files with timestamps, enabling comparison across hardware targets over time.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET_PLATFORM` | `workstation` | Target hardware platform |
| `CUDA_ARCH` | `sm_89` | CUDA compute capability |
| `LAU_LOG_LEVEL` | `info` | Logging verbosity |
| `LAU_WORKER_THREADS` | `0` (auto) | Worker thread count |
| `LAU_BATCH_SIZE` | `1024` | Processing batch size |
| `LAU_ENABLE_CUDA` | `auto` | CUDA enable (auto/true/false) |

## License

See the main SuperInstance repository.
