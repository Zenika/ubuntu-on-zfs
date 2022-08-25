#!/usr/bin/env bash

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    # shellcheck disable=SC2034
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

log() {
  echo >&2 -e "${1-}"
}

log_info() {
  log "${BLUE}ℹ $1${NOFORMAT}"
}

log_success() {
  log "${GREEN}✅ $1${NOFORMAT}"
}

log_warning() {
  log "${ORANGE}⚠  $1${NOFORMAT}"
}

log_error() {
  log "${RED}🚨 $1${NOFORMAT}"
}

retry() {
  local tries=${1:-10}
  shift

  if [ "$tries" -le 0 ]; then
    tries=1
  fi

  local count=0
  local wait_seconds
  until "$@"; do
    exit=$?
    wait_seconds=$((2 ** count))
    if [ "$(((++count)))" -lt "$tries" ]; then
      log_warning "Attempt $count/$tries exited $exit, retrying in $wait_seconds seconds…"
      sleep $wait_seconds
    else
      log_error "Attempt $count/$tries exited $exit, no more attempt left."
      return $exit
    fi
  done
  return 0
}

setup_colors
