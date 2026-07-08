// kapsis-ctl is a host-side tool that queries and manages Podman containers via
// the libpod REST API over a Unix socket. It is intended for use by kapsis
// bash scripts and the slack-bot as a more reliable alternative to shelling
// out to the podman(1) CLI.
//
// This binary MUST NOT be installed inside container images — the Podman socket
// is a host-only resource and mounting it into a container would allow a
// compromised agent to enumerate or inspect sibling containers.
//
// Phase 1 implements three read-only subcommands (issue #266):
//
//	inspect <name>            print container JSON (state, pid, image, labels)
//	list [--filter k=v]...    print JSON array of containers
//	alive <name>              exit 0 if running, exit 1 if stopped/missing
//
// Phase 2 adds container management subcommands:
//
//	stop [-t N] <name>                    graceful SIGTERM→SIGKILL stop
//	logs [-f] [-n N] [--since TS] <name>  stream container logs (stdout+stderr)
//	cp <name>:<src> <dst-dir>             copy files from container to host
//
// See docs/K8S-BACKEND.md and issue #266 for the full strangler-fig roadmap.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/aviadshiber/kapsis/ctl/podman"
)

// version is stamped at build time via -ldflags "-X main.version=...".
// It defaults to "dev" for local `make build-ctl` builds without ldflags.
var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	subcommand := os.Args[1]
	args := os.Args[2:]

	// Handle informational subcommands before connecting to the socket.
	switch subcommand {
	case "help", "--help", "-h":
		usage()
		return
	case "version", "--version":
		fmt.Printf("kapsis-ctl %s\n", version)
		return
	}

	client, err := podman.NewClientFromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl: cannot connect to Podman socket: %v\n", err)
		os.Exit(1)
	}

	// Phase 1 read-only commands use a shared 10s context.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	switch subcommand {
	case "inspect":
		os.Exit(cmdInspect(ctx, client, args))
	case "list":
		os.Exit(cmdList(ctx, client, args))
	case "alive":
		os.Exit(cmdAlive(ctx, client, args))
	// Phase 2 management commands manage their own contexts.
	case "stop":
		os.Exit(cmdStop(client, args))
	case "logs":
		os.Exit(cmdLogs(client, args))
	case "cp":
		os.Exit(cmdCp(client, args))
	default:
		fmt.Fprintf(os.Stderr, "kapsis-ctl: unknown subcommand %q\n\n", subcommand)
		usage()
		os.Exit(2)
	}
}

// cmdInspect implements `kapsis-ctl inspect <name>`.
// Prints a single ContainerInfo JSON object to stdout.
// Exit codes: 0 = found, 1 = error, 3 = not found.
func cmdInspect(ctx context.Context, client *podman.Client, args []string) int {
	fs := flag.NewFlagSet("inspect", flag.ContinueOnError)
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: kapsis-ctl inspect <container-name>\n")
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fs.Usage()
		return 2
	}
	name := fs.Arg(0)

	info, err := client.Inspect(ctx, name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl inspect: %v\n", err)
		if errors.Is(err, podman.ErrNotFound) {
			return 3
		}
		return 1
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(info); err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl inspect: encoding output: %v\n", err)
		return 1
	}
	return 0
}

// filterFlag is a flag.Value that accumulates --filter k=v pairs.
type filterFlag struct {
	parsed map[string][]string
}

func (f *filterFlag) String() string { return "" }

func (f *filterFlag) Set(val string) error {
	parts := strings.SplitN(val, "=", 2)
	if len(parts) != 2 {
		return fmt.Errorf("--filter %q: expected key=value format", val)
	}
	key, value := parts[0], parts[1]
	if f.parsed == nil {
		f.parsed = make(map[string][]string)
	}
	f.parsed[key] = append(f.parsed[key], value)
	return nil
}

// cmdList implements `kapsis-ctl list [--filter key=value]...`.
// Prints a JSON array of ContainerInfo to stdout. An empty result is [].
// Filters follow the same key=value syntax as podman ps --filter.
//
// Note: unlike `podman ps` (which defaults to running-only), this returns ALL
// containers unless --filter status=running is supplied explicitly.
func cmdList(ctx context.Context, client *podman.Client, args []string) int {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	var filters filterFlag
	fs.Var(&filters, "filter", "filter in key=value form; may be repeated (allowed keys: label, name, status, id)")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: kapsis-ctl list [--filter key=value]...\n\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	result, err := client.List(ctx, filters.parsed)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl list: %v\n", err)
		return 1
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl list: encoding output: %v\n", err)
		return 1
	}
	return 0
}

// cmdAlive implements `kapsis-ctl alive <name>`.
// Silent by design — exit 0 if the container is running, exit 1 otherwise.
// Use in bash: kapsis-ctl alive "$name" || handle_dead_container
func cmdAlive(ctx context.Context, client *podman.Client, args []string) int {
	fs := flag.NewFlagSet("alive", flag.ContinueOnError)
	verbose := fs.Bool("v", false, "print state to stderr")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: kapsis-ctl alive [-v] <container-name>\n")
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fs.Usage()
		return 2
	}
	name := fs.Arg(0)

	running, err := client.Alive(ctx, name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl alive: %v\n", err)
		return 1
	}
	if *verbose {
		if running {
			fmt.Fprintf(os.Stderr, "%s: running\n", name)
		} else {
			fmt.Fprintf(os.Stderr, "%s: not running\n", name)
		}
	}
	if running {
		return 0
	}
	return 1
}

// cmdStop implements `kapsis-ctl stop [-t seconds] <name>`.
//
// Sends SIGTERM to the container; the Podman server waits up to -t seconds
// then sends SIGKILL. This bypasses the SSH tunnel entirely, which is the
// root cause of the hanging `podman rm -f -t 0` bug (issue #266).
//
// Exit codes: 0=stopped (or was already stopped), 1=error, 3=not found.
func cmdStop(client *podman.Client, args []string) int {
	fs := flag.NewFlagSet("stop", flag.ContinueOnError)
	timeout := fs.Int("t", 10, "seconds to wait after SIGTERM before sending SIGKILL")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: kapsis-ctl stop [-t seconds] <container-name>\n\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fs.Usage()
		return 2
	}
	name := fs.Arg(0)
	gracePeriod := *timeout

	// The context must outlive the server-side grace period. Any negative -t
	// means "use the server default" (10 s on libpod); clamp it for the
	// deadline math so e.g. -t -100 cannot produce an already-expired
	// context. The 30 s margin absorbs connection latency (notably the macOS
	// socket forwarder).
	serverGrace := gracePeriod
	if serverGrace < 0 {
		serverGrace = 10
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(serverGrace+30)*time.Second)
	defer cancel()

	err := client.Stop(ctx, name, gracePeriod)
	if err == nil || errors.Is(err, podman.ErrAlreadyStopped) {
		return 0
	}
	fmt.Fprintf(os.Stderr, "kapsis-ctl stop: %v\n", err)
	if errors.Is(err, podman.ErrNotFound) {
		return 3
	}
	return 1
}

// cmdLogs implements `kapsis-ctl logs [-f] [-n N] [--since TS] <name>`.
//
// Streams log output from the container to stdout/stderr. The container is
// inspected first to learn whether it was started with a TTY: non-TTY
// containers (the standard kapsis agent run) emit Docker's multiplexed frame
// format, which is demultiplexed so stdout frames go to stdout and stderr
// frames go to stderr; TTY containers emit raw bytes, which are copied to
// stdout unmodified. The -f flag follows new output until the container exits
// or the process is interrupted (Ctrl-C / SIGTERM / SIGHUP).
//
// Exit codes: 0=success, 1=error, 3=not found.
func cmdLogs(client *podman.Client, args []string) int {
	fs := flag.NewFlagSet("logs", flag.ContinueOnError)
	follow := fs.Bool("f", false, "follow new log output (stream until container exits)")
	tail := fs.Int("n", 0, "show last N lines only (0 = all)")
	since := fs.String("since", "", "show logs since timestamp (RFC3339 or relative, e.g. 5m)")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: kapsis-ctl logs [-f] [-n N] [--since TIMESTAMP] <container-name>\n\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fs.Usage()
		return 2
	}
	name := fs.Arg(0)

	var ctx context.Context
	var cancel context.CancelFunc
	if *follow {
		// Cancel on Ctrl-C / SIGTERM / terminal hangup so the HTTP
		// connection is closed cleanly.
		ctx, cancel = signal.NotifyContext(context.Background(),
			syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	} else {
		// Generous deadline: full-history dumps of long-running agents can
		// be large, and 30 s proved too tight for big -n values.
		ctx, cancel = context.WithTimeout(context.Background(), 5*time.Minute)
	}
	defer cancel()

	// Inspect first to learn whether the container has a TTY. TTY containers
	// emit raw bytes; feeding them through the demultiplexer would interpret
	// log content as frame headers and garble the output.
	inspectCtx, inspectCancel := context.WithTimeout(ctx, 10*time.Second)
	info, err := client.Inspect(inspectCtx, name)
	inspectCancel()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl logs: %v\n", err)
		if errors.Is(err, podman.ErrNotFound) {
			return 3
		}
		return 1
	}

	opts := podman.LogsOptions{
		Follow: *follow,
		Stdout: true,
		Stderr: true,
		Tail:   *tail,
		Since:  *since,
	}

	rc, err := client.Logs(ctx, name, opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl logs: %v\n", err)
		if errors.Is(err, podman.ErrNotFound) {
			return 3
		}
		return 1
	}
	defer rc.Close() //nolint:errcheck

	if info.Tty {
		_, err = io.Copy(os.Stdout, rc)
	} else {
		err = podman.DemuxLogs(rc, os.Stdout, os.Stderr)
	}
	if err != nil {
		// Context cancellation (Ctrl-C in follow mode) is not an error.
		if errors.Is(err, context.Canceled) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "kapsis-ctl logs: %v\n", err)
		return 1
	}
	return 0
}

// cmdCp implements `kapsis-ctl cp <name>:<container-path> <host-dest-dir>`.
//
// Extracts a file or directory from the named container and writes it under
// the host destination directory (unlike podman cp, the destination is always
// treated as a directory and created if missing). Uses the Podman archive
// (tar) API — no SSH required. Zip-slip protection is applied to all tar
// entries.
//
// Exit codes: 0=success, 1=error, 3=not found.
func cmdCp(client *podman.Client, args []string) int {
	fs := flag.NewFlagSet("cp", flag.ContinueOnError)
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: kapsis-ctl cp <name>:<container-path> <host-dest-dir>\n")
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 2 {
		fs.Usage()
		return 2
	}
	src := fs.Arg(0) // name:path
	hostDest := fs.Arg(1)

	colonIdx := strings.Index(src, ":")
	if colonIdx < 0 {
		fmt.Fprintf(os.Stderr, "kapsis-ctl cp: source must be <name>:<path>, got %q\n", src)
		return 2
	}
	name := src[:colonIdx]
	containerPath := src[colonIdx+1:]
	if containerPath == "" {
		fmt.Fprintf(os.Stderr, "kapsis-ctl cp: container path in %q is empty\n", src)
		return 2
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if err := client.CopyFromContainer(ctx, name, containerPath, hostDest); err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl cp: %v\n", err)
		if errors.Is(err, podman.ErrNotFound) {
			return 3
		}
		return 1
	}
	return 0
}

func usage() {
	fmt.Fprintf(os.Stderr, `kapsis-ctl — Podman container tool (Phase 1+2, issue #266)

IMPORTANT: This binary is host-side only. Never install inside container images.

Phase 1 — read-only queries:
  kapsis-ctl inspect <name>             print container JSON
  kapsis-ctl list [--filter k=v]...     print JSON array of containers
  kapsis-ctl alive [-v] <name>          exit 0 if running, 1 if not

Phase 2 — container management:
  kapsis-ctl stop [-t N] <name>                    graceful SIGTERM→SIGKILL stop
  kapsis-ctl logs [-f] [-n N] [--since TS] <name>  stream stdout+stderr log output
  kapsis-ctl cp <name>:<src> <dst-dir>             copy files from container into host dir

Environment:
  KAPSIS_PODMAN_SOCKET   override Podman Unix socket path (auto-detected otherwise)

Exit codes for 'inspect':  0=found  1=error  2=usage error  3=not found
Exit codes for 'alive':    0=running  1=stopped/missing  2=usage error
Exit codes for 'stop':     0=stopped  1=error  2=usage error  3=not found
Exit codes for 'logs':     0=success  1=error  2=usage error  3=not found
Exit codes for 'cp':       0=success  1=error  2=usage error  3=not found

`)
}
