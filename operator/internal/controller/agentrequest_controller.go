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
	"k8s.io/client-go/util/retry"
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
// +kubebuilder:rbac:groups=networking.k8s.io,resources=networkpolicies,verbs=get;list;watch;create;delete

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

	// Create NetworkPolicy for network isolation (skip for "open" mode).
	if ShouldCreateNetworkPolicy(ar) {
		np := BuildNetworkPolicy(ar)
		if err := ctrl.SetControllerReference(ar, np, r.Scheme); err != nil {
			return ctrl.Result{}, fmt.Errorf("setting network policy owner reference: %w", err)
		}
		if err := r.Create(ctx, np); err != nil {
			if apierrors.IsAlreadyExists(err) {
				log.V(1).Info("NetworkPolicy already exists", "name", np.Name)
			} else {
				return ctrl.Result{}, fmt.Errorf("creating network policy: %w", err)
			}
		} else {
			log.Info("Created network policy", "name", np.Name, "mode", networkMode(ar))
		}
	}

	// Update CR status to Initializing.
	nn := types.NamespacedName{Name: ar.Name, Namespace: ar.Namespace}
	podNameStr := pod.Name
	if err := r.updateStatusWithRetry(ctx, nn, func(fresh *kapsisv1alpha1.AgentRequest) {
		fresh.Status.Phase = kapsisv1alpha1.PhaseInitializing
		fresh.Status.PodName = podNameStr
		fresh.Status.Message = "Pod created, waiting for container start"
		now := metav1.Now()
		fresh.Status.StartedAt = &now
	}); err != nil {
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

	// Update CR status with retry on conflict.
	nn := types.NamespacedName{Name: ar.Name, Namespace: ar.Namespace}
	prevStartedAt := ar.Status.StartedAt
	if err := r.updateStatusWithRetry(ctx, nn, func(fresh *kapsisv1alpha1.AgentRequest) {
		fresh.Status.Phase = bridged.Phase
		fresh.Status.PodName = bridged.PodName
		fresh.Status.Progress = bridged.Progress
		fresh.Status.Message = bridged.Message
		// Only update GistUpdatedAt when gist content actually changes.
		if bridged.Gist != "" && bridged.Gist != fresh.Status.Gist {
			now := metav1.Now()
			fresh.Status.GistUpdatedAt = &now
		}
		fresh.Status.Gist = bridged.Gist
		fresh.Status.ExitCode = bridged.ExitCode
		fresh.Status.CommitSha = bridged.CommitSha
		fresh.Status.PushStatus = bridged.PushStatus
		fresh.Status.PrUrl = bridged.PrUrl
		if bridged.StartedAt != nil {
			fresh.Status.StartedAt = bridged.StartedAt
		} else if fresh.Status.StartedAt == nil {
			fresh.Status.StartedAt = prevStartedAt
		}
		if bridged.CompletedAt != nil {
			fresh.Status.CompletedAt = bridged.CompletedAt
		}

		// Set error message for failed pods.
		if fresh.Status.Phase == kapsisv1alpha1.PhaseFailed {
			fresh.Status.Error = terminationMessage(pod)
			if fresh.Status.Message == "" {
				fresh.Status.Message = "Agent failed"
			}
		}
		if fresh.Status.Phase == kapsisv1alpha1.PhaseComplete {
			if fresh.Status.Message == "" {
				fresh.Status.Message = "Agent completed successfully"
			}
		}
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating CR status: %w", err)
	}

	// Terminal: no requeue.
	if bridged.Phase == kapsisv1alpha1.PhaseComplete || bridged.Phase == kapsisv1alpha1.PhaseFailed {
		log.Info("Agent finished", "phase", bridged.Phase, "exitCode", bridged.ExitCode)
		return ctrl.Result{}, nil
	}

	// Still running: requeue to poll for updates.
	return ctrl.Result{RequeueAfter: requeueInterval}, nil
}

// updateStatusWithRetry wraps a status update with conflict retry.
// On conflict, it re-fetches the CR and reapplies the mutator function.
func (r *AgentRequestReconciler) updateStatusWithRetry(
	ctx context.Context, nn types.NamespacedName,
	mutate func(*kapsisv1alpha1.AgentRequest),
) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		var ar kapsisv1alpha1.AgentRequest
		if err := r.Get(ctx, nn, &ar); err != nil {
			return err
		}
		mutate(&ar)
		return r.Status().Update(ctx, &ar)
	})
}

// terminationMessage extracts the termination message from the agent container,
// falling back to a generic message.
func terminationMessage(pod *corev1.Pod) string {
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.Name != AgentContainerName {
			continue
		}
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
