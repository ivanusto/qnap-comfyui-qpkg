#!/usr/bin/env python3
"""Regenerate docker-compose.yml by embedding Dockerfile into dockerfile_inline.

Compose performs variable substitution on the whole compose file, including
inside dockerfile_inline. An unescaped $PATH or ${TORCH_INDEX} in the embedded
Dockerfile is therefore replaced with an empty string long before Docker sees
it, and the build fails with confusing errors such as
  python -m venv: exit code 127
So every dollar sign has to be doubled on the way in. Run this after editing
Dockerfile or compose-tail.yml; do not hand edit the generated file.
"""
import sys, pathlib

here = pathlib.Path(__file__).parent
dockerfile = (here / "Dockerfile").read_text()
head = (here / "compose-head.yml").read_text()
tail = (here / "compose-tail.yml").read_text()

escaped = dockerfile.replace("$", "$$")
body = "\n".join(("        " + line).rstrip() for line in escaped.splitlines())

out = head.rstrip("\n") + "\n" + body + "\n\n" + tail.lstrip("\n")
(here / "docker-compose.yml").write_text(out)
print("wrote docker-compose.yml, %d lines" % len(out.splitlines()))
