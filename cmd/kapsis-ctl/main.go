// kapsis-ctl is a host-side tool that queries the Podman container runtime via
// the libpod REST API over a Unix socket. It is intended for use by kapsis
// bash scripts and the slack-bot as a more reliable alternative to shelling
// out to the podman(1) CLI for read-only container queries.
//
// This binary MUST NOT be installed inside container images — the Podman socket
// is a host-only resource and mounting it into a container would allow a
// compromised agent to enumerate or inspect sibling containers.
//
// Phase 1 implements three read-only subcommands:
//
//	inspect <name>            print container JSON (state, pid, image, labels)
//	list [--filter k=v]...    print JSON array of containers
//	alive <name>              exit 0 if running, exit 1 if stopped/missing
//
// See docs/K8S-BACKEND.md and issue #266 for the full strangler-fig roadmap.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/aviadshiber/kapsis/ctl/podman"
)

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
		fmt.Println("kapsis-ctl phase-1 (issue #266)")
		return
	}

	client, err := podman.NewClientFromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kapsis-ctl: cannot connect to Podman socket: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	switch subcommand {
	case "inspect":
		os.Exit(cmdInspect(ctx, client, args))
	case "list":
		os.Exit(cmdList(ctx, client, args))
	case "alive":
		os.Exit(cmdAlive(ctx, client, args))
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
		if strings.Contains(err.Error(), "not found") {
			fmt.Fprintf(os.Stderr, "kapsis-ctl inspect: %v\n", err)
			return 3
		}
		fmt.Fprintf(os.Stderr, "kapsis-ctl inspect: %v\n", err)
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

func usage() {
	fmt.Fprintf(os.Stderr, `kapsis-ctl — Podman container query tool (Phase 1, issue #266)

IMPORTANT: This binary is host-side only. Never install inside container images.

Usage:
  kapsis-ctl inspect <name>             print container JSON
  kapsis-ctl list [--filter k=v]...     print JSON array of containers
  kapsis-ctl alive [-v] <name>          exit 0 if running, 1 if not

Environment:
  KAPSIS_PODMAN_SOCKET   override Podman Unix socket path (auto-detected otherwise)

Exit codes for 'inspect':  0=found  1=error  3=not found
Exit codes for 'alive':    0=running  1=stopped/missing  2=usage error

`)
}
