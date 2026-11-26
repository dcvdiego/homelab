#!/usr/bin/env python3
"""Fail on compose settings that only break when Komodo deploys the stack.

Komodo runs `docker compose` inside the periphery container, which sees the stack's git checkout and
/etc/komodo, not the rest of the host. Anything compose itself reads is resolved in there; bind
mounts (volumes, file secrets) are resolved by the Docker daemon on the host and are fine.
  env_file  outside the checkout or /etc/komodo: compose can't read it. With `required: false` it is
            dropped without an error (pve-exporter, PR #75); without it the deploy fails.
Each stack is rendered with `docker compose config --no-env-resolution --no-interpolate`, which keeps
the declared env_file paths as absolute paths and needs no secrets.

Usage: check-compose-komodo.py [docker-compose/<stack>/docker-compose.yml ...]   (default: all)
Undo: delete this file and its step in .github/workflows/ops-check.yml.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PERIPHERY_VISIBLE = (ROOT, pathlib.Path("/etc/komodo"))


def visible(p: pathlib.Path) -> bool:
    return any(p == base or base in p.parents for base in PERIPHERY_VISIBLE)


def check(f: pathlib.Path) -> list[str]:
    r = subprocess.run(
        ["docker", "compose", "-f", str(f), "config", "--no-env-resolution", "--no-interpolate",
         "--format", "json"],
        capture_output=True, text=True, cwd=f.parent)
    if r.returncode:
        return [f"{f.relative_to(ROOT)}: docker compose config failed: {r.stderr.strip()}"]
    errors = []
    for name, svc in (json.loads(r.stdout).get("services") or {}).items():
        for e in svc.get("env_file") or []:
            path = pathlib.Path(e["path"] if isinstance(e, dict) else e)
            if not path.is_absolute():
                path = (f.parent / path).resolve()
            if not visible(path):
                quiet = isinstance(e, dict) and e.get("required") is False
                errors.append(
                    f"{f.relative_to(ROOT)}: service {name}: env_file {path} is outside the stack's checkout "
                    f"and /etc/komodo, so Komodo's periphery can't read it"
                    + (" and compose drops it silently (required: false)" if quiet else " and the deploy fails")
                    + ". Put non-secret values in `environment:`, and mount secrets as files "
                    "(e.g. <VAR>_FILE or `secrets: file:`), which the host's Docker daemon resolves.")
    return errors


def main() -> int:
    files = [pathlib.Path(a).resolve() for a in sys.argv[1:]] or sorted(ROOT.glob("docker-compose/*/docker-compose.yml"))
    errors = [e for f in files if f.exists() for e in check(f)]
    for e in errors:
        print(f"::error::{e}")
    print(f"{len(files)} compose file(s) checked, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
