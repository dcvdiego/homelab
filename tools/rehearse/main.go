// Command rehearse runs ops requests in a sandboxed shell before they run for real in the apply job.
//
// Each request runs in mvdan.cc/sh's bash interpreter, not in bash, so every external command goes
// through this program: ssh, scp, rsync, curl, python3, docker and anything else that could reach
// a network or change a host are faked (no output, exit 0); only plain text tools (jq, sed, grep...)
// run for real, and file writes go to a scratch directory. Dummy values stand in for the apply
// job's secrets, taken from .github/workflows/apply.yml.
//
// Every remote command (the ssh arguments joined with spaces, as ssh does, plus a heredoc when the
// remote shell reads one with `sh -s` / bare `bash`) is parsed into a syntax tree and walked:
//   - each `sh -c` / `bash -c` payload, at any depth (`pct exec 101 -- sh -c '...'`), is parsed too:
//     a quoting error in any layer is an error
//   - long-running commands (tar, rsync, du, dumps, docker pull, cp -a/-r, scp) in one SSH session
//     are errors unless run under setsid, nohup or systemd-run: Warpgate cuts sessions after ~5 min
//     (PR #74). A line `# rehearse: allow-long <command> <why>` makes that command's findings warnings.
//
// It also reports shell errors in the request itself (syntax, unbound variables, unknown commands)
// and shellcheck errors when shellcheck is installed. With fake data a request usually stops at its
// first real check; that is expected and not an error.
//
// Usage: go -C tools run ./rehearse [-root DIR] ops/requests/<name>.sh ...
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/interp"
	"mvdan.cc/sh/v3/syntax"
)

// Finding is one problem found in a request.
type Finding struct {
	Error bool   // false: warning
	Kind  string // long-running command name, "" for other findings
	Msg   string
}

// Result is the outcome of rehearsing one request.
type Result struct {
	Findings []Finding
	Remote   int    // remote commands reached
	Exit     string // how the request ended
	Faked    []string
	LastOut  string
}

// Tools that only transform text and are run for real. Everything else is faked or, when it isn't
// installed on the runner either, reported as a missing command.
// None of them can start another program (env, xargs, awk's system() and find -exec can, so they
// are faked; sed runs with --sandbox, which rejects its e/r/w commands).
var realTools = set("jq", "sed", "grep", "egrep", "head", "tail", "sort", "uniq", "cut", "tr",
	"wc", "date", "seq", "base64", "basename", "dirname", "od", "sha256sum", "md5sum", "rev", "column",
	"fold", "paste", "expr", "numfmt", "fmt", "nl", "true", "false", "cat", "printf", "echo",
	"tac", "comm", "join", "diff", "cmp", "test", "[")

var shells = set("sh", "bash", "dash", "/bin/sh", "/bin/bash", "/usr/bin/env sh")

var longCmds = set("tar", "rsync", "du", "pg_dump", "pg_dumpall", "mysqldump", "mariadb-dump", "vzdump",
	"zstd", "gzip", "xz", "scp")

var allowRe = regexp.MustCompile(`(?m)^# rehearse: allow-long (docker image pull|docker pull|cp -a|cp -r|\S+)`)

func set(xs ...string) map[string]bool {
	m := map[string]bool{}
	for _, x := range xs {
		m[x] = true
	}
	return m
}

// Rehearse runs one request file with root as the repository checkout.
func Rehearse(root, req string, timeout time.Duration) Result {
	var res Result
	src, err := os.ReadFile(req)
	if err != nil {
		res.Findings = append(res.Findings, Finding{Error: true, Msg: err.Error()})
		return res
	}
	allowed := map[string]bool{}
	for _, m := range allowRe.FindAllStringSubmatch(string(src), -1) {
		allowed[longKey(m[1])] = true
	}
	add := func(f Finding) {
		if f.Kind != "" && allowed[f.Kind] {
			f.Error = false
		}
		res.Findings = append(res.Findings, f)
	}

	if sc, err := exec.LookPath("shellcheck"); err == nil {
		out, err := exec.Command(sc, "-S", "error", "-s", "bash", req).CombinedOutput()
		if err != nil {
			add(Finding{Error: true, Msg: "shellcheck:\n" + strings.TrimSpace(string(out))})
		}
	}

	file, err := syntax.NewParser(syntax.Variant(syntax.LangBash)).Parse(bytes.NewReader(src), req)
	if err != nil {
		add(Finding{Error: true, Msg: "shell syntax error: " + err.Error()})
		return res
	}

	scratch, err := os.MkdirTemp("", "rehearse-")
	if err != nil {
		add(Finding{Error: true, Msg: err.Error()})
		return res
	}
	defer os.RemoveAll(scratch)
	cfg := filepath.Join(scratch, "ssh_config")
	_ = os.WriteFile(cfg, []byte("Host pve\n  HostName pve.invalid\n"), 0o600)

	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + scratch, "LANG=C.UTF-8", "OPS_SSH_CONFIG=" + cfg,
		"GITHUB_WORKSPACE=" + root, "GITHUB_RUN_ID=0", "GITHUB_SHA=" + strings.Repeat("0", 40),
		"RUNNER_TEMP=" + scratch}
	for _, n := range applyEnv(root) {
		v := "x"
		if n == "KOMODO_URL" {
			v = "http://komodo.invalid"
		}
		env = append(env, n+"="+v)
	}

	faked := map[string]bool{}
	var stdout, stderr bytes.Buffer
	// mapped returns the scratch copy of a file the request wrote, or "".
	mapped := func(dir, p string) string {
		if p == "" || strings.HasPrefix(p, "-") {
			return ""
		}
		if !filepath.IsAbs(p) {
			p = filepath.Join(dir, p)
		}
		m := filepath.Join(scratch, "fs", p)
		if _, err := os.Stat(m); err == nil {
			return m
		}
		return ""
	}
	exe := func(ctx context.Context, args []string) error {
		hc := interp.HandlerCtx(ctx)
		name := args[0]
		switch base := filepath.Base(name); {
		case base == "ssh":
			res.Remote++
			var stdin string
			if hc.Stdin != nil {
				b, _ := io.ReadAll(hc.Stdin)
				stdin = string(b)
			}
			host, remote := sshRemote(args[1:])
			where := fmt.Sprintf("ssh %s #%d (request line %d)", host, res.Remote, hc.Pos.Line())
			for _, f := range CheckRemote(remote, stdin, where) {
				add(f)
			}
			return nil
		case base == "scp" || base == "rsync":
			add(Finding{Error: true, Kind: base, Msg: fmt.Sprintf("%s on the runner (request line %d): a copy through"+
				" Warpgate is cut after ~5 min; fine for small files (allow-long %s)\n    %s", base, hc.Pos.Line(), base,
				strings.Join(args, " "))})
			return nil
		case base == "sleep":
			return nil
		case realTools[base]:
			for i := 1; i < len(args); i++ { // files the request wrote are read from the scratch copy
				if m := mapped(hc.Dir, args[i]); m != "" {
					args[i] = m
				}
			}
			if base == "sed" {
				args = append([]string{args[0], "--sandbox"}, args[1:]...)
			}
			return interp.DefaultExecHandler(2*time.Second)(ctx, args)
		default:
			if _, err := exec.LookPath(name); err != nil {
				fmt.Fprintf(hc.Stderr, "%s: command not found\n", name)
				return interp.NewExitStatus(127)
			}
			faked[base] = true
			return nil
		}
	}
	open := func(ctx context.Context, path string, flag int, perm os.FileMode) (io.ReadWriteCloser, error) {
		switch path {
		case "/dev/null", "/dev/stdout", "/dev/stderr":
			return interp.DefaultOpenHandler()(ctx, path, flag, perm)
		}
		abs := path
		if !filepath.IsAbs(abs) {
			abs = filepath.Join(interp.HandlerCtx(ctx).Dir, path)
		}
		if strings.HasPrefix(abs, scratch+string(os.PathSeparator)) {
			return interp.DefaultOpenHandler()(ctx, abs, flag, perm)
		}
		mapped := filepath.Join(scratch, "fs", abs)
		if flag&(os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_APPEND|os.O_TRUNC) != 0 {
			_ = os.MkdirAll(filepath.Dir(mapped), 0o700)
			return os.OpenFile(mapped, flag, perm)
		}
		if _, err := os.Stat(mapped); err == nil {
			return os.Open(mapped)
		}
		return interp.DefaultOpenHandler()(ctx, abs, flag, perm)
	}

	runner, err := interp.New(
		interp.Env(expand.ListEnviron(env...)),
		interp.Dir(root),
		interp.Params("-e", "-u", "-o", "pipefail"),
		interp.StdIO(strings.NewReader(""), &stdout, &stderr),
		interp.ExecHandler(exe),
		interp.OpenHandler(open),
	)
	if err != nil {
		add(Finding{Error: true, Msg: err.Error()})
		return res
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	err = runner.Run(ctx, file)
	switch st, ok := interp.IsExitStatus(err); {
	case err == nil:
		res.Exit = "0"
	case ok:
		res.Exit = fmt.Sprint(st)
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		res.Exit = "timeout"
		add(Finding{Error: true, Msg: fmt.Sprintf("did not finish within %s with fake ssh/curl/sleep (a loop that never ends?)", timeout)})
	default:
		res.Exit = "error"
		add(Finding{Error: true, Msg: "shell error: " + err.Error()})
	}
	for _, line := range strings.Split(stderr.String(), "\n") {
		if shellErr.MatchString(line) {
			add(Finding{Error: true, Msg: "shell error: " + strings.TrimSpace(line)})
		}
	}
	out := strings.TrimSpace(stdout.String() + "\n" + stderr.String())
	if i := strings.LastIndex(out, "\n"); i >= 0 {
		out = out[i+1:]
	}
	res.LastOut = out
	for k := range faked {
		res.Faked = append(res.Faked, k)
	}
	sort.Strings(res.Faked)
	return res
}

var shellErr = regexp.MustCompile(`unbound variable|command not found|bad substitution|syntax error`)

func longKey(s string) string {
	switch s {
	case "docker image pull":
		return "docker pull"
	case "cp -a", "cp -r":
		return "cp"
	}
	return s
}

// sshRemote returns the host and the remote command (arguments joined with spaces, as ssh does).
func sshRemote(args []string) (string, string) {
	withValue := set("-F", "-i", "-o", "-p", "-l", "-J", "-b", "-c", "-E", "-L", "-R", "-D", "-W")
	i := 0
	for i < len(args) && strings.HasPrefix(args[i], "-") {
		if withValue[args[i]] {
			i++
		}
		i++
	}
	if i >= len(args) {
		return "?", ""
	}
	return args[i], strings.Join(args[i+1:], " ")
}

// CheckRemote parses a remote command (and the heredoc fed to it, if its shell reads stdin) and
// every nested shell payload in it.
func CheckRemote(remote, stdin, where string) []Finding {
	c := &checker{where: where}
	c.script(remote, stdin, false, 0)
	return c.out
}

type checker struct {
	where string
	out   []Finding
}

func (c *checker) script(src, stdin string, detached bool, depth int) {
	f, err := syntax.NewParser(syntax.Variant(syntax.LangBash)).Parse(strings.NewReader(src), "")
	if err != nil {
		c.out = append(c.out, Finding{Error: true, Msg: fmt.Sprintf("%s: shell syntax error at depth %d: %v\n    command: %s",
			c.where, depth, err, firstLine(src, 0))})
		return
	}
	syntax.Walk(f, func(n syntax.Node) bool {
		call, ok := n.(*syntax.CallExpr)
		if !ok || len(call.Args) == 0 {
			return true
		}
		args := make([]string, len(call.Args))
		for i, w := range call.Args {
			args[i] = word(w)
		}
		c.call(args, src, int(call.Pos().Line()), stdin, detached, depth)
		return true
	})
}

// call checks one simple command: unwraps prefixes (setsid, nohup, pct exec N --, timeout...),
// then recurses into shell payloads and flags long-running commands.
func (c *checker) call(args []string, src string, line int, stdin string, detached bool, depth int) {
	for len(args) > 0 {
		switch a := filepath.Base(args[0]); a {
		case "setsid", "nohup", "systemd-run":
			detached = true
			args = dropOpts(args[1:], set("-u", "--unit", "-p", "--property"))
			continue
		case "timeout", "nice", "ionice", "sudo", "exec", "command":
			args = dropOpts(args[1:], set("-n", "-c", "-u", "-s", "-k"))
			if a == "timeout" && len(args) > 0 {
				args = args[1:]
			}
			continue
		case "env":
			args = args[1:]
			for len(args) > 0 && (strings.Contains(args[0], "=") || strings.HasPrefix(args[0], "-")) {
				args = args[1:]
			}
			continue
		case "pct", "lxc-attach":
			if i := indexOf(args, "--"); i >= 0 && (a == "lxc-attach" || (len(args) > 1 && args[1] == "exec")) {
				args = args[i+1:]
				continue
			}
		}
		break
	}
	if len(args) == 0 {
		return
	}
	name := filepath.Base(args[0])
	if shells[name] {
		hasC, payload, readsStdin := shellArgs(args[1:])
		switch {
		case hasC && payload != nil:
			c.script(*payload, "", detached, depth+1)
		case readsStdin && stdin != "":
			c.script(stdin, "", detached, depth+1)
		}
		return
	}
	key := name
	switch {
	case name == "docker" && len(args) > 1 && (args[1] == "pull" || (args[1] == "image" && len(args) > 2 && args[2] == "pull")):
		key = "docker pull"
	case name == "cp" && hasAnyFlag(args[1:], "aRr"):
		key = "cp"
	case !longCmds[name]:
		return
	}
	if detached {
		return
	}
	c.out = append(c.out, Finding{Error: true, Kind: key, Msg: fmt.Sprintf("%s: long-running command (%s) in one SSH session"+
		" (Warpgate cuts sessions after ~5 min); detach with setsid and poll if it can take minutes:\n    %s",
		c.where, key, firstLine(src, line))})
}

// shellArgs reads sh/bash options: whether -c is given and its payload, or whether the shell reads
// its script from stdin (-s, or no script argument at all).
func shellArgs(args []string) (hasC bool, payload *string, readsStdin bool) {
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "--" {
			i++
			break
		}
		if len(a) < 2 || (a[0] != '-' && a[0] != '+') {
			break
		}
		if strings.ContainsRune(a[1:], 'c') {
			hasC = true
		}
		if strings.ContainsRune(a[1:], 's') {
			readsStdin = true
		}
		if strings.HasSuffix(a, "o") && !strings.ContainsRune(a[1:], 'c') { // -o pipefail, -euo pipefail
			i++
		}
		i++
	}
	if hasC {
		if i < len(args) {
			payload = &args[i]
		}
		return
	}
	if i >= len(args) {
		readsStdin = true
	}
	return
}

func dropOpts(args []string, withValue map[string]bool) []string {
	for len(args) > 0 && strings.HasPrefix(args[0], "-") {
		if withValue[args[0]] && len(args) > 1 {
			args = args[1:]
		}
		args = args[1:]
	}
	return args
}

func hasAnyFlag(args []string, letters string) bool {
	for _, a := range args {
		if strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--") && strings.ContainsAny(a[1:], letters) {
			return true
		}
		if a == "--archive" || a == "--recursive" {
			return true
		}
	}
	return false
}

func indexOf(xs []string, s string) int {
	for i, x := range xs {
		if x == s {
			return i
		}
	}
	return -1
}

// word expands a word as the shell at that layer would, with every variable and command
// substitution standing in as "X" (their values are only known on the remote host).
func word(w *syntax.Word) string {
	cfg := &expand.Config{
		Env: expand.FuncEnviron(func(string) string { return "X" }),
		CmdSubst: func(out io.Writer, _ *syntax.CmdSubst) error {
			_, err := io.WriteString(out, "X")
			return err
		},
		ProcSubst: func(*syntax.ProcSubst) (string, error) { return "/dev/null", nil },
	}
	s, err := expand.Literal(cfg, w)
	if err != nil {
		var b strings.Builder
		_ = syntax.NewPrinter().Print(&b, w)
		return b.String()
	}
	return s
}

func firstLine(src string, line int) string {
	lines := strings.Split(src, "\n")
	if line < 1 || line > len(lines) {
		line = 1
	}
	s := strings.TrimSpace(lines[line-1])
	if len(s) > 200 {
		s = s[:200] + "..."
	}
	return s
}

var applyEnvRe = regexp.MustCompile(`(?m)^\s+([A-Z][A-Z0-9_]+): \$\{\{`)

// applyEnv lists every env value the apply job sets, so a request using one it doesn't set fails
// here as it would there.
func applyEnv(root string) []string {
	b, err := os.ReadFile(filepath.Join(root, ".github/workflows/apply.yml"))
	if err != nil {
		return nil
	}
	var names []string
	for _, m := range applyEnvRe.FindAllStringSubmatch(string(b), -1) {
		names = append(names, m[1])
	}
	return names
}

// annotate prints a GitHub workflow command; it must be one line.
func annotate(kind, file, msg string) {
	r := strings.NewReplacer("%", "%25", "\r", "%0D", "\n", "%0A")
	fmt.Printf("::%s file=%s::%s\n", kind, file, r.Replace(msg))
}

func main() {
	root := flag.String("root", "", "repository root (default: the git checkout containing the current directory)")
	timeout := flag.Duration("timeout", 120*time.Second, "per-request time limit")
	flag.Parse()
	if *root == "" {
		out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
		if err != nil {
			fmt.Fprintln(os.Stderr, "rehearse: not in a git checkout; pass -root")
			os.Exit(2)
		}
		*root = strings.TrimSpace(string(out))
	}
	*root, _ = filepath.Abs(*root)
	failed := false
	for _, a := range flag.Args() {
		abs, _ := filepath.Abs(a)
		if _, err := os.Stat(abs); err != nil && !filepath.IsAbs(a) {
			abs = filepath.Join(*root, a) // `go -C tools run ./rehearse ops/requests/x.sh` from the repo root
		}
		rel, err := filepath.Rel(*root, abs)
		if err != nil {
			rel = a
		}
		res := Rehearse(*root, abs, *timeout)
		fmt.Printf("%s: reached %d remote command(s), exit %s (non-zero is expected with fake data)\n", rel, res.Remote, res.Exit)
		if res.LastOut != "" {
			fmt.Printf("    last output: %.200s\n", res.LastOut)
		}
		if len(res.Faked) > 0 {
			fmt.Printf("    faked (not run): %s\n", strings.Join(res.Faked, ", "))
		}
		for _, f := range res.Findings {
			if f.Error {
				failed = true
				annotate("error", rel, f.Msg)
			} else {
				annotate("warning", rel, f.Msg)
			}
		}
	}
	if failed {
		os.Exit(1)
	}
}
