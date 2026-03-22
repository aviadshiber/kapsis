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
	// Image is the container image to run.
	// +required
	Image string `json:"image"`

	// Agent defines the agent configuration.
	// +required
	Agent AgentSpec `json:"agent"`

	// Resources defines resource limits for the pod.
	// +optional
	Resources *ResourceSpec `json:"resources,omitempty"`

	// Git defines git repository configuration.
	// +optional
	Git *GitSpec `json:"git,omitempty"`

	// Task defines the task specification.
	// +optional
	Task *TaskSpec `json:"task,omitempty"`

	// Environment defines environment configuration.
	// +optional
	Environment *EnvironmentSpec `json:"environment,omitempty"`

	// Network defines network configuration.
	// +optional
	Network *NetworkSpec `json:"network,omitempty"`

	// Security defines security configuration.
	// +optional
	Security *SecuritySpec `json:"security,omitempty"`

	// Audit configures audit logging.
	// +optional
	Audit *AuditSpec `json:"audit,omitempty"`

	// Liveness configures agent liveness monitoring and auto-kill for hung processes.
	// +optional
	Liveness *LivenessSpec `json:"liveness,omitempty"`

	// TTL is the time-to-live in seconds (pod killed after this).
	// +optional
	// +kubebuilder:default=3600
	TTL *int32 `json:"ttl,omitempty"`

	// PodAnnotations are arbitrary annotations to add to the created Pod.
	// Use this to integrate with annotation-based tools such as Vault/OpenBao
	// Agent Injector, Istio, Linkerd, or Prometheus scraping.
	// +optional
	PodAnnotations map[string]string `json:"podAnnotations,omitempty"`
}

// AgentSpec defines the agent type and command.
type AgentSpec struct {
	// Type is the agent type (claude-cli, codex-cli, aider, gemini-cli).
	// +required
	Type string `json:"type"`

	// Command is the command to execute in the container.
	// +optional
	Command []string `json:"command,omitempty"`

	// Workdir is the working directory inside container.
	// +optional
	// +kubebuilder:default="/workspace"
	Workdir string `json:"workdir,omitempty"`
}

// ResourceSpec defines resource limits for the pod.
type ResourceSpec struct {
	// Memory limit (e.g., "8Gi").
	// +optional
	// +kubebuilder:default="8Gi"
	Memory string `json:"memory,omitempty"`

	// CPU limit (e.g., "4").
	// +optional
	// +kubebuilder:default="4"
	CPU string `json:"cpu,omitempty"`
}

// GitSpec defines git repository configuration.
type GitSpec struct {
	// RepoUrl is the repository URL to clone.
	// +optional
	RepoUrl string `json:"repoUrl,omitempty"`

	// Branch to work on.
	// +optional
	Branch string `json:"branch,omitempty"`

	// BaseBranch for new branches.
	// +optional
	// +kubebuilder:default="main"
	BaseBranch string `json:"baseBranch,omitempty"`

	// Push indicates whether to push changes after completion.
	// +optional
	// +kubebuilder:default=false
	Push bool `json:"push,omitempty"`

	// CredentialSecretRef is a reference to a Secret containing git credentials.
	// +optional
	CredentialSecretRef *SecretKeyRef `json:"credentialSecretRef,omitempty"`
}

// SecretKeyRef references a key in a Secret.
type SecretKeyRef struct {
	// Name of the Secret.
	// +required
	Name string `json:"name"`

	// Key within the Secret.
	// +required
	Key string `json:"key"`
}

// ConfigMapKeyRef references a key in a ConfigMap.
type ConfigMapKeyRef struct {
	// Name of the ConfigMap.
	// +required
	Name string `json:"name"`

	// Key within the ConfigMap.
	// +optional
	// +kubebuilder:default="spec.md"
	Key string `json:"key,omitempty"`
}

// TaskSpec defines the task specification.
type TaskSpec struct {
	// Inline task description.
	// +optional
	Inline string `json:"inline,omitempty"`

	// SpecConfigMapRef references a ConfigMap containing the task spec.
	// +optional
	SpecConfigMapRef *ConfigMapKeyRef `json:"specConfigMapRef,omitempty"`
}

// EnvVar is a name-value environment variable pair.
type EnvVar struct {
	// Name of the environment variable.
	// +required
	Name string `json:"name"`

	// Value of the environment variable.
	// +required
	Value string `json:"value"`
}

// SecretRef references a Secret by name.
type SecretRef struct {
	// Name of the Secret.
	// +required
	Name string `json:"name"`
}

// ConfigMount defines a ConfigMap to mount as a volume.
type ConfigMount struct {
	// Name of the ConfigMap.
	// +required
	Name string `json:"name"`

	// MountPath inside the container.
	// +required
	MountPath string `json:"mountPath"`
}

// EnvironmentSpec defines environment configuration.
type EnvironmentSpec struct {
	// Vars is a list of environment variables.
	// +optional
	Vars []EnvVar `json:"vars,omitempty"`

	// SecretRefs are references to Secrets to mount as env vars.
	// +optional
	SecretRefs []SecretRef `json:"secretRefs,omitempty"`

	// ConfigMounts are ConfigMaps to mount as volumes.
	// +optional
	ConfigMounts []ConfigMount `json:"configMounts,omitempty"`
}

// NetworkSpec defines network configuration.
type NetworkSpec struct {
	// Mode is the network mode: none, filtered, open.
	// +optional
	// +kubebuilder:default="filtered"
	// +kubebuilder:validation:Enum=none;filtered;open
	Mode string `json:"mode,omitempty"`
}

// SecuritySpec defines security configuration.
type SecuritySpec struct {
	// Profile is the security profile: minimal, standard, strict, paranoid.
	// +optional
	// +kubebuilder:default="standard"
	// +kubebuilder:validation:Enum=minimal;standard;strict;paranoid
	Profile string `json:"profile,omitempty"`

	// ServiceAccountName for the pod.
	// +optional
	// +kubebuilder:default="kapsis-agent"
	ServiceAccountName string `json:"serviceAccountName,omitempty"`
}

// AuditSpec defines audit logging configuration.
type AuditSpec struct {
	// Enabled controls whether audit logging is active.
	// +optional
	Enabled bool `json:"enabled,omitempty"`
}

// LivenessSpec configures agent liveness monitoring and auto-kill for hung processes.
type LivenessSpec struct {
	// Enabled controls whether liveness monitoring is active.
	// +optional
	Enabled bool `json:"enabled,omitempty"`

	// TimeoutSeconds is how long (in seconds) to wait with no activity before killing the agent.
	// +optional
	// +kubebuilder:default=1800
	// +kubebuilder:validation:Minimum=60
	TimeoutSeconds *int32 `json:"timeoutSeconds,omitempty"`

	// GracePeriodSeconds is how long to skip liveness checks after agent start.
	// +optional
	// +kubebuilder:default=300
	GracePeriodSeconds *int32 `json:"gracePeriodSeconds,omitempty"`

	// CheckIntervalSeconds is how often to check for agent activity.
	// +optional
	// +kubebuilder:default=30
	// +kubebuilder:validation:Minimum=10
	CheckIntervalSeconds *int32 `json:"checkIntervalSeconds,omitempty"`
}

// AgentRequestPhase represents the current phase of an AgentRequest.
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
	// Phase is the current phase.
	// +optional
	Phase AgentRequestPhase `json:"phase,omitempty"`

	// Progress percentage (0-100).
	// +optional
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	Progress int32 `json:"progress,omitempty"`

	// Message is a human-readable status message.
	// +optional
	Message string `json:"message,omitempty"`

	// Gist is a short summary of current work.
	// +optional
	Gist string `json:"gist,omitempty"`

	// GistUpdatedAt is the timestamp of last gist update.
	// +optional
	GistUpdatedAt *metav1.Time `json:"gistUpdatedAt,omitempty"`

	// ExitCode is the container exit code.
	// +optional
	ExitCode *int32 `json:"exitCode,omitempty"`

	// PodName is the name of the created Pod.
	// +optional
	PodName string `json:"podName,omitempty"`

	// StartedAt is when the agent started.
	// +optional
	StartedAt *metav1.Time `json:"startedAt,omitempty"`

	// CompletedAt is when the agent completed.
	// +optional
	CompletedAt *metav1.Time `json:"completedAt,omitempty"`

	// CommitSha is the SHA of the commit created by the agent.
	// +optional
	CommitSha string `json:"commitSha,omitempty"`

	// PushStatus indicates push result: success, failed, skipped.
	// +optional
	PushStatus string `json:"pushStatus,omitempty"`

	// PrUrl is the URL of the PR created by the agent.
	// +optional
	PrUrl string `json:"prUrl,omitempty"`

	// Response is the agent response summary.
	// +optional
	Response string `json:"response,omitempty"`

	// Error message if failed.
	// +optional
	Error string `json:"error,omitempty"`

	// Conditions represent the current state of the AgentRequest.
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
