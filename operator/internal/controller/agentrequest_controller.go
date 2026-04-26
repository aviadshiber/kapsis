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

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

const (
	// watchdogRequeue is the safety-net re-check interval for running Jobs.
	// The primary driver is watch events from Owns(&batchv1.Job{}) and
	// Owns(&corev1.Pod{}); this requeue is only a watchdog.
	watchdogRequeue = 5 * time.Minute
)

// AgentRequestReconciler reconciles an AgentRequest object by creating and
// monitoring a batch/v1 Job that runs the requested agent, then bridging Job
// and Pod status back to the CR status subresource.
type AgentRequestReconciler struct {
	client.Client
	Scheme *runtime.Scheme

	// StatusSidecarImage is the container image for the status/audit sidecar.
	// Defaults to DefaultStatusSidecarImage if empty.
	// Set via KAPSIS_STATUS_SIDECAR_IMAGE environment variable in the operator Deployment.
	StatusSidecarImage string
}

// +kubebuilder:rbac:groups=kapsis.aviadshiber.github.io,resources=agentrequests,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=kapsis.aviadshiber.github.io,resources=agentrequests/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=kapsis.aviadshiber.github.io,resources=agentrequests/finalizers,verbs=update
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;delete
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch
// +kubebuilder:rbac:groups=networking.k8s.io,resources=networkpolicies,verbs=get;list;watch;create;update;patch

// Reconcile implements the reconciliation loop for AgentRequest.
//
// Phase lifecycle:
//  1. Pending  → create the namespace-level NetworkPolicy + batch/v1 Job
//  2. Initializing → Job pod not yet running; driven by Job watch events
//  3. Running  → pod running; sidecar patches annotations; 5-min watchdog safety net
//  4. Complete/Failed → Job terminal; set final status; stop requeueing
func (r *AgentRequestReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Fetch the AgentRequest CR.
	var ar kapsisv1alpha1.AgentRequest
	if err := r.Get(ctx, req.NamespacedName, &ar); err != nil {
		if apierrors.IsNotFound(err) {
			log.Info("AgentRequest not found, likely deleted")
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("fetching AgentRequest: %w", err)
	}

	// Terminal phases need no further reconciliation.
	if ar.Status.Phase == kapsisv1alpha1.PhaseComplete || ar.Status.Phase == kapsisv1alpha1.PhaseFailed {
		return ctrl.Result{}, nil
	}

	// Look up the owned Job.
	jobName := JobName(&ar)
	var job batchv1.Job
	jobExists := true
	if err := r.Get(ctx, types.NamespacedName{Name: jobName, Namespace: ar.Namespace}, &job); err != nil {
		if apierrors.IsNotFound(err) {
			jobExists = false
		} else {
			return ctrl.Result{}, fmt.Errorf("fetching Job %s: %w", jobName, err)
		}
	}

	if !jobExists {
		return r.reconcilePending(ctx, &ar)
	}

	return r.reconcileWithJob(ctx, &ar, &job)
}

// reconcilePending handles the initial state: ensures the namespace NetworkPolicy
// exists, creates the agent Job, and transitions to Initializing.
func (r *AgentRequestReconciler) reconcilePending(ctx context.Context, ar *kapsisv1alpha1.AgentRequest) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Ensure the namespace-level NetworkPolicy exists (idempotent: create or skip).
	if ShouldCreateNetworkPolicy(ar) {
		if err := r.ensureNetworkPolicy(ctx, ar); err != nil {
			return ctrl.Result{}, fmt.Errorf("ensuring network policy: %w", err)
		}
	}

	// Build the Job spec.
	job, err := BuildJob(ar, r.StatusSidecarImage)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("building Job spec: %w", err)
	}

	// Set the CR as the owner so the Job is garbage-collected when the CR is deleted.
	if err := ctrl.SetControllerReference(ar, job, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("setting owner reference: %w", err)
	}

	if err := r.Create(ctx, job); err != nil {
		if apierrors.IsAlreadyExists(err) {
			// Race: Job created between our Get and Create; pick it up on next reconcile.
			return ctrl.Result{Requeue: true}, nil
		}
		return ctrl.Result{}, fmt.Errorf("creating Job: %w", err)
	}

	log.Info("Created agent Job", "job", job.Name)

	// Transition CR to Initializing.
	nn := types.NamespacedName{Name: ar.Name, Namespace: ar.Namespace}
	jobNameStr := job.Name
	if err := r.updateStatusWithRetry(ctx, nn, func(fresh *kapsisv1alpha1.AgentRequest) {
		fresh.Status.Phase = kapsisv1alpha1.PhaseInitializing
		fresh.Status.JobName = jobNameStr
		fresh.Status.Message = "Job created, waiting for pod to start"
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating status to Initializing: %w", err)
	}

	// Watch events from Owns(&batchv1.Job{}) drive subsequent reconciles.
	// Small requeue here in case the Job watch event is delayed.
	return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
}

// ensureNetworkPolicy creates the namespace-level NetworkPolicy if it does not exist.
// Unlike the old per-agent policy, this policy applies to ALL kapsis-agent pods in
// the namespace via a label selector, so it is created once and reused.
func (r *AgentRequestReconciler) ensureNetworkPolicy(ctx context.Context, ar *kapsisv1alpha1.AgentRequest) error {
	log := logf.FromContext(ctx)

	np := BuildNetworkPolicy(ar)
	if np == nil {
		return nil
	}

	// Namespace-level policy is NOT owned by any single AgentRequest — it must
	// outlive individual runs. Do not set a controller reference here.
	if err := r.Create(ctx, np); err != nil {
		if apierrors.IsAlreadyExists(err) {
			log.V(1).Info("NetworkPolicy already exists, reusing", "name", np.Name)
			return nil
		}
		return fmt.Errorf("creating NetworkPolicy %s: %w", np.Name, err)
	}

	log.Info("Created namespace NetworkPolicy", "name", np.Name, "mode", networkMode(ar))
	return nil
}

// reconcileWithJob handles ongoing and terminal states by bridging Job and Pod
// status back to the CR.
func (r *AgentRequestReconciler) reconcileWithJob(ctx context.Context, ar *kapsisv1alpha1.AgentRequest, job *batchv1.Job) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Derive phase from the Job's conditions.
	bridged := BridgeStatusFromJob(job)

	// Look up the Job's pod to overlay real-time annotation-based status.
	pod, err := r.findJobPod(ctx, job, ar.Status.PodName)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("finding job pod: %w", err)
	}
	if pod != nil {
		BridgeStatusFromPod(pod, &bridged)
	}

	// Apply the bridged status to the CR with conflict retry.
	nn := types.NamespacedName{Name: ar.Name, Namespace: ar.Namespace}
	if err := r.updateStatusWithRetry(ctx, nn, func(fresh *kapsisv1alpha1.AgentRequest) {
		// Phase: always accept the bridged phase (authoritative from Job conditions).
		fresh.Status.Phase = bridged.Phase
		fresh.Status.JobName = bridged.JobName
		if bridged.PodName != "" {
			fresh.Status.PodName = bridged.PodName
		}

		// Real-time fields from pod annotations.
		fresh.Status.Progress = bridged.Progress
		fresh.Status.Message = bridged.Message
		fresh.Status.Gist = bridged.Gist
		fresh.Status.CommitSha = bridged.CommitSha
		fresh.Status.PushStatus = bridged.PushStatus
		fresh.Status.PrUrl = bridged.PrUrl
		fresh.Status.PushFallbackCommand = bridged.PushFallbackCommand

		if bridged.ExitCode != nil {
			fresh.Status.ExitCode = bridged.ExitCode
		}
		if bridged.StartedAt != nil {
			fresh.Status.StartedAt = bridged.StartedAt
		}
		if bridged.CompletedAt != nil {
			fresh.Status.CompletedAt = bridged.CompletedAt
		}

		// Set human-readable messages for terminal phases.
		switch fresh.Status.Phase {
		case kapsisv1alpha1.PhaseFailed:
			if fresh.Status.Error == "" {
				fresh.Status.Error = jobFailureMessage(job)
			}
			if fresh.Status.Message == "" {
				fresh.Status.Message = "Agent Job failed"
			}
		case kapsisv1alpha1.PhaseComplete:
			if fresh.Status.Message == "" {
				fresh.Status.Message = "Agent completed successfully"
			}
		}
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating CR status: %w", err)
	}

	// Terminal: stop requeueing.
	if bridged.Phase == kapsisv1alpha1.PhaseComplete || bridged.Phase == kapsisv1alpha1.PhaseFailed {
		log.Info("Agent Job finished", "phase", bridged.Phase, "exitCode", bridged.ExitCode)
		return ctrl.Result{}, nil
	}

	// Non-terminal: rely on watch events; requeue only as a safety watchdog.
	return ctrl.Result{RequeueAfter: watchdogRequeue}, nil
}

// findJobPod returns the pod for the given Job. If the pod name is already
// cached in the CR status, it performs a direct Get instead of a List.
func (r *AgentRequestReconciler) findJobPod(ctx context.Context, job *batchv1.Job, cachedPodName string) (*corev1.Pod, error) {
	if cachedPodName != "" {
		var pod corev1.Pod
		if err := r.Get(ctx, types.NamespacedName{Name: cachedPodName, Namespace: job.Namespace}, &pod); err != nil {
			if apierrors.IsNotFound(err) {
				return nil, nil
			}
			return nil, fmt.Errorf("getting cached pod %s: %w", cachedPodName, err)
		}
		return &pod, nil
	}
	// First-time discovery: List by job-name label.
	var podList corev1.PodList
	selector := labels.SelectorFromSet(map[string]string{
		"batch.kubernetes.io/job-name": job.Name,
	})
	if err := r.List(ctx, &podList,
		client.InNamespace(job.Namespace),
		client.MatchingLabelsSelector{Selector: selector},
	); err != nil {
		return nil, fmt.Errorf("listing pods for job %s: %w", job.Name, err)
	}
	if len(podList.Items) == 0 {
		return nil, nil
	}
	return &podList.Items[0], nil
}

// updateStatusWithRetry wraps a status update with optimistic-concurrency retry.
// On conflict it re-fetches the CR and re-applies the mutator.
func (r *AgentRequestReconciler) updateStatusWithRetry(
	ctx context.Context,
	nn types.NamespacedName,
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

// jobFailureMessage extracts a human-readable failure reason from the Job.
func jobFailureMessage(job *batchv1.Job) string {
	for _, cond := range job.Status.Conditions {
		if cond.Type == batchv1.JobFailed && cond.Status == corev1.ConditionTrue {
			if cond.Message != "" {
				return cond.Message
			}
			if cond.Reason != "" {
				return cond.Reason
			}
		}
	}
	return "Job failed without condition message"
}

// podToAgentRequest maps a Pod annotation-change event to the owning AgentRequest
// by walking up the ownerReference chain: Pod -> Job -> AgentRequest.
func (r *AgentRequestReconciler) podToAgentRequest(ctx context.Context, obj client.Object) []reconcile.Request {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return nil
	}
	// Find the Job that owns this pod.
	jobName := ""
	for _, ref := range pod.OwnerReferences {
		if ref.Kind == "Job" && ref.Controller != nil && *ref.Controller {
			jobName = ref.Name
			break
		}
	}
	if jobName == "" {
		return nil
	}
	// Find the AgentRequest that owns the Job.
	var job batchv1.Job
	if err := r.Get(ctx, types.NamespacedName{Name: jobName, Namespace: pod.Namespace}, &job); err != nil {
		return nil
	}
	for _, ref := range job.OwnerReferences {
		if ref.Kind == "AgentRequest" && ref.Controller != nil && *ref.Controller {
			return []reconcile.Request{
				{NamespacedName: types.NamespacedName{Name: ref.Name, Namespace: pod.Namespace}},
			}
		}
	}
	return nil
}

// SetupWithManager registers the controller with the Manager.
// It watches AgentRequest resources plus their owned Jobs and Pods so that
// status changes trigger reconciliation without constant polling.
func (r *AgentRequestReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&kapsisv1alpha1.AgentRequest{}).
		Owns(&batchv1.Job{}).
		// Pod watch: maps annotation changes by the status sidecar back to the owning
		// AgentRequest via Pod->Job->AgentRequest owner reference chain.
		Watches(
			&corev1.Pod{},
			handler.EnqueueRequestsFromMapFunc(r.podToAgentRequest),
		).
		Named("agentrequest").
		Complete(r)
}
