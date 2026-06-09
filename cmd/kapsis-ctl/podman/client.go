//go:build !windows

// Package podman provides a minimal HTTP client for the Podman libpod REST API
// over a Unix socket. It is intentionally stdlib-only and covers only the
// container query and management operations needed by kapsis-ctl.
package podman

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/binary"
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

// ErrAlreadyStopped is returned by Stop when the container was not running
// (Podman returns HTTP 304 Not Modified). Callers should usually treat this as
// success.
var ErrAlreadyStopped = errors.New("container already stopped")

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

// validateContainerPath rejects paths that contain null bytes or line-ending
// characters, which would corrupt the URL query parameter.
func validateContainerPath(p string) error {
	if p == "" {
		return fmt.Errorf("container path is empty")
	}
	for _, c := range p {
		if c == '\x00' || c == '\r' || c == '\n' {
			return fmt.Errorf("container path %q contains invalid character (%U)", p, c)
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

// Stop gracefully stops the named container. Podman sends SIGTERM and waits
// up to timeout seconds before sending SIGKILL — the server handles the
// escalation. Pass timeout < 0 to use the server default (10 s).
//
// Returns nil on success (204 Stopped). Returns ErrAlreadyStopped when the
// container was not running (304 Not Modified); callers should usually treat
// this as success. Returns ErrNotFound (wrapped) when no container with that
// name exists.
func (c *Client) Stop(ctx context.Context, name string, timeout int) error {
	if err := ValidateName(name); err != nil {
		return err
	}
	u := fmt.Sprintf("%s/containers/%s/stop", c.baseURL, url.PathEscape(name))
	if timeout >= 0 {
		u += fmt.Sprintf("?t=%d", timeout)
	}
	resp, err := c.doRequest(ctx, http.MethodPost, u)
	if err != nil {
		return fmt.Errorf("stop %s: %w", name, err)
	}
	defer resp.Body.Close() //nolint:errcheck
	switch resp.StatusCode {
	case http.StatusNoContent: // 204 — stopped
		return nil
	case http.StatusNotModified: // 304 — already stopped
		return ErrAlreadyStopped
	case http.StatusNotFound: // 404
		return fmt.Errorf("%w: %s", ErrNotFound, name)
	default:
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("podman stop returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
}

// LogsOptions controls which log content is returned by Logs.
type LogsOptions struct {
	Follow bool   // stream new lines until the container exits
	Stdout bool   // include stdout frames
	Stderr bool   // include stderr frames
	Tail   int    // last N lines; 0 = all
	Since  string // RFC3339 timestamp or relative duration (e.g. "5m"); empty = beginning
}

// Logs returns an io.ReadCloser that streams log content from the container.
//
// For non-TTY containers the stream uses Docker's multiplexed-frame format:
// each frame is prefixed with an 8-byte header —
// [stream_type(1B)][pad(3B)][size(4B big-endian)] — followed by the payload.
// stream_type 1 = stdout, 2 = stderr. Use DemuxLogs to route frames by stream.
//
// For TTY containers (launched with --tty) the stream is raw bytes; all output
// goes to a single stream without framing. The standard kapsis agent run does
// not use --tty, so multiplexed format is the common case.
//
// The caller must close the returned ReadCloser.
func (c *Client) Logs(ctx context.Context, name string, opts LogsOptions) (io.ReadCloser, error) {
	if err := ValidateName(name); err != nil {
		return nil, err
	}
	params := url.Values{}
	if opts.Follow {
		params.Set("follow", "true")
	}
	if opts.Stdout {
		params.Set("stdout", "true")
	}
	if opts.Stderr {
		params.Set("stderr", "true")
	}
	if opts.Tail > 0 {
		params.Set("tail", fmt.Sprintf("%d", opts.Tail))
	}
	if opts.Since != "" {
		params.Set("since", opts.Since)
	}
	u := fmt.Sprintf("%s/containers/%s/logs", c.baseURL, url.PathEscape(name))
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	resp, err := c.doRequest(ctx, http.MethodGet, u)
	if err != nil {
		return nil, fmt.Errorf("logs %s: %w", name, err)
	}
	switch resp.StatusCode {
	case http.StatusOK:
		return resp.Body, nil
	case http.StatusNotFound:
		resp.Body.Close() //nolint:errcheck
		return nil, fmt.Errorf("%w: %s", ErrNotFound, name)
	default:
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close() //nolint:errcheck
		return nil, fmt.Errorf("podman logs returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
}

// DemuxLogs reads Docker's multiplexed log stream from r and routes stdout
// frames (stream_type=1) to out and stderr frames (stream_type=2) to errOut.
// Frames with other stream types are silently discarded. Returns nil on clean
// EOF; a truncated frame header is also treated as EOF.
//
// This format is used by non-TTY containers. For TTY containers (raw bytes),
// the caller should copy r directly to out.
func DemuxLogs(r io.Reader, out, errOut io.Writer) error {
	hdr := make([]byte, 8)
	for {
		if _, err := io.ReadFull(r, hdr); err != nil {
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				return nil
			}
			return fmt.Errorf("reading log frame header: %w", err)
		}
		streamType := hdr[0]
		frameSize := binary.BigEndian.Uint32(hdr[4:8])

		var dst io.Writer
		switch streamType {
		case 1:
			dst = out
		case 2:
			dst = errOut
		default:
			dst = io.Discard
		}
		if _, err := io.Copy(dst, io.LimitReader(r, int64(frameSize))); err != nil {
			return fmt.Errorf("reading log frame payload: %w", err)
		}
	}
}

// CopyFromContainer extracts the file or directory at containerPath from the
// named container and writes it under hostDest. Podman returns a tar archive
// (raw or gzip-compressed); each entry is extracted with its original mode
// bits. Parent directories in hostDest are created as needed.
//
// Security: extracted paths are validated to prevent zip-slip attacks.
// Absolute tar entry paths and entries that resolve outside hostDest are
// rejected.
func (c *Client) CopyFromContainer(ctx context.Context, name, containerPath, hostDest string) error {
	if err := ValidateName(name); err != nil {
		return err
	}
	if err := validateContainerPath(containerPath); err != nil {
		return err
	}
	u := fmt.Sprintf("%s/containers/%s/archive?path=%s",
		c.baseURL,
		url.PathEscape(name),
		url.QueryEscape(containerPath),
	)
	resp, err := c.doRequest(ctx, http.MethodGet, u)
	if err != nil {
		return fmt.Errorf("cp %s:%s: %w", name, containerPath, err)
	}
	defer resp.Body.Close() //nolint:errcheck
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return fmt.Errorf("%w: %s", ErrNotFound, name)
	default:
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("podman archive returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	return extractTar(io.LimitReader(resp.Body, maxResponseBodyBytes), hostDest)
}

// extractTar unpacks a tar archive (raw or gzip-compressed) under destDir,
// creating destDir if it does not exist.
func extractTar(r io.Reader, destDir string) error {
	if err := os.MkdirAll(destDir, 0o750); err != nil {
		return fmt.Errorf("creating destination directory: %w", err)
	}

	// Peek at the first two bytes to detect gzip magic (0x1f 0x8b).
	buf := make([]byte, 2)
	n, err := io.ReadFull(r, buf)
	if err != nil && err != io.ErrUnexpectedEOF {
		return fmt.Errorf("reading archive header: %w", err)
	}
	combined := io.MultiReader(bytes.NewReader(buf[:n]), r)

	var tr *tar.Reader
	if n == 2 && buf[0] == 0x1f && buf[1] == 0x8b {
		gr, err := gzip.NewReader(combined)
		if err != nil {
			return fmt.Errorf("decompressing archive: %w", err)
		}
		defer gr.Close() //nolint:errcheck
		tr = tar.NewReader(gr)
	} else {
		tr = tar.NewReader(combined)
	}

	destDir = filepath.Clean(destDir)
	prefix := destDir + string(os.PathSeparator)

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("reading tar entry: %w", err)
		}

		// Reject absolute paths (zip-slip class 1).
		if filepath.IsAbs(hdr.Name) {
			return fmt.Errorf("archive entry %q has absolute path; rejected", hdr.Name)
		}
		target := filepath.Clean(filepath.Join(destDir, hdr.Name))
		// Reject paths that resolve outside destDir (zip-slip class 2).
		if target != destDir && !strings.HasPrefix(target+string(os.PathSeparator), prefix) {
			return fmt.Errorf("archive entry %q would escape destination; rejected (zip-slip)", hdr.Name)
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, os.FileMode(hdr.Mode)&0o777|0o700); err != nil {
				return fmt.Errorf("creating directory %s: %w", target, err)
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(target), 0o750); err != nil {
				return fmt.Errorf("creating parent of %s: %w", target, err)
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode)&0o777|0o200)
			if err != nil {
				return fmt.Errorf("creating %s: %w", target, err)
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close() //nolint:errcheck
				return fmt.Errorf("writing %s: %w", target, err)
			}
			if err := f.Close(); err != nil {
				return fmt.Errorf("closing %s: %w", target, err)
			}
		default:
			// Symlinks, devices, FIFOs: out of scope for Phase 2; skip silently.
		}
	}
}

func (c *Client) doRequest(ctx context.Context, method, rawURL string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, rawURL, nil)
	if err != nil {
		return nil, fmt.Errorf("building %s request for %s: %w", method, rawURL, err)
	}
	return c.http.Do(req)
}

func (c *Client) get(ctx context.Context, rawURL string) (*http.Response, error) {
	return c.doRequest(ctx, http.MethodGet, rawURL)
}
