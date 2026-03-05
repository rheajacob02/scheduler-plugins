#!/usr/bin/env bash

# Copyright 2023 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_ROOT=$(realpath $(dirname "${BASH_SOURCE[@]}")/..)

SCHEDULER_DIR="${SCRIPT_ROOT}"/build/scheduler
CONTROLLER_DIR="${SCRIPT_ROOT}"/build/controller

# -t is the Docker engine default
TAG_FLAG="-t"

# If docker is not present, fall back to nerdctl
# TODO: nerdctl doesn't seem to have buildx.
if ! command -v ${BUILDER} && command -v nerdctl >/dev/null; then
  BUILDER=nerdctl
fi

# podman needs the manifest flag in order to create a single image.
if [[ "${BUILDER}" == "podman" ]]; then
  TAG_FLAG="--manifest"
fi

cd "${SCRIPT_ROOT}"

# For local builds (v0.0.0), use plain "docker build" so we don't require buildx or --platform
# (many Docker installs use the legacy builder which doesn't support --platform).
if [[ "${RELEASE_VERSION}" == "v0.0.0" ]]; then
  # Set TARGETARCH so the Dockerfile's RUN step builds for the current machine (legacy builder doesn't set it).
  case "$(uname -m)" in
    x86_64) TARGETARCH=amd64 ;;
    aarch64|arm64) TARGETARCH=arm64 ;;
    *) TARGETARCH=amd64 ;;
  esac
  ${BUILDER} build \
    -f ${SCHEDULER_DIR}/Dockerfile \
    --build-arg RELEASE_VERSION=${RELEASE_VERSION} \
    --build-arg GO_BASE_IMAGE=${GO_BASE_IMAGE} \
    --build-arg DISTROLESS_BASE_IMAGE=${DISTROLESS_BASE_IMAGE} \
    --build-arg TARGETARCH=${TARGETARCH} \
    --build-arg CGO_ENABLED=0 \
    -t ${REGISTRY}/${IMAGE} .
  ${BUILDER} build \
    -f ${CONTROLLER_DIR}/Dockerfile \
    --build-arg RELEASE_VERSION=${RELEASE_VERSION} \
    --build-arg GO_BASE_IMAGE=${GO_BASE_IMAGE} \
    --build-arg DISTROLESS_BASE_IMAGE=${DISTROLESS_BASE_IMAGE} \
    --build-arg TARGETARCH=${TARGETARCH} \
    --build-arg CGO_ENABLED=0 \
    -t ${REGISTRY}/${CONTROLLER_IMAGE} .
else
  IMAGE_BUILD_CMD=${DOCKER_BUILDX_CMD:-${BUILDER} buildx}
  BLD_INSTANCE=""
  BLD_INSTANCE=$($IMAGE_BUILD_CMD create --use 2>/dev/null) || true

  ${IMAGE_BUILD_CMD} build \
    --platform=${PLATFORMS} \
    -f ${SCHEDULER_DIR}/Dockerfile \
    --build-arg RELEASE_VERSION=${RELEASE_VERSION} \
    --build-arg GO_BASE_IMAGE=${GO_BASE_IMAGE} \
    --build-arg DISTROLESS_BASE_IMAGE=${DISTROLESS_BASE_IMAGE} \
    --build-arg CGO_ENABLED=0 \
    ${EXTRA_ARGS:-} ${TAG_FLAG:-} ${REGISTRY}/${IMAGE} .

  ${IMAGE_BUILD_CMD} build \
    --platform=${PLATFORMS} \
    -f ${CONTROLLER_DIR}/Dockerfile \
    --build-arg RELEASE_VERSION=${RELEASE_VERSION} \
    --build-arg GO_BASE_IMAGE=${GO_BASE_IMAGE} \
    --build-arg DISTROLESS_BASE_IMAGE=${DISTROLESS_BASE_IMAGE} \
    --build-arg CGO_ENABLED=0 \
    ${EXTRA_ARGS:-} ${TAG_FLAG:-} ${REGISTRY}/${CONTROLLER_IMAGE} .

  if [[ -n "${BLD_INSTANCE}" ]]; then
    ${DOCKER_BUILDX_CMD:-${BUILDER} buildx} rm "${BLD_INSTANCE}" 2>/dev/null || true
  fi
fi
