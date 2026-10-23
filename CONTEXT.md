# CONTEXT — GitHub Actions runner LXC trên Proxmox (nhánh `master`)

Nguồn context duy nhất cho nhánh `master`: hệ thống runner LXC và gói `lxc-runner-tools`.
Phần k3s + ARC nằm ở nhánh `v2` (`docs/proxmox-k3s-arc-guide.md`).

**Quy ước:** ✅ = đã kiểm chứng (ghi ngày + bằng chứng) · ⚠️ = chưa kiểm chứng / cần kiểm tra lại.
Không ghi điều chưa kiểm chứng như sự thật. Khi đổi code/config, cập nhật file này trong cùng commit.

Cập nhật lần cuối: 2026-10-23.

---

## 1. Tổng quan

- Mục tiêu: chạy self-hosted runner GitHub Actions cho org **`Gravity-Global`**, runner group **`VN-Team`**, dưới dạng LXC container trên một node Proxmox; tự dọn/rebuild runner khi đầy disk mà không cắt ngang job.
- Cách làm:
  1. `master.sh` tạo **container template** (Ubuntu 24.04 + browsers + Node + Playwright + Docker + AWS CLI + tarball runner).
  2. `clone.sh` clone template → đăng ký runner với GitHub.
  3. Gói `.deb` **`lxc-runner-tools`** bọc hai script trên thành lệnh `lxc-runner`, thêm `recycle` chạy bằng systemd timer.
- Repo: `github.com/ynguyengravity/setup-github-runner` — ✅ **public** (2026-10-23, `gh repo view`). **Không bao giờ commit token.**

## 2. Trạng thái hiện tại

| Hạng mục | Trạng thái |
|---|---|
| Gói trên host | ✅ `lxc-runner-tools 0.0.4` đã cài (2026-10-23 ~17:00, output `apt install` + `lxc-runner version`) |
| Timer recycle | ✅ bật, chạy mỗi 15 phút (`systemctl list-timers` 2026-10-23 16:47: last 16:45, next 17:00) |
| Số runner | ✅ 31 LXC, VMID 101–131, tất cả `running` + `online` trên GitHub, disk 13–38% (`lxc-runner status` 2026-10-23 ~16:40) |
| `MAX_RUNNERS` trên host | ✅ 50 (dòng `Runners: 31 / max 50`) |
| `DRY_RUN` trên host | ⚠️ chưa thấy — kiểm tra: `grep DRY_RUN /etc/lxc-runner/lxc-runner.env` hoặc dòng `Recycle: ... dry-run N` trong journal |
| `FILL_TO_MAX` trên host | ⚠️ chưa thấy (mặc định gói = 0) |
| `SOURCE_CONTAINER_ID` (template) | ⚠️ chưa xác nhận template hiện tại là ID nào / còn tồn tại không |
| Template mới | ⚠️ đang build lại. Lần build bằng 0.0.3 **lỗi** ở bước Docker (✅ output `Failed to restart docker.service: Unit docker.service not found`). Nguyên nhân nghi do `DRY_RUN` lọt vào container (mục 8) — ⚠️ chưa chạy lệnh xác nhận. ⚠️ ID của container template dở dang và đã xóa chưa: chưa biết |
| Nguồn gốc 31 runner | ⚠️ tên dạng `github-runner-1xx-20261023MAY` — hậu tố `MAY` **không** do script trong repo tạo; cấu hình (cores/RAM/disk) chưa kiểm tra |
| OS host | ✅ Debian 13 (libc `2.41-12+deb13u4` trong output apt, 2026-10-23) |
| OS trong container | ✅ Ubuntu 24.04 (libc `2.39-0ubuntu8.9` trong output build template) |
| ARC (nhánh `v2`) | ⚠️ theo ghi chú 2026-10-23 sáng: k3s + ARC đang chạy, scale set `vn-gaqc-docker`, maxRunners 40. Chưa kiểm tra lại song song với 31 LXC |

## 3. Proxmox host

⚠️ Các số dưới đây lấy từ discovery 2026-10-22 (nhánh `v2`, `scripts/pve-discovery.sh`), chưa đo lại trên `master`:

- Node `GG-Nha-VM-GA`, Xeon Silver 4109T **32 thread**, 376 GiB RAM. CPU đã 76–89% bận trước khi thêm runner; RAM cấp phát ~3,6× thực.
- Mạng: `vmbr0` LAN 10.128.6.102/24; **`vmbr1`** NAT 192.168.8.1/22, DHCP 192.168.8.10–192.168.11.254 (runner LXC lấy IP DHCP ở đây). MTU đường ra ~1480.
- Storage: **`local-lvm2`** (LVM thick, ~348 GB trống lúc đo) — mỗi LXC chiếm trọn `PCTSIZE`. `local-lvm` (thin) gần đầy, không dùng.
- Truy cập: chỉ qua **shell của Proxmox web UI** (không SSH từ Mac). Lệnh dài chạy trong `tmux`.

Kiểm tra lại: `nproc; free -g; uptime; pvesh get /storage/local-lvm2/status --output-format json | jq '.avail/1024/1024/1024|floor'`.

## 4. Repo

```
lxc_create_github_actions_runner.master.sh   tạo template (đọc config từ env)
lxc_create_github_actions_runner.clone.sh    clone template + đăng ký runner (in NEW_PCTID=<id>)
package/
  lxc-runner                 CLI → /usr/sbin/lxc-runner
  lib/common.sh              log, load_config, GitHub API, pvesh, lock
  lib/recycle.sh             logic recycle
  lxc-runner.env             config mẫu → /etc/lxc-runner/lxc-runner.env (conffile, 600)
  systemd/lxc-runner-recycle.{service,timer}
  debian/{control,conffiles,postinst,prerm,postrm}
  build-deb.sh               build dist/lxc-runner-tools_<ver>_all.deb
  README.md                  hướng dẫn cài ngắn
.github/workflows/release-deb.yml   tag v* → lint + build + đính .deb vào Release
.github/workflows/test-runner.yml   (cũ) chạy trên label test-setup mỗi push master — xem mục 9
```

Nhánh: `master` = LXC (file này) · `v2` = k3s + ARC. Commit `7d59d3b v-optimize` đã xóa bộ công cụ cũ (Python `lxc_runner/`, `container_scripts/`, `install.sh`, monitor systemd…) — có thể xem lại bằng `git show 7d59d3b~1:<path>`.

## 5. Template & runner

`master.sh` (`lxc-runner template`) tạo LXC từ `ubuntu-24.04-standard_24.04-2`:

| Thông số | Giá trị mặc định (config) |
|---|---|
| CPU / RAM / swap | `PCT_CORES=3`, `PCT_MEMORY=16384` MiB, `PCT_SWAP=4096` MiB (trước 2026-10-23: 5 / 32768 / 32768) |
| Disk | `PCTSIZE=25G` trên `PCT_STORAGE=local-lvm2` (trước: 50G) |
| Mạng | `PCT_BRIDGE=vmbr1`, DHCP, firewall=1 |
| Chế độ | **privileged** (`-unprivileged 0`), `nesting=1,keyctl=1`, `lxc.cgroup2.devices.allow: a`, `lxc.cap.drop:` rỗng, TUN `/dev/net/tun` (cho Docker + OpenVPN) |
| Root | mật khẩu **khóa** (`passwd -l root`); vào shell bằng `pct enter <id>` |
| Cài sẵn | Chrome, Edge, Firefox (PPA), xvfb, Node 24 (NodeSource), Playwright + browsers, OpenVPN, Docker (`get.docker.com`, `daemon.json` `iptables:false`), AppArmor tắt, AWS CLI v2, `apt upgrade`, tarball runner `v2.338.0` ở `/root/actions-runner/` |
| Cuối | `pct reboot`, in `TEMPLATE_PCTID=<id>` |

`clone.sh` (`lxc-runner clone N`): dừng template (nếu đang chạy) → `pct clone --full` → hostname `github-runner-<id>-<YYYYMMDD>` → áp `PCT_CORES/MEMORY/SWAP` nếu đặt → start → chờ DNS `api.github.com` (≤60s) → reset machine-id, khóa root → lấy registration token → `config.sh --unattended --replace` (labels `RUNNER_LABELS`, group `RUNNER_GROUP`) → service + `onboot=1` → start lại template nếu lúc đầu đang chạy → in `NEW_PCTID=<id>`.

- **Tên runner trên GitHub = hostname LXC.** Recycle dựa vào điều này để map LXC ↔ runner.
- `--replace`: VMID vừa xóa có thể được dùng lại ngay → cùng tên trong ngày; `--replace` thay bản đăng ký cũ thay vì lỗi.
- Labels mặc định `vn-gaqc-docker,test-setup` — ⚠️ trùng tên scale set ARC (mục 9).

## 6. Gói `lxc-runner-tools`

### Lệnh

| Lệnh | Việc |
|---|---|
| `lxc-runner template` | chạy `master.sh` (cache template ở `/var/lib/lxc-runner/cache`) |
| `lxc-runner clone [N]` | chạy `clone.sh` N lần |
| `lxc-runner recycle [--dry-run]` | dọn/rebuild/xóa/bù runner (mục 7) |
| `lxc-runner status` | `Runners: N / max M` + bảng VMID, disk %, GitHub online/offline, busy |
| `lxc-runner version` | phiên bản |

`template`/`clone`/`recycle` dùng **chung lock** `/var/lib/lxc-runner/lxc-runner.lock`: `template`/`clone` chờ; `recycle` gặp lock thì log `Đang có recycle/clone/template khác chạy — bỏ qua lượt này` và thoát (✅ thấy lúc 16:45 khi đang build template).

### Config `/etc/lxc-runner/lxc-runner.env`

Định dạng `KEY=VALUE`, đọc nguyên văn (không `eval`). **Biến môi trường khi chạy lệnh ghi đè file** (vd `PCT_CORES=6 lxc-runner clone`). Mỗi lần chạy đọc lại file → sửa xong **không cần restart** gì.

| Nhóm | Key (mặc định) |
|---|---|
| GitHub | `GITHUB_TOKEN` (PAT classic, `admin:org`), `ORGNAME=Gravity-Global`, `RUNNER_GROUP=VN-Team`, `RUNNER_LABELS=vn-gaqc-docker,test-setup`, `GITHUB_RUNNER_URL` (v2.338.0) |
| Template | `SOURCE_CONTAINER_ID=100`, `TEMPL_URL`, `PCTSIZE=25G`, `PCT_CORES=3`, `PCT_MEMORY=16384`, `PCT_SWAP=4096`, `PCT_STORAGE=local-lvm2`, `PCT_BRIDGE=vmbr1` |
| Recycle | `DRY_RUN=1`, `DISK_THRESHOLD=90`, `CLEANUP=1`, `CLEAN_TARGET=80`, `MAX_REBUILDS_PER_RUN=1`, `MAX_RUNNERS=` (rỗng = không giới hạn), `FILL_TO_MAX=0`, `MAX_CLONES_PER_RUN=2`, `SKIP_TAG=lxc-runner-skip`, `REBUILD_HOURS=` (vd `1-6`), `LXC_IDS=` (vd `101,102`), `LXC_NAME_PATTERN=^github-runner-`, `STORAGE_MARGIN_GB=10` |
| Thông báo | `SLACK_WEBHOOK_URL`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (rỗng = chỉ log) |

### Timer

`OnCalendar=*:0/15` (phút :00 :15 :30 :45, trễ ≤1 phút), `OnBootSec=10min`, `Persistent=true`. Không chạy chồng. Đổi lịch: `systemctl edit lxc-runner-recycle.timer` → `[Timer]` / `OnCalendar=` / `OnCalendar=*:0/30`.

## 7. Recycle — thuật toán

Chỉ xét LXC tên khớp `LXC_NAME_PATTERN`, **trừ** template `SOURCE_CONTAINER_ID` và LXC gắn tag `SKIP_TAG`. **Tổng** = số LXC đó (kể cả đang tắt). Không đọc được GitHub API → dừng cả lượt.

**LXC đang chạy, disk ≥ `DISK_THRESHOLD`:**
1. Không có `/root/actions-runner/.runner` → bỏ qua (template, LXC hỏng).
2. Bận (GitHub `busy` hoặc có tiến trình `Runner.Worker`) → bỏ qua, lượt sau thử lại.
3. `DRY_RUN=1` → chỉ log.
4. **Drain**: gỡ custom labels trên GitHub → chờ `DRAIN_WAIT` (20s) → kiểm tra bận lại (bận thì trả labels, bỏ qua) → stop runner service.
5. **Tổng > `MAX_RUNNERS`** → gỡ đăng ký + xóa LXC, **không dọn, không clone**.
6. **Tổng ≤ `MAX_RUNNERS`** → dọn (`docker system prune -af`, `docker volume prune`, `_work/*` trừ `_tool`/`_actions`, `apt-get clean`, journal 100M, cache npm, `/tmp` >1 ngày). Disk < `CLEAN_TARGET` → start runner, trả labels, xong.
7. Vẫn đầy → rebuild (tối đa `MAX_REBUILDS_PER_RUN`/lượt, trong `REBUILD_HOURS` nếu đặt):
   - storage đủ (template maxdisk + `STORAGE_MARGIN_GB`): clone mới → chờ online (`ONLINE_WAIT` 180s) → gỡ đăng ký + xóa cũ; lỗi thì giữ cũ.
   - không đủ: gỡ đăng ký + xóa cũ → clone mới.

**LXC đang tắt** — chỉ xử lý khi đủ cả: tắt **2 lượt liên tiếp** (lưu ở `/var/lib/lxc-runner/stopped.list`, theo `vmid:tên`), **không bị lock** Proxmox, **có runner cùng tên trên GitHub** (chặn xóa nhầm template cũ). Khi đó gỡ đăng ký + xóa; tổng ≤ max thì clone thay.

**Bù số lượng** — `FILL_TO_MAX=1` và tổng < `MAX_RUNNERS`: cuối lượt clone thêm ≤ `MAX_CLONES_PER_RUN` (kiểm tra storage trước mỗi clone). Bỏ qua khi đặt `LXC_IDS`.

**Xóa LXC** = `DELETE /orgs/Gravity-Global/actions/runners/{id}` + `pct stop` + `pct destroy --purge` (xóa config, rootfs trên `local-lvm2`, khỏi backup/replication/HA).

**Không bao giờ:** tự bật LXC đang tắt; xóa runner thừa khi disk chưa đầy; đụng template / LXC có tag skip / VM khác.

Chạy thử một vòng đầy đủ trên 1 runner rảnh:
`DRY_RUN=0 DISK_THRESHOLD=1 CLEAN_TARGET=1 LXC_IDS=<id> lxc-runner recycle`

## 8. Bảo mật

- `pct exec` (lxc-attach) **giữ environment của host** → biến host lọt vào lệnh chạy trong container. Từ **0.0.4**: `master.sh`, `clone.sh`, `recycle.sh` dùng `export -n` cho `GITHUB_TOKEN`, `DRY_RUN`, webhook; recycle truyền token tường minh cho `clone.sh`.
- Sự cố đã biết: build template bằng 0.0.3 → `DRY_RUN=1` lọt vào `get.docker.com` (script này coi `DRY_RUN` khác rỗng là chạy thử) → Docker không được cài; PAT cũng nằm trong env của các script cài đặt trong template đó. ⚠️ Cân nhắc **xoay PAT** (tạo mới → sửa config → thu hồi cũ).
- Config 600, conffile (nâng cấp không ghi đè). `apt remove` **giữ** token; `apt purge` mới xóa.
- Container privileged + AppArmor tắt (cần cho Docker/TUN trong LXC) — chấp nhận, chưa chuyển unprivileged.

## 9. Việc còn mở / rủi ro

- ⚠️ **Template**: build lại bằng 0.0.4 → kiểm tra (`docker --version`, browsers, `node -v`, `npx playwright --version`, `aws --version`, `ls /root/actions-runner`) → đặt `SOURCE_CONTAINER_ID` → test clone → xóa (hoặc tag skip) template cũ.
- ⚠️ **Trùng label với ARC**: `RUNNER_LABELS` chứa `vn-gaqc-docker` = tên scale set ARC → job chia giữa LXC và ARC nếu ARC còn chạy. (Đã quyết định để nguyên — 2026-10-23.)
- ⚠️ **Tải CPU**: 31 LXC + ARC trên 32 thread. `MAX_RUNNERS=50` + `FILL_TO_MAX=1` sẽ clone thêm 19. Đo `uptime` trước khi tăng.
- ⚠️ **Docker `iptables:false`** trong container: Docker network có thể không có NAT ra ngoài. Chưa test (đã quyết định bỏ qua — 2026-10-23).
- **Workflow `test-runner.yml`**: ✅ nhiều lượt `queued` mãi (2026-10-23, `gh run list`); mỗi push master thêm 1 lượt. Nguyên nhân: repo này là repo **cá nhân** (`ynguyengravity/…`), runner của org `Gravity-Global` không phục vụ repo ngoài org → `runs-on: test-setup` không bao giờ có runner. Workflow còn giả định user `test` (runner chạy root). Cần hủy run + bỏ trigger `push` (hoặc xóa workflow).
- **Release có file zip thừa**: ✅ `v0.0.2`–`v0.0.4` có `lxc-runner-tools.zip` (bên trong là bản `0.0.0+master`) cạnh file `.deb` đúng. **Chỉ cài `.deb`.**

## 10. Quy trình release & cài

1. Sửa code → commit → push `master`.
2. `git tag vX.Y.Z && git push origin vX.Y.Z` → workflow `release-deb.yml` (ubuntu-latest, GitHub-hosted) chạy `bash -n` + `shellcheck -S error` + build → đính `lxc-runner-tools_X.Y.Z_all.deb` vào Release. Không cần upload tay.
3. Trên Proxmox:
   ```bash
   cd /tmp
   curl -fLO https://github.com/ynguyengravity/setup-github-runner/releases/download/vX.Y.Z/lxc-runner-tools_X.Y.Z_all.deb
   systemctl is-active lxc-runner-recycle.service   # chờ "inactive"
   apt install ./lxc-runner-tools_X.Y.Z_all.deb      # dpkg hỏi lxc-runner.env → N (giữ bản của mình)
   lxc-runner version
   ```

Vòng đời gói:

| Lệnh | Kết quả |
|---|---|
| cài | file vào `/usr/sbin`, `/usr/lib/lxc-runner`, `/lib/systemd/system`, `/etc/lxc-runner`; `postinst` chmod 600, `daemon-reload`; **timer không tự bật** |
| nâng cấp | thay script/unit; timer giữ trạng thái; config giữ (hỏi nếu file mẫu đổi) |
| `apt remove` | `prerm` tắt timer + dừng service; giữ config + `/var/lib/lxc-runner` |
| `apt purge` | xóa thêm `/etc/lxc-runner`, `/var/lib/lxc-runner` |
| — | gói **không** đụng LXC/runner/template khi gỡ |

Cài lại đúng cùng phiên bản cần `apt install --reinstall`.

## 11. Vận hành nhanh

```bash
lxc-runner status
lxc-runner recycle --dry-run
journalctl -u lxc-runner-recycle --since today --no-pager | grep -E "Recycle:|Runners:|WARN|Fill|Xong"
systemctl list-timers 'lxc-runner*' --no-pager
pct set <id> --tags lxc-runner-skip          # cấm script đụng vào LXC này
tmux new -s tpl; lxc-runner template          # build template
```

## 12. Nhật ký quyết định (2026-10-23)

- Review script cũ: sửa phiên bản runner lệch (clone 2.334 ↔ master 2.338), hậu tố `-27` gắn cứng, template luôn bị bật lại sau clone, `passwd -d root`, token hiện khi gõ / in ra log, tài nguyên quá lớn, `sleep` cố định thay vì chờ mạng.
- Bỏ qua có chủ đích: label `test-setup` trên runner production; trùng label ARC; Docker `iptables:false`.
- Tài nguyên template: giảm một nửa so với gốc → 3 core / 16 GiB / 25G, swap 4 GiB.
- Đóng gói `.deb` (bash) thay vì binary Go / tar.gz.
- Recycle: dọn trước rồi mới rebuild; không giới hạn khung giờ mặc định; thông báo tắt mặc định; `DRY_RUN=1` mặc định.
- Số lượng: `> max` + đầy → xóa không clone; `≤ max` + đầy → dọn/xóa + clone; `FILL_TO_MAX` (tùy chọn) để bù.
- LXC đang tắt → xóa + clone thay (với 4 điều kiện an toàn ở mục 7).
- `--replace` khi đăng ký để xử lý VMID dùng lại.
- 0.0.4: chặn env host lọt vào container.
