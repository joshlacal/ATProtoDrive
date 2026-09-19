#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ATProtoDrive"
BUNDLE_ID="blue.catbird.atprotodrive"
SCHEME="ATProtoDrive"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ATProtoDrive.xcodeproj"
DERIVED_DATA="${ATD_DERIVED_DATA:-$ROOT_DIR/.build/DerivedData}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
FIXTURE_PID_FILE="$DERIVED_DATA/atprotodrive-fixture.pid"

MODE="run"
FIXTURE=0

usage() {
  echo "usage: $0 [run|--verify|--logs|--telemetry|--debug] [--fixture]" >&2
}

for argument in "$@"; do
  case "$argument" in
    run)
      MODE="run"
      ;;
    --verify|verify)
      MODE="verify"
      ;;
    --logs|logs)
      MODE="logs"
      ;;
    --telemetry|telemetry)
      MODE="telemetry"
      ;;
    --debug|debug)
      MODE="debug"
      ;;
    --fixture|fixture)
      FIXTURE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

stop_fixture() {
  [[ -f "$FIXTURE_PID_FILE" ]] || return 0

  local pid executable
  pid="$(<"$FIXTURE_PID_FILE")"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ -n "$executable" && "$executable" -ef "$APP_EXECUTABLE" ]]; then
      /bin/kill "$pid" 2>/dev/null || true
    fi
  fi
  /bin/rm -f "$FIXTURE_PID_FILE"
}

stop_existing_app() {
  if (( FIXTURE )); then
    stop_fixture
  else
    /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  fi
}

build_app() {
  local -a build_arguments=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS"
    -derivedDataPath "$DERIVED_DATA"
  )
  if [[ -n "${ATD_CODE_SIGNING_ALLOWED:-}" ]]; then
    build_arguments+=("CODE_SIGNING_ALLOWED=$ATD_CODE_SIGNING_ALLOWED")
  fi

  /usr/bin/xcodebuild "${build_arguments[@]}" build

  if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "error: build succeeded but executable is missing: $APP_EXECUTABLE" >&2
    exit 1
  fi
}

launch_app() {
  if (( FIXTURE )); then
    local existing_pids launched_pids
    existing_pids="$(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)"
    /usr/bin/open -n --env ATPROTODRIVE_FIXTURE_MODE=public-browser "$APP_BUNDLE"

    local attempt pid seen
    for attempt in {1..50}; do
      launched_pids="$(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)"
      for pid in $launched_pids; do
        seen=0
        for existing_pid in $existing_pids; do
          if [[ "$pid" == "$existing_pid" ]]; then
            seen=1
            break
          fi
        done
        if (( ! seen )); then
          echo "$pid" >"$FIXTURE_PID_FILE"
          return 0
        fi
      done
      /bin/sleep 0.1
    done
    echo "error: fixture app launched, but its process could not be identified" >&2
    return 1
  fi

  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app() {
  local attempt
  for attempt in {1..50}; do
    if (( FIXTURE )); then
      if [[ -f "$FIXTURE_PID_FILE" ]] && /bin/kill -0 "$(<"$FIXTURE_PID_FILE")" 2>/dev/null; then
        echo "$APP_NAME fixture is running (PID $(<"$FIXTURE_PID_FILE"))"
        return 0
      fi
    elif /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
      echo "$APP_NAME is running"
      return 0
    fi
    /bin/sleep 0.1
  done
  echo "error: $APP_NAME did not remain running" >&2
  return 1
}

stop_existing_app
build_app

case "$MODE" in
  run)
    launch_app
    ;;
  verify)
    launch_app
    verify_app
    ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  telemetry)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  debug)
    if (( FIXTURE )); then
      /usr/bin/lldb -o "settings set target.env-vars ATPROTODRIVE_FIXTURE_MODE=public-browser" -o run -- "$APP_EXECUTABLE"
    else
      /usr/bin/lldb -o run -- "$APP_EXECUTABLE"
    fi
    ;;
esac
