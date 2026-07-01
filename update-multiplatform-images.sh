#!/bin/bash

set -euo pipefail

#todo change to new private repo
CONTAINER_REGISTRY="curity.azurecr.io"
IMAGE_REPO="curity/idsvr-fips"



SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSIONS_FILE="${SCRIPT_DIR}/versions.yaml"
S3_BUCKET="curity-idsvr-build-artifacts"
S3_PREFIX="11.3.1" #todo change to release-candidates
DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"
BUILD_CONTEXT_DIR="${SCRIPT_DIR}/build-context"
IMAGE_BASE="${CONTAINER_REGISTRY}/${IMAGE_REPO}"
UBUNTU_22=ubuntu:22.04

PUSH_IMAGES="${PUSH_IMAGES:-}"
FORCE_UPDATE_VERSION="${FORCE_UPDATE_VERSION:-}"

for cmd in aws yq jq docker tar; do
  command -v "${cmd}" >/dev/null || { echo "error: ${cmd} not found in PATH" >&2; exit 1; }
done

# Pull x86 base images once to avoid pull limit in dockerhub
docker pull "$UBUNTU_22" --platform linux/amd64
UBUNTU_X86_LAST_LAYER_ID=$(docker inspect "${UBUNTU_22}" | jq ".[0].RootFS.Layers[-1]")

# Pull ARM base images once to avoid pull limit in dockerhub
docker pull "$UBUNTU_22" --platform linux/arm64
UBUNTU_ARM_LAST_LAYER_ID=$(docker inspect "${UBUNTU_22}" | jq ".[0].RootFS.Layers[-1]")

docker buildx create --name idsvr-fips || docker buildx use idsvr-fips
docker buildx inspect --bootstrap

mkdir -p "${DOWNLOAD_DIR}" "${BUILD_CONTEXT_DIR}"

download_if_missing() {
  local s3_url="$1"
  local local_path="$2"
  if [[ -f "${local_path}" ]]; then
    echo "skip download: $(basename "${local_path}") already cached"
    return 0
  fi
  echo "downloading: ${s3_url}"
  aws s3 cp "${s3_url}" "${local_path}"
}

# Target dir name matches `idsvr-${VERSION}-${COMMIT}-${TARGETARCH}` in the Dockerfile's COPY.
extract_into() {
  local tgz="$1"
  local target_dir="$2"
  if [[ -d "${target_dir}" ]]; then
    echo "skip extract: $(basename "${target_dir}") already extracted"
    return 0
  fi
  echo "extracting $(basename "${tgz}") -> $(basename "${target_dir}")"
  mkdir -p "${target_dir}"
  tar -xzf "${tgz}" -C "${target_dir}" --strip-components 1

  # Lock down permissions before COPY into the image (mode bits are preserved by docker COPY).
  find "${target_dir}/idsvr" -type f -exec chmod a-w {} \;
  chmod -R o-rwx "${target_dir}/idsvr"
  chmod -R g+rX "${target_dir}/idsvr"
}

yq -o=json '.' "${VERSIONS_FILE}" | jq -c '.versions[]' | while read -r entry; do
  version=$(jq -r '.version' <<<"${entry}")
  commit=$(jq -r '.commit' <<<"${entry}")
  x86_build=$(jq -r '.builds["linux-x86"]' <<<"${entry}")
  arm_build=$(jq -r '.builds["linux-arm"]' <<<"${entry}")

  TAG="${IMAGE_BASE}:${version}"

  x86_file="idsvr-fips-${version}-${commit}-linux-${x86_build}.tgz"
  arm_file="idsvr-fips-${version}-${commit}-linux-${arm_build}-aarch64.tgz"

  docker pull "$TAG" --platform linux/amd64 || true
  X86_IMAGE_INSPECT=$(docker inspect "$TAG" || true)

  docker pull "$TAG" --platform linux/arm64 || true
  ARM_IMAGE_INSPECT=$(docker inspect "$TAG" || true)

  if [[ "${X86_IMAGE_INSPECT}" != *"${UBUNTU_X86_LAST_LAYER_ID}"* ]] \
     || [[ "${ARM_IMAGE_INSPECT}" != *"${UBUNTU_ARM_LAST_LAYER_ID}"* ]] \
     || [[ "${FORCE_UPDATE_VERSION}" == *"${version}"* ]]; then

    echo "=== ${version} (${commit}) ==="

    download_if_missing "s3://${S3_BUCKET}/${S3_PREFIX}/${x86_file}" "${DOWNLOAD_DIR}/${x86_file}"
    download_if_missing "s3://${S3_BUCKET}/${S3_PREFIX}/${arm_file}" "${DOWNLOAD_DIR}/${arm_file}"

    # Per-version context so buildx only sees this version's extracted artifacts.
    version_ctx="${BUILD_CONTEXT_DIR}/${version}"
    mkdir -p "${version_ctx}"
    extract_into "${DOWNLOAD_DIR}/${x86_file}" "${version_ctx}/idsvr-${version}-${commit}-amd64"
    extract_into "${DOWNLOAD_DIR}/${arm_file}" "${version_ctx}/idsvr-${version}-${commit}-arm64"

    if [[ -n "${PUSH_IMAGES}" ]]; then PUSH="--push"; else PUSH=""; fi
    echo "Running docker buildx for tag: ${TAG} with --platform linux/amd64,linux/arm64 ${PUSH}"
    TOKEN1=$(sudo pro api u.pro.attach.guest.get_guest_token.v1 | jq -r '.data.attributes.guest_token')
    TOKEN2=$(sudo pro api u.pro.attach.guest.get_guest_token.v1 | jq -r '.data.attributes.guest_token')

    PRO_ATTACH_CONFIG_ARM64=$(mktemp)
    trap 'rm -f "${PRO_ATTACH_CONFIG_ARM64}"' EXIT
    cat >"${PRO_ATTACH_CONFIG_ARM64}" <<EOF
token: ${TOKEN1}
enable_services:
  - fips-updates
EOF

    PRO_ATTACH_CONFIG_AMD64=$(mktemp)
    trap 'rm -f "${PRO_ATTACH_CONFIG_AMD64}"' EXIT
    cat >"${PRO_ATTACH_CONFIG_AMD64}" <<EOF
token: ${TOKEN2}
enable_services:
  - fips-updates
EOF

    docker buildx build \
      --pull \
      --platform linux/amd64,linux/arm64 \
      ${PUSH} \
      -t "${TAG}" \
      --build-arg VERSION="${version}" \
      --build-arg COMMIT="${commit}" \
      --secret id=pro-attach-config-amd64,src="${PRO_ATTACH_CONFIG_AMD64}" \
      --secret id=pro-attach-config-arm64,src="${PRO_ATTACH_CONFIG_ARM64}" \
      --build-context=downloads="${version_ctx}" \
      "${SCRIPT_DIR}/docker"

    rm -rf "${version_ctx}"
  else
    echo "${version} is based on the latest base image, skip building"
  fi

  #todo change to new private repo
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep '^curity\.azurecr\.io/curity' | awk '{print $2}' | xargs -r docker rmi
done

# Delete stopped containers and images
docker buildx stop idsvr-fips && docker buildx rm idsvr-fips
docker rm $(docker ps --filter status=exited -q) 2>/dev/null || true
docker image prune -af
