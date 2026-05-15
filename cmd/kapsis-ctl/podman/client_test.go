package podman

import (
	"strings"
	"testing"
)

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
			// All our test cases should error out before hitting os.Stat.
			if tc.wantErr && err == nil {
				t.Errorf("validateSocketPath(%q): expected error, got nil", tc.input)
			}
		})
	}
}

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
