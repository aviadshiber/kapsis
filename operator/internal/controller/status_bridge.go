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

	corev1 "k8s.io/api/core/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

const (
	// Annotation keys written by in-container status hooks.
	AnnotationGist      = "kapsis.aviadshiber.github.io/gist"
	AnnotationPhase     = "kapsis.aviadshiber.github.io/phase"
	AnnotationProgress  = "kapsis.aviadshiber.github.io/progress"
	AnnotationMessage   = "kapsis.aviadshiber.github.io/message"
	AnnotationCommitSha = "kapsis.aviadshiber.github.io/commit-sha"
	AnnotationPush      = "kapsis.aviadshiber.github.io/push-status"
	AnnotationPrURL     = "kapsis.aviadshiber.github.io/pr-url"
)

// BridgeStatus reads Pod status and annotations to produce an updated
// AgentRequestStatus. It maps Kubernetes Pod phases to Kapsis CR phases
// and extracts agent-reported metadata from Pod annotations.
func BridgeStatus(pod *corev1.Pod) kapsisv1alpha1.AgentRequestStatus {
	status := kapsisv1alpha1.AgentRequestStatus{
		PodName: pod.Name,
	}

	// Map pod phase to CR phase.
	status.Phase = mapPodPhase(pod)

	// Extract exit code from the first terminated container.
	status.ExitCode = extractExitCode(pod)

	// Read annotations written by the agent's status hooks.
	applyAnnotations(pod, &status)

	// Set timestamps.
	applyTimestamps(pod, &status)

	return status
}

// mapPodPhase translates a Kubernetes Pod phase into a Kapsis AgentRequest phase.
// Pod annotations can override the phase when the pod is running (e.g., the agent
// can report "PostProcessing" while the pod is still technically Running).
func mapPodPhase(pod *corev1.Pod) kapsisv1alpha1.AgentRequestPhase {
	switch pod.Status.Phase {
	case corev1.PodPending:
		return kapsisv1alpha1.PhaseInitializing

	case corev1.PodRunning:
		// Allow annotation override for finer-grained phases.
		if override, ok := pod.Annotations[AnnotationPhase]; ok {
			return toAgentPhase(override)
		}
		return kapsisv1alpha1.PhaseRunning

	case corev1.PodSucceeded:
		return kapsisv1alpha1.PhaseComplete

	case corev1.PodFailed:
		return kapsisv1alpha1.PhaseFailed

	default:
		return kapsisv1alpha1.PhasePending
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

// extractExitCode reads the termination exit code from the agent container.
func extractExitCode(pod *corev1.Pod) *int32 {
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.Name != AgentContainerName {
			continue
		}
		if cs.State.Terminated != nil {
			code := cs.State.Terminated.ExitCode
			return &code
		}
	}
	return nil
}

// applyAnnotations reads agent-reported annotations from the Pod and populates
// the corresponding fields on the CR status.
func applyAnnotations(pod *corev1.Pod, status *kapsisv1alpha1.AgentRequestStatus) {
	if pod.Annotations == nil {
		return
	}

	if gist, ok := pod.Annotations[AnnotationGist]; ok {
		status.Gist = gist
		// GistUpdatedAt is managed by the controller to avoid unnecessary
		// timestamp updates when gist content hasn't changed.
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
}

// applyTimestamps sets StartedAt and CompletedAt from the agent container status.
func applyTimestamps(pod *corev1.Pod, status *kapsisv1alpha1.AgentRequestStatus) {
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
		}
	}
}
