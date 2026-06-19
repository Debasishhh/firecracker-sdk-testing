// vsock-client is a host-side test tool for the in-guest agent.
// It connects to a Firecracker VM's vsock proxy socket and sends commands.
//
// Usage:
//
//	vsock-client -sock /tmp/fc-vsock-3.sock ping
//	vsock-client -sock /tmp/fc-vsock-3.sock exec -- bash -c "echo hello"
//	vsock-client -sock /tmp/fc-vsock-3.sock stream -- python3 -u /tmp/script.py
//	vsock-client -sock /tmp/fc-vsock-3.sock upload localfile.txt /tmp/remote.txt
//	vsock-client -sock /tmp/fc-vsock-3.sock download /tmp/remote.txt localfile.txt
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
)

var (
	sockFlag = flag.String("sock", "", "path to Firecracker vsock.sock (required)")
	portFlag = flag.Int("port", 52, "guest vsock port")
)

func usage() {
	fmt.Fprintf(os.Stderr, `usage: vsock-client -sock PATH <command> [args]

commands:
  ping
  exec -- <cmd> [args...]
  stream -- <cmd> [args...]
  upload <local-src> <guest-dst>
  download <guest-src> <local-dst>
`)
	os.Exit(2)
}

// connect dials the Firecracker vsock proxy and performs the CONNECT handshake.
func connect(sockPath string, port int) (net.Conn, error) {
	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", sockPath, err)
	}
	fmt.Fprintf(conn, "CONNECT %d\n", port)

	// Read response byte by byte to avoid over-reading with a bufio.Reader.
	var resp []byte
	b := make([]byte, 1)
	for {
		if _, err := io.ReadFull(conn, b); err != nil {
			conn.Close()
			return nil, fmt.Errorf("read handshake: %w", err)
		}
		if b[0] == '\n' {
			break
		}
		resp = append(resp, b[0])
	}
	expected := "OK " + strconv.Itoa(port)
	if string(resp) != expected {
		conn.Close()
		return nil, fmt.Errorf("unexpected handshake response: %q (want %q)", resp, expected)
	}
	return conn, nil
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

func cmdPing(conn net.Conn) int {
	if err := writeFrame(conn, map[string]any{"type": "ping"}); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		return 1
	}
	var resp map[string]any
	if err := readFrame(conn, &resp); err != nil {
		fmt.Fprintln(os.Stderr, "read:", err)
		return 1
	}
	b, _ := json.MarshalIndent(resp, "", "  ")
	fmt.Println(string(b))
	if ok, _ := resp["ok"].(bool); !ok {
		return 1
	}
	return 0
}

func cmdExec(conn net.Conn, args []string) int {
	if err := writeFrame(conn, map[string]any{"type": "exec", "cmd": args}); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		return 1
	}
	var resp map[string]any
	if err := readFrame(conn, &resp); err != nil {
		fmt.Fprintln(os.Stderr, "read:", err)
		return 1
	}
	if s, _ := resp["stdout"].(string); s != "" {
		fmt.Print(s)
	}
	if s, _ := resp["stderr"].(string); s != "" {
		fmt.Fprint(os.Stderr, s)
	}
	if ok, _ := resp["ok"].(bool); !ok {
		if msg, _ := resp["error"].(string); msg != "" {
			fmt.Fprintln(os.Stderr, "error:", msg)
		}
		return 1
	}
	if code, _ := resp["exit_code"].(float64); code != 0 {
		return int(code)
	}
	return 0
}

func cmdStream(conn net.Conn, args []string) int {
	if err := writeFrame(conn, map[string]any{"type": "exec_stream", "cmd": args}); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		return 1
	}
	for {
		var frame map[string]any
		if err := readFrame(conn, &frame); err != nil {
			fmt.Fprintln(os.Stderr, "read:", err)
			return 1
		}
		switch frame["type"] {
		case "stdout":
			fmt.Print(frame["data"])
		case "stderr":
			fmt.Fprint(os.Stderr, frame["data"])
		case "done":
			code, _ := frame["exit_code"].(float64)
			return int(code)
		case "error":
			fmt.Fprintln(os.Stderr, "error:", frame["message"])
			return 1
		}
	}
}

func cmdUpload(conn net.Conn, localPath, remotePath string) int {
	f, err := os.Open(localPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := writeFrame(conn, map[string]any{
		"type": "upload",
		"path": remotePath,
		"size": fi.Size(),
	}); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		return 1
	}
	if _, err := io.Copy(conn, f); err != nil {
		fmt.Fprintln(os.Stderr, "send file:", err)
		return 1
	}
	var resp map[string]any
	if err := readFrame(conn, &resp); err != nil {
		fmt.Fprintln(os.Stderr, "read:", err)
		return 1
	}
	if ok, _ := resp["ok"].(bool); !ok {
		fmt.Fprintln(os.Stderr, "upload failed:", resp["error"])
		return 1
	}
	fmt.Println("uploaded", localPath, "→", remotePath)
	return 0
}

func cmdDownload(conn net.Conn, remotePath, localPath string) int {
	if err := writeFrame(conn, map[string]any{"type": "download", "path": remotePath}); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		return 1
	}
	var resp map[string]any
	if err := readFrame(conn, &resp); err != nil {
		fmt.Fprintln(os.Stderr, "read:", err)
		return 1
	}
	if ok, _ := resp["ok"].(bool); !ok {
		fmt.Fprintln(os.Stderr, "download failed:", resp["error"])
		return 1
	}
	size := int64(resp["size"].(float64))
	f, err := os.Create(localPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer f.Close()
	if _, err := io.CopyN(f, conn, size); err != nil {
		fmt.Fprintln(os.Stderr, "recv file:", err)
		return 1
	}
	fmt.Printf("downloaded %s → %s (%d bytes)\n", remotePath, localPath, size)
	return 0
}

func main() {
	flag.Usage = usage
	flag.Parse()

	if *sockFlag == "" || flag.NArg() == 0 {
		usage()
	}

	conn, err := connect(*sockFlag, *portFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer conn.Close()

	args := flag.Args()
	var rc int
	switch args[0] {
	case "ping":
		rc = cmdPing(conn)
	case "exec":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "exec requires a command after --")
			usage()
		}
		rc = cmdExec(conn, args[1:])
	case "stream":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "stream requires a command after --")
			usage()
		}
		rc = cmdStream(conn, args[1:])
	case "upload":
		if len(args) != 3 {
			fmt.Fprintln(os.Stderr, "usage: upload <local> <remote>")
			usage()
		}
		rc = cmdUpload(conn, args[1], args[2])
	case "download":
		if len(args) != 3 {
			fmt.Fprintln(os.Stderr, "usage: download <remote> <local>")
			usage()
		}
		rc = cmdDownload(conn, args[1], args[2])
	default:
		fmt.Fprintln(os.Stderr, "unknown command:", args[0])
		usage()
	}
	os.Exit(rc)
}
