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
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

// podWithPhase returns a minimal Pod with the given Kubernetes phase and an
// agent container status slot populated (terminated/running per state).
func podWithPhase(phase corev1.PodPhase, state string, exitCode int32) *corev1.Pod {
	started := metav1.NewTime(time.Date(2026, 4, 24, 12, 0, 0, 0, time.UTC))
	finished := metav1.NewTime(time.Date(2026, 4, 24, 12, 5, 0, 0, time.UTC))

	cs := corev1.ContainerStatus{Name: AgentContainerName}
	switch state {
	case "running":
		cs.State.Running = &corev1.ContainerStateRunning{StartedAt: started}
	case "terminated":
		cs.State.Terminated = &corev1.ContainerStateTerminated{
			StartedAt:  started,
			FinishedAt: finished,
			ExitCode:   exitCode,
		}
	}

	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "agent-pod", Namespace: "default"},
		Status: corev1.PodStatus{
			Phase:             phase,
			ContainerStatuses: []corev1.ContainerStatus{cs},
		},
	}
}

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

//===============================================================================
// toAgentPhase (helper unit tests)
//===============================================================================

func TestToAgentPhase_KnownValuesRoundTrip(t *testing.T) {
	cases := []kapsisv1alpha1.AgentRequestPhase{
		kapsisv1alpha1.PhasePending,
		kapsisv1alpha1.PhaseInitializing,
		kapsisv1alpha1.PhaseRunning,
		kapsisv1alpha1.PhasePostProcessing,
		kapsisv1alpha1.PhaseComplete,
		kapsisv1alpha1.PhaseFailed,
	}
	for _, want := range cases {
		if got := toAgentPhase(string(want)); got != want {
			t.Errorf("toAgentPhase(%q) = %q, want %q", want, got, want)
		}
	}
}

func TestToAgentPhase_UnknownFallsBackToRunning(t *testing.T) {
	if got := toAgentPhase("NotAPhase"); got != kapsisv1alpha1.PhaseRunning {
		t.Errorf("unknown → want Running, got %q", got)
	}
}

func TestToAgentPhase_EmptyFallsBackToRunning(t *testing.T) {
	if got := toAgentPhase(""); got != kapsisv1alpha1.PhaseRunning {
		t.Errorf("empty → want Running, got %q", got)
	}
}

//===============================================================================
// applyAnnotations (helper unit tests)
//===============================================================================

func TestApplyAnnotations_AllFieldsMapped(t *testing.T) {
	pod := podWithPhase(corev1.PodSucceeded, "terminated", 0)
	pod.Annotations = map[string]string{
		AnnotationGist:            "implementing auth",
		AnnotationMessage:         "all green",
		AnnotationProgress:        "87",
		AnnotationCommitSha:       "deadbeef",
		AnnotationPush:            "success",
		AnnotationPrURL:           "https://github.com/o/r/pull/1",
		AnnotationPushFallbackCmd: "git push -u origin feat",
	}

	status := kapsisv1alpha1.AgentRequestStatus{}
	applyAnnotations(pod, &status)

	if status.Gist != "implementing auth" {
		t.Errorf("Gist = %q", status.Gist)
	}
	if status.Message != "all green" {
		t.Errorf("Message = %q", status.Message)
	}
	if status.Progress != 87 {
		t.Errorf("Progress = %d, want 87", status.Progress)
	}
	if status.CommitSha != "deadbeef" {
		t.Errorf("CommitSha = %q", status.CommitSha)
	}
	if status.PushStatus != "success" {
		t.Errorf("PushStatus = %q", status.PushStatus)
	}
	if status.PrUrl != "https://github.com/o/r/pull/1" {
		t.Errorf("PrUrl = %q", status.PrUrl)
	}
	if status.PushFallbackCommand != "git push -u origin feat" {
		t.Errorf("PushFallbackCommand = %q", status.PushFallbackCommand)
	}
}

func TestApplyAnnotations_MalformedProgressLeavesZero(t *testing.T) {
	pod := podWithPhase(corev1.PodRunning, "running", 0)
	pod.Annotations = map[string]string{AnnotationProgress: "not-a-number"}

	status := kapsisv1alpha1.AgentRequestStatus{}
	applyAnnotations(pod, &status)

	if status.Progress != 0 {
		t.Errorf("malformed progress should remain 0, got %d", status.Progress)
	}
}

func TestApplyAnnotations_NilMapIsSafe(t *testing.T) {
	pod := podWithPhase(corev1.PodRunning, "running", 0)
	pod.Annotations = nil

	status := kapsisv1alpha1.AgentRequestStatus{}
	applyAnnotations(pod, &status) // must not panic
	if status.Message != "" || status.Gist != "" {
		t.Errorf("nil annotations should leave status untouched")
	}
}

//===============================================================================
// applyContainerState (helper unit tests)
//===============================================================================

func TestApplyContainerState_RunningPopulatesStartedAt(t *testing.T) {
	pod := podWithPhase(corev1.PodRunning, "running", 0)

	status := kapsisv1alpha1.AgentRequestStatus{}
	applyContainerState(pod, &status)

	if status.StartedAt == nil {
		t.Fatal("StartedAt must be set for running container")
	}
	if status.CompletedAt != nil {
		t.Errorf("CompletedAt must be nil for running container")
	}
}

func TestApplyContainerState_TerminatedPopulatesBoth(t *testing.T) {
	pod := podWithPhase(corev1.PodSucceeded, "terminated", 0)

	status := kapsisv1alpha1.AgentRequestStatus{}
	applyContainerState(pod, &status)

	if status.StartedAt == nil || status.CompletedAt == nil {
		t.Fatal("terminated container must populate both timestamps")
	}
	if !status.CompletedAt.After(status.StartedAt.Time) {
		t.Errorf("CompletedAt must be after StartedAt")
	}
}

func TestApplyContainerState_IgnoresSidecarTermination(t *testing.T) {
	// A terminated sidecar container must not leak exit code into status.
	pod := podWithPhase(corev1.PodRunning, "", 0)
	pod.Status.ContainerStatuses = append(
		[]corev1.ContainerStatus{{
			Name: "status-sidecar",
			State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
				ExitCode: 99,
			}},
		}},
		pod.Status.ContainerStatuses...,
	)
	// Agent container is running (no exit code).
	for i, cs := range pod.Status.ContainerStatuses {
		if cs.Name == AgentContainerName {
			pod.Status.ContainerStatuses[i].State = corev1.ContainerState{
				Running: &corev1.ContainerStateRunning{},
			}
		}
	}

	status := kapsisv1alpha1.AgentRequestStatus{}
	applyContainerState(pod, &status)

	if status.ExitCode != nil {
		t.Errorf("sidecar termination must not set ExitCode, got %d", *status.ExitCode)
	}
}
