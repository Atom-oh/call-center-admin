"""PII regex-based detection and masking.

순서가 중요: card → rrn → phone → account (긴/특수 패턴 먼저).
"""
from __future__ import annotations

import re
from dataclasses import dataclass

MASK_PHONE = "[MASKED_PHONE]"
MASK_RRN = "[MASKED_RRN]"
MASK_ACCOUNT = "[MASKED_ACCOUNT]"
MASK_CARD = "[MASKED_CARD]"

# `\b` 는 한글+숫자 경계에서 안 잡히므로 (?<!\d)/(?!\d) 로 명시.
_CARD = re.compile(r"(?<!\d)(?:\d[ -]?){13,19}(?<!\D)")
_RRN = re.compile(r"(?<!\d)\d{6}-?\d{7}(?!\d)")
_PHONE = re.compile(r"(?<!\d)01[016789][ -]?\d{3,4}[ -]?\d{4}(?!\d)")
_ACCOUNT = re.compile(r"(?<!\d)\d{2,4}-\d{2,6}-\d{2,8}(?!\d)|(?<!\d)\d{10,14}(?!\d)")


def _luhn_valid(digits: str) -> bool:
    s = [int(c) for c in digits if c.isdigit()]
    if len(s) < 13:
        return False
    total = 0
    for i, d in enumerate(reversed(s)):
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


@dataclass
class MaskStats:
    phone: int = 0
    rrn: int = 0
    account: int = 0
    card: int = 0

    def total(self) -> int:
        return self.phone + self.rrn + self.account + self.card

    def as_dict(self) -> dict[str, int]:
        return {"phone": self.phone, "rrn": self.rrn, "account": self.account, "card": self.card}


def mask(text: str) -> tuple[str, MaskStats]:
    """Mask PII in text. Returns (masked_text, stats)."""
    stats = MaskStats()

    def _card_repl(m: re.Match[str]) -> str:
        if _luhn_valid(m.group()):
            stats.card += 1
            return MASK_CARD
        return m.group()

    text = _CARD.sub(_card_repl, text)

    def _rrn_repl(_m: re.Match[str]) -> str:
        stats.rrn += 1
        return MASK_RRN

    text = _RRN.sub(_rrn_repl, text)

    def _phone_repl(_m: re.Match[str]) -> str:
        stats.phone += 1
        return MASK_PHONE

    text = _PHONE.sub(_phone_repl, text)

    def _account_repl(_m: re.Match[str]) -> str:
        stats.account += 1
        return MASK_ACCOUNT

    text = _ACCOUNT.sub(_account_repl, text)

    return text, stats
