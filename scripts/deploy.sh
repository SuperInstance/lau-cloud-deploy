#!/usr/bin/env bash
# =============================================================================
# deploy.sh — One-command deployment for LAU Stack
# Detects target platform, builds appropriate container, pushes, and deploys
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[DEPLOY]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Detect target platform
# ---------------------------------------------------------------------------
detect_target() {
    local target="${1:-auto}"

    if [[ "$target" == "auto" ]]; then
        log "Auto-detecting target platform..."

        # Check for NVIDIA GPU
        if command -v nvidia-smi &>/dev/null; then
            local gpu_name
            gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "")

            if echo "$gpu_name" | grep -qi "jetson\|orin\|tx2\|xavier"; then
                echo "jetson"
                return
            fi

            if [[ -n "$gpu_name" ]]; then
                echo "local"
                return
            fi
        fi

        # Check for OCI cloud instance metadata
        if curl -s --connect-timeout 2 http://169.254.169.254/opc/v1/instance/ &>/dev/null; then
            local shape
            shape=$(curl -s http://169.254.169.254/opc/v1/instance/ | python3 -c "import sys,json; print(json.load(sys.stdin).get('shape',''))" 2>/dev/null || echo "")

            if echo "$shape" | grep -qi "a1\|ampere"; then
                echo "oracle-arm"
            elif echo "$shape" | grep -qi "bm\."; then
                echo "oracle-bm"
            elif echo "$shape" | grep -qi "gpu"; then
                echo "oracle-gpu"
            else
                echo "oracle-vm"
            fi
            return
        fi

        # Check architecture
        local arch
        arch=$(uname -m)
        if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
            echo "jetson"  # Assume Jetson if ARM64 without GPU detection
        else
            echo "local"   # Default: local workstation
        fi
        return
    fi

    echo "$target"
}

# ---------------------------------------------------------------------------
# Build functions
# ---------------------------------------------------------------------------
build_gpu() {
    log "Building GPU container (x86_64 + CUDA)..."
    docker build \
        -f "$PROJECT_ROOT/docker/Dockerfile.gpu" \
        -t "lau-stack:gpu" \
        --build-arg CUDA_ARCH="${CUDA_ARCH:-sm_89}" \
        "$PROJECT_ROOT"
    ok "GPU image built: lau-stack:gpu"
}

build_cpu_arm64() {
    log "Building CPU container (ARM64 for Oracle Cloud free tier)..."
    if docker buildx inspect arm64-builder &>/dev/null; then
        docker buildx use arm64-builder
    else
        docker buildx create --name arm64-builder --platform linux/arm64
        docker buildx use arm64-builder
    fi
    docker buildx build \
        --platform linux/arm64 \
        -f "$PROJECT_ROOT/docker/Dockerfile.cpu" \
        -t "lau-stack:cpu-arm64" \
        --load \
        "$PROJECT_ROOT"
    ok "CPU ARM64 image built: lau-stack:cpu-arm64"
}

build_cpu_x86() {
    log "Building CPU container (x86_64)..."
    docker build \
        -f "$PROJECT_ROOT/docker/Dockerfile.cpu" \
        -t "lau-stack:cpu" \
        "$PROJECT_ROOT"
    ok "CPU image built: lau-stack:cpu"
}

build_edge() {
    log "Building edge container (Jetson ARM64 + CUDA)..."
    local cuda_arch="${1:-sm_87}"
    docker build \
        -f "$PROJECT_ROOT/docker/Dockerfile.edge" \
        -t "lau-stack:edge" \
        --build-arg CUDA_ARCH="$cuda_arch" \
        "$PROJECT_ROOT"
    ok "Edge image built: lau-stack:edge"
}

# ---------------------------------------------------------------------------
# Deploy functions
# ---------------------------------------------------------------------------
deploy_local() {
    log "Deploying locally with Docker..."
    docker run -d \
        --name lau-stack \
        --gpus all \
        -p 8080:8080 \
        -p 9090:9090 \
        --restart unless-stopped \
        lau-stack:gpu
    ok "Local deployment running on http://localhost:8080"
}

deploy_k8s() {
    local target="$1"
    log "Deploying to Kubernetes (target: $target)..."

    # Apply base manifests
    kubectl apply -f "$PROJECT_ROOT/k8s/base/namespace.yaml"
    kubectl apply -f "$PROJECT_ROOT/k8s/base/configmap.yaml"
    kubectl apply -f "$PROJECT_ROOT/k8s/base/secret.yaml"
    kubectl apply -f "$PROJECT_ROOT/k8s/base/deployment.yaml"
    kubectl apply -f "$PROJECT_ROOT/k8s/base/service.yaml"
    kubectl apply -f "$PROJECT_ROOT/k8s/base/hpa.yaml"

    # Apply platform-specific manifests
    case "$target" in
        oracle-vm|oracle-bm|oracle-arm|oracle-gpu)
            kubectl apply -f "$PROJECT_ROOT/k8s/oracle/"
            ;;
    esac

    # Update platform in configmap
    kubectl patch configmap lau-hardware-profiles \
        -n lau-stack \
        --type merge \
        -p "{\"data\":{\"TARGET_PLATFORM\":\"$target\"}}"

    ok "Kubernetes deployment applied"
    kubectl get pods -n lau-stack
}

deploy_terraform() {
    log "Provisioning infrastructure with Terraform..."
    cd "$PROJECT_ROOT/terraform"

    if [[ ! -f terraform.tfvars ]]; then
        warn "No terraform.tfvars found. Copy terraform.tfvars.example and fill in values."
        cp terraform.tfvars.example terraform.tfvars
        fail "Edit terraform/terraform.tfvars with your OCI credentials, then re-run."
    fi

    terraform init
    terraform plan -out=tfplan
    log "Review the plan above. Applying in 10 seconds..."
    sleep 10
    terraform apply tfplan
    ok "Infrastructure provisioned"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [TARGET] [OPTIONS]

Targets:
  auto        Auto-detect platform (default)
  local       Local workstation with GPU
  oracle-vm   Oracle Cloud VM (x86_64)
  oracle-bm   Oracle Cloud Bare Metal
  oracle-arm  Oracle Cloud ARM (A1.Flex free tier)
  oracle-gpu  Oracle Cloud GPU instance
  jetson      NVIDIA Jetson (edge)

Options:
  --build-only     Build image without deploying
  --push           Push image to registry after build
  --registry URL   Container registry URL
  --skip-build     Skip build, deploy existing image
  --terraform      Provision infrastructure with Terraform
  --help           Show this help

Examples:
  $(basename "$0")                         # Auto-detect and deploy
  $(basename "$0") oracle-arm --build-only # Build ARM image
  $(basename "$0") local --push --registry ghcr.io/myorg
  $(basename "$0") --terraform             # Provision OCI infrastructure
EOF
}

main() {
    local target="auto"
    local build_only=false
    local push=false
    local registry=""
    local skip_build=false
    local use_terraform=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-only)   build_only=true; shift ;;
            --push)         push=true; shift ;;
            --registry)     registry="$2"; shift 2 ;;
            --skip-build)   skip_build=true; shift ;;
            --terraform)    use_terraform=true; shift ;;
            --help|-h)      usage; exit 0 ;;
            -*)             fail "Unknown option: $1. Use --help for usage." ;;
            *)              target="$1"; shift ;;
        esac
    done

    echo ""
    log "=== LAU Stack Deployment ==="
    log "Project root: $PROJECT_ROOT"
    echo ""

    # Terraform mode
    if [[ "$use_terraform" == true ]]; then
        deploy_terraform
        exit 0
    fi

    # Detect target
    local platform
    platform=$(detect_target "$target")
    log "Target platform: $platform"
    echo ""

    # Build
    if [[ "$skip_build" == false ]]; then
        case "$platform" in
            local)        build_gpu ;;
            oracle-vm)    build_cpu_x86 ;;
            oracle-bm)    build_cpu_x86 ;;
            oracle-arm)   build_cpu_arm64 ;;
            oracle-gpu)   build_gpu ;;
            jetson)       build_edge "sm_87" ;;
            *)            fail "Unknown platform: $platform" ;;
        esac
    fi

    # Push
    if [[ "$push" == true && -n "$registry" ]]; then
        local image_tag
        case "$platform" in
            local|oracle-gpu) image_tag="lau-stack:gpu" ;;
            oracle-arm)       image_tag="lau-stack:cpu-arm64" ;;
            oracle-vm|oracle-bm) image_tag="lau-stack:cpu" ;;
            jetson)           image_tag="lau-stack:edge" ;;
            *)                fail "Unknown platform" ;;
        esac

        log "Pushing to $registry..."
        docker tag "$image_tag" "$registry/$image_tag"
        docker push "$registry/$image_tag"
        ok "Image pushed to $registry"
    fi

    if [[ "$build_only" == true ]]; then
        ok "Build complete (--build-only specified, skipping deploy)"
        exit 0
    fi

    # Deploy
    case "$platform" in
        local)  deploy_local ;;
        oracle-vm|oracle-bm|oracle-arm|oracle-gpu) deploy_k8s "$platform" ;;
        jetson)
            log "Jetson deployment — starting edge container..."
            docker run -d \
                --name lau-stack \
                --runtime nvidia \
                -p 8080:8080 \
                --restart unless-stopped \
                --env NVIDIA_VISIBLE_DEVICES=all \
                lau-stack:edge
            ok "Edge deployment running on http://localhost:8080"
            ;;
        *) fail "Unknown platform: $platform" ;;
    esac

    echo ""
    ok "Deployment complete!"
}

main "$@"
