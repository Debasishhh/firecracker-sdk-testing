// guest-agent is the in-guest vsock server (M1.6).
// It listens on vsock port 52 and handles exec, exec_stream, upload, download,
// and ping requests from the host control plane / sub-agents.
//
// Wire protocol: each message = 4-byte big-endian length prefix + JSON payload.
// For upload, the JSON header is followed immediately by raw file bytes.
// For download, the JSON response is followed immediately by raw file bytes.
//
// Build: GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build ./cmd/guest-agent
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mdlayher/vsock"
)

const (
	listenPort      = 52
	agentVersion    = "0.1.0"
	dockerReadyWait = 60 * time.Second
)

// dockerReady is set true by the background Docker poller once docker info succeeds.
var dockerReady atomic.Bool

// Request is the JSON body of an incoming message.
type Request struct {
	Type string            `json:"type"`
	Cmd  []string          `json:"cmd,omitempty"`
	Cwd  string            `json:"cwd,omitempty"`
	Env  map[string]string `json:"env,omitempty"`
	Path string            `json:"path,omitempty"`
	Size int64             `json:"size,omitempty"`
	Mode uint32            `json:"mode,omitempty"`
}

func writeFrame(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if err := binary.Write(w, binary.BigEndian, uint32(len(b))); err != nil {
		return err
	}
	_, err = w.Write(b)
	return err
}

func readFrame(r io.Reader, v any) error {
	var n uint32
	if err := binary.Read(r, binary.BigEndian, &n); err != nil {
		return err
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return err
	}
	return json.Unmarshal(buf, v)
}

// buildEnv merges os.Environ with the per-request env overrides.
func buildEnv(overrides map[string]string) []string {
	env := os.Environ()
	for k, v := range overrides {
		env = append(env, k+"="+v)
	}
	return env
}

func handlePing(conn io.Writer) {
	writeFrame(conn, map[string]any{
		"ok":           true,
		"version":      agentVersion,
		"docker_ready": dockerReady.Load(),
	})
}

func handleExec(conn io.ReadWriter, req *Request) {
	if len(req.Cmd) == 0 {
		writeFrame(conn, map[string]any{"ok": false, "error": "cmd is empty"})
		return
	}
	cmd := exec.Command(req.Cmd[0], req.Cmd[1:]...)
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	}
	if len(req.Env) > 0 {
		cmd.Env = buildEnv(req.Env)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	exitCode := 0
	errMsg := ""
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			errMsg = err.Error()
		}
	}
	writeFrame(conn, map[string]any{
		"ok":        errMsg == "",
		"stdout":    stdout.String(),
		"stderr":    stderr.String(),
		"exit_code": exitCode,
		"error":     errMsg,
	})
}

func handleExecStream(conn io.ReadWriter, req *Request) {
	if len(req.Cmd) == 0 {
		writeFrame(conn, map[string]any{"type": "error", "message": "cmd is empty"})
		return
	}
	cmd := exec.Command(req.Cmd[0], req.Cmd[1:]...)
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	}
	if len(req.Env) > 0 {
		cmd.Env = buildEnv(req.Env)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		writeFrame(conn, map[string]any{"type": "error", "message": err.Error()})
		return
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		writeFrame(conn, map[string]any{"type": "error", "message": err.Error()})
		return
	}
	if err := cmd.Start(); err != nil {
		writeFrame(conn, map[string]any{"type": "error", "message": err.Error()})
		return
	}

	var mu sync.Mutex
	var wg sync.WaitGroup

	stream := func(kind string, r io.Reader) {
		defer wg.Done()
		buf := make([]byte, 4096)
		for {
			n, err := r.Read(buf)
			if n > 0 {
				mu.Lock()
				writeFrame(conn, map[string]any{"type": kind, "data": string(buf[:n])})
				mu.Unlock()
			}
			if err != nil {
				break
			}
		}
	}

	wg.Add(2)
	go stream("stdout", stdoutPipe)
	go stream("stderr", stderrPipe)
	wg.Wait()

	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		}
	}
	writeFrame(conn, map[string]any{"type": "done", "exit_code": exitCode})
}

func handleUpload(conn io.ReadWriter, req *Request) {
	if req.Path == "" || req.Size < 0 {
		writeFrame(conn, map[string]any{"ok": false, "error": "path or size missing"})
		return
	}
	if err := os.MkdirAll(filepath.Dir(req.Path), 0755); err != nil {
		writeFrame(conn, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	mode := os.FileMode(req.Mode)
	if mode == 0 {
		mode = 0644
	}
	f, err := os.OpenFile(req.Path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		writeFrame(conn, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	defer f.Close()
	// Raw file bytes follow the JSON header directly on the connection.
	if _, err := io.CopyN(f, conn, req.Size); err != nil {
		writeFrame(conn, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeFrame(conn, map[string]any{"ok": true})
}

func handleDownload(conn io.ReadWriter, req *Request) {
	if req.Path == "" {
		writeFrame(conn, map[string]any{"ok": false, "error": "path missing"})
		return
	}
	f, err := os.Open(req.Path)
	if err != nil {
		writeFrame(conn, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		writeFrame(conn, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	// Send header with file size, then raw bytes.
	writeFrame(conn, map[string]any{"ok": true, "size": fi.Size()})
	io.Copy(conn, f)
}

func handle(conn io.ReadWriter) {
	var req Request
	if err := readFrame(conn, &req); err != nil {
		return
	}
	switch req.Type {
	case "ping":
		handlePing(conn)
	case "exec":
		handleExec(conn, &req)
	case "exec_stream":
		handleExecStream(conn, &req)
	case "upload":
		handleUpload(conn, &req)
	case "download":
		handleDownload(conn, &req)
	default:
		writeFrame(conn, map[string]any{"ok": false, "error": "unknown type: " + req.Type})
	}
}

// pollDocker sets dockerReady once `docker info` succeeds. Runs as a goroutine
// so the vsock listener is up immediately and ping responses include docker_ready.
func pollDocker(deadline time.Duration) {
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if exec.Command("docker", "info").Run() == nil {
			dockerReady.Store(true)
			fmt.Println("guest-agent: Docker ready")
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Fprintln(os.Stderr, "guest-agent: warning: Docker not ready within timeout")
}

func main() {
	// Bind vsock FIRST so the host can ping us immediately after boot.
	// Docker readiness is tracked in the background and reported in ping responses.
	ln, err := vsock.Listen(listenPort, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "guest-agent: listen vsock :%d: %v\n", listenPort, err)
		os.Exit(1)
	}
	defer ln.Close()
	fmt.Printf("guest-agent: listening on vsock port %d (version %s)\n", listenPort, agentVersion)

	go pollDocker(dockerReadyWait)

	for {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "guest-agent: accept: %v\n", err)
			continue
		}
		go func() {
			defer conn.Close()
			handle(conn)
		}()
	}
}
