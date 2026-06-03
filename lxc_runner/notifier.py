from __future__ import annotations

import logging

import requests

from .config import Config

log = logging.getLogger(__name__)


class Notifier:
    """Gửi thông báo qua Telegram và/hoặc Slack."""

    def __init__(self, config: Config) -> None:
        self._tg_token = config.telegram_bot_token
        self._tg_chat = config.telegram_chat_id
        self._slack_url = config.slack_webhook_url

    def send(self, message: str) -> None:
        """Gửi message đến tất cả kênh được cấu hình."""
        if self._tg_token and self._tg_chat:
            self._telegram(message)
        if self._slack_url:
            self._slack(message)

    def _telegram(self, message: str) -> None:
        try:
            requests.post(
                f"https://api.telegram.org/bot{self._tg_token}/sendMessage",
                json={"chat_id": self._tg_chat, "text": message, "parse_mode": "Markdown"},
                timeout=10,
            )
        except Exception:
            log.debug("Gửi Telegram thất bại", exc_info=True)

    def _slack(self, message: str) -> None:
        try:
            requests.post(
                self._slack_url,
                json={"text": message},
                timeout=10,
            )
        except Exception:
            log.debug("Gửi Slack thất bại", exc_info=True)
