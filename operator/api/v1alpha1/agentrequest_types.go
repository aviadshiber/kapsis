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

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// AgentRequestSpec defines the desired state of AgentRequest.
type AgentRequestSpec struct {
	// Agent defines the agent type and container image.
	// +required
	Agent AgentSpec `json:"agent"`

	// Task defines what the agent should do.
	// +optional
	Task *TaskSpec `json:"task,omitempty"`

	// Workspace defines the git repository to clone.
	// +optional
	Workspace *WorkspaceSpec `json:"workspace,omitempty"`

	// Security defines the security profile and container hardening settings.
	// +optional
	Security *SecuritySpec `json:"security,omitempty"`

	// Network defines network isolation mode.
	// +optional
	Network *NetworkSpec `json:"network,omitempty"`

	// Resources defines CPU/memory limits and workspace disk quota.
	// +optional
	Resources *ResourceSpec `json:"resources,omitempty"`

	// BuildCache mounts a PVC-backed build tool cache (Maven, Gradle, npm).
	// +optional
	BuildCache *BuildCacheSpec `json:"buildCache,omitempty"`

	// Environment defines user-supplied environment variables, secrets, and ConfigMap mounts.
	// +optional
	Environment *EnvironmentSpec `json:"environment,omitempty"`

	// Liveness configures agent activity monitoring and hung-process detection.
	// +optional
	Liveness *LivenessSpec `json:"liveness,omitempty"`

	// TTL is the maximum lifetime of the agent Job in seconds.
	// The Job is killed when this deadline is exceeded.
	// +optional
	// +kubebuilder:default=3600
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=86400
	TTL int64 `json:"ttl,omitempty"`

	// PodAnnotations are passed through to the Job pod template.
	// Use this for annotation-based sidecar injection (Vault, Istio, Prometheus, etc.).
	// +optional
	PodAnnotations map[string]string `json:"podAnnotations,omitempty"`
}

// AgentSpec defines the agent container image and startup configuration.
type AgentSpec struct {
	// Type is the agent identifier (claude-cli, codex-cli, aider, gemini-cli).
	// +required
	// +kubebuilder:validation:Enum=claude-cli;codex-cli;aider;gemini-cli
	Type string `json:"type"`

	// Image is the container image to run.
	// +required
	Image string `json:"image"`

	// Command overrides the container entrypoint.
	// +optional
	Command []string `json:"command,omitempty"`

	// Workdir is the working directory inside the container.
	// +optional
	// +kubebuilder:default="/workspace"
	Workdir string `json:"workdir,omitempty"`
}

// WorkspaceSpec defines the git repository to clone into the agent workspace.
type WorkspaceSpec struct {
	// Git defines the git repository configuration.
	// +optional
	Git *GitSpec `json:"git,omitempty"`
}

// GitSpec defines a git repository to clone.
type GitSpec struct {
	// URL is the repository URL to clone.
	// +required
	URL string `json:"url"`

	// Branch to work on. Created from BaseBranch if it does not exist.
	// +optional
	Branch string `json:"branch,omitempty"`

	// BaseBranch is the source branch for new branches and the merge base.
	// +optional
	// +kubebuilder:default="main"
	BaseBranch string `json:"baseBranch,omitempty"`

	// Push indicates whether to commit and push changes after the agent completes.
	// +optional
	// +kubebuilder:default=false
	Push bool `json:"push,omitempty"`

	// CredentialSecretRef is the name of a Secret that contains a GIT_TOKEN key
	// used for authenticated git operations.
	// +optional
	CredentialSecretRef string `json:"credentialSecretRef,omitempty"`
}

// SecuritySpec defines security hardening for the agent container.
type SecuritySpec struct {
	// Profile is the security hardening level.
	// +optional
	// +kubebuilder:default="standard"
	// +kubebuilder:validation:Enum=minimal;standard;strict;paranoid
	Profile string `json:"profile,omitempty"`

	// NestedContainers allows Podman-in-pod (rootless containers inside the agent).
	// Requires the namespace to have PSA policy "privileged" and explicit admission approval.
	// +optional
	// +kubebuilder:default=false
	NestedContainers bool `json:"nestedContainers,omitempty"`

	// RuntimeClass selects an alternative container runtime (e.g. gvisor, kata-containers).
	// Typically used with the paranoid profile.
	// +optional
	RuntimeClass string `json:"runtimeClass,omitempty"`

	// RunAsUser sets the UID for the agent container.
	// +optional
	// +kubebuilder:default=1000
	RunAsUser int64 `json:"runAsUser,omitempty"`

	// RunAsGroup sets the GID for the agent container.
	// +optional
	// +kubebuilder:default=1000
	RunAsGroup int64 `json:"runAsGroup,omitempty"`

	// ServiceAccountName is the Kubernetes ServiceAccount to bind to the Job pod.
	// +optional
	// +kubebuilder:default="kapsis-agent"
	ServiceAccountName string `json:"serviceAccountName,omitempty"`

	// SeccompProfilePath is the path to a localhost seccomp profile for the paranoid
	// security profile. Only used when Profile == "paranoid". When empty, RuntimeDefault
	// is used instead.
	// +optional
	SeccompProfilePath string `json:"seccompProfilePath,omitempty"`
}

// NetworkSpec defines network isolation for the agent.
type NetworkSpec struct {
	// Mode is the network isolation mode.
	// none: deny all egress. filtered: allow git/npm/Maven/PyPI ports + DNS. open: unrestricted.
	// +optional
	// +kubebuilder:default="filtered"
	// +kubebuilder:validation:Enum=none;filtered;open
	Mode string `json:"mode,omitempty"`
}

// ResourceSpec defines CPU, memory, and workspace disk limits.
type ResourceSpec struct {
	// Memory limit (e.g., "8Gi").
	// +optional
	// +kubebuilder:default="8Gi"
	Memory string `json:"memory,omitempty"`

	// CPU limit (e.g., "4").
	// +optional
	// +kubebuilder:default="4"
	CPU string `json:"cpu,omitempty"`

	// WorkspaceSizeLimit caps the emptyDir workspace volume (e.g., "20Gi").
	// Prevents noisy-neighbour disk exhaustion on the node.
	// +optional
	// +kubebuilder:default="20Gi"
	WorkspaceSizeLimit string `json:"workspaceSizeLimit,omitempty"`
}

// BuildCacheSpec configures a PVC-backed build tool cache.
type BuildCacheSpec struct {
	// ClaimRef is the name of an existing PersistentVolumeClaim to mount.
	// +required
	ClaimRef string `json:"claimRef"`

	// MountPath is the path inside the agent container where the PVC is mounted.
	// +optional
	// +kubebuilder:default="/root/.m2"
	MountPath string `json:"mountPath,omitempty"`
}

// TaskSpec defines what the agent should do.
// Exactly one of Inline or SpecConfigMapRef should be set.
type TaskSpec struct {
	// Inline is a free-form task description passed as the KAPSIS_TASK environment variable.
	// +optional
	Inline string `json:"inline,omitempty"`

	// SpecConfigMapRef references a ConfigMap containing a task spec file (e.g., spec.md).
	// The file is mounted read-only at /task-spec.md inside the agent container.
	// +optional
	SpecConfigMapRef *ConfigMapKeyRef `json:"specConfigMapRef,omitempty"`
}

// ConfigMapKeyRef references a key within a ConfigMap.
type ConfigMapKeyRef struct {
	// Name of the ConfigMap.
	// +required
	Name string `json:"name"`

	// Key within the ConfigMap. Defaults to "spec.md" if omitted.
	// +optional
	// +kubebuilder:default="spec.md"
	Key string `json:"key,omitempty"`
}

// EnvVar is a name-value environment variable pair.
type EnvVar struct {
	// Name of the environment variable. Must not start with "KAPSIS_".
	// +required
	Name string `json:"name"`

	// Value of the environment variable.
	// +required
	Value string `json:"value"`
}

// SecretRef references a Kubernetes Secret by name.
type SecretRef struct {
	// Name of the Secret.
	// +required
	Name string `json:"name"`
}

// ConfigMount defines a ConfigMap to mount as a read-only volume.
type ConfigMount struct {
	// Name of the ConfigMap.
	// +required
	Name string `json:"name"`

	// MountPath inside the agent container.
	// Must not overlap with /etc/, /proc/, /sys/, or .git/hooks/.
	// +required
	MountPath string `json:"mountPath"`
}

// EnvironmentSpec defines user-supplied runtime configuration.
type EnvironmentSpec struct {
	// Vars is a list of plain environment variables.
	// Names must not start with "KAPSIS_" (reserved for operator-injected variables).
	// +optional
	Vars []EnvVar `json:"vars,omitempty"`

	// SecretRefs are Secrets to expose as environment variables via envFrom.
	// +optional
	SecretRefs []SecretRef `json:"secretRefs,omitempty"`

	// ConfigMounts are ConfigMaps to mount as read-only volumes inside the agent container.
	// +optional
	ConfigMounts []ConfigMount `json:"configMounts,omitempty"`
}

// LivenessSpec configures hung-process detection and automatic kill.
type LivenessSpec struct {
	// Enabled controls whether liveness monitoring is active.
	// +optional
	// +kubebuilder:default=true
	Enabled bool `json:"enabled,omitempty"`

	// TimeoutSeconds is how long to wait without activity before killing the agent.
	// +optional
	// +kubebuilder:default=900
	// +kubebuilder:validation:Minimum=60
	TimeoutSeconds *int32 `json:"timeoutSeconds,omitempty"`

	// CompletionTimeoutSeconds is how long to wait after the agent reports completion
	// before forcibly killing the process (handles stuck MCP servers, etc.).
	// +optional
	// +kubebuilder:default=120
	// +kubebuilder:validation:Minimum=30
	CompletionTimeoutSeconds *int32 `json:"completionTimeoutSeconds,omitempty"`

	// GracePeriodSeconds is how long to skip liveness checks after agent start.
	// +optional
	// +kubebuilder:default=300
	GracePeriodSeconds *int32 `json:"gracePeriodSeconds,omitempty"`
}

// AgentRequestPhase represents the lifecycle phase of an AgentRequest.
type AgentRequestPhase string

const (
	PhasePending        AgentRequestPhase = "Pending"
	PhaseInitializing   AgentRequestPhase = "Initializing"
	PhaseRunning        AgentRequestPhase = "Running"
	PhasePostProcessing AgentRequestPhase = "PostProcessing"
	PhaseComplete       AgentRequestPhase = "Complete"
	PhaseFailed         AgentRequestPhase = "Failed"
)

// AgentRequestStatus defines the observed state of AgentRequest.
type AgentRequestStatus struct {
	// Phase is the current lifecycle phase.
	// +optional
	Phase AgentRequestPhase `json:"phase,omitempty"`

	// Progress percentage (0–100) reported by the agent.
	// +optional
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	Progress int32 `json:"progress,omitempty"`

	// Message is a human-readable status message from the agent or operator.
	// +optional
	// +kubebuilder:validation:MaxLength=1024
	Message string `json:"message,omitempty"`

	// Gist is a short natural-language summary of the agent's current work.
	// +optional
	// +kubebuilder:validation:MaxLength=1024
	Gist string `json:"gist,omitempty"`

	// JobName is the name of the batch/v1 Job created for this request.
	// +optional
	JobName string `json:"jobName,omitempty"`

	// PodName is the name of the Job's pod (populated once the pod is scheduled).
	// +optional
	PodName string `json:"podName,omitempty"`

	// ExitCode is the container exit code (populated when the agent completes).
	// +optional
	ExitCode *int32 `json:"exitCode,omitempty"`

	// StartedAt is when the agent container started.
	// +optional
	StartedAt *metav1.Time `json:"startedAt,omitempty"`

	// CompletedAt is when the agent container finished.
	// +optional
	CompletedAt *metav1.Time `json:"completedAt,omitempty"`

	// CommitSha is the SHA of the commit created by the agent.
	// +optional
	CommitSha string `json:"commitSha,omitempty"`

	// PushStatus indicates the result of the post-agent git push: success, failed, or skipped.
	// +optional
	PushStatus string `json:"pushStatus,omitempty"`

	// PrUrl is the URL of the pull/merge request created by the agent.
	// +optional
	PrUrl string `json:"prUrl,omitempty"`

	// PushFallbackCommand is a ready-to-run git push command for manual recovery
	// when the in-container push failed (typically due to missing credentials).
	// +optional
	PushFallbackCommand string `json:"pushFallbackCommand,omitempty"`

	// Error is a human-readable failure description (populated when phase=Failed).
	// +optional
	Error string `json:"error,omitempty"`

	// Conditions represent the latest available observations of the AgentRequest state.
	// Defined for future use; not populated in v1alpha1.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=ar;agent
// +kubebuilder:printcolumn:name="Agent",type=string,JSONPath=`.spec.agent.type`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Progress",type=integer,JSONPath=`.status.progress`
// +kubebuilder:printcolumn:name="Job",type=string,JSONPath=`.status.jobName`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// AgentRequest is the Schema for the agentrequests API.
type AgentRequest struct {
	metav1.TypeMeta `json:",inline"`

	// +optional
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// +required
	Spec AgentRequestSpec `json:"spec"`

	// +optional
	Status AgentRequestStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// AgentRequestList contains a list of AgentRequest.
type AgentRequestList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AgentRequest `json:"items"`
}

func init() {
	SchemeBuilder.Register(&AgentRequest{}, &AgentRequestList{})
}
