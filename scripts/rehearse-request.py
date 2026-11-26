#!/usr/bin/env python3
"""Rehearse ops requests on a CI runner with fake ssh, curl and sleep, before they run for real.

`ssh`, `scp` and `rsync` never connect, `curl` returns an empty body, `sleep` returns at once, and
dummy values stand in for the apply job's secrets. This is not a sandbox: the request is PR code and
runs on the GitHub-hosted runner like any other PR check (other tools, e.g. python3 or wget, are
real), but the runner has no secrets and no route to the LAN, and the owner still reviews requests. What it catches:
  - shell errors in the request (syntax, unbound variables, missing commands), and shellcheck errors
  - quoting errors in every nested layer of a remote command: the remote shell, then each
    `sh -c '...'` / `bash -c '...'` inside it (e.g. `pct exec 101 -- sh -c '...'`), checked with -n
    and never executed
  - long-running work in a single SSH session (tar, rsync, du, dumps, pulls) not run detached, in
    ssh arguments or a heredoc fed to `sh -s`/`bash -s`, and scp/rsync from the runner:
    Warpgate cuts sessions after ~5 minutes (PR #74); detach with setsid and poll, as in #75.
    This is an error. A request whose long-looking command is known to be quick names it in a line
    `# rehearse: allow-long <command> <why>` (e.g. `# rehearse: allow-long du small dir`), which makes
    findings for every use of that command in the request warnings, and no other command's.
With fake data, a request usually stops at its first real check (`CHECK FAILED`, an empty Komodo
reply). That is expected and not an error; the report says how many remote commands were reached.

Usage: rehearse-request.py ops/requests/<name>.sh ...
Note: the remote command is the ssh arguments joined with spaces and re-parsed by the remote shell,
exactly as ssh does it, so a payload split across ssh arguments is checked as the remote sees it.
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
# a command word: at the start or after a separator, so "x.tar.gz" or "--rsync" don't match
LONG = re.compile(r"(?:^|[\s;&|(`'\"]|\$\()(tar|rsync|du|pg_dump|pg_dumpall|mysqldump|mariadb-dump|vzdump|zstd|gzip|xz|docker pull|docker image pull|cp -a|cp -r)(?=\s)")
DETACHED = re.compile(r"\b(setsid|nohup|systemd-run)\b")
SHELL_ERR = re.compile(r"(syntax error|unbound variable|command not found|unexpected EOF|bad substitution)")


def dummy_env() -> dict[str, str]:
    """A dummy for every env value the apply job sets (.github/workflows/apply.yml), so a request that
    uses one the job doesn't set fails here as it would there (unbound variable under bash -u)."""
    names = re.findall(r"(?m)^\s+([A-Z][A-Z0-9_]+): \$\{\{", (ROOT / ".github/workflows/apply.yml").read_text())
    env = {n: "x" for n in names}
    env.update(KOMODO_URL="http://komodo.invalid", GITHUB_RUN_ID="0", GITHUB_SHA="0" * 40)
    return env


def nested_check(cmd: str, where: str, depth: int = 0) -> list[str]:
    """Syntax-check a shell string and every sh/bash -c string inside it, without running them."""
    out = []
    r = subprocess.run(["bash", "-n", "-c", cmd], capture_output=True, text=True)
    if r.returncode:
        return [f"{where}: shell syntax error at depth {depth}: {r.stderr.strip()}\n    command: {cmd[:300]}"]
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)  # ; & | ( ) are separate tokens
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError as e:
        return [f"{where}: unbalanced quotes at depth {depth}: {e}\n    command: {cmd[:300]}"]
    for i, t in enumerate(toks):
        if t not in ("sh", "bash", "/bin/sh", "/bin/bash"):
            continue
        j = i + 1  # skip options (-e, -euo pipefail, -o errexit, +x) up to the one with c
        while j < len(toks) and re.fullmatch(r"[-+][a-zA-Z]+", toks[j]):
            has_c = "c" in toks[j]
            j += 2 if toks[j].endswith("o") and not has_c else 1
            if has_c:
                if j < len(toks):
                    out += nested_check(toks[j], where, depth + 1)
                break
    return out


def ssh_stub(args: list[str]) -> int:
    """Called as `ssh`: record the remote command, check it, print nothing, succeed."""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-F", "-i", "-o", "-p", "-l", "-J", "-b", "-c", "-E", "-L", "-R", "-D", "-W") else 1
    remote = " ".join(args[i + 1:])
    stdin = "" if sys.stdin.isatty() else sys.stdin.read()
    # `ssh pve 'bash -s' <<EOF` / `pct exec 101 -- sh -s`: the payload is the script, check it as one
    shell_reads_stdin = re.search(
        r"(?:^|\s)(?:ba)?sh(?:\s+(?:[-+]\w+|pipefail|errexit|nounset|xtrace))*\s+-\w*s\w*(?:\s|$)"  # sh -s, bash -euo pipefail -s --
        r"|(?:^|\s)(?:ba)?sh(?:\s+[-+]\w+)*\s*$", remote)                                           # bare sh / bash -e
    if stdin and shell_reads_stdin:
        remote = remote + "\n" + stdin
    log = pathlib.Path(os.environ["REHEARSE_LOG"])
    n = sum(1 for line in log.open() if line.startswith("CMD\t")) + 1 if log.exists() else 1
    where = f"ssh {args[i] if i < len(args) else '?'} #{n}"
    with log.open("a") as fh:
        fh.write(f"CMD\t{where}\n")
        parts = remote.split("\n", 1) if stdin and "\n" in remote else [remote]
        for p in [e for part in parts for e in nested_check(part, where)]:  # the ssh command, then the heredoc
            fh.write(f"ERR\t{p}\n")
        for m in LONG.finditer(remote):
            # heuristic: detached if setsid/nohup/systemd-run comes earlier on the same line
            line_start = remote.rfind("\n", 0, m.start()) + 1
            if DETACHED.search(remote[line_start:m.start()]):
                continue
            fh.write(f"WARN\t{m.group(1)}\t{where}: long-running command in one SSH session (Warpgate cuts sessions after"
                     f" ~5 min); detach with setsid and poll if it can take minutes:\n    {remote[line_start:line_start + 300].splitlines()[0]}\n")
    return 0


def rehearse(req: pathlib.Path) -> tuple[list[str], list[str]]:
    errors, warns = [], []
    allowed = set(re.findall(r"(?m)^# rehearse: allow-long (docker image pull|docker pull|cp -a|cp -r|\S+)", req.read_text()))
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
        for t in ("scp", "rsync"):  # these open their own SSH session through Warpgate
            (bin_ / t).write_text(f'#!/bin/sh\nprintf "WARN\\t{t}\\t{t} on the runner: a copy through Warpgate is cut after ~5 min; '
                                  f'fine for small files (allow-long {t})\\n    {t} %s\\n" "$*" >> "$REHEARSE_LOG"\n')
        for f in bin_.iterdir():
            f.chmod(0o755)
        cfg = pathlib.Path(d, "ssh_config")
        cfg.write_text("Host pve\n  HostName pve.invalid\n")
        log = pathlib.Path(d, "log")
        env = {**os.environ, **dummy_env(), "PATH": f"{bin_}:{os.environ['PATH']}", "OPS_SSH_CONFIG": str(cfg),
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
                cmd, msg = block[5:].split("\t", 1)
                (warns if cmd in allowed else errors).append(msg.rstrip())
        print(f"{req.relative_to(ROOT)}: reached {n_cmd} remote command(s), exit {rc} (non-zero is expected with fake data)")
        if out.strip():
            print("    last output: " + out.strip().splitlines()[-1][:200])
    return errors, warns


def annotate(kind: str, file: str, msg: str) -> None:
    """A GitHub workflow command is one line: escape % and newlines (they render as line breaks)."""
    msg = msg.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{kind} file={file}::{msg}")


def main() -> int:
    if sys.argv[1:2] == ["--ssh-stub"]:
        return ssh_stub(sys.argv[2:])
    failed = 0
    for a in sys.argv[1:]:
        req = pathlib.Path(a).resolve()
        errors, warns = rehearse(req)
        for w in warns:
            annotate("warning", str(req.relative_to(ROOT)), w)
        for e in errors:
            annotate("error", str(req.relative_to(ROOT)), e)
        failed += bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
