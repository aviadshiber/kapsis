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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

var _ = Describe("AgentRequest Controller", func() {

	const namespace = "default"

	// newMinimalAR builds a minimal AgentRequest for a given name.
	newMinimalAR := func(name string) *kapsisv1alpha1.AgentRequest {
		return &kapsisv1alpha1.AgentRequest{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: namespace,
			},
			Spec: kapsisv1alpha1.AgentRequestSpec{
				Agent: kapsisv1alpha1.AgentSpec{
					Type:  "claude-cli",
					Image: "ghcr.io/aviadshiber/kapsis/claude-cli:latest",
				},
			},
		}
	}

	// newReconciler builds a reconciler backed by the test k8sClient.
	newReconciler := func() *AgentRequestReconciler {
		return &AgentRequestReconciler{
			Client: k8sClient,
			Scheme: k8sClient.Scheme(),
		}
	}

	// ── New AgentRequest ────────────────────────────────────────────────────────
	Context("When reconciling a new AgentRequest", func() {
		const resourceName = "test-new-cr"

		ctx := context.Background()
		nn := types.NamespacedName{Name: resourceName, Namespace: namespace}

		BeforeEach(func() {
			ar := newMinimalAR(resourceName)
			ar.Spec.PodAnnotations = map[string]string{
				"vault.hashicorp.com/agent-inject": "true",
			}
			err := k8sClient.Get(ctx, nn, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			ar := &kapsisv1alpha1.AgentRequest{}
			if err := k8sClient.Get(ctx, nn, ar); err == nil {
				Expect(k8sClient.Delete(ctx, ar)).To(Succeed())
			}
			job := &batchv1.Job{}
			jobNN := types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}
			if err := k8sClient.Get(ctx, jobNN, job); err == nil {
				Expect(k8sClient.Delete(ctx, job)).To(Succeed())
			}
		})

		It("should create a Job when reconciling a new AgentRequest", func() {
			result, err := newReconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nn})
			Expect(err).NotTo(HaveOccurred())
			Expect(result.RequeueAfter).To(BeNumerically(">", 0), "should requeue to monitor the job")

			By("verifying the Job was created")
			job := &batchv1.Job{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}, job)).
				To(Succeed())

			By("verifying Job spec")
			Expect(job.Spec.BackoffLimit).NotTo(BeNil())
			Expect(*job.Spec.BackoffLimit).To(Equal(int32(0)))
			Expect(job.Spec.Template.Spec.RestartPolicy).To(Equal(corev1.RestartPolicyNever))

			By("verifying two containers: agent + status-sidecar")
			Expect(job.Spec.Template.Spec.Containers).To(HaveLen(2))
			Expect(job.Spec.Template.Spec.Containers[0].Name).To(Equal(AgentContainerName))
			Expect(job.Spec.Template.Spec.Containers[1].Name).To(Equal(StatusSidecarContainerName))

			By("verifying pod annotations are passed through")
			Expect(job.Spec.Template.Annotations).To(HaveKeyWithValue("vault.hashicorp.com/agent-inject", "true"))

			By("verifying service account token is not auto-mounted")
			Expect(job.Spec.Template.Spec.AutomountServiceAccountToken).NotTo(BeNil())
			Expect(*job.Spec.Template.Spec.AutomountServiceAccountToken).To(BeFalse())

			By("verifying Kapsis environment variables on agent container")
			envMap := map[string]string{}
			for _, e := range job.Spec.Template.Spec.Containers[0].Env {
				envMap[e.Name] = e.Value
			}
			Expect(envMap["KAPSIS_BACKEND"]).To(Equal("k8s"))
			Expect(envMap["KAPSIS_AGENT_ID"]).To(Equal(resourceName))
			Expect(envMap["KAPSIS_AGENT_TYPE"]).To(Equal("claude-cli"))

			By("verifying CR status was updated to Initializing")
			updatedAR := &kapsisv1alpha1.AgentRequest{}
			Expect(k8sClient.Get(ctx, nn, updatedAR)).To(Succeed())
			Expect(updatedAR.Status.Phase).To(Equal(kapsisv1alpha1.PhaseInitializing))
			Expect(updatedAR.Status.JobName).To(Equal(resourceName + "-job"))

			By("verifying owner reference is set")
			Expect(job.OwnerReferences).To(HaveLen(1))
			Expect(job.OwnerReferences[0].Name).To(Equal(resourceName))

			By("verifying Guaranteed QoS (requests = limits)")
			c := job.Spec.Template.Spec.Containers[0]
			Expect(c.Resources.Requests).To(Equal(c.Resources.Limits))

			By("verifying capabilities are dropped (standard profile)")
			sc := c.SecurityContext
			Expect(sc).NotTo(BeNil())
			Expect(sc.Capabilities.Drop).To(ContainElement(corev1.Capability("ALL")))
		})
	})

	// ── Job succeeded ───────────────────────────────────────────────────────────
	Context("When a Job has completed successfully", func() {
		const resourceName = "test-completed-job"

		ctx := context.Background()
		nn := types.NamespacedName{Name: resourceName, Namespace: namespace}

		BeforeEach(func() {
			ar := newMinimalAR(resourceName)
			Expect(k8sClient.Create(ctx, ar)).To(Succeed())

			ar.Status.Phase = kapsisv1alpha1.PhaseRunning
			ar.Status.JobName = resourceName + "-job"
			Expect(k8sClient.Status().Update(ctx, ar)).To(Succeed())

			By("creating a Job that has completed")
			job := &batchv1.Job{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName + "-job",
					Namespace: namespace,
					Labels: map[string]string{
						LabelAgentType: "claude-cli",
						LabelAgentID:   resourceName,
						LabelManagedBy: ManagedByValue,
					},
				},
				Spec: batchv1.JobSpec{
					Template: corev1.PodTemplateSpec{
						Spec: corev1.PodSpec{
							Containers:    []corev1.Container{{Name: "agent", Image: "test"}},
							RestartPolicy: corev1.RestartPolicyNever,
						},
					},
				},
			}
			Expect(k8sClient.Create(ctx, job)).To(Succeed())

			// Set Job status to Complete.
			job.Status.Conditions = []batchv1.JobCondition{
				{
					Type:   batchv1.JobComplete,
					Status: corev1.ConditionTrue,
				},
			}
			Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())

			// Create a pod with status annotations simulating the sidecar's work.
			pod := &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName + "-job-pod",
					Namespace: namespace,
					Labels: map[string]string{
						"batch.kubernetes.io/job-name": resourceName + "-job",
						LabelManagedBy:                 ManagedByValue,
					},
					Annotations: map[string]string{
						AnnotationCommitSha: "abc123",
						AnnotationPush:      "success",
					},
					OwnerReferences: []metav1.OwnerReference{
						{
							APIVersion: "batch/v1",
							Kind:       "Job",
							Name:       resourceName + "-job",
							Controller: boolPtr(true),
						},
					},
				},
				Spec: corev1.PodSpec{
					Containers:    []corev1.Container{{Name: "agent", Image: "test"}},
					RestartPolicy: corev1.RestartPolicyNever,
				},
			}
			Expect(k8sClient.Create(ctx, pod)).To(Succeed())
			// Set pod status with terminated container and exit code.
			pod.Status.ContainerStatuses = []corev1.ContainerStatus{
				{
					Name: AgentContainerName,
					State: corev1.ContainerState{
						Terminated: &corev1.ContainerStateTerminated{
							ExitCode: 0,
						},
					},
				},
			}
			Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
		})

		AfterEach(func() {
			ar := &kapsisv1alpha1.AgentRequest{}
			if err := k8sClient.Get(ctx, nn, ar); err == nil {
				Expect(k8sClient.Delete(ctx, ar)).To(Succeed())
			}
			job := &batchv1.Job{}
			jobNN := types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}
			if err := k8sClient.Get(ctx, jobNN, job); err == nil {
				Expect(k8sClient.Delete(ctx, job)).To(Succeed())
			}
			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-job-pod", Namespace: namespace}
			if err := k8sClient.Get(ctx, podNN, pod); err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}
		})

		It("should set CR status to Complete", func() {
			result, err := newReconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nn})
			Expect(err).NotTo(HaveOccurred())
			Expect(result.RequeueAfter).To(BeZero(), "should not requeue a completed CR")
			Expect(result.Requeue).To(BeFalse())

			updatedAR := &kapsisv1alpha1.AgentRequest{}
			Expect(k8sClient.Get(ctx, nn, updatedAR)).To(Succeed())
			Expect(updatedAR.Status.Phase).To(Equal(kapsisv1alpha1.PhaseComplete))

			By("verifying CommitSha from pod annotation is bridged to CR status")
			Expect(updatedAR.Status.CommitSha).To(Equal("abc123"))

			By("verifying PushStatus from pod annotation is bridged to CR status")
			Expect(updatedAR.Status.PushStatus).To(Equal("success"))

			By("verifying ExitCode from pod container state is bridged")
			Expect(updatedAR.Status.ExitCode).NotTo(BeNil())
			Expect(*updatedAR.Status.ExitCode).To(BeEquivalentTo(0))
		})
	})

	// ── Job failed ──────────────────────────────────────────────────────────────
	Context("When a Job has failed", func() {
		const resourceName = "test-failed-job"

		ctx := context.Background()
		nn := types.NamespacedName{Name: resourceName, Namespace: namespace}

		BeforeEach(func() {
			ar := newMinimalAR(resourceName)
			Expect(k8sClient.Create(ctx, ar)).To(Succeed())

			ar.Status.Phase = kapsisv1alpha1.PhaseRunning
			ar.Status.JobName = resourceName + "-job"
			Expect(k8sClient.Status().Update(ctx, ar)).To(Succeed())

			job := &batchv1.Job{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName + "-job",
					Namespace: namespace,
					Labels: map[string]string{
						LabelAgentType: "claude-cli",
						LabelAgentID:   resourceName,
						LabelManagedBy: ManagedByValue,
					},
				},
				Spec: batchv1.JobSpec{
					Template: corev1.PodTemplateSpec{
						Spec: corev1.PodSpec{
							Containers:    []corev1.Container{{Name: "agent", Image: "test"}},
							RestartPolicy: corev1.RestartPolicyNever,
						},
					},
				},
			}
			Expect(k8sClient.Create(ctx, job)).To(Succeed())

			// Set Job status to Failed.
			job.Status.Conditions = []batchv1.JobCondition{
				{
					Type:    batchv1.JobFailed,
					Status:  corev1.ConditionTrue,
					Reason:  "BackoffLimitExceeded",
					Message: "agent process exited with error",
				},
			}
			Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())

			// Create a pod with a non-zero exit code.
			pod := &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName + "-job-pod",
					Namespace: namespace,
					Labels: map[string]string{
						"batch.kubernetes.io/job-name": resourceName + "-job",
						LabelManagedBy:                 ManagedByValue,
					},
					OwnerReferences: []metav1.OwnerReference{
						{
							APIVersion: "batch/v1",
							Kind:       "Job",
							Name:       resourceName + "-job",
							Controller: boolPtr(true),
						},
					},
				},
				Spec: corev1.PodSpec{
					Containers:    []corev1.Container{{Name: "agent", Image: "test"}},
					RestartPolicy: corev1.RestartPolicyNever,
				},
			}
			Expect(k8sClient.Create(ctx, pod)).To(Succeed())
			pod.Status.ContainerStatuses = []corev1.ContainerStatus{
				{
					Name: AgentContainerName,
					State: corev1.ContainerState{
						Terminated: &corev1.ContainerStateTerminated{
							ExitCode: 1,
						},
					},
				},
			}
			Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
		})

		AfterEach(func() {
			ar := &kapsisv1alpha1.AgentRequest{}
			if err := k8sClient.Get(ctx, nn, ar); err == nil {
				Expect(k8sClient.Delete(ctx, ar)).To(Succeed())
			}
			job := &batchv1.Job{}
			jobNN := types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}
			if err := k8sClient.Get(ctx, jobNN, job); err == nil {
				Expect(k8sClient.Delete(ctx, job)).To(Succeed())
			}
			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-job-pod", Namespace: namespace}
			if err := k8sClient.Get(ctx, podNN, pod); err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}
		})

		It("should set CR status to Failed with error", func() {
			result, err := newReconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nn})
			Expect(err).NotTo(HaveOccurred())
			Expect(result.RequeueAfter).To(BeZero(), "should not requeue a failed CR")

			updatedAR := &kapsisv1alpha1.AgentRequest{}
			Expect(k8sClient.Get(ctx, nn, updatedAR)).To(Succeed())
			Expect(updatedAR.Status.Phase).To(Equal(kapsisv1alpha1.PhaseFailed))
			Expect(updatedAR.Status.Error).To(ContainSubstring("agent process exited with error"))

			By("verifying ExitCode from pod container state is bridged for failed job")
			Expect(updatedAR.Status.ExitCode).NotTo(BeNil())
			Expect(*updatedAR.Status.ExitCode).To(BeEquivalentTo(1))
		})
	})

	// ── Not found ───────────────────────────────────────────────────────────────
	Context("When the AgentRequest has been deleted", func() {
		It("should handle not-found gracefully", func() {
			result, err := newReconciler().Reconcile(context.Background(), reconcile.Request{
				NamespacedName: types.NamespacedName{Name: "nonexistent-resource", Namespace: namespace},
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(result).To(Equal(reconcile.Result{}))
		})
	})

	// ── Network mode: filtered ──────────────────────────────────────────────────
	Context("When reconciling with network mode 'filtered'", func() {
		const resourceName = "test-netpol-filtered"

		ctx := context.Background()
		nn := types.NamespacedName{Name: resourceName, Namespace: namespace}

		BeforeEach(func() {
			ar := newMinimalAR(resourceName)
			ar.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "filtered"}
			err := k8sClient.Get(ctx, nn, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			ar := &kapsisv1alpha1.AgentRequest{}
			if err := k8sClient.Get(ctx, nn, ar); err == nil {
				Expect(k8sClient.Delete(ctx, ar)).To(Succeed())
			}
			job := &batchv1.Job{}
			jobNN := types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}
			if err := k8sClient.Get(ctx, jobNN, job); err == nil {
				Expect(k8sClient.Delete(ctx, job)).To(Succeed())
			}
			np := &networkingv1.NetworkPolicy{}
			if err := k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameFiltered, Namespace: namespace}, np); err == nil {
				Expect(k8sClient.Delete(ctx, np)).To(Succeed())
			}
		})

		It("should create a namespace-level filtered NetworkPolicy alongside the Job", func() {
			_, err := newReconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nn})
			Expect(err).NotTo(HaveOccurred())

			By("verifying the Job was created")
			job := &batchv1.Job{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}, job)).
				To(Succeed())

			By("verifying the namespace-level NetworkPolicy was created")
			np := &networkingv1.NetworkPolicy{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameFiltered, Namespace: namespace}, np)).
				To(Succeed())

			By("verifying NetworkPolicy has both Ingress and Egress policy types")
			Expect(np.Spec.PolicyTypes).To(ContainElements(
				networkingv1.PolicyTypeIngress,
				networkingv1.PolicyTypeEgress,
			))

			By("verifying 2 egress rules (DNS + service ports)")
			Expect(np.Spec.Egress).To(HaveLen(2))

			By("verifying deny-all ingress (empty ingress rules)")
			Expect(np.Spec.Ingress).To(BeEmpty())

			By("verifying NetworkPolicy is NOT owned by any single AgentRequest (namespace-level)")
			Expect(np.OwnerReferences).To(BeEmpty())
		})
	})

	// ── Network mode: none ──────────────────────────────────────────────────────
	Context("When reconciling with network mode 'none'", func() {
		const resourceName = "test-netpol-none"

		ctx := context.Background()
		nn := types.NamespacedName{Name: resourceName, Namespace: namespace}

		BeforeEach(func() {
			ar := newMinimalAR(resourceName)
			ar.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "none"}
			err := k8sClient.Get(ctx, nn, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			ar := &kapsisv1alpha1.AgentRequest{}
			if err := k8sClient.Get(ctx, nn, ar); err == nil {
				Expect(k8sClient.Delete(ctx, ar)).To(Succeed())
			}
			job := &batchv1.Job{}
			jobNN := types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}
			if err := k8sClient.Get(ctx, jobNN, job); err == nil {
				Expect(k8sClient.Delete(ctx, job)).To(Succeed())
			}
			np := &networkingv1.NetworkPolicy{}
			if err := k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameNone, Namespace: namespace}, np); err == nil {
				Expect(k8sClient.Delete(ctx, np)).To(Succeed())
			}
		})

		It("should create a deny-all NetworkPolicy", func() {
			_, err := newReconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nn})
			Expect(err).NotTo(HaveOccurred())

			np := &networkingv1.NetworkPolicy{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameNone, Namespace: namespace}, np)).
				To(Succeed())

			Expect(np.Spec.PolicyTypes).To(ContainElement(networkingv1.PolicyTypeEgress))
			Expect(np.Spec.Egress).To(BeEmpty(), "deny-all egress should have no rules")
		})
	})

	// ── Network mode: open ──────────────────────────────────────────────────────
	Context("When reconciling with network mode 'open'", func() {
		const resourceName = "test-netpol-open"

		ctx := context.Background()
		nn := types.NamespacedName{Name: resourceName, Namespace: namespace}

		BeforeEach(func() {
			ar := newMinimalAR(resourceName)
			ar.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "open"}
			err := k8sClient.Get(ctx, nn, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			ar := &kapsisv1alpha1.AgentRequest{}
			if err := k8sClient.Get(ctx, nn, ar); err == nil {
				Expect(k8sClient.Delete(ctx, ar)).To(Succeed())
			}
			job := &batchv1.Job{}
			jobNN := types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}
			if err := k8sClient.Get(ctx, jobNN, job); err == nil {
				Expect(k8sClient.Delete(ctx, job)).To(Succeed())
			}
		})

		It("should not create a NetworkPolicy", func() {
			_, err := newReconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nn})
			Expect(err).NotTo(HaveOccurred())

			By("verifying the Job was created")
			job := &batchv1.Job{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}, job)).
				To(Succeed())

			By("verifying no NetworkPolicy exists for open mode")
			np := &networkingv1.NetworkPolicy{}
			err = k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameFiltered, Namespace: namespace}, np)
			Expect(errors.IsNotFound(err)).To(BeTrue(), "should not create filtered NetworkPolicy for open mode")

			By("verifying neither filtered nor none NetworkPolicy exists for open mode")
			npNone := &networkingv1.NetworkPolicy{}
			errNone := k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameNone, Namespace: namespace}, npNone)
			Expect(errors.IsNotFound(errNone)).To(BeTrue(), "should not create none NetworkPolicy for open mode")
		})
	})

	// ── NetworkPolicy idempotency ──────────────────────────────────────────────
	Context("When reconciling the same AgentRequest twice (NetworkPolicy idempotency)", func() {
		const resourceName = "test-netpol-idempotent"

		ctx := context.Background()
		nn := types.NamespacedName{Name: resourceName, Namespace: namespace}

		BeforeEach(func() {
			ar := newMinimalAR(resourceName)
			ar.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "filtered"}
			err := k8sClient.Get(ctx, nn, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			ar := &kapsisv1alpha1.AgentRequest{}
			if err := k8sClient.Get(ctx, nn, ar); err == nil {
				Expect(k8sClient.Delete(ctx, ar)).To(Succeed())
			}
			job := &batchv1.Job{}
			jobNN := types.NamespacedName{Name: resourceName + "-job", Namespace: namespace}
			if err := k8sClient.Get(ctx, jobNN, job); err == nil {
				Expect(k8sClient.Delete(ctx, job)).To(Succeed())
			}
			np := &networkingv1.NetworkPolicy{}
			if err := k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameFiltered, Namespace: namespace}, np); err == nil {
				Expect(k8sClient.Delete(ctx, np)).To(Succeed())
			}
		})

		It("should not error on the second reconcile when the NetworkPolicy already exists", func() {
			By("first reconcile: creates Job and NetworkPolicy")
			_, err := newReconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nn})
			Expect(err).NotTo(HaveOccurred())

			np := &networkingv1.NetworkPolicy{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameFiltered, Namespace: namespace}, np)).
				To(Succeed())
			firstRV := np.ResourceVersion

			By("creating a second AgentRequest in the same namespace")
			ar2Name := resourceName + "-2"
			ar2 := newMinimalAR(ar2Name)
			ar2.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: "filtered"}
			Expect(k8sClient.Create(ctx, ar2)).To(Succeed())
			defer func() {
				if err := k8sClient.Delete(ctx, ar2); err != nil {
					// cleanup best-effort
				}
				j2 := &batchv1.Job{}
				if err := k8sClient.Get(ctx, types.NamespacedName{Name: ar2Name + "-job", Namespace: namespace}, j2); err == nil {
					_ = k8sClient.Delete(ctx, j2)
				}
			}()

			By("second reconcile: NetworkPolicy already exists, should succeed")
			_, err = newReconciler().Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{Name: ar2Name, Namespace: namespace},
			})
			Expect(err).NotTo(HaveOccurred())

			By("verifying NetworkPolicy ResourceVersion is unchanged (not recreated)")
			np2 := &networkingv1.NetworkPolicy{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: networkPolicyNameFiltered, Namespace: namespace}, np2)).
				To(Succeed())
			Expect(np2.ResourceVersion).To(Equal(firstRV))
		})
	})
})
