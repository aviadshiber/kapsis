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
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

var _ = Describe("AgentRequest Controller", func() {

	const (
		namespace = "default"
	)

	Context("When reconciling a new AgentRequest", func() {
		const resourceName = "test-new-cr"

		ctx := context.Background()

		typeNamespacedName := types.NamespacedName{
			Name:      resourceName,
			Namespace: namespace,
		}

		BeforeEach(func() {
			By("creating the AgentRequest CR")
			ar := &kapsisv1alpha1.AgentRequest{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName,
					Namespace: namespace,
				},
				Spec: kapsisv1alpha1.AgentRequestSpec{
					Image: "ghcr.io/kapsis/agent:latest",
					Agent: kapsisv1alpha1.AgentSpec{
						Type:    "claude-cli",
						Command: []string{"/bin/agent", "--task", "test"},
						Workdir: "/workspace",
					},
					PodAnnotations: map[string]string{
						"vault.hashicorp.com/agent-inject": "true",
						"example.com/custom":               "value",
					},
				},
			}
			err := k8sClient.Get(ctx, typeNamespacedName, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			// Clean up the CR.
			resource := &kapsisv1alpha1.AgentRequest{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			if err == nil {
				Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
			}

			// Clean up the pod if it exists.
			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			err = k8sClient.Get(ctx, podNN, pod)
			if err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}
		})

		It("should create a Pod when reconciling a new AgentRequest", func() {
			By("reconciling the created resource")
			reconciler := &AgentRequestReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(result.RequeueAfter).To(BeNumerically(">", 0), "should requeue to monitor the pod")

			By("verifying the pod was created")
			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			Expect(k8sClient.Get(ctx, podNN, pod)).To(Succeed())

			Expect(pod.Spec.Containers).To(HaveLen(1))
			Expect(pod.Spec.Containers[0].Image).To(Equal("ghcr.io/kapsis/agent:latest"))
			Expect(pod.Spec.Containers[0].Command).To(Equal([]string{"/bin/agent", "--task", "test"}))
			Expect(pod.Spec.Containers[0].WorkingDir).To(Equal("/workspace"))
			Expect(pod.Spec.RestartPolicy).To(Equal(corev1.RestartPolicyNever))

			By("verifying labels")
			Expect(pod.Labels[LabelAgentType]).To(Equal("claude-cli"))
			Expect(pod.Labels[LabelAgentID]).To(Equal(resourceName))
			Expect(pod.Labels[LabelManagedBy]).To(Equal(ManagedByValue))

			By("verifying pod annotations are passed through")
			Expect(pod.Annotations).To(HaveKeyWithValue("vault.hashicorp.com/agent-inject", "true"))
			Expect(pod.Annotations).To(HaveKeyWithValue("example.com/custom", "value"))

			By("verifying service account token is not mounted")
			Expect(pod.Spec.AutomountServiceAccountToken).NotTo(BeNil())
			Expect(*pod.Spec.AutomountServiceAccountToken).To(BeFalse())

			By("verifying Kapsis environment variables")
			envNames := make(map[string]string)
			for _, env := range pod.Spec.Containers[0].Env {
				envNames[env.Name] = env.Value
			}
			Expect(envNames["KAPSIS_BACKEND"]).To(Equal("k8s"))
			Expect(envNames["KAPSIS_AGENT_ID"]).To(Equal(resourceName))
			Expect(envNames["KAPSIS_AGENT_TYPE"]).To(Equal("claude-cli"))

			By("verifying CR status was updated to Initializing")
			updatedAR := &kapsisv1alpha1.AgentRequest{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, updatedAR)).To(Succeed())
			Expect(updatedAR.Status.Phase).To(Equal(kapsisv1alpha1.PhaseInitializing))
			Expect(updatedAR.Status.PodName).To(Equal(resourceName + "-pod"))

			By("verifying owner reference is set")
			Expect(pod.OwnerReferences).To(HaveLen(1))
			Expect(pod.OwnerReferences[0].Name).To(Equal(resourceName))

			By("verifying Guaranteed QoS (requests = limits)")
			resources := pod.Spec.Containers[0].Resources
			Expect(resources.Requests).To(Equal(resources.Limits))

			By("verifying capabilities are dropped (standard profile)")
			sc := pod.Spec.Containers[0].SecurityContext
			Expect(sc.Capabilities).NotTo(BeNil())
			Expect(sc.Capabilities.Drop).To(ContainElement(corev1.Capability("ALL")))
			Expect(sc.Capabilities.Add).To(ContainElements(
				corev1.Capability("CHOWN"),
				corev1.Capability("KILL"),
				corev1.Capability("NET_BIND_SERVICE"),
			))
		})
	})

	Context("When a Pod has succeeded", func() {
		const resourceName = "test-completed-pod"

		ctx := context.Background()

		typeNamespacedName := types.NamespacedName{
			Name:      resourceName,
			Namespace: namespace,
		}

		BeforeEach(func() {
			By("creating the AgentRequest CR with Initializing status")
			ar := &kapsisv1alpha1.AgentRequest{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName,
					Namespace: namespace,
				},
				Spec: kapsisv1alpha1.AgentRequestSpec{
					Image: "ghcr.io/kapsis/agent:latest",
					Agent: kapsisv1alpha1.AgentSpec{
						Type:    "claude-cli",
						Command: []string{"/bin/agent"},
						Workdir: "/workspace",
					},
				},
			}
			Expect(k8sClient.Create(ctx, ar)).To(Succeed())

			// Set status to Initializing to simulate that the pod was already created.
			ar.Status.Phase = kapsisv1alpha1.PhaseInitializing
			ar.Status.PodName = resourceName + "-pod"
			Expect(k8sClient.Status().Update(ctx, ar)).To(Succeed())

			By("creating a pod that has succeeded")
			exitCode := int32(0)
			pod := &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName + "-pod",
					Namespace: namespace,
					Labels: map[string]string{
						LabelAgentType: "claude-cli",
						LabelAgentID:   resourceName,
						LabelManagedBy: ManagedByValue,
					},
					Annotations: map[string]string{
						AnnotationCommitSha: "abc123def",
						AnnotationPush:      "success",
					},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:    "agent",
							Image:   "ghcr.io/kapsis/agent:latest",
							Command: []string{"/bin/agent"},
						},
					},
					RestartPolicy: corev1.RestartPolicyNever,
				},
			}
			Expect(k8sClient.Create(ctx, pod)).To(Succeed())

			// Update the pod status to Succeeded.
			pod.Status.Phase = corev1.PodSucceeded
			now := metav1.Now()
			pod.Status.ContainerStatuses = []corev1.ContainerStatus{
				{
					Name: "agent",
					State: corev1.ContainerState{
						Terminated: &corev1.ContainerStateTerminated{
							ExitCode:   exitCode,
							StartedAt:  now,
							FinishedAt: now,
						},
					},
				},
			}
			Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
		})

		AfterEach(func() {
			resource := &kapsisv1alpha1.AgentRequest{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			if err == nil {
				Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
			}

			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			err = k8sClient.Get(ctx, podNN, pod)
			if err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}
		})

		It("should set CR status to Complete with exit code 0", func() {
			reconciler := &AgentRequestReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(result.RequeueAfter).To(BeZero(), "should not requeue a completed CR")
			Expect(result.Requeue).To(BeFalse())

			By("verifying CR status")
			updatedAR := &kapsisv1alpha1.AgentRequest{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, updatedAR)).To(Succeed())
			Expect(updatedAR.Status.Phase).To(Equal(kapsisv1alpha1.PhaseComplete))
			Expect(updatedAR.Status.ExitCode).NotTo(BeNil())
			Expect(*updatedAR.Status.ExitCode).To(Equal(int32(0)))
			Expect(updatedAR.Status.CommitSha).To(Equal("abc123def"))
			Expect(updatedAR.Status.PushStatus).To(Equal("success"))
		})
	})

	Context("When a Pod has failed", func() {
		const resourceName = "test-failed-pod"

		ctx := context.Background()

		typeNamespacedName := types.NamespacedName{
			Name:      resourceName,
			Namespace: namespace,
		}

		BeforeEach(func() {
			By("creating the AgentRequest CR with Initializing status")
			ar := &kapsisv1alpha1.AgentRequest{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName,
					Namespace: namespace,
				},
				Spec: kapsisv1alpha1.AgentRequestSpec{
					Image: "ghcr.io/kapsis/agent:latest",
					Agent: kapsisv1alpha1.AgentSpec{
						Type:    "claude-cli",
						Command: []string{"/bin/agent"},
						Workdir: "/workspace",
					},
				},
			}
			Expect(k8sClient.Create(ctx, ar)).To(Succeed())

			ar.Status.Phase = kapsisv1alpha1.PhaseRunning
			ar.Status.PodName = resourceName + "-pod"
			Expect(k8sClient.Status().Update(ctx, ar)).To(Succeed())

			By("creating a pod that has failed")
			exitCode := int32(1)
			pod := &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName + "-pod",
					Namespace: namespace,
					Labels: map[string]string{
						LabelAgentType: "claude-cli",
						LabelAgentID:   resourceName,
						LabelManagedBy: ManagedByValue,
					},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:    "agent",
							Image:   "ghcr.io/kapsis/agent:latest",
							Command: []string{"/bin/agent"},
						},
					},
					RestartPolicy: corev1.RestartPolicyNever,
				},
			}
			Expect(k8sClient.Create(ctx, pod)).To(Succeed())

			// Update the pod status to Failed.
			pod.Status.Phase = corev1.PodFailed
			now := metav1.Now()
			pod.Status.ContainerStatuses = []corev1.ContainerStatus{
				{
					Name: "agent",
					State: corev1.ContainerState{
						Terminated: &corev1.ContainerStateTerminated{
							ExitCode:   exitCode,
							Reason:     "Error",
							Message:    "agent process exited with error",
							StartedAt:  now,
							FinishedAt: now,
						},
					},
				},
			}
			Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
		})

		AfterEach(func() {
			resource := &kapsisv1alpha1.AgentRequest{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			if err == nil {
				Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
			}

			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			err = k8sClient.Get(ctx, podNN, pod)
			if err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}
		})

		It("should set CR status to Failed with exit code and error", func() {
			reconciler := &AgentRequestReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(result.RequeueAfter).To(BeZero(), "should not requeue a failed CR")
			Expect(result.Requeue).To(BeFalse())

			By("verifying CR status")
			updatedAR := &kapsisv1alpha1.AgentRequest{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, updatedAR)).To(Succeed())
			Expect(updatedAR.Status.Phase).To(Equal(kapsisv1alpha1.PhaseFailed))
			Expect(updatedAR.Status.ExitCode).NotTo(BeNil())
			Expect(*updatedAR.Status.ExitCode).To(Equal(int32(1)))
			Expect(updatedAR.Status.Error).To(Equal("agent process exited with error"))
			Expect(updatedAR.Status.CompletedAt).NotTo(BeNil())
		})
	})

	Context("When the AgentRequest has been deleted", func() {
		It("should handle not-found gracefully", func() {
			reconciler := &AgentRequestReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			result, err := reconciler.Reconcile(context.Background(), reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      "nonexistent-resource",
					Namespace: namespace,
				},
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(result).To(Equal(reconcile.Result{}))
		})
	})

	Context("When reconciling with network mode 'filtered'", func() {
		const resourceName = "test-netpol-filtered"

		ctx := context.Background()

		typeNamespacedName := types.NamespacedName{
			Name:      resourceName,
			Namespace: namespace,
		}

		BeforeEach(func() {
			By("creating the AgentRequest CR with filtered network mode")
			ar := &kapsisv1alpha1.AgentRequest{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName,
					Namespace: namespace,
				},
				Spec: kapsisv1alpha1.AgentRequestSpec{
					Image: "ghcr.io/kapsis/agent:latest",
					Agent: kapsisv1alpha1.AgentSpec{
						Type:    "claude-cli",
						Command: []string{"/bin/agent"},
						Workdir: "/workspace",
					},
					Network: &kapsisv1alpha1.NetworkSpec{
						Mode: "filtered",
					},
				},
			}
			err := k8sClient.Get(ctx, typeNamespacedName, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			resource := &kapsisv1alpha1.AgentRequest{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			if err == nil {
				Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
			}

			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			err = k8sClient.Get(ctx, podNN, pod)
			if err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}

			np := &networkingv1.NetworkPolicy{}
			npNN := types.NamespacedName{Name: resourceName + NetworkPolicySuffix, Namespace: namespace}
			err = k8sClient.Get(ctx, npNN, np)
			if err == nil {
				Expect(k8sClient.Delete(ctx, np)).To(Succeed())
			}
		})

		It("should create a NetworkPolicy alongside the Pod", func() {
			reconciler := &AgentRequestReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())

			By("verifying the Pod was created")
			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			Expect(k8sClient.Get(ctx, podNN, pod)).To(Succeed())

			By("verifying the NetworkPolicy was created")
			np := &networkingv1.NetworkPolicy{}
			npNN := types.NamespacedName{Name: resourceName + NetworkPolicySuffix, Namespace: namespace}
			Expect(k8sClient.Get(ctx, npNN, np)).To(Succeed())

			By("verifying NetworkPolicy has Egress policy type")
			Expect(np.Spec.PolicyTypes).To(ContainElement(networkingv1.PolicyTypeEgress))

			By("verifying 2 egress rules (DNS + service ports)")
			Expect(np.Spec.Egress).To(HaveLen(2))

			By("verifying owner reference points to the CR")
			Expect(np.OwnerReferences).To(HaveLen(1))
			Expect(np.OwnerReferences[0].Name).To(Equal(resourceName))
		})
	})

	Context("When reconciling with network mode 'none'", func() {
		const resourceName = "test-netpol-none"

		ctx := context.Background()

		typeNamespacedName := types.NamespacedName{
			Name:      resourceName,
			Namespace: namespace,
		}

		BeforeEach(func() {
			By("creating the AgentRequest CR with none network mode")
			ar := &kapsisv1alpha1.AgentRequest{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName,
					Namespace: namespace,
				},
				Spec: kapsisv1alpha1.AgentRequestSpec{
					Image: "ghcr.io/kapsis/agent:latest",
					Agent: kapsisv1alpha1.AgentSpec{
						Type:    "claude-cli",
						Command: []string{"/bin/agent"},
						Workdir: "/workspace",
					},
					Network: &kapsisv1alpha1.NetworkSpec{
						Mode: "none",
					},
				},
			}
			err := k8sClient.Get(ctx, typeNamespacedName, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			resource := &kapsisv1alpha1.AgentRequest{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			if err == nil {
				Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
			}

			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			err = k8sClient.Get(ctx, podNN, pod)
			if err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}

			np := &networkingv1.NetworkPolicy{}
			npNN := types.NamespacedName{Name: resourceName + NetworkPolicySuffix, Namespace: namespace}
			err = k8sClient.Get(ctx, npNN, np)
			if err == nil {
				Expect(k8sClient.Delete(ctx, np)).To(Succeed())
			}
		})

		It("should create a deny-all NetworkPolicy", func() {
			reconciler := &AgentRequestReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())

			By("verifying the NetworkPolicy was created")
			np := &networkingv1.NetworkPolicy{}
			npNN := types.NamespacedName{Name: resourceName + NetworkPolicySuffix, Namespace: namespace}
			Expect(k8sClient.Get(ctx, npNN, np)).To(Succeed())

			By("verifying deny-all egress (empty Egress list)")
			Expect(np.Spec.PolicyTypes).To(ContainElement(networkingv1.PolicyTypeEgress))
			Expect(np.Spec.Egress).To(BeEmpty())

			By("verifying owner reference")
			Expect(np.OwnerReferences).To(HaveLen(1))
			Expect(np.OwnerReferences[0].Name).To(Equal(resourceName))
		})
	})

	Context("When reconciling with network mode 'open'", func() {
		const resourceName = "test-netpol-open"

		ctx := context.Background()

		typeNamespacedName := types.NamespacedName{
			Name:      resourceName,
			Namespace: namespace,
		}

		BeforeEach(func() {
			By("creating the AgentRequest CR with open network mode")
			ar := &kapsisv1alpha1.AgentRequest{
				ObjectMeta: metav1.ObjectMeta{
					Name:      resourceName,
					Namespace: namespace,
				},
				Spec: kapsisv1alpha1.AgentRequestSpec{
					Image: "ghcr.io/kapsis/agent:latest",
					Agent: kapsisv1alpha1.AgentSpec{
						Type:    "claude-cli",
						Command: []string{"/bin/agent"},
						Workdir: "/workspace",
					},
					Network: &kapsisv1alpha1.NetworkSpec{
						Mode: "open",
					},
				},
			}
			err := k8sClient.Get(ctx, typeNamespacedName, &kapsisv1alpha1.AgentRequest{})
			if err != nil && errors.IsNotFound(err) {
				Expect(k8sClient.Create(ctx, ar)).To(Succeed())
			}
		})

		AfterEach(func() {
			resource := &kapsisv1alpha1.AgentRequest{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			if err == nil {
				Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
			}

			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			err = k8sClient.Get(ctx, podNN, pod)
			if err == nil {
				Expect(k8sClient.Delete(ctx, pod)).To(Succeed())
			}
		})

		It("should not create a NetworkPolicy", func() {
			reconciler := &AgentRequestReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			_, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())

			By("verifying the Pod was created")
			pod := &corev1.Pod{}
			podNN := types.NamespacedName{Name: resourceName + "-pod", Namespace: namespace}
			Expect(k8sClient.Get(ctx, podNN, pod)).To(Succeed())

			By("verifying no NetworkPolicy exists")
			np := &networkingv1.NetworkPolicy{}
			npNN := types.NamespacedName{Name: resourceName + NetworkPolicySuffix, Namespace: namespace}
			err = k8sClient.Get(ctx, npNN, np)
			Expect(errors.IsNotFound(err)).To(BeTrue(), "NetworkPolicy should not exist for open mode")
		})
	})
})
