package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"sync"
	"time"

	firecracker "github.com/firecracker-microvm/firecracker-go-sdk"
	models "github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"github.com/sirupsen/logrus"
)

const (
	firecrackerBin = "/usr/local/bin/firecracker"
	kernelImage    = "/tmp/vmlinux"
	baseRootfs     = "/tmp/rootfs.ext4"
	vsockPort      = 52
	bootTimeout    = 60 * time.Second
)

var cids = []uint32{3, 4, 5}

type vmConfig struct {
	cid          uint32
	sockPath     string // Firecracker API socket: /tmp/fc-api-{cid}.sock
	rootfs       string // per-VM CoW rootfs: /tmp/rootfs-vm{cid}.ext4
	vsockPath    string // FC vsock device base path: /tmp/fc-vsock-{cid}.sock
	listenerPath string // host UDS listener: /tmp/fc-vsock-{cid}.sock_52
}

func newVMConfig(cid uint32) vmConfig {
	return vmConfig{
		cid:          cid,
		sockPath:     fmt.Sprintf("/tmp/fc-api-%d.sock", cid),
		rootfs:       fmt.Sprintf("/tmp/rootfs-vm%d.ext4", cid),
		vsockPath:    fmt.Sprintf("/tmp/fc-vsock-%d.sock", cid),
		listenerPath: fmt.Sprintf("/tmp/fc-vsock-%d.sock_%d", cid, vsockPort),
	}
}

// cleanup removes all per-VM socket files and rootfs copies.
// Called before any VM is created (to clear stale state) and after all VMs stop.
func cleanup(cfgs []vmConfig) {
	for _, c := range cfgs {
		for _, p := range []string{c.sockPath, c.rootfs, c.vsockPath, c.listenerPath} {
			os.Remove(p)
		}
	}
}

// copyRootfs copies the base rootfs to a per-VM path.
// Uses cp --reflink=auto for instant CoW on XFS; falls back to io.Copy on other filesystems.
func copyRootfs(cfg vmConfig) error {
	if err := exec.Command("cp", "--reflink=auto", baseRootfs, cfg.rootfs).Run(); err == nil {
		return nil
	}
	src, err := os.Open(baseRootfs)
	if err != nil {
		return fmt.Errorf("open base rootfs: %w", err)
	}
	defer src.Close()
	dst, err := os.Create(cfg.rootfs)
	if err != nil {
		return fmt.Errorf("create vm rootfs: %w", err)
	}
	defer dst.Close()
	if _, err := io.Copy(dst, src); err != nil {
		return fmt.Errorf("copy rootfs data: %w", err)
	}
	return dst.Sync()
}

// acceptOne creates a Unix domain socket listener at listenerPath and accepts exactly one
// connection from the VM. The listener is created synchronously — the socket file exists on
// disk before this function returns — so callers can safely boot VMs afterward without a race.
//
// vsock guest-to-host path: when a guest dials AF_VSOCK(CID=2, port=52), the Firecracker VMM
// connects to <vsockPath>_52 on the host. We listen on that suffixed path, not the base path.
func acceptOne(ctx context.Context, listenerPath string, cid uint32, msgCh chan<- string) (net.Listener, error) {
	os.Remove(listenerPath)
	ln, err := net.Listen("unix", listenerPath)
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", listenerPath, err)
	}
	go func() {
		// Close the listener when the context is cancelled so Accept() unblocks.
		go func() { <-ctx.Done(); ln.Close() }()

		conn, err := ln.Accept()
		if err != nil {
			return // context cancelled or listener closed
		}
		defer conn.Close()

		buf := make([]byte, 256)
		n, _ := conn.Read(buf)
		msgCh <- fmt.Sprintf("CID %d: %s", cid, string(buf[:n]))
	}()
	return ln, nil
}

func bootVM(ctx context.Context, cfg vmConfig, log *logrus.Logger) (*firecracker.Machine, error) {
	fcCfg := firecracker.Config{
		SocketPath:      cfg.sockPath,
		KernelImagePath: kernelImage,
		// cid= is read by the guest-agent from /proc/cmdline.
		// init= makes the guest-agent the Linux init process; on exit the kernel panics,
		// and reboot=k/panic=1 causes Firecracker to halt the VM cleanly.
		KernelArgs: fmt.Sprintf(
			"console=ttyS0 reboot=k panic=1 pci=off cid=%d init=/usr/local/bin/guest-agent",
			cfg.cid,
		),
		Drives: []models.Drive{{
			DriveID:      firecracker.String("rootfs"),
			PathOnHost:   firecracker.String(cfg.rootfs),
			IsRootDevice: firecracker.Bool(true),
			IsReadOnly:   firecracker.Bool(false),
		}},
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  firecracker.Int64(1),
			MemSizeMib: firecracker.Int64(128),
		},
		VsockDevices: []firecracker.VsockDevice{{
			Path: cfg.vsockPath,
			CID:  cfg.cid,
		}},
	}

	cmd := firecracker.VMCommandBuilder{}.
		WithBin(firecrackerBin).
		WithSocketPath(cfg.sockPath).
		Build(ctx)

	m, err := firecracker.NewMachine(ctx, fcCfg,
		firecracker.WithProcessRunner(cmd),
		firecracker.WithLogger(logrus.NewEntry(log)),
	)
	if err != nil {
		return nil, fmt.Errorf("new machine CID %d: %w", cfg.cid, err)
	}

	if err := m.Start(ctx); err != nil {
		return nil, fmt.Errorf("start machine CID %d: %w", cfg.cid, err)
	}
	return m, nil
}

func main() {
	log := logrus.New()
	log.SetFormatter(&logrus.TextFormatter{FullTimestamp: true})

	cfgs := make([]vmConfig, len(cids))
	for i, cid := range cids {
		cfgs[i] = newVMConfig(cid)
	}

	// Remove stale socket files and rootfs copies from any previous (possibly crashed) run.
	cleanup(cfgs)

	// Copy base rootfs for each VM (sequential; IO-bound but not the critical path).
	for _, cfg := range cfgs {
		if err := copyRootfs(cfg); err != nil {
			log.Fatalf("copyRootfs CID %d: %v", cfg.cid, err)
		}
		log.Infof("rootfs ready: %s", cfg.rootfs)
	}

	ctx, cancel := context.WithTimeout(context.Background(), bootTimeout)
	defer cancel()

	msgCh := make(chan string, len(cfgs))
	listeners := make([]net.Listener, len(cfgs))

	// Start all vsock listeners BEFORE booting any VM. The listener socket files must
	// exist on disk when the guest-agent dials or Firecracker cannot connect.
	for i, cfg := range cfgs {
		ln, err := acceptOne(ctx, cfg.listenerPath, cfg.cid, msgCh)
		if err != nil {
			log.Fatalf("acceptOne CID %d: %v", cfg.cid, err)
		}
		listeners[i] = ln
		log.Infof("vsock listener ready: %s", cfg.listenerPath)
	}

	// Boot all 3 VMs in parallel (each m.Start() is an independent Firecracker process).
	machines := make([]*firecracker.Machine, len(cfgs))
	var bootWg sync.WaitGroup
	bootErrCh := make(chan error, len(cfgs))

	for i, cfg := range cfgs {
		bootWg.Add(1)
		go func(idx int, c vmConfig) {
			defer bootWg.Done()
			m, err := bootVM(ctx, c, log)
			if err != nil {
				bootErrCh <- err
				return
			}
			machines[idx] = m
			log.Infof("VM booted: CID %d", c.cid)
		}(i, cfg)
	}
	bootWg.Wait()
	close(bootErrCh)
	for err := range bootErrCh {
		log.Fatalf("boot error: %v", err)
	}

	// Wait for all 3 VMs to phone home.
	log.Info("waiting for VMs to phone home...")
	for range cfgs {
		select {
		case msg := <-msgCh:
			log.Infof("received: %s", msg)
		case <-ctx.Done():
			log.Fatalf("timeout waiting for VM messages after %s", bootTimeout)
		}
	}

	log.Info("=== ALL VMs PHONED HOME ===")

	// Shutdown: StopVMM kills the Firecracker process directly.
	// We do not use ShutdownMachine (ACPI power-off) because the guest-agent is
	// the init process and has no ACPI handler.
	for i, m := range machines {
		if m == nil {
			continue
		}
		if err := m.StopVMM(); err != nil {
			log.Errorf("StopVMM CID %d: %v", cfgs[i].cid, err)
		} else {
			log.Infof("VM stopped: CID %d", cfgs[i].cid)
		}
	}

	for _, ln := range listeners {
		if ln != nil {
			ln.Close()
		}
	}

	cleanup(cfgs)
	log.Info("cleanup complete — exiting")
}
