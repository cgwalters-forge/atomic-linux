#!/usr/bin/bash
# Runs inside a `bcvk ephemeral` VM; `just ephemeral-smoke` passes it in
# base64 so no quoting survives several shells. Expects EXPECT_IMAGE_NAME
# and EXPECT_TAG.

set -euo pipefail

: "${EXPECT_IMAGE_NAME:?}" "${EXPECT_TAG:?}"
info=/usr/share/ublue-os/image-info.json

for _ in $(seq 1 60); do
    systemctl is-active --quiet NetworkManager && break
    sleep 2
done
systemctl is-active NetworkManager
test "$(jq -r '."image-name"' "${info}")" = "${EXPECT_IMAGE_NAME}"
test "$(jq -r '."image-tag"' "${info}")" = "${EXPECT_TAG}"
bootc status
test "$(systemctl get-default)" = graphical.target
command -v tmux gum k3s
test "$(systemctl is-enabled k3s.service || true)" = disabled
systemctl is-active firewalld
getent hosts fedoraproject.org
curl --fail --silent --show-error --head https://fedoraproject.org >/dev/null
echo "ephemeral smoke passed"
