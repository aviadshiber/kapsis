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
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

const (
	// LabelAgentType identifies the agent type on managed pods.
	LabelAgentType = "kapsis.io/agent-type"
	// LabelAgentID identifies the agent instance on managed pods.
	LabelAgentID = "kapsis.io/agent-id"
	// LabelManagedBy identifies the managing controller.
	LabelManagedBy = "app.kubernetes.io/managed-by"
	// ManagedByValue is the value for the managed-by label.
	ManagedByValue = "kapsis-operator"

	defaultMemory = "8Gi"
	defaultCPU    = "4"
)

// PodName returns the deterministic pod name for an AgentRequest.
func PodName(cr *kapsisv1alpha1.AgentRequest) string {
	return cr.Name + "-pod"
}

// BuildPod constructs a Pod specification from an AgentRequest custom resource.
// The returned Pod has an owner reference set to the CR so that garbage collection
// works automatically when the CR is deleted.
func BuildPod(cr *kapsisv1alpha1.AgentRequest) (*corev1.Pod, error) {
	podName := PodName(cr)

	container, err := buildContainer(cr)
	if err != nil {
		return nil, fmt.Errorf("building container spec: %w", err)
	}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      podName,
			Namespace: cr.Namespace,
			Labels: map[string]string{
				LabelAgentType: cr.Spec.Agent.Type,
				LabelAgentID:   cr.Name,
				LabelManagedBy: ManagedByValue,
			},
		},
		Spec: corev1.PodSpec{
			Containers:    []corev1.Container{container},
			RestartPolicy: corev1.RestartPolicyNever,
		},
	}

	// SecurityContext: runAsNonRoot and readOnlyRootFilesystem based on profile.
	runAsNonRoot := true
	readOnlyRoot := shouldReadOnlyRoot(cr)
	pod.Spec.Containers[0].SecurityContext = &corev1.SecurityContext{
		RunAsNonRoot:             &runAsNonRoot,
		ReadOnlyRootFilesystem:   &readOnlyRoot,
		AllowPrivilegeEscalation: boolPtr(false),
		Capabilities:             buildCapabilities(cr),
	}

	// ServiceAccountName from security spec.
	if cr.Spec.Security != nil && cr.Spec.Security.ServiceAccountName != "" {
		pod.Spec.ServiceAccountName = cr.Spec.Security.ServiceAccountName
	}

	// ActiveDeadlineSeconds from TTL.
	if cr.Spec.TTL != nil {
		ttl := int64(*cr.Spec.TTL)
		pod.Spec.ActiveDeadlineSeconds = &ttl
	}

	// Volume mounts for ConfigMap mounts.
	volumes, volumeMounts := buildConfigMountVolumes(cr)
	if len(volumes) > 0 {
		pod.Spec.Volumes = append(pod.Spec.Volumes, volumes...)
		pod.Spec.Containers[0].VolumeMounts = append(pod.Spec.Containers[0].VolumeMounts, volumeMounts...)
	}

	// envFrom for secret references.
	pod.Spec.Containers[0].EnvFrom = buildSecretEnvFrom(cr)

	return pod, nil
}

// buildContainer constructs the primary container for the agent pod.
func buildContainer(cr *kapsisv1alpha1.AgentRequest) (corev1.Container, error) {
	container := corev1.Container{
		Name:    "agent",
		Image:   cr.Spec.Image,
		Command: cr.Spec.Agent.Command,
		Env:     buildEnvVars(cr),
	}

	if cr.Spec.Agent.Workdir != "" {
		container.WorkingDir = cr.Spec.Agent.Workdir
	}

	limits, err := buildResourceLimits(cr)
	if err != nil {
		return corev1.Container{}, err
	}
	container.Resources = corev1.ResourceRequirements{
		Requests: limits, // Guaranteed QoS: requests = limits
		Limits:   limits,
	}

	return container, nil
}

// buildEnvVars constructs environment variables from the CR spec plus
// Kapsis-injected variables (KAPSIS_BACKEND, KAPSIS_AGENT_ID, KAPSIS_AGENT_TYPE).
func buildEnvVars(cr *kapsisv1alpha1.AgentRequest) []corev1.EnvVar {
	// Kapsis-injected variables come first.
	envVars := []corev1.EnvVar{
		{Name: "KAPSIS_BACKEND", Value: "k8s"},
		{Name: "KAPSIS_AGENT_ID", Value: cr.Name},
		{Name: "KAPSIS_AGENT_TYPE", Value: cr.Spec.Agent.Type},
	}

	// User-specified variables from spec.environment.vars.
	if cr.Spec.Environment != nil {
		for _, v := range cr.Spec.Environment.Vars {
			envVars = append(envVars, corev1.EnvVar{
				Name:  v.Name,
				Value: v.Value,
			})
		}
	}

	return envVars
}

// buildResourceLimits parses resource strings into Kubernetes resource quantities.
func buildResourceLimits(cr *kapsisv1alpha1.AgentRequest) (corev1.ResourceList, error) {
	memStr := defaultMemory
	cpuStr := defaultCPU

	if cr.Spec.Resources != nil {
		if cr.Spec.Resources.Memory != "" {
			memStr = cr.Spec.Resources.Memory
		}
		if cr.Spec.Resources.CPU != "" {
			cpuStr = cr.Spec.Resources.CPU
		}
	}

	memQty, err := resource.ParseQuantity(memStr)
	if err != nil {
		return nil, fmt.Errorf("parsing memory quantity %q: %w", memStr, err)
	}

	cpuQty, err := resource.ParseQuantity(cpuStr)
	if err != nil {
		return nil, fmt.Errorf("parsing cpu quantity %q: %w", cpuStr, err)
	}

	return corev1.ResourceList{
		corev1.ResourceMemory: memQty,
		corev1.ResourceCPU:    cpuQty,
	}, nil
}

// buildConfigMountVolumes creates volumes and volume mounts for each ConfigMount
// in the environment spec.
func buildConfigMountVolumes(cr *kapsisv1alpha1.AgentRequest) ([]corev1.Volume, []corev1.VolumeMount) {
	if cr.Spec.Environment == nil {
		return nil, nil
	}

	var volumes []corev1.Volume
	var mounts []corev1.VolumeMount

	for i, cm := range cr.Spec.Environment.ConfigMounts {
		volName := fmt.Sprintf("config-%d", i)

		volumes = append(volumes, corev1.Volume{
			Name: volName,
			VolumeSource: corev1.VolumeSource{
				ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{
						Name: cm.Name,
					},
				},
			},
		})

		mounts = append(mounts, corev1.VolumeMount{
			Name:      volName,
			MountPath: cm.MountPath,
			ReadOnly:  true,
		})
	}

	return volumes, mounts
}

// buildSecretEnvFrom creates EnvFromSource entries for each secret reference
// in the environment spec.
func buildSecretEnvFrom(cr *kapsisv1alpha1.AgentRequest) []corev1.EnvFromSource {
	if cr.Spec.Environment == nil {
		return nil
	}

	var envFrom []corev1.EnvFromSource
	for _, ref := range cr.Spec.Environment.SecretRefs {
		envFrom = append(envFrom, corev1.EnvFromSource{
			SecretRef: &corev1.SecretEnvSource{
				LocalObjectReference: corev1.LocalObjectReference{
					Name: ref.Name,
				},
			},
		})
	}

	return envFrom
}

// shouldReadOnlyRoot returns true if the security profile requires a read-only
// root filesystem (strict or paranoid).
func shouldReadOnlyRoot(cr *kapsisv1alpha1.AgentRequest) bool {
	if cr.Spec.Security == nil {
		return false
	}
	switch cr.Spec.Security.Profile {
	case "strict", "paranoid":
		return true
	default:
		return false
	}
}

// buildCapabilities returns container capabilities based on security profile.
// Minimal: no restrictions. Standard/strict/paranoid: drop ALL, add back minimal set.
// Matches KAPSIS_CAPS_MINIMAL from scripts/lib/security.sh for Podman parity.
func buildCapabilities(cr *kapsisv1alpha1.AgentRequest) *corev1.Capabilities {
	profile := "standard"
	if cr.Spec.Security != nil && cr.Spec.Security.Profile != "" {
		profile = cr.Spec.Security.Profile
	}
	if profile == "minimal" {
		return nil
	}
	return &corev1.Capabilities{
		Drop: []corev1.Capability{"ALL"},
		Add: []corev1.Capability{
			"CHOWN", "FOWNER", "FSETID", "KILL",
			"SETGID", "SETUID", "SYS_NICE", "NET_BIND_SERVICE",
		},
	}
}

func boolPtr(b bool) *bool {
	return &b
}
