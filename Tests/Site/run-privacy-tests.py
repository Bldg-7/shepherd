#!/usr/bin/env python3
"""Check the bilingual privacy page without a browser, app or network."""
import argparse
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PolicyParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.articles = {}
        self.current = None
        self.stack = []
        self.errors = []
        self.effective = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "article":
            lang = attrs.get("lang")
            if self.current is not None or lang in self.articles:
                self.errors.append("nested or duplicate article")
            self.current = {"tags": [], "text": [], "dates": [], "id": attrs.get("id")}
            self.articles[lang] = self.current
        if self.current is None:
            return
        self.current["tags"].append(tag)
        if tag not in {"br", "hr", "img", "input", "meta", "link"}:
            self.stack.append(tag)
        if tag == "p" and "effective" in attrs.get("class", "").split():
            self.current["dates"].append("")
            self.effective = True

    def handle_endtag(self, tag):
        if self.current is None:
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append(f"unbalanced article tag: {tag}")
        else:
            self.stack.pop()
        if tag == "p":
            self.effective = False
        if tag == "article":
            self.current = None

    def handle_data(self, data):
        if self.current is not None:
            self.current["text"].append(data)
            if self.effective:
                self.current["dates"][-1] += data


def validate(source):
    parser = PolicyParser()
    parser.feed(source)
    parser.close()
    assert not parser.errors and not parser.stack, parser.errors or parser.stack
    assert set(parser.articles) == {"en", "ko"}, "both language articles required"
    en, ko = (parser.articles[lang] for lang in ("en", "ko"))
    assert en["id"] == "en" and ko["id"] == "ko", "language anchors changed"
    assert en["tags"] == ko["tags"], "EN/KO document structure differs"
    counts = Counter(en["tags"])
    assert (counts["h2"], counts["h3"], counts["li"]) == (8, 2, 13), counts
    assert en["dates"] == ["Effective October 22, 2026"], "English effective date"
    assert ko["dates"] == ["시행일: 2026년 10월 22일"], "Korean effective date"
    contracts = {
        "en": ["QR code", "device's name, model, app version and an ID",
               "public half of its SSH key", "encrypted with a key from the code",
               "no image is kept or sent", "ten minutes at most", "port of its own",
               "~/.ssh/authorized_keys", "key fingerprint", "last 1,000 pairing events",
               "address each request came from", "takes its line out of authorized_keys"],
        "ko": ["QR 코드", "기기의 이름, 모델, 앱 버전, 앱이 만든 ID",
               "SSH 키의 공개 키", "코드의 키로 암호화", "이미지를 보관하거나 보내지 않습니다",
               "최대 10분", "별도의 포트", "~/.ssh/authorized_keys", "키 지문",
               "최근 1,000건", "각 요청이 온 주소", "그 기기의 줄이 authorized_keys에서 빠집니다"],
    }
    for lang, phrases in contracts.items():
        text = " ".join("".join(parser.articles[lang]["text"]).split())
        for phrase in phrases:
            assert phrase in text, f"{lang}: missing {phrase}"
        assert "Only the SSH connections" not in text
        assert "SSH 연결뿐입니다" not in text


class PrivacyTests(unittest.TestCase):
    def test_current_page(self):
        validate(SOURCE)

    def test_missing_language_rejected(self):
        with self.assertRaises(AssertionError):
            validate(SOURCE.replace('lang="ko"', 'lang="ja"'))

    def test_stale_date_rejected(self):
        with self.assertRaises(AssertionError):
            validate(SOURCE.replace("October 22, 2026", "October 20, 2026"))

    def test_missing_pairing_disclosure_rejected(self):
        with self.assertRaises(AssertionError):
            validate(SOURCE.replace("no image is kept or sent", "camera used"))

    def test_wrong_history_limit_rejected(self):
        with self.assertRaises(AssertionError):
            validate(SOURCE.replace("1,000", "100"))

    def test_broken_markup_rejected(self):
        with self.assertRaises(AssertionError):
            validate(SOURCE.replace("</article>", "", 1))


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--html", type=Path, default=ROOT / "site/privacy/index.html")
    args = cli.parse_args()
    SOURCE = args.html.read_text(encoding="utf-8")
    unittest.main(argv=[__file__], verbosity=2)
