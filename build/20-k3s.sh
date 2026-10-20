#!/usr/bin/bash
# Install a checksum-pinned k3s release and its SELinux policy. k3s is left
# disabled: a derived image enables k3s.service and adds its own
# /etc/rancher/k3s/config.yaml.d/ drop-ins (see README.md).

set -euo pipefail

K3S_VERSION='v1.36.4+k3s1'
K3S_BINARY_SHA256='835873f37245fc615f547a2fe2af9402a347875f13fa64a1f136de644955ea3f'
K3S_SELINUX_VERSION='v1.6.latest.1'
K3S_SELINUX_RPM='k3s-selinux-1.6-1.coreos.noarch.rpm'
K3S_SELINUX_SHA256='ff171703f71f8c2c987342267d674a9ee3b86bb2e5d4c7cbd4a3a4be3be386d3'
K3S_RELEASE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}"
K3S_SELINUX_URL="https://github.com/k3s-io/k3s-selinux/releases/download/${K3S_SELINUX_VERSION}/${K3S_SELINUX_RPM}"

cleanup() {
    rm -rf "${workdir}"
}

workdir=$(mktemp -d)
trap cleanup EXIT

dnf5 install -y \
    container-selinux \
    curl \
    firewalld \
    iproute \
    iptables-nft \
    jq \
    kmod \
    policycoreutils-python-utils

curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors \
    --connect-timeout 20 --output "${workdir}/k3s" "${K3S_RELEASE_URL}/k3s"
printf '%s  %s\n' "${K3S_BINARY_SHA256}" "${workdir}/k3s" | sha256sum --check --status

curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors \
    --connect-timeout 20 --output "${workdir}/${K3S_SELINUX_RPM}" "${K3S_SELINUX_URL}"
printf '%s  %s\n' "${K3S_SELINUX_SHA256}" "${workdir}/${K3S_SELINUX_RPM}" | sha256sum --check --status

install --mode=0755 "${workdir}/k3s" /usr/bin/k3s
dnf5 install -y "${workdir}/${K3S_SELINUX_RPM}"
install -d /var/lib/rancher/k3s
restorecon -RFv /usr/bin/k3s /usr/lib/systemd/system/k3s.service /var/lib/rancher/k3s
systemctl enable firewalld.service
