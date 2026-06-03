from __future__ import annotations

import logging
import time
from dataclasses import dataclass

from .clone import clone_and_register, _CLONE_SUFFIX
from .config import Config
from .exceptions import LxcRunnerError
from .github_api import GitHubAPI
from . import proxmox

log = logging.getLogger(__name__)


@dataclass
class CycleResult:
    old_vmid: int
    old_hostname: str
    new_vmid: int | None
    new_hostname: str | None
    elapsed_seconds: int
    success: bool
    error: str = ""


class FullCycleTester:
    """
    Thực hiện full cycle cho một container:
    1. Deregister runner khỏi GitHub
    2. Destroy container cũ
    3. Clone container mới từ template
    4. Verify runner mới online trên GitHub
    """

    def __init__(self, config: Config, *, dry_run: bool = False) -> None:
        self._cfg = config
        self._dry_run = dry_run
        self._gh = GitHubAPI(config)

    def run(self, target_vmid: int) -> CycleResult:
        hostname = proxmox.get_hostname(target_vmid)
        log.info("Container đích: %s (%s)", target_vmid, hostname)
        log.info("Template source: %s", self._cfg.source_container_id)

        start = time.time()
        new_vmid: int | None = None
        new_hostname: str | None = None

        try:
            self._step_deregister(hostname)
            self._step_destroy(target_vmid, hostname)
            new_vmid = self._step_clone()

            from datetime import datetime
            new_hostname = f"github-runner-{new_vmid}-{datetime.now().strftime('%Y%m%d')}-{_CLONE_SUFFIX}"
            self._step_verify(new_hostname)

        except LxcRunnerError as exc:
            elapsed = int(time.time() - start)
            log.error("Cycle thất bại: %s", exc)
            return CycleResult(
                old_vmid=target_vmid,
                old_hostname=hostname,
                new_vmid=new_vmid,
                new_hostname=new_hostname,
                elapsed_seconds=elapsed,
                success=False,
                error=str(exc),
            )

        elapsed = int(time.time() - start)
        log.info("Cycle hoàn tất trong %ds", elapsed)
        return CycleResult(
            old_vmid=target_vmid,
            old_hostname=hostname,
            new_vmid=new_vmid,
            new_hostname=new_hostname,
            elapsed_seconds=elapsed,
            success=True,
        )

    # ── Steps ──────────────────────────────────────────────────────────────

    def _step_deregister(self, hostname: str) -> None:
        log.info("STEP 1/4 — Hủy đăng ký runner '%s' khỏi GitHub", hostname)
        if self._dry_run:
            log.warning("[DRY-RUN] Bỏ qua deregister")
            return
        self._gh.deregister(hostname)

    def _step_destroy(self, vmid: int, hostname: str) -> None:
        log.info("STEP 2/4 — Xóa container %s (%s)", vmid, hostname)
        if self._dry_run:
            log.warning("[DRY-RUN] Bỏ qua xóa container")
            return
        proxmox.stop(vmid)
        proxmox.destroy(vmid)

    def _step_clone(self) -> int:
        log.info("STEP 3/4 — Clone container mới từ template %s", self._cfg.source_container_id)
        if self._dry_run:
            log.warning("[DRY-RUN] Bỏ qua clone")
            return -1
        return clone_and_register(self._cfg)

    def _step_verify(self, expected_hostname: str) -> None:
        log.info("STEP 4/4 — Verify runner '%s' online", expected_hostname)
        if self._dry_run:
            log.warning("[DRY-RUN] Bỏ qua verify")
            return
        ok = self._gh.verify_online(expected_hostname, max_wait=90)
        if not ok:
            log.warning("Runner chưa online sau 90s — kiểm tra log container")
