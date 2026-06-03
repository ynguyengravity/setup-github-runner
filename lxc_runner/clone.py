from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path

from .config import Config
from .github_api import GitHubAPI
from . import proxmox

log = logging.getLogger(__name__)

_SCRIPTS_DIR = Path(__file__).parent.parent / "container_scripts"

# Suffix cố định để phân biệt các clone trong cùng ngày (giống script gốc)
_CLONE_SUFFIX = "27"


def clone_and_register(config: Config) -> int:
    """
    Clone container template → đăng ký GitHub Actions runner mới.
    Trả về VMID của container vừa tạo.
    """
    source_id = config.source_container_id
    current_date = f"{datetime.now().strftime('%Y%m%d')}-{_CLONE_SUFFIX}"

    if not _container_exists(source_id):
        raise RuntimeError(
            f"Source container {source_id} không tồn tại — hãy chạy 'lxc-runner create' trước"
        )

    proxmox.sanitize_lxc_config(source_id)

    new_id = proxmox.get_next_id()
    hostname = f"github-runner-{new_id}-{current_date}"
    log.info("Clone %s → %s (hostname: %s)", source_id, new_id, hostname)

    if proxmox.is_running(source_id):
        log.info("Dừng source container %s trước khi clone...", source_id)
        proxmox.stop(source_id)
        _source_was_running = True
    else:
        _source_was_running = False

    proxmox.clone(source_id, new_id, hostname)
    proxmox.sanitize_lxc_config(new_id)
    proxmox.set_hostname(new_id, hostname)

    log.info("Khởi động container %s...", new_id)
    proxmox.start(new_id)
    proxmox.wait_ready(new_id, delay=25)

    log.info("Reset machine ID...")
    proxmox.exec_command(
        new_id,
        "rm -f /etc/machine-id /var/lib/dbus/machine-id"
        " && systemd-machine-id-setup"
        " && dbus-uuidgen --ensure",
    )

    log.info("Lấy runner registration token...")
    gh = GitHubAPI(config)
    runner_token = gh.get_registration_token()

    log.info("Cài đặt GitHub Actions runner...")
    runner_env = {
        "RUNNER_TOKEN": runner_token,
        "RUNNER_URL": config.runner_url,
        "RUNNER_NAME": hostname,
        "RUNNER_LABELS": config.runner_labels,
        "RUNNER_GROUP": config.runner_group,
        "GITHUB_RUNNER_FILE": config.github_runner_filename,
        "ORGNAME": config.orgname,
    }
    proxmox.exec_script(new_id, _SCRIPTS_DIR / "08-runner.sh", env=runner_env)

    log.info("Cấu hình PATH cho runner service...")
    _configure_runner_service_path(new_id, hostname, config.orgname)

    proxmox.set_onboot(new_id, True)

    if _source_was_running:
        log.info("Khởi động lại source container %s...", source_id)
        proxmox.start(source_id)

    log.info("Container %s (%s) đã sẵn sàng!", new_id, hostname)
    return new_id


# ── Internal helpers ───────────────────────────────────────────────────────────

def _container_exists(vmid: int) -> bool:
    import subprocess
    result = subprocess.run(
        ["pct", "status", str(vmid)],
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def _configure_runner_service_path(vmid: int, hostname: str, orgname: str) -> None:
    """Thêm PATH vào systemd service của runner để aws/docker available."""
    service_name = f"actions.runner.{orgname}.{hostname}.service"
    override_dir = f"/etc/systemd/system/{service_name}.d"
    proxmox.exec_command(vmid, f"mkdir -p {override_dir}")
    proxmox.exec_command(
        vmid,
        f"printf '[Service]\\nEnvironment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\\n'"
        f" > {override_dir}/path.conf",
    )
    proxmox.exec_command(vmid, "systemctl daemon-reload")
    proxmox.exec_command(vmid, f"systemctl restart {service_name} || true")
