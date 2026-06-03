class LxcRunnerError(Exception):
    """Base exception."""


class ProxmoxError(LxcRunnerError):
    """pct / pvesh command thất bại."""


class GitHubAPIError(LxcRunnerError):
    """GitHub API trả về lỗi hoặc dữ liệu không hợp lệ."""


class ConfigError(LxcRunnerError):
    """Config thiếu hoặc không hợp lệ."""


class ContainerScriptError(LxcRunnerError):
    """Script chạy trong container thất bại."""
