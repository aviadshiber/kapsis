//go:build !windows

// Package podman provides a minimal HTTP client for the Podman libpod REST API
// over a Unix socket. It is intentionally stdlib-only and covers only the
// read-only container query operations needed by Phase 1 of kapsis-ctl.
package podman

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// apiVersion is the libpod API version string used in request paths.
const apiVersion = "v5.0.0"

// maxResponseBodyBytes caps response reads to guard against a runaway/malicious
// Podman API sending an unbounded body that could OOM the host.
const maxResponseBodyBytes = 16 * 1024 * 1024 // 16 MB

// ErrNotFound is returned by Inspect (and transitively by Alive) when the
// named container does not exist. Use errors.Is to distinguish it from other
// errors such as a broken socket connection.
var ErrNotFound = errors.New("container not found")

// nameRE validates container names: alphanumeric, dash, dot, underscore, max 253 chars.
// This prevents path traversal and HTTP request smuggling when the name is
// interpolated into a URL path segment.
var nameRE = regexp.MustCompile(`^[a-zA-Z0-9_.\-]{1,253}$`)

// allowedFilterKeys is the set of filter keys accepted by the List command.
// Unknown keys are rejected to prevent unexpected API behaviour.
var allowedFilterKeys = map[string]bool{
	"label":  true,
	"name":   true,
	"status": true,
	"id":     true,
}

// ContainerInfo is the normalised output type for all kapsis-ctl subcommands.
// Field names are lower-case for consistent jq consumption from bash scripts.
//
// Security note: Config.Env is intentionally absent — container env vars
// routinely contain API keys and tokens; opt-in output is left for a future
// --show-env flag. Labels are included as-is; callers should be aware that
// some CI tooling stores credentials in container labels. The kapsis codebase
// uses only "kapsis.*"-prefixed labels on its own containers.
type ContainerInfo struct {
	ID      string            `json:"id"`
	Name    string            `json:"name"`
	State   string            `json:"state"`
	Pid     int               `json:"pid,omitempty"`
	Created string            `json:"created"`
	Image   string            `json:"image"`
	Labels  map[string]string `json:"labels,omitempty"`
}

// Client wraps an http.Client pre-configured to dial the Podman Unix socket.
type Client struct {
	http    *http.Client
	baseURL string
}

// NewClientFromEnv discovers the Podman socket and returns a ready Client.
// The KAPSIS_PODMAN_SOCKET environment variable overrides auto-detection.
func NewClientFromEnv() (*Client, error) {
	socketPath, err := discoverSocket()
	if err != nil {
		return nil, err
	}
	return newClient(socketPath)
}

// NewClientWithSocket returns a Client that dials the given socket path.
func NewClientWithSocket(socketPath string) (*Client, error) {
	return newClient(socketPath)
}

func newClient(socketPath string) (*Client, error) {
	if err := validateSocketPath(socketPath); err != nil {
		return nil, err
	}
	sp := socketPath
	httpClient := &http.Client{
		// No client-level Timeout: callers pass a context with their own deadline.
		// Dialer.Timeout covers the connection-establishment phase only.
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "unix", sp)
			},
			// Disable keep-alives: each CLI invocation is a single request.
			DisableKeepAlives: true,
		},
	}
	return &Client{
		http:    httpClient,
		baseURL: "http://d/" + apiVersion + "/libpod",
	}, nil
}

// discoverSocket returns the first Podman Unix socket found on the host.
//
// Discovery order:
//  1. KAPSIS_PODMAN_SOCKET env var (explicit override)
//  2. $XDG_RUNTIME_DIR/podman/podman.sock  (Linux rootless standard)
//  3. ~/.local/share/containers/podman/machine/{podman,qemu,applehv}/podman.sock (macOS)
//  4. /run/user/<uid>/podman/podman.sock   (Linux rootless uid fallback)
//
// The /tmp/podman-run-<uid> path is intentionally excluded: /tmp is
// world-writable and a local attacker could pre-create a socket there to
// intercept or forge Podman API responses.
func discoverSocket() (string, error) {
	if s := os.Getenv("KAPSIS_PODMAN_SOCKET"); s != "" {
		return s, nil
	}

	var candidates []string

	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		candidates = append(candidates, filepath.Join(xdg, "podman", "podman.sock"))
	}

	if home, err := os.UserHomeDir(); err == nil {
		machineBase := filepath.Join(home, ".local", "share", "containers", "podman", "machine")
		// Podman 4/5 on macOS places the socket in a hypervisor-specific subdirectory;
		// check the bare machine dir first for future versions or symlinks.
		candidates = append(candidates,
			filepath.Join(machineBase, "podman.sock"),
			filepath.Join(machineBase, "qemu", "podman.sock"),
			filepath.Join(machineBase, "applehv", "podman.sock"),
		)
	}

	uid := fmt.Sprintf("%d", os.Getuid())
	candidates = append(candidates,
		filepath.Join("/run/user", uid, "podman", "podman.sock"),
	)

	for _, p := range candidates {
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		if info.Mode()&os.ModeSocket != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf(
		"podman socket not found; set KAPSIS_PODMAN_SOCKET or ensure podman machine is running",
	)
}

// validateSocketPath rejects non-absolute, unclean, or non-socket paths to
// prevent KAPSIS_PODMAN_SOCKET injection attacks.
func validateSocketPath(p string) error {
	if p == "" {
		return fmt.Errorf("socket path is empty")
	}
	if !filepath.IsAbs(p) {
		return fmt.Errorf("socket path %q must be absolute", p)
	}
	if clean := filepath.Clean(p); clean != p {
		return fmt.Errorf("socket path %q is not clean (got %q after Clean)", p, clean)
	}
	info, err := os.Stat(p)
	if err != nil {
		return fmt.Errorf("socket path %q: %w", p, err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("path %q is not a Unix socket (mode %s)", p, info.Mode())
	}
	return nil
}

// ValidateName returns an error if name contains characters that could cause
// path traversal or HTTP request smuggling when embedded in a URL path.
func ValidateName(name string) error {
	// Explicitly reject dot-only names before the regex check.
	// Both "." and ".." pass [a-zA-Z0-9_.-] and url.PathEscape does not
	// encode them, which could produce /containers/./json or /containers/../json.
	if name == "." || name == ".." {
		return fmt.Errorf("invalid container name %q: reserved path component", name)
	}
	if !nameRE.MatchString(name) {
		return fmt.Errorf(
			"invalid container name %q: must match [a-zA-Z0-9_.-]{1,253}",
			name,
		)
	}
	return nil
}

// ValidateFilters returns an error if any filter key is not in the allowlist
// or if a label value does not match the expected key=value format.
func ValidateFilters(filters map[string][]string) error {
	for key, vals := range filters {
		if !allowedFilterKeys[key] {
			return fmt.Errorf("filter key %q is not allowed; permitted: label, name, status, id", key)
		}
		if key == "label" {
			for _, v := range vals {
				if !strings.Contains(v, "=") {
					return fmt.Errorf("label filter %q must be in key=value format", v)
				}
			}
		}
	}
	return nil
}

// Inspect returns normalised information about a single container.
// Returns ErrNotFound (wrapped) when the container does not exist.
func (c *Client) Inspect(ctx context.Context, name string) (*ContainerInfo, error) {
	if err := ValidateName(name); err != nil {
		return nil, err
	}
	u := fmt.Sprintf("%s/containers/%s/json", c.baseURL, url.PathEscape(name))
	resp, err := c.get(ctx, u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck

	switch resp.StatusCode {
	case http.StatusNotFound:
		return nil, fmt.Errorf("%w: %s", ErrNotFound, name)
	case http.StatusOK:
	default:
		return nil, fmt.Errorf("podman API returned %s", resp.Status)
	}

	var raw struct {
		ID    string `json:"Id"`
		Name  string `json:"Name"`
		State struct {
			Status string `json:"Status"`
			Pid    int    `json:"Pid"`
		} `json:"State"`
		Created string `json:"Created"`
		Image   string `json:"Image"`
		Config  struct {
			Labels map[string]string `json:"Labels"`
			// Env intentionally omitted — may contain API keys and tokens.
		} `json:"Config"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxResponseBodyBytes)).Decode(&raw); err != nil {
		return nil, fmt.Errorf("decoding inspect response: %w", err)
	}

	return &ContainerInfo{
		ID:      raw.ID,
		Name:    strings.TrimPrefix(raw.Name, "/"),
		State:   raw.State.Status,
		Pid:     raw.State.Pid,
		Created: raw.Created,
		Image:   raw.Image,
		Labels:  raw.Config.Labels,
	}, nil
}

// List returns containers matching the given filters. An empty filters map
// returns all containers (equivalent to `podman ps --all`). Pass
// {"status": ["running"]} to match `podman ps` default behaviour.
func (c *Client) List(ctx context.Context, filters map[string][]string) ([]ContainerInfo, error) {
	if err := ValidateFilters(filters); err != nil {
		return nil, err
	}

	u := c.baseURL + "/containers/json"
	if len(filters) > 0 {
		filterJSON, err := json.Marshal(filters)
		if err != nil {
			return nil, fmt.Errorf("marshaling filters: %w", err)
		}
		u += "?" + url.Values{"filters": {string(filterJSON)}}.Encode()
	}

	resp, err := c.get(ctx, u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("podman API returned %s", resp.Status)
	}

	var raw []struct {
		ID     string            `json:"Id"`
		Names  []string          `json:"Names"`
		Image  string            `json:"Image"`
		State  string            `json:"State"`
		Labels map[string]string `json:"Labels"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxResponseBodyBytes)).Decode(&raw); err != nil {
		return nil, fmt.Errorf("decoding list response: %w", err)
	}

	result := make([]ContainerInfo, 0, len(raw))
	for _, r := range raw {
		name := ""
		if len(r.Names) > 0 {
			name = strings.TrimPrefix(r.Names[0], "/")
		}
		result = append(result, ContainerInfo{
			ID:     r.ID,
			Name:   name,
			State:  r.State,
			Image:  r.Image,
			Labels: r.Labels,
		})
	}
	return result, nil
}

// aliveStates is the set of container states that kapsis-ctl alive considers
// "alive". Running is the primary state; paused and restarting are transient
// states during podman pause/restart operations and should not be treated as
// dead during brief polling windows.
var aliveStates = map[string]bool{
	"running":    true,
	"paused":     true,
	"restarting": true,
}

// Alive reports whether a container is in an alive state (running, paused, or
// restarting). It uses Inspect rather than the /exists endpoint because /exists
// returns true for containers in any state including exited.
// Returns false (not an error) when the container does not exist.
func (c *Client) Alive(ctx context.Context, name string) (bool, error) {
	info, err := c.Inspect(ctx, name)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	return aliveStates[info.State], nil
}

func (c *Client) get(ctx context.Context, rawURL string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, fmt.Errorf("building request for %s: %w", rawURL, err)
	}
	return c.http.Do(req)
}
