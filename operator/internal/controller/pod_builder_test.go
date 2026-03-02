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
			Namespace: "default",
		},
		Spec: kapsisv1alpha1.AgentRequestSpec{
			Image: "kapsis-agent:latest",
			Agent: kapsisv1alpha1.AgentSpec{
				Type:    "claude-cli",
				Command: []string{"/bin/agent"},
			},
		},
	}
}

func TestBuildPod_ContainerNameConstant(t *testing.T) {
	cr := minimalCR()
	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	if len(pod.Spec.Containers) != 1 {
		t.Fatalf("expected 1 container, got %d", len(pod.Spec.Containers))
	}
	if pod.Spec.Containers[0].Name != AgentContainerName {
		t.Errorf("container name = %q, want %q", pod.Spec.Containers[0].Name, AgentContainerName)
	}
}

func TestBuildPod_AutomountServiceAccountTokenDisabled(t *testing.T) {
	cr := minimalCR()
	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	if pod.Spec.AutomountServiceAccountToken == nil {
		t.Fatal("AutomountServiceAccountToken is nil, expected non-nil")
	}
	if *pod.Spec.AutomountServiceAccountToken != false {
		t.Errorf("AutomountServiceAccountToken = %v, want false", *pod.Spec.AutomountServiceAccountToken)
	}
}

func TestBuildPod_TaskInlineEnvVar(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Task = &kapsisv1alpha1.TaskSpec{
		Inline: "implement the login feature",
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	found := findEnvVar(pod.Spec.Containers[0].Env, "KAPSIS_TASK")
	if found == nil {
		t.Fatal("KAPSIS_TASK env var not found")
	}
	if found.Value != "implement the login feature" {
		t.Errorf("KAPSIS_TASK = %q, want %q", found.Value, "implement the login feature")
	}
}

func TestBuildPod_TaskInlineEmpty(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Task = &kapsisv1alpha1.TaskSpec{
		Inline: "",
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	found := findEnvVar(pod.Spec.Containers[0].Env, "KAPSIS_TASK")
	if found != nil {
		t.Error("KAPSIS_TASK should not be set when inline is empty")
	}
}

func TestBuildPod_GitEnvVars(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Git = &kapsisv1alpha1.GitSpec{
		Branch:     "feat/login",
		BaseBranch: "develop",
		Push:       true,
		RepoUrl:    "https://github.com/org/repo.git",
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	envs := pod.Spec.Containers[0].Env

	tests := []struct {
		name string
		want string
	}{
		{"KAPSIS_BRANCH", "feat/login"},
		{"KAPSIS_BASE_BRANCH", "develop"},
		{"KAPSIS_DO_PUSH", "true"},
		{"GIT_REPO_URL", "https://github.com/org/repo.git"},
	}

	for _, tt := range tests {
		found := findEnvVar(envs, tt.name)
		if found == nil {
			t.Errorf("env var %s not found", tt.name)
			continue
		}
		if found.Value != tt.want {
			t.Errorf("%s = %q, want %q", tt.name, found.Value, tt.want)
		}
	}
}

func TestBuildPod_GitCredentialSecretRef(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Git = &kapsisv1alpha1.GitSpec{
		Branch: "feat/x",
		CredentialSecretRef: &kapsisv1alpha1.SecretKeyRef{
			Name: "git-creds",
			Key:  "token",
		},
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	found := findEnvVar(pod.Spec.Containers[0].Env, "GIT_CREDENTIAL")
	if found == nil {
		t.Fatal("GIT_CREDENTIAL env var not found")
	}
	if found.ValueFrom == nil {
		t.Fatal("GIT_CREDENTIAL.ValueFrom is nil")
	}
	if found.ValueFrom.SecretKeyRef == nil {
		t.Fatal("GIT_CREDENTIAL.ValueFrom.SecretKeyRef is nil")
	}
	if found.ValueFrom.SecretKeyRef.Name != "git-creds" {
		t.Errorf("SecretKeyRef.Name = %q, want %q", found.ValueFrom.SecretKeyRef.Name, "git-creds")
	}
	if found.ValueFrom.SecretKeyRef.Key != "token" {
		t.Errorf("SecretKeyRef.Key = %q, want %q", found.ValueFrom.SecretKeyRef.Key, "token")
	}
}

func TestBuildPod_SpecConfigMapRef(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Task = &kapsisv1alpha1.TaskSpec{
		SpecConfigMapRef: &kapsisv1alpha1.ConfigMapKeyRef{
			Name: "my-spec-cm",
			Key:  "task.md",
		},
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	// Verify the volume exists.
	var taskVol *corev1.Volume
	for i := range pod.Spec.Volumes {
		if pod.Spec.Volumes[i].Name == "task-spec" {
			taskVol = &pod.Spec.Volumes[i]
			break
		}
	}
	if taskVol == nil {
		t.Fatal("task-spec volume not found")
	}
	if taskVol.ConfigMap == nil {
		t.Fatal("task-spec volume has no ConfigMap source")
	}
	if taskVol.ConfigMap.Name != "my-spec-cm" {
		t.Errorf("ConfigMap name = %q, want %q", taskVol.ConfigMap.Name, "my-spec-cm")
	}
	if len(taskVol.ConfigMap.Items) != 1 || taskVol.ConfigMap.Items[0].Key != "task.md" {
		t.Errorf("ConfigMap items = %v, want key=task.md", taskVol.ConfigMap.Items)
	}

	// Verify the volume mount exists.
	var taskMount *corev1.VolumeMount
	for i := range pod.Spec.Containers[0].VolumeMounts {
		if pod.Spec.Containers[0].VolumeMounts[i].Name == "task-spec" {
			taskMount = &pod.Spec.Containers[0].VolumeMounts[i]
			break
		}
	}
	if taskMount == nil {
		t.Fatal("task-spec volume mount not found")
	}
	if taskMount.MountPath != "/task-spec.md" {
		t.Errorf("MountPath = %q, want %q", taskMount.MountPath, "/task-spec.md")
	}
	if taskMount.SubPath != "task-spec.md" {
		t.Errorf("SubPath = %q, want %q", taskMount.SubPath, "task-spec.md")
	}
	if !taskMount.ReadOnly {
		t.Error("mount should be read-only")
	}
}

func TestBuildPod_SpecConfigMapRefDefaultKey(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Task = &kapsisv1alpha1.TaskSpec{
		SpecConfigMapRef: &kapsisv1alpha1.ConfigMapKeyRef{
			Name: "my-spec-cm",
			// Key intentionally empty — should default to "spec.md"
		},
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	for _, v := range pod.Spec.Volumes {
		if v.Name == "task-spec" && v.ConfigMap != nil {
			if len(v.ConfigMap.Items) == 1 && v.ConfigMap.Items[0].Key == "spec.md" {
				return // success
			}
			t.Fatalf("expected default key 'spec.md', got %v", v.ConfigMap.Items)
		}
	}
	t.Fatal("task-spec volume not found")
}

func TestBuildPod_SecurityServiceAccount(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Security = &kapsisv1alpha1.SecuritySpec{
		Profile:            "standard",
		ServiceAccountName: "my-sa",
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	if pod.Spec.ServiceAccountName != "my-sa" {
		t.Errorf("ServiceAccountName = %q, want %q", pod.Spec.ServiceAccountName, "my-sa")
	}
}

func TestBuildPod_TTLActiveDeadline(t *testing.T) {
	cr := minimalCR()
	ttl := int32(7200)
	cr.Spec.TTL = &ttl

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	if pod.Spec.ActiveDeadlineSeconds == nil {
		t.Fatal("ActiveDeadlineSeconds is nil")
	}
	if *pod.Spec.ActiveDeadlineSeconds != 7200 {
		t.Errorf("ActiveDeadlineSeconds = %d, want 7200", *pod.Spec.ActiveDeadlineSeconds)
	}
}

func TestBuildPod_EnvFromSecretRefs(t *testing.T) {
	cr := minimalCR()
	cr.Spec.Environment = &kapsisv1alpha1.EnvironmentSpec{
		SecretRefs: []kapsisv1alpha1.SecretRef{
			{Name: "secret-a"},
			{Name: "secret-b"},
		},
	}

	pod, err := BuildPod(cr)
	if err != nil {
		t.Fatalf("BuildPod() error: %v", err)
	}

	envFrom := pod.Spec.Containers[0].EnvFrom
	if len(envFrom) != 2 {
		t.Fatalf("envFrom length = %d, want 2", len(envFrom))
	}
	if envFrom[0].SecretRef.Name != "secret-a" {
		t.Errorf("envFrom[0] secret = %q, want %q", envFrom[0].SecretRef.Name, "secret-a")
	}
	if envFrom[1].SecretRef.Name != "secret-b" {
		t.Errorf("envFrom[1] secret = %q, want %q", envFrom[1].SecretRef.Name, "secret-b")
	}
}

// findEnvVar searches for an env var by name.
func findEnvVar(envs []corev1.EnvVar, name string) *corev1.EnvVar {
	for i := range envs {
		if envs[i].Name == name {
			return &envs[i]
		}
	}
	return nil
}
