#!/usr/bin/env bash
# state-check.sh – In hiện trạng THẬT của hệ thống để đối chiếu với mục 1 của
# docs/proxmox-k3s-arc-guide.md. Script CHỈ ĐỌC, không thay đổi gì.
# Chạy bằng root trên Proxmox host:
#
#   bash state-check.sh            # in ra màn hình
#   bash state-check.sh > state-$(date +%F).txt
#
# Không in secret: chỉ liệt kê TÊN secret/configmap và các khoá, không in nội dung.

main() (
set -uo pipefail

SERVER=${SERVER:-ubuntu@192.168.8.2}
MIRROR=${MIRROR:-ubuntu@192.168.8.5}
VMIDS=${VMIDS:-"9000 201 211 212 213 214 220"}

hdr() { echo; echo "===== $* ====="; }
srv() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$SERVER" "$@" 2>&1; }

echo "state-check $(hostname) $(date -u '+%F %T UTC')"

hdr "Host"
pveversion
echo "CPU: $(nproc) thread, load: $(cut -d' ' -f1-3 /proc/loadavg)"
free -g | awk '/Mem/ { print "RAM: dùng " $3 " / " $2 " GiB, available " $7 " GiB" } /Swap/ { print "Swap: dùng " $3 " / " $2 " GiB" }'
pvesm status | awk 'NR == 1 || $1 ~ /^local/ { printf "%-12s %-8s %-8s trống %6d GB\n", $1, $2, $3, $6 / 1048576 }'

hdr "Mạng host (vmbr1)"
ip -o -4 addr show dev vmbr1 | awk '{ print "vmbr1 " $4 }'
echo "ip_forward=$(sysctl -n net.ipv4.ip_forward)"
iptables -t nat -S POSTROUTING | grep -c '192.168.8.0/22.*MASQUERADE' | xargs echo "MASQUERADE 192.168.8.0/22 (số rule):"
iptables -t mangle -S FORWARD | grep TCPMSS || echo "KHÔNG có rule TCPMSS"
grep -A12 '^auto vmbr1' /etc/network/interfaces | grep -cE 'post-up .*TCPMSS' | xargs echo "post-up TCPMSS trong /etc/network/interfaces:"

hdr "VM"
printf "%-6s %-22s %-8s %-6s %-7s %-9s %-8s %s\n" VMID NAME STATUS CORES MEM_MiB CPUUNITS ONBOOT "DISK / IP"
for id in $VMIDS; do
  conf=$(qm config "$id" --current 2>/dev/null) || { echo "$id (không tồn tại)"; continue; }
  g() { awk -F': ' -v k="$1" '$1 == k { print $2 }' <<<"$conf"; }
  st=$(qm status "$id" | awk '{ print $2 }')
  disk=$(g scsi0 | grep -o 'size=[^,]*'); ip=$(g ipconfig0 | grep -o 'ip=[^,]*')
  printf "%-6s %-22s %-8s %-6s %-7s %-9s %-8s %s %s %s\n" "$id" "$(g name)" "$st" "$(g cores)" "$(g memory)" "$(g cpuunits)" "$(g onboot)" "$disk" "$ip" "$(g template | sed 's/1/(template)/')"
done
echo "LXC github-runner-* còn lại: $(pct list 2>/dev/null | awk '$NF ~ /^github-runner-/' | wc -l)"

hdr "k3s"
srv 'k3s --version | head -1'
srv 'kubectl get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].status,SCHED_OFF:.spec.unschedulable,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,VER:.status.nodeInfo.kubeletVersion,LABEL:.metadata.labels.gha-runner'

hdr "Helm / ARC"
srv 'helm list -A -o table'
srv 'helm history vn-gaqc-docker -n arc-runners --max 3'
srv 'helm get values vn-gaqc-docker -n arc-runners -o yaml' | grep -E '^(runnerScaleSetName|runnerGroup|minRunners|maxRunners|githubConfigUrl|githubConfigSecret):|image:|cpu:' | sed 's/^ *//' | sort | uniq -c
srv 'kubectl get autoscalingrunnerset -n arc-runners'
srv 'kubectl get pods -n arc-systems -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName'
echo "Runner pod đang chạy: $(srv 'kubectl get pods -n arc-runners --no-headers 2>/dev/null | wc -l')"
# Chỉ in TÊN khoá (go-template duyệt key của .data), không bao giờ in giá trị.
# Secret do Helm (sh.helm.release.*) và ARC (runner jitToken) tự sinh thì chỉ đếm.
srv "kubectl get secret,configmap -n arc-runners -o go-template='{{range .items}}{{.kind}} {{.metadata.name}}{{range \$k, \$v := .data}} {{\$k}}{{end}}{{\"\\n\"}}{{end}}'" \
  | awk '$2 ~ /^sh\.helm\.release\./ { h++; next } $2 ~ /-runner-/ && $3 == "jitToken" { j++; next } $2 == "kube-root-ca.crt" { next } { print }
         END { print "(Secret Helm release: " h+0 ", Secret jitToken của runner: " j+0 ")" }'

hdr "Registry trên mirror"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$MIRROR" 'cd /opt/mirror && sudo docker compose ps --format "{{.Service}} {{.State}} {{.Ports}}"; echo "cache :5000 -> $(curl -s localhost:5000/v2/_catalog)"; echo "local :5001 -> $(curl -s localhost:5001/v2/_catalog)"; for r in $(curl -s localhost:5001/v2/_catalog | grep -o "\"[^\"]*\"" | tr -d "\"" | grep -v repositories); do echo "  $r tags: $(curl -s localhost:5001/v2/$r/tags/list)"; done; df -h / | tail -1' 2>&1

hdr "Image runner trên từng worker"
for ip in $(srv "kubectl get nodes -l gha-runner=true -o jsonpath='{.items[*].status.addresses[?(@.type==\"InternalIP\")].address}'"); do
  echo "$ip: $(ssh -o BatchMode=yes -o ConnectTimeout=5 "ubuntu@$ip" 'sudo k3s crictl images 2>/dev/null | awk "/vn-gaqc-runner|actions-runner|docker +dind/ { printf \"%s:%s \", \$1, \$2 }"; echo; nproc' | tr '\n' ' ')"
done
)

main "$@"
