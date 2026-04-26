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
	"testing"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

// crWithNetworkMode returns a minimal AgentRequest with the given network mode.
func crWithNetworkMode(mode string) *kapsisv1alpha1.AgentRequest {
	cr := minimalCR()
	cr.Spec.Network = &kapsisv1alpha1.NetworkSpec{Mode: mode}
	return cr
}

// TestNetworkPolicyStableNames verifies the namespace-level stable policy names are used.
// The old per-agent name ({cr.Name}-netpol) was replaced with stable names per mode.
func TestNetworkPolicyStableNames(t *testing.T) {
	tests := []struct {
		mode string
		want string
	}{
		{NetworkModeFiltered, networkPolicyNameFiltered},
		{NetworkModeNone, networkPolicyNameNone},
	}
	for _, tt := range tests {
		t.Run(tt.mode, func(t *testing.T) {
			cr := crWithNetworkMode(tt.mode)
			np := BuildNetworkPolicy(cr)
			if np == nil {
				t.Fatal("BuildNetworkPolicy() returned nil")
			}
			if np.Name != tt.want {
				t.Errorf("Name = %q, want %q", np.Name, tt.want)
			}
		})
	}
}

func TestShouldCreateNetworkPolicy_Modes(t *testing.T) {
	tests := []struct {
		mode string
		want bool
	}{
		{NetworkModeNone, true},
		{NetworkModeFiltered, true},
		{NetworkModeOpen, false},
	}

	for _, tt := range tests {
		t.Run(tt.mode, func(t *testing.T) {
			cr := crWithNetworkMode(tt.mode)
			got := ShouldCreateNetworkPolicy(cr)
			if got != tt.want {
				t.Errorf("ShouldCreateNetworkPolicy(mode=%q) = %v, want %v", tt.mode, got, tt.want)
			}
		})
	}
}

func TestShouldCreateNetworkPolicy_Default(t *testing.T) {
	cr := minimalCR() // No Network spec set
	if !ShouldCreateNetworkPolicy(cr) {
		t.Error("ShouldCreateNetworkPolicy() with nil Network spec should return true (default filtered)")
	}
}

func TestBuildNetworkPolicy_ModeNone_DenyAll(t *testing.T) {
	cr := crWithNetworkMode(NetworkModeNone)
	np := BuildNetworkPolicy(cr)

	if np == nil {
		t.Fatal("BuildNetworkPolicy(none) returned nil, expected deny-all policy")
	}

	// Namespace-level policy: both Ingress and Egress must be listed so the cluster
	// applies deny-all on both directions.
	if len(np.Spec.PolicyTypes) != 2 {
		t.Fatalf("PolicyTypes = %v, want [Ingress Egress]", np.Spec.PolicyTypes)
	}
	hasIngress := false
	hasEgress := false
	for _, pt := range np.Spec.PolicyTypes {
		if pt == networkingv1.PolicyTypeIngress {
			hasIngress = true
		}
		if pt == networkingv1.PolicyTypeEgress {
			hasEgress = true
		}
	}
	if !hasIngress || !hasEgress {
		t.Errorf("PolicyTypes = %v, want both Ingress and Egress", np.Spec.PolicyTypes)
	}

	// Deny-all egress: no egress rules.
	if len(np.Spec.Egress) != 0 {
		t.Errorf("Egress rules = %d, want 0 (deny-all)", len(np.Spec.Egress))
	}

	// Deny-all ingress: empty slice (not nil).
	if np.Spec.Ingress == nil {
		t.Error("Ingress should be empty slice (not nil) to express deny-all ingress")
	}
	if len(np.Spec.Ingress) != 0 {
		t.Errorf("Ingress rules = %d, want 0 (deny-all)", len(np.Spec.Ingress))
	}

	// Namespace-level selector: only managed-by label (not per-agent).
	sel := np.Spec.PodSelector.MatchLabels
	if sel[LabelManagedBy] != ManagedByValue {
		t.Errorf("PodSelector %s = %q, want %q", LabelManagedBy, sel[LabelManagedBy], ManagedByValue)
	}
	if _, ok := sel[LabelAgentID]; ok {
		t.Error("PodSelector must NOT contain agent-id label (namespace-level policy)")
	}

	// NetworkPolicy labels: only managed-by (no agent-id).
	if np.Labels[LabelManagedBy] != ManagedByValue {
		t.Errorf("label %s = %q, want %q", LabelManagedBy, np.Labels[LabelManagedBy], ManagedByValue)
	}
	if _, ok := np.Labels[LabelAgentID]; ok {
		t.Error("NetworkPolicy must NOT carry agent-id label (namespace-level policy)")
	}
}

func TestBuildNetworkPolicy_ModeFiltered_EgressRules(t *testing.T) {
	cr := crWithNetworkMode(NetworkModeFiltered)
	np := BuildNetworkPolicy(cr)

	if np == nil {
		t.Fatal("BuildNetworkPolicy(filtered) returned nil")
	}

	// Filtered mode: both Ingress and Egress policy types.
	if len(np.Spec.PolicyTypes) != 2 {
		t.Fatalf("PolicyTypes = %v, want [Ingress Egress]", np.Spec.PolicyTypes)
	}

	// Deny-all ingress even in filtered mode.
	if len(np.Spec.Ingress) != 0 {
		t.Errorf("Ingress rules = %d, want 0 (deny-all ingress)", len(np.Spec.Ingress))
	}

	if len(np.Spec.Egress) != 2 {
		t.Fatalf("Egress rules = %d, want 2 (DNS + service ports)", len(np.Spec.Egress))
	}

	// Rule 1: DNS (port 53 UDP + TCP).
	dnsRule := np.Spec.Egress[0]
	if len(dnsRule.Ports) != 2 {
		t.Fatalf("DNS rule ports = %d, want 2", len(dnsRule.Ports))
	}
	expectPort(t, dnsRule.Ports[0], corev1.ProtocolUDP, PortDNS)
	expectPort(t, dnsRule.Ports[1], corev1.ProtocolTCP, PortDNS)
	if len(dnsRule.To) != 0 {
		t.Error("DNS rule should have no To (allow any destination)")
	}

	// Rule 2: Service ports (22, 80, 443, 9418 TCP).
	serviceRule := np.Spec.Egress[1]
	if len(serviceRule.Ports) != 4 {
		t.Fatalf("Service rule ports = %d, want 4", len(serviceRule.Ports))
	}
	expectPort(t, serviceRule.Ports[0], corev1.ProtocolTCP, PortSSH)
	expectPort(t, serviceRule.Ports[1], corev1.ProtocolTCP, PortHTTP)
	expectPort(t, serviceRule.Ports[2], corev1.ProtocolTCP, PortHTTPS)
	expectPort(t, serviceRule.Ports[3], corev1.ProtocolTCP, PortGitProtocol)
	if len(serviceRule.To) != 0 {
		t.Error("Service rule should have no To (allow any destination)")
	}
}

func TestBuildNetworkPolicy_ModeOpen_ReturnsNil(t *testing.T) {
	cr := crWithNetworkMode(NetworkModeOpen)
	np := BuildNetworkPolicy(cr)
	if np != nil {
		t.Error("BuildNetworkPolicy(open) should return nil")
	}
}

// TestBuildNetworkPolicy_SelectorMatchesJobPodLabels verifies that the namespace-level
// NetworkPolicy selector (LabelManagedBy) matches a label that every agent Job pod carries.
func TestBuildNetworkPolicy_SelectorMatchesJobPodLabels(t *testing.T) {
	cr := minimalCR()
	job, err := BuildJob(cr, "")
	if err != nil {
		t.Fatalf("BuildJob() error: %v", err)
	}

	np := BuildNetworkPolicy(cr)
	if np == nil {
		t.Fatal("BuildNetworkPolicy() returned nil for default mode")
	}

	// The PodSelector labels must be a subset of the Job's pod template labels.
	podLabels := job.Spec.Template.Labels
	for k, v := range np.Spec.PodSelector.MatchLabels {
		podVal, ok := podLabels[k]
		if !ok {
			t.Errorf("PodSelector label %q not found on Job pod template", k)
		} else if podVal != v {
			t.Errorf("PodSelector label %s = %q, Job pod label = %q", k, v, podVal)
		}
	}
}

func TestBuildNetworkPolicy_Namespace(t *testing.T) {
	cr := minimalCR()
	cr.Namespace = "custom-ns"
	np := BuildNetworkPolicy(cr)
	if np == nil {
		t.Fatal("BuildNetworkPolicy() returned nil")
	}
	if np.Namespace != "custom-ns" {
		t.Errorf("Namespace = %q, want %q", np.Namespace, "custom-ns")
	}
}

// TestBuildNetworkPolicy_NoOwnerReference verifies the namespace-level policy
// has no owner reference (it must outlive individual AgentRequest deletions).
func TestBuildNetworkPolicy_NoOwnerReference(t *testing.T) {
	cr := crWithNetworkMode(NetworkModeFiltered)
	np := BuildNetworkPolicy(cr)
	if np == nil {
		t.Fatal("BuildNetworkPolicy() returned nil")
	}
	if len(np.OwnerReferences) != 0 {
		t.Errorf("OwnerReferences = %d, want 0 (namespace-level policy must not be owned)", len(np.OwnerReferences))
	}
}

// expectPort verifies a NetworkPolicyPort has the expected protocol and port number.
func expectPort(t *testing.T, p networkingv1.NetworkPolicyPort, proto corev1.Protocol, port int32) {
	t.Helper()
	if p.Protocol == nil || *p.Protocol != proto {
		t.Errorf("port protocol = %v, want %v", p.Protocol, proto)
	}
	if p.Port == nil || p.Port.IntVal != port {
		var got int32
		if p.Port != nil {
			got = p.Port.IntVal
		}
		t.Errorf("port number = %d, want %d", got, port)
	}
}
