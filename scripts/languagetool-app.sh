#!/usr/bin/env bash
# LanguageTool local lifecycle: Docker HTTP API, sync-safe update, config backups.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_FILE="${LANGUAGETOOL_APP_CONFIG:-$ROOT/scripts/languagetool-app.env}"
SYNC_SCRIPT="$ROOT/scripts/sync-upstream.sh"
COMPOSE_DIR="$ROOT/docker/compose"

BACKUP_DIR="${BACKUP_DIR:-$ROOT/../languagetool-backups}"
BACKUP_INTERVAL_DAYS="${BACKUP_INTERVAL_DAYS:-30}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
LANGUAGETOOL_PORT="${LANGUAGETOOL_PORT:-8010}"
LANGUAGETOOL_IMAGE="${LANGUAGETOOL_IMAGE:-erikvl87/languagetool:latest}"
Java_Xms="${Java_Xms:-256m}"
Java_Xmx="${Java_Xmx:-512m}"
UPDATE_SYNC_ON_UPDATE="${UPDATE_SYNC_ON_UPDATE:-true}"

usage() {
  cat <<'EOF'
Usage: scripts/languagetool-app.sh <command> [options]

Commands:
  setup                 Detect capabilities; write env from example
  start                 Start LanguageTool HTTP server (Docker)
  stop                  Stop containers (keeps volumes/data)
  down                  Remove containers (never uses -v)
  status                Show stack, API probe, backup status
  check [text...]       POST /v2/check (default sample English sentence)
  backup                Snapshot local env + compose into BACKUP_DIR
  backup --if-due       Backup only if last one is older than BACKUP_INTERVAL_DAYS
  update                Backup (if due) → optional git sync → pull & recreate
  schedule-hint         Print LaunchAgent / cron hints
  help                  Show this help

Update options:
  --sync / --no-sync    Force or skip git sync with upstream
  --backup / --no-backup Force or skip pre-update backup
  --rebase              When syncing, rebase instead of merge

Config:
  Copy scripts/languagetool-app.env.example → scripts/languagetool-app.env
EOF
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "warning: $*" >&2; }

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
  fi
  if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$ROOT/$BACKUP_DIR"
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
  docker info >/dev/null 2>&1 || die "docker is not running (start Docker Desktop)"
}

ensure_runtime_files() {
  mkdir -p "$COMPOSE_DIR/ngrams"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    info "writing $CONFIG_FILE from example"
    cp "$ROOT/scripts/languagetool-app.env.example" "$CONFIG_FILE"
  fi
  if [[ ! -f "$COMPOSE_DIR/docker-compose.override.yml" ]]; then
    info "creating docker/compose/docker-compose.override.yml (localhost bind on ${LANGUAGETOOL_PORT})"
    cat >"$COMPOSE_DIR/docker-compose.override.yml" <<EOF
# Local-only override (gitignored). Bind API to localhost.
services:
  languagetool:
    ports: !override
      - "127.0.0.1:${LANGUAGETOOL_PORT}:8010"
EOF
  fi
}

compose() {
  (
    cd "$COMPOSE_DIR"
    export LANGUAGETOOL_PORT LANGUAGETOOL_IMAGE Java_Xms Java_Xmx
    local args=(-f "./$COMPOSE_FILE")
    if [[ -f ./docker-compose.override.yml ]]; then
      args+=(-f ./docker-compose.override.yml)
    fi
    docker compose "${args[@]}" "$@"
  )
}

api_url() {
  echo "http://127.0.0.1:${LANGUAGETOOL_PORT}/v2/check"
}

probe_api() {
  local code
  code="$(curl -sS -o /tmp/languagetool-check.json -w "%{http_code}" \
    --data-urlencode "language=en-US" \
    --data-urlencode "text=This are wrong." \
    "$(api_url)" 2>/dev/null || echo fail)"
  if [[ "$code" == "200" ]]; then
    local n
    n="$(python3 -c 'import json;print(len(json.load(open("/tmp/languagetool-check.json")).get("matches",[])))' 2>/dev/null || echo "?")"
    echo "API: ok $(api_url) ($n match(es) on sample)"
    return 0
  fi
  echo "API: probe failed (HTTP $code) at $(api_url)"
  return 1
}

cmd_setup() {
  load_config
  ensure_runtime_files
  load_config

  echo "Capability detection (languagetool-org/languagetool):"
  echo "  Telemetry: not applicable (self-hosted HTTP server; no app OTEL)"
  echo "  LLM: not applicable"
  echo "  Search: not applicable"
  echo
  echo "Runtime:"
  echo "  Image: $LANGUAGETOOL_IMAGE"
  echo "  API:   $(api_url)"
  echo "  Compose: docker/compose/$COMPOSE_FILE"
  echo "  Optional n-grams: place under docker/compose/ngrams/ and enable volume in compose"
}

cmd_start() {
  load_config
  require_docker
  ensure_runtime_files
  load_config
  info "starting LanguageTool ($LANGUAGETOOL_IMAGE) on 127.0.0.1:${LANGUAGETOOL_PORT}"
  compose up -d
  info "waiting for API..."
  local i
  for i in $(seq 1 40); do
    if probe_api >/dev/null 2>&1; then
      probe_api
      info "ready — example: ./scripts/languagetool-app.sh check 'This are wrong.'"
      return 0
    fi
    sleep 2
  done
  compose ps || true
  die "API did not become ready; try: docker logs languagetool"
}

cmd_stop() {
  load_config
  require_docker
  if [[ ! -f "$COMPOSE_DIR/$COMPOSE_FILE" ]]; then
    info "no compose file; nothing to stop"
    return 0
  fi
  info "stopping (containers kept; no volume wipe)"
  compose stop
}

cmd_down() {
  load_config
  require_docker
  info "removing containers (never -v)"
  compose down --remove-orphans
}

cmd_status() {
  load_config
  echo "root:     $ROOT"
  echo "compose:  docker/compose/$COMPOSE_FILE"
  echo "image:    $LANGUAGETOOL_IMAGE"
  echo "port:     $LANGUAGETOOL_PORT"
  echo "backups:  $BACKUP_DIR"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    compose ps 2>/dev/null || true
    probe_api || true
  else
    echo "docker:   not running"
  fi
  if [[ -f "$BACKUP_DIR/.languagetool-backup-complete" ]]; then
    local last age
    last="$(cat "$BACKUP_DIR/.languagetool-backup-complete")"
    age=$(( ($(date +%s) - last) / 86400 ))
    echo "last backup: ${age}d ago"
  else
    echo "last backup: none"
  fi
}

cmd_check() {
  load_config
  local text="${*:-This are wrong.}"
  curl -sS \
    --data-urlencode "language=en-US" \
    --data-urlencode "text=$text" \
    "$(api_url)" | python3 -m json.tool
}

last_backup_stamp() {
  local marker="$BACKUP_DIR/.languagetool-backup-complete"
  [[ -f "$marker" ]] || return 1
  cat "$marker"
}

cmd_backup() {
  load_config
  local if_due=false
  [[ "${1:-}" == "--if-due" ]] && if_due=true

  if [[ "$if_due" == true ]]; then
    local last now age
    last="$(last_backup_stamp || echo 0)"
    now="$(date +%s)"
    age=$(( (now - last) / 86400 ))
    if [[ "$age" -lt "$BACKUP_INTERVAL_DAYS" ]]; then
      info "backup not due (last ${age}d ago; interval ${BACKUP_INTERVAL_DAYS}d)"
      return 0
    fi
  fi

  mkdir -p "$BACKUP_DIR"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"
  info "backing up to $dest"
  [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$dest/"
  [[ -f "$COMPOSE_DIR/$COMPOSE_FILE" ]] && cp "$COMPOSE_DIR/$COMPOSE_FILE" "$dest/"
  [[ -f "$COMPOSE_DIR/docker-compose.override.yml" ]] && cp "$COMPOSE_DIR/docker-compose.override.yml" "$dest/"
  # Server is mostly stateless; snapshot optional n-gram dir metadata only (not multi-GB data)
  if [[ -d "$COMPOSE_DIR/ngrams" ]]; then
    du -sh "$COMPOSE_DIR/ngrams" >"$dest/ngrams-size.txt" 2>/dev/null || true
    find "$COMPOSE_DIR/ngrams" -maxdepth 2 -type d >"$dest/ngrams-dirs.txt" 2>/dev/null || true
  fi
  git -C "$ROOT" rev-parse HEAD >"$dest/git-HEAD.txt" 2>/dev/null || true
  date +%s >"$BACKUP_DIR/.languagetool-backup-complete"
  local keep="$BACKUP_KEEP"
  ls -1dt "$BACKUP_DIR"/20* 2>/dev/null | tail -n +"$((keep + 1))" | while read -r old; do
    info "pruning $old"
    rm -rf "$old"
  done
  info "backup complete"
}

cmd_update() {
  load_config
  local do_sync="$UPDATE_SYNC_ON_UPDATE"
  local do_backup=true
  local rebase=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync) do_sync=true ;;
      --no-sync) do_sync=false ;;
      --backup) do_backup=true ;;
      --no-backup) do_backup=false ;;
      --rebase) rebase=true ;;
      *) die "unknown update option: $1" ;;
    esac
    shift
  done

  [[ "$do_backup" == true ]] && cmd_backup --if-due
  if [[ "$do_sync" == true ]]; then
    if [[ "$rebase" == true ]]; then
      "$SYNC_SCRIPT" sync --rebase
    else
      "$SYNC_SCRIPT" sync
    fi
  fi
  require_docker
  ensure_runtime_files
  info "pulling image and recreating (no -v)"
  compose pull
  compose up -d --force-recreate
  probe_api || warn "API probe failed after update"
  info "update complete"
}

cmd_schedule_hint() {
  load_config
  cat <<EOF
# Monthly LaunchAgent (Day=1 03:15) — adjust Label/paths; never hardcode a username:
# ProgramArguments: $ROOT/scripts/languagetool-app.sh backup
# WorkingDirectory: $ROOT
# Or cron: 15 3 1 * * $ROOT/scripts/languagetool-app.sh backup >> $BACKUP_DIR/backup.log 2>&1
EOF
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true
  case "$cmd" in
    -h|--help|help) usage ;;
    setup) cmd_setup ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    down) cmd_down ;;
    status) cmd_status ;;
    check) cmd_check "$@" ;;
    backup) cmd_backup "$@" ;;
    update) cmd_update "$@" ;;
    schedule-hint) cmd_schedule_hint ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
