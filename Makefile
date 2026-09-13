# Lệnh hằng ngày (OPERATIONS.md). Bốn lệnh đáng thuộc nằm lòng:
#   make drift      hằng tuần
#   make snapshot   trước mọi việc nguy hiểm
#   make kit-check  hằng tháng
#   make dr         lúc sự cố, khi không nhớ nổi phải làm gì
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help status pending logs sh top events drift sync promote snapshot \
        kit-check dr validate render lint test new-service bootstrap verify-dumps

help:           ## Danh sách lệnh
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

# ---- hằng ngày -------------------------------------------------------------
status:         ## Bảng service: tag dev ↔ prod ↔ trạng thái ArgoCD
	@scripts/status.sh

pending:        ## Service nào ở dev đang chờ lên prod
	@scripts/status.sh --pending-only

logs:           ## make logs SVC=lotus-clinic ENV=prod
	@stern -n $(SVC)-$(ENV) . --tail 100

sh:             ## make sh SVC=lotus-clinic ENV=dev
	@kubectl -n $(SVC)-$(ENV) exec -it $$(kubectl -n $(SVC)-$(ENV) get pod -o name | head -1) -- sh

top:            ## Node và pod ăn tài nguyên nhất
	@kubectl top nodes && kubectl top pods -A --sort-by=memory | head -15

events:         ## Event bất thường gần đây
	@kubectl get events -A --sort-by=.lastTimestamp --field-selector type!=Normal | tail -30

drift:          ## Cái gì lệch Git + đường dữ liệu còn dự phòng không (hằng tuần)
	@scripts/drift.sh

sync:           ## make sync SVC=lotus-clinic ENV=dev
	@argocd app sync $(SVC)-$(ENV)

# ---- thay đổi --------------------------------------------------------------
new-service:    ## make new-service NAME=abc-clinic CHART=webservice [CONFIG=true]
	@ci/scripts/new-service.sh NAME=$(NAME) CHART=$(CHART) CONFIG=$(or $(CONFIG),false)

promote:        ## Đưa image dev lên prod: make promote NAME=lotus-clinic
	@ci/scripts/promote.sh "$(NAME)"

# ---- kiểm trước khi commit (giống hệt CI) ----------------------------------
validate: lint test render ## Chạy toàn bộ cửa CI ngay trên máy
	@ci/scripts/check-secrets.sh
	@conftest test --policy ci/policy .render/*.yaml .render/platform/*.yaml
	@conftest test --policy ci/policy --namespace gitops \
	  gitops/root.yaml gitops/bootstrap/*.yaml gitops/bootstrap/platform/*.yaml
	@echo "✅ tất cả cửa CI đều xanh"

lint:           ## yamllint + JSON Schema + helm lint
	@yamllint -c .yamllint.yaml .
	@ci/scripts/check-schema.sh
	@helm dependency build charts/webservice >/dev/null 2>&1 || helm dependency update charts/webservice >/dev/null
	@helm lint charts/webservice -f env/dev.yaml \
	  --set image.repository=x --set image.tag=abc1234 --set ingress.host=x.example.com
	@helm dependency build charts/datastore >/dev/null 2>&1 || helm dependency update charts/datastore >/dev/null
	@helm lint charts/datastore -f env/dev.yaml \
	  --set image.repository=x --set image.tag=abc1234 --set backup.command=x

test:           ## helm unittest
	@helm unittest charts/webservice charts/datastore

render:         ## Render mọi service × mọi env rồi kubeconform
	@ci/scripts/render-all.sh
	@kubeconform -strict -ignore-missing-schemas -summary .render/*.yaml .render/platform/*.yaml

# ---- an toàn ---------------------------------------------------------------
snapshot:       ## etcd snapshot NGAY — chạy trước mọi việc nguy hiểm
	@ssh hnq-01 'sudo k3s etcd-snapshot save --name manual-$$(date +%Y%m%d-%H%M)'

kit-check:      ## Recovery kit còn đủ 4 món và còn dùng được? (hằng tháng)
	@scripts/dr/kit-check.sh

verify-dumps:   ## Dump hằng giờ có thật sự lên R2 và còn mới không
	@scripts/backup/verify-dumps.sh prod

dr:             ## In phần "60 giây đầu tiên" — gõ khi đang sự cố
	@sed -n '/## 60 giây đầu tiên/,/## Recovery kit/p' docs/RECOVERY.md

bootstrap:      ## Dựng cluster lần đầu — in đúng thứ tự, không tự chạy
	@echo "helm repo add argo https://argoproj.github.io/argo-helm && helm repo update"
	@echo "helm install argocd argo/argo-cd -n argocd --create-namespace -f gitops/install/argocd-values.yaml"
	@echo "kubectl -n argocd apply -f gitops/root.yaml     # lệnh duy nhất apply tay trong đời cluster"
	@echo "kubectl -n kube-system scale deploy coredns --replicas=2"
	@echo "kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/sealing-key.yaml"
	@echo "# → password manager (2 nơi), rồi shred -u ~/sealing-key.yaml"
