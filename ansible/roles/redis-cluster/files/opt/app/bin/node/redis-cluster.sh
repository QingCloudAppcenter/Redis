initNode() {
  mkdir -p /data/redis/logs && chown -R redis.svc /data/redis
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _initNode
}

initCluster() {
  local nodesConf=/data/redis/nodes.conf
  [ -e "$nodesConf" ] || {
    local tmplConf=/opt/app/conf/redis-cluster/nodes.conf
    sudo -u redis cp $tmplConf $nodesConf
    if [ -n "$JOINING_REDIS_NODES" ]; then
      egrep -o ".* ($(echo $JOINING_REDIS_NODES | xargs -n1 | awk -F/ '{print $4}' | paste -s -d'|')):.* connected" $tmplConf > $nodesConf
    fi
  }
}

init() {
  execute initNode && initCluster
}

start() {
  isNodeInitialized || execute initNode
  configure && _start

  if [ -n "$JOINING_REDIS_NODES" ]; then
    retry 10 1 0 execute check
    local node; for node in $REDIS_NODES; do runRedisCmd cluster meet ${node##*/} $REDIS_PORT; done
  fi
}

scaleOut() {
  # TODO: sometimes it fails with "[WARNING] The following slots are open: " or "[ERR] Nodes don't agree about configuration!".
  runRedisCmd --timeout 86400 --cluster rebalance --cluster-use-empty-masters $MY_IP:$REDIS_PORT
}

# redis-cli --cluster rebalance --weight xxx=0 yyy=0
preScaleIn() {
  [ -n "$LEAVING_REDIS_NODES" ] || (log "No leaving nodes detected." && return 200)
  local runtimeMasters
  runtimeMasters="$(runRedisCmd --cluster info $MY_IP $REDIS_PORT | awk '$3=="->" {print gensub(/:.*$/, "", "g", $1)}' | paste -s -d'|')"
  local runtimeMastersToLeave="$(echo $LEAVING_REDIS_NODES | xargs -n1 | egrep "($runtimeMasters)$" | xargs)"
  if echo "$LEAVING_REDIS_NODES" | grep -q "/master/"; then
    local totalCount=$(echo "$runtimeMasters" | awk -F"|" '{printf NF}')
    local leavingCount=$(echo "$runtimeMastersToLeave" | awk '{printf NF}')
    (( $leavingCount>0 && $totalCount-$leavingCount>2 )) || (log "ERROR broken cluster: runm='$runtimeMasters' leav='$LEAVING_REDIS_NODES'." && return 201)
    local leavingIds node; leavingIds="$(for node in $runtimeMastersToLeave; do buildNodeId $node; done)"
    runRedisCmd --timeout 86400 --cluster rebalance --cluster-weight $(echo $leavingIds | xargs -n1 | sed 's/$/=0/g' | xargs) $MY_IP:$REDIS_PORT || {
      log "ERROR failed to rebalance the cluster ($?)." && return 203
    }
  else
    [ -z "$runtimeMastersToLeave" ] || (log "ERROR replica node(s) '$runtimeMastersToLeave' are now runtime master(s)." && return 202)
  fi

  local leavingNode; for leavingNode in $LEAVING_REDIS_NODES; do
    local node; for node in $REDIS_NODES; do
      echo $LEAVING_REDIS_NODES | grep -q $node || {
        runRedisCmd -h ${node##*/} cluster forget $(buildNodeId $leavingNode) || (log "ERROR failed to delete '$id' ($?)." && return 204)
      }
    done
  done
}

check(){
  _check
  local loadingTag="loading the dataset in memory"
  local response;response=$(runRedisCmd cluster info)
  egrep -q "(cluster_state:ok|$loadingTag)" <(echo $response)
}

checkBgsaveDone(){
  local lastsaveCmd; lastsaveCmd=$(getRuntimeNameOfCmd "LASTSAVE")
  [[ $(runRedisCmd $lastsaveCmd) > ${1?Lastsave time is required} ]]
}

backup(){
  log "Start backup"
  local lastsave="LASTSAVE" bgsave="BGSAVE"
  local lastsaveCmd bgsaveCmd; lastsaveCmd=$(getRuntimeNameOfCmd $lastsave) bgsaveCmd=$(getRuntimeNameOfCmd $bgsave)
  local lastTime; lastTime=$(runRedisCmd $lastsaveCmd)
  runRedisCmd $bgsaveCmd
  retry 60 1 $EC_BACKUP_ERR checkBgsaveDone $lastTime
  log "backup successfully"
}

getRedisInfo(){
  runRedisCmd cluster nodes |awk 'BEGIN{print "{"}
  {
      split($2,ips,":");
      redisInfo[$1]="{\"ip\":\""ips[1]"\",\"role\":\""gensub(/^(myself,)?(master|slave|fail|pfail){1}.*/,"\\2",1,$3)"\",\"masterId\":\""$4"\"}";
  }
  END{
      len = length(redisInfo)
      i = 1

      for(id in redisInfo){
          if(i<len){
          print "\""id"\""":"redisInfo[id]","
          }
          else{
          print "\""id"\""":"redisInfo[id]
          }
          i++
      };
      print "}"
  }'
}

reload() {
  if [ "$1" == "redis-server" ]; then
    if echo "$LEAVING_REDIS_NODES " | grep -q "/master/.*/$MY_IP "; then
      local myRuntimeRole; myRuntimeRole=$(runRedisCmd role | head -1)
      if [ "$myRuntimeRole" == "slave" ]; then appctl stop; fi
      return 0
    fi
    configure
  fi
  _reload $@
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

buildNodeId() {
  echo $1 | awk -F/ '{printf $3}' | sha1sum | cut -c1-40
}

runRedisCmd() {
  local timeout=5; if [ "$1" == "--timeout" ]; then timeout=$2 && shift 2; fi
  local authOpt; [ -z "$REDIS_PASSWORD" ] || authOpt="--no-auth-warning -a '$REDIS_PASSWORD'"
  local result retCode=0
  result="$(timeout --preserve-status ${timeout}s /opt/redis/current/redis-cli $authOpt -p "$REDIS_PORT" $@ 2>&1)" || retCode=$?
  if [ "$retCode" != 0 ] || [[ "$result" == *ERR* ]]; then
    log "ERROR failed to run redis command '$@' ($retCode): $result." && retCode=210
  else
    echo "$result"
  fi
  return $retCode
}

getRuntimeNameOfCmd() {
  if echo -e $DISABLED_COMMANDS | grep -oq $1;then
    encodeCmd $1
  else
    echo $1
  fi
}

encodeCmd() {
  echo -n "${CLUSTER_ID}${NODE_ID}${1?command is required}"
}

nodesFile=/data/redis/nodes
rootConfDir=/opt/app/conf/redis-cluster

configureForChangeVxnet(){
  local runtimeConfigFile=/data/redis/redis.conf
  if checkFileChanged $nodesFile; then
    log "IP addresses changed from [$(paste -s $nodesFile.1)] to [$(paste -s $nodesFile)]. Updating config files accordingly ..."
    local replaceCmd="$(join -j1 -t/ -o1.4,2.4 $nodesFile.1 $nodesFile | sed 's#/# / #g; s#^#s/ #g; s#$# /g#g' | paste -sd';')"
    sed -i "$replaceCmd" $runtimeConfigFile
  fi
}

configureForRedis(){
  local changedConfigFile=$rootConfDir/redis.changed.conf
  local defaultConfigFile=$rootConfDir/redis.default.conf
  local runtimeConfigFile=/data/redis/redis.conf
  awk '$0~/^[^ #$]/ ? $1~/^(client-output-buffer-limit|rename-command)$/ ? !a[$1$2]++ : !a[$1]++ : 0' \
    $changedConfigFile $runtimeConfigFile.1 $defaultConfigFile > $runtimeConfigFile
}

configure() {
  local changedConfigFile=$rootConfDir/redis.changed.conf
  local defaultConfigFile=$rootConfDir/redis.default.conf
  local runtimeConfigFile=/data/redis/redis.conf
  sudo -u redis touch $runtimeConfigFile $nodesFile && rotate $runtimeConfigFile $nodesFile
  echo $REDIS_NODES | xargs -n1 > $nodesFile
  configureForChangeVxnet
  configureForRedis
}

checkFileChanged() {
  ! ([ -f "$1.1" ] && cmp -s $1 $1.1)
}

runCommand(){
  local redisInfo;redisInfo=$(getRedisInfo)
  if [[ $(echo $redisInfo |jq 'map(select(.["role"]=="master" and .["ip"]=="'$MY_IP'"))' |jq 'length') == 0 ]];then log --debug "My role is not master, Unauthorized operation";return 0;fi
  local db=$(echo $1 |jq .db) flushCmd=$(echo $1 |jq -r .cmd)
  local cmd=$(getRuntimeNameOfCmd $flushCmd)
  if [[ "$flushCmd" == "BGSAVE" ]];then
    log "runCommand BGSAVE"
    backup
  else
    runRedisCmd -n $db $cmd
  fi
}