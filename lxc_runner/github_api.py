from __future__ import annotations

import logging
import time
from typing import Any

import requests

from .config import Config
from .exceptions import GitHubAPIError

log = logging.getLogger(__name__)

_HEADERS = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}


class GitHubAPI:
    """Wrapper cho GitHub Actions Runner API của một Organization."""

    def __init__(self, config: Config) -> None:
        self._cfg = config
        self._session = requests.Session()
        self._session.headers.update({
            **_HEADERS,
            "Authorization": f"Bearer {config.github_token}",
        })

    # ── Registration token ─────────────────────────────────────────────────

    def get_registration_token(self) -> str:
        """Lấy token ngắn hạn để đăng ký runner mới."""
        resp = self._session.post(self._cfg.api_registration_url, timeout=30)
        if not resp.ok:
            raise GitHubAPIError(
                f"Lấy registration token thất bại: HTTP {resp.status_code} — {resp.text}"
            )
        token = resp.json().get("token", "")
        if not token:
            raise GitHubAPIError("GitHub trả về token rỗng")
        log.debug("Lấy registration token thành công")
        return token

    # ── Runner lookup ──────────────────────────────────────────────────────

    def _iter_runners(self) -> list[dict[str, Any]]:
        """Duyệt tất cả runner (có phân trang), trả về list."""
        runners: list[dict[str, Any]] = []
        page = 1
        while True:
            resp = self._session.get(
                self._cfg.api_runners_url,
                params={"per_page": 100, "page": page},
                timeout=30,
            )
            if not resp.ok:
                raise GitHubAPIError(f"List runners thất bại: HTTP {resp.status_code}")
            data = resp.json().get("runners", [])
            runners.extend(data)
            if len(data) < 100:
                break
            page += 1
        return runners

    def find_runner(self, name: str) -> dict[str, Any] | None:
        """Tìm runner theo tên, trả về dict hoặc None nếu không thấy."""
        for runner in self._iter_runners():
            if runner.get("name") == name:
                return runner
        return None

    # ── Deregister ─────────────────────────────────────────────────────────

    def deregister(self, runner_name: str) -> bool:
        """
        Hủy đăng ký runner khỏi GitHub.
        Trả về True nếu xóa thành công (hoặc runner không tồn tại).
        """
        runner = self.find_runner(runner_name)
        if runner is None:
            log.warning("Runner '%s' không tìm thấy trên GitHub — đã offline hoặc chưa đăng ký", runner_name)
            return True

        runner_id = runner["id"]
        log.info("Tìm thấy runner ID %s — đang hủy đăng ký...", runner_id)

        url = f"{self._cfg.api_runners_url}/{runner_id}"
        resp = self._session.delete(url, timeout=30)

        if resp.status_code == 204:
            log.info("Đã hủy đăng ký runner '%s' (ID: %s)", runner_name, runner_id)
            return True

        log.warning(
            "DELETE runner '%s' trả về HTTP %s — runner sẽ tự offline sau khi container bị xóa",
            runner_name,
            resp.status_code,
        )
        return False

    # ── Verify online ──────────────────────────────────────────────────────

    def verify_online(self, runner_name: str, max_wait: int = 90) -> bool:
        """
        Poll cho đến khi runner xuất hiện trên GitHub hoặc hết thời gian chờ.
        Trả về True nếu runner online.
        """
        attempts = max(1, max_wait // 10)
        log.info("Chờ runner '%s' online (tối đa %ss)...", runner_name, max_wait)

        for attempt in range(1, attempts + 1):
            time.sleep(10)
            log.info("  Kiểm tra lần %d/%d...", attempt, attempts)
            runner = self.find_runner(runner_name)
            if runner:
                status = runner.get("status", "unknown")
                log.info("Runner '%s' online — status: %s", runner_name, status)
                return True

        log.warning("Không tìm thấy runner '%s' sau %ss", runner_name, max_wait)
        return False
