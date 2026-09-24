#!/usr/bin/env bash
#
# Pi-fork helper: re-apply the k3s-loopback-registry / rustfs overrides that
# `ate-setup deploy` does not render into manifests.
#
# The base manifests assume GKE (GCS storage backend, GCP registry auth).
# On the Pi single-node install, snapshots live in the in-cluster rustfs and
# images in the host loopback registry, so every deploy/upgrade must be
# followed by:
#
#   ./hack/pi-env.sh
#
# Idempotent; safe to re-run. Requires kubectl configured for the cluster
# (KUBECONFIG) and the `app=atelet` label selector to find the DaemonSets.
#
# Env knobs:
#   NS                    namespace, default ate-system
#   RUSTFS_SVC            rustfs endpoint, default http://rustfs.ate-system.svc:9000
#   REGISTRY_REPLACEMENT  what atelet rewrites localhost:5000 to when pulling
#                         images from inside pods, default 192.168.1.134:5000
#                         (the node's LAN IP; pod-localhost never reaches the
#                         host loopback registry)
#   ATE_GVISOR_PLATFORM   when "kvm", gVisor workers also get /dev/kvm plus the
#                         worker-side switch. KVM runsc currently panics on the
#                         Pi's 39-bit-VA kernel (fillAddressSpace), so leave this
#                         unset (systrap) unless the kernel is rebuilt with
#                         48-bit VA. See pi-kvm branch notes.

set -o errexit -o nounset -o pipefail

NS="${NS:-ate-system}"
RUSTFS_SVC="${RUSTFS_SVC:-http://rustfs.ate-system.svc:9000}"
REGISTRY_REPLACEMENT="${REGISTRY_REPLACEMENT:-192.168.1.134:5000}"

echo "==> api-server: S3/rustfs storage backend"
kubectl set env deploy/ate-api-server -n "$NS" \
  ATE_STORAGE_BACKEND=s3 \
  AWS_REGION=us-east-1 \
  AWS_ENDPOINT_URL="$RUSTFS_SVC" \
  AWS_S3_USE_PATH_STYLE=true \
  AWS_ACCESS_KEY_ID=rustfsadmin \
  AWS_SECRET_ACCESS_KEY=rustfsadmin >/dev/null

if [[ "${ATE_GVISOR_PLATFORM:-}" == "kvm" ]]; then
  echo "==> controller: enable KVM gVisor workers"
  kubectl set env deploy/ate-controller -n "$NS" ATE_GVISOR_PLATFORM=kvm >/dev/null
fi

echo "==> atelet daemonsets: no GCP auth, S3 backend, registry replacement"
for ds in $(kubectl get ds -n "$NS" -l app=atelet -o 'jsonpath={.items[*].metadata.name}'); do
  desired="$(kubectl get ds "$ds" -n "$NS" -o 'jsonpath={.status.desiredNumberScheduled}')"
  if [[ "$desired" == "0" ]]; then
    echo "    $ds: scaled down, skipping"
    continue
  fi
  args="$(kubectl get ds "$ds" -n "$NS" -o 'jsonpath={.spec.template.spec.containers[0].args}')"
  if [[ "$args" == *"--gcp-auth-for-image-pulls=true"* ]]; then
    kubectl patch ds "$ds" -n "$NS" --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/0","value":"--gcp-auth-for-image-pulls=false"}]' >/dev/null
    echo "    $ds: gcp-auth disabled"
  fi
  if [[ "$args" != *"localhost-registry-replacement"* ]]; then
    kubectl patch ds "$ds" -n "$NS" --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--localhost-registry-replacement='"$REGISTRY_REPLACEMENT"'"}]' >/dev/null
    echo "    $ds: registry replacement added"
  fi
  kubectl set env "ds/$ds" -n "$NS" \
    ATE_STORAGE_BACKEND=s3 \
    AWS_REGION=us-east-1 \
    AWS_ENDPOINT_URL="$RUSTFS_SVC" \
    AWS_S3_USE_PATH_STYLE=true \
    AWS_ACCESS_KEY_ID=rustfsadmin \
    AWS_SECRET_ACCESS_KEY=rustfsadmin >/dev/null
  echo "    $ds: storage env set"
done

echo "done"
