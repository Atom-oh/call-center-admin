"""PII 정규식 마스킹 단위 테스트."""
from lib.pii_regex import MASK_PHONE, MASK_ACCOUNT, MASK_RRN, MASK_CARD, mask


def test_mask_phone_with_dashes() -> None:
    text = "전화는 010-1234-5678로 주세요"
    out, stats = mask(text)
    assert MASK_PHONE in out
    assert "010-1234-5678" not in out
    assert stats.phone == 1


def test_mask_phone_without_dashes() -> None:
    text = "01012345678 입니다"
    out, _ = mask(text)
    assert MASK_PHONE in out
    assert "01012345678" not in out


def test_mask_rrn_with_dash() -> None:
    text = "주민번호 900101-1234567"
    out, stats = mask(text)
    assert MASK_RRN in out
    assert "900101" not in out
    assert stats.rrn == 1


def test_mask_account_long_digits() -> None:
    text = "계좌 110-1234-567890 입니다"
    out, stats = mask(text)
    assert MASK_ACCOUNT in out or MASK_PHONE not in out
    assert stats.account >= 1


def test_mask_card_with_luhn_valid() -> None:
    # 4532015112830366 — Luhn valid VISA test number
    text = "카드 4532-0151-1283-0366"
    out, stats = mask(text)
    assert MASK_CARD in out
    assert "4532-0151" not in out
    assert stats.card == 1


def test_does_not_mask_random_digits() -> None:
    text = "건수는 12345 입니다"
    out, stats = mask(text)
    assert "12345" in out
    assert stats.total() == 0


def test_multiple_pii_in_one_text() -> None:
    text = "홍길동(010-1111-2222)의 계좌 110123456789로 송금 90"
    out, stats = mask(text)
    assert stats.phone == 1
    assert stats.account == 1
    assert "010-1111-2222" not in out
    assert "110123456789" not in out


def test_card_not_over_eaten_when_preceded_by_short_digit() -> None:
    """회귀 방지: 카드 앞에 짧은 숫자가 있어도 정상 마스킹돼야 한다.

    이전 정규식 `(?:\\d[ -]?){13,19}`은 `0 4532-0151-1283-0366`을 한 번에 잡아
    Luhn 실패 → 마스킹 안 됨. 수정된 정규식은 digit count로 제한해 정확히 16자리만 매칭.
    """
    text = "참고 0 4532-0151-1283-0366 사용 가능"
    out, stats = mask(text)
    assert MASK_CARD in out
    assert "4532-0151-1283-0366" not in out
    assert stats.card == 1
