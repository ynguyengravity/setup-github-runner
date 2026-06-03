from __future__ import annotations

import logging
import subprocess
from datetime import datetime
from pathlib import Path

from .config import Config
from .exceptions import ProxmoxError
from . import proxmox

log = logging.getLogger(__name__)

# Thư mục chứa shell scripts cài đặt bên trong container
_SCRIPTS_DIR = Path(__file__).parent.parent / "container_scripts"


def create_template(config: Config) -> int:
    """
    Tạo LXC container template đầy đủ với:
    Docker, Chrome/Edge/Firefox, Node.js, Playwright, OpenVPN, AWS CLI.
    Trả về VMID của container mới tạo.
    """
    current_date = datetime.now().strftime("%Y%m%d")
    template_file = Path(config.template_url).name
    runner_file = config.github_runner_filename

    _ensure_template_downloaded(config.template_url, template_file)
    _ensure_runner_downloaded(config.github_runner_url, runner_file)

    vmid = proxmox.get_next_id()
    hostname = f"github-runner-{vmid}-{current_date}"
    log.info("Tạo container ID: %s — hostname: %s", vmid, hostname)

    proxmox.create(
        vmid,
        template_file,
        hostname,
        cores=config.pct_cores,
        memory=config.pct_memory,
        swap=config.pct_swap,
        storage=config.pct_storage,
        bridge=config.pct_bridge,
    )

    proxmox.resize(vmid, "rootfs", config.pct_size)
    _configure_docker_cgroups(vmid)
    _configure_tun(vmid)

    log.info("Khởi động container %s...", vmid)
    proxmox.start(vmid)
    proxmox.wait_ready(vmid, delay=10)

    _setup_tun_device(vmid)

    log.info("Chạy các installation scripts...")
    env = _build_env(config)

    for script_name in [
        "01-base.sh",
        "02-browsers.sh",
        "03-nodejs.sh",
        "04-playwright.sh",
        "05-docker.sh",
        "06-openvpn.sh",
        "07-awscli.sh",
    ]:
        script = _SCRIPTS_DIR / script_name
        log.info("  [%s]", script_name)
        proxmox.exec_script(vmid, script, env=env)

    log.info("Pre-download GitHub Actions runner tarball vào container...")
    proxmox.exec_command(
        vmid,
        f"mkdir -p /root/actions-runner && cd /root/actions-runner"
        f" && curl -fsSL -o {runner_file} -L {config.github_runner_url}",
    )

    log.info("Upgrade packages...")
    proxmox.exec_command(
        vmid,
        "apt update -qq && DEBIAN_FRONTEND=noninteractive apt upgrade -y && apt autoremove -y && apt autoclean -y",
    )

    log.info("Reboot container %s...", vmid)
    proxmox.reboot(vmid)

    log.info("Template container %s tạo xong — hostname: %s", vmid, hostname)
    return vmid


# ── Internal helpers ───────────────────────────────────────────────────────────

def _ensure_template_downloaded(url: str, filename: str) -> None:
    if Path(filename).exists():
        log.info("Template %s đã có sẵn, bỏ qua download.", filename)
        return
    log.info("Downloading template %s...", filename)
    subprocess.run(["curl", "-q", "-C", "-", "-o", filename, url], check=True)


def _ensure_runner_downloaded(url: str, filename: str) -> None:
    if Path(filename).exists():
        result = subprocess.run(
            ["tar", "tzf", filename],
            capture_output=True,
        )
        if result.returncode == 0:
            log.info("Runner tarball %s đã có và hợp lệ, bỏ qua download.", filename)
            return
        log.warning("Runner tarball bị hỏng, tải lại...")
        Path(filename).unlink()

    log.info("Downloading GitHub runner %s...", filename)
    subprocess.run(["curl", "-o", filename, "-L", url], check=True)


def _configure_docker_cgroups(vmid: int) -> None:
    log.info("Cấu hình Docker cgroup cho container %s...", vmid)
    proxmox.append_lxc_config(vmid, [
        "# Docker support",
        "lxc.cgroup2.devices.allow: a",
        "lxc.cap.drop: ",
    ])


def _configure_tun(vmid: int) -> None:
    log.info("Cấu hình TUN/TAP cho container %s...", vmid)
    proxmox.append_lxc_config(vmid, [
        "# TUN/TAP for OpenVPN",
        "lxc.cgroup2.devices.allow: c 10:200 rwm",
        "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file",
    ])


def _setup_tun_device(vmid: int) -> None:
    proxmox.exec_command(
        vmid,
        "mkdir -p /dev/net && mknod /dev/net/tun c 10 200 2>/dev/null || true && chmod 600 /dev/net/tun",
    )


def _build_env(config: Config) -> dict[str, str]:
    return {
        "DEBIAN_FRONTEND": "noninteractive",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    }
