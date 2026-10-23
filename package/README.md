# lxc-runner-tools

Gói `.deb` cho Proxmox: tạo template, clone runner GitHub Actions (LXC), và tự dọn/rebuild runner khi disk đầy **lúc runner đang rảnh**.

## Cài đặt (trên Proxmox shell)

```bash
VER=1.0.0
curl -fLO https://github.com/ynguyengravity/setup-github-runner/releases/download/v${VER}/lxc-runner-tools_${VER}_all.deb
apt install ./lxc-runner-tools_${VER}_all.deb

nano /etc/lxc-runner/lxc-runner.env      # GITHUB_TOKEN, SOURCE_CONTAINER_ID...
lxc-runner status
lxc-runner recycle --dry-run
```

Bật tự động (mỗi 15 phút) sau khi log dry-run ổn:

```bash
systemctl enable --now lxc-runner-recycle.timer
journalctl -u lxc-runner-recycle -f
```

Khi đã tin tưởng, đổi `DRY_RUN=0` trong config.

Nâng cấp: cài `.deb` mới (config giữ nguyên). Gỡ: `apt remove lxc-runner-tools` (`apt purge` xóa cả config).

## Lệnh

| Lệnh | Việc làm |
|---|---|
| `lxc-runner template` | Tạo container template (= `lxc_create_github_actions_runner.master.sh`) |
| `lxc-runner clone [N]` | Clone N runner từ template (= `lxc_create_github_actions_runner.clone.sh`) |
| `lxc-runner recycle [--dry-run]` | Dọn/rebuild runner có disk >= `DISK_THRESHOLD` |
| `lxc-runner status` | VMID, disk %, trạng thái GitHub, bận/rảnh |

Biến môi trường ghi đè config: `PCT_CORES=6 lxc-runner clone 2`.

## Recycle hoạt động thế nào

Với mỗi container khớp `LXC_NAME_PATTERN` (trừ template `SOURCE_CONTAINER_ID`):

1. Disk < `DISK_THRESHOLD` → bỏ qua.
2. Runner bận (GitHub API `busy` hoặc có tiến trình `Runner.Worker`) → bỏ qua, lượt sau thử lại.
3. Drain: gỡ custom labels trên GitHub → chờ `DRAIN_WAIT` → kiểm tra lại → stop runner service.
   - Tổng số runner > `MAX_RUNNERS` → gỡ đăng ký + xóa LXC, **không clone thêm** (bỏ qua bước 4–5).
4. Dọn: `docker system prune -af`, `_work` (giữ `_tool`, `_actions`), apt cache, journal. Disk < `CLEAN_TARGET` → start lại runner, trả labels.
5. Vẫn đầy → rebuild (tối đa `MAX_REBUILDS_PER_RUN` mỗi lượt, trong `REBUILD_HOURS` nếu có):
   - Storage đủ chỗ: clone mới → chờ online → gỡ đăng ký + xóa cũ. Lỗi thì giữ container cũ.
   - Không đủ: gỡ đăng ký + xóa cũ → clone mới.

Container **đang tắt**: chỉ xử lý khi tắt 2 lượt timer liên tiếp, không bị Proxmox lock, và có runner cùng tên trên GitHub (để không xóa nhầm template cũ). Khi đó gỡ đăng ký + xóa; tổng ≤ `MAX_RUNNERS` thì clone thay.

`FILL_TO_MAX=1`: cuối mỗi lượt, tổng < `MAX_RUNNERS` thì clone thêm (tối đa `MAX_CLONES_PER_RUN`).

Bỏ qua hẳn một container (vd. cố ý tắt): `pct set <id> --tags lxc-runner-skip`.

Clone dùng `config.sh --replace`: VMID vừa xóa có thể được dùng lại ngay, ra cùng tên runner trong ngày — `--replace` thay bản đăng ký cũ thay vì lỗi.

An toàn: lock chung giữa `recycle`/`clone`/`template` (recycle không bao giờ thấy container clone dở); không đọc được GitHub API thì dừng; bỏ qua container không có `/root/actions-runner/.runner`.

## Build

Tag `v*` → workflow `.github/workflows/release-deb.yml` build và đính `.deb` vào GitHub Release.
Build tay trên máy Debian/Ubuntu: `package/build-deb.sh 1.0.0` → `dist/`.
