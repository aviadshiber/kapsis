/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package webhook

import (
	"reflect"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

// minimalAR returns a minimal AgentRequest for testing.
func minimalAR() *kapsisv1alpha1.AgentRequest {
	return &kapsisv1alpha1.AgentRequest{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-agent",
			Namespace: "default",
		},
		Spec: kapsisv1alpha1.AgentRequestSpec{
			Agent: kapsisv1alpha1.AgentSpec{
				Type:  "claude-cli",
				Image: "ghcr.io/aviadshiber/kapsis/claude-cli:latest",
			},
		},
	}
}

func TestSplitEnvList(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"  ", nil},
		{"a", []string{"a"}},
		{"a,b,c", []string{"a", "b", "c"}},
		{" a , b ,c ", []string{"a", "b", "c"}},
		{"a b\tc\nd", []string{"a", "b", "c", "d"}},
		{",,a,,", []string{"a"}},
	}
	for _, tc := range cases {
		got := splitEnvList(tc.in)
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("splitEnvList(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func TestNewValidatorFromEnv_Defaults(t *testing.T) {
	t.Setenv(EnvImageAllowlist, "")
	t.Setenv(EnvApprovedServiceAccounts, "")
	t.Setenv(EnvNestedContainerNamespaces, "")

	v := NewValidatorFromEnv()
	if !reflect.DeepEqual(v.ImageAllowlistPatterns, []string{defaultImageAllowlistPrefix}) {
		t.Errorf("expected default image allowlist [%q], got %v", defaultImageAllowlistPrefix, v.ImageAllowlistPatterns)
	}
	if len(v.ApprovedServiceAccounts) != 0 {
		t.Errorf("expected no approved service accounts (validator defaults internally), got %v", v.ApprovedServiceAccounts)
	}
	if len(v.NestedContainerNamespaces) != 0 {
		t.Errorf("expected no approved nested-container namespaces (forbidden by default), got %v", v.NestedContainerNamespaces)
	}

	// With the default config, a request that enables nestedContainers must be rejected.
	ar := minimalAR()
	ar.Spec.Security = &kapsisv1alpha1.SecuritySpec{NestedContainers: true}
	if err := v.Validate(ar); err == nil {
		t.Error("expected nestedContainers=true to be rejected under default (no approved namespaces)")
	}
}

func TestNewValidatorFromEnv_Configured(t *testing.T) {
	t.Setenv(EnvImageAllowlist, "ghcr.io/myorg/, docker.io/myorg/")
	t.Setenv(EnvApprovedServiceAccounts, "kapsis-agent,custom-sa")
	t.Setenv(EnvNestedContainerNamespaces, "trusted-ns")

	v := NewValidatorFromEnv()
	if !reflect.DeepEqual(v.ImageAllowlistPatterns, []string{"ghcr.io/myorg/", "docker.io/myorg/"}) {
		t.Errorf("unexpected image allowlist: %v", v.ImageAllowlistPatterns)
	}
	if !reflect.DeepEqual(v.ApprovedServiceAccounts, []string{"kapsis-agent", "custom-sa"}) {
		t.Errorf("unexpected approved service accounts: %v", v.ApprovedServiceAccounts)
	}
	if !reflect.DeepEqual(v.NestedContainerNamespaces, []string{"trusted-ns"}) {
		t.Errorf("unexpected nested-container namespaces: %v", v.NestedContainerNamespaces)
	}
}

func TestValidate_ExportedWrapper(t *testing.T) {
	v := &AgentRequestValidator{ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"}}
	if err := v.Validate(minimalAR()); err != nil {
		t.Errorf("expected valid request to pass Validate, got: %v", err)
	}

	bad := minimalAR()
	bad.Spec.Agent.Image = "evil.example.com/backdoor:latest"
	if err := v.Validate(bad); err == nil {
		t.Error("expected disallowed image to be rejected by Validate")
	}
}

func TestValidateImage_AllowedPrefix(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for allowed image prefix, got: %v", errs)
	}
}

func TestValidateImage_DisallowedPrefix(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/myorg/"},
	}
	ar := minimalAR()
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.agent.image" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected image validation error for disallowed prefix")
	}
}

func TestValidateImage_EmptyAllowlist_FailClosed(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: nil,
	}
	ar := minimalAR()
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.agent.image" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected image validation error when allowlist is empty (fail-closed)")
	}
}

func TestValidateKAPSIS_EnvName_Rejected(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		Vars: []kapsisv1alpha1.EnvVar{
			{Name: "KAPSIS_BACKEND", Value: "override"},
		},
	}
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.environment.vars[0].name" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected validation error for reserved KAPSIS_BACKEND env var name")
	}
}

func TestValidateEnvName_NonKAPSIS_Passes(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		Vars: []kapsisv1alpha1.EnvVar{
			{Name: "MY_CUSTOM_VAR", Value: "hello"},
		},
	}
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for non-reserved env var name, got: %v", errs)
	}
}

func TestValidateEnvName_KAPSIS_StatusProject_Passes(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		Vars: []kapsisv1alpha1.EnvVar{
			{Name: "KAPSIS_STATUS_PROJECT", Value: "my-project"},
		},
	}
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for non-reserved KAPSIS_ env var, got: %v", errs)
	}
}

func TestValidateConfigMount_ProtectedPath_Rejected(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		ConfigMounts: []kapsisv1alpha1.ConfigMount{
			{Name: "my-cm", MountPath: "/etc/foo"},
		},
	}
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.environment.configMounts[0].mountPath" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected validation error for protected mount path /etc/foo")
	}
}

func TestValidateConfigMount_NormalPath_Passes(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		ConfigMounts: []kapsisv1alpha1.ConfigMount{
			{Name: "my-cm", MountPath: "/app/config"},
		},
	}
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for normal mount path /app/config, got: %v", errs)
	}
}

func TestValidateConfigMount_PathTraversal_Rejected(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		ConfigMounts: []kapsisv1alpha1.ConfigMount{
			{Name: "my-cm", MountPath: "/workspace/../etc/shadow"},
		},
	}
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.environment.configMounts[0].mountPath" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected validation error for path traversal /workspace/../etc/shadow")
	}
}

func TestValidateNestedContainers_ApprovedNamespace_Passes(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns:    []string{"ghcr.io/aviadshiber/kapsis/"},
		NestedContainerNamespaces: []string{"default", "sandbox"},
	}
	ar := minimalAR()
	ar.Spec.Security = &kapsisv1alpha1.SecuritySpec{NestedContainers: true}
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for nestedContainers in approved namespace, got: %v", errs)
	}
}

func TestValidateNestedContainers_UnapprovedNamespace_Rejected(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns:    []string{"ghcr.io/aviadshiber/kapsis/"},
		NestedContainerNamespaces: []string{"sandbox"},
	}
	ar := minimalAR()
	ar.Namespace = "default"
	ar.Spec.Security = &kapsisv1alpha1.SecuritySpec{NestedContainers: true}
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.security.nestedContainers" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected validation error for nestedContainers in unapproved namespace")
	}
}

func TestValidateNestedContainers_NoApprovedNamespaces_Rejected(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns:    []string{"ghcr.io/aviadshiber/kapsis/"},
		NestedContainerNamespaces: nil,
	}
	ar := minimalAR()
	ar.Spec.Security = &kapsisv1alpha1.SecuritySpec{NestedContainers: true}
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.security.nestedContainers" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected validation error for nestedContainers with no approved namespaces")
	}
}

func TestValidateNetworkOpen_WithAnnotation_Passes(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "open"}
	ar.Annotations = map[string]string{
		"kapsis.aviadshiber.github.io/allow-open-network": "true",
	}
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for open mode with annotation, got: %v", errs)
	}
}

func TestValidateNetworkOpen_WithoutAnnotation_Rejected(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "open"}
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.network.mode" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected validation error for open mode without annotation")
	}
}

func TestValidateNetworkOpen_NonOpenMode_Passes(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns: []string{"ghcr.io/aviadshiber/kapsis/"},
	}
	ar := minimalAR()
	ar.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "filtered"}
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for filtered mode, got: %v", errs)
	}
}

func TestValidateServiceAccount_Approved_Passes(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns:  []string{"ghcr.io/aviadshiber/kapsis/"},
		ApprovedServiceAccounts: []string{"kapsis-agent", "custom-sa"},
	}
	ar := minimalAR()
	ar.Spec.Security = &kapsisv1alpha1.SecuritySpec{ServiceAccountName: "custom-sa"}
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for approved service account, got: %v", errs)
	}
}

func TestValidateServiceAccount_Unapproved_Rejected(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns:  []string{"ghcr.io/aviadshiber/kapsis/"},
		ApprovedServiceAccounts: []string{"kapsis-agent"},
	}
	ar := minimalAR()
	ar.Spec.Security = &kapsisv1alpha1.SecuritySpec{ServiceAccountName: "evil-sa"}
	errs := v.validate(ar)
	found := false
	for _, e := range errs {
		if e.Field == "spec.security.serviceAccountName" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected validation error for unapproved service account")
	}
}

func TestValidateServiceAccount_DefaultApproval(t *testing.T) {
	v := &AgentRequestValidator{
		ImageAllowlistPatterns:  []string{"ghcr.io/aviadshiber/kapsis/"},
		ApprovedServiceAccounts: nil, // defaults to {"kapsis-agent"}
	}
	ar := minimalAR()
	// No security spec → uses default kapsis-agent
	errs := v.validate(ar)
	if len(errs) != 0 {
		t.Errorf("expected no errors for default service account, got: %v", errs)
	}
}
