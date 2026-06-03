from __future__ import annotations

import logging
import sys
from pathlib import Path

import click
from rich.console import Console
from rich.logging import RichHandler

from .config import Config
from .exceptions import ConfigError, LxcRunnerError

console = Console()


def _setup_logging(log_dir: Path, verbose: bool) -> None:
    log_dir.mkdir(parents=True, exist_ok=True)
    from datetime import datetime
    log_file = log_dir / f"lxc-monitor-{datetime.now().strftime('%Y%m%d')}.log"

    handlers: list[logging.Handler] = [
        RichHandler(console=console, rich_tracebacks=True, show_path=False),
        logging.FileHandler(log_file, encoding="utf-8"),
    ]
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=handlers,
        force=True,
    )


def _load_config(env_file: str | None) -> Config:
    try:
        return Config.from_env(Path(env_file) if env_file else None)
    except ConfigError as exc:
        console.print(f"[red]❌ Config lỗi:[/] {exc}")
        sys.exit(1)


# ── Root group ─────────────────────────────────────────────────────────────────

@click.group()
@click.option("--env-file", "-e", default=None, help="Đường dẫn file .env")
@click.option("--verbose", "-v", is_flag=True, help="Debug logging")
@click.pass_context
def cli(ctx: click.Context, env_file: str | None, verbose: bool) -> None:
    """LXC GitHub Actions Runner — Proxmox orchestrator."""
    ctx.ensure_object(dict)
    ctx.obj["env_file"] = env_file
    ctx.obj["verbose"] = verbose


# ── monitor ────────────────────────────────────────────────────────────────────

@cli.command()
@click.option("--dry-run", is_flag=True, help="Mô phỏng, không thực hiện thay đổi thật")
@click.option("--check-only", is_flag=True, help="Chỉ kiểm tra và in trạng thái, không action")
@click.pass_context
def monitor(ctx: click.Context, dry_run: bool, check_only: bool) -> None:
    """Kiểm tra disk và tự động rebuild khi cần (replaces lxc-disk-monitor.sh)."""
    cfg = _load_config(ctx.obj["env_file"])
    _setup_logging(cfg.log_dir, ctx.obj["verbose"])

    from .monitor import DiskMonitor
    m = DiskMonitor(cfg, dry_run=dry_run, check_only=check_only)

    log = logging.getLogger(__name__)
    log.info(
        "Bắt đầu | Threshold: %d%% | Org: %s | Max LXC: %d | Window: %dh–%dh%s%s",
        cfg.disk_threshold, cfg.orgname, cfg.lxc_count,
        cfg.maintenance_start, cfg.maintenance_end,
        " [DRY-RUN]" if dry_run else "",
        " [CHECK-ONLY]" if check_only else "",
    )

    result = m.run()

    log.info(
        "Kết quả | Monitor: %d | Rebuilt: %d | Skipped: %d | Failed: %d",
        result["monitored"], result["rebuilt"], result["skipped"], result["failed"],
    )
    if result["failed"] > 0:
        sys.exit(1)


# ── ui ─────────────────────────────────────────────────────────────────────────

@cli.command()
@click.option("-i", "--interval", default=30, show_default=True, help="Refresh interval (giây), 0 = 1 lần")
@click.pass_context
def ui(ctx: click.Context, interval: int) -> None:
    """Live terminal dashboard (replaces lxc-monitor-ui.sh)."""
    cfg = _load_config(ctx.obj["env_file"])
    from .ui import run_dashboard
    run_dashboard(cfg, interval=interval)


# ── test ───────────────────────────────────────────────────────────────────────

@cli.command("test")
@click.argument("vmid", type=int, required=False)
@click.option("--dry-run", is_flag=True)
@click.pass_context
def test_runner(ctx: click.Context, vmid: int | None, dry_run: bool) -> None:
    """Full cycle test: deregister → destroy → clone → verify (replaces lxc-test-runner.sh)."""
    cfg = _load_config(ctx.obj["env_file"])
    _setup_logging(cfg.log_dir, ctx.obj["verbose"])

    from . import proxmox
    from .lifecycle import FullCycleTester

    if vmid is None:
        # Liệt kê runners và hỏi
        _list_runners(cfg)
        vmid = click.prompt("Nhập Container ID cần test (0 để hủy)", type=int)
        if vmid == 0:
            console.print("Đã hủy.")
            return

    hostname = proxmox.get_hostname(vmid)
    console.print(f"\n[yellow bold]⚠️  Thao tác này sẽ XÓA container {vmid} ({hostname}) và tạo mới![/]")
    if dry_run:
        console.print("[green](DRY-RUN — không xóa thật)[/]")

    if not click.confirm("Xác nhận tiến hành?", default=False):
        console.print("Đã hủy.")
        return

    tester = FullCycleTester(cfg, dry_run=dry_run)
    result = tester.run(vmid)

    if result.success:
        console.print(
            f"\n[green bold]🎉 Hoàn tất![/] "
            f"Cũ: {result.old_vmid} → Mới: {result.new_vmid} | {result.elapsed_seconds}s"
        )
    else:
        console.print(f"\n[red bold]❌ Thất bại:[/] {result.error}")
        sys.exit(1)


# ── create (master) ────────────────────────────────────────────────────────────

@cli.command()
@click.pass_context
def create(ctx: click.Context) -> None:
    """Tạo LXC container template với full stack (replaces master.sh)."""
    cfg = _load_config(ctx.obj["env_file"])
    _setup_logging(cfg.log_dir, ctx.obj["verbose"])

    from .master import create_template
    try:
        vmid = create_template(cfg)
        console.print(f"[green]✅ Template container {vmid} tạo xong![/]")
    except LxcRunnerError as exc:
        console.print(f"[red]❌ Thất bại:[/] {exc}")
        sys.exit(1)


# ── clone ──────────────────────────────────────────────────────────────────────

@cli.command()
@click.pass_context
def clone(ctx: click.Context) -> None:
    """Clone từ template và đăng ký runner mới (replaces clone.sh)."""
    cfg = _load_config(ctx.obj["env_file"])
    _setup_logging(cfg.log_dir, ctx.obj["verbose"])

    from .clone import clone_and_register
    try:
        new_id = clone_and_register(cfg)
        console.print(f"[green]✅ Runner container {new_id} đã sẵn sàng![/]")
    except LxcRunnerError as exc:
        console.print(f"[red]❌ Thất bại:[/] {exc}")
        sys.exit(1)


# ── Helpers ────────────────────────────────────────────────────────────────────

def _list_runners(cfg: Config) -> None:
    from . import proxmox
    from rich.table import Table

    table = Table(title="GitHub Runner Containers", show_header=True)
    table.add_column("VMID", width=6)
    table.add_column("Hostname")
    table.add_column("Status", width=10)

    try:
        containers = proxmox.list_containers()
        for c in containers:
            vmid = int(c["vmid"])
            hn = proxmox.get_hostname(vmid)
            if cfg.lxc_name_pattern in hn:
                status = "running" if proxmox.is_running(vmid) else "stopped"
                table.add_row(str(vmid), hn, status)
    except Exception as exc:
        console.print(f"[yellow]Không lấy được danh sách: {exc}[/]")

    console.print(table)
