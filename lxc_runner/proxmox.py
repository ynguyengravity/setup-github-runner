from __future__ import annotations

import json
import logging
import subprocess
import tempfile
import time
from pathlib import Path

from .exceptions import ContainerScriptError, ProxmoxError

log = logging.getLogger(__name__)


def _run(*args: str, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    """Wrapper chung cho subprocess, raise ProxmoxError nếu thất bại."""
    cmd = list(args)
    log.debug("$ %s", " ".join(cmd))
    try:
        result = subprocess.run(
            cmd,
            check=check,
            capture_output=capture,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        raise ProxmoxError(f"Lệnh thất bại: {' '.join(cmd)}\n{stderr}") from exc
    except FileNotFoundError as exc:
        raise ProxmoxError(f"Không tìm thấy lệnh: {cmd[0]}") from exc
    return result


# ── pvesh helpers ──────────────────────────────────────────────────────────────

def get_next_id() -> int:
    """Lấy VMID trống tiếp theo từ Proxmox cluster."""
    result = _run("pvesh", "get", "/cluster/nextid", capture=True)
    return int(result.stdout.strip())


def list_containers() -> list[dict]:
    """Trả về danh sách tất cả LXC containers trên node localhost."""
    result = _run(
        "pvesh", "get", "/nodes/localhost/lxc", "--output-format", "json",
        capture=True,
    )
    return json.loads(result.stdout)


def get_latest_vmid() -> int:
    """VMID lớn nhất hiện tại (container vừa clone xong)."""
    containers = list_containers()
    if not containers:
        raise ProxmoxError("Không có container nào trên node")
    return max(int(c["vmid"]) for c in containers)


# ── pct helpers ───────────────────────────────────────────────────────────────

def get_hostname(vmid: int) -> str:
    result = _run("pct", "config", str(vmid), capture=True, check=False)
    for line in result.stdout.splitlines():
        if line.startswith("hostname:"):
            return line.split(":", 1)[1].strip()
    return f"unknown-{vmid}"


def is_running(vmid: int) -> bool:
    result = _run("pct", "status", str(vmid), capture=True, check=False)
    return "status: running" in result.stdout


def start(vmid: int) -> None:
    log.info("Khởi động container %s...", vmid)
    _run("pct", "start", str(vmid))


def stop(vmid: int, timeout: int = 30) -> None:
    log.info("Dừng container %s...", vmid)
    _run("pct", "stop", str(vmid), "--timeout", str(timeout), check=False)


def reboot(vmid: int) -> None:
    log.info("Reboot container %s...", vmid)
    _run("pct", "reboot", str(vmid))


def destroy(vmid: int) -> None:
    log.info("Xóa container %s...", vmid)
    _run("pct", "destroy", str(vmid), "--destroy-unreferenced-disks", "1", "--purge", "1")


def resize(vmid: int, storage: str, size: str) -> None:
    log.info("Resize container %s rootfs → %s", vmid, size)
    _run("pct", "resize", str(vmid), storage, size)


def set_onboot(vmid: int, enabled: bool = True) -> None:
    _run("pct", "set", str(vmid), "--onboot", "1" if enabled else "0")


def set_hostname(vmid: int, hostname: str) -> None:
    _run("pct", "set", str(vmid), "--hostname", hostname)


def create(
    vmid: int,
    template_file: str,
    hostname: str,
    *,
    cores: int = 5,
    memory: int = 32768,
    swap: int = 32768,
    storage: str = "local-lvm2",
    bridge: str = "vmbr1",
) -> None:
    log.info("Tạo container %s — hostname: %s", vmid, hostname)
    _run(
        "pct", "create", str(vmid), template_file,
        "-arch", "amd64",
        "-ostype", "ubuntu",
        "-hostname", hostname,
        "-cores", str(cores),
        "-memory", str(memory),
        "-swap", str(swap),
        "-storage", storage,
        "-features", "nesting=1,keyctl=1",
        "-unprivileged", "0",
        "-net0", f"name=eth0,bridge={bridge},ip=dhcp,firewall=1,type=veth",
    )


def clone(source_id: int, new_id: int, hostname: str) -> None:
    log.info("Clone container %s → %s (hostname: %s)", source_id, new_id, hostname)
    _run(
        "pct", "clone", str(source_id), str(new_id),
        "-hostname", hostname,
        "-full", "1",
    )


# ── Config file helpers ───────────────────────────────────────────────────────

def append_lxc_config(vmid: int, lines: list[str]) -> None:
    """Thêm dòng vào /etc/pve/lxc/<vmid>.conf (chạy trên Proxmox host)."""
    conf_path = f"/etc/pve/lxc/{vmid}.conf"
    content = "\n".join(lines) + "\n"
    with open(conf_path, "a") as f:
        f.write(content)
    log.debug("Đã thêm %d dòng vào %s", len(lines), conf_path)


def sanitize_lxc_config(vmid: int) -> None:
    """Xóa deprecated keys, đảm bảo cgroup2 đúng."""
    conf_path = Path(f"/etc/pve/lxc/{vmid}.conf")
    if not conf_path.exists():
        return

    lines = conf_path.read_text().splitlines()
    filtered = [
        line for line in lines
        if not line.startswith("lxc.cgroup.devices.allow:")
        and not line.startswith("lxc.apparmor.profile:")
    ]

    has_cgroup2 = any(l == "lxc.cgroup2.devices.allow: a" for l in filtered)
    if not has_cgroup2:
        filtered.append("lxc.cgroup2.devices.allow: a")

    conf_path.write_text("\n".join(filtered) + "\n")
    log.debug("Đã sanitize config container %s", vmid)


# ── exec helpers ──────────────────────────────────────────────────────────────

def exec_command(vmid: int, command: str, env: dict[str, str] | None = None) -> None:
    """Chạy một shell command string bên trong container."""
    if env:
        exports = " ".join(f"export {k}={v};" for k, v in env.items())
        command = exports + " " + command
    _run("pct", "exec", str(vmid), "--", "bash", "-c", command)


def exec_script(vmid: int, script_path: Path, env: dict[str, str] | None = None) -> None:
    """
    Copy file script vào container rồi chạy.
    Tự dọn dẹp sau khi xong.
    """
    remote_path = f"/tmp/_lxr_{script_path.name}"
    log.info("Push script %s → container %s:%s", script_path.name, vmid, remote_path)

    try:
        _run("pct", "push", str(vmid), str(script_path), remote_path)
        _run("pct", "exec", str(vmid), "--", "chmod", "+x", remote_path)

        cmd = remote_path
        if env:
            exports = " ".join(f"{k}={v}" for k, v in env.items())
            cmd = f"{exports} bash {remote_path}"
            _run("pct", "exec", str(vmid), "--", "bash", "-c", cmd)
        else:
            _run("pct", "exec", str(vmid), "--", "bash", remote_path)

    except ProxmoxError as exc:
        raise ContainerScriptError(
            f"Script {script_path.name} thất bại trong container {vmid}: {exc}"
        ) from exc
    finally:
        _run("pct", "exec", str(vmid), "--", "rm", "-f", remote_path, check=False)


# ── Disk monitor ──────────────────────────────────────────────────────────────

def get_disk_usage_pct(vmid: int) -> int | None:
    """Trả về % disk / của container, hoặc None nếu không đọc được."""
    result = _run(
        "pct", "exec", str(vmid), "--", "bash", "-c",
        "df / --output=pcent | tail -1 | tr -d ' %'",
        capture=True,
        check=False,
    )
    raw = result.stdout.strip()
    if raw.isdigit():
        return int(raw)
    return None


def wait_ready(vmid: int, delay: int = 10) -> None:
    """Chờ container khởi động xong."""
    log.info("Chờ container %s sẵn sàng (%ss)...", vmid, delay)
    time.sleep(delay)
