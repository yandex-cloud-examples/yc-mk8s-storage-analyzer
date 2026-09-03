#!/bin/bash
# Read-only storage diagnostics for the cluster in the current kubectl context.
# The script starts no external programs except kubectl.

set -u -o pipefail

if (( $# != 2 )); then
  printf 'Usage: %s <since> <namespace>\n' "${0##*/}" >&2
  printf 'Example: %s 1h prod > storage-info.txt 2>&1\n' "${0##*/}" >&2
  exit 2
fi

SINCE="$1"
NAMESPACE="$2"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30s}"
NAMESPACES=("$NAMESPACE")

if [[ "$NAMESPACE" != kube-system ]]; then
  NAMESPACES+=(kube-system)
fi

header() {
  printf '\n\n===============================================================================\n'
  printf '### %s\n' "$1"
  printf '===============================================================================\n'
}

kc() {
  kubectl --request-timeout="$REQUEST_TIMEOUT" "$@"
}

# Run one kubectl command and always let the collection continue.
run() {
  local title="$1"
  local status
  shift

  header "$title"
  printf '$ kubectl --request-timeout=%q' "$REQUEST_TIMEOUT"
  printf ' %q' "$@"
  printf '\n\n'

  kc "$@" 2>&1
  status=$?
  if (( status != 0 )); then
    printf '\n[kubectl exited with status %d; collection continues]\n' "$status"
  fi
  return 0
}

run_namespaced() {
  local title="$1"
  local namespace
  shift

  for namespace in "${NAMESPACES[@]}"; do
    run "$title [$namespace]" "$@" -n "$namespace"
  done
}

printf '# Kubernetes storage diagnostics\n'
printf 'since: %s\n' "$SINCE"
printf 'namespaces: %s\n' "${NAMESPACES[*]}"
printf 'request timeout: %s\n' "$REQUEST_TIMEOUT"

run 'Current kubectl context' config current-context
run 'Kubernetes client and server versions' version
run 'storage.k8s.io API resources' api-resources --api-group=storage.k8s.io
run 'snapshot.storage.k8s.io API resources' api-resources --api-group=snapshot.storage.k8s.io

run 'StorageClasses' get storageclasses -o wide
run 'StorageClass details' describe storageclasses
run 'StorageClasses YAML' get storageclasses -o yaml

run 'PersistentVolumes' get persistentvolumes -o wide
run 'PersistentVolume details' describe persistentvolumes
run 'PersistentVolumes YAML' get persistentvolumes -o yaml

run_namespaced 'PersistentVolumeClaims' get persistentvolumeclaims -o wide
run_namespaced 'PersistentVolumeClaim details' describe persistentvolumeclaims
run_namespaced 'PersistentVolumeClaims YAML' get persistentvolumeclaims -o yaml

run_namespaced 'Pods' get pods -o wide
run_namespaced 'Pods YAML (volume consumers and placement)' get pods -o yaml

run 'VolumeAttachments' get volumeattachments -o wide
run 'VolumeAttachment details' describe volumeattachments
run 'VolumeAttachments YAML' get volumeattachments -o yaml

run 'CSIDrivers' get csidrivers -o wide
run 'CSIDriver details' describe csidrivers
run 'CSIDrivers YAML' get csidrivers -o yaml

run 'CSINodes' get csinodes -o wide
run 'CSINode details' describe csinodes
run 'CSINodes YAML' get csinodes -o yaml

run_namespaced 'CSIStorageCapacities' get csistoragecapacities -o wide
run_namespaced 'CSIStorageCapacity details' describe csistoragecapacities
run_namespaced 'CSIStorageCapacities YAML' get csistoragecapacities -o yaml

run 'VolumeAttributesClasses' get volumeattributesclasses -o wide
run 'VolumeAttributesClass details' describe volumeattributesclasses
run 'VolumeAttributesClasses YAML' get volumeattributesclasses -o yaml

run 'VolumeSnapshotClasses' get volumesnapshotclasses -o wide
run 'VolumeSnapshotClass details' describe volumesnapshotclasses
run 'VolumeSnapshotClasses YAML' get volumesnapshotclasses -o yaml

run 'VolumeSnapshotContents' get volumesnapshotcontents -o wide
run 'VolumeSnapshotContent details' describe volumesnapshotcontents
run 'VolumeSnapshotContents YAML' get volumesnapshotcontents -o yaml

run_namespaced 'VolumeSnapshots' get volumesnapshots -o wide
run_namespaced 'VolumeSnapshot details' describe volumesnapshots
run_namespaced 'VolumeSnapshots YAML' get volumesnapshots -o yaml

run_namespaced 'Events' get events --sort-by=.lastTimestamp

run_namespaced 'ResourceQuotas' get resourcequotas -o wide
run_namespaced 'ResourceQuota details' describe resourcequotas
run_namespaced 'LimitRanges' get limitranges
run_namespaced 'LimitRange details' describe limitranges
run_namespaced 'StatefulSets' get statefulsets -o wide
run_namespaced 'StatefulSets YAML (volumeClaimTemplates)' get statefulsets -o yaml

header 'CSI pods and container logs'
CSI_FOUND=0

collect_csi_pods() {
  local target_namespace="$1"
  local csi_pods
  local csi_status
  local namespace
  local pod
  local containers

  printf '$ kubectl --request-timeout=%q get pods -n %q -o jsonpath=...\n\n' \
    "$REQUEST_TIMEOUT" "$target_namespace"

  csi_pods="$(kc get pods -n "$target_namespace" \
    -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}' 2>&1)"
  csi_status=$?

  if (( csi_status != 0 )); then
    printf '%s\n' "$csi_pods"
    printf '\n[kubectl exited with status %d; CSI pod collection skipped for namespace %s]\n\n' \
      "$csi_status" "$target_namespace"
    return
  fi

  while IFS=$'\t' read -r namespace pod containers; do
    [[ -n "${namespace:-}" && -n "${pod:-}" ]] || continue

    case "$pod $containers" in
      *csi*|*s3*|*geesefs*|*snapshot*|*provisioner*|*attacher*|*resizer*|*node-driver-registrar*)
        CSI_FOUND=1
        run "CSI pod $namespace/$pod" describe pod -n "$namespace" "$pod"
        for container in $containers; do
          run "Logs $namespace/$pod [$container]" \
            logs -n "$namespace" "$pod" -c "$container" --since="$SINCE"
        done
        ;;
    esac
  done <<< "$csi_pods"
}

for namespace in "${NAMESPACES[@]}"; do
  collect_csi_pods "$namespace"
done

if (( CSI_FOUND == 0 )); then
  printf 'No CSI, S3 storage, or snapshot pods matched by pod/container name.\n'
fi

printf '\n\n=== collection complete ===\n'
