// Command shannon-mcp is the opencode MCP server for the Shannon driver
// development workflow. It is a pure-Go rewrite of the previous Python MCP
// (shannon-server.py) and adds native IPMI power + Serial-over-LAN (SOL)
// console capture, implemented with github.com/bougou/go-ipmi (pure-Go IPMI
// v2.0 / RMCP+). No ipmitool / freeipmi dependency.
//
// The shannon_* tools wrap the shell scripts in scripts/ (subprocess). The
// ipmi_* tools talk IPMI directly over UDP/623 to the BMC.
//
// IPMI credentials (ipmi_host / ipmi_user / ipmi_password) are read by this
// binary from a local .ipmi.creds file (located by walking up from the working
// directory, or via $SHANNON_IPMI_CREDS). They are NEVER accepted as tool
// arguments and NEVER printed -- the agent/LLM cannot see them.
//
// Usage: opencode launches this binary as an MCP stdio server. It can also be
// run standalone for testing: it speaks newline-delimited JSON-RPC 2.0.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	ipmi "github.com/bougou/go-ipmi"
)

const protocolVersion = "2024-11-05"

// ---------------------------------------------------------------------------
// repo / scripts path discovery
// ---------------------------------------------------------------------------

func findScriptsDir() string {
	// 1. $SHANNON_SCRIPTS
	if p := os.Getenv("SHANNON_SCRIPTS"); p != "" {
		if isDir(p) {
			return p
		}
	}
	// 2. ./scripts (opencode runs the MCP from the repo root)
	if isDir("scripts") {
		if abs, err := filepath.Abs("scripts"); err == nil {
			return abs
		}
	}
	// 3. walk up from cwd looking for a repo with scripts/ + .opencode/
	dir, err := os.Getwd()
	if err == nil {
		for i := 0; i < 10; i++ {
			if isDir(filepath.Join(dir, "scripts")) && isDir(filepath.Join(dir, ".opencode")) {
				return filepath.Join(dir, "scripts")
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	// 4. relative to this binary (.opencode/mcp[-go]/<binary> -> repo/scripts)
	if exe, err := os.Executable(); err == nil {
		d := filepath.Dir(exe)
		for i := 0; i < 6; i++ {
			if isDir(filepath.Join(d, "scripts")) {
				return filepath.Join(d, "scripts")
			}
			p := filepath.Dir(d)
			if p == d {
				break
			}
			d = p
		}
	}
	return "scripts"
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// ---------------------------------------------------------------------------
// MCP JSON-RPC plumbing
// ---------------------------------------------------------------------------

type rpcReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

func respond(id any, result any) {
	type resp struct {
		JSONRPC string `json:"jsonrpc"`
		ID      any    `json:"id"`
		Result  any    `json:"result"`
	}
	out, _ := json.Marshal(resp{"2.0", id, result})
	fmt.Fprintln(os.Stdout, string(out))
}

func errorResp(id any, code int, msg string) {
	type errr struct {
		JSONRPC string `json:"jsonrpc"`
		ID      any    `json:"id"`
		Error   struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	e := errr{JSONRPC: "2.0", ID: id}
	e.Error.Code = code
	e.Error.Message = msg
	out, _ := json.Marshal(e)
	fmt.Fprintln(os.Stdout, string(out))
}

// ---------------------------------------------------------------------------
// tool definitions + dispatch
// ---------------------------------------------------------------------------

type handler func(args map[string]any) (text string, isError bool)

type toolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	h           handler
}

var tools []toolDef

// schema helpers
func schema(props map[string]any, required ...string) map[string]any {
	s := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if len(required) > 0 {
		s["required"] = required
	}
	return s
}

func str() map[string]any       { return map[string]any{"type": "string"} }
func intl() map[string]any      { return map[string]any{"type": "integer"} }
func boolp() map[string]any     { return map[string]any{"type": "boolean"} }
func strArr() map[string]any    { return map[string]any{"type": "array", "items": map[string]any{"type": "string"}} }
func enumStr(v ...string) map[string]any {
	e := map[string]any{"type": "string"}
	e["enum"] = v
	return e
}

// arg helpers
func gstr(a map[string]any, k string) string {
	if v, ok := a[k]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

func gbool(a map[string]any, k string) (bool, bool) {
	if v, ok := a[k]; ok {
		if b, ok := v.(bool); ok {
			return b, true
		}
	}
	return false, false
}

func gint(a map[string]any, k string) int {
	if v, ok := a[k]; ok {
		switch n := v.(type) {
		case float64:
			return int(n)
		case int:
			return n
		}
	}
	return 0
}

func garr(a map[string]any, k string) []string {
	if v, ok := a[k]; ok {
		if arr, ok := v.([]any); ok {
			out := make([]string, 0, len(arr))
			for _, x := range arr {
				if s, ok := x.(string); ok {
					out = append(out, s)
				}
			}
			return out
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// script runner (shannon_* tools)
// ---------------------------------------------------------------------------

var SCRIPTS = findScriptsDir()

func runScript(script string, args []string, timeout time.Duration) (string, bool) {
	path := filepath.Join(SCRIPTS, script)
	if !isFile(path) {
		return fmt.Sprintf("script not found: %s", path), true
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	full := append([]string{path}, args...)
	cmd := exec.CommandContext(ctx, "sh", full...)
	// scripts call ssh/scp/rsync; inherit the agent env (SSH_AUTH_SOCK etc.)
	cmd.Env = os.Environ()
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Sprintf("timeout after %ds", int(timeout.Seconds())), true
	}
	out := stdout.String()
	errStr := stderr.String()
	if err != nil {
		text := errStr
		if text == "" {
			text = out
		}
		if text == "" {
			text = fmt.Sprintf("exit: %v", err)
		}
		if out != "" && errStr != "" {
			text = errStr + "\n--- stdout ---\n" + out
		}
		return text, true
	}
	return out, false
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// --- shannon tool handlers (mirror shannon-server.py) ---

func tListPCI(a map[string]any) (string, bool) {
	return runScript("shannon-pci-list.sh", []string{"--host", gstr(a, "host"), "--json"}, 60)
}

func tBind(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host")}
	if bdfs := garr(a, "bdfs"); len(bdfs) > 0 {
		args = append(args, bdfs...)
	} else {
		args = append(args, "--all")
	}
	return runScript("driver-bind.sh", args, 120)
}

func tReleaseHost(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host")}
	if bdfs := garr(a, "bdfs"); len(bdfs) > 0 {
		args = append(args, bdfs...)
	} else {
		args = append(args, "--all")
	}
	if t := gstr(a, "tmux"); t != "" {
		args = append(args, "--tmux", t)
	}
	if r, _ := gbool(a, "reset"); r {
		args = append(args, "--reset")
	}
	if kq, ok := gbool(a, "kill_qemu"); ok && !kq {
		args = append(args, "--no-kill-qemu")
	}
	args = append(args, "--json")
	return runScript("release-host.sh", args, 300)
}

func tFetchKernel(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host"), "--kernel", gstr(a, "kver")}
	switch gstr(a, "what") {
	case "image":
		args = append(args, "--image-only")
	case "headers":
		args = append(args, "--headers-only")
	}
	if s := gstr(a, "suite"); s != "" {
		args = append(args, "--suite", s)
	}
	return runScript("fetch-kernel.sh", args, 900)
}

func tRsync(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host")}
	if s := gstr(a, "src"); s != "" {
		args = append(args, "--src", s)
	}
	return runScript("rsync-src.sh", args, 300)
}

func tBuild(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host"), "--kernel", gstr(a, "kver")}
	if s := gstr(a, "src"); s != "" {
		args = append(args, "--src", s)
	}
	if j := gint(a, "jobs"); j > 0 {
		args = append(args, "-j", strconv.Itoa(j))
	}
	return runScript("build-module.sh", args, 1200)
}

func tMakeInitrd(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host"), "--kernel", gstr(a, "kver")}
	if s := gstr(a, "src"); s != "" {
		args = append(args, "--src", s)
	}
	if t := gstr(a, "initrd_template"); t != "" {
		args = append(args, "--initrd-template", t)
	}
	if se, ok := gbool(a, "skip_epilog"); ok && !se {
		args = append(args, "--no-skip-epilog")
	}
	return runScript("make-initrd.sh", args, 900)
}

func tInstallQEMU(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host"), "--version", gstrDefault(a, "version", "11.0.2")}
	if b := gstr(a, "bundle"); b != "" {
		args = append(args, "--bundle", b)
	}
	if n, _ := gbool(a, "native"); n {
		args = append(args, "--native")
	}
	if j := gint(a, "jobs"); j > 0 {
		args = append(args, "-j", strconv.Itoa(j))
	}
	return runScript("install-qemu.sh", args, 3600)
}

func tRunQEMU(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host"), "--json"}
	if k := gstr(a, "kver"); k != "" {
		args = append(args, "--kernel", k)
	}
	if m := gstr(a, "memory"); m != "" {
		args = append(args, "-m", m)
	}
	if s := gint(a, "smp"); s > 0 {
		args = append(args, "-s", strconv.Itoa(s))
	}
	if g, _ := gbool(a, "gdb"); g {
		args = append(args, "--gdb")
	}
	if t := gstr(a, "tmux"); t != "" {
		args = append(args, "--tmux", t)
	}
	if sl := gstr(a, "serial_log"); sl != "" {
		args = append(args, "--serial-log", sl)
	}
	if c, _ := gbool(a, "capture_only"); c {
		args = append(args, "--capture-only")
	}
	if q := gstr(a, "qemu"); q != "" {
		args = append(args, "--qemu", q)
	}
	if bdfs := garr(a, "bdfs"); len(bdfs) > 0 {
		args = append(args, bdfs...)
	} else {
		args = append(args, "--all")
	}
	return runScript("qemu-shannon-run.sh", args, 120)
}

func tConsole(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host"), "--json"}
	if t := gstr(a, "tmux"); t != "" {
		args = append(args, "--tmux", t)
	}
	if sl := gstr(a, "serial_log"); sl != "" {
		args = append(args, "--serial-log", sl)
	}
	action := gstr(a, "action")
	args = append(args, action)
	switch action {
	case "grep":
		if p := gstr(a, "pattern"); p != "" {
			args = append(args, p)
		}
	case "send", "send-keys":
		if c := gstr(a, "cmd"); c != "" {
			args = append(args, c)
		}
	case "tail":
		if l := gint(a, "lines"); l > 0 {
			args = append(args, strconv.Itoa(l))
		}
	case "wait-ready":
		if to := gint(a, "timeout"); to > 0 {
			args = append(args, "--timeout", strconv.Itoa(to))
		}
		if iv := gint(a, "interval"); iv > 0 {
			args = append(args, "--interval", strconv.Itoa(iv))
		}
	}
	timeout := 60 * time.Second
	if action == "wait-ready" {
		to := gint(a, "timeout")
		if to <= 0 {
			to = 600
		}
		timeout = time.Duration(to+30) * time.Second
	}
	return runScript("qemu-console.sh", args, timeout)
}

func tDevCycle(a map[string]any) (string, bool) {
	args := []string{"--host", gstr(a, "host"), "--kernel", gstr(a, "kver")}
	if g, _ := gbool(a, "gdb"); g {
		args = append(args, "--gdb")
	}
	if t := gstr(a, "tmux"); t != "" {
		args = append(args, "--tmux", t)
	}
	if q := gstr(a, "qemu"); q != "" {
		args = append(args, "--qemu", q)
	}
	if bdfs := garr(a, "bdfs"); len(bdfs) > 0 {
		args = append(args, bdfs...)
	} else {
		args = append(args, "--all")
	}
	return runScript("dev-cycle.sh", args, 1800)
}

func gstrDefault(a map[string]any, k, def string) string {
	if v := gstr(a, k); v != "" {
		return v
	}
	return def
}

// ---------------------------------------------------------------------------
// IPMI credentials (read from .ipmi.creds by this binary only)
// ---------------------------------------------------------------------------

type ipmiCreds struct {
	Host string
	User string
	Pass string
}

func loadIPMICreds() (*ipmiCreds, error) {
	path := os.Getenv("SHANNON_IPMI_CREDS")
	if path == "" {
		dir, err := os.Getwd()
		if err == nil {
			for i := 0; i < 10; i++ {
				p := filepath.Join(dir, ".ipmi.creds")
				if isFile(p) {
					path = p
					break
				}
				parent := filepath.Dir(dir)
				if parent == dir {
					break
				}
				dir = parent
			}
		}
	}
	if path == "" {
		// last resort: relative to the binary
		if exe, err := os.Executable(); err == nil {
			d := filepath.Dir(exe)
			for i := 0; i < 8; i++ {
				p := filepath.Join(d, ".ipmi.creds")
				if isFile(p) {
					path = p
					break
				}
				pn := filepath.Dir(d)
				if pn == d {
					break
				}
				d = pn
			}
		}
	}
	if path == "" {
		return nil, fmt.Errorf(".ipmi.creds not found (set $SHANNON_IPMI_CREDS or place it at the repo root)")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	c := &ipmiCreds{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		kv := strings.SplitN(line, "=", 2)
		if len(kv) != 2 {
			continue
		}
		k := strings.TrimSpace(kv[0])
		v := strings.TrimSpace(kv[1])
		switch k {
		case "ipmi_host":
			c.Host = v
		case "ipmi_user":
			c.User = v
		case "ipmi_password":
			c.Pass = v
		}
	}
	if c.Host == "" || c.User == "" {
		return nil, fmt.Errorf(".ipmi.creds at %s is missing ipmi_host and/or ipmi_user", path)
	}
	return c, nil
}

// newIPMIClient connects an RMCP+ (lanplus) client. Caller must Close(ctx).
func newIPMIClient(ctx context.Context) (*ipmi.Client, func(), error) {
	creds, err := loadIPMICreds()
	if err != nil {
		return nil, nil, err
	}
	client, err := ipmi.NewClient(creds.Host, 623, creds.User, creds.Pass)
	if err != nil {
		return nil, nil, err
	}
	client.WithInterface(ipmi.InterfaceLanplus)
	if err := client.Connect(ctx); err != nil {
		return nil, nil, fmt.Errorf("ipmi connect to %s: %w", creds.Host, err)
	}
	cleanup := func() { _ = client.Close(context.Background()) }
	return client, cleanup, nil
}

// ---------------------------------------------------------------------------
// IPMI power tool
// ---------------------------------------------------------------------------

func tIPMIPower(a map[string]any) (string, bool) {
	action := gstr(a, "action")
	if action == "" {
		action = "status"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	client, cleanup, err := newIPMIClient(ctx)
	if err != nil {
		return err.Error(), true
	}
	defer cleanup()

	if action == "status" {
		st, err := client.GetChassisStatus(ctx)
		if err != nil {
			return "get chassis status: " + err.Error(), true
		}
		out, _ := json.Marshal(map[string]any{
			"ok":               true,
			"power_on":         st.PowerIsOn,
			"power_fault":      st.PowerFault,
			"power_overload":   st.PowerOverload,
			"interlock":        st.InterLock,
			"power_control_fault": st.PowerControlFault,
		})
		return string(out), false
	}

	var cc ipmi.ChassisControl
	switch action {
	case "on":
		cc = ipmi.ChassisControlPowerUp
	case "off":
		cc = ipmi.ChassisControlPowerDown
	case "cycle":
		cc = ipmi.ChassisControlPowerCycle
	case "reset":
		cc = ipmi.ChassisControlHardReset
	case "soft":
		cc = ipmi.ChassisControlSoftShutdown
	default:
		return "unknown action (use on|off|cycle|reset|soft|status): " + action, true
	}
	if _, err := client.ChassisControl(ctx, cc); err != nil {
		return "chassis control: " + err.Error(), true
	}
	out, _ := json.Marshal(map[string]any{"ok": true, "action": action})
	return string(out), false
}

// ---------------------------------------------------------------------------
// IPMI SOL capture tools (stateful: one active session at a time)
// ---------------------------------------------------------------------------

type solSession struct {
	cancel   context.CancelFunc
	logPath  string
	done     chan struct{}
	inWriter io.Writer // pipe write end for sending console input (nil if none)
}

var (
	solMu  sync.Mutex
	solCur *solSession
)

func defaultSOLLog() string {
	if t := os.TempDir(); t != "" {
		return filepath.Join(t, "shannon-sol.log")
	}
	return "shannon-sol.log"
}

func tIPMISolStart(a map[string]any) (string, bool) {
	logPath := gstr(a, "log")
	if logPath == "" {
		logPath = defaultSOLLog()
	}
	creds, err := loadIPMICreds()
	if err != nil {
		return err.Error(), true
	}

	solMu.Lock()
	if solCur != nil {
		solMu.Unlock()
		return "an SOL session is already active; call ipmi_sol_stop first", true
	}
	solMu.Unlock()

	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return "open log: " + err.Error(), true
	}
	client, err := ipmi.NewClient(creds.Host, 623, creds.User, creds.Pass)
	if err != nil {
		f.Close()
		return err.Error(), true
	}
	client.WithInterface(ipmi.InterfaceLanplus)
	// SOL does sustained polling; be tolerant of a lossy Mac->BMC VPN link.
	client.WithRetry(12)
	client.WithTimeout(6 * time.Second)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	// Blocking, no-input reader by default: a pipe whose write end is kept open
	// blocks SOLActivate's input loop so it stays idle while the poll ticker
	// drains inbound bytes into the log. ipmi_sol_send writes to pw to inject
	// console input (e.g. a newline to trigger a getty login prompt).
	pr, pw := io.Pipe()
	sess := &solSession{cancel: cancel, logPath: logPath, done: done, inWriter: pw}

	solMu.Lock()
	solCur = sess
	solMu.Unlock()

	go func() {
		defer close(done)
		defer f.Close()
		defer func() { _ = client.Close(context.Background()) }()
		defer pw.Close()
		fmt.Fprintf(f, "[SOL capture started -> %s at %s]\n", creds.Host, time.Now().Format(time.RFC3339))
		if cerr := client.Connect(ctx); cerr != nil {
			fmt.Fprintf(f, "[SOL connect failed: %v]\n", cerr)
			return
		}
		if serr := client.SOLActivate(ctx, pr, f, &ipmi.SOLActivateOptions{
			PollInterval: 1000 * time.Millisecond,
		}); serr != nil {
			fmt.Fprintf(f, "[SOL session ended: %v]\n", serr)
		}
	}()

	out, _ := json.Marshal(map[string]any{"ok": true, "log": logPath, "host": creds.Host})
	return string(out), false
}

func tIPMISolStop(a map[string]any) (string, bool) {
	solMu.Lock()
	sess := solCur
	solCur = nil
	solMu.Unlock()
	if sess == nil {
		return "no active SOL session", true
	}
	sess.cancel()
	// wait for the goroutine to finish (deactivate payload, close log)
	select {
	case <-sess.done:
	case <-time.After(15 * time.Second):
	}
	out, _ := json.Marshal(map[string]any{"ok": true, "stopped": true, "log": sess.logPath})
	return string(out), false
}

func tIPMISolSend(a map[string]any) (string, bool) {
	s := gstr(a, "data")
	if s == "" {
		s = "\n"
	}
	s = strings.ReplaceAll(s, "\\n", "\n")
	s = strings.ReplaceAll(s, "\\r", "\r")
	solMu.Lock()
	sess := solCur
	solMu.Unlock()
	if sess == nil || sess.inWriter == nil {
		return "no active SOL session", true
	}
	if _, err := sess.inWriter.Write([]byte(s)); err != nil {
		return "write to SOL failed: " + err.Error(), true
	}
	out, _ := json.Marshal(map[string]any{"ok": true, "sent": len(s)})
	return string(out), false
}

func tIPMISolTail(a map[string]any) (string, bool) {
	n := gint(a, "lines")
	if n <= 0 {
		n = 200
	}
	solMu.Lock()
	logPath := solCur.logPath
	solMu.Unlock()
	if logPath == "" {
		logPath = gstr(a, "log")
		if logPath == "" {
			logPath = defaultSOLLog()
		}
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		return "read log: " + err.Error(), true
	}
	all := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	start := 0
	if len(all) > n {
		start = len(all) - n
	}
	return strings.Join(all[start:], "\n"), false
}

// ---------------------------------------------------------------------------
// tool registration
// ---------------------------------------------------------------------------

func registerTools() {
	tools = []toolDef{
		{Name: "shannon_list_pci", Description: "List Shannon Direct-IO PCIe devices (1cb0:0275) on a remote host. Returns JSON {ok, host, devices:[{bdf, desc}]}.", InputSchema: schema(map[string]any{"host": str()}, "host"), h: tListPCI},
		{Name: "shannon_bind", Description: "Bind Shannon PCIe devices to vfio-pci on a remote host (needs root). Use all=true (default) or explicit bdfs.", InputSchema: schema(map[string]any{"host": str(), "all": boolp(), "bdfs": strArr()}, "host"), h: tBind},
		{Name: "shannon_release_host", Description: "Release Shannon devices from the HOST before a QEMU debug session: kill the running QEMU tmux session, unmount /dev/df* filesystems (and kill holders), unbind devices from the host 'shannon' driver, and rmmod shannon. Run BEFORE shannon_run_qemu / shannon_dev_cycle. Returns JSON {ok, killed_qemu, unmounted, unbound, rmmod, reset, modules_loaded}.", InputSchema: schema(map[string]any{"host": str(), "all": boolp(), "bdfs": strArr(), "tmux": str(), "reset": boolp(), "kill_qemu": boolp()}, "host"), h: tReleaseHost},
		{Name: "shannon_fetch_kernel", Description: "Ensure vmlinuz-<kver> and/or linux-headers-<kver> are present on the host (downloads + unpacks the kernel .deb via temp apt config if missing). what: both|image|headers (default both).", InputSchema: schema(map[string]any{"host": str(), "kver": str(), "what": enumStr("both", "image", "headers"), "suite": str()}, "host", "kver"), h: tFetchKernel},
		{Name: "shannon_rsync_src", Description: "Rsync the driver source from this repo to ~/shannon-src on the host.", InputSchema: schema(map[string]any{"host": str(), "src": str()}, "host"), h: tRsync},
		{Name: "shannon_build", Description: "Build shannon.ko on the host for the given kernel (ensures headers first). Returns the path to shannon.ko.", InputSchema: schema(map[string]any{"host": str(), "kver": str(), "src": str(), "jobs": intl()}, "host", "kver"), h: tBuild},
		{Name: "shannon_make_initrd", Description: "Pack an initrd with the built shannon.ko + busybox + /init on the host. Auto-bootstraps a busybox root if no initrd_template given. skip_epilog=false for full epilog recovery (data-integrity runs).", InputSchema: schema(map[string]any{"host": str(), "kver": str(), "src": str(), "initrd_template": str(), "skip_epilog": boolp()}, "host", "kver"), h: tMakeInitrd},
		{Name: "shannon_install_qemu", Description: "Install/build QEMU (default 11.0.2) on the host via the Dockerfile.qemu build (native=true to build without Docker).", InputSchema: schema(map[string]any{"host": str(), "version": str(), "bundle": str(), "jobs": intl(), "native": boolp()}, "host"), h: tInstallQEMU},
		{Name: "shannon_run_qemu", Description: "Launch QEMU on the host with Shannon device(s) passed through via vfio-pci. Returns JSON {ok, tmux, serial_log, capture_only, kernel, devices}. capture_only=true for headless serial-log capture; default is interactive in a tmux session. After launch, use shannon_console(wait_ready) to wait out the 5+ min startup.", InputSchema: schema(map[string]any{"host": str(), "kver": str(), "all": boolp(), "bdfs": strArr(), "gdb": boolp(), "tmux": str(), "capture_only": boolp(), "serial_log": str(), "memory": str(), "smp": intl(), "qemu": str()}, "host"), h: tRunQEMU},
		{Name: "shannon_console", Description: "Inspect/drive a running Shannon QEMU guest via its serial log + tmux console. action: tail|grep|snapshot|send|send-keys|wait-ready|crash-check. wait-ready polls the serial log for 'Probed Direct-IO PCIe Flash' (ready) and crash markers; returns JSON {ok, ready, crash, elapsed_s, last_lines}.", InputSchema: schema(map[string]any{"host": str(), "action": enumStr("tail", "grep", "snapshot", "send", "send-keys", "wait-ready", "crash-check"), "tmux": str(), "serial_log": str(), "cmd": str(), "pattern": str(), "lines": intl(), "timeout": intl(), "interval": intl()}, "host", "action"), h: tConsole},
		{Name: "shannon_dev_cycle", Description: "One-shot end-to-end cycle on the host: fetch kernel -> rsync -> build -> pack initrd -> bind vfio-pci -> boot QEMU in tmux. Does NOT wait for the device (use shannon_console(wait_ready) next).", InputSchema: schema(map[string]any{"host": str(), "kver": str(), "all": boolp(), "bdfs": strArr(), "gdb": boolp(), "tmux": str(), "qemu": str()}, "host", "kver"), h: tDevCycle},

		// ---- IPMI (creds read from .ipmi.creds by the binary; never passed by the agent) ----
		{Name: "ipmi_power", Description: "Control or query the baremetal host power via IPMI (RMCP+/lanplus, pure-Go). action: status (default) | on | off | cycle | reset | soft (ACPI soft shutdown). Credentials are read from .ipmi.creds by the server; do NOT pass them. Returns JSON {ok, power_on,...} or {ok, action}.", InputSchema: schema(map[string]any{"action": enumStr("status", "on", "off", "cycle", "reset", "soft")}), h: tIPMIPower},
		{Name: "ipmi_sol_start", Description: "Start an IPMI Serial-over-LAN (SOL) capture session: opens an RMCP+ SOL payload and tees the host's serial console output to a log file (default $TMPDIR/shannon-sol.log). Returns immediately with {ok, log, host}. The host's grub/console must be redirected to the serial port for SOL to capture boot/kernel output. Capture is input-less (read-only); use ipmi_sol_send to inject console input (e.g. a newline to trigger a getty prompt). Stop with ipmi_sol_stop.", InputSchema: schema(map[string]any{"log": str()}), h: tIPMISolStart},
		{Name: "ipmi_sol_send", Description: "Send a string to the active IPMI SOL console (console input). Use data='\\n' (default) to send a newline, e.g. to trigger a getty login prompt on the host's ttyS0. \\n and \\r escapes are expanded.", InputSchema: schema(map[string]any{"data": str()}), h: tIPMISolSend},
		{Name: "ipmi_sol_stop", Description: "Stop the active IPMI SOL capture session (deactivates the SOL payload, closes the log). Returns {ok, stopped, log}.", InputSchema: schema(map[string]any{}), h: tIPMISolStop},
		{Name: "ipmi_sol_tail", Description: "Tail the IPMI SOL capture log (default last 200 lines). Optional 'lines' and 'log' (defaults to the active session's log).", InputSchema: schema(map[string]any{"lines": intl(), "log": str()}), h: tIPMISolTail},
	}
}

func handlerFor(name string) handler {
	for i := range tools {
		if tools[i].Name == name {
			return tools[i].h
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// MCP stdio loop
// ---------------------------------------------------------------------------

func serve() {
	registerTools()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var req rpcReq
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}
		if req.JSONRPC == "" {
			req.JSONRPC = "2.0"
		}
		if req.Method == "" {
			continue
		}
		// notifications (no id) get no response
		if req.ID == nil {
			continue
		}
		switch req.Method {
		case "initialize":
			respond(req.ID, map[string]any{
				"protocolVersion": protocolVersion,
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "shannon", "version": "1.1.0"},
			})
		case "initialized", "notifications/initialized":
			// notification, no response
		case "ping":
			respond(req.ID, map[string]any{})
		case "tools/list":
			type pub struct {
				Name string `json:"name"`
				Description string `json:"description"`
				InputSchema map[string]any `json:"inputSchema"`
			}
			list := make([]pub, 0, len(tools))
			for _, t := range tools {
				list = append(list, pub{t.Name, t.Description, t.InputSchema})
			}
			respond(req.ID, map[string]any{"tools": list})
		case "tools/call":
			var params struct {
				Name      string         `json:"name"`
				Arguments map[string]any `json:"arguments"`
			}
			if err := json.Unmarshal(req.Params, &params); err != nil {
				errorResp(req.ID, -32602, "invalid params: "+err.Error())
				continue
			}
			h := handlerFor(params.Name)
			if h == nil {
				errorResp(req.ID, -32602, "unknown tool: "+params.Name)
				continue
			}
			args := params.Arguments
			if args == nil {
				args = map[string]any{}
			}
			text, isErr := h(args)
			respond(req.ID, map[string]any{
				"content":  []map[string]any{{"type": "text", "text": text}},
				"isError":  isErr,
			})
		case "shutdown":
			respond(req.ID, map[string]any{})
		default:
			errorResp(req.ID, -32601, "method not found: "+req.Method)
		}
	}
}

func main() {
	serve()
}
