# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Save the current, builtin variables so we can filter them out in the `print-variables` target
OLD_VARS := $(.VARIABLES)

# Most variables defined in this Makefile can be overriden in Makefile.vendor.mk
# Use `make print-variables` to inspect the values of the variables
-include Makefile.vendor.mk

VERSION ?= 1.27.0
MINOR_VERSION := $(shell echo "${VERSION}" | cut -f1,2 -d'.')

# This version will be used to generate the OLM upgrade graph in the FBC as a version to be replaced by the new operator version defined in $VERSION.
# This applies for stable releases, for nightly releases we are getting previous version directly from the FBC.
# Currently we are pushing the operator to two operator hubs https://github.com/k8s-operatorhub/community-operators and
# https://github.com/redhat-openshift-ecosystem/community-operators-prod. Nightly builds go only to community-operators-prod which already
# supports FBC. FBC yaml files and kept in community-operators-prod repo and we only generate a PR with changes using make targets from this Makefile.
# There are also GH workflows defined to release nightly and stable operators.
# There is no need to define `replaces` and `skipRange` fields in the CSV as those fields are defined in the FBC and CSV values are ignored.
# FBC is source of truth for OLM upgrade graph.
PREVIOUS_VERSION ?= 1.26.0

OPERATOR_NAME ?= sailoperator
VERSIONS_YAML_DIR ?= pkg/istioversion
VERSIONS_YAML_FILE ?= versions.yaml

# Istio images names
ISTIO_CNI_IMAGE_NAME ?= install-cni
ISTIO_PILOT_IMAGE_NAME ?= pilot
ISTIO_PROXY_IMAGE_NAME ?= proxyv2

# GitHub creds
GITHUB_USER ?= openshift-service-mesh-bot
GITHUB_TOKEN ?= 

SOURCE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

# Git repository state
ifndef GIT_TAG
GIT_TAG := $(shell git describe 2> /dev/null || echo "unknown")
endif
ifndef GIT_REVISION
GIT_REVISION := $(shell git rev-parse --verify HEAD 2> /dev/null || echo "unknown")
endif
ifndef GIT_STATUS
GIT_STATUS := $(shell git diff-index --quiet HEAD -- 2> /dev/null; if [ "$$?" = "0" ]; then echo Clean; else echo Modified; fi)
endif

# Linker flags for the go builds
GO_MODULE = github.com/istio-ecosystem/sail-operator
VENDOR_LD_EXTRAFLAGS ?=
LD_EXTRAFLAGS = -X ${GO_MODULE}/pkg/version.buildVersion=${VERSION}
LD_EXTRAFLAGS += -X ${GO_MODULE}/pkg/version.buildGitRevision=${GIT_REVISION}
LD_EXTRAFLAGS += -X ${GO_MODULE}/pkg/version.buildTag=${GIT_TAG}
LD_EXTRAFLAGS += -X ${GO_MODULE}/pkg/version.buildStatus=${GIT_STATUS}
LD_EXTRAFLAGS += -X ${GO_MODULE}/pkg/istioversion.versionsFilename=${VERSIONS_YAML_FILE}
LD_EXTRAFLAGS += $(VENDOR_LD_EXTRAFLAGS)

IS_FIPS_COMPLIANT ?= false # set to true for FIPS compliance
ifeq ($(IS_FIPS_COMPLIANT), true)
	CGO_ENABLED = 1
	LD_FLAGS = ${LD_EXTRAFLAGS} -s -w
else
	CGO_ENABLED = 0
	LD_FLAGS = -extldflags -static ${LD_EXTRAFLAGS} -s -w
endif

# Image hub to use
HUB ?= quay.io/sail-dev
# Image tag to use
TAG ?= ${MINOR_VERSION}-latest
# Image base to use
IMAGE_BASE ?= sail-operator
# Image URL to use all building/pushing image targets
IMAGE ?= ${HUB}/${IMAGE_BASE}:${TAG}
# Namespace to deploy the controller in
NAMESPACE ?= sail-operator
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION ?= 1.30.0

ifeq ($(findstring gen-check,$(MAKECMDGOALS)),gen-check)
FORCE_DOWNLOADS := true
else
FORCE_DOWNLOADS ?= false
endif

# Set DOCKER_BUILD_FLAGS to specify flags to pass to 'docker build', default to empty. Example: --platform=linux/arm64
DOCKER_BUILD_FLAGS ?= "--platform=$(TARGET_OS)/$(TARGET_ARCH)"

GOTEST_FLAGS := $(if $(VERBOSE),-v) $(if $(COVERAGE),-coverprofile=$(REPO_ROOT)/out/coverage-unit.out)
GINKGO_FLAGS ?= $(if $(VERBOSE),-v) $(if $(CI),--no-color) $(if $(COVERAGE),-coverprofile=coverage-integration.out -coverpkg=./... --output-dir=out)

# Fail fast when keeping the environment on failure, to make sure we don't contaminate it with other resources. Also make sure to skip cleanup so it won't be deleted.
ifeq ($(KEEP_ON_FAILURE),true)
GINKGO_FLAGS += --fail-fast
SKIP_CLEANUP = true
endif

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
CHANNEL_PREFIX := dev

CHANNELS ?= $(CHANNEL_PREFIX)-$(MINOR_VERSION)
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS = --channels=\"$(CHANNELS)\"
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# quay.io/sail-dev/sail-operator-bundle:$VERSION and quay.io/sail-dev/sail-operator-catalog:$VERSION.
IMAGE_TAG_BASE ?= ${HUB}/${IMAGE_BASE}

BUNDLE_MANIFEST_DATE := $(shell cat bundle/manifests/${OPERATOR_NAME}.clusterserviceversion.yaml 2>/dev/null | grep createdAt | awk '{print $$2}')

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# BUNDLE_GEN_FLAGS are the flags passed to the operator-sdk generate bundle command
BUNDLE_GEN_FLAGS ?= -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

# USE_IMAGE_DIGESTS defines if images are resolved via tags or digests
# You can enable this value if you would like to use SHA Based Digests
# To enable set flag to true
# It also adds .spec.relatedImages field to generated CSV
# Note that 'operator-sdk generate bundle' always removes spec.relatedImages field when USE_IMAGE_DIGESTS=false, even if the field already exists in the base CSV
# Make sure to enable this before creating a release as it's a requirement for disconnected environments.
USE_IMAGE_DIGESTS ?= false
GENERATE_RELATED_IMAGES ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
	BUNDLE_GEN_FLAGS += --use-image-digests
endif

# Default values and flags used when rendering chart templates locally
HELM_VALUES_FILE ?= chart/values.yaml
HELM_TEMPL_DEF_FLAGS ?= --include-crds --values $(HELM_VALUES_FILE)

TODAY ?= $(shell date -I)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /bin/bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

export

##@ Testing

.PHONY: test
test: test.unit test.integration ## Run both unit tests and integration test.

.PHONY: test.unit
test.unit: envtest  ## Run unit tests.
ifdef COVERAGE
	if [ ! -d "$(REPO_ROOT)/out" ]; then mkdir $(REPO_ROOT)/out; fi
endif
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" \
	go test $(GOTEST_FLAGS) ./...

.PHONY: test.integration
test.integration: envtest ## Run integration tests located in the tests/integration directory.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" \
	go run github.com/onsi/ginkgo/v2/ginkgo --tags=integration $(GINKGO_FLAGS) ./tests/integration/...

.PHONY: test.scorecard
test.scorecard: operator-sdk ## Run the operator scorecard test.
	OPERATOR_SDK=$(OPERATOR_SDK) ${SOURCE_DIR}/tests/scorecard-test.sh

.PHONY: test.e2e.ocp
test.e2e.ocp: istioctl ## Run the end-to-end tests against an existing OCP cluster. While running on OCP in downstream you need to set ISTIOCTL_DOWNLOAD_URL to the URL where the istioctl productized binary.
	GINKGO_FLAGS="$(GINKGO_FLAGS)" ${SOURCE_DIR}/tests/e2e/integ-suite-ocp.sh

.PHONY: test.e2e.kind
test.e2e.kind: istioctl ## Deploy a KinD cluster and run the end-to-end tests against it.
	GINKGO_FLAGS="$(GINKGO_FLAGS)" ISTIOCTL="$(ISTIOCTL)" ${SOURCE_DIR}/tests/e2e/integ-suite-kind.sh

.PHONY: test.e2e.describe
test.e2e.describe: ## Runs ginkgo outline -format indent over the e2e test to show in BDD style the steps and test structure
	GINKGO_FLAGS="$(GINKGO_FLAGS)" ${SOURCE_DIR}/tests/e2e/common-operator-integ-suite.sh --describe

.PHONE: test.docs
test.docs: runme istioctl ## Run the documentation examples tests.
## test.docs use runme to test the documentation examples. 
## Check the specific documentation to understand the use of the tool
	@echo "Running runme test on the documentation examples."
	@PATH=$(LOCALBIN):$$PATH tests/documentation_tests/scripts/run-docs-examples.sh
	@echo "Documentation examples tested successfully"

##@ Build

.PHONY: build
build: build-$(TARGET_ARCH) ## Build the sail-operator binary.

.PHONY: run
run: gen ## Run a controller from your host.
	POD_NAMESPACE=${NAMESPACE} go run ./cmd/main.go --config-file=./hack/config.properties --resource-directory=./resources

# docker build -t ${IMAGE} --build-arg GIT_TAG=${GIT_TAG} --build-arg GIT_REVISION=${GIT_REVISION} --build-arg GIT_STATUS=${GIT_STATUS} .
.PHONY: docker-build
docker-build: build ## Build docker image.
	docker build ${DOCKER_BUILD_FLAGS} -t ${IMAGE} .

PHONY: push
push: docker-push ## Build and push docker image.

.PHONY: docker-push
docker-push: docker-build ## Build and Push docker image.
	docker push ${IMAGE}

.PHONY: docker-push-nightly
docker-push-nightly: TAG=$(MINOR_VERSION)-nightly-$(TODAY) ## Build and push nightly docker image.
docker-push-nightly: docker-build
	docker push ${IMAGE}
	docker tag ${IMAGE} $(HUB)/$(IMAGE_BASE):$(MINOR_VERSION)-latest
	docker push $(HUB)/$(IMAGE_BASE):$(MINOR_VERSION)-latest

# NIGHTLY defines if the nightly image should be pushed or not
NIGHTLY ?= false

# BUILDX_OUTPUT defines the buildx output
# --load builds locally the container image
# --push builds and pushes the container image to a registry
BUILDX_OUTPUT ?= --push

# BUILDX_ADDITIONAL_TAGS are the additional --tag flags passed to the docker buildx build command.
BUILDX_ADDITIONAL_TAGS =
ifeq ($(NIGHTLY),true)
BUILDX_ADDITIONAL_TAGS += --tag $(HUB)/$(IMAGE_BASE):$(MINOR_VERSION)-nightly-$(TODAY)
endif

# BUILDX_BUILD_ARGS are the additional --build-arg flags passed to the docker buildx build command.
BUILDX_BUILD_ARGS = --build-arg TARGETOS=$(TARGET_OS)

# PLATFORMS defines the target platforms for the sail-operator image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMAGE=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image for your registry (i.e. if you do not inform a valid value via IMAGE=<myregistry/image:<tag>> then the export will fail)
# To properly provided solutions that supports more than one platform you should use this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
PLATFORM_ARCHITECTURES = $(shell echo ${PLATFORMS} | sed -e 's/,/\ /g' -e 's/linux\///g')

ifndef BUILDX
define BUILDX
.PHONY: build-$(1)
build-$(1): ## Build sail-operator binary for specific architecture.
	GOARCH=$(1) CGO_ENABLED=$(CGO_ENABLED) LDFLAGS="$(LD_FLAGS)" common/scripts/gobuild.sh $(REPO_ROOT)/out/$(TARGET_OS)_$(1)/sail-operator cmd/main.go

.PHONY: build-all
build-all: build-$(1)
endef

$(foreach arch,$(PLATFORM_ARCHITECTURES),$(eval $(call BUILDX,$(arch))))
undefine BUILDX
endif

.PHONY: docker-buildx
docker-buildx: build-all ## Build and push docker image with cross-platform support.
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	docker buildx ls --format "{{.Name}}" | grep project-v4-builder || docker buildx create --name project-v4-builder
	docker buildx use project-v4-builder
	docker buildx build $(BUILDX_OUTPUT) --platform=$(PLATFORMS) --tag ${IMAGE} $(BUILDX_ADDITIONAL_TAGS) $(BUILDX_BUILD_ARGS) -f Dockerfile.cross .
	docker buildx rm project-v4-builder
	rm Dockerfile.cross

clean: ## Cleans all the intermediate files and folders previously generated.
	rm -rf $(REPO_ROOT)/out

##@ Deployment

.PHONY: verify-kubeconfig
verify-kubeconfig:
	@kubectl get pods >/dev/null 2>&1 || (echo "Please verify that you have an active, running cluster and that KUBECONFIG is pointing to it." && exit 1)

.PHONY: install
install: verify-kubeconfig gen-manifests ## Install CRDs into an existing cluster.
	kubectl create ns ${NAMESPACE} || echo "namespace ${NAMESPACE} already exists"
	kubectl apply --server-side=true -f chart/crds

.PHONY: uninstall
uninstall: verify-kubeconfig ## Uninstall CRDs from an existing cluster.
	kubectl delete --ignore-not-found -f chart/crds

.PHONY: helm-package
helm-package: helm operator-chart ## Package the helm chart.
	$(HELM) package chart --destination $(REPO_ROOT)/out

# optional flags for 'gh release create' cmd
GH_RELEASE_ADDITIONAL_FLAGS =
# set to true to label the GH release as non-production ready
GH_PRE_RELEASE ?= false
ifeq ($(GH_PRE_RELEASE),true)
GH_RELEASE_ADDITIONAL_FLAGS += --prerelease
endif

# create a draft by default to avoid creating real GH release by accident
GH_RELEASE_DRAFT ?= true
ifeq ($(GH_RELEASE_DRAFT),true)
GH_RELEASE_ADDITIONAL_FLAGS += --draft
endif

.PHONY: create-gh-release
create-gh-release: helm-package ## Create a GitHub release and upload the helm charts package to it.
	export GITHUB_TOKEN=$(GITHUB_TOKEN)
	gh release create $(VERSION) $(REPO_ROOT)/out/sail-operator-$(VERSION).tgz \
		--target release-$(MINOR_VERSION) \
		--title "Sail Operator $(VERSION)" \
		--generate-notes \
		$(GH_RELEASE_ADDITIONAL_FLAGS)

.PHONY: cluster
cluster: SKIP_CLEANUP=true
cluster: ## Creates a KinD cluster(s) to use in local deployments.
	source ${SOURCE_DIR}/tests/e2e/setup/setup-kind.sh; \
	export HUB="$${KIND_REGISTRY}"; \
	OCP=false ${SOURCE_DIR}/tests/e2e/setup/build-and-push-operator.sh

.PHONY: deploy
deploy: verify-kubeconfig helm ## Deploy controller to an existing cluster.
	$(info NAMESPACE: $(NAMESPACE))
	kubectl create ns ${NAMESPACE} || echo "namespace ${NAMESPACE} already exists"
	$(HELM) template chart chart $(HELM_TEMPL_DEF_FLAGS) --set image='$(IMAGE)' --namespace $(NAMESPACE) | kubectl apply --server-side=true -f -

.PHONY: deploy-yaml
deploy-yaml: helm ## Output YAML manifests used by `deploy`.
	$(HELM) template chart chart $(HELM_TEMPL_DEF_FLAGS) --set image='$(IMAGE)' --namespace $(NAMESPACE)

.PHONY: deploy-openshift # TODO: remove this target and use deploy-olm instead (when we fix the internal registry TLS issues when using operator-sdk run bundle)
deploy-openshift: verify-kubeconfig helm ## Deploy controller to an existing OCP cluster.
	$(info NAMESPACE: $(NAMESPACE))
	kubectl create ns ${NAMESPACE} || echo "namespace ${NAMESPACE} already exists"
	$(HELM) template chart chart $(HELM_TEMPL_DEF_FLAGS) --set image='$(IMAGE)' --namespace $(NAMESPACE) --set platform="openshift" | kubectl apply --server-side=true -f -

.PHONY: deploy-yaml-openshift
deploy-yaml-openshift: helm ## Output YAML manifests used by `deploy-openshift`.
	$(HELM) template chart chart $(HELM_TEMPL_DEF_FLAGS) --set image='$(IMAGE)' --namespace $(NAMESPACE) --set platform="openshift"

.PHONY: deploy-olm
deploy-olm: verify-kubeconfig bundle bundle-build bundle-push ## Build and push the operator OLM bundle and deploy the operator using OLM.
	kubectl create ns ${NAMESPACE} || echo "namespace ${NAMESPACE} already exists"
	$(OPERATOR_SDK) run bundle $(BUNDLE_IMG) -n ${NAMESPACE} --skip-tls

.PHONY: undeploy
undeploy: verify-kubeconfig ## Undeploy controller from an existing cluster.
	kubectl delete istios.sailoperator.io --all --all-namespaces --wait=true
	kubectl delete istiocni.sailoperator.io --all --all-namespaces --wait=true
	kubectl delete ztunnel.sailoperator.io --all --all-namespaces --wait=true
	$(MAKE) -e HELM_TEMPL_DEF_FLAGS="$(HELM_TEMPL_DEF_FLAGS)" deploy-yaml | kubectl delete --ignore-not-found -f -
	kubectl delete ns ${NAMESPACE} --ignore-not-found
	$(HELM) template chart chart $(HELM_TEMPL_DEF_FLAGS) --set image='$(IMAGE)' --namespace $(NAMESPACE) | kubectl delete --ignore-not-found -f -

.PHONY: undeploy-olm
undeploy-olm: verify-kubeconfig operator-sdk ## Undeploy the operator from an existing cluster (used only if operator was installed via OLM).
	kubectl delete istios.sailoperator.io --all --all-namespaces --wait=true
	kubectl delete istiocni.sailoperator.io --all --all-namespaces --wait=true
	kubectl delete ztunnel.sailoperator.io --all --all-namespaces --wait=true
	$(OPERATOR_SDK) cleanup $(OPERATOR_NAME) --delete-all -n ${NAMESPACE}

.PHONY: deploy-istio
deploy-istio: verify-kubeconfig ## Deploy a sample Istio resource (without CNI) to an existing cluster.
	kubectl create ns istio-system || echo "namespace istio-system already exists"
	kubectl apply -f chart/samples/istio-sample.yaml

.PHONY: deploy-istio-with-cni
deploy-istio-with-cni: verify-kubeconfig ## Deploy a sample Istio and IstioCNI resource to an existing cluster.
	kubectl create ns istio-cni || echo "namespace istio-cni already exists"
	kubectl apply -f chart/samples/istiocni-sample.yaml
	kubectl create ns istio-system || echo "namespace istio-system already exists"
	kubectl apply -f chart/samples/istio-sample.yaml

.PHONY: deploy-istio-with-ambient
deploy-istio-with-ambient: verify-kubeconfig ## Deploy necessary Istio resources using the ambient profile.
	kubectl create ns istio-system || echo "namespace istio-system already exists"
	kubectl apply -f chart/samples/ambient/istio-sample.yaml
	kubectl create ns istio-cni || echo "namespace istio-cni already exists"
	kubectl apply -f chart/samples/ambient/istiocni-sample.yaml
	kubectl create ns ztunnel || echo "namespace zunnel already exists"
	kubectl apply -f chart/samples/ambient/istioztunnel-sample.yaml

##@ Generated Code & Resources

.PHONY: gen-manifests
gen-manifests: controller-gen ## Generate WebhookConfiguration and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) crd:allowDangerousTypes=true webhook paths="./..." output:crd:artifacts:config=chart/crds

.PHONY: gen-api
gen-api: tidy-go ## Generate API types from upstream files.
	echo Generating API types from upstream files
	go run hack/api_transformer/main.go hack/api_transformer/transform.yaml

.PHONY: gen-code
gen-code: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="common/scripts/copyright-banner-go.txt" paths="./..."

export FORCE_DOWNLOADS
.PHONY: download-istio-charts
download-istio-charts: ## Pull charts from istio repository.
	@# use yq to generate a list of download-charts.sh commands for each version in versions.yaml; these commands are
	@# passed to sh and executed; in a nutshell, the yq command generates commands like:
	@# ./hack/download-charts.sh <version> <git repo> <commit> [chart1] [chart2] ...
	@yq eval '.versions[] | select(.ref == null) | select(.eol != true) | "./hack/download-charts.sh " + .name + " " + .version + " " + .repo + " " + .commit + " " + ((.charts // []) | join(" "))' < $(VERSIONS_YAML_DIR)/$(VERSIONS_YAML_FILE) | sh -e

.PHONY: gen-charts
gen-charts: download-istio-charts
	@# remove old version directories
	@hack/remove-old-versions.sh

	@# find the profiles used in the downloaded charts and update list of available profiles
	@hack/update-profiles-list.sh

	@# update the urn:alm:descriptor:com.tectonic.ui:select entries in istio_types.go to match the supported versions of the Helm charts
	@hack/update-version-list.sh

	@# extract the Istio CRD YAMLs from the istio.io/istio dependency in go.mod into ./chart/crds
	@hack/extract-istio-crds.sh

.PHONY: gen
gen: gen-all-except-bundle bundle ## Generate everything.

.PHONY: gen-all-except-bundle
gen-all-except-bundle: operator-name operator-chart controller-gen gen-api gen-charts gen-manifests gen-code gen-api-docs github-workflow mirror-licenses

.PHONY: gen-check
gen-check: gen restore-manifest-dates check-clean-repo ## Verify that changes in generated resources have been checked in.

.PHONY: gen-api-docs
CRD_PATH := ./api
OUTPUT_DOCS_PATH := ./docs/api-reference
CONFIG_API_DOCS_GEN_PATH := ./hack/api-docs/config.yaml
DOCS_RENDERER := markdown
TEMPLATES_DIR := ./hack/api-docs/templates/$(DOCS_RENDERER)

gen-api-docs: ## Generate API documentation. Known issues: go fmt does not properly handle tabs and add new line empty. Workaround is applied to the generated markdown files. The crd-ref-docs tool add br tags to the generated markdown files. Workaround is applied to the generated markdown files.
	@echo "Generating API documentation..."
	@echo "CRD_PATH: $(CRD_PATH)"
	mkdir -p $(OUTPUT_DOCS_PATH)
	go run github.com/elastic/crd-ref-docs \
		--source-path=$(CRD_PATH) \
		--templates-dir=$(TEMPLATES_DIR) \
		--config=$(CONFIG_API_DOCS_GEN_PATH) \
		--renderer=$(DOCS_RENDERER) \
		--output-path=$(OUTPUT_DOCS_PATH)/sailoperator.io.md \
		--output-mode=single
	@find $(OUTPUT_DOCS_PATH) -type f -name "*.md" -exec sed -i 's/<br \/>/ /g' {} \;
	@find $(OUTPUT_DOCS_PATH) -type f \( -name "*.md" -o -name "*.asciidoc" \) -exec sed -i 's/\t/  /g' {} \;
	@find $(OUTPUT_DOCS_PATH) -type f \( -name "*.md" -o -name "*.asciidoc" \) -exec sed -i '/^```/,/^```/ {/./!d;}' {} \;
	@echo "API reference documentation generated at $(OUTPUT_DOCS_PATH)"

.PHONY: restore-manifest-dates
restore-manifest-dates:
ifneq "${BUNDLE_MANIFEST_DATE}" ""
	@sed -i -e "s/\(createdAt:\).*/\1 \"${BUNDLE_MANIFEST_DATE}\"/" bundle/manifests/${OPERATOR_NAME}.clusterserviceversion.yaml
endif

.PHONY: operator-name
operator-name:
	sed -i "s/\(projectName:\).*/\1 ${OPERATOR_NAME}/g" PROJECT

.PHONY: operator-chart
operator-chart: download-istio-charts # pull the charts first as they are required by patch-values.sh
	sed -i -e "s/^\(version: \).*$$/\1${VERSION}/g" \
	       -e "s/^\(appVersion: \).*$$/\1\"${VERSION}\"/g" chart/Chart.yaml
	sed -i -e "s|^\(image: \).*$$|\1${IMAGE}|g" \
	       -e "s/^\(  version: \).*$$/\1${VERSION}/g" chart/values.yaml
	# adding all component images to values
	# when building the bundle, helm generated base CSV is passed to the operator-sdk. With USE_IMAGE_DIGESTS=true, operator-sdk replaces all pullspecs with tags by digests and adds spec.relatedImages field automatically
	@hack/patch-values.sh chart/values.yaml

.PHONY: alauda-update-values
alauda-update-values: VERSIONS_YAML_FILE := alauda-versions.yaml
alauda-update-values: download-istio-charts # pull the charts first as they are required by patch-values.sh
	sed -i -e "s/^\(version: \).*$$/\1${VERSION}/g" \
	       -e "s/^\(appVersion: \).*$$/\1\"${VERSION}\"/g" chart/Chart.yaml
	sed -i -e "s|^\(image: \).*$$|\1${IMAGE}|g" \
	       -e "s/^\(  version: \).*$$/\1${VERSION}/g" chart/values.yaml
	# adding all component images to values
	# when building the bundle, helm generated base CSV is passed to the operator-sdk. With USE_IMAGE_DIGESTS=true, operator-sdk replaces all pullspecs with tags by digests and adds spec.relatedImages field automatically
	@hack/patch-values.sh ${HELM_VALUES_FILE}

.PHONY: github-workflow
github-workflow:
	sed -i -e '1,/default:/ s/^\(.*default:\).*$$/\1 ${CHANNELS}/' .github/workflows/alauda-release.yaml

.PHONY: update-istio
update-istio: ## Update the Istio commit hash in the 'latest' entry in versions.yaml to the latest commit in the branch.
	@hack/update-istio.sh

.PHONY: print-variables
print-variables: ## Print all Makefile variables; Useful to inspect overrides of variables.
	$(foreach v,                                        \
  $(filter-out $(OLD_VARS) OLD_VARS,$(.VARIABLES)), \
  $(info $(v) = $($(v))))
	@echo

##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
OPERATOR_SDK ?= $(LOCALBIN)/operator-sdk
HELM ?= $(LOCALBIN)/helm
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GITLEAKS ?= $(LOCALBIN)/gitleaks
OPM ?= $(LOCALBIN)/opm
ISTIOCTL ?= $(LOCALBIN)/istioctl
RUNME ?= $(LOCALBIN)/runme
MISSPELL ?= $(LOCALBIN)/misspell

## Tool Versions
OPERATOR_SDK_VERSION ?= v1.41.1
HELM_VERSION ?= v3.18.4
CONTROLLER_TOOLS_VERSION ?= v0.18.0
CONTROLLER_RUNTIME_BRANCH ?= release-0.21
OPM_VERSION ?= v1.56.0
OLM_VERSION ?= v0.32.0
GITLEAKS_VERSION ?= v8.28.0
ISTIOCTL_VERSION ?= 1.26.0
RUNME_VERSION ?= 3.15.0
MISSPELL_VERSION ?= v0.3.4

.PHONY: helm $(HELM)
helm: $(HELM) ## Download helm to bin directory. If wrong version is installed, it will be overwritten.
$(HELM): $(LOCALBIN)
	@if test -x $(LOCALBIN)/helm && ! $(LOCALBIN)/helm version | grep -q $(shell v='$(HELM_VERSION)'; echo "$${v%.*}") > /dev/stderr; then \
		echo "$(LOCALBIN)/helm version is not expected $(HELM_VERSION). Removing it before installing." > /dev/stderr; \
		rm -rf $(LOCALBIN)/helm; \
	fi
	@test -s $(LOCALBIN)/helm || GOBIN=$(LOCALBIN) GO111MODULE=on go install helm.sh/helm/v3/cmd/helm@$(HELM_VERSION) > /dev/stderr
.PHONY: operator-sdk $(OPERATOR_SDK)
operator-sdk: $(OPERATOR_SDK)
operator-sdk: OS=$(shell go env GOOS)
operator-sdk: ARCH=$(shell go env GOARCH)
$(OPERATOR_SDK): $(LOCALBIN)
	@if test -x $(LOCALBIN)/operator-sdk && ! $(LOCALBIN)/operator-sdk version | grep -q $(OPERATOR_SDK_VERSION); then \
		echo "$(LOCALBIN)/operator-sdk version is not expected $(OPERATOR_SDK_VERSION). Removing it before installing."; \
		rm -rf $(LOCALBIN)/operator-sdk; \
	fi
	@test -s $(LOCALBIN)/operator-sdk || \
	curl -sSLfo $(LOCALBIN)/operator-sdk https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$(OS)_$(ARCH) && \
	chmod +x $(LOCALBIN)/operator-sdk;

# ISTIOCTL_DOWNLOAD_URL defines the url where istioctl will be downloaded
# By default, it is not set and it uses the istio/istio release download artifact
ISTIOCTL_DOWNLOAD_URL ?= 

.PHONY: istioctl $(ISTIOCTL)
istioctl: $(ISTIOCTL) ## Download istioctl to bin directory.
istioctl: TARGET_OS=$(shell go env GOOS)
istioctl: TARGET_ARCH=$(shell go env GOARCH)
$(ISTIOCTL): $(LOCALBIN)
	@test -s $(LOCALBIN)/istioctl || { \
		OSEXT=$(if $(filter $(TARGET_OS),Darwin),osx,linux); \
		URL=$(if $(value ISTIOCTL_DOWNLOAD_URL),$(ISTIOCTL_DOWNLOAD_URL),"https://github.com/istio/istio/releases/download/$(ISTIOCTL_VERSION)/istioctl-$(ISTIOCTL_VERSION)-$$OSEXT-$(TARGET_ARCH).tar.gz"); \
		echo "Fetching istioctl from $$URL"; \
		curl -fsL $$URL -o /tmp/istioctl.tar.gz || { \
			echo "Download failed! Please check the URL and ISTIO_VERSION."; \
			exit 1; \
		}; \
		tar -xzf /tmp/istioctl.tar.gz -C /tmp || { \
			echo "Extraction failed!"; \
			exit 1; \
		}; \
		mv /tmp/$$(tar tf /tmp/istioctl.tar.gz) $(LOCALBIN)/istioctl; \
		rm -f /tmp/istioctl.tar.gz; \
		echo "istioctl has been downloaded and placed in $(LOCALBIN)"; \
	}

.PHONY: runme $(RUNME)
runme: OS=$(shell go env GOOS)
runme: ARCH=$(shell go env GOARCH)
runme: $(RUNME) ## Download runme to bin directory. If wrong version is installed, it will be overwritten.
	@test -s $(LOCALBIN)/runme || { \
		GOBIN=$(LOCALBIN) GO111MODULE=on go install github.com/runmedev/runme/v3@v$(RUNME_VERSION) > /dev/stderr; \
		echo "runme has been downloaded and placed in $(LOCALBIN)"; \
	}

.PHONY: controller-gen
controller-gen: $(LOCALBIN) ## Download controller-gen to bin directory. If wrong version is installed, it will be overwritten.
	@test -s $(LOCALBIN)/controller-gen && $(LOCALBIN)/controller-gen --version | grep -q $(CONTROLLER_TOOLS_VERSION) || \
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup to bin directory.
$(ENVTEST): $(LOCALBIN)
	@test -s $(LOCALBIN)/setup-envtest || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@$(CONTROLLER_RUNTIME_BRANCH)

.PHONY: gitleaks
gitleaks: $(GITLEAKS) ## Download gitleaks to bin directory.
$(GITLEAKS): $(LOCALBIN)
	@test -s $(LOCALBIN)/gitleaks || GOBIN=$(LOCALBIN) go install github.com/zricethezav/gitleaks/v8@${GITLEAKS_VERSION}

# Openshift Platform flag
# If is set to true will add `--set platform=openshift` to the helm template command
OPENSHIFT_PLATFORM ?= true

.PHONY: bundle
bundle: gen-all-except-bundle helm operator-sdk ## Generate bundle manifests and metadata, then validate generated files.
	@TEMPL_FLAGS="$(HELM_TEMPL_DEF_FLAGS)"; \
	if [ "$(OPENSHIFT_PLATFORM)" = "true" ]; then \
		TEMPL_FLAGS="$$TEMPL_FLAGS --set platform=openshift"; \
	fi; \
	$(HELM) template chart chart $$TEMPL_FLAGS --set image='$(IMAGE)' --set bundleGeneration=true | $(OPERATOR_SDK) generate bundle $(BUNDLE_GEN_FLAGS)

# operator sdk does not generate sorted relatedImages, we need to sort it here
ifeq ($(USE_IMAGE_DIGESTS), true)
	yq -i '.spec.relatedImages |= sort_by(.name)' bundle/manifests/$(OPERATOR_NAME).clusterserviceversion.yaml
else ifeq ($(GENERATE_RELATED_IMAGES), true)
	@hack/alauda-patch-csv.sh bundle/manifests/$(OPERATOR_NAME).clusterserviceversion.yaml ${HELM_VALUES_FILE}
endif
	# update CSV's spec.customresourcedefinitions.owned field. ideally we could do this straight in ./bundle, but
	# sadly this is only possible if the file lives in a `bases` directory
	mkdir -p _tmp/bases
	cp bundle/manifests/$(OPERATOR_NAME).clusterserviceversion.yaml _tmp/bases
	$(OPERATOR_SDK) generate kustomize manifests --input-dir=_tmp --output-dir=_tmp
	mv _tmp/bases/$(OPERATOR_NAME).clusterserviceversion.yaml bundle/manifests/$(OPERATOR_NAME).clusterserviceversion.yaml
	rm -rf _tmp

	# format the CSV using yq to easily process it later via yq if needed without any format changes
	yq -i '.' "bundle/manifests/${OPERATOR_NAME}.clusterserviceversion.yaml"

	# check if the only change in the CSV is the createdAt timestamp; if so, revert the change
	@csvPath="bundle/manifests/${OPERATOR_NAME}.clusterserviceversion.yaml"; \
		if (git ls-files --error-unmatch "$$csvPath" &>/dev/null); then \
			if ! (git diff "$$csvPath" | grep '^[+-][^+-][^+-]' | grep -v "createdAt:" >/dev/null); then \
				echo "reverting timestamp change in $$csvPath"; \
				git checkout "$$csvPath" || echo "failed to revert timestamp change. assuming we're in the middle of a merge"; \
			fi \
		fi

	$(OPERATOR_SDK) bundle validate ./bundle

.PHONY: bundle-build
bundle-build: ## Build the bundle image.
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	docker push $(BUNDLE_IMG)

.PHONY: bundle-publish
bundle-publish: ## Create a PR for publishing in OperatorHub.
	@export GIT_USER=$(GITHUB_USER); \
	export GITHUB_TOKEN=$(GITHUB_TOKEN); \
	export OPERATOR_VERSION=$(VERSION); \
	export OPERATOR_NAME=$(OPERATOR_NAME); \
	export CHANNELS="$(CHANNELS)"; \
	export PREVIOUS_VERSION=$(PREVIOUS_VERSION); \
	./hack/operatorhub/publish-bundle.sh

## Generate nightly bundle.
.PHONY: bundle-nightly
bundle-nightly: VERSION:=$(VERSION)-nightly-$(TODAY)
bundle-nightly: CHANNELS:=$(MINOR_VERSION)-nightly
bundle-nightly: TAG=$(MINOR_VERSION)-nightly-$(TODAY)
bundle-nightly: bundle

## Publish nightly bundle.
.PHONY: bundle-publish-nightly
bundle-publish-nightly: VERSION:=$(VERSION)-nightly-$(TODAY)
bundle-publish-nightly: TAG=$(MINOR_VERSION)-nightly-$(TODAY)
bundle-publish-nightly: CHANNELS:=$(MINOR_VERSION)-nightly
bundle-publish-nightly: bundle-nightly bundle-publish

.PHONY: helm-artifacts-publish
helm-artifacts-publish: helm ## Publish Helm artifacts to be available for "Helm repo add"
	@export GIT_USER=$(GITHUB_USER); \
	export GITHUB_TOKEN=$(GITHUB_TOKEN); \
	./hack/helm-artifacts.sh

.PHONY: opm $(OPM)
opm: $(OPM)
opm: OS=$(shell go env GOOS)
opm: ARCH=$(shell go env GOARCH)
$(OPM): $(LOCALBIN)
	@if test -x $(LOCALBIN)/opm && ! $(LOCALBIN)/opm version | grep -q $(OPM_VERSION); then \
		echo "$(LOCALBIN)/opm version is not expected $(OPM_VERSION). Removing it before installing."; \
		rm -f $(LOCALBIN)/opm; \
	fi
	test -s $(LOCALBIN)/opm || \
	curl -sSLfo $(LOCALBIN)/opm https://github.com/operator-framework/operator-registry/releases/download/$(OPM_VERSION)/$(OS)-$(ARCH)-opm && \
	chmod +x $(LOCALBIN)/opm;

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:v$(VERSION)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool docker --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

# Push the catalog image.
.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMAGE=$(CATALOG_IMG)


##@ Linting

.PHONY: lint-bundle
lint-bundle: operator-sdk ## Run linters against OLM metadata bundle.
	$(OPERATOR_SDK) bundle validate bundle --select-optional suite=operatorframework

.PHONY: lint-watches
lint-watches: ## Checks if the operator watches all resource kinds present in Helm charts.
	@hack/lint-watches.sh

lint-secrets: gitleaks ## Checks whether any secrets are present in the repository.
	@${GITLEAKS} detect --no-git --redact -v

.PHONY: lint-spell ## Run spell checker on the documentation files. Skipping sailoperator.io.md file.
lint-spell: misspell
	@echo "Get misspell from $(LOCALBIN)"
	@echo "Running misspell on the documentation files"
	@find $(REPO_ROOT)/docs -type f \( \( -name "*.md" -o -name "*.asciidoc" \) ! -name "*sailoperator.io.md" \) \
	| xargs $(LOCALBIN)/misspell -error -locale US

.PHONY: misspell
misspell: $(LOCALBIN) ## Download misspell to bin directory.
	@test -s $(LOCALBIN)/misspell || GOBIN=$(LOCALBIN) go install github.com/client9/misspell/cmd/misspell@$(MISSPELL_VERSION)

.PHONY: lint
lint: lint-scripts lint-licenses lint-copyright-banner lint-go lint-yaml lint-helm lint-bundle lint-watches lint-secrets lint-spell ## Run all linters.

.PHONY: format
format: format-go tidy-go ## Auto-format all code. This should be run before sending a PR.

git-hook: gitleaks ## Installs gitleaks as a git pre-commit hook.
	@if ! test -x .git/hooks/pre-commit || ! grep -q "gitleaks" .git/hooks/pre-commit ; then \
		echo "Adding gitleaks to pre-commit hook"; \
		echo "bin/gitleaks protect --staged -v" >> .git/hooks/pre-commit; \
		chmod +x .git/hooks/pre-commit; \
	fi

.SILENT: helm $(HELM) $(LOCALBIN) deploy-yaml gen-api operator-name operator-chart

COMMON_IMPORTS ?= mirror-licenses dump-licenses lint-all lint-licenses lint-scripts lint-copyright-banner lint-go lint-yaml lint-helm format-go tidy-go check-clean-repo update-common
.PHONY: $(COMMON_IMPORTS)
$(COMMON_IMPORTS):
	@$(MAKE) --no-print-directory -f common/Makefile.common.mk $@
