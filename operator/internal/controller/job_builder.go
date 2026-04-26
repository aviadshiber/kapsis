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

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

const (
	// AgentContainerName is the name of the primary agent container in the Job pod.
	AgentContainerName = "agent"

	// StatusSidecarContainerName is the name of the status/audit sidecar container.
	// This sidecar watches /kapsis-status/status.json and patches pod annotations
	// so the operator can bridge real-time status without polling.
	// It also tails /kapsis-audit/*.jsonl to stdout for log-aggregator capture.
	StatusSidecarContainerName = "status-sidecar"

	// DefaultStatusSidecarImage is the default container image for the status/audit sidecar.
	// Override at runtime by setting KAPSIS_STATUS_SIDECAR_IMAGE on the operator Deployment.
	DefaultStatusSidecarImage = "ghcr.io/aviadshiber/kapsis/status-sidecar:latest"

	// LabelAgentType identifies the agent type on managed Jobs and pods.
	LabelAgentType = "kapsis.aviadshiber.github.io/agent-type"
	// LabelAgentID identifies the specific agent instance.
	LabelAgentID = "kapsis.aviadshiber.github.io/agent-id"
	// LabelManagedBy identifies the managing controller.
	LabelManagedBy = "app.kubernetes.io/managed-by"
	// ManagedByValue is the value for the managed-by label.
	ManagedByValue = "kapsis-operator"

	defaultMemory            = "8Gi"
	defaultCPU               = "4"
	defaultWorkspaceSizeLimit = "20Gi"
	defaultBuildCacheMountPath = "/root/.m2"

	// maxTTLSecondsAfterFinished caps Job retention to 4 hours after completion.
	maxTTLSecondsAfterFinished = int32(4 * 3600)

	// Projected SA token expiration for the status sidecar.
	sidecarTokenExpirationSeconds = int64(3600)
)

// JobName returns the deterministic Job name for an AgentRequest.
func JobName(cr *kapsisv1alpha1.AgentRequest) string {
	return cr.Name + "-job"
}

// BuildJob constructs a batch/v1 Job specification from an AgentRequest CR.
// The Job uses BackoffLimit=0 (no retries) and derives its deadline from spec.ttl.
// Each pod contains two containers: the agent and a status sidecar.
// sidecarImage is the container image for the status/audit sidecar; if empty,
// DefaultStatusSidecarImage is used.
func BuildJob(cr *kapsisv1alpha1.AgentRequest, sidecarImage string) (*batchv1.Job, error) {
	if sidecarImage == "" {
		sidecarImage = DefaultStatusSidecarImage
	}

	agentContainer, err := buildAgentContainer(cr)
	if err != nil {
		return nil, fmt.Errorf("building agent container: %w", err)
	}

	sidecarContainer := buildStatusSidecarContainer(sidecarImage)

	volumes, err := buildVolumes(cr)
	if err != nil {
		return nil, fmt.Errorf("building volumes: %w", err)
	}

	agentContainer.VolumeMounts = buildAgentVolumeMounts(cr)
	sidecarContainer.VolumeMounts = buildSidecarVolumeMounts()

	ttl := effectiveTTL(cr)
	backoffLimit := int32(0)
	ttlAfterFinished := min(int32(ttl*2), maxTTLSecondsAfterFinished)

	labels := map[string]string{
		LabelAgentType: cr.Spec.Agent.Type,
		LabelAgentID:   cr.Name,
		LabelManagedBy: ManagedByValue,
	}

	// Merge user-supplied pod annotations without overwriting operator labels.
	podAnnotations := make(map[string]string, len(cr.Spec.PodAnnotations))
	for k, v := range cr.Spec.PodAnnotations {
		podAnnotations[k] = v
	}

	saName := effectiveServiceAccount(cr)

	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      JobName(cr),
			Namespace: cr.Namespace,
			Labels:    labels,
		},
		Spec: batchv1.JobSpec{
			BackoffLimit:            &backoffLimit,
			ActiveDeadlineSeconds:   &ttl,
			TTLSecondsAfterFinished: &ttlAfterFinished,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels:      labels,
					Annotations: podAnnotations,
				},
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					// Disable auto-mount at the pod level; sidecar gets the token
					// via a projected volume so the main agent container stays credential-free.
					AutomountServiceAccountToken: boolPtr(false),
					ServiceAccountName:           saName,
					SecurityContext:              buildPodSecurityContext(cr),
					Containers:                   []corev1.Container{agentContainer, sidecarContainer},
					Volumes:                      volumes,
				},
			},
		},
	}

	// RuntimeClass for paranoid profile or explicit override.
	if cr.Spec.Security != nil && cr.Spec.Security.RuntimeClass != "" {
		job.Spec.Template.Spec.RuntimeClassName = &cr.Spec.Security.RuntimeClass
	}

	// AppArmor unconfined annotation required for nested containers (userns).
	if nestedContainersEnabled(cr) {
		if job.Spec.Template.Annotations == nil {
			job.Spec.Template.Annotations = make(map[string]string)
		}
		job.Spec.Template.Annotations["container.apparmor.security.beta.kubernetes.io/"+AgentContainerName] = "unconfined"
	}

	return job, nil
}

// buildAgentContainer constructs the primary agent container spec.
func buildAgentContainer(cr *kapsisv1alpha1.AgentRequest) (corev1.Container, error) {
	limits, err := buildResourceLimits(cr)
	if err != nil {
		return corev1.Container{}, err
	}

	workdir := "/workspace"
	if cr.Spec.Agent.Workdir != "" {
		workdir = cr.Spec.Agent.Workdir
	}

	container := corev1.Container{
		Name:       AgentContainerName,
		Image:      cr.Spec.Agent.Image,
		Command:    cr.Spec.Agent.Command,
		WorkingDir: workdir,
		Env:        buildEnvVars(cr),
		EnvFrom:    buildSecretEnvFrom(cr),
		Resources: corev1.ResourceRequirements{
			Requests: limits, // Guaranteed QoS: requests == limits
			Limits:   limits,
		},
		SecurityContext: buildAgentSecurityContext(cr),
	}

	return container, nil
}

// buildStatusSidecarContainer constructs the status/audit sidecar container.
// The sidecar:
//   - Watches /kapsis-status/status.json and patches the pod's own annotations
//     via the Kubernetes API (using the projected SA token).
//   - Tails /kapsis-audit/*.jsonl to stdout so log aggregators capture audit events.
func buildStatusSidecarContainer(image string) corev1.Container {
	falseVal := false
	trueVal := true
	return corev1.Container{
		Name:  StatusSidecarContainerName,
		Image: image,
		Env: []corev1.EnvVar{
			{
				Name: "POD_NAME",
				ValueFrom: &corev1.EnvVarSource{
					FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.name"},
				},
			},
			{
				Name: "POD_NAMESPACE",
				ValueFrom: &corev1.EnvVarSource{
					FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.namespace"},
				},
			},
			{
				Name:  "STATUS_DIR",
				Value: "/kapsis-status",
			},
			{
				Name:  "AUDIT_DIR",
				Value: "/kapsis-audit",
			},
		},
		SecurityContext: &corev1.SecurityContext{
			RunAsNonRoot:             &trueVal,
			AllowPrivilegeEscalation: &falseVal,
			ReadOnlyRootFilesystem:   &trueVal,
			Capabilities: &corev1.Capabilities{
				Drop: []corev1.Capability{"ALL"},
			},
			SeccompProfile: &corev1.SeccompProfile{
				Type: corev1.SeccompProfileTypeRuntimeDefault,
			},
		},
		// No resource limits set on the sidecar — it is intentionally lightweight.
		// The operator's own resource limits prevent it from consuming significant resources.
	}
}

// buildEnvVars returns the ordered list of environment variables for the agent container.
// SECURITY: user-supplied vars are appended FIRST, then Kapsis-controlled vars are
// appended LAST so they cannot be overridden by a malicious AgentRequest.
func buildEnvVars(cr *kapsisv1alpha1.AgentRequest) []corev1.EnvVar {
	// Step 1: user-supplied variables (first — lower priority).
	var envVars []corev1.EnvVar
	if cr.Spec.Environment != nil {
		for _, v := range cr.Spec.Environment.Vars {
			envVars = append(envVars, corev1.EnvVar{
				Name:  v.Name,
				Value: v.Value,
			})
		}
	}

	// Step 2: Kapsis-controlled variables (last — always win).
	kapsisVars := []corev1.EnvVar{
		{Name: "KAPSIS_BACKEND", Value: "k8s"},
		{Name: "KAPSIS_AGENT_ID", Value: cr.Name},
		{Name: "KAPSIS_AGENT_TYPE", Value: cr.Spec.Agent.Type},
		// Audit is always enabled in K8s mode; the sidecar tails /kapsis-audit/*.jsonl.
		{Name: "KAPSIS_AUDIT_ENABLED", Value: "true"},
		{Name: "KAPSIS_AUDIT_DIR", Value: "/kapsis-audit"},
		// Status dir shared with the sidecar.
		{Name: "KAPSIS_STATUS_DIR", Value: "/kapsis-status"},
	}

	// Task inline text.
	if cr.Spec.Task != nil && cr.Spec.Task.Inline != "" {
		kapsisVars = append(kapsisVars, corev1.EnvVar{
			Name:  "KAPSIS_TASK",
			Value: cr.Spec.Task.Inline,
		})
	}

	// Git environment variables.
	if cr.Spec.Workspace != nil && cr.Spec.Workspace.Git != nil {
		git := cr.Spec.Workspace.Git
		kapsisVars = append(kapsisVars, corev1.EnvVar{Name: "GIT_REPO_URL", Value: git.URL})
		if git.Branch != "" {
			kapsisVars = append(kapsisVars, corev1.EnvVar{Name: "KAPSIS_BRANCH", Value: git.Branch})
		}
		if git.BaseBranch != "" {
			kapsisVars = append(kapsisVars, corev1.EnvVar{Name: "KAPSIS_BASE_BRANCH", Value: git.BaseBranch})
		}
		kapsisVars = append(kapsisVars, corev1.EnvVar{
			Name:  "KAPSIS_DO_PUSH",
			Value: fmt.Sprintf("%t", git.Push),
		})
		// Git credentials from the named Secret (key: GIT_TOKEN).
		if git.CredentialSecretRef != "" {
			kapsisVars = append(kapsisVars, corev1.EnvVar{
				Name: "GIT_TOKEN",
				ValueFrom: &corev1.EnvVarSource{
					SecretKeyRef: &corev1.SecretKeySelector{
						LocalObjectReference: corev1.LocalObjectReference{
							Name: git.CredentialSecretRef,
						},
						Key: "GIT_TOKEN",
					},
				},
			})
		}
	}

	// Liveness monitoring.
	if cr.Spec.Liveness != nil && cr.Spec.Liveness.Enabled {
		kapsisVars = append(kapsisVars, corev1.EnvVar{Name: "KAPSIS_LIVENESS_ENABLED", Value: "true"})
		if cr.Spec.Liveness.TimeoutSeconds != nil {
			kapsisVars = append(kapsisVars, corev1.EnvVar{
				Name:  "KAPSIS_LIVENESS_TIMEOUT",
				Value: fmt.Sprintf("%d", *cr.Spec.Liveness.TimeoutSeconds),
			})
		}
		if cr.Spec.Liveness.CompletionTimeoutSeconds != nil {
			kapsisVars = append(kapsisVars, corev1.EnvVar{
				Name:  "KAPSIS_COMPLETION_TIMEOUT",
				Value: fmt.Sprintf("%d", *cr.Spec.Liveness.CompletionTimeoutSeconds),
			})
		}
		if cr.Spec.Liveness.GracePeriodSeconds != nil {
			kapsisVars = append(kapsisVars, corev1.EnvVar{
				Name:  "KAPSIS_LIVENESS_GRACE_PERIOD",
				Value: fmt.Sprintf("%d", *cr.Spec.Liveness.GracePeriodSeconds),
			})
		}
	}

	// Agent-specific workaround: prevent Claude from hanging after completion.
	if isClaudeAgent(cr.Spec.Agent.Type) {
		kapsisVars = append(kapsisVars, corev1.EnvVar{
			Name:  "CLAUDE_CODE_EXIT_AFTER_STOP_DELAY",
			Value: "10000",
		})
	}

	return append(envVars, kapsisVars...)
}

// buildResourceLimits parses resource strings into Kubernetes ResourceList quantities.
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

// buildPodSecurityContext returns the pod-level security context.
// runAsNonRoot is always enforced; the UID/GID come from the security spec.
func buildPodSecurityContext(cr *kapsisv1alpha1.AgentRequest) *corev1.PodSecurityContext {
	uid := int64(1000)
	gid := int64(1000)
	if cr.Spec.Security != nil {
		if cr.Spec.Security.RunAsUser != 0 {
			uid = cr.Spec.Security.RunAsUser
		}
		if cr.Spec.Security.RunAsGroup != 0 {
			gid = cr.Spec.Security.RunAsGroup
		}
	}
	runAsNonRoot := true
	return &corev1.PodSecurityContext{
		RunAsUser:    &uid,
		RunAsGroup:   &gid,
		RunAsNonRoot: &runAsNonRoot,
		SeccompProfile: &corev1.SeccompProfile{
			Type: corev1.SeccompProfileTypeRuntimeDefault,
		},
	}
}

// buildAgentSecurityContext returns the container-level security context for the
// agent container, based on the requested security profile.
//
// Profile capabilities (matching Podman parity from scripts/lib/security.sh):
//
//	minimal:  drop ALL, add SETUID+SETGID
//	standard: drop ALL, add SETUID+SETGID+CHOWN+FOWNER+FSETID+KILL+SETPCAP+NET_BIND_SERVICE
//	strict:   drop ALL, add SETUID+SETGID, readOnlyRootFilesystem=true
//	paranoid: drop ALL, add SETUID+SETGID, readOnlyRootFilesystem=true, seccomp=Localhost
//
// nestedContainers=true overrides allowPrivilegeEscalation and seccomp (required for
// rootless Podman inside the container via newuidmap/newgidmap setuid helpers).
func buildAgentSecurityContext(cr *kapsisv1alpha1.AgentRequest) *corev1.SecurityContext {
	profile := effectiveProfile(cr)
	nested := nestedContainersEnabled(cr)

	falseVal := false
	trueVal := true

	allowPrivEsc := falseVal
	if nested {
		allowPrivEsc = trueVal
	}

	readOnlyRoot := false
	if profile == "strict" || profile == "paranoid" {
		readOnlyRoot = true
	}

	sc := &corev1.SecurityContext{
		AllowPrivilegeEscalation: &allowPrivEsc,
		ReadOnlyRootFilesystem:   &readOnlyRoot,
		Capabilities:             buildCapabilities(profile),
	}

	if nested {
		// Unconfined seccomp required for CLONE_NEWUSER (rootless userns).
		sc.SeccompProfile = &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeUnconfined}
	} else if profile == "paranoid" {
		// Localhost profile for paranoid — caller must supply the profile path separately.
		sc.SeccompProfile = &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeLocalhost}
	} else {
		sc.SeccompProfile = &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault}
	}

	return sc
}

// buildCapabilities returns container capabilities for the given profile.
func buildCapabilities(profile string) *corev1.Capabilities {
	base := []corev1.Capability{"SETUID", "SETGID"}

	switch profile {
	case "standard":
		return &corev1.Capabilities{
			Drop: []corev1.Capability{"ALL"},
			Add:  append(base, "CHOWN", "FOWNER", "FSETID", "KILL", "SETPCAP", "NET_BIND_SERVICE"),
		}
	case "strict", "paranoid":
		return &corev1.Capabilities{
			Drop: []corev1.Capability{"ALL"},
			Add:  base,
		}
	default: // minimal
		return &corev1.Capabilities{
			Drop: []corev1.Capability{"ALL"},
			Add:  base,
		}
	}
}

// buildVolumes constructs all volumes required by the Job pod.
func buildVolumes(cr *kapsisv1alpha1.AgentRequest) ([]corev1.Volume, error) {
	var volumes []corev1.Volume

	// Workspace emptyDir with a size cap to prevent noisy-neighbour disk exhaustion.
	workspaceSizeLimit := defaultWorkspaceSizeLimit
	if cr.Spec.Resources != nil && cr.Spec.Resources.WorkspaceSizeLimit != "" {
		workspaceSizeLimit = cr.Spec.Resources.WorkspaceSizeLimit
	}
	workspaceLimit, err := resource.ParseQuantity(workspaceSizeLimit)
	if err != nil {
		return nil, fmt.Errorf("parsing workspaceSizeLimit %q: %w", workspaceSizeLimit, err)
	}
	volumes = append(volumes, corev1.Volume{
		Name: "workspace",
		VolumeSource: corev1.VolumeSource{
			EmptyDir: &corev1.EmptyDirVolumeSource{SizeLimit: &workspaceLimit},
		},
	})

	// Shared status volume: agent writes status.json, sidecar reads and patches annotations.
	volumes = append(volumes, corev1.Volume{
		Name:         "kapsis-status",
		VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
	})

	// Shared audit volume: agent writes JSONL events, sidecar tails to stdout.
	volumes = append(volumes, corev1.Volume{
		Name:         "kapsis-audit",
		VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
	})

	// /tmp emptyDir — required when readOnlyRootFilesystem=true (strict/paranoid profiles).
	volumes = append(volumes, corev1.Volume{
		Name:         "tmp",
		VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
	})

	// Projected ServiceAccount token for the status sidecar only.
	// The main agent container never receives the SA token.
	expiry := sidecarTokenExpirationSeconds
	volumes = append(volumes, corev1.Volume{
		Name: "sidecar-token",
		VolumeSource: corev1.VolumeSource{
			Projected: &corev1.ProjectedVolumeSource{
				Sources: []corev1.VolumeProjection{
					{
						ServiceAccountToken: &corev1.ServiceAccountTokenProjection{
							Path:              "token",
							ExpirationSeconds: &expiry,
						},
					},
					{
						ConfigMap: &corev1.ConfigMapProjection{
							LocalObjectReference: corev1.LocalObjectReference{Name: "kube-root-ca.crt"},
							Items: []corev1.KeyToPath{
								{Key: "ca.crt", Path: "ca.crt"},
							},
						},
					},
					{
						DownwardAPI: &corev1.DownwardAPIProjection{
							Items: []corev1.DownwardAPIVolumeFile{
								{
									Path: "namespace",
									FieldRef: &corev1.ObjectFieldSelector{
										APIVersion: "v1",
										FieldPath:  "metadata.namespace",
									},
								},
							},
						},
					},
				},
			},
		},
	})

	// Task spec ConfigMap (optional).
	if cr.Spec.Task != nil && cr.Spec.Task.SpecConfigMapRef != nil {
		key := cr.Spec.Task.SpecConfigMapRef.Key
		if key == "" {
			key = "spec.md"
		}
		volumes = append(volumes, corev1.Volume{
			Name: "task-spec",
			VolumeSource: corev1.VolumeSource{
				ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{
						Name: cr.Spec.Task.SpecConfigMapRef.Name,
					},
					Items: []corev1.KeyToPath{
						{Key: key, Path: "task-spec.md"},
					},
				},
			},
		})
	}

	// Environment ConfigMap mounts (optional).
	if cr.Spec.Environment != nil {
		for i, cm := range cr.Spec.Environment.ConfigMounts {
			volumes = append(volumes, corev1.Volume{
				Name: fmt.Sprintf("config-%d", i),
				VolumeSource: corev1.VolumeSource{
					ConfigMap: &corev1.ConfigMapVolumeSource{
						LocalObjectReference: corev1.LocalObjectReference{Name: cm.Name},
					},
				},
			})
		}
	}

	// Build cache PVC (optional).
	if cr.Spec.BuildCache != nil && cr.Spec.BuildCache.ClaimRef != "" {
		volumes = append(volumes, corev1.Volume{
			Name: "build-cache",
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
					ClaimName: cr.Spec.BuildCache.ClaimRef,
				},
			},
		})
	}

	// Nested containers support: /dev/fuse device and /var/lib/containers storage.
	if nestedContainersEnabled(cr) {
		volumes = append(volumes, corev1.Volume{
			Name: "dev-fuse",
			VolumeSource: corev1.VolumeSource{
				HostPath: &corev1.HostPathVolumeSource{Path: "/dev/fuse"},
			},
		})
		volumes = append(volumes, corev1.Volume{
			Name:         "containers-storage",
			VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
		})
	}

	return volumes, nil
}

// buildAgentVolumeMounts returns the volume mounts for the agent container.
func buildAgentVolumeMounts(cr *kapsisv1alpha1.AgentRequest) []corev1.VolumeMount {
	mounts := []corev1.VolumeMount{
		{Name: "workspace", MountPath: "/workspace"},
		{Name: "kapsis-status", MountPath: "/kapsis-status"},
		{Name: "kapsis-audit", MountPath: "/kapsis-audit"},
		{Name: "tmp", MountPath: "/tmp"},
	}

	// Task spec file (read-only).
	if cr.Spec.Task != nil && cr.Spec.Task.SpecConfigMapRef != nil {
		mounts = append(mounts, corev1.VolumeMount{
			Name:      "task-spec",
			MountPath: "/task-spec.md",
			SubPath:   "task-spec.md",
			ReadOnly:  true,
		})
	}

	// Environment ConfigMap mounts.
	if cr.Spec.Environment != nil {
		for i, cm := range cr.Spec.Environment.ConfigMounts {
			mounts = append(mounts, corev1.VolumeMount{
				Name:      fmt.Sprintf("config-%d", i),
				MountPath: cm.MountPath,
				ReadOnly:  true,
			})
		}
	}

	// Build cache PVC.
	if cr.Spec.BuildCache != nil && cr.Spec.BuildCache.ClaimRef != "" {
		mountPath := cr.Spec.BuildCache.MountPath
		if mountPath == "" {
			mountPath = defaultBuildCacheMountPath
		}
		mounts = append(mounts, corev1.VolumeMount{
			Name:      "build-cache",
			MountPath: mountPath,
		})
	}

	// Nested containers: /dev/fuse and /var/lib/containers.
	if nestedContainersEnabled(cr) {
		mounts = append(mounts, corev1.VolumeMount{
			Name:      "dev-fuse",
			MountPath: "/dev/fuse",
		})
		mounts = append(mounts, corev1.VolumeMount{
			Name:      "containers-storage",
			MountPath: "/var/lib/containers",
		})
	}

	return mounts
}

// buildSidecarVolumeMounts returns the volume mounts for the status sidecar container.
func buildSidecarVolumeMounts() []corev1.VolumeMount {
	return []corev1.VolumeMount{
		{Name: "kapsis-status", MountPath: "/kapsis-status", ReadOnly: true},
		{Name: "kapsis-audit", MountPath: "/kapsis-audit", ReadOnly: true},
		// Projected SA token mounted at the standard location so client-go auto-discovers it.
		{
			Name:      "sidecar-token",
			MountPath: "/var/run/secrets/kubernetes.io/serviceaccount",
			ReadOnly:  true,
		},
	}
}

// buildSecretEnvFrom creates EnvFromSource entries for each SecretRef in the spec.
func buildSecretEnvFrom(cr *kapsisv1alpha1.AgentRequest) []corev1.EnvFromSource {
	if cr.Spec.Environment == nil {
		return nil
	}
	var envFrom []corev1.EnvFromSource
	for _, ref := range cr.Spec.Environment.SecretRefs {
		envFrom = append(envFrom, corev1.EnvFromSource{
			SecretRef: &corev1.SecretEnvSource{
				LocalObjectReference: corev1.LocalObjectReference{Name: ref.Name},
			},
		})
	}
	return envFrom
}

// --- helpers ---

func effectiveTTL(cr *kapsisv1alpha1.AgentRequest) int64 {
	if cr.Spec.TTL <= 0 {
		return 3600
	}
	return cr.Spec.TTL
}

func effectiveProfile(cr *kapsisv1alpha1.AgentRequest) string {
	if cr.Spec.Security != nil && cr.Spec.Security.Profile != "" {
		return cr.Spec.Security.Profile
	}
	return "standard"
}

func effectiveServiceAccount(cr *kapsisv1alpha1.AgentRequest) string {
	if cr.Spec.Security != nil && cr.Spec.Security.ServiceAccountName != "" {
		return cr.Spec.Security.ServiceAccountName
	}
	return "kapsis-agent"
}

func nestedContainersEnabled(cr *kapsisv1alpha1.AgentRequest) bool {
	return cr.Spec.Security != nil && cr.Spec.Security.NestedContainers
}

func isClaudeAgent(agentType string) bool {
	switch agentType {
	case "claude-cli", "claude", "claude-code":
		return true
	}
	return false
}

func boolPtr(b bool) *bool {
	return &b
}
