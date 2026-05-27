# 🖥️ LXC Disk Monitor — Hướng Dẫn Cài Đặt

Tự động kiểm tra disk các LXC GitHub runner, cảnh báo và rebuild khi disk đầy.

---

## 📋 Yêu Cầu

- Proxmox VE 7.0+
- Quyền root trên Proxmox host
- Container template đã tạo sẵn bằng `lxc_create_github_actions_runner.master.sh` (mặc định ID = **100**)
- GitHub Personal Access Token với quyền `admin:org`

---

## 🚀 Cài Đặt (5 bước)

### Bước 1 — Upload lên Proxmox

```bash
# Từ máy local, upload toàn bộ folder lên Proxmox
scp -r setup-github-runner/ root@<proxmox-ip>:/tmp/

# SSH vào Proxmox
ssh root@<proxmox-ip>
cd /tmp/setup-github-runner
```

### Bước 2 — Tạo file `.env`

```bash
cp .env.example /opt/lxc-monitor/.env 2>/dev/null || \
    { mkdir -p /opt/lxc-monitor && cp .env.example /opt/lxc-monitor/.env; }

nano /opt/lxc-monitor/.env
```

Các biến **bắt buộc** phải điền:

```bash
GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"   # GitHub PAT với quyền admin:org
ORGNAME="Gravity-Global"                  # Tên tổ chức GitHub
SOURCE_CONTAINER_ID=100                   # ID container template để clone
```

Các biến **tuỳ chỉnh** (đã có giá trị mặc định hợp lý):

```bash
DISK_THRESHOLD=85        # Rebuild khi disk >= 85%
MAINTENANCE_START=1      # Chỉ rebuild từ 1:00 AM
MAINTENANCE_END=6        # đến 6:00 AM
LXC_COUNT=35             # Tối đa 35 LXC runner
LXC_IDS=auto             # Tự tìm container theo tên "github-runner-*"
```

Bảo mật file `.env`:
```bash
chmod 600 /opt/lxc-monitor/.env
```

### Bước 3 — Chạy installer

```bash
bash /tmp/setup-github-runner/install-monitor.sh
```

Installer sẽ tự động:
- Copy scripts vào `/opt/lxc-monitor/`
- Cài systemd service + timer
- Enable và start timer

### Bước 4 — Kiểm tra trước khi chạy thật

```bash
# Xem trạng thái (không xóa/tạo gì)
/opt/lxc-monitor/lxc-disk-monitor.sh --check-only

# Mô phỏng toàn bộ flow (không xóa/tạo thật)
/opt/lxc-monitor/lxc-disk-monitor.sh --dry-run
```

Output mẫu:
```
================================================================
[2026-05-27 02:00:01] [INFO] 🚀 LXC Disk Monitor - Bắt đầu kiểm tra
[2026-05-27 02:00:01] [INFO]    Threshold : 85% | Org: Gravity-Global | Max LXC: 35
[2026-05-27 02:00:01] [INFO]    Window    : 1h–6h | Giờ hiện tại: 2h (TRONG window → rebuild ON)
================================================================
[2026-05-27 02:00:02] [INFO] 🔍 Kiểm tra container [101] - github-runner-101-20260101X
[2026-05-27 02:00:03] [INFO]    Disk usage: 45% (ngưỡng: 85%) 
[2026-05-27 02:00:03] [INFO]    ✅ Disk OK (45% < 85%) - không cần action
```

### Bước 5 — Xác nhận timer đang chạy

```bash
systemctl status lxc-disk-monitor.timer
systemctl list-timers lxc-disk-monitor.timer
```

Output mẫu:
```
NEXT                        LEFT      LAST                        PASSED UNIT
Wed 2026-05-28 05:00:00 +07 2h 15min  Wed 2026-05-27 01:00:00 +07 1h 44min lxc-disk-monitor.timer
```

---

## ⏰ Lịch Chạy

Timer check disk **6 lần/ngày** (mỗi 4 giờ):

```
01:00  ← Trong maintenance window → CÓ THỂ rebuild
05:00  ← Trong maintenance window → CÓ THỂ rebuild
09:00  ← Ngoài window → chỉ cảnh báo
13:00  ← Ngoài window → chỉ cảnh báo
17:00  ← Ngoài window → chỉ cảnh báo
21:00  ← Ngoài window → chỉ cảnh báo
```

**Tại sao thiết kế vậy?**

| Vấn đề | Giải pháp |
|--------|-----------|
| Disk đầy ban ngày, không biết | Check mỗi 4h → phát hiện trong vòng 4h |
| Rebuild giữa giờ làm → job bị interrupt | Chỉ rebuild trong 1h–6h (thấp điểm) |
| Disk đầy 10h sáng | Cảnh báo lúc 13h, rebuild tự động lúc 1h sáng |

---

## 🔍 Xem Trạng Thái

### Live Dashboard (khuyên dùng)

```bash
# Mở UI dashboard, auto-refresh mỗi 30 giây
/opt/lxc-monitor/lxc-monitor-ui.sh

# Tuỳ chỉnh interval
/opt/lxc-monitor/lxc-monitor-ui.sh -i 60   # refresh mỗi 60 giây
/opt/lxc-monitor/lxc-monitor-ui.sh -i 0    # xem 1 lần, không loop
```

Phím tắt trong UI: **`r`** refresh ngay | **`q`** thoát

### Xem Log

```bash
# Log hôm nay
tail -f /var/log/lxc-monitor/lxc-monitor-$(date +%Y%m%d).log

# Log qua journalctl
journalctl -u lxc-disk-monitor.service -f
journalctl -u lxc-disk-monitor.service --since today
```

### Chạy Thủ Công

```bash
# Chạy ngay (theo đúng logic maintenance window)
systemctl start lxc-disk-monitor.service

# Hoặc chạy trực tiếp
/opt/lxc-monitor/lxc-disk-monitor.sh
```

---

## 🗑️ Gỡ Cài Đặt

```bash
# Gỡ service/timer, GIỮ LẠI .env và log
bash /tmp/setup-github-runner/uninstall-monitor.sh

# Gỡ hoàn toàn (xóa luôn .env, log, thư mục)
bash /tmp/setup-github-runner/uninstall-monitor.sh --purge
```

---

## 🔧 Tuỳ Chỉnh Nâng Cao

### Thay đổi lịch check

Sửa file `/etc/systemd/system/lxc-disk-monitor.timer`:

```bash
# Mỗi 4 giờ (mặc định)
OnCalendar=*-*-* 01,05,09,13,17,21:00:00

# Mỗi 2 giờ
OnCalendar=*-*-* 01,03,05,07,09,11,13,15,17,19,21,23:00:00

# Mỗi giờ
OnCalendar=hourly
```

Sau khi sửa:
```bash
systemctl daemon-reload
systemctl restart lxc-disk-monitor.timer
```

### Thay đổi maintenance window

Sửa trong `/opt/lxc-monitor/.env`:

```bash
MAINTENANCE_START=22   # bắt đầu 10 PM
MAINTENANCE_END=5      # kết thúc 5 AM (qua nửa đêm → script tự xử lý)
```

### Bật thông báo Telegram

```bash
# Trong .env
TELEGRAM_BOT_TOKEN="123456:ABCdef..."
TELEGRAM_CHAT_ID="-1001234567890"
```

---

## ❓ Xử Lý Sự Cố

**Timer không chạy:**
```bash
systemctl status lxc-disk-monitor.timer
journalctl -u lxc-disk-monitor.timer
```

**"GITHUB_TOKEN chưa được đặt":**
```bash
grep GITHUB_TOKEN /opt/lxc-monitor/.env   # kiểm tra token có trong file không
chmod 600 /opt/lxc-monitor/.env           # đảm bảo permission đúng
```

**"Không tìm thấy LXC container nào":**
```bash
# Kiểm tra tên container có khớp pattern không
pvesh get /nodes/localhost/lxc --output-format json | grep hostname
# Sửa LXC_NAME_PATTERN trong .env nếu cần
```

**Clone thất bại - "Source container does not exist":**
```bash
pct status 100   # kiểm tra template container ID=100 có tồn tại không
# Nếu dùng ID khác, sửa SOURCE_CONTAINER_ID trong .env
```
