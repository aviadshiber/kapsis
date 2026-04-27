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
	"strconv"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

const (
	// Annotation keys written by the status sidecar.
	// The sidecar reads /kapsis-status/status.json and patches these onto the pod.
	AnnotationGist              = "kapsis.aviadshiber.github.io/gist"
	AnnotationPhase             = "kapsis.aviadshiber.github.io/phase"
	AnnotationProgress          = "kapsis.aviadshiber.github.io/progress"
	AnnotationMessage           = "kapsis.aviadshiber.github.io/message"
	AnnotationCommitSha         = "kapsis.aviadshiber.github.io/commit-sha"
	AnnotationPush              = "kapsis.aviadshiber.github.io/push-status"
	AnnotationPrURL             = "kapsis.aviadshiber.github.io/pr-url"
	AnnotationPushFallbackCmd   = "kapsis.aviadshiber.github.io/push-fallback-cmd"
)

// BridgeStatusFromJob derives the authoritative phase and job-level metadata
// from the batch/v1 Job conditions. This is the source of truth for
// Complete/Failed phase transitions.
//
// Job condition precedence:
//  1. Complete condition True → PhaseComplete
//  2. Failed condition True  → PhaseFailed
//  3. Active pods > 0        → PhaseRunning (or PhaseInitializing if no pod yet)
//  4. Otherwise              → PhasePending
func BridgeStatusFromJob(job *batchv1.Job) kapsisv1alpha1.AgentRequestStatus {
	status := kapsisv1alpha1.AgentRequestStatus{
		JobName: job.Name,
	}

	for _, cond := range job.Status.Conditions {
		if cond.Status != corev1.ConditionTrue {
			continue
		}
		switch cond.Type {
		case batchv1.JobComplete:
			status.Phase = kapsisv1alpha1.PhaseComplete
			return status
		case batchv1.JobFailed:
			status.Phase = kapsisv1alpha1.PhaseFailed
			return status
		}
	}

	// Job is not terminal: infer phase from active/ready pod counts.
	if job.Status.Active > 0 {
		status.Phase = kapsisv1alpha1.PhaseRunning
	} else if job.Status.StartTime != nil {
		// Job has started but no active pods yet (scheduling or just started).
		status.Phase = kapsisv1alpha1.PhaseInitializing
	} else {
		status.Phase = kapsisv1alpha1.PhasePending
	}

	return status
}

// BridgeStatusFromPod overlays pod-level information (annotations, exit code, timestamps)
// onto an existing AgentRequestStatus that was previously populated by BridgeStatusFromJob.
// The Job-derived phase is NOT overwritten except when the annotation carries a finer-
// grained sub-phase (PostProcessing) while the pod is still running.
func BridgeStatusFromPod(pod *corev1.Pod, status *kapsisv1alpha1.AgentRequestStatus) {
	status.PodName = pod.Name

	// Allow the agent to signal PostProcessing via annotation while the pod is still running
	// or initializing.
	if status.Phase == kapsisv1alpha1.PhaseRunning || status.Phase == kapsisv1alpha1.PhaseInitializing {
		if override, ok := pod.Annotations[AnnotationPhase]; ok {
			if toAgentPhase(override) == kapsisv1alpha1.PhasePostProcessing {
				status.Phase = kapsisv1alpha1.PhasePostProcessing
			}
		}
	}

	// Overlay real-time fields written by the status sidecar.
	applyAnnotations(pod, status)

	// Extract exit code and timestamps from the agent container's termination state.
	applyContainerState(pod, status)
}

// applyAnnotations reads the status sidecar's pod annotations into the CR status.
func applyAnnotations(pod *corev1.Pod, status *kapsisv1alpha1.AgentRequestStatus) {
	if pod.Annotations == nil {
		return
	}

	if gist, ok := pod.Annotations[AnnotationGist]; ok {
		status.Gist = gist
	}
	if msg, ok := pod.Annotations[AnnotationMessage]; ok {
		status.Message = msg
	}
	if progressStr, ok := pod.Annotations[AnnotationProgress]; ok {
		if p, err := strconv.ParseInt(progressStr, 10, 32); err == nil {
			status.Progress = int32(p)
		}
	}
	if sha, ok := pod.Annotations[AnnotationCommitSha]; ok {
		status.CommitSha = sha
	}
	if push, ok := pod.Annotations[AnnotationPush]; ok {
		status.PushStatus = push
	}
	if prURL, ok := pod.Annotations[AnnotationPrURL]; ok {
		status.PrUrl = prURL
	}
	if fallback, ok := pod.Annotations[AnnotationPushFallbackCmd]; ok {
		status.PushFallbackCommand = fallback
	}
}

// applyContainerState reads exit code and timing from the agent container's state.
func applyContainerState(pod *corev1.Pod, status *kapsisv1alpha1.AgentRequestStatus) {
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.Name != AgentContainerName {
			continue
		}
		if cs.State.Running != nil {
			status.StartedAt = &cs.State.Running.StartedAt
		}
		if cs.State.Terminated != nil {
			status.StartedAt = &cs.State.Terminated.StartedAt
			status.CompletedAt = &cs.State.Terminated.FinishedAt
			code := cs.State.Terminated.ExitCode
			status.ExitCode = &code
		}
		return
	}
}

// toAgentPhase converts a string annotation value to a typed AgentRequestPhase.
// Unrecognized values default to Running to avoid invalid states.
func toAgentPhase(s string) kapsisv1alpha1.AgentRequestPhase {
	switch kapsisv1alpha1.AgentRequestPhase(s) {
	case kapsisv1alpha1.PhasePending,
		kapsisv1alpha1.PhaseInitializing,
		kapsisv1alpha1.PhaseRunning,
		kapsisv1alpha1.PhasePostProcessing,
		kapsisv1alpha1.PhaseComplete,
		kapsisv1alpha1.PhaseFailed:
		return kapsisv1alpha1.AgentRequestPhase(s)
	default:
		return kapsisv1alpha1.PhaseRunning
	}
}
