#!/usr/bin/env bash
# pve-create-vms.sh – Bước 1 của docs/proxmox-k3s-arc-guide.md: tạo template Ubuntu cloud-init
# và các VM của cụm k3s (server, worker, registry mirror) trên Proxmox host.
#
# Chạy bằng root trên Proxmox host, SAU KHI pve-discovery.sh báo 0 FAIL, với CÙNG bộ biến:
#   set -a; source /root/k3s-plan.env; set +a
#   DRY_RUN=1 bash pve-create-vms.sh   # chỉ kiểm tra + in các lệnh sẽ chạy
#   bash pve-create-vms.sh             # kiểm tra, hỏi xác nhận rồi mới tạo
#
# Tuỳ chọn: CI_PASSWORD='...' đặt mật khẩu console cứu hộ cho user ubuntu
# (chỉ dùng được ở Console noVNC / qm terminal; SSH vẫn chỉ nhận key).
#
# Script chỉ TẠO MỚI: không sửa, không xoá VM nào đã có. VM của kế hoạch đã tồn tại
# (đúng VMID và đúng tên) thì bỏ qua, nên chạy lại sau khi lỗi giữa chừng là an toàn.
#
# Exit code: 0 = xong, 1 = kiểm tra thất bại hoặc lỗi khi tạo, 2 = không chạy được.

# Toàn bộ script chạy trong subshell (main() ( ... )): chạy bằng bash, source, hay dán
# thẳng vào terminal đều không thoát phiên shell và không để lại 'set -u' / biến.
main() (
set -uo pipefail

# ---------- Kế hoạch (cùng tên biến với pve-discovery.sh) ----------
BRIDGE=${BRIDGE:-vmbr0}
STORAGE=${STORAGE:-local-lvm}
SNIPPET_STORAGE=${SNIPPET_STORAGE:-local}
GATEWAY=${GATEWAY:-}                     # để trống = default route qua BRIDGE, không có thì IP host trên BRIDGE (NAT)
PREFIX=${PREFIX:-}                       # để trống = lấy theo IP của bridge
NAMESERVER=${NAMESERVER:-}               # để trống = lấy từ dhcpd.conf, không có thì /etc/resolv.conf của host

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

SSH_PUBKEY=${SSH_PUBKEY:-/root/.ssh/id_ed25519.pub}
CLOUD_IMAGE=${CLOUD_IMAGE:-/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img}
CLOUD_IMAGE_URL=${CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
TEMPLATE_NAME=${TEMPLATE_NAME:-ubuntu-2404-k3s-tpl}
CI_USER=${CI_USER:-ubuntu}
CI_PASSWORD=${CI_PASSWORD:-}

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}              # 1 = không hỏi xác nhận
WAIT_SSH_SEC=${WAIT_SSH_SEC:-600}        # chờ tối đa bao lâu để VM lên SSH + xong cloud-init

# ---------- Helpers ----------
if [[ -t 1 ]]; then
  G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' B=$'\e[1m' N=$'\e[0m'
else
  G='' Y='' R='' B='' N=''
fi
NBAD=0
ok()      { echo "  ${G}[OK]${N}   $*"; }
warn()    { echo "  ${Y}[WARN]${N} $*"; }
bad()     { echo "  ${R}[FAIL]${N} $*"; NBAD=$((NBAD + 1)); }
info()    { echo "  [INFO] $*"; }
section() { echo; echo "${B}== $* ==${N}"; }
die()     { echo "  ${R}[FAIL]${N} $*" >&2; exit 1; }

# In lệnh rồi chạy; DRY_RUN=1 thì chỉ in
run() {
  echo "  \$ $*"
  (( DRY_RUN )) && return 0
  "$@" || die "Lệnh thất bại: $*"
}

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

cidr_overlap() {
  local n1=${1%/*} p1=${1#*/} n2=${2%/*} p2=${2#*/}
  [[ $1 == */* ]] || p1=32
  [[ $2 == */* ]] || p2=32
  local p=$(( p1 < p2 ? p1 : p2 ))
  local mask=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  (( ($(ip2int "$n1") & mask) == ($(ip2int "$n2") & mask) ))
}

DHCP_RANGES=''
in_dhcp_range() {
  local n s e
  n=$(ip2int "$1")
  while read -r s e; do
    [[ -n $s ]] && (( n >= s && n <= e )) && return 0
  done <<<"$DHCP_RANGES"
  return 1
}

current_conf() { sed '/^\[/q' "$1"; }

conf_of_id() {
  ls /etc/pve/nodes/*/qemu-server/"$1".conf /etc/pve/nodes/*/lxc/"$1".conf 2>/dev/null | head -1
}

ssh_vm() { ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$CI_USER@$1" "${@:2}"; }

# ---------- 0. Điều kiện chạy ----------
if ! command -v pveversion >/dev/null 2>&1; then
  echo "Không tìm thấy pveversion: hãy chạy script trên Proxmox host." >&2
  exit 2
fi
if [[ $EUID -ne 0 ]]; then
  echo "Cần chạy bằng root." >&2
  exit 2
fi

read -r -a WIDS <<<"$WORKER_IDS"
read -r -a WIPS <<<"$WORKER_IPS"

# Danh sách VM theo thứ tự tạo: id|tên|ip|cores|RAM GB|disk GB|thứ tự khởi động
VMS=("$SERVER_ID|k3s-server-1|$SERVER_IP|$SERVER_CORES|$SERVER_MEM_GB|$SERVER_DISK_GB|1")
for i in "${!WIDS[@]}"; do
  VMS+=("${WIDS[$i]}|k3s-worker-$((i + 1))|${WIPS[$i]:-}|$WORKER_CORES|$WORKER_MEM_GB|$WORKER_DISK_GB|2")
done
VMS+=("$MIRROR_ID|registry-mirror|$MIRROR_IP|$MIRROR_CORES|$MIRROR_MEM_GB|$MIRROR_DISK_GB|2")

echo "${B}Tạo VM cho cụm k3s + ARC${N}  ($(hostname), $(date '+%F %T'))"
(( DRY_RUN )) && echo "${Y}DRY_RUN=1: chỉ kiểm tra và in lệnh, không tạo gì${N}"

# ---------- 1. Kiểm tra trước ----------
section "1. Kiểm tra trước"

(( ${#WIPS[@]} == ${#WIDS[@]} )) || bad "Số WORKER_IPS (${#WIPS[@]}) khác số WORKER_IDS (${#WIDS[@]})"

# Mạng
host_addr=''
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  host_addr=$(ip -o -4 addr show dev "$BRIDGE" | awk '{ print $4 }' | head -1)
  ok "Bridge $BRIDGE, IP host: ${host_addr:-không có}"
else
  bad "Không có bridge '$BRIDGE'"
fi
if [[ -z $GATEWAY ]]; then
  GATEWAY=$(ip -4 route show default dev "$BRIDGE" 2>/dev/null | awk '{ print $3; exit }')
  [[ -z $GATEWAY && -n $host_addr ]] && GATEWAY=${host_addr%/*}
fi
if [[ -z $PREFIX ]]; then
  PREFIX=${host_addr#*/}
  [[ -n $host_addr ]] || PREFIX=24
fi
if [[ -z $GATEWAY ]]; then
  bad "Không xác định được gateway cho $BRIDGE: đặt GATEWAY=..."
  GATEWAY=0.0.0.0
fi
SUBNET="$GATEWAY/$PREFIX"
info "Gateway $GATEWAY, subnet $SUBNET"

# Dải DHCP (dnsmasq, ISC dhcpd, Kea, Proxmox SDN) – IP tĩnh phải nằm ngoài
ranges=$( { pgrep -a dnsmasq | grep -o -- '--dhcp-range=[^ ]*'
            grep -hs '^[[:space:]]*dhcp-range' /etc/dnsmasq.conf /etc/dnsmasq.d/* /etc/pve/sdn/subnets.cfg
            grep -hs '^[[:space:]]*range[[:space:]]' /etc/dhcp/dhcpd.conf
            grep -hs '"pool"' /etc/kea/kea-dhcp4.conf; } | sort -u)
DHCP_RANGES=$(while read -r line; do
  read -r a b _ <<<"$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$line" | tr '\n' ' ')"
  [[ -n ${a:-} ]] && echo "$(ip2int "$a") $(ip2int "${b:-$a}")"
done <<<"$ranges")
[[ -n $DHCP_RANGES ]] && info "Dải DHCP trên host: $(tr '\n' ';' <<<"$ranges" | tr -s ' ')"

# DNS cho VM
if [[ -z $NAMESERVER ]]; then
  NAMESERVER=$(grep -hs 'domain-name-servers' /etc/dhcp/dhcpd.conf | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -2 | tr '\n' ' ')
  [[ -n $NAMESERVER ]] || NAMESERVER=$(awk '$1 == "nameserver" && $2 !~ /^127\./ { print $2 }' /etc/resolv.conf | head -2 | tr '\n' ' ')
  NAMESERVER=${NAMESERVER% }
fi
if [[ -n $NAMESERVER ]]; then ok "DNS cho VM: $NAMESERVER"; else bad "Không xác định được DNS: đặt NAMESERVER=..."; fi

# Storage
line=$(pvesm status --content images 2>/dev/null | awk -v s="$STORAGE" '$1 == s')
if [[ -z $line ]]; then
  bad "Storage '$STORAGE' không tồn tại hoặc không cho phép disk VM"
  avail_gb=0
else
  read -r _ st_type st_status _ _ st_avail _ <<<"$line"
  avail_gb=$(( st_avail / 1048576 ))
  [[ $st_status == active ]] || bad "Storage '$STORAGE' đang $st_status"
fi

snip_dir=$(awk -v s="$SNIPPET_STORAGE" '$1 == "dir:" && $2 == s { f = 1; next } /^[a-z]/ { f = 0 } f && $1 == "path" { print $2 }' /etc/pve/storage.cfg)
if [[ -z $snip_dir ]]; then
  bad "Storage '$SNIPPET_STORAGE' không phải loại directory: không chứa được snippet"
elif ! pvesm status --content snippets 2>/dev/null | awk -v s="$SNIPPET_STORAGE" '$1 == s { f = 1 } END { exit !f }'; then
  bad "'$SNIPPET_STORAGE' chưa bật content Snippets (Datacenter -> Storage -> $SNIPPET_STORAGE -> Edit)"
else
  ok "Snippet sẽ lưu tại $snip_dir/snippets/k3s-vendor.yaml"
fi

if [[ -f $SSH_PUBKEY ]]; then ok "SSH public key: $SSH_PUBKEY"; else bad "Không có $SSH_PUBKEY (ssh-keygen -t ed25519)"; fi
[[ -n $CI_PASSWORD ]] && ok "Có CI_PASSWORD: đặt mật khẩu console cho user $CI_USER" \
                      || warn "Không có CI_PASSWORD: VM sẽ không đăng nhập được qua Console noVNC khi SSH hỏng"

# Template
tpl_skip=0
tpl_conf=$(conf_of_id "$TEMPLATE_ID")
if [[ -n $tpl_conf ]]; then
  tpl_name=$(current_conf "$tpl_conf" | awk -F': ' '/^name:/ { print $2; exit }')
  if grep -q '^template: 1' "$tpl_conf" && [[ $tpl_name == "$TEMPLATE_NAME" ]]; then
    info "Template $TEMPLATE_ID ('$tpl_name') đã có: dùng lại"
    tpl_skip=1
  else
    bad "VMID $TEMPLATE_ID đã dùng bởi '$tpl_name' và không phải template của script này"
  fi
fi

# Từng VM: VMID, IP
need_gb=$(( tpl_skip ? 0 : 4 ))          # disk template ~3.5 GB
host_ips=$(ip -o -4 addr show | awk '{ split($4, a, "/"); print a[1] }')
declare -A SKIP=()
seen_ips=' '
for vm in "${VMS[@]}"; do
  IFS='|' read -r id name ip cores mem disk order <<<"$vm"
  conf=$(conf_of_id "$id")
  if [[ -n $conf ]]; then
    cur_name=$(current_conf "$conf" | awk -F': ' '/^(name|hostname):/ { print $2; exit }')
    if [[ $cur_name == "$name" ]] && grep -qF "ip=$ip/" "$conf"; then
      info "VM $id '$name' ($ip) đã có: bỏ qua"
      SKIP[$id]=1
    else
      bad "VMID $id đã dùng bởi '$cur_name' ($conf)"
    fi
    continue
  fi
  need_gb=$(( need_gb + disk ))
  [[ $seen_ips == *" $ip "* ]] && bad "IP $ip bị lặp trong kế hoạch"
  seen_ips+="$ip "
  if [[ -z $ip ]] || ! cidr_overlap "$ip/32" "$SUBNET"; then bad "$name: IP '$ip' nằm ngoài $SUBNET"; continue; fi
  [[ $ip == "$GATEWAY" ]] && { bad "$name: $ip trùng gateway"; continue; }
  grep -qxF "$ip" <<<"$host_ips" && { bad "$name: $ip là IP của Proxmox host"; continue; }
  in_dhcp_range "$ip" && { bad "$name: $ip nằm trong dải DHCP"; continue; }
  owner=$(grep -lF "ip=$ip/" /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf 2>/dev/null | head -1)
  [[ -n $owner ]] && { bad "$name: $ip đã gán cho VM/CT $(basename "$owner" .conf)"; continue; }
  if ping -c1 -W1 "$ip" >/dev/null 2>&1 || ip neigh show "$ip" | grep -q lladdr; then
    bad "$name: $ip đang có thiết bị khác dùng"
    continue
  fi
  ok "$name: VMID $id, IP $ip trống"
done

if (( avail_gb > 0 )); then
  if (( need_gb > avail_gb )); then
    bad "Storage '$STORAGE' còn $avail_gb GB, cần $need_gb GB"
  else
    ok "Storage '$STORAGE' còn $avail_gb GB, cần $need_gb GB"
  fi
fi

if (( NBAD > 0 )); then
  echo
  echo "  ${R}$NBAD mục FAIL: chưa tạo gì. Sửa rồi chạy lại (hoặc chạy pve-discovery.sh để xem chi tiết).${N}"
  exit 1
fi

# ---------- 2. Kế hoạch ----------
section "2. Kế hoạch"
printf "  %-6s %-16s %-15s %5s %7s %8s\n" VMID Tên IP vCPU RAM Disk
for vm in "${VMS[@]}"; do
  IFS='|' read -r id name ip cores mem disk order <<<"$vm"
  printf "  %-6s %-16s %-15s %5s %6sG %7sG %s\n" "$id" "$name" "$ip" "$cores" "$mem" "$disk" "${SKIP[$id]:+(đã có)}"
done
echo "  Template $TEMPLATE_ID trên $STORAGE, bridge $BRIDGE, gateway $GATEWAY/$PREFIX, DNS $NAMESERVER"

if (( ! DRY_RUN && ! ASSUME_YES )); then
  echo
  read -r -p "  Gõ YES để tạo: " answer </dev/tty
  [[ $answer == YES ]] || { echo "  Huỷ, chưa tạo gì."; exit 1; }
fi

# ---------- 3. Snippet cloud-init ----------
section "3. Snippet cloud-init"
snippet="$snip_dir/snippets/k3s-vendor.yaml"
snippet_body='#cloud-config
package_update: true
packages:
  - qemu-guest-agent
  - curl
  - chrony
runcmd:
  - systemctl enable --now qemu-guest-agent'
if [[ -f $snippet ]] && [[ $(cat "$snippet") == "$snippet_body" ]]; then
  ok "$snippet đã có, đúng nội dung"
elif [[ -f $snippet ]]; then
  die "$snippet đã có nhưng nội dung khác: xem lại rồi xoá file đó nếu không dùng"
else
  echo "  \$ ghi $snippet"
  (( DRY_RUN )) || { mkdir -p "$snip_dir/snippets" && printf '%s\n' "$snippet_body" > "$snippet"; } || die "Không ghi được $snippet"
fi

# ---------- 4. Cloud image ----------
section "4. Cloud image"
if (( tpl_skip )); then
  info "Template đã có: không cần cloud image"
elif [[ -f $CLOUD_IMAGE ]]; then
  ok "Đã có $CLOUD_IMAGE"
else
  img_dir=$(dirname "$CLOUD_IMAGE")
  run mkdir -p "$img_dir"
  run wget -q --show-progress -O "$CLOUD_IMAGE.part" "$CLOUD_IMAGE_URL"
  if (( ! DRY_RUN )); then
    want=$(wget -qO- "${CLOUD_IMAGE_URL%/*}/SHA256SUMS" | awk -v f="$(basename "$CLOUD_IMAGE_URL")" '$2 == "*" f || $2 == f { print $1 }')
    got=$(sha256sum "$CLOUD_IMAGE.part" | awk '{ print $1 }')
    if [[ -z $want ]]; then
      warn "Không lấy được SHA256SUMS: bỏ qua kiểm tra checksum"
    elif [[ $want != "$got" ]]; then
      rm -f "$CLOUD_IMAGE.part"
      die "Checksum sai (tải lỗi?): đã xoá file tải dở, chạy lại script"
    else
      ok "Checksum SHA256 khớp"
    fi
  fi
  run mv "$CLOUD_IMAGE.part" "$CLOUD_IMAGE"
fi

# ---------- 5. Template ----------
section "5. Template $TEMPLATE_ID"
if (( tpl_skip )); then
  info "Dùng lại template có sẵn"
else
  run qm create "$TEMPLATE_ID" --name "$TEMPLATE_NAME" --ostype l26 \
    --memory 2048 --cores 2 --cpu host \
    --net0 "virtio,bridge=$BRIDGE" \
    --scsihw virtio-scsi-single --agent enabled=1 \
    --serial0 socket --vga serial0 \
    --scsi0 "$STORAGE:0,import-from=$CLOUD_IMAGE,discard=on,iothread=1,ssd=1" \
    --ide2 "$STORAGE:cloudinit" --boot order=scsi0 \
    --ciuser "$CI_USER" --sshkeys "$SSH_PUBKEY" \
    --cicustom "vendor=$SNIPPET_STORAGE:snippets/k3s-vendor.yaml" \
    --tags k3s --description "Template cho cụm k3s + ARC (scripts/pve-create-vms.sh)"
  if [[ -n $CI_PASSWORD ]]; then
    echo "  \$ qm set $TEMPLATE_ID --cipassword '***'"
    (( DRY_RUN )) || qm set "$TEMPLATE_ID" --cipassword "$CI_PASSWORD" >/dev/null || die "Không đặt được cipassword"
  fi
  run qm template "$TEMPLATE_ID"
fi

# ---------- 6. Clone VM ----------
section "6. Tạo VM"
created=()
for vm in "${VMS[@]}"; do
  IFS='|' read -r id name ip cores mem disk order <<<"$vm"
  [[ -n ${SKIP[$id]:-} ]] && { info "$name ($id) đã có: bỏ qua"; continue; }
  echo "  -- $name ($id, $ip)"
  run qm clone "$TEMPLATE_ID" "$id" --name "$name" --full 1 --storage "$STORAGE"
  run qm set "$id" --cores "$cores" --memory $((mem * 1024)) --balloon 0 \
    --onboot 1 --startup "order=$order" \
    --ipconfig0 "ip=$ip/$PREFIX,gw=$GATEWAY" --nameserver "$NAMESERVER" \
    --tags k3s
  run qm disk resize "$id" scsi0 "${disk}G"
  run qm start "$id"
  created+=("$ip")
done

if (( DRY_RUN )); then
  echo
  echo "  ${Y}DRY_RUN xong: chưa tạo gì. Chạy lại không có DRY_RUN=1 để tạo thật.${N}"
  exit 0
fi

# ---------- 7. Chờ VM sẵn sàng ----------
section "7. Chờ SSH + cloud-init (tối đa ${WAIT_SSH_SEC}s mỗi VM)"
for ip in "${created[@]}"; do
  ssh-keygen -R "$ip" >/dev/null 2>&1       # VM mới có host key mới
done
nfail=0
for vm in "${VMS[@]}"; do
  IFS='|' read -r id name ip _ <<<"$vm"
  deadline=$((SECONDS + WAIT_SSH_SEC))
  until ssh_vm "$ip" true 2>/dev/null; do
    if (( SECONDS > deadline )); then
      echo "  ${R}[FAIL]${N} $name ($ip): chưa SSH được. Xem Console của VM $id trên web UI"
      nfail=$((nfail + 1))
      continue 2
    fi
    sleep 5
  done
  ssh_vm "$ip" 'sudo cloud-init status --wait >/dev/null 2>&1' || true
  st=$(ssh_vm "$ip" 'echo "$(hostname) | cloud-init: $(cloud-init status | sed "s/status: //") | agent: $(systemctl is-active qemu-guest-agent) | github: $(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://github.com)"')
  if [[ $st == *"cloud-init: done"*"agent: active"*"github: 200"* ]]; then
    ok "$name ($ip): $st"
  else
    warn "$name ($ip): $st"
  fi
done

# ---------- Tổng kết ----------
section "Tổng kết"
if (( nfail > 0 )); then
  echo "  ${R}$nfail VM chưa SSH được.${N} Kiểm tra Console trên web UI, rồi chạy lại script (VM đã có sẽ được bỏ qua)."
  exit 1
fi
echo "  ${G}Đã tạo xong.${N} Bước tiếp theo trong guide:"
echo "    - Bước 2: chạy node-prep.sh trên server + worker (ssh $CI_USER@<ip> từ Proxmox Shell)"
echo "    - Bước 3: cài k3s; Bước 4: dựng registry mirror trên $MIRROR_IP"
exit 0
)

main "$@"
