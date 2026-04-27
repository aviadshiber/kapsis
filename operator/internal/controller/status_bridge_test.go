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

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

func TestBridgeStatusFromJob_Complete(t *testing.T) {
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: "test-job"},
		Status: batchv1.JobStatus{
			Conditions: []batchv1.JobCondition{
				{Type: batchv1.JobComplete, Status: corev1.ConditionTrue},
			},
		},
	}
	status := BridgeStatusFromJob(job)
	if status.Phase != kapsisv1alpha1.PhaseComplete {
		t.Errorf("Phase = %q, want %q", status.Phase, kapsisv1alpha1.PhaseComplete)
	}
}

func TestBridgeStatusFromJob_Failed(t *testing.T) {
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: "test-job"},
		Status: batchv1.JobStatus{
			Conditions: []batchv1.JobCondition{
				{Type: batchv1.JobFailed, Status: corev1.ConditionTrue},
			},
		},
	}
	status := BridgeStatusFromJob(job)
	if status.Phase != kapsisv1alpha1.PhaseFailed {
		t.Errorf("Phase = %q, want %q", status.Phase, kapsisv1alpha1.PhaseFailed)
	}
}

func TestBridgeStatusFromJob_Active(t *testing.T) {
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: "test-job"},
		Status: batchv1.JobStatus{
			Active: 1,
		},
	}
	status := BridgeStatusFromJob(job)
	if status.Phase != kapsisv1alpha1.PhaseRunning {
		t.Errorf("Phase = %q, want %q", status.Phase, kapsisv1alpha1.PhaseRunning)
	}
}

func TestBridgeStatusFromJob_Starting(t *testing.T) {
	now := metav1.Now()
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: "test-job"},
		Status: batchv1.JobStatus{
			StartTime: &now,
			Active:    0,
		},
	}
	status := BridgeStatusFromJob(job)
	if status.Phase != kapsisv1alpha1.PhaseInitializing {
		t.Errorf("Phase = %q, want %q", status.Phase, kapsisv1alpha1.PhaseInitializing)
	}
}

func TestBridgeStatusFromJob_Pending(t *testing.T) {
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: "test-job"},
		Status:     batchv1.JobStatus{},
	}
	status := BridgeStatusFromJob(job)
	if status.Phase != kapsisv1alpha1.PhasePending {
		t.Errorf("Phase = %q, want %q", status.Phase, kapsisv1alpha1.PhasePending)
	}
}

func TestBridgeStatusFromJob_JobName(t *testing.T) {
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: "my-special-job"},
		Status:     batchv1.JobStatus{},
	}
	status := BridgeStatusFromJob(job)
	if status.JobName != "my-special-job" {
		t.Errorf("JobName = %q, want %q", status.JobName, "my-special-job")
	}
}

func TestBridgeStatusFromPod_AnnotationBridging(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-pod",
			Annotations: map[string]string{
				AnnotationGist:            "Working on feature X",
				AnnotationMessage:         "Building project",
				AnnotationProgress:        "42",
				AnnotationCommitSha:       "abc123",
				AnnotationPush:            "success",
				AnnotationPrURL:           "https://github.com/org/repo/pull/1",
				AnnotationPushFallbackCmd: "git push -u origin feat",
			},
		},
	}
	status := &kapsisv1alpha1.AgentRequestStatus{
		Phase: kapsisv1alpha1.PhaseRunning,
	}
	BridgeStatusFromPod(pod, status)

	if status.PodName != "test-pod" {
		t.Errorf("PodName = %q, want %q", status.PodName, "test-pod")
	}
	if status.Gist != "Working on feature X" {
		t.Errorf("Gist = %q, want %q", status.Gist, "Working on feature X")
	}
	if status.Message != "Building project" {
		t.Errorf("Message = %q, want %q", status.Message, "Building project")
	}
	if status.Progress != 42 {
		t.Errorf("Progress = %d, want 42", status.Progress)
	}
	if status.CommitSha != "abc123" {
		t.Errorf("CommitSha = %q, want %q", status.CommitSha, "abc123")
	}
	if status.PushStatus != "success" {
		t.Errorf("PushStatus = %q, want %q", status.PushStatus, "success")
	}
	if status.PrUrl != "https://github.com/org/repo/pull/1" {
		t.Errorf("PrUrl = %q, want %q", status.PrUrl, "https://github.com/org/repo/pull/1")
	}
	if status.PushFallbackCommand != "git push -u origin feat" {
		t.Errorf("PushFallbackCommand = %q, want %q", status.PushFallbackCommand, "git push -u origin feat")
	}
}

func TestBridgeStatusFromPod_MissingAnnotations_NoOp(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-pod",
		},
	}
	status := &kapsisv1alpha1.AgentRequestStatus{
		Phase: kapsisv1alpha1.PhaseRunning,
	}
	// Should not panic with nil annotations.
	BridgeStatusFromPod(pod, status)

	if status.PodName != "test-pod" {
		t.Errorf("PodName = %q, want %q", status.PodName, "test-pod")
	}
	if status.Gist != "" {
		t.Errorf("Gist = %q, want empty", status.Gist)
	}
}

func TestBridgeStatusFromPod_PostProcessingOverride_FromRunning(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-pod",
			Annotations: map[string]string{
				AnnotationPhase: string(kapsisv1alpha1.PhasePostProcessing),
			},
		},
	}
	status := &kapsisv1alpha1.AgentRequestStatus{
		Phase: kapsisv1alpha1.PhaseRunning,
	}
	BridgeStatusFromPod(pod, status)

	if status.Phase != kapsisv1alpha1.PhasePostProcessing {
		t.Errorf("Phase = %q, want %q", status.Phase, kapsisv1alpha1.PhasePostProcessing)
	}
}

func TestBridgeStatusFromPod_PostProcessingOverride_FromInitializing(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-pod",
			Annotations: map[string]string{
				AnnotationPhase: string(kapsisv1alpha1.PhasePostProcessing),
			},
		},
	}
	status := &kapsisv1alpha1.AgentRequestStatus{
		Phase: kapsisv1alpha1.PhaseInitializing,
	}
	BridgeStatusFromPod(pod, status)

	if status.Phase != kapsisv1alpha1.PhasePostProcessing {
		t.Errorf("Phase = %q, want %q (override from Initializing)", status.Phase, kapsisv1alpha1.PhasePostProcessing)
	}
}

func TestBridgeStatusFromPod_ExitCodeFromTerminatedContainer(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "test-pod"},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{
				{
					Name: AgentContainerName,
					State: corev1.ContainerState{
						Terminated: &corev1.ContainerStateTerminated{
							ExitCode: 42,
						},
					},
				},
			},
		},
	}
	status := &kapsisv1alpha1.AgentRequestStatus{
		Phase: kapsisv1alpha1.PhaseComplete,
	}
	BridgeStatusFromPod(pod, status)

	if status.ExitCode == nil {
		t.Fatal("ExitCode is nil, expected non-nil")
	}
	if *status.ExitCode != 42 {
		t.Errorf("ExitCode = %d, want 42", *status.ExitCode)
	}
}

func TestBridgeStatusFromPod_StartedAtFromRunningContainer(t *testing.T) {
	now := metav1.Now()
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "test-pod"},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{
				{
					Name: AgentContainerName,
					State: corev1.ContainerState{
						Running: &corev1.ContainerStateRunning{
							StartedAt: now,
						},
					},
				},
			},
		},
	}
	status := &kapsisv1alpha1.AgentRequestStatus{
		Phase: kapsisv1alpha1.PhaseRunning,
	}
	BridgeStatusFromPod(pod, status)

	if status.StartedAt == nil {
		t.Fatal("StartedAt is nil, expected non-nil")
	}
	if !status.StartedAt.Equal(&now) {
		t.Errorf("StartedAt = %v, want %v", status.StartedAt, now)
	}
}

func TestBridgeStatusFromPod_NoOverwritePhase(t *testing.T) {
	// An annotation with a non-PostProcessing phase value should not change the status phase.
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-pod",
			Annotations: map[string]string{
				AnnotationPhase: string(kapsisv1alpha1.PhasePending),
			},
		},
	}
	status := &kapsisv1alpha1.AgentRequestStatus{
		Phase: kapsisv1alpha1.PhaseRunning,
	}
	BridgeStatusFromPod(pod, status)

	if status.Phase != kapsisv1alpha1.PhaseRunning {
		t.Errorf("Phase = %q, want %q (non-PostProcessing annotation should be ignored)", status.Phase, kapsisv1alpha1.PhaseRunning)
	}
}
