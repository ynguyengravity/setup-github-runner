#!/usr/bin/env bash
# pve-discovery.sh – Kiểm tra Proxmox host trước khi dựng cụm k3s + ARC
# theo docs/proxmox-k3s-arc-guide.md. Script CHỈ ĐỌC, không tạo/sửa gì.
#
# Chạy bằng root trên Proxmox host (node sẽ chứa các VM):
#   bash pve-discovery.sh
# hoặc dán nguyên nội dung file vào Shell của Proxmox (web UI) cũng được.
#
# Đổi kế hoạch theo 1 trong 3 cách (xem bảng biến trong guide, bước 0):
#   1. Sửa giá trị mặc định trong khối "Kế hoạch" ngay dưới đây.
#   2. Đặt biến trước lệnh:  BRIDGE=vmbr1 STORAGE=local-lvm2 bash pve-discovery.sh
#   3. Trước khi dán vào terminal:  export BRIDGE=vmbr1 STORAGE=local-lvm2
#
# Exit code: 0 = không có FAIL, 1 = có ít nhất một FAIL, 2 = không chạy được.

# Toàn bộ script chạy trong subshell (main() ( ... )): chạy bằng bash, source, hay dán
# thẳng vào terminal đều không thoát phiên shell và không để lại 'set -u' / biến.
main() (
set -uo pipefail
set +m                                   # không in thông báo job khi quét ping song song

# ---------- Kế hoạch (mặc định theo guide) ----------
BRIDGE=${BRIDGE:-vmbr0}
STORAGE=${STORAGE:-local-lvm}
SNIPPET_STORAGE=${SNIPPET_STORAGE:-local}
GATEWAY=${GATEWAY:-}                     # để trống = default route qua BRIDGE, không có thì IP host trên BRIDGE (NAT)
PREFIX=${PREFIX:-}                       # để trống = lấy theo IP của bridge, không có thì 24
SCAN=${SCAN:-auto}                       # quét IP trống trong subnet host: auto | 1 | 0

TEMPLATE_ID=${TEMPLATE_ID:-9000}
SERVER_ID=${SERVER_ID:-201}
SERVER_IP=${SERVER_IP:-10.10.10.11}
WORKER_IDS=${WORKER_IDS:-"211 212 213 214"}
WORKER_IPS=${WORKER_IPS:-"10.10.10.21 10.10.10.22 10.10.10.23 10.10.10.24"}
MIRROR_ID=${MIRROR_ID:-220}
MIRROR_IP=${MIRROR_IP:-10.10.10.30}

SERVER_CORES=${SERVER_CORES:-4};   SERVER_MEM_GB=${SERVER_MEM_GB:-8};   SERVER_DISK_GB=${SERVER_DISK_GB:-60}
WORKER_CORES=${WORKER_CORES:-16};  WORKER_MEM_GB=${WORKER_MEM_GB:-32};  WORKER_DISK_GB=${WORKER_DISK_GB:-300}
MIRROR_CORES=${MIRROR_CORES:-2};   MIRROR_MEM_GB=${MIRROR_MEM_GB:-4};   MIRROR_DISK_GB=${MIRROR_DISK_GB:-200}

CPU_SAMPLE_SEC=${CPU_SAMPLE_SEC:-10}     # số giây đo tải CPU host

POD_MEM_GB=${POD_MEM_GB:-1}              # RAM request của 1 runner pod (runner + dind)
POD_CPU=${POD_CPU:-0.5}                  # CPU request của 1 runner pod
HOST_RESERVE_GB=${HOST_RESERVE_GB:-8}    # RAM chừa cho chính Proxmox

SSH_PUBKEY=${SSH_PUBKEY:-/root/.ssh/id_ed25519.pub}
CLOUD_IMAGE=${CLOUD_IMAGE:-/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img}

POD_CIDR=${POD_CIDR:-10.42.0.0/16}       # k3s cluster-cidr mặc định
SVC_CIDR=${SVC_CIDR:-10.43.0.0/16}       # k3s service-cidr mặc định
DIND_CIDR=${DIND_CIDR:-172.17.0.0/16}    # bridge docker0 bên trong mỗi dind

# ---------- Helpers ----------
if [[ -t 1 ]]; then
  G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' B=$'\e[1m' N=$'\e[0m'
else
  G='' Y='' R='' B='' N=''
fi
PASS=0 WARN=0 FAIL=0
ok()      { echo "  ${G}[OK]${N}   $*"; PASS=$((PASS + 1)); }
warn()    { echo "  ${Y}[WARN]${N} $*"; WARN=$((WARN + 1)); }
fail()    { echo "  ${R}[FAIL]${N} $*"; FAIL=$((FAIL + 1)); }
info()    { echo "  [INFO] $*"; }
section() { echo; echo "${B}== $* ==${N}"; }

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Hai CIDR (a.b.c.d/n) có giao nhau không
cidr_overlap() {
  local n1=${1%/*} p1=${1#*/} n2=${2%/*} p2=${2#*/}
  [[ $1 == */* ]] || p1=32
  [[ $2 == */* ]] || p2=32
  local p=$(( p1 < p2 ? p1 : p2 ))
  local mask=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  (( ($(ip2int "$n1") & mask) == ($(ip2int "$n2") & mask) ))
}

# Config hiện tại của VM/CT, bỏ phần snapshot
current_conf() { sed '/^\[/q' "$1"; }

conf_of_id() {
  ls /etc/pve/nodes/*/qemu-server/"$1".conf /etc/pve/nodes/*/lxc/"$1".conf 2>/dev/null | head -1
}

gb() { awk -v v="$1" 'BEGIN { printf "%.1f", v / 1024 }'; }   # MiB -> GiB

int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }

# In các dải IP trống trong <ip>/<prefix> (prefix >= 22): không trả lời ping/ARP,
# không có trong config VM/CT nào, không phải IP của host
suggest_free_ips() {
  local p=${1#*/} tmp n ip
  local mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )) addr=$(ip2int "${1%/*}")
  local first=$(( (addr & mask) + 1 )) last=$(( (addr | (~mask & 0xFFFFFFFF)) - 1 ))
  tmp=$(mktemp -d)
  (
    for ((n = first; n <= last; n++)); do
      ip=$(int2ip "$n")
      { ping -c1 -W1 "$ip" >/dev/null 2>&1 && touch "$tmp/$ip"; } &
      (( (n - first) % 256 == 255 )) && wait     # tối đa 256 ping song song
    done
    wait
  ) 2>/dev/null
  local -A used=()
  while read -r ip; do [[ -n $ip ]] && used[$ip]=1; done < <(
    ls "$tmp"
    ip neigh show | awk '/lladdr/ { print $1 }'
    grep -ohE 'ip=[0-9.]+/' /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf 2>/dev/null | sed -E 's#^ip=(.*)/$#\1#'
    ip -o -4 addr show | awk '{ split($4, a, "/"); print a[1] }'
    echo "$GATEWAY"
  )
  rm -rf "$tmp"
  for ((n = first; n <= last; n++)); do
    [[ -n ${used[$(int2ip "$n")]:-} ]] || echo "$n"
  done | awk '
    function ip(n) { return int(n / 16777216) "." (int(n / 65536) % 256) "." (int(n / 256) % 256) "." (n % 256) }
    function out() { printf "%s%s%s", sep, ip(s), (p > s ? " – " ip(p) : ""); sep = ", "; c += p - s + 1 }
    NR == 1     { s = p = $1; next }
    $1 == p + 1 { p = $1; next }
                { out(); s = p = $1 }
    END         { if (NR) out(); printf "\n         (%d IP, bỏ qua %d IP đang dùng)\n", c, '"$((last - first + 1))"' - c }'
}

# maxRunners gợi ý cho w worker (giống công thức trong guide)
rec_max_runners() {
  awk -v w="$1" -v wm="$WORKER_MEM_GB" -v wc="$WORKER_CORES" -v pm="$POD_MEM_GB" -v pc="$POD_CPU" 'BEGIN {
    m = int((w * (wm - 2.5) - 2) / pm)     # theo RAM allocatable
    c = int((w * (wc - 1) - 1) / pc)       # theo CPU allocatable
    p = w * 100                            # max-pods 110, chừa pod hệ thống
    r = m; if (c < r) r = c; if (p < r) r = p; if (r < 0) r = 0
    print int(r / 10) * 10
  }'
}

# ---------- 0. Điều kiện chạy ----------
if ! command -v pveversion >/dev/null 2>&1; then
  echo "Không tìm thấy pveversion: hãy chạy script trên Proxmox host." >&2
  exit 2
fi
if [[ $EUID -ne 0 ]]; then
  echo "Cần chạy bằng root (đọc /etc/pve)." >&2
  exit 2
fi

read -r -a WIDS <<<"$WORKER_IDS"
read -r -a WIPS <<<"$WORKER_IPS"
NW=${#WIDS[@]}

echo "${B}Proxmox discovery cho cụm k3s + ARC${N}  ($(hostname), $(date '+%F %T'))"
echo "Kế hoạch: server $SERVER_ID/$SERVER_IP, ${NW} worker [${WORKER_IDS}] / [${WORKER_IPS}], mirror $MIRROR_ID/$MIRROR_IP"
echo "          bridge=$BRIDGE storage=$STORAGE gateway=${GATEWAY:-auto} template=$TEMPLATE_ID"

# ---------- 1. Proxmox ----------
section "1. Proxmox"
pvever=$(pveversion | sed -n 's#^pve-manager/\([0-9]*\.[0-9]*\).*#\1#p')
major=${pvever%%.*} minor=${pvever#*.}
info "$(pveversion)"
if (( major > 7 || (major == 7 && minor >= 3) )); then
  ok "Proxmox $pvever hỗ trợ import-from và 'qm disk resize'"
elif (( major == 7 && minor == 2 )); then
  warn "Proxmox 7.2: dùng 'qm resize' thay cho 'qm disk resize'"
else
  fail "Proxmox $pvever quá cũ: cần >= 7.2 cho 'import-from' (bước 1.2)"
fi

if [[ -f /etc/pve/corosync.conf ]]; then
  nodes=$(ls /etc/pve/nodes | tr '\n' ' ')
  info "Cluster nhiều node: $nodes"
  info "Script tính tài nguyên cho node hiện tại ($(hostname)). Nên rải worker sang các node khác nhau."
else
  info "Proxmox đơn node"
fi

if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; then
  ok "Đồng hồ host đã đồng bộ NTP"
else
  warn "Đồng hồ host chưa đồng bộ NTP (TLS/etcd nhạy với lệch giờ)"
fi

# ---------- 2. CPU / RAM ----------
section "2. CPU / RAM"
threads=$(nproc)
model=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
mem_total_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
mem_avail_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
info "CPU: $model, $threads thread"
# Đo tải CPU thật của host
read -r _ a1 b1 c1 d1 e1 f1 g1 h1 _ < /proc/stat; sleep "$CPU_SAMPLE_SEC"
read -r _ a2 b2 c2 d2 e2 f2 g2 h2 _ < /proc/stat
cpu_busy=$(awk -v t1=$((a1 + b1 + c1 + d1 + e1 + f1 + g1 + h1)) -v t2=$((a2 + b2 + c2 + d2 + e2 + f2 + g2 + h2)) \
               -v i1=$((d1 + e1)) -v i2=$((d2 + e2)) 'BEGIN { printf "%.0f", 100 * (1 - (i2 - i1) / (t2 - t1)) }')
cpu_free=$(awk -v t="$threads" -v b="$cpu_busy" 'BEGIN { printf "%.0f", t * (100 - b) / 100 }')
info "CPU host đang bận ${cpu_busy}% (đo ${CPU_SAMPLE_SEC} giây) -> khoảng $cpu_free thread rảnh"
if (( cpu_busy >= 70 )); then
  warn "CPU host đã bận ${cpu_busy}%: runner sẽ tranh CPU với VM hiện có. Xem biểu đồ CPU tuần/tháng ở Node -> Summary"
fi
info "RAM: tổng $(gb "$mem_total_mb") GiB, đang trống $(gb "$mem_avail_mb") GiB"

# Chỉ VM/CT đang chạy mới chiếm RAM/CPU; VM tắt được báo riêng
vm_mem_mb=0 vm_run_mem_mb=0 vm_cpu=0 vm_run_cpu=0 nvm=0 nrun=0
for conf in /etc/pve/qemu-server/*.conf; do
  [[ -e $conf ]] || continue
  cur=$(current_conf "$conf")
  grep -q '^template: 1' <<<"$cur" && continue
  id=$(basename "$conf" .conf)
  m=$(awk -F': ' '/^memory:/ { print $2 }' <<<"$cur"); m=${m//[^0-9]/}; m=${m:-512}
  c=$(awk -F': ' '/^cores:/ { print $2 }' <<<"$cur"); c=${c:-1}
  s=$(awk -F': ' '/^sockets:/ { print $2 }' <<<"$cur"); s=${s:-1}
  vm_mem_mb=$((vm_mem_mb + m)); vm_cpu=$((vm_cpu + c * s)); nvm=$((nvm + 1))
  if [[ -e /var/run/qemu-server/$id.pid ]]; then
    vm_run_mem_mb=$((vm_run_mem_mb + m)); vm_run_cpu=$((vm_run_cpu + c * s)); nrun=$((nrun + 1))
  fi
done
for conf in /etc/pve/lxc/*.conf; do
  [[ -e $conf ]] || continue
  cur=$(current_conf "$conf")
  grep -q '^template: 1' <<<"$cur" && continue
  id=$(basename "$conf" .conf)
  m=$(awk -F': ' '/^memory:/ { print $2 }' <<<"$cur"); m=${m:-512}
  c=$(awk -F': ' '/^cores:/ { print $2 }' <<<"$cur"); c=${c:-0}
  vm_mem_mb=$((vm_mem_mb + m)); vm_cpu=$((vm_cpu + c)); nvm=$((nvm + 1))
  if [[ -d /sys/fs/cgroup/lxc/$id ]]; then
    vm_run_mem_mb=$((vm_run_mem_mb + m)); vm_run_cpu=$((vm_run_cpu + c)); nrun=$((nrun + 1))
  fi
done
info "VM/CT đang chạy: $nrun, cấp phát $(gb "$vm_run_mem_mb") GiB RAM, $vm_run_cpu vCPU"
info "VM/CT đang tắt: $((nvm - nrun)), cấp phát $(gb $((vm_mem_mb - vm_run_mem_mb))) GiB RAM, $((vm_cpu - vm_run_cpu)) vCPU (không tính vào phần còn trống)"

arc_mb=0
if [[ -r /proc/spl/kstat/zfs/arcstats ]]; then
  arc_param=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo 0)
  arc_cmax=$(awk '$1 == "c_max" { print $3 }' /proc/spl/kstat/zfs/arcstats)
  arc_size=$(awk '$1 == "size" { print $3 }' /proc/spl/kstat/zfs/arcstats)
  if zpool list -H -o name 2>/dev/null | grep -q .; then
    arc_mb=$((arc_cmax / 1048576))
    info "ZFS ARC: đang dùng $(gb $((arc_size / 1048576))) GiB, tối đa $(gb "$arc_mb") GiB (zfs_arc_max=$arc_param)"
    if (( arc_mb > mem_total_mb * 15 / 100 )); then
      warn "ZFS ARC có thể chiếm tới $(gb "$arc_mb") GiB: nên giới hạn (bước 1.5)"
    else
      ok "ZFS ARC đã giới hạn hợp lý"
    fi
  else
    info "Có module ZFS nhưng không có pool nào: ARC không dùng RAM, bỏ qua bước 1.5"
  fi
fi

ksm=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo 0)
(( ksm > 0 )) && info "KSM đang gộp $(gb $((ksm * 4 / 1024))) GiB, không tính vào phép tính dưới đây"

plan_mem_mb=$(( (SERVER_MEM_GB + MIRROR_MEM_GB + NW * WORKER_MEM_GB) * 1024 ))
plan_cpu=$(( SERVER_CORES + MIRROR_CORES + NW * WORKER_CORES ))
# Tính theo RAM trống THỰC TẾ (MemAvailable): VM thường không dùng hết RAM được cấp
free_mb=$(( mem_avail_mb - HOST_RESERVE_GB * 1024 ))
info "RAM còn cho cụm = RAM đang trống − ${HOST_RESERVE_GB} GiB dự phòng = $(gb "$free_mb") GiB"
info "Kế hoạch cần $(gb "$plan_mem_mb") GiB RAM, $plan_cpu vCPU"

workers_fit=$(( (free_mb - (SERVER_MEM_GB + MIRROR_MEM_GB) * 1024) / (WORKER_MEM_GB * 1024) ))
(( workers_fit < 0 )) && workers_fit=0
if (( plan_mem_mb <= free_mb )); then
  ok "RAM trống hiện tại đủ cho $NW worker × ${WORKER_MEM_GB} GiB"
else
  fail "Thiếu RAM: chỉ đủ $workers_fit worker × ${WORKER_MEM_GB} GiB. Giảm WORKER_IDS/WORKER_MEM_GB hoặc maxRunners"
fi
alloc_ratio=$(awk -v a=$((vm_run_mem_mb + plan_mem_mb)) -v t="$mem_total_mb" 'BEGIN { printf "%.1f", a / t }')
if awk -v r="$alloc_ratio" 'BEGIN { exit !(r > 1) }'; then
  warn "RAM cấp cho VM (đang chạy + cụm) = ${alloc_ratio}x RAM vật lý. Nếu VM cũ dùng thêm RAM, host OOM sẽ kill nguyên VM (có thể là worker)"
fi
stopped_mb=$(( vm_mem_mb - vm_run_mem_mb ))
if (( stopped_mb > 0 && stopped_mb > free_mb - plan_mem_mb )); then
  warn "Bật lại các VM đang tắt ($(gb "$stopped_mb") GiB) sẽ vượt RAM còn lại sau khi có cụm"
fi

ratio=$(awk -v a=$((vm_run_cpu + plan_cpu)) -v t="$threads" 'BEGIN { printf "%.1f", a / t }')
if awk -v r="$ratio" 'BEGIN { exit !(r > 4) }'; then
  warn "vCPU (VM đang chạy + cụm) / thread = ${ratio}x: quá cao, job sẽ chậm"
elif awk -v r="$ratio" 'BEGIN { exit !(r > 2) }'; then
  info "vCPU (VM đang chạy + cụm) / thread = ${ratio}x: chấp nhận được với job nhẹ"
else
  ok "vCPU (VM đang chạy + cụm) / thread = ${ratio}x"
fi

# ---------- 3. Storage ----------
section "3. Storage"
line=$(pvesm status --content images 2>/dev/null | awk -v s="$STORAGE" '$1 == s')
plan_disk_gb=$(( SERVER_DISK_GB + MIRROR_DISK_GB + NW * WORKER_DISK_GB ))
if [[ -z $line ]]; then
  fail "Storage '$STORAGE' không tồn tại hoặc không cho phép disk VM (content images)"
  info "Các storage chứa được disk VM:"
  pvesm status --content images 2>/dev/null | sed 's/^/         /'
else
  read -r _ st_type st_status _ _ st_avail _ <<<"$line"
  avail_gb=$(( st_avail / 1048576 ))
  [[ $st_status == active ]] && ok "Storage '$STORAGE' ($st_type) active" || fail "Storage '$STORAGE' đang $st_status"
  case $st_type in
    lvmthin|zfspool|rbd|btrfs) ok "'$st_type' hỗ trợ thin provisioning + discard" ;;
    dir|nfs|cifs|glusterfs)    info "'$st_type': nên dùng qcow2 để thin, hiệu năng thấp hơn lvmthin/zfs" ;;
    lvm)                       info "'lvm' (thick): disk cấp đủ ngay lúc tạo, không linked clone; chỉ dùng full clone như guide" ;;
    *)                         info "Loại storage: $st_type" ;;
  esac
  if [[ $st_type == lvm ]]; then
    if (( plan_disk_gb > avail_gb )); then
      fail "Còn $avail_gb GB, kế hoạch cần $plan_disk_gb GB (thick, cấp đủ ngay): không tạo được hết VM"
    elif (( plan_disk_gb * 10 > avail_gb * 9 )); then
      warn "Còn $avail_gb GB, kế hoạch dùng $plan_disk_gb GB (thick): gần hết storage"
    else
      ok "Còn $avail_gb GB, kế hoạch dùng $plan_disk_gb GB (thick), dư $((avail_gb - plan_disk_gb)) GB"
    fi
  elif (( avail_gb * 4 < plan_disk_gb )); then
    fail "Còn $avail_gb GB, kế hoạch cấp phát $plan_disk_gb GB (thin): chắc chắn đầy khi chạy job. Chọn storage khác (STORAGE=...)"
  elif (( avail_gb * 2 < plan_disk_gb )); then
    warn "Còn $avail_gb GB, kế hoạch cấp phát $plan_disk_gb GB (thin): dễ đầy khi nhiều job chạy"
  else
    ok "Còn $avail_gb GB, kế hoạch cấp phát $plan_disk_gb GB (thin)"
  fi
fi
info "Tất cả storage chứa được disk VM (dung lượng trống):"
pvesm status --content images 2>/dev/null | awk 'NR > 1 { printf "         %-20s %-10s %-9s %6d GB trống\n", $1, $2, $3, $6 / 1048576 }'

if pvesm status --content snippets 2>/dev/null | awk -v s="$SNIPPET_STORAGE" '$1 == s { f = 1 } END { exit !f }'; then
  ok "'$SNIPPET_STORAGE' đã bật content snippets"
else
  warn "'$SNIPPET_STORAGE' chưa bật snippets: làm bước 1.1"
fi

iso_free_gb=$(df -BG --output=avail /var/lib/vz 2>/dev/null | tail -1 | tr -dc '0-9')
(( ${iso_free_gb:-0} >= 2 )) && ok "/var/lib/vz còn ${iso_free_gb} GB cho cloud image" \
                              || warn "/var/lib/vz còn ${iso_free_gb:-?} GB: không đủ chỗ tải cloud image"

disks=$(lsblk -d -n -o NAME,TYPE,ROTA,SIZE,MODEL 2>/dev/null | awk '$2 == "disk" && $1 !~ /^zd/')
info "Ổ đĩa vật lý:"; sed 's/^/         /' <<<"$disks"
if [[ -n $disks ]] && ! awk '$3 == 0 { f = 1 } END { exit !f }' <<<"$disks"; then
  warn "Không thấy SSD/NVMe (ROTA=0): 100 pod cùng pull image sẽ nghẽn I/O"
fi

# ---------- 4. Mạng & IP ----------
section "4. Mạng & IP"
host_addr=''
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  mtu=$(cat "/sys/class/net/$BRIDGE/mtu")
  host_addr=$(ip -o -4 addr show dev "$BRIDGE" | awk '{ print $4 }' | head -1)
  ok "Bridge $BRIDGE tồn tại, MTU $mtu, IP host: ${host_addr:-không có}"
  (( mtu < 1500 )) && warn "MTU $mtu < 1500: nếu giữ vậy, thêm '--mtu' cho dind (bước 7.1)"
  if awk -v b="$BRIDGE" '$1 == "iface" { inb = ($2 == b) } inb && /bridge-vlan-aware[[:space:]]+yes/ { f = 1 } END { exit !f }' /etc/network/interfaces; then
    info "$BRIDGE là VLAN-aware: có thể đặt cụm vào VLAN riêng (tag=...)"
  fi
else
  fail "Không có bridge '$BRIDGE'. Bridge hiện có: $(ip -o link show type bridge | awk -F': ' '{ print $2 }' | tr '\n' ' ')"
fi

if [[ -z $GATEWAY ]]; then
  GATEWAY=$(ip -4 route show default dev "$BRIDGE" 2>/dev/null | awk '{ print $3; exit }')
  [[ -z $GATEWAY && -n $host_addr ]] && GATEWAY=${host_addr%/*}
  GATEWAY=${GATEWAY:-10.10.10.1}
  info "GATEWAY tự chọn theo $BRIDGE: $GATEWAY"
fi
if [[ -z $PREFIX ]]; then
  PREFIX=${host_addr#*/}
  [[ -n $host_addr ]] || PREFIX=24
fi
SUBNET="$GATEWAY/$PREFIX"

# Gateway là chính Proxmox host (bridge nội bộ như vmbr1): VM ra Internet nhờ NAT của host
nat_host=0
if ip -o -4 addr show | awk '{ split($4, a, "/"); print a[1] }' | grep -qxF "$GATEWAY"; then
  info "Gateway $GATEWAY là chính Proxmox host: VM ra Internet qua NAT của host"
  if [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]; then
    ok "net.ipv4.ip_forward = 1"
  else
    fail "net.ipv4.ip_forward = 0: VM trên $BRIDGE không ra được Internet"
  fi
  masq=$( { iptables -t nat -S POSTROUTING 2>/dev/null; nft list ruleset 2>/dev/null; } | grep -i masquerade)
  if [[ -n $masq ]]; then
    ok "Có rule MASQUERADE:"; sed 's/^/         /' <<<"$masq"
    grep -qF -- "${GATEWAY%.*}." <<<"$masq" || info "Không thấy subnet $SUBNET trong rule trên: kiểm tra rule có áp cho subnet này"
  else
    fail "Không có rule MASQUERADE: VM trên $BRIDGE không ra được Internet (xem guide, phần vmbr1)"
  fi
  dup_masq=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -i masquerade | sort | uniq -d)
  [[ -n $dup_masq ]] && info "Có rule MASQUERADE bị lặp (vô hại, do post-up chạy nhiều lần): $(head -1 <<<"$dup_masq")"

  dhcp_ss=$(ss -H -lunp 'sport = :67' 2>/dev/null)
  if [[ -n $dhcp_ss ]]; then
    dhcp=$(grep -o 'users:(("[^"]*' <<<"$dhcp_ss" | sed 's/^users:(("//' | sort -u | tr '\n' ' ')
    warn "Host đang chạy DHCP server (${dhcp:-không rõ tiến trình}): IP tĩnh của cụm phải nằm NGOÀI dải cấp phát"
    sed 's/^/         /' <<<"$dhcp_ss"
    ranges=$( { pgrep -a dnsmasq | grep -o -- '--dhcp-range=[^ ]*'
                grep -Hs 'dhcp-range' /etc/dnsmasq.conf /etc/dnsmasq.d/* /etc/pve/sdn/subnets.cfg
                grep -Hs '^[[:space:]]*range[[:space:]]' /etc/dhcp/dhcpd.conf
                grep -Hs '"pool"' /etc/kea/kea-dhcp4.conf; } | sort -u)
    if [[ -n $ranges ]]; then
      info "Dải cấp phát DHCP tìm thấy:"; sed 's/^/         /' <<<"$ranges"
    else
      info "Không đọc được dải DHCP: xem cấu hình của ${dhcp:-tiến trình đang nghe cổng 67}"
    fi
  else
    ok "Host không chạy DHCP server: VM trên $BRIDGE dùng IP tĩnh"
    info "Nếu có VM làm router/DHCP trên $BRIDGE (pfSense, OPNsense...), kiểm tra thêm dải DHCP của nó"
  fi
  nat_host=1
fi
info "Subnet kế hoạch: $SUBNET"

on_link=0
for a in $(ip -o -4 addr show | awk '{ split($4, x, "/"); print x[1] }'); do
  cidr_overlap "$a/32" "$SUBNET" && on_link=1
done
if (( ! on_link )); then
  warn "Host không có IP nào trong $SUBNET: không xác minh được IP trống; VM sẽ cần VLAN tag hoặc route tới subnet này"
fi
if ping -c1 -W1 "$GATEWAY" >/dev/null 2>&1; then
  ok "Gateway $GATEWAY phản hồi"
else
  warn "Gateway $GATEWAY không phản hồi ping (có thể do VLAN khác hoặc chặn ICMP)"
fi

(( ${#WIPS[@]} == NW )) || fail "Số WORKER_IPS (${#WIPS[@]}) khác số WORKER_IDS ($NW)"

declare -A PLAN_IP_ID=([$SERVER_IP]=$SERVER_ID [$MIRROR_IP]=$MIRROR_ID)
for i in "${!WIPS[@]}"; do PLAN_IP_ID[${WIPS[$i]}]=${WIDS[$i]:-?}; done
all_ips="$SERVER_IP ${WORKER_IPS} $MIRROR_IP"
dups=$(tr ' ' '\n' <<<"$all_ips" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
[[ -n $dups ]] && fail "IP bị lặp trong kế hoạch: $dups"
host_ips=$(ip -o -4 addr show | awk '{ split($4, a, "/"); print a[1] }')

ip_problem=0
for ip in $all_ips; do
  want_id=${PLAN_IP_ID[$ip]:-?}
  if ! cidr_overlap "$ip/32" "$SUBNET"; then fail "$ip nằm ngoài subnet $SUBNET"; ip_problem=1; continue; fi
  [[ $ip == "$GATEWAY" ]] && { fail "$ip trùng gateway"; continue; }
  grep -qxF "$ip" <<<"$host_ips" && { fail "$ip đang là IP của chính Proxmox host"; continue; }

  owner=$(grep -lF "ip=$ip/" /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf 2>/dev/null | head -1)
  if [[ -n $owner ]]; then
    if [[ $(basename "$owner" .conf) == "$want_id" ]]; then
      info "$ip đã gán cho VM $want_id đúng kế hoạch (chạy lại sau khi tạo VM)"
    else
      fail "$ip đã gán cho VM/CT $(basename "$owner" .conf) ($owner)"
      ip_problem=1
    fi
    continue
  fi
  if ping -c1 -W1 "$ip" >/dev/null 2>&1 || ip neigh show "$ip" | grep -q lladdr; then
    fail "$ip đang có thiết bị khác dùng (trả lời ping/ARP)"
    ip_problem=1
  elif (( on_link )); then
    ok "$ip trống"
  else
    warn "$ip không trả lời, nhưng host không cùng subnet nên chưa chắc trống"
  fi
done
info "Script không thấy được dải DHCP của router: đảm bảo các IP trên nằm NGOÀI dải DHCP"

if [[ $SCAN == 1 || ( $SCAN == auto && ( $ip_problem == 1 || $on_link == 0 ) ) ]] && [[ -n $host_addr ]]; then
  scan_net=$host_addr
  (( ${host_addr#*/} < 22 )) && scan_net="${host_addr%/*}/24"   # subnet lớn hơn /22: chỉ quét /24 của host
  info "Đang quét $scan_net (ping + ARP)..."
  info "Gợi ý IP trống (không ping/ARP, không có trong config VM nào):"
  echo -n "         "; suggest_free_ips "$scan_net"
  info "Thiết bị đang tắt hoặc chặn cả ARP sẽ trông như trống: đối chiếu thêm với IPAM/DHCP"
fi

host_nets=$( { ip -o -4 addr show | awk '{ print $4 }'; ip -4 route show | awk '$1 ~ /^[0-9]/ { print $1 }'; } | sort -u)
for pair in "pod:$POD_CIDR" "service:$SVC_CIDR" "dind:$DIND_CIDR"; do
  kind=${pair%%:*} cidr=${pair#*:} hit=''
  cidr_overlap "$cidr" "$SUBNET" && hit="$SUBNET (subnet VM)"
  while read -r net; do
    [[ -z $net || $net == 127.* ]] && continue
    cidr_overlap "$cidr" "$net" && { hit="$net"; break; }
  done <<<"$host_nets"
  if [[ -n $hit ]]; then
    case $kind in
      dind) warn "Dải dind $cidr trùng $hit: job sẽ không tới được mạng đó, thêm '--bip' cho dind" ;;
      *)    fail "Dải $kind $cidr trùng $hit: đặt cluster-cidr/service-cidr khác trong config server TRƯỚC khi cài k3s" ;;
    esac
  else
    ok "Dải $kind $cidr không trùng mạng nào host thấy"
  fi
done

[[ -s /etc/pve/sdn/zones.cfg ]] && info "Có Proxmox SDN: nếu VM dùng zone VXLAN/EVPN, MTU thấp hơn 1500"

# ---------- 5. VMID & tên ----------
section "5. VMID & tên VM"
for id in "$TEMPLATE_ID" "$SERVER_ID" "${WIDS[@]}" "$MIRROR_ID"; do
  conf=$(conf_of_id "$id")
  if [[ -z $conf ]]; then
    ok "VMID $id trống"
    continue
  fi
  name=$(current_conf "$conf" | awk -F': ' '/^(name|hostname):/ { print $2; exit }')
  if [[ $id == "$TEMPLATE_ID" ]] && grep -q '^template: 1' "$conf"; then
    info "VMID $id đã là template ('$name'): dùng lại được, bỏ qua bước 1.2"
  else
    fail "VMID $id đã dùng bởi '$name' ($conf)"
  fi
done
plan_ids=" $TEMPLATE_ID $SERVER_ID $WORKER_IDS $MIRROR_ID "
dup_ids=$(tr ' ' '\n' <<<"$plan_ids" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
[[ -n $dup_ids ]] && fail "VMID bị lặp trong kế hoạch: $dup_ids"
for conf in /etc/pve/nodes/*/qemu-server/*.conf; do
  [[ -e $conf ]] || continue
  id=$(basename "$conf" .conf)
  [[ $plan_ids == *" $id "* ]] && continue
  name=$(current_conf "$conf" | awk -F': ' '/^name:/ { print $2; exit }')
  [[ $name =~ ^(k3s-server-|k3s-worker-|registry-mirror) ]] && warn "Tên '$name' đã có ở VMID $id: dễ nhầm VM"
done

# ---------- 6. Backup ----------
section "6. Backup job"
excluded_ok=1
if [[ -f /etc/pve/jobs.cfg ]] && grep -q '^vzdump:' /etc/pve/jobs.cfg; then
  while IFS='|' read -r jid en all sel exc sched; do
    [[ $en == 0 ]] && { info "Job $jid đang tắt"; continue; }
    if [[ $all == 1 ]]; then
      missing=''
      for id in "${WIDS[@]}" "$MIRROR_ID"; do
        [[ ,$exc, == *",$id,"* ]] || missing+="$id "
      done
      if [[ -n $missing ]]; then
        warn "Job '$jid' ($sched) backup TẤT CẢ VM, sẽ gồm cả worker mới: thêm vào exclude: $missing"
        excluded_ok=0
      else
        ok "Job '$jid' backup tất cả nhưng đã exclude worker + mirror"
      fi
    else
      hit=''
      for id in "${WIDS[@]}" "$MIRROR_ID"; do [[ ,$sel, == *",$id,"* ]] && hit+="$id "; done
      [[ -n $hit ]] && { warn "Job '$jid' đang chọn VM $hit: bỏ worker/mirror ra"; excluded_ok=0; } \
                    || ok "Job '$jid' ($sched) không đụng tới worker/mirror"
    fi
  done < <(awk '
    function flush() { if (id != "") printf "%s|%s|%s|%s|%s|%s\n", id, en, all, sel, exc, sched }
    /^vzdump:/              { flush(); id = $2; en = "1"; all = "0"; sel = ""; exc = ""; sched = ""; next }
    /^[a-z-]+:/             { flush(); id = ""; next }
    id != "" && $1 == "all"      { all = $2 }
    id != "" && $1 == "enabled"  { en = $2 }
    id != "" && $1 == "vmid"     { sel = $2 }
    id != "" && $1 == "pool"     { sel = "pool:" $2 }
    id != "" && $1 == "exclude"  { exc = $2 }
    id != "" && $1 == "schedule" { $1 = ""; sched = substr($0, 2) }
    END { flush() }' /etc/pve/jobs.cfg)
else
  info "Không có backup job nào"
fi
if [[ -s /etc/pve/vzdump.cron ]] && grep -q -- '--all 1' /etc/pve/vzdump.cron; then
  warn "/etc/pve/vzdump.cron (kiểu cũ) backup tất cả VM: exclude worker/mirror"
fi

# ---------- 7. Internet ----------
section "7. Kết nối Internet (kiểm tra từ host)"
info "VM ở VLAN/firewall khác có thể cho kết quả khác host"
if getent hosts github.com >/dev/null; then ok "DNS phân giải được github.com"; else fail "DNS không phân giải được github.com"; fi
for url in https://github.com https://api.github.com https://ghcr.io/v2/ \
           https://pkg-containers.githubusercontent.com https://registry-1.docker.io/v2/ \
           https://get.k3s.io https://update.k3s.io/v1-release/channels \
           https://cloud-images.ubuntu.com; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null) || code=000
  if [[ $code != 000 ]]; then ok "$url (HTTP $code)"; else fail "Không tới được $url"; fi
done
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
  pmtu=''
  for size in 1472 1452 1432 1422 1412 1392 1372 1322 1272; do
    if ping -M do -s "$size" -c1 -W2 1.1.1.1 >/dev/null 2>&1; then pmtu=$((size + 28)); break; fi
  done
  if [[ $pmtu == 1500 ]]; then
    ok "MTU đường ra Internet = 1500"
  elif [[ -n $pmtu ]]; then
    if (( nat_host )); then
      warn "MTU đường ra Internet ≈ $pmtu (< 1500): bật MSS clamp $((pmtu - 40)) trên host cho VM trên $BRIDGE (guide, phần vmbr1)"
      if iptables -t mangle -S FORWARD 2>/dev/null | grep -q TCPMSS; then
        ok "Đã có rule TCPMSS trong mangle/FORWARD"
      fi
    else
      warn "MTU đường ra Internet ≈ $pmtu (< 1500): nếu git/npm trong job bị treo, thêm '--mtu=$pmtu' cho dind"
    fi
  else
    warn "Ping 1.1.1.1 được nhưng mọi gói DF >= 1300 byte đều rớt: kiểm tra firewall/VPN"
  fi
else
  info "1.1.1.1 không trả lời ping (ICMP bị chặn): bỏ qua kiểm tra MTU đường ra"
fi

# ---------- 8. Chuẩn bị khác ----------
section "8. Chuẩn bị khác"
if [[ -f $SSH_PUBKEY ]]; then
  ok "Có SSH public key $SSH_PUBKEY"
else
  warn "Chưa có $SSH_PUBKEY: copy public key của máy admin lên, hoặc chạy với SSH_PUBKEY=<file>"
  info "Từ máy admin: scp ~/.ssh/id_ed25519.pub root@<proxmox>:/root/admin.pub, rồi dùng --sshkeys /root/admin.pub ở bước 1.2"
fi
[[ -f $CLOUD_IMAGE ]] && info "Cloud image đã có: $CLOUD_IMAGE" \
                      || info "Chưa tải cloud image (bước 1.2 sẽ tải)"

# ---------- Tổng kết ----------
section "Tổng kết"
echo "  ${G}OK: $PASS${N}   ${Y}WARN: $WARN${N}   ${R}FAIL: $FAIL${N}"
echo
echo "  Kế hoạch: $NW worker × ${WORKER_CORES} vCPU / ${WORKER_MEM_GB} GiB, pod request ${POD_CPU} CPU / ${POD_MEM_GB} GiB"
rec=$(rec_max_runners "$NW")
echo "  -> maxRunners theo RAM/CPU của VM: $rec"
if (( workers_fit < NW )); then
  echo "  -> RAM host chỉ đủ $workers_fit worker -> maxRunners ≈ $(rec_max_runners "$workers_fit")"
fi
# CPU thật là thread vật lý của host đang rảnh, không phải số vCPU cấp cho VM
start=$(awk -v f="$cpu_free" -v pc="$POD_CPU" -v rec="$rec" 'BEGIN {
  s = int(f / pc); if (s >= 20) s = int(s / 10) * 10; if (s > rec) s = rec; print s }')
if awk -v a="$rec" -v pc="$POD_CPU" -v f="$cpu_free" 'BEGIN { exit !(a * pc > f) }'; then
  echo "  -> CPU request của $rec runner = $(awk -v a="$rec" -v pc="$POD_CPU" 'BEGIN { print a * pc }') CPU, vượt ~${cpu_free} thread host đang rảnh"
  if (( start > 0 )); then
    echo "     Nên bắt đầu maxRunners = $start, đo 'kubectl top nodes' khi chạy thật rồi mới tăng"
  else
    echo "     Host gần như hết CPU rảnh: chạy runner ở đây sẽ làm chậm cả VM hiện có"
  fi
fi
(( excluded_ok )) || echo "  -> Nhớ exclude worker/mirror khỏi backup TRƯỚC khi tạo VM (bước 1.6)"
(( FAIL == 0 )) || { echo; echo "  ${R}Sửa các mục FAIL trước khi làm bước 1.${N}"; exit 1; }
exit 0
)

main "$@"
