#!/usr/bin/env bash
# TechStream — Chaos Script (Shell)
# Artificially injects failures into the web server to test the self-healing pipeline.
#
# Usage:
#   bash chaos.sh --mode errors          # 60% HTTP 500 errors
#   bash chaos.sh --mode cpu             # CPU spike via stress-ng
#   bash chaos.sh --mode latency         # High latency injection
#   bash chaos.sh --mode full            # All of the above
#   bash chaos.sh --stop                 # Restore normal operation
#   bash chaos.sh --traffic              # Generate traffic only (no chaos)

set -uo pipefail

# ── Config — update for your environment ─────────────────────────────────────
APP_URL="http://localhost:5000"
AWS_REGION="us-east-1"
NAMESPACE="TechStream/App"
CHAOS_DURATION=300

# ── Parse arguments ───────────────────────────────────────────────────────────
MODE=""
STOP=false
TRAFFIC_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)     MODE="$2";           shift 2 ;;
    --stop)     STOP=true;           shift   ;;
    --traffic)  TRAFFIC_ONLY=true;   shift   ;;
    --duration) CHAOS_DURATION="$2"; shift 2 ;;
    --url)      APP_URL="$2";        shift 2 ;;
    *) echo "Unknown argument: $1" >&2; shift ;;
  esac
done

# ── Logging helpers ───────────────────────────────────────────────────────────
log()  { echo "$(date '+%Y-%m-%d %H:%M:%S')  INFO   $*"; }
warn() { echo "$(date '+%Y-%m-%d %H:%M:%S')  WARN   $*" >&2; }
err()  { echo "$(date '+%Y-%m-%d %H:%M:%S')  ERROR  $*" >&2; }

# ── CloudWatch metric publish ─────────────────────────────────────────────────
publish_metric() {
  local name="$1" value="$2"
  aws cloudwatch put-metric-data \
    --region     "$AWS_REGION" \
    --namespace  "$NAMESPACE" \
    --metric-name "$name" \
    --value       "$value" \
    --unit        None \
    --dimensions  Name=Service,Value=techstream-api 2>/dev/null \
    || warn "Could not publish metric $name=$value"
}

# ── Chaos control ─────────────────────────────────────────────────────────────
enable_errors() {
  local error_rate="${1:-0.6}" latency_ms="${2:-0}"
  local response
  response=$(curl -sf -X POST "$APP_URL/chaos/enable" \
    -H 'Content-Type: application/json' \
    -d "{\"error_rate\":$error_rate,\"latency_ms\":$latency_ms}" 2>/dev/null) \
    || { err "Could not reach app server at $APP_URL"; return 1; }
  log "Error chaos enabled: $response"
}

enable_latency() {
  enable_errors 0.1 2000
  log "Latency chaos enabled: 2000ms added to every request"
}

disable_chaos() {
  curl -sf -X POST "$APP_URL/chaos/disable" > /dev/null 2>&1 \
    && log "Chaos disabled — system restored" \
    || warn "Could not reach app server"
  publish_metric CPUChaosActive       0
  publish_metric ErrorRateChaosActive 0
}

# ── CPU spike ─────────────────────────────────────────────────────────────────
CPU_PIDS=()

spike_cpu() {
  local duration="${1:-120}"
  local cores; cores=$(nproc 2>/dev/null || echo 1)

  if command -v stress-ng &>/dev/null; then
    warn "Spiking CPU with $cores workers for ${duration}s (stress-ng)"
    stress-ng --cpu "$cores" --timeout "${duration}s" &
    CPU_PIDS+=($!)
  else
    warn "stress-ng not found — using shell CPU burn ($cores subshells)"
    for _ in $(seq 1 "$cores"); do
      ( end=$(( SECONDS + duration )); while [[ $SECONDS -lt $end ]]; do :; done ) &
      CPU_PIDS+=($!)
    done
  fi
  publish_metric CPUChaosActive 1
}

stop_cpu() {
  for pid in "${CPU_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  CPU_PIDS=()
}

# ── Traffic generation ────────────────────────────────────────────────────────
generate_traffic() {
  local duration="${1:-60}" rps="${2:-20}"
  local delay; delay=$(awk "BEGIN{printf \"%.3f\", 1/$rps}")
  log "Generating ~${rps} req/s for ${duration}s against $APP_URL"

  local end=$(( SECONDS + duration ))
  local total=0 errors=0

  while [[ $SECONDS -lt $end ]]; do
    local code
    code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
           "$APP_URL/api/data" 2>/dev/null || echo "000")
    total=$(( total + 1 ))
    if [[ "$code" == "000" ]] || [[ "$code" -ge 500 ]]; then
      errors=$(( errors + 1 ))
    fi
    sleep "$delay" 2>/dev/null || sleep 0.05
  done

  local error_pct=0
  [[ $total -gt 0 ]] && error_pct=$(( errors * 100 / total ))
  log "Traffic done — $total reqs | $errors errors | ${error_pct}% error rate"

  publish_metric ErrorRate    "$error_pct"
  publish_metric RequestCount "$total"
}

# ── Full end-to-end chaos scenario ────────────────────────────────────────────
run_full() {
  echo "============================================================"
  echo " STARTING FULL CHAOS SCENARIO"
  echo "============================================================"

  log "Phase 1: Generating 30s of clean baseline traffic..."
  generate_traffic 30 10

  log "Phase 2: Injecting chaos — 60% errors + 500ms latency..."
  enable_errors 0.6 500
  publish_metric ErrorRateChaosActive 1

  log "Phase 3: Spiking CPU + generating chaotic traffic for ${CHAOS_DURATION}s..."
  spike_cpu "$CHAOS_DURATION"
  generate_traffic "$CHAOS_DURATION" 15

  log "Phase 4: Stopping chaos..."
  stop_cpu
  disable_chaos

  log "Phase 5: Generating 30s of post-recovery traffic to verify..."
  generate_traffic 30 10

  echo "============================================================"
  echo " CHAOS SCENARIO COMPLETE — check CloudWatch dashboard"
  echo "============================================================"
}

# ── Cleanup on exit ───────────────────────────────────────────────────────────
trap 'stop_cpu' EXIT INT TERM

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ "$STOP" == true ]]; then
  disable_chaos

elif [[ "$TRAFFIC_ONLY" == true ]]; then
  generate_traffic "$CHAOS_DURATION"

elif [[ "$MODE" == "errors" ]]; then
  log "Injecting HTTP 500 errors (60% error rate)..."
  enable_errors 0.6
  generate_traffic "$CHAOS_DURATION" 15

elif [[ "$MODE" == "cpu" ]]; then
  log "Spiking CPU for ${CHAOS_DURATION}s..."
  spike_cpu "$CHAOS_DURATION"
  wait "${CPU_PIDS[@]}" 2>/dev/null || true

elif [[ "$MODE" == "latency" ]]; then
  log "Injecting high latency (2000ms)..."
  enable_latency
  generate_traffic "$CHAOS_DURATION" 15

elif [[ "$MODE" == "full" ]]; then
  run_full

else
  echo "Usage: $0 --mode <errors|cpu|latency|full> [options]"
  echo ""
  echo "Options:"
  echo "  --mode <errors|cpu|latency|full>  Chaos mode to activate"
  echo "  --stop                            Stop all chaos"
  echo "  --traffic                         Generate traffic only (no chaos)"
  echo "  --duration <seconds>              Duration (default: 300)"
  echo "  --url <url>                       App server URL (default: http://localhost:5000)"
  exit 1
fi
