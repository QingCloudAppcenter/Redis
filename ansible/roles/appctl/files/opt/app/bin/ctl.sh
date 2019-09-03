#!/usr/bin/env bash

# Default hook functions named starting with _, e.g. _init(), _start(), etc.
# Specific roles can override the default hooks like:
#   start() {
#     _start
#     ...
#   }
#
# Specific hooks will be executed if exist, otherwise the default ones.

# Error codes
EC_CHECK_INACTIVE=200
EC_CHECK_PORT_ERR=201
EC_CHECK_PROTO_ERR=202

command=$1
args="${@:2}"

log() {
  if [ "$1" == "--debug" ]; then
    [ "$APPCTL_ENV" == "dev" ] || return 0
    shift
  fi

  logger -t appctl --id=$$ -- "[cmd=$command args='$args'] $@"
}

retry() {
  local tried=0
  local maxAttempts=$1
  local interval=$2
  local stopCode=$3
  local cmd="${@:4}"
  local retCode=0
  while [ $tried -lt $maxAttempts ]; do
    $cmd && return 0 || {
      retCode=$?
      if [ "$retCode" = "$stopCode" ]; then
        log "'$cmd' returned with stop code $stopCode. Stopping ..." && return $retCode
      fi
    }
    sleep $interval
    tried=$((tried+1))
  done

  log "'$cmd' still returned errors after $tried attempts. Stopping ..." && return $retCode
}

rotate() {
  local maxFilesCount=5
  for path in $@; do
    for i in $(seq 1 $maxFilesCount | tac); do
      if [ -f "${path}.$i" ]; then mv ${path}.$i ${path}.$(($i+1)); fi
    done
    if [ -f "$path" ]; then cp $path ${path}.1; fi
  done
}

execute() {
  local cmd=$1; log --debug "Executing command ..."
  [ "$(type -t $cmd)" = "function" ] || cmd=_$cmd
  $cmd ${@:2}
}

applyEnvFiles() {
  local envFile; for envFile in $(find /opt/app/bin/envs -name "*.env"); do . $envFile; done
}

applyRoleScripts() {
  local scriptFile=/opt/app/bin/node/$NODE_CTL.sh
  if [ -f "$scriptFile" ]; then . $scriptFile; fi
}

getServices() {
  if [ "$1" = "-a" ]; then
    echo $SERVICES
  else
    echo $SERVICES | xargs -n1 | awk -F/ '$2=="true"'
  fi
}

isSvcEnabled() {
  local svc="${1%%/*}"
  [ "$(echo $(getServices -a) | xargs -n1 | awk -F/ '$1=="'$svc'" {print $2}')" = "true" ]
}

checkActive() {
  systemctl is-active -q $1
}

checkEndpoint() {
  local host=$MY_IP proto=${1%:*} port=${1#*:}
  if [ "$proto" = "tcp" ]; then
    nc -z -w5 $host $port
  elif [ "$proto" = "udp" ]; then
    nc -z -u -q5 -w5 $host $port
  elif [ "$proto" = "http" ]; then
    local code="$(curl -s -o /dev/null -w "%{http_code}" $host:$port)"
    [[ "$code" =~ ^(200|302|401|403|404)$ ]]
  else
    return $EC_CHECK_PROTO_ERR
  fi
}

isNodeInitialized() {
  local svcs="$(getServices -a)"
  [ "$(systemctl is-enabled ${svcs%%/*})" == "disabled" ]
}

initSvc() {
  systemctl unmask -q ${1%%/*}
}

checkSvc() {
  checkActive ${1%%/*} || {
    log "Service '$1' is inactive."
    return $EC_CHECK_INACTIVE
  }
  local endpoints=$(echo $1 | awk -F/ '{print $3}')
  local endpoint; for endpoint in ${endpoints//,/ }; do
    checkEndpoint $endpoint || {
      log "Endpoint '$endpoint' is unreachable."
      return $EC_CHECK_PORT_ERR
    }
  done
}

startSvc() {
  systemctl start ${1%%/*}
}

stopSvc() {
  systemctl stop ${1%%/*}
}

restartSvc() {
  stopSvc $1 && startSvc $1
}

### app management

_initNode() {
  rm -rf /data/lost+found
  install -d -o syslog -g svc /data/appctl/logs
  local svc; for svc in $(getServices -a); do initSvc $svc; done
}

_revive() {
  local svc; for svc in $(getServices); do
    if [ "$1" == "--check-only" ]; then
      checkSvc $svc
    else
      checkSvc $svc || restartSvc $svc || log "ERROR: failed to restart '$svc' ($?)."
    fi
  done
}

_check() {
  execute revive --check-only
}

_start() {
  isNodeInitialized || {
    execute initNode
    systemctl restart rsyslog # output to log files under /data
  }
  local svc; for svc in $(getServices); do startSvc $svc; done
}

_stop() {
  log "Stopping all services ..."
  local svc; for svc in $(getServices -a | xargs -n1 | tac); do stopSvc $svc; done
}

_restart() {
  execute stop && execute start
}

_reload() {
  if ! isNodeInitialized; then return 0; fi # only reload after initialized
  local svcs="${@:-$(getServices -a)}"
  local svc; for svc in $(echo $svcs | xargs -n1 | tac); do stopSvc $svc; done
  local svc; for svc in $svcs; do
    if isSvcEnabled $svc; then startSvc $svc; fi
  done
}

applyEnvFiles
applyRoleScripts

set -eo pipefail

execute $command $args
