from __future__ import annotations

import subprocess
import time
from datetime import datetime
from pathlib import Path

from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.progress import BarColumn, Progress, TextColumn
from rich.table import Table
from rich.text import Text

from .config import Config
from . import proxmox

console = Console()


def _disk_bar(pct: int, threshold: int) -> Text:
    bar_width = 20
    filled = pct * bar_width // 100

    if pct >= threshold:
        color = "red"
    elif pct >= threshold - 15:
        color = "yellow"
    else:
        color = "green"

    bar = Text()
    bar.append("█" * filled, style=color)
    bar.append("░" * (bar_width - filled), style="dim")
    return bar


def _pct_style(pct: int, threshold: int) -> str:
    if pct >= threshold:
        return "bold red"
    if pct >= threshold - 15:
        return "bold yellow"
    return "green"


def _next_timer() -> str:
    result = subprocess.run(
        ["systemctl", "list-timers", "lxc-disk-monitor.timer", "--no-pager"],
        capture_output=True,
        text=True,
        check=False,
    )
    for line in result.stdout.splitlines():
        if "lxc-disk-monitor" in line:
            parts = line.split()
            return " ".join(parts[:2]) if len(parts) >= 2 else "N/A"
    return "N/A"


def _last_run(log_dir: Path) -> str:
    today_log = log_dir / f"lxc-monitor-{datetime.now().strftime('%Y%m%d')}.log"
    if not today_log.exists():
        return "Chưa chạy hôm nay"
    lines = today_log.read_text(errors="replace").splitlines()
    for line in reversed(lines[-20:]):
        if "Bắt đầu" in line or "Kết quả" in line:
            parts = line.split("]")
            return parts[0].lstrip("[") if parts else "N/A"
    return "Hôm nay (xem log)"


def _build_table(config: Config) -> Table:
    table = Table(show_header=True, header_style="bold white on black", expand=True)
    table.add_column("ID", width=6)
    table.add_column("Hostname", min_width=30)
    table.add_column("Status", width=10)
    table.add_column("Disk%", width=7)
    table.add_column("Free", width=7)
    table.add_column("Total", width=7)
    table.add_column("Bar", min_width=22)
    table.add_column("Action", width=16)

    try:
        containers = proxmox.list_containers()
    except Exception:
        table.add_row("[red]Lỗi kết nối Proxmox[/]", *[""] * 7)
        return table

    pattern = config.lxc_name_pattern
    vmids = [
        int(c["vmid"])
        for c in containers
        if pattern in proxmox.get_hostname(int(c["vmid"]))
    ]

    for vmid in sorted(vmids):
        hostname = proxmox.get_hostname(vmid)
        running = proxmox.is_running(vmid)

        if running:
            status_text = Text("● running", style="green")
            usage = proxmox.get_disk_usage_pct(vmid)
        else:
            status_text = Text("○ stopped", style="red")
            usage = None

        if usage is not None:
            pct_text = Text(f"{usage}%", style=_pct_style(usage, config.disk_threshold))
            bar = _disk_bar(usage, config.disk_threshold)
            action = (
                Text("🔴 REBUILD", style="bold red")
                if usage >= config.disk_threshold
                else Text("✅ OK", style="green")
            )
            # Read df -h for free/total
            result = subprocess.run(
                ["pct", "exec", str(vmid), "--", "df", "-h", "/"],
                capture_output=True, text=True, check=False,
            )
            lines = result.stdout.strip().splitlines()
            if len(lines) >= 2:
                parts = lines[-1].split()
                total = parts[1] if len(parts) > 1 else "-"
                free = parts[3] if len(parts) > 3 else "-"
            else:
                total = free = "-"
        else:
            pct_text = Text("-", style="dim")
            bar = Text("─" * 20, style="dim")
            action = Text("⏸ OFFLINE", style="dim")
            total = free = "-"

        table.add_row(
            str(vmid),
            hostname[:40],
            status_text,
            pct_text,
            free,
            total,
            bar,
            action,
        )

    return table


def _build_layout(config: Config) -> Panel:
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    header = (
        f"[bold cyan]Org:[/] [white]{config.orgname}[/]   "
        f"[bold cyan]Threshold:[/] [yellow]{config.disk_threshold}%[/]   "
        f"[bold cyan]Updated:[/] [white]{now}[/]\n"
        f"[bold cyan]Last run:[/] [dim]{_last_run(config.log_dir)}[/]   "
        f"[bold cyan]Next timer:[/] [dim]{_next_timer()}[/]"
    )

    table = _build_table(config)

    from rich.columns import Columns
    from rich import box
    inner = Table.grid(expand=True)
    inner.add_row(Text(header))
    inner.add_row(table)

    return Panel(
        inner,
        title="[bold blue]LXC GitHub Runner — Disk Monitor Dashboard[/]",
        border_style="blue",
    )


def run_dashboard(config: Config, interval: int = 30) -> None:
    """Live dashboard, refresh mỗi `interval` giây. interval=0 → chạy 1 lần."""
    if interval <= 0:
        console.print(_build_layout(config))
        return

    with Live(
        _build_layout(config),
        console=console,
        refresh_per_second=1,
        screen=True,
    ) as live:
        elapsed = 0
        while True:
            time.sleep(1)
            elapsed += 1
            if elapsed >= interval:
                live.update(_build_layout(config))
                elapsed = 0
