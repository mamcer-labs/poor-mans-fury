#!/usr/bin/env bash
# pmf - Poor Man's Fury CLI
# Envuelve comandos de kubectl/vault ya existentes en un vocabulario simple.
set -euo pipefail

readonly SCOPES=(dev staging prod)
readonly REGISTRY="ghcr.io/mamcer-labs"
readonly VAULT_INIT_FILE="$HOME/secrets/vault-init.json"

usage() {
  cat <<'EOF'
pmf - Poor Man's Fury CLI

Uso:
  pmf deploy <app> <version> <scope>   Deployar una imagen a un scope
  pmf logs <app> <scope> [-f]          Ver logs (agregá -f para seguir en vivo)
  pmf status <app>                     Estado del deployment en todos los scopes
  pmf rollback <app> <scope>           Rollback al deploy anterior
  pmf scope list <app>                 En que scopes esta deployada la app
  pmf config get <app> <scope>         Ver la config de Vault de la app

Scopes validos: dev, staging, prod
EOF
}

die() {
  echo "pmf: $*" >&2
  exit 1
}

require_args() {
  local need="$1" have="$2" usage_line="$3"
  [[ "$have" -ge "$need" ]] || die "$usage_line"
}

valid_scope() {
  local scope="$1" s
  for s in "${SCOPES[@]}"; do
    [[ "$scope" == "$s" ]] && return 0
  done
  return 1
}

require_scope() {
  local scope="$1"
  valid_scope "$scope" || die "scope invalido '$scope' (valen: ${SCOPES[*]})"
}

deployment_exists() {
  local app="$1" scope="$2"
  kubectl get deployment "$app" -n "fury-$scope" >/dev/null 2>&1
}

cmd_deploy() {
  require_args 3 "$#" "uso: pmf deploy <app> <version> <scope>"
  local app="$1" version="$2" scope="$3"
  require_scope "$scope"
  deployment_exists "$app" "$scope" || die "no existe el deployment '$app' en fury-$scope"

  echo "Deployando $app:$version en fury-$scope..."
  kubectl set image "deployment/$app" "$app=$REGISTRY/$app:$version" -n "fury-$scope"
  kubectl rollout status "deployment/$app" -n "fury-$scope" --timeout=120s
}

cmd_logs() {
  require_args 2 "$#" "uso: pmf logs <app> <scope> [-f]"
  local app="$1" scope="$2"
  require_scope "$scope"
  deployment_exists "$app" "$scope" || die "no existe el deployment '$app' en fury-$scope"

  local follow_flag=()
  if [[ "${3:-}" == "-f" || "${3:-}" == "--follow" ]]; then
    follow_flag=(-f)
  fi

  kubectl logs -n "fury-$scope" -l "app=$app" -c "$app" --tail=100 "${follow_flag[@]}"
}

cmd_status() {
  require_args 1 "$#" "uso: pmf status <app>"
  local app="$1" scope
  printf "%-10s %-12s %-10s %s\n" "SCOPE" "READY" "STATUS" "IMAGEN"
  for scope in "${SCOPES[@]}"; do
    if deployment_exists "$app" "$scope"; then
      local ready image
      ready=$(kubectl get deployment "$app" -n "fury-$scope" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)
      image=$(kubectl get deployment "$app" -n "fury-$scope" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
      printf "%-10s %-12s %-10s %s\n" "$scope" "${ready:-?}" "up" "${image:-?}"
    else
      printf "%-10s %-12s %-10s %s\n" "$scope" "-" "no-deploy" "-"
    fi
  done
}

cmd_rollback() {
  require_args 2 "$#" "uso: pmf rollback <app> <scope>"
  local app="$1" scope="$2"
  require_scope "$scope"
  deployment_exists "$app" "$scope" || die "no existe el deployment '$app' en fury-$scope"

  kubectl rollout undo "deployment/$app" -n "fury-$scope"
  kubectl rollout status "deployment/$app" -n "fury-$scope" --timeout=120s
}

cmd_scope_list() {
  require_args 1 "$#" "uso: pmf scope list <app>"
  local app="$1" scope found=0
  for scope in "${SCOPES[@]}"; do
    if deployment_exists "$app" "$scope"; then
      echo "$scope"
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    die "'$app' no esta deployada en ningun scope"
  fi
}

cmd_config_get() {
  require_args 2 "$#" "uso: pmf config get <app> <scope>"
  local app="$1" scope="$2"
  require_scope "$scope"
  [[ -f "$VAULT_INIT_FILE" ]] || die "no encuentro $VAULT_INIT_FILE (root token de Vault)"

  local sealed
  sealed=$(kubectl exec -n fury-infra vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || true)
  if [[ "$sealed" != "false" ]]; then
    die "Vault no responde o esta sellado. Unseal: kubectl exec -n fury-infra vault-0 -- vault operator unseal \$(jq -r '.unseal_keys_b64[0]' $VAULT_INIT_FILE)"
  fi

  local root_token
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
  kubectl exec -n fury-infra vault-0 -- env VAULT_TOKEN="$root_token" \
    vault kv get -format=json "fury/apps/$app/$scope/config" | jq '.data.data'
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local sub="$1"
  shift

  case "$sub" in
    deploy)   cmd_deploy "$@" ;;
    logs)     cmd_logs "$@" ;;
    status)   cmd_status "$@" ;;
    rollback) cmd_rollback "$@" ;;
    scope)
      [[ "${1:-}" == "list" ]] || die "uso: pmf scope list <app>"
      shift
      cmd_scope_list "$@"
      ;;
    config)
      [[ "${1:-}" == "get" ]] || die "uso: pmf config get <app> <scope>"
      shift
      cmd_config_get "$@"
      ;;
    -h|--help|help) usage ;;
    *) die "comando desconocido '$sub' (pmf --help)" ;;
  esac
}

main "$@"
