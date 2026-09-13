# Policy cho chính các file GitOps: Application, ApplicationSet, AppProject.
# Chạy trên gitops/**.yaml, không phải trên manifest đã render.
package gitops

import rego.v1

is_app if input.kind == "Application"

# Pin version tuyệt đối ở mọi Application (D23). targetRevision kiểu HEAD,
# main hay một dải semver nghĩa là hai lần sync có thể ra hai phiên bản khác
# nhau mà Git không ghi lại gì.
floating := {"HEAD", "main", "master", "latest", "*"}

deny contains msg if {
	is_app
	input.spec.source.chart
	rev := input.spec.source.targetRevision
	rev in floating
	msg := sprintf("Application/%s: targetRevision=%q cho chart %q — phải pin version tuyệt đối", [input.metadata.name, rev, input.spec.source.chart])
}

deny contains msg if {
	is_app
	input.spec.source.chart
	rev := input.spec.source.targetRevision
	contains(rev, "*")
	msg := sprintf("Application/%s: targetRevision=%q có ký tự đại diện", [input.metadata.name, rev])
}

# Prod không bao giờ tự prune (D8): xoá tài nguyên prod là thao tác tay có
# chủ ý, không phải hệ quả của một PR sửa nhầm.
deny contains msg if {
	is_app
	endswith(input.metadata.name, "-prod")
	input.spec.syncPolicy.automated.prune == true
	msg := sprintf("Application/%s: prune=true ở prod", [input.metadata.name])
}

# ArgoCD không bao giờ lộ ra internet (D20).
deny contains msg if {
	input.kind == "Ingress"
	input.metadata.namespace == "argocd"
	msg := sprintf("Ingress/%s ở namespace argocd — ArgoCD vào bằng port-forward qua tailnet, không qua internet", [input.metadata.name])
}

# ApplicationSet phải giữ hai chốt an toàn của D15.
deny contains msg if {
	input.kind == "ApplicationSet"
	input.spec.syncPolicy.applicationsSync != "create-update"
	msg := sprintf("ApplicationSet/%s: applicationsSync phải là create-update — generator hỏng không được phép xoá hàng loạt Application", [input.metadata.name])
}

deny contains msg if {
	input.kind == "ApplicationSet"
	not input.spec.syncPolicy.preserveResourcesOnDeletion
	msg := sprintf("ApplicationSet/%s: thiếu preserveResourcesOnDeletion: true", [input.metadata.name])
}
