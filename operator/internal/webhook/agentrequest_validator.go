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

// Package webhook provides the ValidatingAdmissionWebhook for AgentRequest resources.
// It enforces security invariants that cannot be expressed in CRD validation markers:
//   - container image must match an operator-configured allowlist
//   - serviceAccountName must be the approved value
//   - environment.vars must not contain KAPSIS_* names (reserved for operator injection)
//   - configMount paths must not overlap with protected system paths
//   - nestedContainers=true only in operator-approved namespaces
//   - network.mode=open requires an explicit opt-in annotation
package webhook

import (
	"context"
	"fmt"
	"strings"

	"k8s.io/apimachinery/pkg/util/validation/field"
	ctrl "sigs.k8s.io/controller-runtime"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

var webhookLog = logf.Log.WithName("agentrequest-webhook")

// AgentRequestValidator implements admission.Validator[*kapsisv1alpha1.AgentRequest].
type AgentRequestValidator struct {
	// ImageAllowlistPatterns are prefix patterns for allowed container images.
	// An image is allowed if it starts with any of these prefixes.
	// Example: ["ghcr.io/aviadshiber/kapsis/", "ghcr.io/my-org/kapsis/"]
	// If empty, all images are allowed (development mode only).
	ImageAllowlistPatterns []string

	// ApprovedServiceAccounts is the set of allowed serviceAccountName values.
	// Defaults to {"kapsis-agent"} if empty.
	ApprovedServiceAccounts []string

	// NestedContainerNamespaces is the set of namespaces where nestedContainers=true
	// is permitted. These namespaces must have PSA policy "privileged".
	NestedContainerNamespaces []string
}

// protectedMountPaths are path prefixes that configMount.mountPath must not use.
var protectedMountPaths = []string{
	"/etc/",
	"/proc/",
	"/sys/",
	"/.git/hooks/",
	"/var/run/secrets/",
}

//+kubebuilder:webhook:path=/validate-kapsis-aviadshiber-github-io-v1alpha1-agentrequest,mutating=false,failurePolicy=fail,sideEffects=None,groups=kapsis.aviadshiber.github.io,resources=agentrequests,verbs=create;update,versions=v1alpha1,name=vagentrequest.kb.io,admissionReviewVersions=v1

// SetupWebhookWithManager registers the validator with the controller-runtime manager.
func (v *AgentRequestValidator) SetupWebhookWithManager(mgr ctrl.Manager) error {
	return ctrl.NewWebhookManagedBy(mgr, &kapsisv1alpha1.AgentRequest{}).
		WithValidator(v).
		Complete()
}

// ValidateCreate validates a new AgentRequest.
func (v *AgentRequestValidator) ValidateCreate(ctx context.Context, ar *kapsisv1alpha1.AgentRequest) (admission.Warnings, error) {
	webhookLog.Info("Validating AgentRequest create", "name", ar.Name, "namespace", ar.Namespace)
	return nil, v.validate(ar).ToAggregate()
}

// ValidateUpdate validates an updated AgentRequest.
func (v *AgentRequestValidator) ValidateUpdate(ctx context.Context, _, ar *kapsisv1alpha1.AgentRequest) (admission.Warnings, error) {
	webhookLog.Info("Validating AgentRequest update", "name", ar.Name, "namespace", ar.Namespace)
	return nil, v.validate(ar).ToAggregate()
}

// ValidateDelete is a no-op; deletions are always permitted.
func (v *AgentRequestValidator) ValidateDelete(_ context.Context, _ *kapsisv1alpha1.AgentRequest) (admission.Warnings, error) {
	return nil, nil
}

// validate runs all security validation rules and returns a FieldErrorList.
func (v *AgentRequestValidator) validate(ar *kapsisv1alpha1.AgentRequest) field.ErrorList {
	var errs field.ErrorList
	specPath := field.NewPath("spec")

	errs = append(errs, v.validateImage(ar, specPath.Child("agent", "image"))...)
	errs = append(errs, v.validateServiceAccount(ar, specPath.Child("security", "serviceAccountName"))...)
	errs = append(errs, v.validateEnvVarNames(ar, specPath.Child("environment", "vars"))...)
	errs = append(errs, v.validateConfigMountPaths(ar, specPath.Child("environment", "configMounts"))...)
	errs = append(errs, v.validateNestedContainers(ar, specPath.Child("security", "nestedContainers"))...)
	errs = append(errs, v.validateNetworkOpen(ar, specPath.Child("network", "mode"))...)

	return errs
}

// validateImage checks that the agent image matches one of the allowed prefixes.
func (v *AgentRequestValidator) validateImage(ar *kapsisv1alpha1.AgentRequest, fld *field.Path) field.ErrorList {
	if len(v.ImageAllowlistPatterns) == 0 {
		return nil // no allowlist = dev/test mode, all images permitted
	}
	img := ar.Spec.Agent.Image
	for _, prefix := range v.ImageAllowlistPatterns {
		if strings.HasPrefix(img, prefix) {
			return nil
		}
	}
	return field.ErrorList{
		field.Invalid(fld, img, fmt.Sprintf(
			"image %q is not in the operator allowlist; allowed prefixes: %v",
			img, v.ImageAllowlistPatterns,
		)),
	}
}

// validateServiceAccount checks that the service account is from the approved set.
func (v *AgentRequestValidator) validateServiceAccount(ar *kapsisv1alpha1.AgentRequest, fld *field.Path) field.ErrorList {
	approved := v.ApprovedServiceAccounts
	if len(approved) == 0 {
		approved = []string{"kapsis-agent"}
	}
	sa := "kapsis-agent"
	if ar.Spec.Security != nil && ar.Spec.Security.ServiceAccountName != "" {
		sa = ar.Spec.Security.ServiceAccountName
	}
	for _, a := range approved {
		if sa == a {
			return nil
		}
	}
	return field.ErrorList{
		field.Invalid(fld, sa, fmt.Sprintf(
			"serviceAccountName %q is not approved; allowed values: %v", sa, approved,
		)),
	}
}

// validateEnvVarNames rejects environment.vars with names that start with "KAPSIS_".
// These names are reserved for operator-injected variables (security: prevents override).
func (v *AgentRequestValidator) validateEnvVarNames(ar *kapsisv1alpha1.AgentRequest, fld *field.Path) field.ErrorList {
	if ar.Spec.Environment == nil {
		return nil
	}
	var errs field.ErrorList
	for i, ev := range ar.Spec.Environment.Vars {
		if strings.HasPrefix(ev.Name, "KAPSIS_") {
			errs = append(errs, field.Invalid(
				fld.Index(i).Child("name"), ev.Name,
				`env var name must not start with "KAPSIS_" (reserved for operator-injected variables)`,
			))
		}
	}
	return errs
}

// validateConfigMountPaths rejects configMounts targeting protected system paths.
func (v *AgentRequestValidator) validateConfigMountPaths(ar *kapsisv1alpha1.AgentRequest, fld *field.Path) field.ErrorList {
	if ar.Spec.Environment == nil {
		return nil
	}
	var errs field.ErrorList
	for i, cm := range ar.Spec.Environment.ConfigMounts {
		for _, protected := range protectedMountPaths {
			if strings.HasPrefix(cm.MountPath, protected) || cm.MountPath == strings.TrimSuffix(protected, "/") {
				errs = append(errs, field.Invalid(
					fld.Index(i).Child("mountPath"), cm.MountPath,
					fmt.Sprintf("mountPath %q overlaps with protected path %q", cm.MountPath, protected),
				))
				break
			}
		}
	}
	return errs
}

// validateNestedContainers gates nestedContainers=true to operator-approved namespaces.
func (v *AgentRequestValidator) validateNestedContainers(ar *kapsisv1alpha1.AgentRequest, fld *field.Path) field.ErrorList {
	if ar.Spec.Security == nil || !ar.Spec.Security.NestedContainers {
		return nil
	}
	if len(v.NestedContainerNamespaces) == 0 {
		return field.ErrorList{
			field.Forbidden(fld, "nestedContainers=true requires explicit operator approval; no approved namespaces configured"),
		}
	}
	for _, ns := range v.NestedContainerNamespaces {
		if ar.Namespace == ns {
			return nil
		}
	}
	return field.ErrorList{
		field.Forbidden(fld, fmt.Sprintf(
			"nestedContainers=true is not permitted in namespace %q; approved namespaces: %v",
			ar.Namespace, v.NestedContainerNamespaces,
		)),
	}
}

// validateNetworkOpen requires an explicit opt-in annotation for network.mode=open.
func (v *AgentRequestValidator) validateNetworkOpen(ar *kapsisv1alpha1.AgentRequest, fld *field.Path) field.ErrorList {
	if ar.Spec.Network == nil || ar.Spec.Network.Mode != "open" {
		return nil
	}
	const optInAnnotation = "kapsis.aviadshiber.github.io/allow-open-network"
	if ar.Annotations[optInAnnotation] == "true" {
		return nil
	}
	return field.ErrorList{
		field.Forbidden(fld, fmt.Sprintf(
			`network.mode=open requires annotation %q: "true" on the AgentRequest`,
			optInAnnotation,
		)),
	}
}
