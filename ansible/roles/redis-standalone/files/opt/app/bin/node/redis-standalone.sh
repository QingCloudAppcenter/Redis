init() {
  mkdir -p /data/redis/logs
  chown -R redis.svc /data/redis
  chown -R syslog.svc /data/redis/logs
  mkdir -p /data/caddy && chown -R caddy.svc /data/caddy
  local htmlFile=/data/index.html
  [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _init
}

start() {
  local initFlag
  isInitialized || {
    initFlag="--init"
    execute init
  }
  applyConfigFiles $initFlag
  applySentinelConfigFile $initFlag
  setUpVip $initFlag
  _start
}

stop() {
  stopSvc redis-sentinel
  if isSvcEnabled redis-sentinel; then
    # waiting for all sentinels to stop to avoid unwanted redis leader switch
    local sentinelHost; for sentinelHost in $REDIS_NODES; do
      retry 15 1 0 checkSentinelStopped ${sentinelHost##*/}
    done
  fi

  _stop
}

revive() {
  _revive $@
  checkVip || setUpVip
}

preScaleIn() {
  [ -n "$LEAVING_REDIS_NODES" ]
  local master; master="$(findCurrentMaster)"
  if [[ "$LEAVING_REDIS_NODES " == *"/$master "* ]]; then
    return 210
  fi
}

determineInitialMaster() {
  local firstRedisNode=${REDIS_NODES%% *}
  echo -n ${firstRedisNode##*/}
}

runtimeSentinelFile=/data/redis/sentinel.conf
findCurrentMaster() {
  if isSvcEnabled redis-sentinel && [ -f "$runtimeSentinelFile" ]; then
    awk '$2=="monitor" && $3=="master" {print $4}' $runtimeSentinelFile
  else
    determineInitialMaster
  fi
}

findCurrentMasterNodeId() {
  local masterIp; masterIp="$(findCurrentMaster)"
  echo $REDIS_NODES | xargs -n1 | awk -F/ '$3=="'$masterIp'" {print $2}'
}

# <master-name> <role> <state> <from-ip> <from-port> <to-ip> <to-port>
failover() {
  log "master changed: '$@'."
  setUpVip
}

checkVip() {
  local vipResponse
  vipResponse="$(timeout --preserve-status 3 /opt/redis/current/redis-cli -h $REDIS_VIP --no-auth-warning -a "$REDIS_PASSWORD" ROLE | sed -n '1{p;q}')"
  [ "$vipResponse" == "master" ]
}

setUpVip() {
  local masterIp; masterIp="$(findCurrentMaster $1)"
  log "DEBUG setting up: [master=$masterIp me=$MY_IP] ..."
  [ -n "$masterIp" ]
  if [ "$MY_IP" == "$masterIp" ]; then
    bindVip
  else
    unbindVip
  fi
}

bindVip() {
  local allIps; allIps="$(hostname -I)"
  log "[DEBUG] binding: [all=$allIps vip=$REDIS_VIP] ..."
  if [[ " $allIps " != *" $REDIS_VIP "* ]]; then
    log "[DEBUG] All of my IPs: '$allIps'. Binding VIP ..."
    ip addr add $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: already bound
    arping -q -c 3 -A $REDIS_VIP -I eth0
  fi
}

unbindVip() {
  local allIps; allIps="$(hostname -I)"
  log "[DEBUG] unbinding: [all=$allIps vip=$REDIS_VIP] ..."
  if [[ " $allIps " == *" $REDIS_VIP "* ]]; then
    log "[DEBUG] All of my IPs: '$allIps'. Unbinding VIP ..."
    ip addr del $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: not bound
  fi
}

mergeConfigFiles() {
  awk '(NF>2) ? !a[$1 $2]++ : !a[$1]++' $@
}

checkSentinelStopped() {
  ! nc -z -w3 $1 26379
}

encodeCmd() {
  echo -n ${1?command is required}${CLUSTER_ID} | sha256sum | cut -d' ' -f1
}

rootConfDir=/opt/app/conf/redis-standalone
managedConfigFile=$rootConfDir/redis.managed.conf
changedConfigFile=$rootConfDir/redis.changed.conf
defaultConfigFile=$rootConfDir/redis.default.conf
initialConfigFile=$rootConfDir/redis.initial.conf
runtimeConfigFile=/data/redis/redis.conf

update() {
  if [ "$1" == "redis-server" ]; then
    isInitialized || return 0
    execute restart
  else
    _update $@
  fi
}

applyConfigFiles() {
  if [ "$1" == "--init" ]; then
    local masterIp="$(determineInitialMaster)"
    [ "$MY_IP" == "$masterIp" ] || echo "SLAVEOF $masterIp $REDIS_PORT" > $initialConfigFile
    sudo -u redis touch $runtimeConfigFile
  else
    > $initialConfigFile # avoid switching master to slave unwanted
  fi
  cp $runtimeConfigFile $runtimeConfigFile.bak
  mergeConfigFiles $managedConfigFile $changedConfigFile $runtimeConfigFile.bak $defaultConfigFile $initialConfigFile > $runtimeConfigFile
}

applySentinelConfigFile() {
  local monitorSentinelFile=$rootConfDir/sentinel.monitor.conf
  local centralSentinelFile=$rootConfDir/sentinel.central.conf
  local changedSentinelFile=$rootConfDir/sentinel.changed.conf
  if [ "$1" == "--init" ]; then
    local masterIp="$(determineInitialMaster)"
    echo "sentinel monitor master $masterIp $REDIS_PORT 2" > $monitorSentinelFile
    sudo -u redis touch $runtimeSentinelFile
  else
    awk '$2=="monitor" && $3=="master"' $runtimeConfigFile > $monitorSentinelFile
  fi
  cp $runtimeSentinelFile $runtimeSentinelFile.bak
  awk '!a[$2 $3 $4]++' $centralSentinelFile $monitorSentinelFile $changedSentinelFile $runtimeSentinelFile.bak > $runtimeSentinelFile
}
