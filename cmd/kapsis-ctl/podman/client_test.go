//go:build !windows

package podman

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ─── helpers ─────────────────────────────────────────────────────────────────

// newTestClient starts an HTTP server on a temp Unix socket and returns
// a Client wired to it. The server and socket are cleaned up when the test ends.
func newTestClient(t *testing.T, handler http.Handler) *Client {
	t.Helper()
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "test.sock")

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("net.Listen unix: %v", err)
	}
	srv := &http.Server{Handler: handler}
	go srv.Serve(ln) //nolint:errcheck
	t.Cleanup(func() { srv.Close() })

	c, err := NewClientWithSocket(sockPath)
	if err != nil {
		t.Fatalf("NewClientWithSocket: %v", err)
	}
	return c
}

func ctx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}

// ─── Inspect ─────────────────────────────────────────────────────────────────

func TestInspect_success(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/containers/my-container/json") {
			http.Error(w, "unexpected path: "+r.URL.Path, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
			"Id":   "abc123",
			"Name": "/my-container",
			"State": map[string]any{
				"Status": "running",
				"Pid":    42,
			},
			"Created": "2026-01-01T00:00:00Z",
			"Image":   "kapsis-sandbox:latest",
			"Config": map[string]any{
				"Labels": map[string]string{"kapsis.managed": "true"},
				"Env":    []string{"SECRET=hunter2"},
			},
		})
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	info, err := c.Inspect(ctx, "my-container")
	if err != nil {
		t.Fatalf("Inspect: %v", err)
	}
	if info.ID != "abc123" {
		t.Errorf("ID: got %q, want %q", info.ID, "abc123")
	}
	if info.Name != "my-container" {
		t.Errorf("Name: got %q (leading slash should be stripped)", info.Name)
	}
	if info.State != "running" {
		t.Errorf("State: got %q", info.State)
	}
	if info.Pid != 42 {
		t.Errorf("Pid: got %d", info.Pid)
	}
	// Env must NOT appear in output — security.
	raw, _ := json.Marshal(info)
	if strings.Contains(string(raw), "hunter2") {
		t.Error("Env var leaked into Inspect output")
	}
}

func TestInspect_notFound(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	_, err := c.Inspect(ctx, "ghost")
	if err == nil {
		t.Fatal("expected error for 404, got nil")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got: %v", err)
	}
}

func TestInspect_serverError(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "internal error", http.StatusInternalServerError)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	_, err := c.Inspect(ctx, "my-container")
	if err == nil {
		t.Fatal("expected error for 500, got nil")
	}
	if errors.Is(err, ErrNotFound) {
		t.Error("500 should not be ErrNotFound")
	}
}

// ─── List ─────────────────────────────────────────────────────────────────────

func TestList_empty(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("[]")) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	result, err := c.List(ctx, nil)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("expected 0 containers, got %d", len(result))
	}
}

func TestList_withResults(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]map[string]any{ //nolint:errcheck
			{
				"Id":     "aaa",
				"Names":  []string{"/kapsis-agent-1"},
				"Image":  "kapsis-sandbox:latest",
				"State":  "running",
				"Labels": map[string]string{"kapsis.managed": "true"},
			},
			{
				"Id":    "bbb",
				"Names": []string{"/kapsis-agent-2"},
				"Image": "kapsis-sandbox:latest",
				"State": "exited",
			},
		})
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	result, err := c.List(ctx, nil)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(result) != 2 {
		t.Fatalf("expected 2 containers, got %d", len(result))
	}
	if result[0].Name != "kapsis-agent-1" {
		t.Errorf("Name[0]: got %q (leading slash should be stripped)", result[0].Name)
	}
	if result[1].State != "exited" {
		t.Errorf("State[1]: got %q", result[1].State)
	}
}

func TestList_filterPassedToServer(t *testing.T) {
	var gotQuery string
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("[]")) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	filters := map[string][]string{"label": {"kapsis.managed=true"}, "status": {"running"}}
	_, err := c.List(ctx, filters)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if !strings.Contains(gotQuery, "filters=") {
		t.Errorf("expected filters= in query, got %q", gotQuery)
	}
}

// ─── Alive ────────────────────────────────────────────────────────────────────

func TestAlive_running(t *testing.T) {
	c := newTestClient(t, inspectHandlerWithState("running"))
	ctx, cancel := ctx()
	defer cancel()

	alive, err := c.Alive(ctx, "my-container")
	if err != nil {
		t.Fatalf("Alive: %v", err)
	}
	if !alive {
		t.Error("expected alive=true for running container")
	}
}

func TestAlive_paused(t *testing.T) {
	c := newTestClient(t, inspectHandlerWithState("paused"))
	ctx, cancel := ctx()
	defer cancel()

	alive, err := c.Alive(ctx, "my-container")
	if err != nil {
		t.Fatalf("Alive: %v", err)
	}
	if !alive {
		t.Error("expected alive=true for paused container (transient state)")
	}
}

func TestAlive_exited(t *testing.T) {
	c := newTestClient(t, inspectHandlerWithState("exited"))
	ctx, cancel := ctx()
	defer cancel()

	alive, err := c.Alive(ctx, "my-container")
	if err != nil {
		t.Fatalf("Alive: %v", err)
	}
	if alive {
		t.Error("expected alive=false for exited container")
	}
}

func TestAlive_notFound(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	alive, err := c.Alive(ctx, "ghost")
	if err != nil {
		t.Fatalf("Alive on missing container should not error, got: %v", err)
	}
	if alive {
		t.Error("expected alive=false for missing container")
	}
}

// inspectHandlerWithState returns an http.Handler that always responds with a
// container in the given state, used by Alive tests.
func inspectHandlerWithState(state string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
			"Id":      "abc123",
			"Name":    "/my-container",
			"State":   map[string]any{"Status": state, "Pid": 1},
			"Created": "2026-01-01T00:00:00Z",
			"Image":   "kapsis-sandbox:latest",
			"Config":  map[string]any{"Labels": map[string]string{}},
		})
	})
}

// ─── ValidateName ─────────────────────────────────────────────────────────────

func TestValidateName(t *testing.T) {
	cases := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{"plain name", "my-container", false},
		{"with dots", "kapsis-agent.1", false},
		{"alphanumeric", "abc123", false},
		{"underscore", "kapsis_agent_1", false},
		{"max length", strings.Repeat("a", 253), false},
		{"empty", "", true},
		{"dot only", ".", true},
		{"dot dot", "..", true},
		{"path traversal", "../../etc/passwd", true},
		{"slash", "foo/bar", true},
		{"url encoded slash", "foo%2Fbar", true},
		{"space", "foo bar", true},
		{"too long", strings.Repeat("a", 254), true},
		{"newline", "foo\nbar", true},
		{"null byte", "foo\x00bar", true},
		{"colon", "foo:bar", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateName(tc.input)
			if tc.wantErr && err == nil {
				t.Errorf("ValidateName(%q): expected error, got nil", tc.input)
			}
			if !tc.wantErr && err != nil {
				t.Errorf("ValidateName(%q): unexpected error: %v", tc.input, err)
			}
		})
	}
}

// ─── validateSocketPath ───────────────────────────────────────────────────────

func TestValidateSocketPath(t *testing.T) {
	cases := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{"empty", "", true},
		{"relative path", "podman/podman.sock", true},
		{"unclean path with ..", "/run/user/1000/../1000/podman/podman.sock", true},
		{"unclean trailing slash", "/run/user/1000/podman/", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateSocketPath(tc.input)
			if tc.wantErr && err == nil {
				t.Errorf("validateSocketPath(%q): expected error, got nil", tc.input)
			}
		})
	}
}

// ─── ValidateFilters ──────────────────────────────────────────────────────────

func TestValidateFilters(t *testing.T) {
	cases := []struct {
		name    string
		filters map[string][]string
		wantErr bool
	}{
		{"empty", map[string][]string{}, false},
		{"valid label", map[string][]string{"label": {"kapsis.managed=true"}}, false},
		{"valid status", map[string][]string{"status": {"running"}}, false},
		{"valid name", map[string][]string{"name": {"my-container"}}, false},
		{"unknown key", map[string][]string{"badkey": {"foo"}}, true},
		{"label without =", map[string][]string{"label": {"noequalssign"}}, true},
		{"multiple valid", map[string][]string{
			"label":  {"kapsis.managed=true"},
			"status": {"running"},
		}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateFilters(tc.filters)
			if tc.wantErr && err == nil {
				t.Errorf("ValidateFilters(%v): expected error, got nil", tc.filters)
			}
			if !tc.wantErr && err != nil {
				t.Errorf("ValidateFilters(%v): unexpected error: %v", tc.filters, err)
			}
		})
	}
}
