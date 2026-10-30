#!/usr/bin/env bash
#
# Backs up and restores the state of Immich, Home Assistant (including
# zigbee2mqtt and mosquitto) and barpath. Run it from a workstation that has
# kubectl access. Everything else in the cluster is out of scope.
#
# Usage: scripts/homelab-backup.sh <command> [options] [backup-dir]
#
#   backup            Stop the apps, copy their data, start them again.
#   verify [dir]      Check a backup's checksums and archives. Touches no cluster.
#   restore-secrets [dir]
#                     Create the barpath secrets. Run on a new cluster, before
#                     or right after the Argo seed job.
#   restore [dir]     Overwrite the apps' data with a backup. Destructive.
#   resume            Start apps left stopped by an interrupted run.
#
#   --context NAME    kubectl context (default: the current context)
#   --dest DIR        Where backups live (default: ~/homelab-backup)
#   --yes             Skip the confirmation prompt
#   --force           restore: continue despite an app version mismatch
#
#   [dir] defaults to the newest complete backup in --dest.
#
# Moving to a new cluster:
#
#   1. On the old cluster, as the last thing before shutting it down:
#        scripts/homelab-backup.sh backup
#      Each run is a new full copy of about 47 GB in its own timestamped folder.
#      Copy that folder off the workstation too, then check the copy:
#        scripts/homelab-backup.sh verify /mnt/external/2026-11-01T100000
#   2. Install the new cluster and Argo as in the README, but do not change app
#      versions in git yet. The backup must go back onto the same Immich version
#      and Postgres major version, or restore refuses to run.
#   3. Create the secrets and start the apps. They come up empty, which creates
#      the PVCs and databases the restore needs:
#        scripts/homelab-backup.sh restore-secrets
#        kubectl apply -f kubernetes/manifests/argocd-seedjobs/manifest-apps.yaml
#   4. Wait until the Immich and barpath databases and the PVCs exist. restore
#      checks this and tells you what is missing. Plug in the same Zigbee USB
#      dongle before the apps start again.
#        scripts/homelab-backup.sh restore
#   5. Check by hand: a shared Immich album link in a private window, a Zigbee
#      device from Home Assistant, a barpath login.
#
# A failed restore leaves the apps stopped so nothing writes to half-restored
# data. Fix the cause and run restore again, or run resume to start them anyway.

set -Eeuo pipefail
umask 077

readonly HELPER_IMAGE=debian:12-slim
readonly HELPER_LABEL=app.kubernetes.io/name=homelab-backup-helper
readonly SCALE_TIMEOUT=300

# namespace pvc
readonly VOLUMES=(
  "media pictures"
  "home-automation home-assistant-config"
  "home-automation zigbee2mqtt-data"
  "home-automation mosquitto-data"
  "barpath data-platform-seaweedfs-0"
)
readonly HELPER_NAMESPACES=(media home-automation barpath)

# Stopped first and started last, so self-heal can't undo the scale-downs.
readonly ARGO_WORKLOADS=(
  "argocd deployment argocd-applicationset-controller"
  "argocd statefulset argocd-application-controller"
)
# Barpath's workloads are looked up at run time. Postgres stays up: it is run
# by CNPG and the dumps need it.
readonly APP_WORKLOADS=(
  "media deployment immich-server"
  "media deployment immich-machine-learning"
  "home-automation deployment home-assistant"
  "home-automation deployment zigbee2mqtt"
  "home-automation deployment mosquitto"
)
readonly BARPATH_SECRETS=(platform-auth-jwt platform-media-s3 ghcr-secret)

CONTEXT=""
DEST="${HOME}/homelab-backup"
ASSUME_YES=false
FORCE=false
MODE=""
BACKUP_DIR=""
PARTIAL_DIR=""
FROZEN=false
FREEZE_FILE=""

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '%s  WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "$CONTEXT" "$@"; }

usage() { sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; }

confirm() { # prompt, word the user must type
  [[ $ASSUME_YES == true ]] && return 0
  local answer
  printf '%s\nType %s to continue: ' "$1" "$2"
  read -r answer
  [[ $answer == "$2" ]] || die "aborted"
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n $CONTEXT ]]; then
    local ns
    for ns in "${HELPER_NAMESPACES[@]}"; do
      k -n "$ns" delete pod -l "$HELPER_LABEL" --ignore-not-found --wait=true >/dev/null 2>&1
    done
  fi
  case "$MODE" in
    backup)
      [[ $FROZEN == true ]] && unfreeze
      if [[ $rc -ne 0 && -n $PARTIAL_DIR ]]; then
        rm -rf "$PARTIAL_DIR"
        log "backup FAILED, incomplete copy removed"
      fi
      ;;
    restore)
      if [[ $rc -ne 0 && $FROZEN == true ]]; then
        printf '\nRestore FAILED. The apps are still stopped so nothing writes to partial data.\n' >&2
        printf 'Fix the cause and run restore again, or run "%s resume" to start them.\n' "$0" >&2
      fi
      ;;
  esac
  exit "$rc"
}

#
# Stopping and starting workloads
#

all_app_workloads() {
  printf '%s\n' "${APP_WORKLOADS[@]}"
  k -n barpath get deployment,statefulset -o json \
    | jq -r '.items[] | "barpath \(.kind | ascii_downcase) \(.metadata.name)"'
}

wait_for_no_pods() { # namespace kind name
  local selector waited=0
  selector=$(k -n "$1" get "$2" "$3" -o json \
    | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
  while [[ -n $(k -n "$1" get pods -l "$selector" -o name) ]]; do
    ((waited += 3))
    ((waited < SCALE_TIMEOUT)) || die "$1/$3 still has pods after ${SCALE_TIMEOUT}s"
    sleep 3
  done
}

freeze() {
  # A leftover file means an earlier run died while frozen. Its replica counts
  # are the real ones: the workloads are at 0 now, so don't record them again.
  if [[ -f $FREEZE_FILE ]]; then
    log "reusing replica counts from an interrupted run"
  else
    local tmp="${FREEZE_FILE}.tmp" ns kind name
    : >"$tmp"
    while read -r ns kind name; do
      printf '%s %s %s %s\n' "$ns" "$kind" "$name" \
        "$(k -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.replicas}')" >>"$tmp"
    done < <(printf '%s\n' "${ARGO_WORKLOADS[@]}"; all_app_workloads)
    mv "$tmp" "$FREEZE_FILE"
  fi
  FROZEN=true

  log "stopping Argo and the apps"
  local ns kind name replicas
  while read -r ns kind name replicas; do
    k -n "$ns" scale "$kind" "$name" --replicas=0 >/dev/null
  done <"$FREEZE_FILE"
  while read -r ns kind name replicas; do
    wait_for_no_pods "$ns" "$kind" "$name"
  done <"$FREEZE_FILE"
}

unfreeze() {
  local ns kind name replicas failed=false
  log "starting the apps and Argo"
  while read -r ns kind name replicas; do
    k -n "$ns" scale "$kind" "$name" --replicas="$replicas" >/dev/null || failed=true
  done < <(tac "$FREEZE_FILE")
  if [[ $failed == true ]]; then
    warn "some workloads did not scale back, run resume to retry"
    return 1
  fi
  # Slow image pulls or a failing app shouldn't fail a run whose data is fine.
  while read -r ns kind name replicas; do
    [[ $replicas -gt 0 ]] || continue
    k -n "$ns" rollout status "$kind" "$name" --timeout=600s >/dev/null \
      || warn "$ns/$name is not ready yet, check it by hand"
  done <"$FREEZE_FILE"
  rm -f "$FREEZE_FILE"
  FROZEN=false
}

#
# Volumes
#

start_helper() { # namespace pvc, prints the pod name
  local pod="bk-$2"
  k -n "$1" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  jq -n --arg pod "$pod" --arg pvc "$2" --arg image "$HELPER_IMAGE" --arg label "$HELPER_LABEL" '{
    apiVersion: "v1", kind: "Pod",
    metadata: {name: $pod, labels: {($label | split("=")[0]): ($label | split("=")[1])}},
    spec: {
      restartPolicy: "Never",
      containers: [{name: "bk", image: $image, command: ["sleep", "86400"],
                    volumeMounts: [{name: "v", mountPath: "/v"}]}],
      volumes: [{name: "v", persistentVolumeClaim: {claimName: $pvc}}]
    }}' | k -n "$1" create -f - >/dev/null
  k -n "$1" wait --for=condition=Ready "pod/$pod" --timeout=300s >/dev/null \
    || die "helper pod for $1/$2 did not start"
  printf '%s' "$pod"
}

files_on_volume() { # namespace pod
  k -n "$1" exec "$2" -- sh -c "find /v -type f -printf '.\n' | wc -l"
}

files_in_tar() { # file, exits non-zero when the archive is damaged
  tar tvf "$1" | awk '/^[-h]/ { n++ } END { print n + 0 }'
}

backup_volume() { # namespace pvc
  local pod target="$PARTIAL_DIR/$2.tar" need avail on_volume in_tar
  pod=$(start_helper "$1" "$2")

  need=$(k -n "$1" exec "$pod" -- du -sk /v | cut -f1)
  avail=$(df -Pk "$PARTIAL_DIR" | awk 'NR == 2 { print $4 }')
  ((avail > need + 1048576)) \
    || die "not enough space for $2: needs $((need / 1024)) MB, $((avail / 1024)) MB free"

  log "copying $1/$2 ($((need / 1024)) MB)"
  k -n "$1" exec "$pod" -- tar -C /v -cf - . >"$target"
  on_volume=$(files_on_volume "$1" "$pod")
  in_tar=$(files_in_tar "$target") || die "$2.tar is damaged"
  [[ $on_volume -eq $in_tar ]] || die "$2: $on_volume files on the volume, $in_tar in the tar"
  log "  $in_tar files"

  k -n "$1" delete pod "$pod" --wait=true >/dev/null
}

restore_volume() { # namespace pvc
  local pod source="$BACKUP_DIR/$2.tar" on_volume in_tar
  pod=$(start_helper "$1" "$2")

  log "restoring $1/$2 ($(du -sm "$source" | cut -f1) MB)"
  k -n "$1" exec "$pod" -- find /v -mindepth 1 -delete
  k -n "$1" exec -i "$pod" -- tar -C /v --numeric-owner -xpf - <"$source"
  on_volume=$(files_on_volume "$1" "$pod")
  in_tar=$(files_in_tar "$source")
  [[ $on_volume -eq $in_tar ]] || die "$2: restored $on_volume files, the tar has $in_tar"
  log "  $on_volume files"

  k -n "$1" delete pod "$pod" --wait=true >/dev/null
}

#
# Databases
#

pg_pod() { # namespace cluster
  local pod
  pod=$(k -n "$1" get pods -l "cnpg.io/cluster=$2,cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
  [[ -n $pod ]] || die "no primary Postgres pod for $1/$2"
  printf '%s' "$pod"
}

pg_exec() { # namespace cluster, then the command to run in the Postgres container
  local ns=$1 cluster=$2 pod
  shift 2
  pod=$(pg_pod "$ns" "$cluster")
  k -n "$ns" exec -i "$pod" -c postgres -- "$@"
}

pg_query() { # namespace cluster database sql
  pg_exec "$1" "$2" psql -U postgres -d "$3" -v ON_ERROR_STOP=1 -Atc "$4"
}

# Table and exact row count across the public schema, to prove a restore put
# back what the dump took.
pg_fingerprint() { # namespace cluster database
  pg_query "$1" "$2" "$3" "
    SELECT count(*) || ' tables, '
        || coalesce(sum((xpath('/row/c/text()', query_to_xml(
             format('SELECT count(*) AS c FROM %I.%I', schemaname, tablename),
             false, true, '')))[1]::text::bigint), 0) || ' rows'
    FROM pg_tables WHERE schemaname = 'public'"
}

pg_reset_schema() { # namespace cluster database owner
  # Clears whatever the empty app created on first start, so that only the
  # backup's contents remain. Run as postgres because the app's role doesn't
  # own the extensions.
  pg_exec "$1" "$2" psql -U postgres -d "$3" -v ON_ERROR_STOP=1 --single-transaction \
    -c 'DROP SCHEMA public CASCADE' -c "CREATE SCHEMA public AUTHORIZATION \"$4\"" >/dev/null
}

check_fingerprint() { # label expected namespace cluster database
  local actual
  actual=$(pg_fingerprint "$3" "$4" "$5")
  [[ $actual == "$2" ]] || die "$1 database: expected $2, got $actual"
  log "  $1 database: $actual"
}

#
# Backup contents
#

resolve_backup_dir() { # optional path
  local dir=${1:-$DEST/latest}
  [[ -d $dir ]] || die "no backup at $dir"
  dir=$(cd "$dir" && pwd -P)
  [[ -f $dir/manifest.json && -f $dir/SHA256SUMS ]] || die "$dir is not a complete backup"
  printf '%s' "$dir"
}

verify_backup() {
  log "checking checksums of $BACKUP_DIR"
  (cd "$BACKUP_DIR" && sha256sum --check --quiet SHA256SUMS) || die "checksum mismatch"
  gzip -t "$BACKUP_DIR/immich.sql.gz"
  jq -e . "$BACKUP_DIR/barpath-secrets.json" >/dev/null
  local volume pvc
  for volume in "${VOLUMES[@]}"; do
    pvc=${volume#* }
    files_in_tar "$BACKUP_DIR/$pvc.tar" >/dev/null || die "$pvc.tar is damaged"
  done
  log "backup is intact"
}

image_of() { # namespace kind name
  k -n "$1" get "$2" "$3" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

immich_versions() {
  jq -n \
    --arg image "$(image_of media deployment immich-server)" \
    --arg pg "$(pg_query media immich-postgresql immich 'SHOW server_version_num')" \
    --arg vchord "$(pg_query media immich-postgresql immich "SELECT extversion FROM pg_extension WHERE extname = 'vchord'")" \
    '{image: $image, pg_major: (($pg | tonumber) / 10000 | floor), vchord: $vchord}'
}

preflight() {
  local cmd
  for cmd in kubectl jq tar gzip sha256sum tac awk; do
    command -v "$cmd" >/dev/null || die "$cmd is not installed"
  done
  k version --request-timeout=10s >/dev/null 2>&1 || die "cannot reach context $CONTEXT"

  local ns kind name problems=()
  while read -r ns kind name; do
    k -n "$ns" get "$kind" "$name" >/dev/null 2>&1 || problems+=("$kind $ns/$name")
  done < <(printf '%s\n' "${ARGO_WORKLOADS[@]}" "${APP_WORKLOADS[@]}" "barpath statefulset platform-seaweedfs")

  local volume pvc
  for volume in "${VOLUMES[@]}"; do
    ns=${volume% *} pvc=${volume#* }
    k -n "$ns" get pvc "$pvc" >/dev/null 2>&1 || problems+=("pvc $ns/$pvc")
  done

  (pg_pod media immich-postgresql >/dev/null) 2>/dev/null || problems+=("Postgres media/immich-postgresql")
  (pg_pod barpath barpath-postgresql >/dev/null) 2>/dev/null || problems+=("Postgres barpath/barpath-postgresql")

  if ((${#problems[@]})); then
    printf 'Not found in context %s:\n' "$CONTEXT" >&2
    printf '  %s\n' "${problems[@]}" >&2
    die "the cluster is not ready"
  fi
}

#
# Commands
#

cmd_backup() {
  # The stopped apps may be mid-restore, and that data must not become a backup.
  [[ ! -f $FREEZE_FILE ]] || die "an earlier run left the apps stopped: finish that restore, or run resume if the data is good"
  MODE=backup
  preflight
  if compgen -G "$DEST/.partial-*" >/dev/null; then
    warn "$DEST holds .partial-* folders from a killed run, they can be deleted"
  fi
  confirm "This stops Immich, Home Assistant, Zigbee and barpath in context '$CONTEXT' during the copy." backup

  local stamp
  stamp=$(date +%Y-%m-%dT%H%M%S)
  PARTIAL_DIR="$DEST/.partial-$stamp"
  mkdir "$PARTIAL_DIR"

  local versions
  versions=$(immich_versions)

  freeze

  log "dumping the Immich database"
  local immich_print barpath_print immich_counts
  immich_print=$(pg_fingerprint media immich-postgresql immich)
  immich_counts=$(pg_query media immich-postgresql immich "
    SELECT (SELECT count(*) FROM asset) || ' assets, '
        || (SELECT count(*) FROM album) || ' albums, '
        || (SELECT count(*) FROM shared_link) || ' shared links'")
  pg_exec media immich-postgresql pg_dump -U postgres --clean --if-exists immich \
    | gzip >"$PARTIAL_DIR/immich.sql.gz"
  gzip -t "$PARTIAL_DIR/immich.sql.gz"
  log "  $immich_counts"

  log "dumping the barpath database"
  barpath_print=$(pg_fingerprint barpath barpath-postgresql auth)
  pg_exec barpath barpath-postgresql pg_dump -U postgres -Fc auth >"$PARTIAL_DIR/barpath.dump"
  pg_exec barpath barpath-postgresql pg_restore --list <"$PARTIAL_DIR/barpath.dump" >/dev/null

  log "exporting the barpath secrets"
  k -n barpath get secret "${BARPATH_SECRETS[@]}" -o json \
    | jq 'del(.metadata, .items[].metadata.uid, .items[].metadata.resourceVersion,
              .items[].metadata.creationTimestamp, .items[].metadata.managedFields)' \
    >"$PARTIAL_DIR/barpath-secrets.json"

  local volume
  for volume in "${VOLUMES[@]}"; do
    # shellcheck disable=SC2086 # "namespace pvc" splits into two arguments
    backup_volume $volume
  done

  jq -n \
    --arg created "$(date -Is)" \
    --arg context "$CONTEXT" \
    --argjson immich "$versions" \
    --arg immich_print "$immich_print" \
    --arg immich_counts "$immich_counts" \
    --arg barpath_print "$barpath_print" \
    --arg home_assistant "$(image_of home-automation deployment home-assistant)" \
    '{created: $created, context: $context, immich: $immich,
      immich_fingerprint: $immich_print, immich_counts: $immich_counts,
      barpath_fingerprint: $barpath_print, home_assistant_image: $home_assistant}' \
    >"$PARTIAL_DIR/manifest.json"

  log "writing checksums"
  (cd "$PARTIAL_DIR" && sha256sum -- * >SHA256SUMS)

  mv "$PARTIAL_DIR" "$DEST/$stamp"
  PARTIAL_DIR=""
  BACKUP_DIR="$DEST/$stamp"
  ln -sfn "$stamp" "$DEST/latest"

  unfreeze
  log "backup complete: $BACKUP_DIR ($(du -sh "$BACKUP_DIR" | cut -f1))"
  log "copy it off this machine, then check the copy with: $0 verify <copy>"
}

cmd_verify() {
  BACKUP_DIR=$(resolve_backup_dir "${1:-}")
  verify_backup
  jq . "$BACKUP_DIR/manifest.json"
}

apply_secrets() {
  k create namespace barpath --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f "$BACKUP_DIR/barpath-secrets.json" >/dev/null
  log "barpath secrets are in place"
}

cmd_restore_secrets() {
  BACKUP_DIR=$(resolve_backup_dir "${1:-}")
  k version --request-timeout=10s >/dev/null 2>&1 || die "cannot reach context $CONTEXT"
  confirm "This writes the barpath secrets to context '$CONTEXT'." secrets
  apply_secrets
}

check_versions() {
  local wanted current ha_wanted ha_current
  wanted=$(jq -c .immich "$BACKUP_DIR/manifest.json")
  current=$(immich_versions | jq -c .)
  if [[ $wanted != "$current" ]]; then
    printf 'Immich version mismatch:\n  backup:  %s\n  cluster: %s\n' "$wanted" "$current" >&2
    [[ $FORCE == true ]] || die "pin the backup's versions in git, or use --force"
    warn "continuing because of --force"
  fi
  ha_wanted=$(jq -r .home_assistant_image "$BACKUP_DIR/manifest.json")
  ha_current=$(image_of home-automation deployment home-assistant)
  [[ $ha_wanted == "$ha_current" ]] \
    || warn "Home Assistant was $ha_wanted, is now $ha_current. It can upgrade its data but not downgrade it."
}

cmd_restore() {
  BACKUP_DIR=$(resolve_backup_dir "${1:-}")
  MODE=restore
  preflight
  check_versions
  verify_backup
  log "backup from $(jq -r .created "$BACKUP_DIR/manifest.json"): $(jq -r .immich_counts "$BACKUP_DIR/manifest.json")"
  confirm "This ERASES the current Immich, Home Assistant, Zigbee and barpath data in context '$CONTEXT'." restore

  apply_secrets
  freeze

  local volume
  for volume in "${VOLUMES[@]}"; do
    # shellcheck disable=SC2086 # "namespace pvc" splits into two arguments
    restore_volume $volume
  done

  log "restoring the Immich database"
  pg_reset_schema media immich-postgresql immich immich
  gunzip -c "$BACKUP_DIR/immich.sql.gz" \
    | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
    | pg_exec media immich-postgresql psql -U postgres -d immich --single-transaction --set ON_ERROR_STOP=on >/dev/null
  check_fingerprint Immich "$(jq -r .immich_fingerprint "$BACKUP_DIR/manifest.json")" media immich-postgresql immich

  log "restoring the barpath database"
  pg_reset_schema barpath barpath-postgresql auth barpath
  pg_exec barpath barpath-postgresql pg_restore -U postgres -d auth --single-transaction --exit-on-error \
    <"$BACKUP_DIR/barpath.dump"
  check_fingerprint barpath "$(jq -r .barpath_fingerprint "$BACKUP_DIR/manifest.json")" barpath barpath-postgresql auth

  unfreeze
  log "restore complete. Check a shared album link, a Zigbee device and a barpath login."
}

cmd_resume() {
  [[ -f $FREEZE_FILE ]] || { log "nothing to resume"; return 0; }
  FROZEN=true
  unfreeze
  log "resumed"
}

main() {
  local command="" positional=()
  while (($#)); do
    case "$1" in
      --context) CONTEXT=${2:?--context needs a value}; shift 2 ;;
      --dest) DEST=${2:?--dest needs a value}; shift 2 ;;
      --yes) ASSUME_YES=true; shift ;;
      --force) FORCE=true; shift ;;
      -h | --help | help) usage; exit 0 ;;
      -*) die "unknown option $1" ;;
      *)
        if [[ -z $command ]]; then command=$1; else positional+=("$1"); fi
        shift
        ;;
    esac
  done
  [[ -n $command ]] || { usage; exit 1; }
  ((${#positional[@]} <= 1)) || die "too many arguments"

  if [[ $command != verify ]]; then
    command -v kubectl >/dev/null || die "kubectl is not installed"
    [[ -n $CONTEXT ]] || CONTEXT=$(kubectl config current-context)
    [[ -n $CONTEXT ]] || die "no kubectl context"
    mkdir -p "$DEST"
    FREEZE_FILE="$DEST/.frozen-${CONTEXT//[^A-Za-z0-9_.-]/_}"
  fi

  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  case "$command" in
    backup) cmd_backup ;;
    verify) cmd_verify "${positional[@]}" ;;
    restore-secrets) cmd_restore_secrets "${positional[@]}" ;;
    restore) cmd_restore "${positional[@]}" ;;
    resume) cmd_resume ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
