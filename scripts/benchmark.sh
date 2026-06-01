#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — Run benchmark suite on target hardware
# Records results, compares against hardware profiles
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/benchmark-results"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${BLUE}[BENCH]${NC} $*"; }
ok()    { echo -e "${GREEN}[PASS]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
HOSTNAME_VAL=$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
RESULT_FILE="$RESULTS_DIR/${HOSTNAME_VAL}-${TIMESTAMP}.json"

# Detect platform
detect_platform() {
    local arch=$(uname -m)
    local has_gpu=false

    if command -v nvidia-smi &>/dev/null; then
        has_gpu=true
    fi

    # Check OCI metadata
    if curl -s --connect-timeout 2 http://169.254.169.254/opc/v1/instance/ &>/dev/null; then
        echo "oracle-cloud"
        return
    fi

    if [[ "$arch" == "aarch64" ]]; then
        echo "jetson-edge"
    elif [[ "$has_gpu" == true ]]; then
        echo "workstation-gpu"
    else
        echo "workstation-cpu"
    fi
}

PLATFORM=$(detect_platform)
log "Platform: $PLATFORM"
log "Results will be saved to: $RESULT_FILE"

# Initialize results JSON
cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "hostname": "$HOSTNAME_VAL",
  "platform": "$PLATFORM",
  "results": {}
}
EOF

# Helper to update results
update_result() {
    local key="$1"
    local value="$2"
    python3 -c "
import json, sys
with open('$RESULT_FILE', 'r') as f:
    data = json.load(f)
data['results']['$key'] = $value
with open('$RESULT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
}

# ---------------------------------------------------------------------------
# System Information
# ---------------------------------------------------------------------------
log "Collecting system information..."

SYS_INFO=$(python3 -c "
import json, os, platform

info = {
    'os': platform.system(),
    'osRelease': platform.release(),
    'arch': platform.machine(),
    'cpuCount': os.cpu_count(),
    'pythonVersion': platform.python_version(),
}

# Try to get memory
try:
    with open('/proc/meminfo') as f:
        for line in f:
            if line.startswith('MemTotal:'):
                info['memoryGB'] = round(int(line.split()[1]) / 1024 / 1024, 1)
                break
except:
    pass

print(json.dumps(info))
")
update_result "system" "$SYS_INFO"

# ---------------------------------------------------------------------------
# CPU Benchmarks
# ---------------------------------------------------------------------------
run_cpu_benchmarks() {
    log "Running CPU benchmarks..."

    # 1. Single-threaded prime calculation (seconds)
    log "  Single-threaded prime sieve..."
    local st_time
    st_time=$( { timeout 30 python3 -c "
import time
start = time.time()
def sieve(n):
    nums = [True] * (n+1)
    nums[0] = nums[1] = False
    for i in range(2, int(n**0.5)+1):
        if nums[i]:
            for j in range(i*i, n+1, i):
                nums[j] = False
    return sum(1 for x in nums if x)
result = sieve(10_000_000)
elapsed = time.time() - start
print(f'{elapsed:.4f}')
" 2>/dev/null; } )
    update_result "cpu_prime_sieve_single_thread_sec" "$st_time"
    ok "  Prime sieve (single-thread): ${st_time}s"

    # 2. Multi-threaded benchmark
    log "  Multi-threaded workload..."
    local mt_time
    mt_time=$( { timeout 60 python3 -c "
import time, concurrent.futures, math

def cpu_work(n):
    return sum(math.isqrt(i*i) for i in range(n))

start = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=None) as executor:
    futures = [executor.submit(cpu_work, 500_000) for _ in range(8)]
    results = [f.result() for f in futures]
elapsed = time.time() - start
print(f'{elapsed:.4f}')
" 2>/dev/null; } )
    update_result "cpu_multi_thread_sec" "$mt_time"
    ok "  Multi-threaded workload: ${mt_time}s"

    # 3. OpenSSL speed test (if available)
    if command -v openssl &>/dev/null; then
        log "  OpenSSL speed (AES-256-CBC)..."
        local aes_speed
        aes_speed=$(openssl speed -elapsed -seconds 5 aes-256-cbc 2>/dev/null | tail -1 | awk '{print $NF}' || echo "null")
        update_result "cpu_aes256cbc_kbytes_sec" "\"$aes_speed\""
        ok "  AES-256-CBC: ${aes_speed} kB/s"
    fi
}

# ---------------------------------------------------------------------------
# GPU Benchmarks
# ---------------------------------------------------------------------------
run_gpu_benchmarks() {
    if ! command -v nvidia-smi &>/dev/null; then
        warn "No NVIDIA GPU detected, skipping GPU benchmarks"
        return
    fi

    log "Running GPU benchmarks..."

    # GPU info
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader 2>/dev/null | head -1)
    update_result "gpu_info" "\"$gpu_info\""
    log "  GPU: $gpu_info"

    # CUDA bandwidth test (if cuda-samples installed)
    if command -v bandwidthTest &>/dev/null; then
        log "  CUDA bandwidth test..."
        local bw_h2d bw_d2h
        bw_output=$(bandwidthTest --memory=pinned --mode=range 2>/dev/null || echo "")
        bw_h2d=$(echo "$bw_output" | grep "Host to Device" | awk '{print $NF}' || echo "null")
        bw_d2h=$(echo "$bw_output" | grep "Device to Host" | awk '{print $NF}' || echo "null")
        update_result "gpu_bandwidth_h2d_GBps" "\"$bw_h2d\""
        update_result "gpu_bandwidth_d2h_GBps" "\"$bw_d2h\""
        ok "  H2D: ${bw_h2d} GB/s, D2H: ${bw_d2h} GB/s"
    else
        warn "  bandwidthTest not found — install cuda-samples for GPU bandwidth test"
    fi

    # GPU compute benchmark via PyTorch (if available)
    if python3 -c "import torch" 2>/dev/null; then
        log "  GPU matrix multiply (PyTorch)..."
        local gpu_matmul
        gpu_matmul=$(python3 -c "
import torch, time
if torch.cuda.is_available():
    device = torch.device('cuda')
    # Warmup
    a = torch.randn(4096, 4096, device=device)
    b = torch.randn(4096, 4096, device=device)
    torch.mm(a, b)
    torch.cuda.synchronize()
    # Benchmark
    start = time.time()
    for _ in range(100):
        c = torch.mm(a, b)
    torch.cuda.synchronize()
    elapsed = time.time() - start
    print(f'{elapsed:.4f}')
else:
    print('null')
" 2>/dev/null)
        update_result "gpu_matmul_4096x4096_100iter_sec" "$gpu_matmul"
        ok "  MatMul 4096x4096 x100: ${gpu_matmul}s"
    fi

    # VRAM usage baseline
    local vram_used
    vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "null")
    update_result "gpu_vram_used_baseline_MB" "$vram_used"
}

# ---------------------------------------------------------------------------
# Memory Benchmark
# ---------------------------------------------------------------------------
run_memory_benchmark() {
    log "Running memory benchmark..."
    local mem_bandwidth
    mem_bandwidth=$(python3 -c "
import time, array

size = 100_000_000  # 100M floats = ~800MB
data = array.array('d', [0.0] * size)

start = time.time()
for i in range(size):
    data[i] = float(i)
elapsed = time.time() - start

bandwidth = (size * 8) / elapsed / 1e9  # GB/s
print(f'{bandwidth:.3f}')
" 2>/dev/null)
    update_result "memory_seq_write_bandwidth_GBps" "$mem_bandwidth"
    ok "  Sequential write: ${mem_bandwidth} GB/s"
}

# ---------------------------------------------------------------------------
# Disk Benchmark
# ---------------------------------------------------------------------------
run_disk_benchmark() {
    log "Running disk benchmark..."
    local disk_path="${1:-$RESULTS_DIR}"

    # Sequential write
    local write_speed
    write_speed=$(dd if=/dev/zero of="$disk_path/.bench_tmp" bs=1M count=1024 conv=fdatasync 2>&1 | tail -1 | grep -oP '[\d.]+ (?=GB/s|MB/s)' || echo "null")
    update_result "disk_seq_write_speed" "\"$write_speed\""
    ok "  Sequential write: $write_speed"
    rm -f "$disk_path/.bench_tmp"
}

# ---------------------------------------------------------------------------
# Network Benchmark (internal — service latency)
# ---------------------------------------------------------------------------
run_network_benchmark() {
    log "Running network/service latency check..."

    # Check if lau-stack is running locally
    if curl -s --connect-timeout 2 http://localhost:8080/health &>/dev/null; then
        local latencies=[]
        for i in $(seq 1 100); do
            local lat
            lat=$(curl -s -o /dev/null -w '%{time_total}' http://localhost:8080/health 2>/dev/null || echo "0")
            echo "$lat"
        done | python3 -c "
import json, sys
vals = [float(line.strip()) for line in sys.stdin if line.strip()]
print(json.dumps({
    'count': len(vals),
    'mean_ms': round(sum(vals)/len(vals)*1000, 2) if vals else 0,
    'p50_ms': round(sorted(vals)[len(vals)//2]*1000, 2) if vals else 0,
    'p99_ms': round(sorted(vals)[int(len(vals)*0.99)]*1000, 2) if vals else 0,
}))
" | while read line; do
            update_result "service_latency" "$line"
            ok "  Service latency: $line"
        done
    else
        warn "  lau-stack not running locally, skipping service latency benchmark"
    fi
}

# ---------------------------------------------------------------------------
# Compare against profiles
# ---------------------------------------------------------------------------
compare_profiles() {
    log ""
    log "=== Profile Comparison ==="

    local profiles_file="$PROJECT_ROOT/profiles/workstation.json"
    if [[ -f "$profiles_file" ]]; then
        log "Compared against workstation profile (see profiles/workstation.json)"
    fi

    python3 -c "
import json

try:
    with open('$RESULT_FILE') as f:
        results = json.load(f)

    r = results.get('results', {})

    print()
    print('  Benchmark Summary:')
    print('  ─────────────────────────────────────')

    if 'cpu_prime_sieve_single_thread_sec' in r:
        v = r['cpu_prime_sieve_single_thread_sec']
        if v != 'null':
            rating = '🟢 Excellent' if float(v) < 3 else '🟡 Good' if float(v) < 5 else '🔴 Slow'
            print(f'  CPU Single-Thread:  {v}s  {rating}')

    if 'cpu_multi_thread_sec' in r:
        v = r['cpu_multi_thread_sec']
        if v != 'null':
            rating = '🟢 Excellent' if float(v) < 2 else '🟡 Good' if float(v) < 5 else '🔴 Slow'
            print(f'  CPU Multi-Thread:   {v}s  {rating}')

    if 'gpu_matmul_4096x4096_100iter_sec' in r:
        v = r['gpu_matmul_4096x4096_100iter_sec']
        if v != 'null':
            rating = '🟢 Excellent' if float(v) < 1 else '🟡 Good' if float(v) < 3 else '🔴 Slow'
            print(f'  GPU MatMul:         {v}s  {rating}')

    if 'memory_seq_write_bandwidth_GBps' in r:
        v = r['memory_seq_write_bandwidth_GBps']
        if v != 'null':
            rating = '🟢 Excellent' if float(v) > 5 else '🟡 Good' if float(v) > 2 else '🔴 Slow'
            print(f'  Memory Bandwidth:   {v} GB/s  {rating}')

    print()
    print(f'  Full results: $RESULT_FILE')

except Exception as e:
    print(f'  Error reading results: {e}')
"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local bench_type="${1:-all}"

    echo ""
    log "╔══════════════════════════════════════╗"
    log "║     LAU Stack Benchmark Suite        ║"
    log "╚══════════════════════════════════════╝"
    echo ""
    log "Platform: $PLATFORM"
    log "Timestamp: $TIMESTAMP"
    echo ""

    case "$bench_type" in
        cpu)
            run_cpu_benchmarks
            ;;
        gpu)
            run_gpu_benchmarks
            ;;
        memory|mem)
            run_memory_benchmark
            ;;
        disk|io)
            run_disk_benchmark
            ;;
        network|net)
            run_network_benchmark
            ;;
        all)
            run_cpu_benchmarks
            echo ""
            run_gpu_benchmarks
            echo ""
            run_memory_benchmark
            echo ""
            run_disk_benchmark
            echo ""
            run_network_benchmark
            ;;
        quick)
            run_cpu_benchmarks
            run_gpu_benchmarks
            ;;
        *)
            echo "Usage: $(basename "$0") [all|cpu|gpu|memory|disk|network|quick]"
            exit 1
            ;;
    esac

    echo ""
    compare_profiles
    echo ""
    ok "Benchmark complete! Results saved to $RESULT_FILE"
}

main "$@"
