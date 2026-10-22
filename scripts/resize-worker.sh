#!/usr/bin/env bash
# resize-worker.sh – Đổi vCPU / RAM / disk của một worker k3s mà không giết job đang chạy.
# Chạy bằng root trên Proxmox host (cần SSH được vào k3s-server-1 để chạy kubectl).
#
#   bash resize-worker.sh <vmid> <node-name> [cores] [mem_gb] [disk_gb]
#   bash resize-worker.sh 211 k3s-worker-1 10            # chỉ đổi vCPU
#   bash resize-worker.sh 212 k3s-worker-2 14 30 200     # vCPU + RAM + disk
#
# Trình tự: cordon -> chờ hết runner pod trên node -> drain -> qm set / disk resize ->
# qm reboot (áp dụng thay đổi phần cứng) -> chờ node Ready -> uncordon.
# Disk chỉ tăng, không giảm được. Làm lần lượt từng worker.

main() (
set -uo pipefail

VMID=${1:-} NODE=${2:-} CORES=${3:-} MEM_GB=${4:-} DISK_GB=${5:-}
SERVER=${SERVER:-ubuntu@192.168.8.2}
WAIT_JOBS_SEC=${WAIT_JOBS_SEC:-7200}     # chờ job trên node xong tối đa bao lâu
WAIT_READY_SEC=${WAIT_READY_SEC:-600}

die() { echo "[FAIL] $*" >&2; exit 1; }
k()   { ssh -o BatchMode=yes "$SERVER" "kubectl $*"; }

[[ -n $VMID && -n $NODE && ( -n $CORES || -n $MEM_GB || -n $DISK_GB ) ]] \
  || die "Cách dùng: bash resize-worker.sh <vmid> <node-name> [cores] [mem_gb] [disk_gb]"
command -v qm >/dev/null || die "Chạy trên Proxmox host"
qm config "$VMID" >/dev/null 2>&1 || die "Không có VM $VMID"
name=$(qm config "$VMID" | awk -F': ' '/^name:/ { print $2 }')
[[ $name == "$NODE" ]] || die "VM $VMID tên '$name', không phải '$NODE'"
k get node "$NODE" >/dev/null || die "kubectl không thấy node $NODE (SSH tới $SERVER?)"

echo "== Hiện tại: $(qm config "$VMID" | awk -F': ' '/^(cores|memory|scsi0):/ { printf "%s=%s  ", $1, $2 }')"
echo "== Sẽ đổi:   ${CORES:+cores=$CORES  }${MEM_GB:+memory=$((MEM_GB * 1024))  }${DISK_GB:+scsi0=${DISK_GB}G}"
read -r -p "Gõ YES để làm: " ok </dev/tty
[[ $ok == YES ]] || { echo "Huỷ."; exit 1; }

echo "== Cordon $NODE (không nhận pod mới)"
k cordon "$NODE" || die "cordon lỗi"

echo "== Chờ runner pod trên $NODE chạy xong job"
deadline=$((SECONDS + WAIT_JOBS_SEC))
while n=$(k get pods -n arc-runners --field-selector spec.nodeName="$NODE" --no-headers 2>/dev/null | wc -l); (( n > 0 )); do
  (( SECONDS > deadline )) && die "Quá ${WAIT_JOBS_SEC}s vẫn còn $n runner pod. Node vẫn đang cordon: chờ thêm rồi chạy lại, hoặc 'kubectl uncordon $NODE' để huỷ"
  echo "   $(date +%T) còn $n runner pod"; sleep 30
done

echo "== Drain $NODE"
k drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s || die "drain lỗi"

echo "== Đổi cấu hình VM $VMID"
args=()
[[ -n $CORES ]]  && args+=(--cores "$CORES")
[[ -n $MEM_GB ]] && args+=(--memory $((MEM_GB * 1024)))
(( ${#args[@]} )) && { qm set "$VMID" "${args[@]}" || die "qm set lỗi"; }
[[ -n $DISK_GB ]] && { qm disk resize "$VMID" scsi0 "${DISK_GB}G" || die "disk resize lỗi (disk chỉ tăng được)"; }

echo "== Reboot VM $VMID để áp dụng"
qm reboot "$VMID" || die "qm reboot lỗi"

echo "== Chờ $NODE Ready"
deadline=$((SECONDS + WAIT_READY_SEC))
sleep 20
until k get node "$NODE" --no-headers 2>/dev/null | awk '{ exit !($2 == "Ready,SchedulingDisabled" || $2 == "Ready") }'; do
  (( SECONDS > deadline )) && die "$NODE chưa Ready sau ${WAIT_READY_SEC}s. Xem Console VM $VMID"
  sleep 10
done

echo "== Uncordon $NODE"
k uncordon "$NODE" || die "uncordon lỗi"
k describe node "$NODE" | grep -A6 '^Allocatable'
echo "== Xong: $(qm config "$VMID" | awk -F': ' '/^(cores|memory|scsi0):/ { printf "%s=%s  ", $1, $2 }')"
)

main "$@"
