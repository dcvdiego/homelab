#!/usr/bin/env python3
"""Rehearse ops requests on a CI runner with fake ssh, curl and sleep, before they run for real.

Nothing reaches the homelab: `ssh` never connects, `curl` returns an empty body, `sleep` returns
at once, and dummy values stand in for the apply job's secrets. What it catches:
  - shell errors in the request (syntax, unbound variables, missing commands), and shellcheck errors
  - quoting errors in every nested layer of a remote command: the remote shell, then each
    `sh -c '...'` / `bash -c '...'` inside it (e.g. `pct exec 101 -- sh -c '...'`), checked with -n
    and never executed
  - long-running work in a single SSH session (tar, rsync, du, dumps, pulls) not run detached:
    Warpgate cuts sessions after ~5 minutes (PR #74); detach with setsid and poll, as in #75.
    This is an error; a request whose long-looking commands are known to be quick (a small tar,
    du on a small dir) says so with a line `# rehearse: allow-long <why>`, which makes it a warning.
With fake data, a request usually stops at its first real check (`CHECK FAILED`, an empty Komodo
reply). That is expected and not an error; the report says how many remote commands were reached.

Usage: rehearse-request.py ops/requests/<name>.sh ...
Undo: delete this file and its step in .github/workflows/ops-check.yml.
"""
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LONG = re.compile(r"\b(tar|rsync|du|pg_dump|pg_dumpall|mysqldump|mariadb-dump|vzdump|zstd|gzip|xz|docker pull|docker image pull|cp -a|cp -r)\b")
DETACHED = re.compile(r"\b(setsid|nohup|systemd-run)\b")
SHELL_ERR = re.compile(r"(syntax error|unbound variable|command not found|unexpected EOF|bad substitution)")
DUMMY_ENV = {
    "KOMODO_URL": "http://komodo.invalid", "KOMODO_API_KEY": "x", "KOMODO_API_SECRET": "x",
    "CF_TOKEN": "x", "CF_ACCOUNT": "x", "CF_ZONE": "x", "CF_TUNNEL": "x",
    "TECHNITIUM_TOWER_TOKEN": "x", "TECHNITIUM_PROD_TOKEN": "x",
    "GITHUB_RUN_ID": "0", "GITHUB_SHA": "0" * 40,
}


def nested_check(cmd: str, where: str, depth: int = 0) -> list[str]:
    """Syntax-check a shell string and every sh/bash -c string inside it, without running them."""
    out = []
    r = subprocess.run(["bash", "-n", "-c", cmd], capture_output=True, text=True)
    if r.returncode:
        return [f"{where}: shell syntax error at depth {depth}: {r.stderr.strip()}\n    command: {cmd[:300]}"]
    try:
        toks = shlex.split(cmd, comments=True)
    except ValueError as e:
        return [f"{where}: unbalanced quotes at depth {depth}: {e}\n    command: {cmd[:300]}"]
    for i, t in enumerate(toks[:-2]):
        if t in ("sh", "bash", "/bin/sh", "/bin/bash") and toks[i + 1] in ("-c", "-ec", "-euc", "-eu"):
            out += nested_check(toks[i + 2], where, depth + 1)
    return out


def ssh_stub(args: list[str]) -> int:
    """Called as `ssh`: record the remote command, check it, print nothing, succeed."""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-F", "-i", "-o", "-p", "-l", "-J") else 1
    remote = " ".join(args[i + 1:])
    if not sys.stdin.isatty():
        sys.stdin.read()
    log = pathlib.Path(os.environ["REHEARSE_LOG"])
    where = f"ssh {args[i] if i < len(args) else '?'} #{sum(1 for _ in log.open()) + 1 if log.exists() else 1}"
    with log.open("a") as fh:
        fh.write(f"CMD\t{where}\n")
        for p in nested_check(remote, where):
            fh.write(f"ERR\t{p}\n")
        if LONG.search(remote) and not DETACHED.search(remote):
            fh.write(f"WARN\t{where}: long-running command in one SSH session (Warpgate cuts sessions after"
                     f" ~5 min); detach with setsid and poll if it can take minutes:\n    {remote[:300]}\n")
    return 0


def rehearse(req: pathlib.Path) -> tuple[list[str], list[str]]:
    errors, warns = [], []
    allow_long = re.search(r"(?m)^# rehearse: allow-long\b", req.read_text()) is not None
    sc = shutil.which("shellcheck")
    if sc:
        r = subprocess.run([sc, "-S", "error", "-s", "bash", str(req)], capture_output=True, text=True)
        if r.returncode:
            errors.append(f"shellcheck:\n{r.stdout.strip()}")
    with tempfile.TemporaryDirectory() as d:
        bin_ = pathlib.Path(d, "bin")
        bin_.mkdir()
        me = pathlib.Path(__file__).resolve()
        (bin_ / "ssh").write_text(f'#!/bin/sh\nexec python3 -I "{me}" --ssh-stub "$@"\n')
        (bin_ / "curl").write_text("#!/bin/sh\ncat >/dev/null 2>&1 </dev/null; exit 0\n")
        (bin_ / "sleep").write_text("#!/bin/sh\nexit 0\n")
        for f in bin_.iterdir():
            f.chmod(0o755)
        cfg = pathlib.Path(d, "ssh_config")
        cfg.write_text("Host pve\n  HostName pve.invalid\n")
        log = pathlib.Path(d, "log")
        env = {**os.environ, **DUMMY_ENV, "PATH": f"{bin_}:{os.environ['PATH']}", "OPS_SSH_CONFIG": str(cfg),
               "REHEARSE_LOG": str(log), "GITHUB_WORKSPACE": str(ROOT)}
        try:
            r = subprocess.run(["bash", "-euo", "pipefail", str(req)], cwd=ROOT, env=env,
                               capture_output=True, text=True, timeout=int(os.environ.get("REHEARSE_TIMEOUT", "120")), stdin=subprocess.DEVNULL)
            out, rc = r.stdout + r.stderr, r.returncode
        except subprocess.TimeoutExpired as e:
            txt = lambda v: v.decode(errors="replace") if isinstance(v, bytes) else (v or "")  # bytes or str by Python version
            out, rc = txt(e.stdout) + txt(e.stderr), "timeout"
            errors.append(f"did not finish within {os.environ.get('REHEARSE_TIMEOUT', '120')} s with fake ssh/curl/sleep (a loop that never ends?)")
        for line in out.splitlines():
            if SHELL_ERR.search(line):
                errors.append(f"shell error: {line.strip()}")
        lines = log.read_text().splitlines(keepends=True) if log.exists() else []
        entries = "".join(lines).split("\n")
        n_cmd = sum(1 for e in entries if e.startswith("CMD\t"))
        text = "".join(lines)
        for block in re.split(r"(?m)^(?=CMD\t|ERR\t|WARN\t)", text):
            if block.startswith("ERR\t"):
                errors.append(block[4:].rstrip())
            elif block.startswith("WARN\t"):
                (warns if allow_long else errors).append(block[5:].rstrip())
        print(f"{req.relative_to(ROOT)}: reached {n_cmd} remote command(s), exit {rc} (non-zero is expected with fake data)")
        if out.strip():
            print("    last output: " + out.strip().splitlines()[-1][:200])
    return errors, warns


def main() -> int:
    if sys.argv[1:2] == ["--ssh-stub"]:
        return ssh_stub(sys.argv[2:])
    failed = 0
    for a in sys.argv[1:]:
        req = pathlib.Path(a).resolve()
        errors, warns = rehearse(req)
        for w in warns:
            print(f"::warning file={req.relative_to(ROOT)}::{w}")
        for e in errors:
            print(f"::error file={req.relative_to(ROOT)}::{e}")
        failed += bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
