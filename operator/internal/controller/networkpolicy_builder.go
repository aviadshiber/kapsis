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
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"

	kapsisv1alpha1 "github.com/aviadshiber/kapsis/operator/api/v1alpha1"
)

const (
	// Network mode values matching the CRD enum.
	NetworkModeNone     = "none"
	NetworkModeFiltered = "filtered"
	NetworkModeOpen     = "open"

	// Allowed egress ports for filtered mode.
	PortSSH         = 22
	PortHTTP        = 80
	PortHTTPS       = 443
	PortGitProtocol = 9418
	PortDNS         = 53

	// networkPolicyNameFiltered / networkPolicyNameNone are the stable, namespace-level
	// policy names. One policy per namespace per mode — not per AgentRequest.
	// This avoids O(N) fan-out when many agents run concurrently.
	networkPolicyNameFiltered = "kapsis-filtered-policy"
	networkPolicyNameNone     = "kapsis-none-policy"
)

// ShouldCreateNetworkPolicy returns true if a namespace-level NetworkPolicy
// should be created for the given CR. Mode "open" needs no policy.
func ShouldCreateNetworkPolicy(cr *kapsisv1alpha1.AgentRequest) bool {
	return networkMode(cr) != NetworkModeOpen
}

// BuildNetworkPolicy constructs a namespace-level NetworkPolicy for all kapsis-agent
// pods in the namespace. The policy applies to ALL pods with the managed-by label,
// so it is created once and reused across concurrent agent runs.
//
//   - mode "none":     deny-all egress + deny-all ingress.
//   - mode "filtered": allow egress on ports 22/80/443/9418 + DNS (port 53 UDP/TCP);
//     deny-all ingress so agents cannot receive inbound connections.
//   - mode "open":     returns nil (no NetworkPolicy needed).
//
// The returned NetworkPolicy is NOT owned by the AgentRequest — it outlives
// individual runs and must not be garbage-collected when a single CR is deleted.
func BuildNetworkPolicy(cr *kapsisv1alpha1.AgentRequest) *networkingv1.NetworkPolicy {
	mode := networkMode(cr)
	if mode == NetworkModeOpen {
		return nil
	}

	name := networkPolicyNameFiltered
	if mode == NetworkModeNone {
		name = networkPolicyNameNone
	}

	np := &networkingv1.NetworkPolicy{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: cr.Namespace,
			Labels: map[string]string{
				LabelManagedBy: ManagedByValue,
			},
		},
		Spec: networkingv1.NetworkPolicySpec{
			// Applies to all pods managed by the kapsis operator in this namespace.
			PodSelector: metav1.LabelSelector{
				MatchLabels: map[string]string{
					LabelManagedBy: ManagedByValue,
				},
			},
			// Deny all ingress — agents must not receive inbound connections.
			// Deny all egress by default; filtered mode adds explicit allow rules below.
			PolicyTypes: []networkingv1.PolicyType{
				networkingv1.PolicyTypeIngress,
				networkingv1.PolicyTypeEgress,
			},
			// Ingress: empty slice = deny all (agents never receive connections).
			Ingress: []networkingv1.NetworkPolicyIngressRule{},
		},
	}

	if mode == NetworkModeFiltered {
		np.Spec.Egress = buildFilteredEgressRules()
	}
	// mode "none": Egress is nil → deny-all egress (combined with deny-all ingress above).

	return np
}

// networkMode returns the effective network mode, defaulting to "filtered".
func networkMode(cr *kapsisv1alpha1.AgentRequest) string {
	if cr.Spec.Network != nil && cr.Spec.Network.Mode != "" {
		return cr.Spec.Network.Mode
	}
	return NetworkModeFiltered
}

// buildFilteredEgressRules returns egress rules for filtered mode:
//  1. DNS egress (port 53 UDP+TCP) — unrestricted destination so kube-dns resolves
//     regardless of cluster DNS implementation or placement.
//  2. Service ports (22, 80, 443, 9418 TCP) to any destination.
//     Fine-grained DNS-level filtering is handled inside the container via dnsmasq.
func buildFilteredEgressRules() []networkingv1.NetworkPolicyEgressRule {
	protocolTCP := corev1.ProtocolTCP
	protocolUDP := corev1.ProtocolUDP
	dnsPort := intstr.FromInt32(PortDNS)

	dnsRule := networkingv1.NetworkPolicyEgressRule{
		Ports: []networkingv1.NetworkPolicyPort{
			{Protocol: &protocolUDP, Port: &dnsPort},
			{Protocol: &protocolTCP, Port: &dnsPort},
		},
	}

	sshPort := intstr.FromInt32(PortSSH)
	httpPort := intstr.FromInt32(PortHTTP)
	httpsPort := intstr.FromInt32(PortHTTPS)
	gitPort := intstr.FromInt32(PortGitProtocol)

	serviceRule := networkingv1.NetworkPolicyEgressRule{
		Ports: []networkingv1.NetworkPolicyPort{
			{Protocol: &protocolTCP, Port: &sshPort},
			{Protocol: &protocolTCP, Port: &httpPort},
			{Protocol: &protocolTCP, Port: &httpsPort},
			{Protocol: &protocolTCP, Port: &gitPort},
		},
	}

	return []networkingv1.NetworkPolicyEgressRule{dnsRule, serviceRule}
}
