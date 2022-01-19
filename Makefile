# Image URL to use all building/pushing image targets
IMG ?= public.ecr.aws/a4z9h2b1/cluster-api-provider-capc:latest

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# Allow overriding release-manifest generation destination directory
RELEASE_DIR ?= out

# Quiet Ginkgo for now.
# The warnings are in regards to a future release.
export ACK_GINKGO_DEPRECATIONS := 1.16.5
export ACK_GINKGO_RC=true

PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
export PATH := $(PROJECT_DIR)/bin:$(PATH)

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

MANIFEST_GEN_INPUTS=$(shell find ./api -type f -name "*test*" -prune -o -name "*zz_generated*" -prune -o -print)
# Using a flag file here as config output is too complicated to be a target.
# The following triggers manifest building if $(IMG) differs from that found in config/default/manager_image_patch.yaml.
$(shell	grep -qs "$(IMG)" config/default/manager_image_patch_edited.yaml || rm -f config/.flag.mk)
.PHONY: manifests
manifests: config/.flag.mk ## Generates crd, webhook, rbac, and other configuration manifests from kubebuilder instructions in go comments.
config/.flag.mk: bin/controller-gen $(MANIFEST_GEN_INPUTS)
	sed -e 's@image: .*@image: '"$(IMG)"'@' config/default/manager_image_patch.yaml > config/default/manager_image_patch_edited.yaml
	controller-gen crd:crdVersions=v1 rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	@touch config/.flag.mk

.PHONY: release-manifests
RELEASE_MANIFEST_TARGETS=$(RELEASE_DIR)/infrastructure-components.yaml $(RELEASE_DIR)/metadata.yaml
RELEASE_MANIFEST_INPUTS=config/.flag.mk $(shell find config)
release-manifests: $(RELEASE_MANIFEST_TARGETS) ## Create kustomized release manifest in $RELEASE_DIR (defaults to out).
$(RELEASE_DIR)/%: $(RELEASE_MANIFEST_INPUTS)
	@mkdir -p $(RELEASE_DIR)
	cp metadata.yaml $(RELEASE_DIR)/metadata.yaml
	kustomize build config/default > $(RELEASE_DIR)/infrastructure-components.yaml

DEEPCOPY_GEN_TARGETS=$(shell find api -type d -name "v*" -exec echo {}\/zz_generated.deepcopy.go \;)
DEEPCOPY_GEN_INPUTS=$(shell find ./api -name "*test*" -prune -o -name "*zz_generated*" -prune -o -type f -print)
.PHONY: generate-deepcopy
generate-deepcopy: $(DEEPCOPY_GEN_TARGETS) ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
api/%/zz_generated.deepcopy.go: bin/controller-gen $(DEEPCOPY_GEN_INPUTS)
	controller-gen object:headerFile="hack/boilerplate.go.txt" paths="./..."

##@ Build

MANAGER_BIN_INPUTS=$(shell find ./controllers ./api ./pkg -name "*mock*" -prune -o -name "*test*" -prune -o -type f -print) main.go go.mod go.sum
.PHONY: build
build: binaries generate-deepcopy manifests release-manifests bin/manager bin/mockgen ## Build manager binary.
bin/manager: $(MANAGER_BIN_INPUTS)
	go fmt ./...
	go vet ./...
	go build -o bin/manager main.go

.PHONY: run
run: generate-deepcopy fmt vet ## Run a controller from your host.
	go fmt ./...
	go vet ./...
	go run ./main.go

# Using a flag file here as docker build doesn't produce a target file.
DOCKER_BUILD_INPUTS=$(MANAGER_BIN_INPUTS) Dockerfile
.PHONY: docker-build
docker-build: .dockerflag.mk ## Build docker image containing the controller manager.
.dockerflag.mk: $(DOCKER_BUILD_INPUTS)
	docker build -t ${IMG} .
	@touch .dockerflag.mk

.PHONY: docker-push
docker-push: .dockerflag.mk ## Push docker image with the manager.
	docker push ${IMG}

##@ Linting

.PHONY: fmt
fmt: ## Run go fmt on the whole project.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet on the whole project.
	go vet ./...

.PHONY: lint
lint: bin/golangci-lint ## Run linting for the project.
	go fmt ./...
	go vet ./...
	golangci-lint run -v --timeout 360s ./...
	@ # The below string of commands checks that ginkgo isn't present in the controllers.
	@(grep ginkgo ${PROJECT_DIR}/controllers/cloudstack*_controller.go && \
		echo "Remove ginkgo from controllers. This is probably an artifact of testing." \
		 	 "See the hack/testing_ginkgo_recover_statements.sh file") && exit 1 || \
		echo "Gingko statements not found in controllers... (passed)"

##@ Deployment

.PHONY: deploy
deploy: generate-deepcopy manifests bin/kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && kustomize edit set image controller=${IMG}
	kustomize build config/default | kubectl apply -f -

undeploy: bin/kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	kustomize build config/default | kubectl delete -f -

##@ Binaries

.PHONY: binaries
binaries: bin/controller-gen bin/kustomize bin/ginkgo bin/golangci-lint bin/mockgen bin/kubectl ## Locally install all needed bins.
bin/controller-gen: ## Install controller-gen to bin.
	GOBIN=$(PROJECT_DIR)/bin go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.9
bin/golangci-lint: ## Install golangci-lint to bin.
	GOBIN=$(PROJECT_DIR)/bin go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.43.0
bin/ginkgo: ## Install ginkgo to bin.
	GOBIN=$(PROJECT_DIR)/bin go install github.com/onsi/ginkgo/ginkgo@v1.16.5
bin/mockgen:
	GOBIN=$(PROJECT_DIR)/bin go install github.com/golang/mock/mockgen@v1.6.0
bin/kustomize: ## Install kustomize to bin.
	@mkdir -p bin
	cd bin && curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash
export K8S_VERSION=1.19.2
bin/kubectl bin/kube-apiserver bin/etcd &:
	curl --silent -L "https://go.kubebuilder.io/test-tools/${K8S_VERSION}/$(shell go env GOOS)/$(shell go env GOARCH)" --output - | \
		tar -C ./ --strip-components=1 -zvxf -

##@ Cleanup

.PHONY: clean
clean: ## Clean.
	rm -rf $(RELEASE_DIR)
	rm -rf bin
	rm -rf cluster-api

##@ Testing

# Tell envtest to use local bins for etcd, kubeapi-server, and kubectl.
export KUBEBUILDER_ASSETS=$(PROJECT_DIR)/bin

.PHONY: test
test: lint generate-deepcopy generate-mocks bin/ginkgo bin/kubectl bin/kube-apiserver bin/etcd ## Run tests. At the moment this is only unit tests.
	@./hack/testing_ginkgo_recover_statements.sh --add # Add ginkgo.GinkgoRecover() statements to controllers.
	@# The following is a slightly funky way to make sure the ginkgo statements are removed regardless the test results.
	@ginkgo -v ./api/... ./controllers/... ./pkg/... -coverprofile cover.out; EXIT_STATUS=$$?;\
		./hack/testing_ginkgo_recover_statements.sh --remove; exit $$EXIT_STATUS
	
.PHONY: generate-mocks
generate-mocks: bin/mockgen $(shell find ./pkg/mocks -type f -name "mock*.go") ## Generate mocks needed for testing. Primarily mocks of the cloud package.
pkg/mocks/mock%.go: $(shell find ./pkg/cloud -type f -name "*test*" -prune -o -print)
	go generate ./...

##@ Tilt

.PHONY: tilt-up 
tilt-up: cluster-api kind-cluster cluster-api/tilt-settings.json manifests cloud-config # Setup and run tilt for development.
	export CLOUDSTACK_B64ENCODED_SECRET=$$(base64 -i cloud-config) && cd cluster-api && tilt up

.PHONY: kind-cluster
kind-cluster: cluster-api cluster-api/hack/kind-install-for-capd.sh # Create a kind cluster with a local Docker repository.
	-./cluster-api/hack/kind-install-for-capd.sh

cluster-api: # Clone cluster-api repository for tilt use.
	git clone --branch v0.3.24 https://github.com/kubernetes-sigs/cluster-api.git

# Need script from CAPI v1.0+
# Can delete this target after upgrading to newer CAPI.
cluster-api/hack/kind-install-for-capd.sh: cluster-api
	cd cluster-api && git checkout v1.0.0 -- hack/kind-install-for-capd.sh

# Need script from CAPI v1.0+
# Can delete this target after upgrading to newer CAPI.
cluster-api/tilt-settings.json: hack/tilt-settings.json cluster-api
	cp ./hack/tilt-settings.json cluster-api

