package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var root, _ = filepath.Abs("../..")

type want struct {
	errors   []string // each must appear in some error finding, in order of findings
	warnings []string
	exit     string // "" = don't care
}

func TestFixtures(t *testing.T) {
	cases := map[string]want{
		"nested-quote.sh":         {errors: []string{"syntax error at depth 1"}},
		"quote-then-semicolon.sh": {},
		"heredoc-bad.sh":          {errors: []string{"syntax error at depth 1"}},
		"heredoc-data.sh":         {},
		"options-before-c.sh":     {errors: []string{"syntax error at depth 1"}},
		"long-tar.sh":             {errors: []string{"(tar)"}},
		"long-detached.sh":        {errors: []string{"(rsync)"}},
		"allow-long.sh":           {errors: []string{"(tar)"}, warnings: []string{"(du)"}},
		"docker-pull.sh":          {errors: []string{"(docker pull)", "(docker pull)", "(docker save)"}},
		"cmdsubst.sh":             {errors: []string{"(du)"}},
		"unbound.sh":              {errors: []string{"NOT_SET_BY_APPLY"}},
		"apply-env.sh":            {exit: "0"},
		"missing-cmd.sh":          {errors: []string{"command not found"}},
		"scp.sh":                  {errors: []string{"scp on the runner"}},
		"no-network.sh":           {exit: "0"},
		"writes-sandboxed.sh":     {exit: "0"},
		"endless.sh":              {errors: []string{"did not finish"}, exit: "timeout"},
		"wrappers.sh":             {errors: []string{"(tar)", "(tar)", "(tar)"}},
		"wrapper-shell.sh":        {errors: []string{"syntax error at depth 1"}},
		"command-v.sh":            {},
		"xargs-find.sh":           {errors: []string{"(tar)", "(rsync)"}},
		"real-writes.sh":          {exit: "0"},
		"untracked-read.sh":       {exit: "1"},
		"dir-read.sh":             {exit: "1"},
		"string-tools.sh":         {exit: "0"},
		"write-then-read.sh":      {exit: "0"},
	}
	secret := filepath.Join("testdata", "untracked-secret.env") // created here, never committed
	if err := os.WriteFile(secret, []byte("CF_TOKEN=leak\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(secret)
	for name, w := range cases {
		t.Run(name, func(t *testing.T) {
			res := Rehearse(root, filepath.Join("testdata", name), 3*time.Second)
			var errs, warns []string
			for _, f := range res.Findings {
				if f.Error {
					errs = append(errs, f.Msg)
				} else {
					warns = append(warns, f.Msg)
				}
			}
			match(t, "error", errs, w.errors)
			match(t, "warning", warns, w.warnings)
			if w.exit != "" && res.Exit != w.exit {
				t.Errorf("exit %s, want %s (last output: %s)", res.Exit, w.exit, res.LastOut)
			}
		})
	}
	for _, f := range []string{"/tmp/rehearse-sort-out", "/tmp/rehearse-sort-out2", "/tmp/rehearse-sed-in-place"} {
		if _, err := os.Stat(f); err == nil {
			t.Errorf("real-writes.sh wrote %s", f)
		}
	}
	if _, err := os.Stat("/root/rehearse-test-file"); err == nil {
		t.Error("writes-sandboxed.sh wrote outside the scratch directory")
	}
}

func match(t *testing.T, kind string, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("%d %s finding(s), want %d:\n%s", len(got), kind, len(want), strings.Join(got, "\n"))
		return
	}
	for i := range want {
		if !strings.Contains(got[i], want[i]) {
			t.Errorf("%s %d = %q, want it to contain %q", kind, i, got[i], want[i])
		}
	}
}

// Every request already in the repo ran in the apply job, so none may get a shell or quoting error
// (long-running findings are allowed: old requests aren't re-checked, and some were cut, PR #74).
func TestExistingRequestsHaveNoFalseErrors(t *testing.T) {
	reqs, _ := filepath.Glob(filepath.Join(root, "ops/requests/*.sh"))
	if len(reqs) == 0 {
		t.Fatal("no requests found")
	}
	for _, r := range reqs {
		res := Rehearse(root, r, 30*time.Second)
		for _, f := range res.Findings {
			if f.Error && f.Kind == "" && !strings.HasPrefix(f.Msg, "shellcheck") {
				t.Errorf("%s: %s", filepath.Base(r), f.Msg)
			}
		}
	}
}

func TestShellArgs(t *testing.T) {
	for _, c := range []struct {
		args        string
		hasC, stdin bool
		payload     string
	}{
		{"-c x", true, false, "x"},
		{"-ec x", true, false, "x"},
		{"-euo pipefail -c x", true, false, "x"},
		{"-e -c x arg0", true, false, "x"},
		{"-s", false, true, ""},
		{"-euo pipefail -s -- a b", false, true, ""},
		{"", false, true, ""},
		{"-e", false, true, ""},
		{"script.sh", false, false, ""},
	} {
		hasC, p, stdin := shellArgs(strings.Fields(c.args))
		got := ""
		if p != nil {
			got = *p
		}
		if hasC != c.hasC || stdin != c.stdin || got != c.payload {
			t.Errorf("shellArgs(%q) = %v %q %v, want %v %q %v", c.args, hasC, got, stdin, c.hasC, c.payload, c.stdin)
		}
	}
}

func TestSSHRemote(t *testing.T) {
	for _, c := range []struct{ args, host, remote string }{
		{"-F cfg pve pct exec 1 -- ls", "pve", "pct exec 1 -- ls"},
		{"-Fcfg -tt pve ls", "pve", "ls"},
		{"-o BatchMode=yes -p 22 host", "host", ""},
	} {
		h, r := sshRemote(strings.Fields(c.args))
		if h != c.host || r != c.remote {
			t.Errorf("sshRemote(%q) = %q %q, want %q %q", c.args, h, r, c.host, c.remote)
		}
	}
}
