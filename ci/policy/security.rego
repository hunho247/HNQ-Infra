# Policy an toàn: những thứ cho phép một pod thoát khỏi ranh giới của nó, hoặc
# làm hỏng lưới backup.
package main

import rego.v1

# 5 thành phần platform duy nhất được phép chạy trên hnq-01 (PLAN §2).
# Taint là hàng rào của scheduler; rule này là hàng rào của review — giữ cả hai
# vì mỗi cái bắt lỗi ở một thời điểm khác nhau.
control_plane_allowlist := {
	"argocd",
	"cert-manager",
	"sealed-secrets",
	"velero",
	"system-upgrade-controller",
	# node-exporter là DaemonSet: không chạy trên master thì không thấy đĩa
	# master sắp đầy — đúng cái alert cần nhất.
	"prometheus-node-exporter",
}

pod_specs contains ps if {
	input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
	ps := input.spec.template.spec
}

pod_specs contains ps if {
	input.kind == "CronJob"
	ps := input.spec.jobTemplate.spec.template.spec
}

name_allowed if {
	some allowed in control_plane_allowlist
	startswith(input.metadata.name, allowed)
}

deny contains msg if {
	some ps in pod_specs
	some t in object.get(ps, "tolerations", [])
	t.key == "hnq.dev/dedicated"
	not name_allowed
	msg := sprintf("%s/%s: khai toleration hnq.dev/dedicated — chỉ 5 thành phần platform ở PLAN §2 được lách taint của master", [input.kind, input.metadata.name])
}

deny contains msg if {
	some ps in pod_specs
	ps.hostNetwork == true
	msg := sprintf("%s/%s: hostNetwork=true — pod dùng chung network namespace với node", [input.kind, input.metadata.name])
}

# Ngoại lệ hostPath — mỗi dòng phải có lý do, và chỉ dành cho thành phần
# platform không có cách nào khác. Dữ liệu của service KHÔNG BAO GIỜ nằm ở đây:
# hostPath là thứ Velero không backup được.
hostpath_exempt := {"system-upgrade-controller": "cần /etc/ssl của node để xác thực chữ ký bản k3s tải về"}

deny contains msg if {
	some ps in pod_specs
	some v in object.get(ps, "volumes", [])
	v.hostPath
	not hostpath_exempt[input.metadata.name]
	msg := sprintf("%s/%s: volume hostPath (%s) — Velero KHÔNG backup được hostPath, và đó là đường thoát container", [input.kind, input.metadata.name, v.name])
}

deny contains msg if {
	some ps in pod_specs
	some c in array.concat(object.get(ps, "containers", []), object.get(ps, "initContainers", []))
	c.securityContext.privileged == true
	msg := sprintf("%s/%s: container %s chạy privileged", [input.kind, input.metadata.name, c.name])
}
