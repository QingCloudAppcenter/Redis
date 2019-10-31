NO_JOINING_NODES_DETECTED_ERR=200
NUMS_OF_REMAIN_NODES_TOO_LESS_ERR=201
DELETED_REPLICA_NODE_REDIS_ROLE_IS_MASTER_ERR=202
REBALANCE_ERR=203
CLUSTER_FORGET_ERR=204
CLUSTER_RESET_ERR=205
REDIS_COMMAND_EXECUTE_FAIL=210

initNode() {
  mkdir -p /data/redis/logs
  chown -R redis.svc /data/redis
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _initNode
}

initCluster() {
  local nodesConf=/data/redis/nodes-6379.conf
  [ -e "$nodesConf" ] || {
    local tmplConf=/opt/app/conf/redis-cluster/nodes-6379.conf
    [[ -n "$JOINING_REDIS_NODES" ]] || sudo -u redis cp $tmplConf $nodesConf
  }
}

init() {
  execute initNode
  initCluster
}

start() {
  isNodeInitialized || execute initNode
  configure
  _start
}

checkRedisStateIsOkByInfo(){
  local oKTag="cluster_state:ok" 
  local infoResponse=$(runRedisCmd -h ${1?node ip is required} cluster info)
  echo "$infoResponse" |grep -q "$oKTag"
}

getRedisCheckResponse(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode=$(getFirstNodeIpInStableNodes)
  runRedisCmd -h "${1?node Ip is required}" --cluster check $firstNodeIpInStableNode:$REDIS_PORT
}

checkForAllAgree(){
  local checkResponse; checkResponse=$(getRedisCheckResponse ${1?node Ip is required}) allAgreetag="OK] All nodes agree about slots configuration."
  echo "$checkResponse" |grep -q "$allAgreetag"
}

waitUntilAllNodesIsOk(){
  local ip; for ip in ${1?stableNodesIps is required};do
    log --debug "check node $ip"
    retry 120 1 0 checkRedisStateIsOkByInfo $ip
    retry 120 1 0 checkForAllAgree $ip
  done
}

getStableNodesIps(){
  awk 'BEGIN{RS=" ";ORS=" "}NR==FNR{a[$0]}NR>FNR{ if(!($0 in a)) print $0}' <(echo "$JOINING_REDIS_NODES" |xargs) <(echo "$REDIS_NODES" |xargs) |xargs -n1 |awk -F "/" '{print $5}'
}

getFirstNodeIpInStableNodes(){
  local stableNodesIps; stableNodesIps=$(getStableNodesIps)
  local leavingNodeIps=" "
  local leavingNode;for leavingNode in $LEAVING_REDIS_NODES; do
    leavingNodeIps="$leavingNodeIps${leavingNode##*/} "
  done
  awk 'BEGIN{RS=" ";ORS=" "}NR==FNR{a[$0]}NR>FNR{ if(!($0 in a)) print $0}' <(echo "$leavingNodeIps") <(echo "$stableNodesIps" |xargs) |awk '{printf $1}'
}

getMasterIdByslaveIp(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode=$(getFirstNodeIpInStableNodes)
  local gid; gid=$(echo "$REDIS_NODES" |xargs -n1 |grep ${1?slaveIp is required} |cut -d "/" -f1)
  local ipsInGid; ipsInGid=$(echo "$REDIS_NODES" |xargs -n1 |awk -F "/" 'BEGIN{ORS="|"}{if ($1=='$gid' && $5!~/'$1'/){print $5}}')
  local redisClusterNodes; redisClusterNodes="$(runRedisCmd -h "$firstNodeIpInStableNode" cluster nodes)"
  log "redisClusterNodes:  $redisClusterNodes"
  local masterId; masterId="$(echo "$redisClusterNodes" |awk '$0~/.*('${ipsInGid:0:-1}'):'$REDIS_PORT'.*(master){1}.*/{print $1}')"
  local masterIdCount; masterIdCount=$(echo "$masterId" |wc -l)
  if [[ $masterIdCount == 1 ]]; then
    echo "$masterId"
  else
    log "node ${1?slaveIp is required} get $masterIdCount masterId:'$masterId'";return 1
  fi
}

getRedisRole(){
  local result; result=$(runRedisCmd -h ${1?Node ip is required} role)
  echo "$result" |head -n1
}

sortOutLeavingNodesIps(){
  local slaveNodeIps="" masterNodeIps=""
  local node; for node in $LEAVING_REDIS_NODES;do
    local nodeRole; nodeRole=$(getRedisRole ${node##*/})
    if [[ "$nodeRole" == "master" ]]; then
      masterNodeIps="$masterNodeIps ${node##*/}"
    else
      slaveNodeIps="$slaveNodeIps ${node##*/}"
    fi
  done
  echo "$slaveNodeIps $masterNodeIps" |xargs -n1
}

scaleOut() {
  # TODO: sometimes it fails with "[WARNING] The following slots are open: " or "[ERR] Nodes don't agree about configuration!".
  [[ -n "$JOINING_REDIS_NODES" ]] || (log "no joining nodes detected" and return $NO_JOINING_NODES_DETECTED_ERR)
  # add master nodes
  local stableNodesIps=$(getStableNodesIps)
  local firstNodeIpInStableNode; firstNodeIpInStableNode=$(getFirstNodeIpInStableNodes)
  local node; for node in $JOINING_REDIS_NODES;do
    if [[ "$(echo "$node"|cut -d "/" -f3)" == "master" ]];then
      waitUntilAllNodesIsOk "$stableNodesIps"
      log "add master node ${node##*/}"
      runRedisCmd --timeout 120 -h "$firstNodeIpInStableNode" --cluster add-node ${node##*/}:$REDIS_PORT $firstNodeIpInStableNode:$REDIS_PORT
      log "add master node ${node##*/} end"
      stableNodesIps=$(echo "$stableNodesIps ${node##*/}" |xargs -n1)
    fi
  done
  # rebalance slots
  log "check stableNodesIps: $stableNodesIps"
  waitUntilAllNodesIsOk "$stableNodesIps"
  log "== rebalance start =="
  # 在配置未同步完的情况下，会出现 --cluster-use-empty-masters 未生效的情况
  runRedisCmd --timeout 86400 -h $firstNodeIpInStableNode --cluster rebalance --cluster-use-empty-masters $firstNodeIpInStableNode:$REDIS_PORT || {
      log "ERROR failed to rebalance the cluster ($?)."
      return $REBALANCE_ERR
    }
  log "== rebanlance end =="
  log "check stableNodesIps: $stableNodesIps"
  waitUntilAllNodesIsOk "$stableNodesIps"
  # add slave nodes
  local node; for node in $JOINING_REDIS_NODES;do
    if [[ "$(echo "$node"|cut -d "/" -f3)" == "slave" ]];then
      log "add master-replica node ${node##*/}"
      waitUntilAllNodesIsOk "$stableNodesIps"
      # 新增的从节点在短时间内其在配置文件中的身份为 master，会导致再次增加从节点时获取到的 masterId 为多个，这里需要等到 masterId 为一个为止 
      local masterId; masterId=$(retry 20 1 0 getMasterIdByslaveIp ${node##*/})
      log "${node##*/}: masterId is $masterId"
      runRedisCmd --timeout 120 -h "$firstNodeIpInStableNode" --cluster add-node ${node##*/}:$REDIS_PORT $firstNodeIpInStableNode:$REDIS_PORT --cluster-slave --cluster-master-id $masterId
      log "add master-replica node ${node##*/} end"
      stableNodesIps=$(echo "$stableNodesIps ${node##*/}" |xargs -n1)
    fi
  done
}

getMyIdByMyIp(){
  runRedisCmd -h ${1?my ip is required} CLUSTER MYID
}

resetMynode(){
  local nodeIp; nodeIp=${1?my ip is required}
  local resetResult; resetResult=$(runRedisCmd -h $nodeIp CLUSTER RESET)
  if [[ "$resetResult" == "OK" ]]; then
    log "Reset node $nodeIp successful"
  else 
    log "ERROR to reset node $nodeIp fail"
    return $CLUSTER_RESET_ERR
  fi
}

# redis-cli --cluster rebalance --weight xxx=0 yyy=0
preScaleIn() {
  local firstNodeIpInStableNode; firstNodeIpInStableNode=$(getFirstNodeIpInStableNodes)
  local stableNodesIps; stableNodesIps=$(getStableNodesIps)
  local runtimeMasters
  runtimeMasters="$(runRedisCmd -h "firstNodeIpInStableNode" --cluster info $firstNodeIpInStableNode $REDIS_PORT | awk '$3=="->" {print gensub(/:.*$/, "", "g", $1)}' | paste -s -d'|')"
  local runtimeMastersToLeave="$(echo $LEAVING_REDIS_NODES | xargs -n1 | egrep "($runtimeMasters)$" | xargs)"
  if echo "$LEAVING_REDIS_NODES" | grep -q "/master/"; then
    local totalCount=$(echo "$runtimeMasters" | awk -F"|" '{printf NF}')
    local leavingCount=$(echo "$runtimeMastersToLeave" | awk '{printf NF}')
    (( $leavingCount>0 && $totalCount-$leavingCount>2 )) || (log "ERROR broken cluster: runm='$runtimeMasters' leav='$LEAVING_REDIS_NODES'."; return $NUMS_OF_REMAIN_NODES_TOO_LESS_ERR)
    log "== rebalance start =="
    local leavingIds node; leavingIds="$(for node in $runtimeMastersToLeave; do getMyIdByMyIp ${node##*/}; done)"
    runRedisCmd --timeout 86400 -h "$firstNodeIpInStableNode" --cluster rebalance --cluster-weight $(echo $leavingIds | xargs -n1 | sed 's/$/=0/g' | xargs) $firstNodeIpInStableNode:$REDIS_PORT || {
      log "ERROR failed to rebalance the cluster ($?)."
      return $REBALANCE_ERR
    }
    log "== rebalance end =="
    log "== check start =="
    waitUntilAllNodesIsOk "$stableNodesIps"
    log "check end"
  else
    [ -z "$runtimeMastersToLeave" ] || (log "ERROR replica node(s) '$runtimeMastersToLeave' are now runtime master(s)."; return $DELETED_REPLICA_NODE_REDIS_ROLE_IS_MASTER_ERR)
  fi

  # cluster forget leavingNode from RedisNode
  # Make sure that forget slave node before master node is forgotten
  local leavingNodeIps; leavingNodeIps=$(sortOutLeavingNodesIps)
  local leavingNodeIp; for leavingNodeIp in $leavingNodeIps; do
    waitUntilAllNodesIsOk "$stableNodesIps"
    log "forget $leavingNodeIp"
    local leavingNodeId; leavingNodeId=$(getMyIdByMyIp $leavingNodeIp)
    local node; for node in $REDIS_NODES; do
      if echo "$stableNodesIps" | grep ${node##*/} |grep -vq $leavingNodeIp; then
        log "forget in ${node##*/}"
        runRedisCmd -h ${node##*/} cluster forget $leavingNodeId || (log "ERROR failed to delete '${leavingNodeIp}':'$leavingNodeId' ($?)."; return $CLUSTER_FORGET_ERR)    
      fi
    done
    log "forget $leavingNodeIp end"
    resetMynode $leavingNodeIp
    stableNodesIps=$(echo "$stableNodesIps" |grep -v "${leavingNodeIp}")
  done
}

check(){
  _check
  local loadingTag="loading the dataset in memory"
  local infoResponse;infoResponse=$(runRedisCmd cluster info)
  echo "$infoResponse"
  egrep -q "(cluster_state:ok|$loadingTag)" <(echo "$infoResponse")
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

reload() {
  # 避免集群刚创建时执行 reload_cmd
  if ! isNodeInitialized; then return 0;fi

  if [[ "$1" == "redis-server" ]]; then
    local nodeEnvFile="/opt/app/bin/envs/node.env"
    local changedConfigFile="$rootConfDir/redis.changed.conf"
    if checkFileChanged $nodeEnvFile || checkFileChanged $changedConfigFile; then 
       stopSvc "redis-server"
       configure
       startSvc "redis-server"
    fi
    return 0
  fi
  _reload $@
}

revive(){
  _revive
  [[ "${REVIVE_ENABLED:-"true"}" == "true" ]] || return 0
  echo "yes" | runRedisCmd --timeout 40 --cluster fix $MY_IP:$REDIS_PORT
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
  }' | jq -R 'split(":")|{(.[0]):.[1]}' | jq -sc add || ( local rc=$?; log "Failed to measure Redis: $metrics"; return $rc )
}

runRedisCmd() {
  local timeout=5; if [ "$1" == "--timeout" ]; then timeout=$2; shift 2; fi
  local authOpt; [ -z "$REDIS_PASSWORD" ] || authOpt="--no-auth-warning -a $REDIS_PASSWORD"
  local result retCode=0
  result="$(timeout --preserve-status ${timeout}s /opt/redis/current/redis-cli $authOpt -p "$REDIS_PORT" $@ 2>&1)" || retCode=$?
  if [ "$retCode" != 0 ] || [[ "$result" == *ERR* ]]; then
    log "ERROR failed to run redis command '$@' ($retCode): $(echo "$result" |tr '\r\n' ';' |tail -c 4000)."
    retCode=$REDIS_COMMAND_EXECUTE_FAIL
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
  local runtimeNodesConfigFile=/data/redis/nodes-6379.conf
  if checkFileChanged $nodesFile; then
    log "IP addresses changed from [$(paste -s $nodesFile.1)] to [$(paste -s $nodesFile)]. Updating config files accordingly ..."
    local replaceCmd="$(join -1 4 -2 4 -t/ -o1.5,2.5 $nodesFile.1 $nodesFile |  sed 's#/#/#g; s#^#s/#g; s#$#/g#g' | paste -sd';')"
    rotate $runtimeNodesConfigFile
    sed -i "$replaceCmd" $runtimeNodesConfigFile
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
  sudo -u redis touch $runtimeConfigFile $nodesFile
  rotate $runtimeConfigFile $nodesFile
  echo $REDIS_NODES | xargs -n1 > $nodesFile
  configureForChangeVxnet
  configureForRedis
}

checkFileChanged() {
  ! ([ -f "$1.1" ] && cmp -s $1 $1.1)
}

runCommand(){
  local myRole; myRole=$(getRedisRole $MY_IP)
  if [[ "$myRole" != "master" ]]; then log "My role is not master, Unauthorized operation";return 0;fi 
  local db=$(echo $1 |jq .db) flushCmd=$(echo $1 |jq -r .cmd)
  local cmd=$(getRuntimeNameOfCmd $flushCmd)
  if [[ "$flushCmd" == "BGSAVE" ]];then
    log "runCommand BGSAVE"
    backup
  else
    runRedisCmd -n $db $cmd
  fi
}

getRedisRoles(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode=$(getFirstNodeIpInStableNodes)
  log "firstNodeIpInStableNode: $firstNodeIpInStableNode"
  local rawResult; rawResult=$(runRedisCmd -h "$firstNodeIpInStableNode" cluster nodes)
  local loadingTag="loading the dataset in memory"
  echo "$rawResult" |grep -q "$loadingTag" && return 0
  local firstProcessResult; firstProcessResult=$(echo "$rawResult" |awk 'BEGIN{OFS=","} {split($2,ips,":");print "\""ips[1]"\"","\""gensub(/^(myself,)?(master|slave|fail|pfail){1}.*/,"\\2",1,$3)"\"","\""$4"t""\""}' |sort -t "," -k3)
  local regexpResult; regexpResult=$(echo "$rawResult" |awk 'BEGIN{ORS=";"}{split($2,ips,":");print "s/"$1"t/"ips[1]"/g"}END{print "s/-t/None/g"}')
  local secondProcssResult; secondProcssResult=$(sed "$regexpResult" <(echo "$firstProcessResult") |awk 'BEGIN{printf "["}{a[NR]=$0}END{for(x in a){printf x==NR ? "["a[x]"]" : "["a[x]"],"};printf "]"}')
  echo "$secondProcssResult" |jq -c '{"labels":["ip","role","master_ip"],"data":.}'
}