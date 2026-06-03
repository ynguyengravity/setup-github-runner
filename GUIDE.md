# LXC GitHub Actions Runner — Setup & Usage Guide

## Mục lục

1. [Yêu cầu hệ thống](#1-yêu-cầu-hệ-thống)
2. [Kiến trúc tổng quan](#2-kiến-trúc-tổng-quan)
3. [Cài đặt](#3-cài-đặt)
4. [Cấu hình .env](#4-cấu-hình-env)
5. [Lần đầu: Tạo template container](#5-lần-đầu-tạo-template-container)
6. [Clone runner từ template](#6-clone-runner-từ-template)
7. [Disk monitor tự động](#7-disk-monitor-tự-động)
8. [Dashboard UI](#8-dashboard-ui)
9. [Full cycle test](#9-full-cycle-test)
10. [Verify hoạt động](#10-verify-hoạt-động)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Yêu cầu hệ thống

| Thành phần | Yêu cầu |
|---|---|
| Host | **Proxmox VE 8.x** |
| Python | **3.11+** (`python3 --version`) |
| Quyền | **root** trên Proxmox host |
| GitHub Token | PAT với quyền `admin:org` |
| Network | Container phải có DHCP qua bridge `vmbr1` |

---

## 2. Kiến trúc tổng quan

```
Proxmox Host
│
├── Python Orchestrator (lxc_runner/)
│   ├── config.py      — load .env
│   ├── github_api.py  — GitHub REST API (token, register, deregister)
│   ├── proxmox.py     — pct / pvesh subprocess wrappers
│   ├── monitor.py     — disk check + auto-rebuild + scale-up
│   ├── master.py      — tạo template container
│   ├── clone.py       — clone + đăng ký runner
│   ├── lifecycle.py   — full cycle test
│   ├── ui.py          — rich terminal dashboard
│   └── cli.py         — click CLI entrypoints
│
├── container_scripts/  — shell scripts chạy TRONG container
│   ├── 01-base.sh      apt, locale
│   ├── 02-browsers.sh  Chrome, Edge, Firefox
│   ├── 03-nodejs.sh    Node.js 22
│   ├── 04-playwright.sh
│   ├── 05-docker.sh    Docker + overlay2
│   ├── 06-openvpn.sh
│   ├── 07-awscli.sh
│   └── 08-runner.sh    config.sh + svc.sh
│
└── systemd/
    ├── lxc-disk-monitor.service  — Type=oneshot, gọi Python
    └── lxc-disk-monitor.timer   — mỗi 4h, Persistent=true
```

**Luồng dữ liệu:**

```
systemd timer (mỗi 4h)
  └─► lxc-runner monitor
        ├─► pvesh list containers
        ├─► pct exec: df /
        ├─► [disk >= threshold] GitHub API deregister
        ├─► pct stop + pct destroy
        └─► clone_and_register()
              ├─► pct clone <source>
              ├─► GitHub API: get token
              ├─► pct push 08-runner.sh → container
              └─► pct exec: ./08-runner.sh
```

---

## 3. Cài đặt

### 3.1 Clone repo và chạy install script

```bash
# Trên Proxmox host (root)
cd /root
git clone <repo-url> setup-github-runner
cd setup-github-runner

bash install.sh
```

`install.sh` sẽ:
- Copy toàn bộ project vào `/opt/lxc-monitor/`
- Tạo Python virtualenv tại `/opt/lxc-monitor/venv/`
- Cài dependencies (`requests`, `rich`, `click`, `python-dotenv`)
- Copy `.env.example` → `.env` (nếu chưa có)
- Enable + start `lxc-disk-monitor.timer`

### 3.2 Verify cài đặt

```bash
# Kiểm tra CLI có sẵn không
/opt/lxc-monitor/venv/bin/lxc-runner --help

# Kiểm tra timer
systemctl status lxc-disk-monitor.timer

# Kiểm tra service (chưa chạy lần nào thì inactive/dead là đúng)
systemctl status lxc-disk-monitor.service
```

**Output mong đợi:**
```
● lxc-disk-monitor.timer - LXC GitHub Runner Disk Monitor - Chạy định kỳ
   Loaded: loaded (/etc/systemd/system/lxc-disk-monitor.timer; enabled)
   Active: active (waiting)
```

---

## 4. Cấu hình .env

```bash
nano /opt/lxc-monitor/.env
```

### Các biến bắt buộc

```bash
# GitHub Personal Access Token — cần quyền admin:org
GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"

# Tên organization GitHub
ORGNAME="Gravity-Global"
```

> **Cách tạo GitHub Token:**  
> GitHub → Settings → Developer settings → Personal access tokens → Fine-grained  
> Chọn organization → Permissions → **Organization permissions → Self-hosted runners → Read & Write**

### Các biến quan trọng khác

```bash
# Container template sẽ clone từ (tạo ở bước 5)
SOURCE_CONTAINER_ID=100

# Runner labels — phải khớp với workflow GitHub Actions
RUNNER_LABELS="vn-gaqc-docker,test-setup"
RUNNER_GROUP="VN-Team"

# Số lượng runner tối đa muốn duy trì
LXC_COUNT=35

# Ngưỡng disk (%) để trigger rebuild
DISK_THRESHOLD=85

# Giờ chỉ rebuild (giờ thấp điểm, tránh interrupt CI đang chạy)
MAINTENANCE_START=1   # 1h sáng
MAINTENANCE_END=6     # 6h sáng

# Thông báo (optional)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
SLACK_WEBHOOK_URL=""
```

### Verify config load đúng

```bash
# Test load config (không có side effect)
/opt/lxc-monitor/venv/bin/python3 -c "
from lxc_runner.config import Config
c = Config.from_env()
print('Org:', c.orgname)
print('Source container:', c.source_container_id)
print('Threshold:', c.disk_threshold, '%')
print('Maintenance:', c.maintenance_start, 'h –', c.maintenance_end, 'h')
print('Token:', c.github_token[:8] + '...')
"
```

---

## 5. Lần đầu: Tạo template container

> **Chỉ cần chạy 1 lần.** Template này sẽ được clone nhiều lần để tạo runner.

```bash
lxc-runner create
```

Lệnh này sẽ:
1. Download Ubuntu 24.04 template (nếu chưa có)
2. Tạo LXC container với 5 CPU, 32GB RAM, 50GB disk
3. Cài đặt tuần tự: base → browsers → nodejs → playwright → docker → openvpn → awscli
4. Pre-download GitHub runner tarball vào `/root/actions-runner/`
5. Reboot container

**Thời gian:** 20–40 phút (phụ thuộc network, Playwright download mirrors)

**Theo dõi progress:**

```bash
# Terminal khác — xem real-time log
tail -f /var/log/lxc-monitor/lxc-monitor-$(date +%Y%m%d).log

# Hoặc xem status container đang chạy script nào
watch pct exec <VMID> -- ps aux
```

**Sau khi xong, ghi lại VMID** và cập nhật `.env`:

```bash
# VMID được in ra cuối output, ví dụ: 100
SOURCE_CONTAINER_ID=100
```

---

## 6. Clone runner từ template

Mỗi lần cần thêm 1 runner mới:

```bash
lxc-runner clone
```

Lệnh này sẽ:
1. Clone container từ `SOURCE_CONTAINER_ID`
2. Reset machine ID (tránh xung đột DHCP)
3. Lấy registration token từ GitHub API
4. Chạy `08-runner.sh` trong container (config + svc.sh start)
5. Đặt `--onboot 1` để container tự start khi Proxmox reboot

**Thời gian:** 3–5 phút

**Verify runner đã online:**

```bash
# Kiểm tra trực tiếp GitHub API
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/$ORGNAME/actions/runners" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data['runners']:
    print(r['id'], r['name'], r['status'])
"
```

---

## 7. Disk monitor tự động

### Cách hoạt động

```
Mỗi 4h (1h, 5h, 9h, 13h, 17h, 21h):
  systemd timer → lxc-runner monitor
    ├── Với mỗi container github-runner-*:
    │   ├── disk < 85%       → OK, skip
    │   ├── disk >= 85%, ngoài window (1h–6h) → chỉ cảnh báo
    │   └── disk >= 85%, trong window          → deregister → destroy → clone
    └── Tổng container < LXC_COUNT → scale up (nếu trong window)
```

### Chạy thủ công

```bash
# Check-only: chỉ in trạng thái, không action
lxc-runner monitor --check-only

# Dry-run: in ra sẽ làm gì nhưng không thật sự làm
lxc-runner monitor --dry-run

# Thật sự chạy (thường để systemd tự trigger)
lxc-runner monitor
```

### Xem log

```bash
# Log systemd journal (real-time)
journalctl -u lxc-disk-monitor.service -f

# Log file theo ngày
tail -f /var/log/lxc-monitor/lxc-monitor-$(date +%Y%m%d).log

# Lần chạy gần nhất
journalctl -u lxc-disk-monitor.service -n 50 --no-pager
```

### Trigger chạy ngay (không đợi timer)

```bash
systemctl start lxc-disk-monitor.service

# Theo dõi
journalctl -u lxc-disk-monitor.service -f
```

---

## 8. Dashboard UI

```bash
# Refresh mỗi 30 giây (default)
lxc-runner ui

# Refresh mỗi 60 giây
lxc-runner ui -i 60

# Chạy 1 lần rồi thoát
lxc-runner ui -i 0
```

Dashboard hiển thị:
- Mỗi container: VMID, hostname, status (running/stopped), disk %, free, bar màu
- Xanh < 70% | Vàng 70–85% | Đỏ ≥ 85%
- Next timer run, last run time
- Alert box nếu có container cần rebuild

---

## 9. Full cycle test

Dùng để test thủ công vòng đời 1 container cụ thể (deregister → destroy → clone → verify):

```bash
# Liệt kê containers, sau đó nhập ID
lxc-runner test

# Chỉ định trực tiếp VMID
lxc-runner test 105

# Dry-run (không xóa/tạo thật)
lxc-runner test 105 --dry-run
```

Output sẽ hiển thị 4 bước rõ ràng:
```
STEP 1/4 — Hủy đăng ký runner 'github-runner-105-...' khỏi GitHub
STEP 2/4 — Xóa container 105
STEP 3/4 — Clone container mới từ template 100
STEP 4/4 — Verify runner online (tối đa 90s)
🎉 Hoàn tất! Cũ: 105 → Mới: 108 | 187s
```

---

## 10. Verify hoạt động

### 10.1 Verify Python package

```bash
cd /opt/lxc-monitor

# Import không lỗi
venv/bin/python3 -c "import lxc_runner; print('OK')"

# CLI available
venv/bin/lxc-runner --help
```

### 10.2 Verify config

```bash
venv/bin/lxc-runner --env-file .env monitor --check-only
```

**Output mong đợi:**
```
[INFO] Bắt đầu | Threshold: 85% | Org: Gravity-Global | Max LXC: 35 | Window: 1h–6h [CHECK-ONLY]
[INFO] Tìm thấy N container(s): [100, 101, ...]
[INFO] Kiểm tra container [101] — github-runner-101-...
[INFO]   Disk: 42% (ngưỡng: 85%)
[INFO]   OK — không cần action
...
[INFO] Kết quả | Monitor: N | Rebuilt: 0 | Skipped: N | Failed: 0
```

### 10.3 Verify GitHub API

```bash
venv/bin/python3 -c "
from lxc_runner.config import Config
from lxc_runner.github_api import GitHubAPI

cfg = Config.from_env()
gh = GitHubAPI(cfg)
runners = gh._iter_runners()
print(f'Tìm thấy {len(runners)} runner(s):')
for r in runners[:5]:
    print(f'  {r[\"id\"]:6}  {r[\"name\"]:45}  {r[\"status\"]}')
"
```

### 10.4 Verify Proxmox commands

```bash
venv/bin/python3 -c "
from lxc_runner import proxmox
print('Next VMID:', proxmox.get_next_id())
containers = proxmox.list_containers()
print('Containers:', len(containers))
for c in containers[:3]:
    vmid = int(c['vmid'])
    print(f'  {vmid}: {proxmox.get_hostname(vmid)} — running={proxmox.is_running(vmid)}')
"
```

### 10.5 Verify systemd timer

```bash
# Timer đang active
systemctl is-active lxc-disk-monitor.timer

# Thời gian chạy tiếp theo
systemctl list-timers lxc-disk-monitor.timer

# Lịch sử chạy
journalctl -u lxc-disk-monitor.service --since "24 hours ago" --no-pager
```

**Output mong đợi:**
```
NEXT                        LEFT       LAST                        PASSED  UNIT
Wed 2026-06-04 01:00:00 +07 3h 12min  Tue 2026-06-03 21:00:01 +07 4h ago  lxc-disk-monitor.timer
```

### 10.6 Verify disk usage của 1 container

```bash
# Kiểm tra disk % của container cụ thể
venv/bin/python3 -c "
from lxc_runner import proxmox
vmid = 101   # đổi theo VMID thực tế
usage = proxmox.get_disk_usage_pct(vmid)
hostname = proxmox.get_hostname(vmid)
print(f'{vmid} ({hostname}): {usage}%')
"
```

### 10.7 End-to-end smoke test (dry-run)

```bash
# Chạy toàn bộ logic nhưng không thay đổi gì
lxc-runner monitor --dry-run

# Hoặc test full cycle 1 container (không xóa thật)
lxc-runner test <VMID> --dry-run
```

---

## 11. Troubleshooting

### Lỗi: `ConfigError: GITHUB_TOKEN chưa được đặt`

```bash
# Kiểm tra file .env có đúng path không
ls -la /opt/lxc-monitor/.env

# Kiểm tra token không bị wrapped bởi dấu ngoặc kép thừa
grep GITHUB_TOKEN /opt/lxc-monitor/.env
# Đúng:  GITHUB_TOKEN="ghp_abc..."
# Sai:   GITHUB_TOKEN=ghp_abc...   ← thiếu ngoặc kép nếu có ký tự đặc biệt
```

### Lỗi: `ProxmoxError: Không tìm thấy lệnh: pct`

```bash
# Script phải chạy trên Proxmox VE host, không phải trong container
which pct
# Nếu không có → không phải Proxmox host
```

### Lỗi: `GitHubAPIError: HTTP 401`

```bash
# Token hết hạn hoặc thiếu quyền
# Kiểm tra quyền token
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/orgs/$ORGNAME/actions/runners
# 200 OK = token đúng
# 401    = token sai/hết hạn
# 403    = thiếu quyền admin:org
```

### Lỗi: `ContainerScriptError: Script 04-playwright.sh thất bại`

```bash
# Playwright download bị timeout/block — thử chạy thủ công trong container
pct exec <VMID> -- bash -c "
  PLAYWRIGHT_DOWNLOAD_HOST=https://npmmirror.com/mirrors/playwright \
  timeout 180 npx playwright install
"
```

### Container bị tạo nhưng runner không xuất hiện trên GitHub

```bash
# Xem log bên trong container
pct exec <VMID> -- journalctl -u "actions.runner.*" -n 30

# Kiểm tra service runner
pct exec <VMID> -- systemctl status "actions.runner.*"

# Xem token registration có hết hạn chưa (token có hiệu lực 1h)
# Nếu quá 1h từ lúc lấy token → clone lại
```

### Timer không tự chạy sau reboot

```bash
# Kiểm tra timer có được enable không
systemctl is-enabled lxc-disk-monitor.timer
# Phải là: enabled

# Enable lại nếu cần
systemctl enable lxc-disk-monitor.timer
systemctl start  lxc-disk-monitor.timer
```

### Xem toàn bộ log hôm nay

```bash
cat /var/log/lxc-monitor/lxc-monitor-$(date +%Y%m%d).log
```

---

## Tham khảo nhanh

```bash
# ── Cài đặt ──────────────────────────────────────────────
bash install.sh

# ── Tạo template (1 lần đầu) ─────────────────────────────
lxc-runner create

# ── Thêm runner mới ──────────────────────────────────────
lxc-runner clone

# ── Monitor ──────────────────────────────────────────────
lxc-runner monitor --check-only     # chỉ xem
lxc-runner monitor --dry-run        # mô phỏng
lxc-runner monitor                  # thật sự chạy

# ── UI ───────────────────────────────────────────────────
lxc-runner ui                       # dashboard live 30s
lxc-runner ui -i 60                 # refresh 60s

# ── Test ─────────────────────────────────────────────────
lxc-runner test <VMID> --dry-run    # mô phỏng
lxc-runner test <VMID>              # thật sự

# ── Log ──────────────────────────────────────────────────
journalctl -u lxc-disk-monitor.service -f
tail -f /var/log/lxc-monitor/lxc-monitor-$(date +%Y%m%d).log

# ── Systemd ──────────────────────────────────────────────
systemctl list-timers lxc-disk-monitor.timer
systemctl start lxc-disk-monitor.service    # trigger ngay
```
