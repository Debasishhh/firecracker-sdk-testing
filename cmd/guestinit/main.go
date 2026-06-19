// guestinit configures guest networking from kernel cmdline parameters then
// execs /sbin/init (systemd). It is designed to run as init= or as a systemd
// one-shot service.
//
// Kernel cmdline parameters (all optional):
//
//	fc.ip=<IP/CIDR>   e.g. fc.ip=10.0.0.2/24
//	fc.gw=<IP>        e.g. fc.gw=10.0.0.1
//	fc.dns=<IP>       e.g. fc.dns=8.8.8.8
//	fc.hostname=<str> e.g. fc.hostname=sandbox-42
//	fc.iface=<str>    e.g. fc.iface=eth0 (default: eth0)
//
// Build: GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build ./cmd/guestinit
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

func parseCmdline() map[string]string {
	data, _ := os.ReadFile("/proc/cmdline")
	params := make(map[string]string)
	for _, field := range strings.Fields(string(data)) {
		k, v, ok := strings.Cut(field, "=")
		if ok {
			params[k] = v
		}
	}
	return params
}

func run(name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "guestinit: %s %v: %v\n", name, args, err)
	}
}

func main() {
	params := parseCmdline()

	iface := "eth0"
	if v := params["fc.iface"]; v != "" {
		iface = v
	}

	run("ip", "link", "set", "lo", "up")

	if ip := params["fc.ip"]; ip != "" {
		run("ip", "addr", "add", ip, "dev", iface)
		run("ip", "link", "set", iface, "up")
	} else {
		run("ip", "link", "set", iface, "up")
	}

	if gw := params["fc.gw"]; gw != "" {
		run("ip", "route", "add", "default", "via", gw, "dev", iface)
	}

	if dns := params["fc.dns"]; dns != "" {
		os.WriteFile("/etc/resolv.conf", []byte("nameserver "+dns+"\n"), 0644)
	}

	if hostname := params["fc.hostname"]; hostname != "" {
		os.WriteFile("/etc/hostname", []byte(hostname+"\n"), 0644)
		run("hostname", hostname)
	}

	// When running as PID 1 (init= kernel arg), hand off to systemd.
	// When running as a systemd service (PID != 1), just exit cleanly.
	if os.Getpid() == 1 {
		if err := syscall.Exec("/sbin/init", []string{"/sbin/init"}, os.Environ()); err != nil {
			fmt.Fprintf(os.Stderr, "guestinit: exec /sbin/init: %v\n", err)
			os.Exit(1)
		}
	}
}
