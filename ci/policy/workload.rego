# Policy cho MỌI workload render ra từ registry/apps (ci/scripts/render-all.sh).
# Mỗi rule ở đây ứng với một dòng trong bảng PLAN §13 — và mỗi rule tồn tại vì
# một sự cố cụ thể mà nó ngăn được.
package main

import rego.v1

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet"}

is_workload if input.kind in workload_kinds

pod_spec := input.spec.template.spec if is_workload

all_containers contains c if {
	some c in object.get(pod_spec, "containers", [])
}

all_containers contains c if {
	some c in object.get(pod_spec, "initContainers", [])
}

# --- Tài nguyên -------------------------------------------------------------
# Một pod không limit ăn hết CPU node là cách nhanh nhất để mất cả môi trường.
deny contains msg if {
	is_workload
	some c in all_containers
	not c.resources.limits
	msg := sprintf("%s/%s: container %s thiếu resources.limits", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	is_workload
	some c in all_containers
	not c.resources.requests
	msg := sprintf("%s/%s: container %s thiếu resources.requests", [input.kind, input.metadata.name, c.name])
}

# --- Image ------------------------------------------------------------------
# Tag trôi = không tái tạo được = không quay lui được (D8).
deny contains msg if {
	is_workload
	some c in all_containers
	endswith(c.image, ":latest")
	msg := sprintf("%s/%s: container %s dùng tag latest", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	is_workload
	some c in all_containers
	not contains(c.image, ":")
	msg := sprintf("%s/%s: container %s không pin tag", [input.kind, input.metadata.name, c.name])
}

# Image của mình phải là git SHA. PLAN §4 viết 7 ký tự; chấp nhận 7–40 để dùng
# được luôn tag 8 ký tự mà CI hiện tại đang sinh — điều quan trọng là SHA, không
# phải độ dài.
own_registry_prefixes := ["ghcr.io/hnq-tech/", "registry.gitlab.com/hnq-tech/", "registry.gitlab.com/lifetocode/"]

# Ngoại lệ SHA — mỗi dòng là một món nợ nhìn thấy được, không phải một ngoại
# lệ im lặng. Bỏ dòng đi ngay khi pipeline của repo đó gắn tag SHA.
sha_exempt := {"registry.gitlab.com/hnq-tech/hnq-platform/server-control": "repo đó chưa gắn tag SHA; 1.1.0 là tag release cố định, không phải tag trôi"}

deny contains msg if {
	is_workload
	some c in all_containers
	some prefix in own_registry_prefixes
	startswith(c.image, prefix)
	repo := split(c.image, ":")[0]
	not sha_exempt[repo]
	tag := split(c.image, ":")[1]
	not regex.match(`^[0-9a-f]{7,40}$`, tag)
	msg := sprintf("%s/%s: container %s có tag %q — image của mình phải pin bằng git SHA", [input.kind, input.metadata.name, c.name, tag])
}

# --- Probe ------------------------------------------------------------------
# Không có readinessProbe thì Service đẩy traffic vào pod chưa sẵn sàng, và
# rolling update thành downtime.
#
# Ngoại lệ: controller không phục vụ traffic nào và không có endpoint sức khoẻ.
# Mỗi dòng phải có lý do.
probe_exempt := {"system-upgrade-controller": "controller thuần watch CRD, không nhận traffic"}

# Worker không có Service thì không ai gửi traffic tới, readinessProbe không
# quyết định điều gì. Chart tự gắn nhãn này khi service.enabled: false — ngoại
# lệ theo TÍNH CHẤT của workload, không theo tên service.
is_worker if {
	labels := object.get(input.spec.template.metadata, "labels", {})
	labels["hnq.dev/workload"] == "worker"
}

deny contains msg if {
	is_workload
	not probe_exempt[input.metadata.name]
	not is_worker
	some c in object.get(pod_spec, "containers", [])
	not c.readinessProbe
	msg := sprintf("%s/%s: container %s thiếu readinessProbe", [input.kind, input.metadata.name, c.name])
}

# --- Chỗ pod chạy -----------------------------------------------------------
# Không khai nodeSelector là pod rơi nhầm môi trường — lỗi im lặng cho tới lúc
# node đó tắt.
deny contains msg if {
	is_workload
	not pod_spec.nodeSelector
	msg := sprintf("%s/%s: thiếu nodeSelector", [input.kind, input.metadata.name])
}

deny contains msg if {
	is_workload
	count(object.get(pod_spec, "nodeSelector", {})) == 0
	msg := sprintf("%s/%s: nodeSelector rỗng", [input.kind, input.metadata.name])
}

# CronJob có pod template riêng — cũng phải khai nodeSelector.
deny contains msg if {
	input.kind == "CronJob"
	not input.spec.jobTemplate.spec.template.spec.nodeSelector
	msg := sprintf("CronJob/%s: thiếu nodeSelector", [input.metadata.name])
}

# --- Lưu trữ ----------------------------------------------------------------
# Class khác hnq-local là mất reclaimPolicy Retain và mất khả năng backup bằng
# Velero File System Backup (D11, D17).
deny contains msg if {
	input.kind == "PersistentVolumeClaim"
	input.spec.storageClassName != "hnq-local"
	msg := sprintf("PVC/%s: storageClassName=%q, chỉ được dùng hnq-local", [input.metadata.name, object.get(input.spec, "storageClassName", "")])
}

# --- Ingress ----------------------------------------------------------------
deny contains msg if {
	input.kind == "Ingress"
	not input.metadata.annotations["cert-manager.io/cluster-issuer"]
	msg := sprintf("Ingress/%s: thiếu annotation cert-manager.io/cluster-issuer — domain sẽ chạy không TLS", [input.metadata.name])
}
