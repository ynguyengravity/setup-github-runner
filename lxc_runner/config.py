from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

from .exceptions import ConfigError

_DEFAULT_RUNNER_URL = (
    "https://github.com/actions/runner/releases/download"
    "/v2.334.0/actions-runner-linux-x64-2.334.0.tar.gz"
)
_DEFAULT_TEMPL_URL = (
    "http://download.proxmox.com/images/system"
    "/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
)


@dataclass
class Config:
    # Bắt buộc
    github_token: str
    orgname: str

    # Runner
    runner_labels: str = "vn-gaqc-docker,test-setup"
    runner_group: str = "VN-Team"
    github_runner_url: str = _DEFAULT_RUNNER_URL

    # Proxmox / LXC
    source_container_id: int = 100
    template_url: str = _DEFAULT_TEMPL_URL
    pct_size: str = "50G"
    pct_cores: int = 5
    pct_memory: int = 32768
    pct_swap: int = 32768
    pct_storage: str = "local-lvm2"
    pct_bridge: str = "vmbr1"

    # Monitor
    disk_threshold: int = 85
    lxc_ids: str = "auto"
    lxc_name_pattern: str = "github-runner-"
    lxc_count: int = 35
    maintenance_start: int = 1
    maintenance_end: int = 6

    # Logging
    log_dir: Path = field(default_factory=lambda: Path("/var/log/lxc-monitor"))
    log_retain_days: int = 30

    # Notifications (optional)
    telegram_bot_token: str = ""
    telegram_chat_id: str = ""
    slack_webhook_url: str = ""

    # ── Computed ──────────────────────────────────────────────────────────

    @property
    def runner_url(self) -> str:
        return f"https://github.com/{self.orgname}"

    @property
    def api_registration_url(self) -> str:
        return f"https://api.github.com/orgs/{self.orgname}/actions/runners/registration-token"

    @property
    def api_runners_url(self) -> str:
        return f"https://api.github.com/orgs/{self.orgname}/actions/runners"

    @property
    def github_runner_filename(self) -> str:
        return Path(self.github_runner_url).name

    # ── Constructor ───────────────────────────────────────────────────────

    @classmethod
    def from_env(cls, env_file: Path | None = None) -> Config:
        """Load từ file .env hoặc environment variables."""
        if env_file:
            load_dotenv(env_file, override=True)
        else:
            # Tìm .env theo thứ tự: /opt/lxc-monitor → thư mục hiện tại
            for candidate in [Path("/opt/lxc-monitor/.env"), Path(".env")]:
                if candidate.exists():
                    load_dotenv(candidate, override=True)
                    break

        token = os.getenv("GITHUB_TOKEN", "").strip()
        orgname = os.getenv("ORGNAME", "").strip()

        if not token:
            raise ConfigError("GITHUB_TOKEN chưa được đặt trong .env")
        if not orgname:
            raise ConfigError("ORGNAME chưa được đặt trong .env")

        return cls(
            github_token=token,
            orgname=orgname,
            runner_labels=os.getenv("RUNNER_LABELS", "vn-gaqc-docker,test-setup"),
            runner_group=os.getenv("RUNNER_GROUP", "VN-Team"),
            github_runner_url=os.getenv("GITHUB_RUNNER_URL", _DEFAULT_RUNNER_URL),
            source_container_id=int(os.getenv("SOURCE_CONTAINER_ID", "100")),
            template_url=os.getenv("TEMPL_URL", _DEFAULT_TEMPL_URL),
            pct_size=os.getenv("PCTSIZE", "50G"),
            pct_cores=int(os.getenv("PCT_CORES", "5")),
            pct_memory=int(os.getenv("PCT_MEMORY", "32768")),
            pct_swap=int(os.getenv("PCT_SWAP", "32768")),
            pct_storage=os.getenv("PCT_STORAGE", "local-lvm2"),
            pct_bridge=os.getenv("PCT_BRIDGE", "vmbr1"),
            disk_threshold=int(os.getenv("DISK_THRESHOLD", "85")),
            lxc_ids=os.getenv("LXC_IDS", "auto"),
            lxc_name_pattern=os.getenv("LXC_NAME_PATTERN", "github-runner-"),
            lxc_count=int(os.getenv("LXC_COUNT", "35")),
            maintenance_start=int(os.getenv("MAINTENANCE_START", "1")),
            maintenance_end=int(os.getenv("MAINTENANCE_END", "6")),
            log_dir=Path(os.getenv("LOG_DIR", "/var/log/lxc-monitor")),
            log_retain_days=int(os.getenv("LOG_RETAIN_DAYS", "30")),
            telegram_bot_token=os.getenv("TELEGRAM_BOT_TOKEN", ""),
            telegram_chat_id=os.getenv("TELEGRAM_CHAT_ID", ""),
            slack_webhook_url=os.getenv("SLACK_WEBHOOK_URL", ""),
        )
