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

package controller

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

// minimalCR returns a minimal AgentRequest for testing.
func minimalCR() *kapsisv1alpha1.AgentRequest {
	return &kapsisv1alpha1.AgentRequest{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-agent",
			Namespace: "kapsis-test",
		},
		Spec: kapsisv1alpha1.AgentRequestSpec{
			Agent: kapsisv1alpha1.AgentSpec{
				Type:  "claude-cli",
				Image: "ghcr.io/aviadshiber/kapsis/claude-cli:latest",
			},
		},
	}
}

// findEnvVar searches for an env var by name in a container's Env list.
func findEnvVar(envs []corev1.EnvVar, name string) *corev1.EnvVar {
	for i := range envs {
		if envs[i].Name == name {
			return &envs[i]
		}
	}
	return nil
}

// hasVolume returns true if a volume with the given name exists in the list.
func hasVolume(volumes []corev1.Volume, name string) bool {
	for _, v := range volumes {
		if v.Name == name {
			return true
		}
	}
	return false
}

// hasMount returns true if a VolumeMount with the given name exists.
func hasMount(mounts []corev1.VolumeMount, name string) bool {
	for _, m := range mounts {
		if m.Name == name {
			return true
		}
	}
	return false
}

func TestBuildJob_BasicStructure(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	// Job name convention.
	if job.Name != "test-agent-job" {
		t.Errorf("job.Name = %q, want %q", job.Name, "test-agent-job")
	}

	// BackoffLimit must be 0 (no retries).
	if job.Spec.BackoffLimit == nil || *job.Spec.BackoffLimit != 0 {
		t.Errorf("BackoffLimit = %v, want 0", job.Spec.BackoffLimit)
	}

	// RestartPolicy must be Never.
	if job.Spec.Template.Spec.RestartPolicy != corev1.RestartPolicyNever {
		t.Errorf("RestartPolicy = %v, want Never", job.Spec.Template.Spec.RestartPolicy)
	}

	// Two containers: agent + status-sidecar.
	if len(job.Spec.Template.Spec.Containers) != 2 {
		t.Fatalf("expected 2 containers, got %d", len(job.Spec.Template.Spec.Containers))
	}
	if job.Spec.Template.Spec.Containers[0].Name != AgentContainerName {
		t.Errorf("containers[0].name = %q, want %q", job.Spec.Template.Spec.Containers[0].Name, AgentContainerName)
	}
	if job.Spec.Template.Spec.Containers[1].Name != StatusSidecarContainerName {
		t.Errorf("containers[1].name = %q, want %q", job.Spec.Template.Spec.Containers[1].Name, StatusSidecarContainerName)
	}
}

func TestBuildJob_AutomountServiceAccountTokenDisabled(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if job.Spec.Template.Spec.AutomountServiceAccountToken == nil {
		t.Fatal("AutomountServiceAccountToken is nil, expected non-nil")
	}
	if *job.Spec.Template.Spec.AutomountServiceAccountToken != false {
		t.Errorf("AutomountServiceAccountToken = %v, want false", *job.Spec.Template.Spec.AutomountServiceAccountToken)
	}
}

func TestBuildJob_TTLFromSpec(t *testing.T) {
	cr := minimalCR()
	cr.Spec.TTL = 7200

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if job.Spec.ActiveDeadlineSeconds == nil {
		t.Fatal("ActiveDeadlineSeconds is nil")
	}
	if *job.Spec.ActiveDeadlineSeconds != 7200 {
		t.Errorf("ActiveDeadlineSeconds = %d, want 7200", *job.Spec.ActiveDeadlineSeconds)
	}

	// TTLSecondsAfterFinished = min(TTL*2, 14400) = min(14400, 14400) = 14400.
	if job.Spec.TTLSecondsAfterFinished == nil {
		t.Fatal("TTLSecondsAfterFinished is nil")
	}
	if *job.Spec.TTLSecondsAfterFinished != 14400 {
		t.Errorf("TTLSecondsAfterFinished = %d, want 14400", *job.Spec.TTLSecondsAfterFinished)
	}
}

func TestBuildJob_TTLDefaultWhenZero(t *testing.T) {
	cr := minimalCR()
	// TTL is 0 (zero value) → should default to 3600.
	cr.Spec.TTL = 0

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if *job.Spec.ActiveDeadlineSeconds != 3600 {
		t.Errorf("ActiveDeadlineSeconds = %d, want 3600", *job.Spec.ActiveDeadlineSeconds)
	}
}

func TestBuildJob_TTLAfterFinishedCappedAt4Hours(t *testing.T) {
	cr := minimalCR()
	cr.Spec.TTL = 86400 // max allowed; doubled would be 172800, should be capped.

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if *job.Spec.TTLSecondsAfterFinished != 14400 {
		t.Errorf("TTLSecondsAfterFinished = %d, want 14400 (4h cap)", *job.Spec.TTLSecondsAfterFinished)
	}
}

func TestBuildJob_RequiredVolumes(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	vols := job.Spec.Template.Spec.Volumes
	for _, name := range []string{"workspace", "kapsis-status", "kapsis-audit", "tmp", "sidecar-token"} {
		if !hasVolume(vols, name) {
			t.Errorf("required volume %q not found", name)
		}
	}
}

func TestBuildJob_WorkspaceSizeLimitDefault(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	for _, v := range job.Spec.Template.Spec.Volumes {
		if v.Name == "workspace" {
			if v.EmptyDir == nil || v.EmptyDir.SizeLimit == nil {
				t.Fatal("workspace volume has no SizeLimit")
			}
			if v.EmptyDir.SizeLimit.String() != "20Gi" {
				t.Errorf("workspace SizeLimit = %q, want 20Gi", v.EmptyDir.SizeLimit.String())
			}
			return
		}
	}
	t.Fatal("workspace volume not found")
}

func TestBuildJob_WorkspaceSizeLimitCustom(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Resources = &kapsisv1alpha1.ResourceSpec{WorkspaceSizeLimit: "50Gi"}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	for _, v := range job.Spec.Template.Spec.Volumes {
		if v.Name == "workspace" {
			if v.EmptyDir.SizeLimit.String() != "50Gi" {
				t.Errorf("workspace SizeLimit = %q, want 50Gi", v.EmptyDir.SizeLimit.String())
			}
			return
		}
	}
	t.Fatal("workspace volume not found")
}

func TestBuildJob_AgentMountsWorkspace(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	agentMounts := job.Spec.Template.Spec.Containers[0].VolumeMounts
	if !hasMount(agentMounts, "workspace") {
		t.Error("agent container missing workspace mount")
	}
	if !hasMount(agentMounts, "kapsis-status") {
		t.Error("agent container missing kapsis-status mount")
	}
	if !hasMount(agentMounts, "kapsis-audit") {
		t.Error("agent container missing kapsis-audit mount")
	}
}

func TestBuildJob_SidecarMountsSidecarToken(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	sidecarMounts := job.Spec.Template.Spec.Containers[1].VolumeMounts
	if !hasMount(sidecarMounts, "sidecar-token") {
		t.Error("status sidecar missing sidecar-token mount")
	}
	// Sidecar should NOT get the workspace.
	if hasMount(sidecarMounts, "workspace") {
		t.Error("status sidecar should not mount workspace")
	}
}

func TestBuildJob_EnvVarInjectionOrder(t *testing.T) {
	// Security invariant: KAPSIS_* vars must appear AFTER user vars so they cannot be overridden.
	cr := minimalCR()
	cr.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		Vars: []kapsisv1alpha1.EnvVar{
			{Name: "MY_VAR", Value: "user_value"},
		},
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	envs := job.Spec.Template.Spec.Containers[0].Env

	// Find positions.
	myVarIdx := -1
	backendVarIdx := -1
	for i, e := range envs {
		if e.Name == "MY_VAR" {
			myVarIdx = i
		}
		if e.Name == "KAPSIS_BACKEND" {
			backendVarIdx = i
		}
	}

	if myVarIdx == -1 {
		t.Fatal("MY_VAR not found in env vars")
	}
	if backendVarIdx == -1 {
		t.Fatal("KAPSIS_BACKEND not found in env vars")
	}

	// User var must come BEFORE the Kapsis vars.
	if myVarIdx >= backendVarIdx {
		t.Errorf("user var MY_VAR (idx=%d) should come before KAPSIS_BACKEND (idx=%d)", myVarIdx, backendVarIdx)
	}
}

func TestBuildJob_KapsisBackendEnvVar(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	envs := job.Spec.Template.Spec.Containers[0].Env
	if v := findEnvVar(envs, "KAPSIS_BACKEND"); v == nil || v.Value != "k8s" {
		t.Errorf("KAPSIS_BACKEND = %v, want k8s", v)
	}
	if v := findEnvVar(envs, "KAPSIS_AGENT_ID"); v == nil || v.Value != "test-agent" {
		t.Errorf("KAPSIS_AGENT_ID = %v, want test-agent", v)
	}
}

func TestBuildJob_TaskInlineEnvVar(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Task = &kapsisv1alpha1.TaskSpec{
		Inline: "fix the login bug",
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	v := findEnvVar(job.Spec.Template.Spec.Containers[0].Env, "KAPSIS_TASK")
	if v == nil {
		t.Fatal("KAPSIS_TASK not found")
	}
	if v.Value != "fix the login bug" {
		t.Errorf("KAPSIS_TASK = %q, want %q", v.Value, "fix the login bug")
	}
}

func TestBuildJob_GitEnvVars(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Workspace = &kapsisv1alpha1.WorkspaceSpec{
		Git: &kapsisv1alpha1.GitSpec{
			URL:        "https://github.com/org/repo.git",
			Branch:     "feat/login",
			BaseBranch: "develop",
			Push:       true,
		},
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	envs := job.Spec.Template.Spec.Containers[0].Env
	tests := []struct{ name, want string }{
		{"GIT_REPO_URL", "https://github.com/org/repo.git"},
		{"KAPSIS_BRANCH", "feat/login"},
		{"KAPSIS_BASE_BRANCH", "develop"},
		{"KAPSIS_DO_PUSH", "true"},
	}
	for _, tt := range tests {
		v := findEnvVar(envs, tt.name)
		if v == nil {
			t.Errorf("env var %s not found", tt.name)
			continue
		}
		if v.Value != tt.want {
			t.Errorf("%s = %q, want %q", tt.name, v.Value, tt.want)
		}
	}
}

func TestBuildJob_GitCredentialSecretRef(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Workspace = &kapsisv1alpha1.WorkspaceSpec{
		Git: &kapsisv1alpha1.GitSpec{
			URL:                 "https://github.com/org/repo.git",
			CredentialSecretRef: "kapsis-git-creds",
		},
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	v := findEnvVar(job.Spec.Template.Spec.Containers[0].Env, "GIT_TOKEN")
	if v == nil {
		t.Fatal("GIT_TOKEN not found")
	}
	if v.ValueFrom == nil || v.ValueFrom.SecretKeyRef == nil {
		t.Fatal("GIT_TOKEN.ValueFrom.SecretKeyRef is nil")
	}
	if v.ValueFrom.SecretKeyRef.Name != "kapsis-git-creds" {
		t.Errorf("SecretKeyRef.Name = %q, want kapsis-git-creds", v.ValueFrom.SecretKeyRef.Name)
	}
	if v.ValueFrom.SecretKeyRef.Key != "GIT_TOKEN" {
		t.Errorf("SecretKeyRef.Key = %q, want GIT_TOKEN", v.ValueFrom.SecretKeyRef.Key)
	}
}

func TestBuildJob_SpecConfigMapRef(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Task = &kapsisv1alpha1.TaskSpec{
		SpecConfigMapRef: &kapsisv1alpha1.ConfigMapKeyRef{
			Name: "my-spec-cm",
			Key:  "task.md",
		},
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	// Volume must exist.
	if !hasVolume(job.Spec.Template.Spec.Volumes, "task-spec") {
		t.Fatal("task-spec volume not found")
	}

	// Mount must exist on agent container.
	agentMounts := job.Spec.Template.Spec.Containers[0].VolumeMounts
	if !hasMount(agentMounts, "task-spec") {
		t.Fatal("task-spec mount not found on agent container")
	}
}

func TestBuildJob_SpecConfigMapRefDefaultKey(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Task = &kapsisv1alpha1.TaskSpec{
		SpecConfigMapRef: &kapsisv1alpha1.ConfigMapKeyRef{Name: "my-spec-cm"},
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	for _, v := range job.Spec.Template.Spec.Volumes {
		if v.Name == "task-spec" && v.ConfigMap != nil {
			if len(v.ConfigMap.Items) == 1 && v.ConfigMap.Items[0].Key == "spec.md" {
				return // success
			}
			t.Fatalf("expected default key spec.md, got %v", v.ConfigMap.Items)
		}
	}
	t.Fatal("task-spec volume not found")
}

func TestBuildJob_SecurityContextProfiles(t *testing.T) {
	tests := []struct {
		profile          string
		wantReadOnlyRoot bool
	}{
		{"minimal", false},
		{"standard", false},
		{"strict", true},
		{"paranoid", true},
	}

	for _, tt := range tests {
		t.Run(tt.profile, func(t *testing.T) {
			cr := minimalCR()
			cr.Spec.Security = &kapsisv1alpha1.SecuritySpec{Profile: tt.profile}

			job, err := BuildJob(cr, "")
			if err != nil {
				t.Fatalf("BuildJob() error: %v", err)
			}

			sc := job.Spec.Template.Spec.Containers[0].SecurityContext
			if sc == nil {
				t.Fatal("SecurityContext is nil")
			}
			if sc.ReadOnlyRootFilesystem == nil {
				t.Fatal("ReadOnlyRootFilesystem is nil")
			}
			if *sc.ReadOnlyRootFilesystem != tt.wantReadOnlyRoot {
				t.Errorf("ReadOnlyRootFilesystem = %v, want %v", *sc.ReadOnlyRootFilesystem, tt.wantReadOnlyRoot)
			}

			// AllowPrivilegeEscalation must be false for all non-nested profiles.
			if sc.AllowPrivilegeEscalation == nil || *sc.AllowPrivilegeEscalation {
				t.Errorf("AllowPrivilegeEscalation should be false for profile %q", tt.profile)
			}
		})
	}
}

func TestBuildJob_NestedContainers(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Security = &kapsisv1alpha1.SecuritySpec{
		Profile:          "standard",
		NestedContainers: true,
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	// /dev/fuse volume must exist.
	if !hasVolume(job.Spec.Template.Spec.Volumes, "dev-fuse") {
		t.Error("dev-fuse volume not found for nestedContainers=true")
	}
	if !hasVolume(job.Spec.Template.Spec.Volumes, "containers-storage") {
		t.Error("containers-storage volume not found for nestedContainers=true")
	}

	// AllowPrivilegeEscalation must be true for nested containers.
	sc := job.Spec.Template.Spec.Containers[0].SecurityContext
	if sc == nil || sc.AllowPrivilegeEscalation == nil || !*sc.AllowPrivilegeEscalation {
		t.Error("AllowPrivilegeEscalation should be true for nestedContainers=true")
	}

	// AppArmor unconfined annotation must be set.
	key := "container.apparmor.security.beta.kubernetes.io/" + AgentContainerName
	if job.Spec.Template.Annotations[key] != "unconfined" {
		t.Errorf("AppArmor annotation %q = %q, want unconfined", key, job.Spec.Template.Annotations[key])
	}

	// Seccomp must be Unconfined.
	if sc.SeccompProfile == nil || sc.SeccompProfile.Type != corev1.SeccompProfileTypeUnconfined {
		t.Errorf("SeccompProfile.Type = %v, want Unconfined", sc.SeccompProfile)
	}
}

func TestBuildJob_BuildCache(t *testing.T) {
	cr := minimalCR()
	cr.Spec.BuildCache = &kapsisv1alpha1.BuildCacheSpec{
		ClaimRef:  "maven-cache-pvc",
		MountPath: "/root/.m2",
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if !hasVolume(job.Spec.Template.Spec.Volumes, "build-cache") {
		t.Fatal("build-cache volume not found")
	}
	if !hasMount(job.Spec.Template.Spec.Containers[0].VolumeMounts, "build-cache") {
		t.Fatal("build-cache mount not found on agent container")
	}
}

func TestBuildJob_ServiceAccountName(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Security = &kapsisv1alpha1.SecuritySpec{
		ServiceAccountName: "custom-sa",
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if job.Spec.Template.Spec.ServiceAccountName != "custom-sa" {
		t.Errorf("ServiceAccountName = %q, want custom-sa", job.Spec.Template.Spec.ServiceAccountName)
	}
}

func TestBuildJob_DefaultServiceAccount(t *testing.T) {
	cr := minimalCR()

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if job.Spec.Template.Spec.ServiceAccountName != "kapsis-agent" {
		t.Errorf("ServiceAccountName = %q, want kapsis-agent", job.Spec.Template.Spec.ServiceAccountName)
	}
}

func TestBuildJob_ClaudeExitDelayEnvVar(t *testing.T) {
	cr := minimalCR()
	// Agent type is claude-cli — should get the exit-delay workaround env var.

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	v := findEnvVar(job.Spec.Template.Spec.Containers[0].Env, "CLAUDE_CODE_EXIT_AFTER_STOP_DELAY")
	if v == nil {
		t.Fatal("CLAUDE_CODE_EXIT_AFTER_STOP_DELAY not found for claude-cli agent")
	}
}

func TestBuildJob_EnvFromSecretRefs(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		SecretRefs: []kapsisv1alpha1.SecretRef{
			{Name: "secret-a"},
			{Name: "secret-b"},
		},
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	envFrom := job.Spec.Template.Spec.Containers[0].EnvFrom
	if len(envFrom) != 2 {
		t.Fatalf("envFrom len = %d, want 2", len(envFrom))
	}
	if envFrom[0].SecretRef.Name != "secret-a" {
		t.Errorf("envFrom[0] = %q, want secret-a", envFrom[0].SecretRef.Name)
	}
	if envFrom[1].SecretRef.Name != "secret-b" {
		t.Errorf("envFrom[1] = %q, want secret-b", envFrom[1].SecretRef.Name)
	}
}

func TestBuildJob_PodAnnotationsPassthrough(t *testing.T) {
	cr := minimalCR()
	cr.Spec.PodAnnotations = map[string]string{
		"vault.hashicorp.com/agent-inject": "true",
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if job.Spec.Template.Annotations["vault.hashicorp.com/agent-inject"] != "true" {
		t.Error("pod annotation not passed through to job template")
	}
}

func TestBuildJob_RuntimeClass(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Security = &kapsisv1alpha1.SecuritySpec{
		Profile:      "paranoid",
		RuntimeClass: "gvisor",
	}

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	if job.Spec.Template.Spec.RuntimeClassName == nil {
		t.Fatal("RuntimeClassName is nil")
	}
	if *job.Spec.Template.Spec.RuntimeClassName != "gvisor" {
		t.Errorf("RuntimeClassName = %q, want gvisor", *job.Spec.Template.Spec.RuntimeClassName)
	}
}

func TestBuildJob_AuditAlwaysEnabled(t *testing.T) {
	cr := minimalCR()

	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	envs := job.Spec.Template.Spec.Containers[0].Env
	if v := findEnvVar(envs, "KAPSIS_AUDIT_ENABLED"); v == nil || v.Value != "true" {
		t.Errorf("KAPSIS_AUDIT_ENABLED should always be true in K8s mode, got %v", v)
	}
}

func TestJobName(t *testing.T) {
	cr := minimalCR()
	if got := JobName(cr); got != "test-agent-job" {
		t.Errorf("JobName = %q, want test-agent-job", got)
	}
}
