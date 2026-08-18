#!/usr/bin/env python3
from __future__ import annotations

import re


SCREENSHOT_PATTERN = re.compile(
    r"^(?P<page>[a-zA-Z0-9-]+)__"
    r"(?P<state>[a-zA-Z0-9-]+)__"
    r"(?P<appearance>light|dark)__"
    r"(?P<locale>en|zh-Hans)__"
    r"(?P<width>\d+)x(?P<height>\d+)__"
    r"(?P<inspector>open|closed|na)\.png$"
)


def parse_screenshot_name(name: str) -> dict[str, str] | None:
    match = SCREENSHOT_PATTERN.fullmatch(name)
    return match.groupdict() if match else None
