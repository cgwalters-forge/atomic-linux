#!/usr/bin/bash
# Runs only in the fresh outer bcvk VM created by `just kubevirt-test`.

set -euo pipefail

readonly KUBEVIRT_VERSION='v1.9.0'
readonly RELEASE_URL="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"
readonly OPERATOR_SHA256='f11307caafc3c23ffedf9887d8beb5a4419e2694da242fa68f63d1ec820de2e0'
readonly CR_SHA256='43106136dbce3312bdbfdeae612aacafc6c12da518d233f90645b4685d84a2af'
readonly VIRTCTL_SHA256='40ede2ee37c98a1aeed71c9c219616a05247ce2be109e1edddf0477572e8b978'
readonly NAMESPACE='kubevirt-acceptance'
readonly VM='kubevirt-acceptance'
readonly KUBECTL=(k3s kubectl)
readonly -A IMAGE_DIGESTS=(
    [virt-operator]='sha256:d08b5b5ad1c0d694fad13279e44b44b6fad961aa7508acd53b87ce6ef468cbae'
    [virt-api]='sha256:42341b1d52699f4bb87f3996151bafe2e3fe065e9146cc64a15959ddf7bf2c69'
    [virt-controller]='sha256:7c6034ab39b97c0bb2b31bab2aaf576b616a3d6e59777002d63e2f2bf51e73c2'
    [virt-handler]='sha256:df9f2069924a28ba76f47e7f4fbd9a0be3aa13cfa004a59e7a708bbff2a90424'
    [virt-launcher]='sha256:f23102ca00bf12f7962021adfdfdad63c873b01a03001a6d20d5813950254b9c'
    [virt-exportproxy]='sha256:042443b8f58246623e440af59cd34c0627f843b6094c41794d16c98c8d0049ea'
    [virt-template-apiserver]='sha256:af326822d8907ce3c96a6458444f5af0f1e3f912215710eae3fa562c92a3470e'
    [virt-template-controller]='sha256:2cd0770ce24b40d742bd6bac438c55c886352366c90e8165c11b715b7cfd94c7'
)
readonly FEDORA_DISK='quay.io/kubevirt/fedora-cloud-container-disk-demo@sha256:4a0c3f9526551d0294079f1b0171a071a57fe0bf60a2e8529bf4102ee63a67cd'

fixture_dir=${1:?pass the guest fixture directory}
workdir=$(mktemp -d /var/tmp/kubevirt-acceptance.XXXXXX)
private_key="${workdir}/id_ed25519"
cleanup() {
    status=$?
    if ((status != 0)); then
        "${KUBECTL[@]}" -n kubevirt get pods -o json >&2 || true
        "${KUBECTL[@]}" -n "${NAMESPACE}" get all -o wide >&2 || true
    fi
    rm -rf "${workdir}"
    exit "${status}"
}
trap cleanup EXIT

test "${KUBEVIRT_ACCEPTANCE:-}" = 1
test -n "${OUTER_LIBVIRT_UUID:-}"
k3s --version | grep -Fq 'v1.36.4+k3s1'
systemctl is-active --quiet k3s.service
systemd-detect-virt --quiet
test "$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_uuid)" = "${OUTER_LIBVIRT_UUID,,}"
test -r /dev/kvm && test -w /dev/kvm
grep -Eq '(^|[[:space:]])(vmx|svm)([[:space:]]|$)' /proc/cpuinfo
test "$("${KUBECTL[@]}" get nodes --no-headers | wc -l)" = 1
"${KUBECTL[@]}" wait --for=condition=Ready node --all --timeout=60s >/dev/null
if "${KUBECTL[@]}" get namespace kubevirt >/dev/null 2>&1 || "${KUBECTL[@]}" get crd kubevirts.kubevirt.io >/dev/null 2>&1; then
    printf 'Refusing pre-existing KubeVirt state.\n' >&2
    exit 1
fi

download() {
    local file=$1 checksum=$2
    curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors --connect-timeout 20 \
        --output "${workdir}/${file}" "${RELEASE_URL}/${file}"
    printf '%s  %s\n' "${checksum}" "${workdir}/${file}" | sha256sum --check --status
}

wait_for() {
    local description=$1
    shift
    for _ in $(seq 1 180); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    printf 'Timed out waiting for %s\n' "${description}" >&2
    return 1
}

has_service_endpoint() {
    "${KUBECTL[@]}" -n "${NAMESPACE}" get endpoints "${VM}" -o json | jq -e '.subsets[]?.addresses[]?.ip' >/dev/null
}

assert_control_plane_images() {
    local component expected
    mapfile -t actual < <("${KUBECTL[@]}" -n kubevirt get pods -o json | jq -r '
      [.items[] | (.status.initContainerStatuses // [])[]?, (.status.containerStatuses // [])[]?]
      | .[] | .imageID | sub("^docker-pullable://"; "")
      | select(. != "quay.io/kubevirt/virt-launcher@sha256:f23102ca00bf12f7962021adfdfdad63c873b01a03001a6d20d5813950254b9c")' | sort -u)
    test "${#actual[@]}" = "$(( ${#IMAGE_DIGESTS[@]} - 1 ))"
    for component in "${!IMAGE_DIGESTS[@]}"; do
        test "${component}" = virt-launcher && continue
        expected="quay.io/kubevirt/${component}@${IMAGE_DIGESTS[${component}]}"
        printf '%s\n' "${actual[@]}" | grep -Fxq "${expected}"
    done
    printf 'Verified KubeVirt control-plane image IDs:\n'
    printf '%s\n' "${actual[@]}"
}

download kubevirt-operator.yaml "${OPERATOR_SHA256}"
download kubevirt-cr.yaml "${CR_SHA256}"
download "virtctl-${KUBEVIRT_VERSION}-linux-amd64" "${VIRTCTL_SHA256}"
install -m 0755 "${workdir}/virtctl-${KUBEVIRT_VERSION}-linux-amd64" "${workdir}/virtctl"
sed -i "s#quay.io/kubevirt/virt-operator:${KUBEVIRT_VERSION}#quay.io/kubevirt/virt-operator@${IMAGE_DIGESTS[virt-operator]}#g" "${workdir}/kubevirt-operator.yaml"
"${KUBECTL[@]}" apply -f "${workdir}/kubevirt-operator.yaml"
wait_for 'virt-operator deployment' "${KUBECTL[@]}" -n kubevirt rollout status deployment/virt-operator --timeout=10s
"${KUBECTL[@]}" -n kubevirt set env deployment/virt-operator \
    "VIRT_API_IMAGE=quay.io/kubevirt/virt-api@${IMAGE_DIGESTS[virt-api]}" \
    "VIRT_CONTROLLER_IMAGE=quay.io/kubevirt/virt-controller@${IMAGE_DIGESTS[virt-controller]}" \
    "VIRT_HANDLER_IMAGE=quay.io/kubevirt/virt-handler@${IMAGE_DIGESTS[virt-handler]}" \
    "VIRT_LAUNCHER_IMAGE=quay.io/kubevirt/virt-launcher@${IMAGE_DIGESTS[virt-launcher]}" \
    "VIRT_EXPORTPROXY_IMAGE=quay.io/kubevirt/virt-exportproxy@${IMAGE_DIGESTS[virt-exportproxy]}" \
    "VIRT_TEMPLATE_APISERVER_IMAGE=quay.io/kubevirt/virt-template-apiserver@${IMAGE_DIGESTS[virt-template-apiserver]}" \
    "VIRT_TEMPLATE_CONTROLLER_IMAGE=quay.io/kubevirt/virt-template-controller@${IMAGE_DIGESTS[virt-template-controller]}"
wait_for 'digest-configured virt-operator' "${KUBECTL[@]}" -n kubevirt rollout status deployment/virt-operator --timeout=10s
"${KUBECTL[@]}" apply -f "${workdir}/kubevirt-cr.yaml"
"${KUBECTL[@]}" -n kubevirt wait --for=condition=Available kubevirt/kubevirt --timeout=10m
wait_for 'virt-handler daemonset' "${KUBECTL[@]}" -n kubevirt rollout status daemonset/virt-handler --timeout=10s
assert_control_plane_images
"${KUBECTL[@]}" get node -o json | jq -e '[.items[].status.allocatable["devices.kubevirt.io/kvm"] | select(. != null and . != "0")] | length > 0' >/dev/null
if "${KUBECTL[@]}" -n kubevirt get kubevirt kubevirt -o json | jq -e '.spec.configuration.developerConfiguration.useEmulation == true' >/dev/null; then
    printf 'KubeVirt software emulation is enabled\n' >&2
    exit 1
fi

"${KUBECTL[@]}" create namespace "${NAMESPACE}"
umask 077
ssh-keygen -q -t ed25519 -N '' -f "${private_key}"
"${KUBECTL[@]}" -n "${NAMESPACE}" create secret generic kubevirt-acceptance-ssh --from-literal=userdata="$(printf '%s\n' '#cloud-config' 'users:' '- name: fedora' '  ssh_authorized_keys:' "  - $(<"${private_key}.pub")")"
"${KUBECTL[@]}" -n "${NAMESPACE}" apply -f "${fixture_dir}/vm.yaml"
"${KUBECTL[@]}" -n "${NAMESPACE}" apply -f "${fixture_dir}/service.yaml"
"${KUBECTL[@]}" -n "${NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Running "vmi/${VM}" --timeout=5m
wait_for 'ClusterIP Service endpoint' has_service_endpoint
launcher_pod=$("${KUBECTL[@]}" -n "${NAMESPACE}" get pod -l kubevirt.io/created-by="$("${KUBECTL[@]}" -n "${NAMESPACE}" get vmi "${VM}" -o jsonpath='{.metadata.uid}')" -o jsonpath='{.items[0].metadata.name}')
test -n "${launcher_pod}"
test "$("${KUBECTL[@]}" -n "${NAMESPACE}" get pod -l kubevirt.io/created-by="$("${KUBECTL[@]}" -n "${NAMESPACE}" get vmi "${VM}" -o jsonpath='{.metadata.uid}')" -o jsonpath='{.items[*].metadata.name}' | wc -w)" = 1
mapfile -t launcher_images < <("${KUBECTL[@]}" -n "${NAMESPACE}" get pod "${launcher_pod}" -o json | jq -r '
  [(.status.initContainerStatuses // [])[]?, (.status.containerStatuses // [])[]?]
  | .[] | .imageID | sub("^docker-pullable://"; "")' | sort -u)
test "${#launcher_images[@]}" = 2
printf '%s\n' "${launcher_images[@]}" | grep -Fxq "${FEDORA_DISK}"
printf '%s\n' "${launcher_images[@]}" | grep -Fxq "quay.io/kubevirt/virt-launcher@${IMAGE_DIGESTS[virt-launcher]}"
printf 'Verified VMI launcher-pod image IDs:\n'
printf '%s\n' "${launcher_images[@]}"
mapfile -t domains < <("${KUBECTL[@]}" -n "${NAMESPACE}" exec "${launcher_pod}" -c compute -- virsh list --name | tr -d '\r' | grep -v '^$')
test "${#domains[@]}" = 1
"${KUBECTL[@]}" -n "${NAMESPACE}" exec "${launcher_pod}" -c compute -- virsh dumpxml "${domains[0]}" | grep -Fq "<domain type='kvm'"
wait_for 'L2 SSH command' env KUBECONFIG=/etc/rancher/k3s/k3s.yaml "${workdir}/virtctl" ssh --namespace="${NAMESPACE}" --username=fedora --identity-file="${private_key}" --known-hosts=/dev/null --local-ssh-opts=-o --local-ssh-opts=StrictHostKeyChecking=no "vmi/${VM}" --command='grep -Eq "(^|[[:space:]])hypervisor([[:space:]]|$)" /proc/cpuinfo; test -d /sys/hypervisor; uname -sr'
env KUBECONFIG=/etc/rancher/k3s/k3s.yaml "${workdir}/virtctl" ssh --namespace="${NAMESPACE}" --username=fedora --identity-file="${private_key}" --known-hosts=/dev/null --local-ssh-opts=-o --local-ssh-opts=StrictHostKeyChecking=no "vmi/${VM}" --command='grep -Eq "(^|[[:space:]])hypervisor([[:space:]]|$)" /proc/cpuinfo; test -d /sys/hypervisor; uname -sr'
printf 'KubeVirt %s nested-KVM acceptance passed.\n' "${KUBEVIRT_VERSION}"
