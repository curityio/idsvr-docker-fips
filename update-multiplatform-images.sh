#!/bin/bash

set -euo pipefail

CONTAINER_REGISTRY="curityfips.azurecr.io"
IMAGE_REPO="curity/idsvr"



SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSIONS_FILE="${SCRIPT_DIR}/versions.yaml"
S3_BUCKET="curity-idsvr-build-artifacts"
S3_PREFIX="release-candidates"
DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"
BUILD_CONTEXT_DIR="${SCRIPT_DIR}/build-context"
TOKEN_ENDPOINT="https://login.curity.io/oauth/v2/token"
RELEASE_API="https://releaseapi.curity.io/releases"
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

docker buildx create --name idsvr-fips --use || docker buildx use idsvr-fips

# Highest stable version in versions.yaml gets the "latest" tag; pre-release
# versions (preview/beta/alpha/rc/hotfix) never do. Empty if no stable version.
# grep exits 1 when everything is filtered out, hence the || true (pipefail).
LATEST_VERSION=$(yq -r '.versions[].version' "${VERSIONS_FILE}" | { grep -vEi 'preview|beta|alpha|rc|hotfix' || true; } | sort -V | tail -1)

# The MAJOR.MINOR.x and MAJOR.MINOR.y tags are ambiguous if two entries share
# the same MAJOR.MINOR, so refuse to run in that case.
DUPLICATE_MINORS=$(yq -r '.versions[].version' "${VERSIONS_FILE}" | cut -d. -f1,2 | sort | uniq -d)
if [[ -n "${DUPLICATE_MINORS}" ]]; then
  echo "error: multiple versions in $(basename "${VERSIONS_FILE}") share the same MAJOR.MINOR: ${DUPLICATE_MINORS}" >&2
  echo "keep only the latest patch version of each MAJOR.MINOR" >&2
  exit 1
fi

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

get_release_api_token() {
  [[ -z "${CLIENT_ID:-}" ]] && { echo "error: CLIENT_ID not set (required to download hotfixes)" >&2; exit 1; }
  [[ -z "${CLIENT_SECRET:-}" ]] && { echo "error: CLIENT_SECRET not set (required to download hotfixes)" >&2; exit 1; }
  local token
  token=$(curl -f -s -S -d "grant_type=client_credentials&client_secret=${CLIENT_SECRET}&client_id=${CLIENT_ID}&scope=release_download release_read" "${TOKEN_ENDPOINT}" | jq -r '.access_token')
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    echo "error: failed to get access token for the release API" >&2
    exit 1
  fi
  echo "${token}"
}

# Hotfixes are not in S3; they are fetched from the release API, same as in idsvr-docker.
download_hotfix_if_missing() {
  local version="$1"
  local hotfix_path="$2"
  local local_path="$3"
  if [[ -f "${local_path}" ]]; then
    echo "skip download: $(basename "${local_path}") already cached"
    return 0
  fi
  echo "downloading hotfix: ${hotfix_path} for ${version}"
  local token
  token=$(get_release_api_token)
  curl -f -s -S -H "Authorization: Bearer ${token}" "${RELEASE_API}/${version}/${hotfix_path}/file" -o "${local_path}.part"
  mv "${local_path}.part" "${local_path}"
}

# Removes each hotfix's originalFiles from the extracted release, then unpacks the hotfix over it.
apply_hotfixes() {
  local target_dir="$1"
  local version="$2"
  local hotfixes="$3"
  local count i hotfix_path original_file
  count=$(jq 'length' <<<"${hotfixes}")
  for ((i = 0; i < count; i++)); do
    hotfix_path=$(jq -r ".[${i}].path" <<<"${hotfixes}")
    echo "applying hotfix ${hotfix_path} -> $(basename "${target_dir}")"
    while IFS= read -r original_file; do
      if [[ ! -f "${target_dir}/${original_file}" ]]; then
        echo "error: hotfix ${hotfix_path} expects ${original_file}, but it is not in the release" >&2
        exit 1
      fi
      rm -f "${target_dir}/${original_file}"
    done < <(jq -r ".[${i}].originalFiles // [] | .[]" <<<"${hotfixes}")
    tar -xzf "${DOWNLOAD_DIR}/${hotfix_path}-${version}.tgz" --exclude='*.md' -C "${target_dir}"
  done
}

# Target dir name matches `idsvr-${VERSION}-${COMMIT}-${TARGETARCH}` in the Dockerfile's COPY.
extract_into() {
  local tgz="$1"
  local target_dir="$2"
  local version="$3"
  local hotfixes="$4"
  if [[ -d "${target_dir}" ]]; then
    echo "skip extract: $(basename "${target_dir}") already extracted"
    return 0
  fi
  echo "extracting $(basename "${tgz}") -> $(basename "${target_dir}")"
  # Work in a staging dir so a failure (e.g. while hotfixing) never leaves a
  # half-prepared target_dir that a later run would skip as "already extracted".
  local staging_dir="${target_dir}.partial"
  rm -rf "${staging_dir}"
  mkdir -p "${staging_dir}"
  tar -xzf "${tgz}" -C "${staging_dir}" --strip-components 1
  apply_hotfixes "${staging_dir}" "${version}" "${hotfixes}"

  # Lock down permissions before COPY into the image (mode bits are preserved by docker COPY).
  find "${staging_dir}/idsvr" -type f -exec chmod a-w {} \;
  chmod -R o-rwx "${staging_dir}/idsvr"
  chmod -R g+rX "${staging_dir}/idsvr"
  mv "${staging_dir}" "${target_dir}"
}

yq -o=json '.' "${VERSIONS_FILE}" | jq -c '.versions[]' | while read -r entry; do
  version=$(jq -r '.version' <<<"${entry}")
  commit=$(jq -r '.commit' <<<"${entry}")
  x86_build=$(jq -r '.builds["linux-x86"]' <<<"${entry}")
  arm_build=$(jq -r '.builds["linux-arm"]' <<<"${entry}")
  hotfixes=$(jq -c '.hotfixes // []' <<<"${entry}")

  TAG="${IMAGE_BASE}:${version}"

  # Additional tags: MAJOR.MINOR, VERSION-ubuntu22, and "latest" for the newest version
  major_minor=$(cut -d. -f1,2 <<<"${version}")
  TAG_ARGS=(-t "${TAG}" -t "${IMAGE_BASE}:${major_minor}" -t "${IMAGE_BASE}:${version}-ubuntu22")
  if [[ "${version}" == "${LATEST_VERSION}" ]]; then
    TAG_ARGS+=(-t "${IMAGE_BASE}:latest")
  fi

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
    while IFS= read -r hotfix_path; do
      download_hotfix_if_missing "${version}" "${hotfix_path}" "${DOWNLOAD_DIR}/${hotfix_path}-${version}.tgz"
    done < <(jq -r '.[].path' <<<"${hotfixes}")

    # Per-version context so buildx only sees this version's extracted artifacts.
    version_ctx="${BUILD_CONTEXT_DIR}/${version}"
    mkdir -p "${version_ctx}"
    extract_into "${DOWNLOAD_DIR}/${x86_file}" "${version_ctx}/idsvr-${version}-${commit}-amd64" "${version}" "${hotfixes}"
    extract_into "${DOWNLOAD_DIR}/${arm_file}" "${version_ctx}/idsvr-${version}-${commit}-arm64" "${version}" "${hotfixes}"

    if [[ -n "${PUSH_IMAGES}" ]]; then PUSH="--push"; else PUSH=""; fi
    echo "Running docker buildx for tags: ${TAG_ARGS[*]} with --platform linux/amd64,linux/arm64 ${PUSH}"
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
      "${TAG_ARGS[@]}" \
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

  # Remove local idsvr images by repo:tag; lists nothing (exit 0) when none exist
  docker images --format '{{.Repository}}:{{.Tag}}' "${IMAGE_BASE}" | xargs -r docker rmi
done

# Delete stopped containers and images
docker buildx stop idsvr-fips && docker buildx rm idsvr-fips
docker rm $(docker ps --filter status=exited -q) 2>/dev/null || true
docker image prune -af
