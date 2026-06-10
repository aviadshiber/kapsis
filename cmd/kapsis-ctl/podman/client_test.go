//go:build !windows

package podman

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
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

// makeMuxFrame builds a single Docker multiplexed log frame.
func makeMuxFrame(streamType byte, payload []byte) []byte {
	frame := make([]byte, 8+len(payload))
	frame[0] = streamType
	// bytes 1-3 are zero padding
	binary.BigEndian.PutUint32(frame[4:8], uint32(len(payload)))
	copy(frame[8:], payload)
	return frame
}

// makeTar builds an in-memory tar archive from a map of filename→content.
func makeTar(files map[string][]byte) []byte {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for name, content := range files {
		hdr := &tar.Header{
			Name:     name,
			Mode:     0o644,
			Size:     int64(len(content)),
			Typeflag: tar.TypeReg,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			panic(err)
		}
		if _, err := tw.Write(content); err != nil {
			panic(err)
		}
	}
	tw.Close() //nolint:errcheck
	return buf.Bytes()
}

// makeGzipTar builds a gzip-compressed tar archive.
func makeGzipTar(files map[string][]byte) []byte {
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gw)
	for name, content := range files {
		hdr := &tar.Header{
			Name:     name,
			Mode:     0o644,
			Size:     int64(len(content)),
			Typeflag: tar.TypeReg,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			panic(err)
		}
		if _, err := tw.Write(content); err != nil {
			panic(err)
		}
	}
	tw.Close() //nolint:errcheck
	gw.Close() //nolint:errcheck
	return buf.Bytes()
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
				"Tty":    true,
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
	if !info.Tty {
		t.Error("Tty: got false, want true (Config.Tty should be surfaced)")
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

// ─── Stop ─────────────────────────────────────────────────────────────────────

func TestStop_success(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "expected POST", http.StatusMethodNotAllowed)
			return
		}
		if !strings.Contains(r.URL.Path, "/containers/my-container/stop") {
			http.Error(w, "unexpected path: "+r.URL.Path, http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	if err := c.Stop(ctx, "my-container", 10); err != nil {
		t.Errorf("Stop: expected nil, got %v", err)
	}
}

func TestStop_alreadyStopped(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotModified)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	err := c.Stop(ctx, "my-container", 10)
	if !errors.Is(err, ErrAlreadyStopped) {
		t.Errorf("Stop on stopped container: expected ErrAlreadyStopped, got %v", err)
	}
}

func TestStop_notFound(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	err := c.Stop(ctx, "ghost", 10)
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("Stop on missing container: expected ErrNotFound, got %v", err)
	}
}

func TestStop_serverError(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "internal error", http.StatusInternalServerError)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	err := c.Stop(ctx, "my-container", 10)
	if err == nil {
		t.Fatal("expected error for 500, got nil")
	}
	if errors.Is(err, ErrNotFound) || errors.Is(err, ErrAlreadyStopped) {
		t.Errorf("500 should not map to ErrNotFound or ErrAlreadyStopped, got %v", err)
	}
}

func TestStop_timeoutPassedToServer(t *testing.T) {
	var gotQuery string
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.WriteHeader(http.StatusNoContent)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	if err := c.Stop(ctx, "my-container", 30); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if gotQuery != "t=30" {
		t.Errorf("expected query t=30, got %q", gotQuery)
	}
}

func TestStop_negativeTimeoutOmitsParam(t *testing.T) {
	var gotQuery string
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.WriteHeader(http.StatusNoContent)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	if err := c.Stop(ctx, "my-container", -1); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if gotQuery != "" {
		t.Errorf("expected empty query for timeout<0, got %q", gotQuery)
	}
}

// ─── DemuxLogs ────────────────────────────────────────────────────────────────

func TestDemuxLogs_stdoutFrame(t *testing.T) {
	payload := []byte("hello stdout\n")
	stream := bytes.NewReader(makeMuxFrame(1, payload))

	var out, errOut bytes.Buffer
	if err := DemuxLogs(stream, &out, &errOut); err != nil {
		t.Fatalf("DemuxLogs: %v", err)
	}
	if out.String() != string(payload) {
		t.Errorf("stdout: got %q, want %q", out.String(), payload)
	}
	if errOut.Len() != 0 {
		t.Errorf("stderr should be empty, got %q", errOut.String())
	}
}

func TestDemuxLogs_stderrFrame(t *testing.T) {
	payload := []byte("error message\n")
	stream := bytes.NewReader(makeMuxFrame(2, payload))

	var out, errOut bytes.Buffer
	if err := DemuxLogs(stream, &out, &errOut); err != nil {
		t.Fatalf("DemuxLogs: %v", err)
	}
	if errOut.String() != string(payload) {
		t.Errorf("stderr: got %q, want %q", errOut.String(), payload)
	}
	if out.Len() != 0 {
		t.Errorf("stdout should be empty, got %q", out.String())
	}
}

func TestDemuxLogs_mixedFrames(t *testing.T) {
	var mux bytes.Buffer
	mux.Write(makeMuxFrame(1, []byte("line1-stdout\n")))
	mux.Write(makeMuxFrame(2, []byte("line1-stderr\n")))
	mux.Write(makeMuxFrame(1, []byte("line2-stdout\n")))

	var out, errOut bytes.Buffer
	if err := DemuxLogs(&mux, &out, &errOut); err != nil {
		t.Fatalf("DemuxLogs: %v", err)
	}
	if out.String() != "line1-stdout\nline2-stdout\n" {
		t.Errorf("stdout: got %q", out.String())
	}
	if errOut.String() != "line1-stderr\n" {
		t.Errorf("stderr: got %q", errOut.String())
	}
}

func TestDemuxLogs_unknownStreamTypeDiscarded(t *testing.T) {
	var mux bytes.Buffer
	mux.Write(makeMuxFrame(0, []byte("stdin-ignored\n"))) // stream_type=0 (stdin)
	mux.Write(makeMuxFrame(1, []byte("stdout-visible\n")))

	var out, errOut bytes.Buffer
	if err := DemuxLogs(&mux, &out, &errOut); err != nil {
		t.Fatalf("DemuxLogs: %v", err)
	}
	if out.String() != "stdout-visible\n" {
		t.Errorf("stdout: got %q, want %q", out.String(), "stdout-visible\n")
	}
}

func TestDemuxLogs_emptyStream(t *testing.T) {
	var out, errOut bytes.Buffer
	if err := DemuxLogs(bytes.NewReader(nil), &out, &errOut); err != nil {
		t.Errorf("DemuxLogs on empty stream: expected nil, got %v", err)
	}
}

func TestDemuxLogs_truncatedHeader(t *testing.T) {
	// Only 4 bytes — not a full 8-byte header. Should be treated as clean EOF.
	stream := bytes.NewReader([]byte{0x01, 0x00, 0x00, 0x00})

	var out, errOut bytes.Buffer
	if err := DemuxLogs(stream, &out, &errOut); err != nil {
		t.Errorf("DemuxLogs with truncated header: expected nil (treat as EOF), got %v", err)
	}
}

// ─── Logs ─────────────────────────────────────────────────────────────────────

func TestLogs_returnsMuxStream(t *testing.T) {
	payload := []byte("log line\n")
	muxData := makeMuxFrame(1, payload)

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.URL.Path, "/containers/my-container/logs") {
			http.Error(w, "unexpected path: "+r.URL.Path, http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write(muxData) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	rc, err := c.Logs(ctx, "my-container", LogsOptions{Stdout: true})
	if err != nil {
		t.Fatalf("Logs: %v", err)
	}
	defer rc.Close()

	var out, errOut bytes.Buffer
	if err := DemuxLogs(rc, &out, &errOut); err != nil {
		t.Fatalf("DemuxLogs: %v", err)
	}
	if out.String() != string(payload) {
		t.Errorf("output: got %q, want %q", out.String(), payload)
	}
}

func TestLogs_notFound(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	_, err := c.Logs(ctx, "ghost", LogsOptions{Stdout: true})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("Logs on missing container: expected ErrNotFound, got %v", err)
	}
}

func TestLogs_queryParamsPassedToServer(t *testing.T) {
	var gotQuery string
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.WriteHeader(http.StatusOK)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	opts := LogsOptions{Follow: true, Stdout: true, Stderr: true, Tail: 50}
	rc, err := c.Logs(ctx, "my-container", opts)
	if err != nil {
		t.Fatalf("Logs: %v", err)
	}
	rc.Close() //nolint:errcheck

	for _, want := range []string{"follow=true", "stdout=true", "stderr=true", "tail=50"} {
		if !strings.Contains(gotQuery, want) {
			t.Errorf("expected %q in query %q", want, gotQuery)
		}
	}
}

func TestLogs_followCancelledContext(t *testing.T) {
	frame := makeMuxFrame(1, []byte("streaming line\n"))
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(frame) //nolint:errcheck
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		// Simulate follow mode: keep the stream open until the client goes away.
		<-r.Context().Done()
	})

	c := newTestClient(t, handler)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	rc, err := c.Logs(ctx, "my-container", LogsOptions{Follow: true, Stdout: true})
	if err != nil {
		t.Fatalf("Logs: %v", err)
	}
	defer rc.Close() //nolint:errcheck

	// Cancel (the Ctrl-C / SIGTERM / SIGHUP path in cmdLogs) once DemuxLogs
	// is blocked reading the next frame header.
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	var out, errOut bytes.Buffer
	err = DemuxLogs(rc, &out, &errOut)
	if err == nil {
		t.Fatal("expected an error after context cancellation, got nil")
	}
	// cmdLogs maps context.Canceled to exit 0 — the error chain must stay
	// errors.Is-detectable through DemuxLogs' wrapping.
	if !errors.Is(err, context.Canceled) {
		t.Errorf("expected error wrapping context.Canceled, got: %v", err)
	}
	if out.String() != "streaming line\n" {
		t.Errorf("frames delivered before cancellation should be written; got %q", out.String())
	}
}

// ─── CopyFromContainer ────────────────────────────────────────────────────────

func TestCopyFromContainer_singleFile(t *testing.T) {
	content := []byte("hello from container\n")
	archive := makeTar(map[string][]byte{"output.txt": content})

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.URL.Path, "/containers/my-container/archive") {
			http.Error(w, "unexpected path", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write(archive) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	destDir := t.TempDir()
	if err := c.CopyFromContainer(ctx, "my-container", "/work/output.txt", destDir); err != nil {
		t.Fatalf("CopyFromContainer: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(destDir, "output.txt"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("content: got %q, want %q", got, content)
	}
}

func TestCopyFromContainer_nestedFiles(t *testing.T) {
	files := map[string][]byte{
		"a/b/file1.txt": []byte("file1"),
		"a/file2.txt":   []byte("file2"),
	}
	archive := makeTar(files)

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(archive) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	destDir := t.TempDir()
	if err := c.CopyFromContainer(ctx, "my-container", "/work", destDir); err != nil {
		t.Fatalf("CopyFromContainer: %v", err)
	}

	for relPath, wantContent := range files {
		got, err := os.ReadFile(filepath.Join(destDir, relPath))
		if err != nil {
			t.Errorf("ReadFile %q: %v", relPath, err)
			continue
		}
		if string(got) != string(wantContent) {
			t.Errorf("%q content: got %q, want %q", relPath, got, wantContent)
		}
	}

	// Intermediate directories (no explicit tar entries) must be real
	// directories the owner can traverse and write.
	for _, dir := range []string{"a", "a/b"} {
		info, err := os.Stat(filepath.Join(destDir, dir))
		if err != nil {
			t.Errorf("intermediate dir %q: %v", dir, err)
			continue
		}
		if !info.IsDir() {
			t.Errorf("intermediate path %q is not a directory", dir)
		}
		if info.Mode().Perm()&0o700 != 0o700 {
			t.Errorf("intermediate dir %q mode %o lacks owner rwx", dir, info.Mode().Perm())
		}
	}
}

func TestCopyFromContainer_largerThanJSONCap(t *testing.T) {
	// Regression test: the 16 MB cap that guards JSON responses must NOT be
	// applied to cp tar streams — it used to silently truncate archives.
	content := bytes.Repeat([]byte("x"), 17*1024*1024) // 17 MB > maxResponseBodyBytes
	archive := makeTar(map[string][]byte{"big.bin": content})

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(archive) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	destDir := t.TempDir()
	if err := c.CopyFromContainer(ctx, "my-container", "/work/big.bin", destDir); err != nil {
		t.Fatalf("CopyFromContainer >16MB: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(destDir, "big.bin"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if len(got) != len(content) {
		t.Fatalf("size: got %d bytes, want %d (archive truncated?)", len(got), len(content))
	}
	if !bytes.Equal(got, content) {
		t.Error("content mismatch in extracted >16MB file")
	}
}

func TestCopyFromContainer_gzipCompressed(t *testing.T) {
	content := []byte("compressed content\n")
	archive := makeGzipTar(map[string][]byte{"result.txt": content})

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(archive) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	destDir := t.TempDir()
	if err := c.CopyFromContainer(ctx, "my-container", "/result.txt", destDir); err != nil {
		t.Fatalf("CopyFromContainer gzip: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(destDir, "result.txt"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("content: got %q, want %q", got, content)
	}
}

func TestCopyFromContainer_notFound(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	if err := c.CopyFromContainer(ctx, "ghost", "/work", t.TempDir()); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestCopyFromContainer_zipSlipParentPath(t *testing.T) {
	// tar entry escapes destination via ../
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	hdr := &tar.Header{
		Name:     "../escape.txt",
		Mode:     0o644,
		Size:     5,
		Typeflag: tar.TypeReg,
	}
	tw.WriteHeader(hdr)       //nolint:errcheck
	tw.Write([]byte("oops!")) //nolint:errcheck
	tw.Close()                //nolint:errcheck

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(buf.Bytes()) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	err := c.CopyFromContainer(ctx, "my-container", "/work", t.TempDir())
	if err == nil {
		t.Fatal("expected zip-slip error, got nil")
	}
	if !strings.Contains(err.Error(), "zip-slip") && !strings.Contains(err.Error(), "escape") {
		t.Errorf("expected zip-slip error message, got: %v", err)
	}
}

func TestCopyFromContainer_zipSlipAbsolutePath(t *testing.T) {
	// tar entry with absolute path
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	hdr := &tar.Header{
		Name:     "/etc/shadow",
		Mode:     0o600,
		Size:     4,
		Typeflag: tar.TypeReg,
	}
	tw.WriteHeader(hdr)      //nolint:errcheck
	tw.Write([]byte("root")) //nolint:errcheck
	tw.Close()               //nolint:errcheck

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(buf.Bytes()) //nolint:errcheck
	})

	c := newTestClient(t, handler)
	ctx, cancel := ctx()
	defer cancel()

	err := c.CopyFromContainer(ctx, "my-container", "/etc/shadow", t.TempDir())
	if err == nil {
		t.Fatal("expected error for absolute path in tar, got nil")
	}
	if !strings.Contains(err.Error(), "absolute") {
		t.Errorf("expected absolute-path error message, got: %v", err)
	}
}

// ─── extractTar ───────────────────────────────────────────────────────────────

func TestExtractTar_extractionLimitEnforced(t *testing.T) {
	// Lower the cap so the test does not need a multi-GiB archive.
	old := maxExtractBytes
	maxExtractBytes = 1024
	t.Cleanup(func() { maxExtractBytes = old })

	t.Run("single oversized entry", func(t *testing.T) {
		archive := makeTar(map[string][]byte{"big.bin": bytes.Repeat([]byte("x"), 4096)})
		err := extractTar(bytes.NewReader(archive), t.TempDir(), io.Discard)
		if err == nil {
			t.Fatal("expected extraction-limit error, got nil")
		}
		if !strings.Contains(err.Error(), "extraction limit") {
			t.Errorf("expected extraction-limit error, got: %v", err)
		}
	})

	t.Run("cumulative across entries", func(t *testing.T) {
		archive := makeTar(map[string][]byte{
			"part1.bin": bytes.Repeat([]byte("x"), 600),
			"part2.bin": bytes.Repeat([]byte("x"), 600),
		})
		err := extractTar(bytes.NewReader(archive), t.TempDir(), io.Discard)
		if err == nil {
			t.Fatal("expected cumulative extraction-limit error, got nil")
		}
		if !strings.Contains(err.Error(), "extraction limit") {
			t.Errorf("expected extraction-limit error, got: %v", err)
		}
	})

	t.Run("gzip bomb bounded post-decompression", func(t *testing.T) {
		// 4 KiB of zeros compresses to a few bytes — the cap must apply to
		// the decompressed payload, not the compressed response body.
		archive := makeGzipTar(map[string][]byte{"bomb.bin": make([]byte, 4096)})
		err := extractTar(bytes.NewReader(archive), t.TempDir(), io.Discard)
		if err == nil {
			t.Fatal("expected extraction-limit error for gzip bomb, got nil")
		}
		if !strings.Contains(err.Error(), "extraction limit") {
			t.Errorf("expected extraction-limit error, got: %v", err)
		}
	})
}

func TestExtractTar_skipsUnsupportedEntriesWithWarning(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	// Symlink pointing outside the destination — must not materialise.
	if err := tw.WriteHeader(&tar.Header{
		Name:     "evil-link",
		Linkname: "/etc/passwd",
		Typeflag: tar.TypeSymlink,
		Mode:     0o777,
	}); err != nil {
		t.Fatal(err)
	}
	if err := tw.WriteHeader(&tar.Header{
		Name:     "hard-link",
		Linkname: "kept.txt",
		Typeflag: tar.TypeLink,
		Mode:     0o644,
	}); err != nil {
		t.Fatal(err)
	}
	if err := tw.WriteHeader(&tar.Header{
		Name:     "kept.txt",
		Size:     4,
		Mode:     0o644,
		Typeflag: tar.TypeReg,
	}); err != nil {
		t.Fatal(err)
	}
	tw.Write([]byte("data")) //nolint:errcheck
	tw.Close()               //nolint:errcheck

	destDir := t.TempDir()
	var warnings bytes.Buffer
	if err := extractTar(bytes.NewReader(buf.Bytes()), destDir, &warnings); err != nil {
		t.Fatalf("extractTar: %v", err)
	}

	// Regular file is still extracted.
	got, err := os.ReadFile(filepath.Join(destDir, "kept.txt"))
	if err != nil || string(got) != "data" {
		t.Errorf("kept.txt: got %q, err %v", got, err)
	}
	for _, name := range []string{"evil-link", "hard-link"} {
		// Link entries must NOT materialise on disk (no write-through-link escape).
		if _, err := os.Lstat(filepath.Join(destDir, name)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s should not exist on disk, Lstat err = %v", name, err)
		}
		// The skip must be loud, not silent.
		if !strings.Contains(warnings.String(), name) {
			t.Errorf("expected a warning mentioning %q, got: %q", name, warnings.String())
		}
	}
}

func TestExtractTar_preservesModes(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	if err := tw.WriteHeader(&tar.Header{
		Name:     "ro-dir/",
		Mode:     0o555,
		Typeflag: tar.TypeDir,
	}); err != nil {
		t.Fatal(err)
	}
	content := []byte("read-only")
	if err := tw.WriteHeader(&tar.Header{
		Name:     "ro-dir/ro-file.txt",
		Mode:     0o444,
		Size:     int64(len(content)),
		Typeflag: tar.TypeReg,
	}); err != nil {
		t.Fatal(err)
	}
	tw.Write(content) //nolint:errcheck
	tw.Close()        //nolint:errcheck

	destDir := t.TempDir()
	// Restore owner-write before t.TempDir cleanup tries to remove the tree.
	t.Cleanup(func() {
		os.Chmod(filepath.Join(destDir, "ro-dir"), 0o755) //nolint:errcheck
	})
	if err := extractTar(bytes.NewReader(buf.Bytes()), destDir, io.Discard); err != nil {
		t.Fatalf("extractTar: %v", err)
	}

	dirInfo, err := os.Stat(filepath.Join(destDir, "ro-dir"))
	if err != nil {
		t.Fatalf("Stat ro-dir: %v", err)
	}
	if dirInfo.Mode().Perm() != 0o555 {
		t.Errorf("ro-dir mode: got %o, want 555 (must not gain owner-write)", dirInfo.Mode().Perm())
	}
	fileInfo, err := os.Stat(filepath.Join(destDir, "ro-dir", "ro-file.txt"))
	if err != nil {
		t.Fatalf("Stat ro-file.txt: %v", err)
	}
	if fileInfo.Mode().Perm() != 0o444 {
		t.Errorf("ro-file.txt mode: got %o, want 444 (must not gain owner-write)", fileInfo.Mode().Perm())
	}
	got, err := os.ReadFile(filepath.Join(destDir, "ro-dir", "ro-file.txt"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("content: got %q, want %q", got, content)
	}
}

// ─── validateContainerPath ────────────────────────────────────────────────────

func TestValidateContainerPath(t *testing.T) {
	cases := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{"absolute path", "/work/output.txt", false},
		{"relative path", "work/output.txt", false},
		{"root", "/", false},
		{"empty", "", true},
		{"null byte", "/foo\x00bar", true},
		{"newline", "/foo\nbar", true},
		{"carriage return", "/foo\rbar", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateContainerPath(tc.input)
			if tc.wantErr && err == nil {
				t.Errorf("validateContainerPath(%q): expected error, got nil", tc.input)
			}
			if !tc.wantErr && err != nil {
				t.Errorf("validateContainerPath(%q): unexpected error: %v", tc.input, err)
			}
		})
	}
}
