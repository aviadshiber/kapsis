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
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

const (
	// requeueInterval is how often we re-check running pods for status updates.
	requeueInterval = 10 * time.Second
)

// AgentRequestReconciler reconciles an AgentRequest object by creating and
// monitoring a Pod that runs the requested agent, then bridging Pod status
// back to the CR status.
type AgentRequestReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=kapsis.io,resources=agentrequests,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=kapsis.io,resources=agentrequests/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=kapsis.io,resources=agentrequests/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;create;delete

// Reconcile implements the three-phase reconciliation loop for AgentRequest:
//  1. Pending: CR just created, no pod yet. Create the pod and move to Initializing.
//  2. Running: Pod exists and is active. Bridge pod status/annotations to CR status.
//  3. Complete/Failed: Pod finished. Set final status and stop requeueing.
func (r *AgentRequestReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Fetch the AgentRequest CR.
	var ar kapsisv1alpha1.AgentRequest
	if err := r.Get(ctx, req.NamespacedName, &ar); err != nil {
		if apierrors.IsNotFound(err) {
			// CR was deleted; nothing to do.
			log.Info("AgentRequest not found, likely deleted")
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("fetching AgentRequest: %w", err)
	}

	// Terminal phases: no further reconciliation needed.
	if ar.Status.Phase == kapsisv1alpha1.PhaseComplete || ar.Status.Phase == kapsisv1alpha1.PhaseFailed {
		return ctrl.Result{}, nil
	}

	// Look up the owned pod.
	podName := PodName(&ar)
	var pod corev1.Pod
	podExists := true
	if err := r.Get(ctx, types.NamespacedName{Name: podName, Namespace: ar.Namespace}, &pod); err != nil {
		if apierrors.IsNotFound(err) {
			podExists = false
		} else {
			return ctrl.Result{}, fmt.Errorf("fetching pod %s: %w", podName, err)
		}
	}

	// Phase 1: No pod yet, create one.
	if !podExists {
		return r.reconcilePending(ctx, &ar)
	}

	// Phase 2 & 3: Pod exists, bridge its status.
	return r.reconcileWithPod(ctx, &ar, &pod)
}

// reconcilePending handles the initial state: sets the CR to Pending, builds
// and creates the Pod, then transitions to Initializing.
func (r *AgentRequestReconciler) reconcilePending(ctx context.Context, ar *kapsisv1alpha1.AgentRequest) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Build the pod spec from the CR.
	pod, err := BuildPod(ar)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("building pod spec: %w", err)
	}

	// Set the CR as the owner so the pod is garbage-collected with it.
	if err := ctrl.SetControllerReference(ar, pod, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("setting owner reference: %w", err)
	}

	// Create the pod in the cluster.
	if err := r.Create(ctx, pod); err != nil {
		if apierrors.IsAlreadyExists(err) {
			// Race condition: pod was created between our Get and Create.
			// Requeue to pick it up on the next reconcile.
			return ctrl.Result{Requeue: true}, nil
		}
		return ctrl.Result{}, fmt.Errorf("creating pod: %w", err)
	}

	log.Info("Created agent pod", "pod", pod.Name)

	// Update CR status to Initializing.
	ar.Status.Phase = kapsisv1alpha1.PhaseInitializing
	ar.Status.PodName = pod.Name
	ar.Status.Message = "Pod created, waiting for container start"
	now := metav1.Now()
	ar.Status.StartedAt = &now

	if err := r.Status().Update(ctx, ar); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating status to Initializing: %w", err)
	}

	return ctrl.Result{RequeueAfter: requeueInterval}, nil
}

// reconcileWithPod handles ongoing and terminal states by bridging pod status
// to the CR. Running pods are requeued; completed/failed pods set final status.
func (r *AgentRequestReconciler) reconcileWithPod(ctx context.Context, ar *kapsisv1alpha1.AgentRequest, pod *corev1.Pod) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Bridge status from the pod.
	bridged := BridgeStatus(pod)

	// Preserve fields that the bridge does not set.
	if bridged.StartedAt == nil && ar.Status.StartedAt != nil {
		bridged.StartedAt = ar.Status.StartedAt
	}

	// Apply bridged status to the CR.
	ar.Status.Phase = bridged.Phase
	ar.Status.PodName = bridged.PodName
	ar.Status.Progress = bridged.Progress
	ar.Status.Message = bridged.Message
	// Only update GistUpdatedAt when gist content actually changes.
	if bridged.Gist != "" && bridged.Gist != ar.Status.Gist {
		now := metav1.Now()
		ar.Status.GistUpdatedAt = &now
	}
	ar.Status.Gist = bridged.Gist
	ar.Status.ExitCode = bridged.ExitCode
	ar.Status.CommitSha = bridged.CommitSha
	ar.Status.PushStatus = bridged.PushStatus
	ar.Status.PrUrl = bridged.PrUrl
	if bridged.StartedAt != nil {
		ar.Status.StartedAt = bridged.StartedAt
	}
	if bridged.CompletedAt != nil {
		ar.Status.CompletedAt = bridged.CompletedAt
	}

	// Set error message for failed pods.
	if ar.Status.Phase == kapsisv1alpha1.PhaseFailed {
		ar.Status.Error = terminationMessage(pod)
		if ar.Status.Message == "" {
			ar.Status.Message = "Agent failed"
		}
	}

	if ar.Status.Phase == kapsisv1alpha1.PhaseComplete {
		if ar.Status.Message == "" {
			ar.Status.Message = "Agent completed successfully"
		}
	}

	if err := r.Status().Update(ctx, ar); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating CR status: %w", err)
	}

	// Terminal: no requeue.
	if ar.Status.Phase == kapsisv1alpha1.PhaseComplete || ar.Status.Phase == kapsisv1alpha1.PhaseFailed {
		log.Info("Agent finished", "phase", ar.Status.Phase, "exitCode", ar.Status.ExitCode)
		return ctrl.Result{}, nil
	}

	// Still running: requeue to poll for updates.
	return ctrl.Result{RequeueAfter: requeueInterval}, nil
}

// terminationMessage extracts the termination message from the first terminated
// container, falling back to a generic message.
func terminationMessage(pod *corev1.Pod) string {
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.State.Terminated != nil && cs.State.Terminated.Message != "" {
			return cs.State.Terminated.Message
		}
	}
	return "Pod failed without termination message"
}

// SetupWithManager sets up the controller with the Manager.
// It watches AgentRequest resources and their owned Pods so that pod status
// changes automatically trigger reconciliation.
func (r *AgentRequestReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&kapsisv1alpha1.AgentRequest{}).
		Owns(&corev1.Pod{}).
		Named("agentrequest").
		Complete(r)
}
