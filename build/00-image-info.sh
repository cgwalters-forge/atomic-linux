#!/usr/bin/bash
# Write /usr/share/ublue-os/image-info.json, which ujust, fastfetch and other
# Universal Blue tooling read to identify the image.
#
# Installed in the image as /usr/libexec/atomic-linux/write-image-info so a
# derived image can record its own identity:
#
#   ARG IMAGE_NAME=my-image IMAGE_VENDOR=me IMAGE_REGISTRY=registry.example.com/me
#   RUN /usr/libexec/atomic-linux/write-image-info
#
# Inputs (environment, normally Containerfile ARGs):
#   IMAGE_NAME            image name (required)
#   IMAGE_VENDOR          owner (required)
#   IMAGE_REGISTRY        registry and namespace (default ghcr.io/IMAGE_VENDOR)
#   UBLUE_IMAGE_TAG       stream tag (default stable)
#   BASE_IMAGE_NAME       base image name (default silverblue)
#   FEDORA_MAJOR_VERSION  Fedora release (default from /usr/lib/os-release)

set -euo pipefail

: "${IMAGE_NAME:?IMAGE_NAME must be set}"
: "${IMAGE_VENDOR:?IMAGE_VENDOR must be set}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/${IMAGE_VENDOR}}"
UBLUE_IMAGE_TAG="${UBLUE_IMAGE_TAG:-stable}"
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-silverblue}"
if [[ -z "${FEDORA_MAJOR_VERSION:-}" ]]; then
	# shellcheck source=/dev/null
	FEDORA_MAJOR_VERSION=$(. /usr/lib/os-release && echo "${VERSION_ID}")
fi

IMAGE_INFO=/usr/share/ublue-os/image-info.json

if [[ "${IMAGE_NAME}" =~ nvidia ]]; then
	IMAGE_FLAVOR=nvidia
else
	IMAGE_FLAVOR=main
fi

# The signed transport records the intended update origin; it only takes
# effect once the host's containers policy requires signatures.
IMAGE_REF="ostree-image-signed:docker://${IMAGE_REGISTRY}/${IMAGE_NAME}"

mkdir -p "$(dirname "${IMAGE_INFO}")"
cat >"${IMAGE_INFO}" <<JSON
{
  "image-name": "${IMAGE_NAME}",
  "image-flavor": "${IMAGE_FLAVOR}",
  "image-vendor": "${IMAGE_VENDOR}",
  "image-ref": "${IMAGE_REF}",
  "image-tag": "${UBLUE_IMAGE_TAG}",
  "base-image-name": "${BASE_IMAGE_NAME}",
  "fedora-version": "${FEDORA_MAJOR_VERSION}"
}
JSON

echo "Wrote ${IMAGE_INFO}: ${IMAGE_VENDOR}/${IMAGE_NAME} (${IMAGE_REF})"
