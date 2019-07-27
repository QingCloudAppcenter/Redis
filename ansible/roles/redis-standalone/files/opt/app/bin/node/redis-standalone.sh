init() {
  install -d -o redis -g svc /data/redis; install -d -o syslog -g svc /data/redis/logs
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _init
}

start() {
  isInitialized || execute init
  configure
  _start
}

stop() {
  if [ -z "$LEAVING_REDIS_NODES" ] && isSvcEnabled redis-sentinel; then
    stopSvc redis-sentinel
    local sentinelHost; for sentinelHost in $REDIS_NODES; do
      retry 15 1 0 checkSentinelStopped ${sentinelHost##*/} || log "WARN: sentinel '$sentinelHost' is still up."
    done
  fi

  _stop
}

revive() {
  _revive $@
  checkVip || setUpVip
}

measure() {
  runRedisCmd info all | awk -F: 'BEGIN {
    g["hash_based_count"] = "^h"
    g["list_based_count"] = "^(bl|br|l|rp)"
    g["set_based_count"] = "^s[^e]"
    g["sorted_set_based_count"] = "^(bz|z)"
    g["stream_based_count"] = "^x"
    g["key_based_count"] = "^(del|dump|exists|expire|expireat|keys|migrate|move|object|persist|pexpire|pexpireat|pttl|randomkey|rename|renamenx|restore|sort|touch|ttl|type|unlink|wait|scan)"
    g["string_based_count"] = "^(append|bitcount|bitfield|bitop|bitpos|decr|decrby|get|getbit|getrange|getset|incr|incrby|incrbyfloat|mget|mset|msetnx|psetex|set|setbit|setex|setnx|setrange|strlen)"
    g["set_count"] = "^(getset|hmset|hset|hsetnx|lset|mset|msetnx|psetex|set|setbit|setex|setnx|setrange)"
    g["get_count"] = "^(get|getbit|getrange|getset|hget|hgetall|hmget|mget)"
  }
  {
    if($1~/^(cmdstat_|connected_c|db|evicted_|expired_k|keyspace_|maxmemory$|role|total_conn|used_memory$)/) {
      r[$1] = gensub(/^(keys=|calls=)?([0-9]+).*/, "\\2", 1, $2);
    }
  }
  END {
    for(k in r) {
      if(k~/^cmdstat_/) {
        cmd = gensub(/^cmdstat_/, "", 1, k)
        for(regexp in g) {
          if(cmd ~ g[regexp]) {
            m[regexp] += r[k]
          }
        }
      } else if(k~/^db[0-9]+/) {
        m["key_count"] += r[k]
      } else if(k!~/^(used_memory|maxmemory|connected_c)/) {
        m[k=="role" ? "node_role" : k] = gensub("\r", "", 1, r[k])
      }
    }
    memUsage = r["maxmemory"] ? 10000 * r["used_memory"] / r["maxmemory"] : 0
    m["memory_usage_min"] = m["memory_usage_avg"] = m["memory_usage_max"] = memUsage
    totalOpsCount = r["keyspace_hits"] + r["keyspace_misses"]
    m["hit_rate_min"] = m["hit_rate_avg"] = m["hit_rate_max"] = totalOpsCount ? 10000 * r["keyspace_hits"] / totalOpsCount : 0
    m["connected_clients_min"] = m["connected_clients_avg"] = m["connected_clients_max"] = r["connected_clients"]
    for(k in m) print k FS m[k]
  }' | jq -R 'split(":")|{(.[0]):.[1]}' | jq -sc add || ( local rc=$?; log "Failed to measure Redis: $metrics" && return $rc )
}

preScaleIn() {
  [ -n "$LEAVING_REDIS_NODES" ] || return 210
  local master; master="$(findMasterIp)" || return 211
  if [[ "$LEAVING_REDIS_NODES " == *"/$master "* ]]; then return 212; fi
}

destroy() {
  preScaleIn && execute stop
  checkVip || ( execute start && return 213 )
}

scaleIn() {
  stopSvc redis-sentinel && rm -f $runtimeSentinelFile*
}

# edge case: 4.0.9 flushall -> 5.0.5 -> backup -> restore rename flushall
restore() {
  find /data/redis -mindepth 1 ! -name appendonly.aof -delete
  execute start
}

runtimeSentinelFile=/data/redis/sentinel.conf
findMasterIp() {
  local firstRedisNode=${REDIS_NODES%% *}
  isSvcEnabled redis-sentinel && [ -f "$runtimeSentinelFile" ] \
    && awk 'BEGIN {rc=1} $0~/^sentinel monitor master / {print $4; rc=0} END {exit rc}' $runtimeSentinelFile \
    || echo -n ${firstRedisNode##*/}
}

findMasterNodeId() {
  echo $REDIS_NODES | xargs -n1 | awk -F/ '$3=="'$(findMasterIp)'" {print $2}'
}

runRedisCmd() {
  local redisIp=$MY_IP; if [ "$1" == "--vip" ]; then redisIp=$REDIS_VIP && shift; fi
  timeout --preserve-status 5s /opt/redis/current/redis-cli -h $redisIp --no-auth-warning -a '$REDIS_PASSWORD' $@
}

checkVip() {
  local vipResponse; vipResponse="$(runRedisCmd --vip ROLE | sed -n '1{p;q}')"
  [ "$vipResponse" == "master" ]
}

setUpVip() {
  local masterIp; masterIp="${1:-$(findMasterIp)}"
  local myIps; myIps="$(hostname -I)"
  log --debug "setting up vip: [master=$masterIp me=$myIps] ..."
  if [ "$MY_IP" == "$masterIp" ]; then
    [[ " $myIps " == *" $REDIS_VIP "* ]] || bindVip
  else
    [[ " $myIps " != *" $REDIS_VIP "* ]] || unbindVip
  fi
}

bindVip() {
  ip addr add $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: already bound
  arping -q -c 3 -A $REDIS_VIP -I eth0
}

unbindVip() {
  ip addr del $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: not bound
}

checkSentinelStopped() {
  ! nc -z -w3 $1 26379
}

encodeCmd() {
  echo -n ${1?command is required}${CLUSTER_ID} | sha256sum | cut -d' ' -f1
}

nodesFile=/data/redis/nodes
rootConfDir=/opt/app/conf/redis-standalone
changedConfigFile=$rootConfDir/redis.changed.conf
changedSentinelFile=$rootConfDir/sentinel.changed.conf
reload() {
  isInitialized || return 0

  if [ -n "${JOINING_REDIS_NODES}" ]; then
    log --debug "scaling out ..."
    configure && startSvc redis-sentinel
  elif [ -n "${LEAVING_REDIS_NODES}" ]; then
    log --debug "scaling in ..."
  elif checkFileChanged $nodesFile; then
    log --debug "changing network ..."
  elif checkFileChanged $changedConfigFile; then
    execute restart
  elif checkFileChanged $changedSentinelFile; then
    _update redis-sentinel
  fi
}

checkFileChanged() {
  ! ([ -f "$1.1" ] && cmp -s $1 $1.1)
}

configure() {
  local runtimeConfigFile=/data/redis/redis.conf slaveofFile=$rootConfDir/redis.slaveof.conf \
        defaultConfigFile=$rootConfDir/redis.default.conf monitorFile=$rootConfDir/sentinel.monitor.conf
  sudo -u redis touch $runtimeConfigFile $runtimeSentinelFile $nodesFile && rotate $runtimeConfigFile $runtimeSentinelFile $nodesFile
  echo $REDIS_NODES | xargs -n1 > $nodesFile
  if checkFileChanged $nodesFile; then
    log "IP addresses changed from [$(paste -s $nodesFile.1)] to [$(paste -s $nodesFile)]. Updating config files accordingly ..."
    local replaceCmd="$(join -j1 -t/ -o1.3,2.3 $nodesFile.1 $nodesFile | sed 's#/# / #g; s#^#s/ #g; s#$# /g#g' | paste -sd';')"
    sed -i "$replaceCmd" $runtimeConfigFile $runtimeSentinelFile
  fi
  local masterIp; masterIp="$(findMasterIp)"

  # flush every time even no master IP switches, but port is changed
  [ "$MY_IP" == "$masterIp" ] && > $slaveofFile || echo "SLAVEOF $masterIp $REDIS_PORT" > $slaveofFile
  echo "sentinel monitor master $masterIp $REDIS_PORT 2" > $monitorFile

  awk '$0~/^[^ #$]/ ? $1~/^(client-output-buffer-limit|rename-command)$/ ? !a[$1$2]++ : !a[$1]++ : 0' \
    $changedConfigFile $slaveofFile $runtimeConfigFile.1 $defaultConfigFile > $runtimeConfigFile
  if isSvcEnabled redis-sentinel; then
    sed -i '/^sentinel rename-(slaveof|config)/d' $runtimeSentinelFile
    awk '$0~/^[^ #$]/ ? $1~/^sentinel/ ? $2~/^rename-/ ? !a[$1$2$3$4]++ : $2~/^(anno|deny-scr)/ ? !a[$1$2]++ : !a[$1$2$3]++ : !a[$1]++ : 0' \
      $monitorFile $changedSentinelFile $runtimeSentinelFile.1 > $runtimeSentinelFile
  else
    rm -f $runtimeSentinelFile*
  fi

  setUpVip $masterIp
}