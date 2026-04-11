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
	// NetworkPolicySuffix is appended to the CR name for the NetworkPolicy.
	NetworkPolicySuffix = "-netpol"

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
)

// NetworkPolicyName returns the deterministic NetworkPolicy name for an AgentRequest.
func NetworkPolicyName(cr *kapsisv1alpha1.AgentRequest) string {
	return cr.Name + NetworkPolicySuffix
}

// ShouldCreateNetworkPolicy returns true if a NetworkPolicy should be created
// for the given CR. Mode "open" needs no NetworkPolicy.
func ShouldCreateNetworkPolicy(cr *kapsisv1alpha1.AgentRequest) bool {
	return networkMode(cr) != NetworkModeOpen
}

// BuildNetworkPolicy constructs a NetworkPolicy from an AgentRequest CR.
//   - mode "none": deny-all egress (Egress PolicyType with no egress rules).
//   - mode "filtered": allow egress on ports 22/80/443/9418 + DNS (port 53 UDP/TCP).
//   - mode "open": returns nil (no NetworkPolicy needed).
func BuildNetworkPolicy(cr *kapsisv1alpha1.AgentRequest) *networkingv1.NetworkPolicy {
	mode := networkMode(cr)
	if mode == NetworkModeOpen {
		return nil
	}

	np := &networkingv1.NetworkPolicy{
		ObjectMeta: metav1.ObjectMeta{
			Name:      NetworkPolicyName(cr),
			Namespace: cr.Namespace,
			Labels: map[string]string{
				LabelAgentType: cr.Spec.Agent.Type,
				LabelAgentID:   cr.Name,
				LabelManagedBy: ManagedByValue,
			},
		},
		Spec: networkingv1.NetworkPolicySpec{
			PodSelector: metav1.LabelSelector{
				MatchLabels: map[string]string{
					LabelAgentID:   cr.Name,
					LabelManagedBy: ManagedByValue,
				},
			},
			PolicyTypes: []networkingv1.PolicyType{
				networkingv1.PolicyTypeEgress,
			},
		},
	}

	if mode == NetworkModeFiltered {
		np.Spec.Egress = buildFilteredEgressRules()
	}
	// mode "none": Egress is nil → deny-all egress.

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
//  1. DNS egress (port 53 UDP+TCP) — unrestricted destination so kube-dns works
//     regardless of cluster DNS implementation or placement.
//  2. Service ports (22, 80, 443, 9418 TCP) to any destination.
//     Fine-grained DNS-level filtering happens inside the container via dnsmasq.
func buildFilteredEgressRules() []networkingv1.NetworkPolicyEgressRule {
	protocolTCP := corev1.ProtocolTCP
	protocolUDP := corev1.ProtocolUDP
	dnsPort := intstr.FromInt32(PortDNS)

	// Rule 1: DNS egress (both UDP and TCP for large responses).
	dnsRule := networkingv1.NetworkPolicyEgressRule{
		Ports: []networkingv1.NetworkPolicyPort{
			{Protocol: &protocolUDP, Port: &dnsPort},
			{Protocol: &protocolTCP, Port: &dnsPort},
		},
	}

	// Rule 2: Allowed service ports (TCP only).
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
