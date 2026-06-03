from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path

from .clone import clone_and_register
from .config import Config
from .exceptions import LxcRunnerError
from .github_api import GitHubAPI
from .notifier import Notifier
from . import proxmox

log = logging.getLogger(__name__)


class DiskMonitor:
    """
    Kiểm tra disk usage của các LXC GitHub runner.
    Khi disk vượt threshold trong maintenance window → rebuild.
    Khi số lượng container < lxc_count → scale up.
    """

    def __init__(self, config: Config, *, dry_run: bool = False, check_only: bool = False) -> None:
        self._cfg = config
        self._dry_run = dry_run
        self._check_only = check_only
        self._gh = GitHubAPI(config)
        self._notify = Notifier(config)

    # ── Public entry point ─────────────────────────────────────────────────

    def run(self) -> dict:
        """
        Chạy một lần kiểm tra đầy đủ.
        Trả về dict tóm tắt kết quả.
        """
        self._cleanup_old_logs()

        vmids = self._get_monitored_ids()
        if not vmids:
            log.warning("Không tìm thấy container nào match pattern '%s'", self._cfg.lxc_name_pattern)
            return {"monitored": 0, "rebuilt": 0, "skipped": 0, "failed": 0}

        log.info("Tìm thấy %d container(s): %s", len(vmids), vmids)

        rebuilt = skipped = failed = 0

        for vmid in vmids:
            result = self._handle_container(vmid)
            if result == "rebuilt":
                rebuilt += 1
            elif result == "failed":
                failed += 1
            else:
                skipped += 1

        # Auto scale-up
        needed = self._cfg.lxc_count - len(vmids)
        if needed > 0:
            created = self._scale_up(needed)
            rebuilt += created

        return {
            "monitored": len(vmids),
            "rebuilt": rebuilt,
            "skipped": skipped,
            "failed": failed,
        }

    # ── Maintenance window ─────────────────────────────────────────────────

    def in_maintenance_window(self) -> bool:
        hour = datetime.now().hour
        start = self._cfg.maintenance_start
        end = self._cfg.maintenance_end
        if start <= end:
            return start <= hour < end
        # Window qua nửa đêm (ví dụ: 22h–4h)
        return hour >= start or hour < end

    # ── Per-container logic ────────────────────────────────────────────────

    def _handle_container(self, vmid: int) -> str:
        """Trả về 'rebuilt' | 'skipped' | 'failed'."""
        hostname = proxmox.get_hostname(vmid)
        log.info("Kiểm tra container [%s] — %s", vmid, hostname)

        if not proxmox.is_running(vmid):
            log.warning("Container %s không chạy — bỏ qua", vmid)
            return "skipped"

        usage = proxmox.get_disk_usage_pct(vmid)
        if usage is None:
            log.warning("Không đọc được disk của container %s — bỏ qua", vmid)
            return "skipped"

        log.info("  Disk: %d%% (ngưỡng: %d%%)", usage, self._cfg.disk_threshold)

        if usage < self._cfg.disk_threshold:
            log.info("  OK — không cần action")
            return "skipped"

        log.warning("  DISK ĐẦY! %d%% >= %d%%", usage, self._cfg.disk_threshold)

        if self._check_only:
            log.warning("  [CHECK-ONLY] Bỏ qua action")
            return "skipped"

        if not self.in_maintenance_window():
            log.warning(
                "  Ngoài maintenance window (%dh–%dh) — chỉ cảnh báo",
                self._cfg.maintenance_start,
                self._cfg.maintenance_end,
            )
            self._notify.send(
                f"⚠️ *LXC Disk Full* | `{vmid}` ({hostname}) | {usage}%"
                f" | Chờ window {self._cfg.maintenance_start}h–{self._cfg.maintenance_end}h"
            )
            return "skipped"

        self._notify.send(
            f"⚠️ *LXC Disk Full* | `{vmid}` ({hostname}) | {usage}% | Đang rebuild..."
        )
        return self._rebuild(vmid, hostname)

    def _rebuild(self, vmid: int, hostname: str) -> str:
        """Deregister → destroy → clone. Trả về 'rebuilt' | 'failed'."""
        if self._dry_run:
            log.warning("[DRY-RUN] Sẽ rebuild container %s (%s)", vmid, hostname)
            return "skipped"

        try:
            log.info("Hủy đăng ký runner '%s'...", hostname)
            self._gh.deregister(hostname)

            log.info("Xóa container %s...", vmid)
            proxmox.stop(vmid)
            proxmox.destroy(vmid)

            log.info("Clone container mới từ template %s...", self._cfg.source_container_id)
            new_id = clone_and_register(self._cfg)

            log.info("Rebuild xong! Container mới: %s", new_id)
            self._notify.send(f"✅ *LXC Rebuilt* | Cũ: `{vmid}` → Mới: `{new_id}`")
            return "rebuilt"

        except LxcRunnerError as exc:
            log.error("Rebuild thất bại: %s", exc)
            self._notify.send(f"❌ *LXC Rebuild FAILED* | `{vmid}` ({hostname}) | {exc}")
            return "failed"

    def _scale_up(self, needed: int) -> int:
        """Tạo thêm container để đủ số lượng. Trả về số container đã tạo."""
        current = self._cfg.lxc_count - needed
        log.warning("Thiếu %d container (hiện có %d/%d)", needed, current, self._cfg.lxc_count)

        if self._check_only or self._dry_run:
            log.warning("[%s] Bỏ qua scale-up", "CHECK-ONLY" if self._check_only else "DRY-RUN")
            return 0

        if not self.in_maintenance_window():
            log.warning(
                "Ngoài maintenance window — sẽ scale up lúc %dh",
                self._cfg.maintenance_start,
            )
            self._notify.send(
                f"⚠️ *LXC thiếu* | {current}/{self._cfg.lxc_count}"
                f" | Sẽ tạo thêm trong window {self._cfg.maintenance_start}h–{self._cfg.maintenance_end}h"
            )
            return 0

        self._notify.send(
            f"🔧 *LXC Scale Up* | Hiện có: {current}/{self._cfg.lxc_count}"
            f" | Đang tạo thêm {needed}..."
        )

        created = 0
        for i in range(1, needed + 1):
            log.info("Tạo container mới %d/%d...", i, needed)
            try:
                new_id = clone_and_register(self._cfg)
                log.info("Tạo xong container mới: %s (%d/%d)", new_id, i, needed)
                created += 1
            except LxcRunnerError as exc:
                log.error("Tạo container %d/%d thất bại: %s", i, needed, exc)
                self._notify.send(f"❌ *Scale Up FAILED* | Container {i}/{needed}: {exc}")
                break

        self._notify.send(
            f"✅ *Scale Up Done* | Đã tạo thêm {created}/{needed}"
            f" | Tổng: {current + created}/{self._cfg.lxc_count}"
        )
        return created

    # ── Container discovery ────────────────────────────────────────────────

    def _get_monitored_ids(self) -> list[int]:
        """Trả về danh sách VMID cần monitor."""
        if self._cfg.lxc_ids != "auto":
            return [int(x.strip()) for x in self._cfg.lxc_ids.split(",") if x.strip()]

        containers = proxmox.list_containers()
        result = []
        for c in containers:
            vmid = int(c["vmid"])
            hostname = proxmox.get_hostname(vmid)
            if self._cfg.lxc_name_pattern in hostname:
                result.append(vmid)
        return sorted(result)

    # ── Log cleanup ────────────────────────────────────────────────────────

    def _cleanup_old_logs(self) -> None:
        log_dir = self._cfg.log_dir
        if not log_dir.exists():
            return
        cutoff = self._cfg.log_retain_days
        import time
        now = time.time()
        for f in log_dir.glob("lxc-monitor-*.log"):
            if (now - f.stat().st_mtime) > cutoff * 86400:
                f.unlink(missing_ok=True)
