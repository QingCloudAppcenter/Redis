NO_JOINING_NODES_DETECTED_ERR=240
NUMS_OF_REMAIN_NODES_TOO_LESS_ERR=241
DELETED_REPLICA_NODE_REDIS_ROLE_IS_MASTER_ERR=242
REBALANCE_ERR=243
CLUSTER_FORGET_ERR=204
CLUSTER_RESET_ERR=205
EXISTS_REDIS_MEMORY_USAGE_TOO_BIG=206
AVERAGE_REDIS_MEMORY_USAGE_TOO_BIG_AFTER_SCALEIN=207
REDIS_COMMAND_EXECUTE_FAIL=210
CHANGE_VXNET_ERR=220
GROUP_MATCHED_ERR=221
CLUSTER_MATCHED_ERR=222
CLUSTER_STATE_NOT_OK=223
LOAD_ACLFILE_ERR=224
ACL_SWITCH_ERR=225
ACL_MANAGE_ERR=226

ROOT_CONF_DIR=/opt/app/conf/redis-cluster
CHANGED_CONFIG_FILE=$ROOT_CONF_DIR/redis.changed.conf
DEFAULT_CONFIG_FILE=$ROOT_CONF_DIR/redis.default.conf
CHANGED_ACL_FILE=$ROOT_CONF_DIR/aclfile.conf

REDIS_EXPORTER="/data/redis_exporter"
REDIS_EXPORTER_LOGS_DIR="$REDIS_EXPORTER/logs"
REDIS_EXPORTER_PID_FILE="$REDIS_EXPORTER/redis_exporter.pid"

REDIS_DIR=/data/redis
RUNTIME_CONFIG_FILE=$REDIS_DIR/redis.conf
RUNTIME_ACL_FILE=$REDIS_DIR/aclfile.conf
NODE_CONF_FILE=$REDIS_DIR/nodes-6379.conf
ACL_CLEAR=$REDIS_DIR/acl.clear

execute() {
  local cmd=$1; log --debug "Executing command ..."
  # 在 checkGroupMatchedCommand(){} 存在的情况下，先对各 command 做判断，仅对 redis cluster 有效
  checkGroupMatchedCommandFunction="checkGroupMatchedCommand"
  [[ "$(type -t $checkGroupMatchedCommandFunction)" == "function" ]] && $checkGroupMatchedCommandFunction $cmd
  [ "$(type -t $cmd)" = "function" ] || cmd=_$cmd
  [[ "$cmd" == *measure* ]] || { log --debug "cat nodes-6379.conf:
  $(cat $NODE_CONF_FILE 2>&1 ||true)"
  }
  $cmd ${@:2}
}

initNode() {
  mkdir -p $REDIS_DIR/{logs,tls}
  mkdir -p $REDIS_EXPORTER $REDIS_EXPORTER_LOGS_DIR
  touch $REDIS_DIR/tls/{ca.crt,redis.crt,redis.dh,redis.key}
  touch $RUNTIME_ACL_FILE
  touch $REDIS_EXPORTER_PID_FILE
  chown -R redis.svc $REDIS_DIR
  chown -R prometheus.svc $REDIS_EXPORTER
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _initNode
}

checkMyRoleSlave() {
  getRedisRole "$MY_IP" | grep -qE "^slave$"
}

stop(){
  if [ -n "${REBUILD_AUDIT}${VERTICAL_SCALING_ROLES}${UPGRADE_AUDIT}" ] && getRedisRole "$MY_IP" | grep -qE "^master$"; then
    local slaveIP
    slaveIP="$(echo -n "$REDIS_NODES" | xargs -n1 | awk -F"/" -v ip="$MY_IP" '{if($5==ip){gid=$1} else{gids[$1]=$5}}END{print gids[gid]}')"
    echo $slaveIP
    [ -n "$slaveIP" ] && {
      log "runRedisCmd -h $slaveIP CLUSTER FAILOVER TAKEOVER"
      runRedisCmd -h "$slaveIP" CLUSTER FAILOVER TAKEOVER
      log "retry 120 1 0 checkMyRoleSlave"
      retry 120 1 0 checkMyRoleSlave
    }
  fi
  _stop
  swapIpAndName
}

initCluster() {
  # 防止新增节点执行
  if [ -n "$JOINING_REDIS_NODES" ]; then return 0; fi
  [ -e "$NODE_CONF_FILE" ] || {
    local tmplConf=/opt/app/conf/redis-cluster/nodes-6379.conf
    sudo -u redis cp $tmplConf $NODE_CONF_FILE
  }
}

init() {
  execute initNode
  initCluster
}

getLoadStatus() {
  local gid
  gid=$(echo "$REDIS_NODES" | xargs -n1 | awk -F/ -v ip="$MY_IP" '$5==ip{print $1}')
  if echo "$REDIS_NODES" | xargs -n1 | awk -F/ -v ip="$MY_IP" -v gid=$gid '$5!=ip && $1==gid {exit 1}'; then
    runRedisCmd Info Persistence | awk -F"[: ]+" 'BEGIN{f=1}$1=="loading"{f=$2} END{exit f}'
  else
    runRedisCmd info Replication | grep -Eq '^(slave[0-9]|master_host):'
  fi
}

start() {
  isNodeInitialized || execute initNode
  if [[ -n "$JOINING_REDIS_NODES" && "$ENABLE_ACL" == "yes" ]] ; then 
    sudo -u redis touch $ACL_CLEAR
    local ACL_CMD node_ip=$(echo ${REDIS_NODES%% *} | cut -d "/" -f5)
    ACL_CMD="$(getRuntimeNameOfCmd --node-id "$(echo ${REDIS_NODES%% *} | cut -d "/" -f4)" ACL)"
    runRedisCmd -h $node_ip $ACL_CMD LIST > $RUNTIME_ACL_FILE
  fi

  configure
  _start
  if [ -n "${REBUILD_AUDIT}${VERTICAL_SCALING_ROLES}${UPGRADE_AUDIT}" ]; then
    log "retry 86400 1 0 getLoadStatus"
    retry 86400 1 0 getLoadStatus
  fi
}

checkRedisStateIsOkByInfo(){
  local oKTag="cluster_state:ok" 
  local infoResponse; infoResponse="$(runRedisCmd -h $1 cluster info)"
  [[ "$infoResponse" == *"$oKTag"* ]]
}

getRedisCheckResponse(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  runRedisCmd -h $1 --cluster check $firstNodeIpInStableNode:$REDIS_PORT
}

checkForAllAgree(){
  local checkResponse retCode=0
  checkResponse="$(getRedisCheckResponse $1 || retCode=$?)"
  [[ "$checkResponse" == *"OK] All nodes agree about slots configuration."* ]]
  [[ "$checkInfo" != *"Nodes don't agree about configuration"* ]]
  return $retCode
}


checkAllAddSuccess(){
  local ip checkResponse retCode=0 newIP=$1
  shift 1;
  for ip in $@ ;do
    checkResponse="$(runRedisCmd -h $ip cluster nodes || retCode=$?)"
    [[ "$checkResponse" == *" $newIP:$REDIS_PORT@"* ]]
  done
}


waitUntilAllNodesIsOk(){
  local ip ips=$@
  for ip in $(echo $ips|xargs -n1);do
    log --debug "check node $ip"
    retry 120 1 0 checkRedisStateIsOkByInfo $ip
    retry 600 1 0 checkForAllAgree $ip
  done
}

getStableNodesIps(){
  awk 'BEGIN{RS=" ";ORS="\n";FS="/"}NR==FNR{a[$NF]}NR>FNR{ if(!($NF in a)) print $NF}' <(echo "$LEAVING_REDIS_NODES $JOINING_REDIS_NODES" ) <(echo "$REDIS_NODES" )
}

getFirstNodeIpInStableNodesExceptLeavingNodes(){
  awk 'BEGIN{RS=" ";ORS="\n";FS="/"}NR==FNR{a[$NF]}NR>FNR{ if(!($NF in a ) && !ip  ) ip=$NF}END{print ip}' <(echo "$LEAVING_REDIS_NODES $JOINING_REDIS_NODES" ) <(echo "$REDIS_NODES" )
}

findMasterIdByJoiningSlaveIp(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  local gid; gid="$(echo "$REDIS_NODES" |xargs -n1 |grep -E "/${1//\./\\.}$" |cut -d "/" -f1)"
  local ipsInGid; ipsInGid="$(echo "$REDIS_NODES" |xargs -n1 |awk -F "/" 'BEGIN{ORS="|"}{if ($1=='$gid' && $5!~/^'${1//\./\\.}'$/){print $5}}' |sed 's/\./\\./g')"
  local redisClusterNodes; redisClusterNodes="$(runRedisCmd -h "$firstNodeIpInStableNode" cluster nodes)"
  log "redisClusterNodes:  $redisClusterNodes"
  local masterId; masterId="$(echo "$redisClusterNodes" |awk '$0~/.*('${ipsInGid:0:-1}'):'$REDIS_PORT'.*(master){1}.*/{print $1}')"
  local masterIdCount; masterIdCount="$(echo "$masterId" |wc -l)"
  if [[ $masterIdCount == 1 ]]; then
    echo "$masterId"
  else
    log "node ${1?slaveIp is required} get $masterIdCount masterId:'$masterId'";return 1
  fi
}

getRedisRole(){
  local result; result="$(runRedisCmd -h $1 role)"
  echo "$result" |head -n1
}

sortOutLeavingNodesIps(){
  local slaveNodeIps="" masterNodeIps=""
  local node; for node in $LEAVING_REDIS_NODES;do
    local nodeRole; nodeRole="$(getRedisRole ${node##*/})"
    if [[ "$nodeRole" == "master" ]]; then
      masterNodeIps="$masterNodeIps ${node##*/}"
    else
      slaveNodeIps="$slaveNodeIps ${node##*/}"
    fi
  done
  echo "$slaveNodeIps $masterNodeIps" |xargs -n1
}

preScaleOut(){
  log "preScaleOut"
  return 0
}

scaleOut() {
  local logFile=/data/appctl/logs/preScaleIn.$(date +%s).$$.log
  rotate $NODE_CONF_FILE
  log "joining nodes $JOINING_REDIS_NODES"
  [[ -n "$JOINING_REDIS_NODES" ]] || {
    log "no joining nodes detected"
    return $NO_JOINING_NODES_DETECTED_ERR
  }

  #runRedisCmd cluster nodes | awk -F "[ :]+" '{print $2}'
  # add master nodes
  local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  local node; for node in $JOINING_REDIS_NODES;do
    if [[ "$(echo "$node"|cut -d "/" -f3)" == "master" ]];then
      waitUntilAllNodesIsOk "$stableNodesIps"
      log "add master node ${node##*/}"
      runRedisCmd --timeout 120 -h "$firstNodeIpInStableNode" --cluster add-node ${node##*/}:$REDIS_PORT $firstNodeIpInStableNode:$REDIS_PORT >> $logFile
      retry 120 1 0 checkAllAddSuccess "${node##*/}" "$stableNodesIps" 
      log "add master node ${node##*/} end"
      stableNodesIps="$(echo "$stableNodesIps ${node##*/}")"
    fi
  done
  # rebalance slots
  log "check stableNodesIps: $stableNodesIps"
  waitUntilAllNodesIsOk "$stableNodesIps"
  log "== rebalance start =="
  # 在配置未同步完的情况下，会出现 --cluster-use-empty-masters 未生效的情况
  runRedisCmd --timeout 86400 -h $firstNodeIpInStableNode --cluster rebalance --cluster-use-empty-masters $firstNodeIpInStableNode:$REDIS_PORT >> $logFile || {
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
      local masterId; masterId="$(retry 20 1 0 findMasterIdByJoiningSlaveIp ${node##*/})"
      log "${node##*/}: masterId is $masterId"
      runRedisCmd --timeout 120 -h "$firstNodeIpInStableNode" --cluster add-node ${node##*/}:$REDIS_PORT $firstNodeIpInStableNode:$REDIS_PORT --cluster-slave --cluster-master-id $masterId >> $logFile
      log "add master-replica node ${node##*/} end"
      stableNodesIps="$(echo "$stableNodesIps ${node##*/}")"
    fi
  done
}

getMyIdByMyIp(){
  runRedisCmd -h ${1?my ip is required} CLUSTER MYID
}

resetMynode(){
  local nodeIp; nodeIp="$1"
  local resetResult; resetResult="$(runRedisCmd -h $nodeIp CLUSTER RESET)"
  if [[ "$resetResult" == "OK" ]]; then
    log "Reset node $nodeIp successful"
  else 
    log "ERROR to reset node $nodeIp fail"
    return $CLUSTER_RESET_ERR
  fi
}

# 仅在删除主从节点对时调用
checkMemoryIsEnoughAfterScaled(){
  log "checkMemoryIsEnoughAfterScaled"
  local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
  local allUsedMemory; allUsedMemory=0
  # 判断节点中是否存在内存使用率达到 0.95 的，存在便禁止删除
  local stableNodeIp; for stableNodeIp in $stableNodesIps; do
    local rawMemoryInfo; rawMemoryInfo="$(runRedisCmd -h $stableNodeIp INFO MEMORY)"
    local usedMemory; usedMemory="$(echo "$rawMemoryInfo" |awk -F":" '{if($1=="used_memory"){printf $2}}')"
    local maxMemory; maxMemory="$(echo "$rawMemoryInfo" |awk -F":" '{if($1=="maxmemory"){printf $2}}')"
    local memoryUsage; memoryUsage="$(awk 'BEGIN{printf "%.3f\n",'$usedMemory'/'$maxMemory'}')"
    [[ $memoryUsage > 0.95 ]] && (log "node $stableNodeIp memoryUsage > 0.95, actual value: $memoryUsage, forbid scale in"; return $EXISTS_REDIS_MEMORY_USAGE_TOO_BIG)
    allUsedMemory="$(awk 'BEGIN{printf '$usedMemory'+'$allUsedMemory'}')"
  done
  # 判断节点被删除后剩余节点的平均内存使用率是否达到 0.95，满足即禁止删除
  local nodesIpsAfterScaleIn; nodesIpsAfterScaleIn="$(getStableNodesIps)"
  local nodesCountAfterScaleIn; nodesCountAfterScaleIn="$(echo "$nodesIpsAfterScaleIn" |xargs -n 1|wc -l)"
  local averageMemoryUsageAfterScaleIn; averageMemoryUsageAfterScaleIn="$(awk 'BEGIN{printf "%.3f\n",'$allUsedMemory'/'$maxMemory'/'$nodesCountAfterScaleIn'}')"
  [[ $averageMemoryUsageAfterScaleIn > 0.95 ]] && (log " averageMemoryUsage > 0.95, calculated result: $averageMemoryUsageAfterScaleIn, forbid scale in"; return $AVERAGE_REDIS_MEMORY_USAGE_TOO_BIG_AFTER_SCALEIN)
  log "RedisMemoryIsOk"
  return 0
}

# redis-cli --cluster rebalance --weight xxx=0 yyy=0
preScaleIn() {
  local logFile=/data/appctl/logs/preScaleIn.$(date +%s).$$.log
  rotate $NODE_CONF_FILE
  log "leaving nodes $LEAVING_REDIS_NODES"
  log "getFirstNodeIpInStableNode"
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  log "firstNodeIpInStableNode: $firstNodeIpInStableNode"
  log "getStableNodesIps"
  local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
  log "stableNodesIps: $stableNodesIps"
  log "get runtimeMasters"
  local runtimeMasters
  runtimeMasters="$(runRedisCmd -h "$firstNodeIpInStableNode" --cluster info $firstNodeIpInStableNode $REDIS_PORT | awk '$3=="->" {print gensub(/:.*$/, "", "g", $1)}' | paste -s -d'|')"
  log "runtimeMasters: $runtimeMasters"
  log "get runtimeMastersToLeave"
  # 防止 egrep 未匹配到信息而报错，比如在删除所有 master-replica 节点时，该位置匹配不到导致删除失败
  local runtimeMastersToLeave; runtimeMastersToLeave="$(echo $LEAVING_REDIS_NODES | xargs -n1 | egrep "(${runtimeMasters//\./\\.})$" | xargs)" || true
  log "runtimeMastersToLeave: $runtimeMastersToLeave"
  if [[ "$LEAVING_REDIS_NODES" == *"/master/"* ]]; then
    checkMemoryIsEnoughAfterScaled
    local totalCount; totalCount="$(echo "$runtimeMasters" | awk -F"|" '{printf NF}')"
    local leavingCount; leavingCount="$(echo "$runtimeMastersToLeave" | awk '{printf NF}')"
    #(( $leavingCount>0 && $totalCount-$leavingCount>2 )) || (log "ERROR broken cluster: runm='$runtimeMasters' leav='$LEAVING_REDIS_NODES'."; return $NUMS_OF_REMAIN_NODES_TOO_LESS_ERR)
    log "== rebalance start =="
    local leavingIds node; leavingIds="$(for node in $runtimeMastersToLeave; do getMyIdByMyIp ${node##*/}; done)"
    runRedisCmd --timeout 86400 -h "$firstNodeIpInStableNode" --cluster rebalance --cluster-weight $(echo $leavingIds | xargs -n1 | sed 's/$/=0/g' | xargs) $firstNodeIpInStableNode:$REDIS_PORT >> $logFile || {
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
  local leavingNodeIps; leavingNodeIps="$(sortOutLeavingNodesIps)"
  local leavingNodeIp; for leavingNodeIp in $leavingNodeIps; do
    waitUntilAllNodesIsOk "$stableNodesIps"
    log "forget $leavingNodeIp"
    local leavingNodeId; leavingNodeId="$(getMyIdByMyIp $leavingNodeIp)"
    local node nodeIp; for node in $REDIS_NODES; do
      nodeIp=${node##*/}
      if echo "$stableNodesIps" | grep -E "^${nodeIp//\./\\.}$" |grep -Ev "^${leavingNodeIp//\./\\.}$"; then
        log "forget in ${nodeIp}"
        runRedisCmd -h ${nodeIp} cluster forget $leavingNodeId || (log "ERROR failed to delete '${leavingNodeIp}':'$leavingNodeId' ($?)."; return $CLUSTER_FORGET_ERR)    
      fi
    done
    log "forget $leavingNodeIp end"
    resetMynode $leavingNodeIp
    stableNodesIps="$(echo "$stableNodesIps" |grep -Ev "^${leavingNodeIp//\./\\.}$")"
  done
}

scaleIn(){
  true
}

clearDisk() {
  find /data/redis/ -maxdepth 1 -type f -mtime +3 -regex "/data/redis/temp-rewriteaof-[0-9]+.aof" -delete
}

check(){
  _check
  local loadingTag="loading the dataset in memory"
  local infoResponse;infoResponse="$(runRedisCmd cluster info)"
  [[ "$infoResponse" == *"$loadingTag"* ]] && return 0
  [[ "$infoResponse" == *"cluster_state:ok"* ]] || return $CLUSTER_STATE_NOT_OK
  # 是否发生错位
  checkGroupMatched
  checkClusterMatched
  clearDisk
}

checkBgsaveDone(){
  local lastsaveCmd; lastsaveCmd="$(getRuntimeNameOfCmd "LASTSAVE")"
  [[ $(runRedisCmd $lastsaveCmd) > ${1?Lastsave time is required} ]]
}

backup(){
  log "Start backup"
  local lastsave="LASTSAVE" bgsave="BGSAVE"
  local lastsaveCmd bgsaveCmd; lastsaveCmd="$(getRuntimeNameOfCmd $lastsave)" bgsaveCmd="$(getRuntimeNameOfCmd $bgsave)"
  local lastTime; lastTime="$(runRedisCmd $lastsaveCmd)"
  runRedisCmd $bgsaveCmd
  retry 60 1 $EC_BACKUP_ERR checkBgsaveDone $lastTime
  log "backup successfully"
}

reload() {
  # 避免集群刚创建时执行 reload_cmd
  if ! isNodeInitialized; then return 0;fi

  if [[ "$1" == "redis-server" ]]; then
    # redis.conf 发生改变时可以对 redis 做重启操作，防止添加节点时redis-server 重启
    if checkFileChanged "$CHANGED_CONFIG_FILE $CHANGED_ACL_FILE $(echo $TLS_CONF_LIST | xargs -n1 | cut -f 1 -d:)"; then 
      stopSvc "redis-server"
      configure
      startSvc "redis-server"
    fi
    return 0
  fi
  _reload $@
}

revive(){
  [[ "${REVIVE_ENABLED:-"true"}" == "true" ]] || return 0
  # 是否发生错位
  checkGroupMatched
  checkClusterMatched
  _revive
}

findMasterIpByNodeIp(){
  local myRoleResult myRole nodeIp=${MY_IP}
  myRoleResult="$(runRedisCmd -h "$nodeIp" role)"
  myRole="$(echo "$myRoleResult" |head -n1)"
  if [[ "$myRole" == "master" ]]; then
    echo "$nodeIp"
  else
    echo "$myRoleResult" | sed -n '2p'
  fi
}

measure() {
  local groupMatched; groupMatched="$(getGroupMatched)"
  local masterIp replicaDelay
  masterIp="$(findMasterIpByNodeIp)"
  if [[ "$masterIp" != "$MY_IP" ]]; then
    local masterReplication masterOffset myOffset
    masterReplication="$(runRedisCmd -h "${masterIp}" info replication)"
    masterOffset="$(echo "$masterReplication"|grep "master_repl_offset" |cut -d: -f2 |tr -d '\n\r')"
    myOffset=$(echo "$masterReplication" |grep -E "ip=${MY_IP//\./\\.}\,"| cut -d, -f4 |cut -d= -f2|tr -d '\n\r')
    replicaDelay="$((masterOffset-myOffset))"
  else
    replicaDelay=0
  fi

  runRedisCmd info all | awk -F: '{
    if($1~/^(cmdstat_|connected_c|db|instantaneous_ops_per_sec|aof_buffer_length$|repl_backlog_size$|repl_backlog_histlen$|evicted_|expired_k|keyspace_|maxmemory$|role|total_conn|used_memory$)/) {
      r[$1] = gensub(/^(keys=|calls=)?([0-9]+).*/, "\\2", 1, $2);
    }
  }
  END {
    for(k in r) {
      if(k~/^cmdstat_/) {
        cmd = gensub(/^cmdstat_/, "", 1, k)
        m[cmd] += r[k]
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
    m["repl_backlog_avg"] = m["repl_backlog_max"] = m["repl_backlog_min"] = r["repl_backlog_histlen"] / r["repl_backlog_size"] * 10000
    m["aof_buffer_avg"] = m["aof_buffer_max"] = m["aof_buffer_min"] = r["aof_buffer_length"] ? r["aof_buffer_length"] : 0
    m["group_matched"] = "'$groupMatched'"
    m["replica_delay"] = "'$replicaDelay'"
    for(k in m) {
      print k FS m[k]
    }
  }' | jq -R 'split(":")|{(.[0]):.[1]}' | jq -sc add || ( local rc=$?; log "Failed to measure Redis: $metrics"; return $rc )
}

redisCli() {
  local authOpt; [ -z "$REDIS_PASSWORD" ] || authOpt="--no-auth-warning -a $REDIS_PASSWORD"
  if [ $REDIS_TLS_CLUSTER == "yes" ]; then
    echo "/opt/redis/current/redis-cli $authOpt --tls --cert /data/redis/tls/redis.crt --key /data/redis/tls/redis.key --cacert /data/redis/tls/ca.crt -p $REDIS_PORT $@"
  else
    echo "/opt/redis/current/redis-cli $authOpt -p $REDIS_PORT $@"
  fi
}

runRedisCmd() {
  local not_error="getUserList addUser measure runRedisCmd"
  local timeout=5; if [ "$1" == "--timeout" ]; then timeout=$2; shift 2; fi
  local result retCode=0
  result="$(timeout --preserve-status ${timeout}s $(redisCli) $@  2>&1)" || retCode=$?
  if [ "$retCode" != 0 ] || [[ " $not_error " != *" $cmd "* && "$result" == *ERR* ]]; then
    log "ERROR failed to run redis command '$@' ($retCode): $(echo "$result" |tr '\r\n' ';' |tail -c 4000)."
    retCode=$REDIS_COMMAND_EXECUTE_FAIL
  else
    echo "$result"
  fi
  return $retCode
}

getRuntimeNameOfCmd() {
  node_id=${NODE_ID}
  if [[ "$1" == "--node-id" ]]; then  node_id=$2; shift 2; fi
  if [[ "$DISABLED_COMMANDS" == *"$1"* ]];then
    echo -n "${CLUSTER_ID}${node_id}${1}" | md5sum | cut -f 1 -d " "
  else
    echo $1
  fi
}


swapIpAndName() {
  local fields replaceCmd  port=$REDIS_PLAIN_PORT nodes=$REDIS_NODES
  [ "$REDIS_TLS_CLUSTER" == "yes" ] && port=$REDIS_TLS_PORT
  sudo -u redis touch $NODE_CONF_FILE && rotate $NODE_CONF_FILE
  if [ -n "$1" ];then
    nodes="$UPDATE_CHANGE_VXNET $nodes"
    fields='{print "s/ "$4":\\([0-9]\\+\\)@/ "$5":\\1@/g"}'
  else
    fields='{gsub("\\.", "\\.", $5);{print "s/ "$5":\\([0-9]\\+\\)@/ "$4":\\1@/g"}}'
  fi
  replaceCmd="$(echo "$nodes" | xargs -n1 | awk -F/ "$fields"  | paste -sd';');s/:[0-9]\\+@[0-9]\\+ /:$port@${CLUSTER_PORT} /g"
  sed -i "$replaceCmd" $NODE_CONF_FILE
}

configureForRedis(){
  log "configureForRedis Start"
  awk '$0~/^[^ #$]/ ? $1~/^(client-output-buffer-limit|rename-command)$/ ? !a[$1$2]++ : !a[$1]++ : 0' \
    $CHANGED_CONFIG_FILE $DEFAULT_CONFIG_FILE $RUNTIME_CONFIG_FILE.1 > $RUNTIME_CONFIG_FILE
  log "configureForRedis End"
}

rotateTLS() {
  local tlsConf changedConf runtimeConf
  for tlsConf in $TLS_CONF_LIST; do
    changedConf="${tlsConf%:*}"
    runtimeConf="${tlsConf#*:}"
    rotate $runtimeConf
    cat $changedConf > $runtimeConf
  done
}

configureForACL() {
  log "configureForACL Start"
  if [[ "$ENABLE_ACL" == "no" && -e "$ACL_CLEAR" ]] ; then
    rm $ACL_CLEAR -f
  elif [[ "$ENABLE_ACL" == "yes" ]]; then
    if [[ -e "$ACL_CLEAR" ]];then
      awk 'NR==FNR{user[$2]=$0}NR>FNR{if (user[$2]){print user[$2]}else{print}}' \
        $CHANGED_ACL_FILE $RUNTIME_ACL_FILE.1 > $RUNTIME_ACL_FILE
    else
      cat $CHANGED_ACL_FILE > $RUNTIME_ACL_FILE
      sudo -u redis touch $ACL_CLEAR
    fi
  fi
  log "configureForACL End"
}

configure() {
  sudo -u redis touch $RUNTIME_CONFIG_FILE
  rotate $RUNTIME_ACL_FILE
  rotate $RUNTIME_CONFIG_FILE
  swapIpAndName --reverse
  configureForACL
  configureForRedis
  rotateTLS
}

checkFileChanged() {
  local configFile retCode=1
  for configFile in $@ ; do
    [ -f "$configFile.1" ] && cmp -s $configFile $configFile.1 || retCode=0
  done
  return $retCode
}

runCommand(){
  local myRole; myRole="$(getRedisRole $MY_IP)"
  if [[ "$myRole" != "master" ]]; then log "My role is not master, Unauthorized operation";return 0;fi 
  local sourceCmd params maxTime; sourceCmd="$(echo $1 |jq -r .cmd)" \
        params="$(echo $1 |jq -r .params)" maxTime=$(echo $1 |jq -r .timeout)
  local cmd; cmd="$(getRuntimeNameOfCmd $sourceCmd)"
  if [[ "$sourceCmd" == "BGSAVE" ]];then
    log "runCommand BGSAVE"
    backup
  else
    runRedisCmd --timeout $maxTime $cmd $params
  fi
}

getRedisRoles(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  log "firstNodeIpInStableNode: $firstNodeIpInStableNode"
  local rawResult; rawResult="$(runRedisCmd -h "$firstNodeIpInStableNode" cluster nodes)"
  local loadingTag="loading the dataset in memory"
  [[ "$rawResult" == *"$loadingTag"* ]] && return 0
  local firstProcessResult; firstProcessResult="$(echo "$rawResult" |awk 'BEGIN{OFS=","} {split($2,ips,":");print "\""ips[1]"\"","\""gensub(/^(myself,)?(master|slave|fail|pfail){1}.*/,"\\2",1,$3)"\"","\""$4"t""\""}' |sort -t "," -k3)"
  local regexpResult; regexpResult="$(echo "$rawResult" |awk 'BEGIN{ORS=";"}{split($2,ips,":");print "s/"$1"t/"ips[1]"/g"}END{print "s/-t/None/g"}')"
  local secondProcssResult; secondProcssResult="$(echo "$firstProcessResult" |sed "$regexpResult" |awk 'BEGIN{printf "["}{a[NR]=$0}END{for(x in a){printf x==NR ? "["a[x]"]" : "["a[x]"],"};printf "]"}')"
  echo "$secondProcssResult" |jq -c '{"labels":["ip","role","master_ip"],"data":.}'
}

getGroupMatched(){
  local clusterNodes groupMatched="true" targetIp="${1:-$MY_IP}"

  if [[ "$targetIp" == "$MY_IP" ]]; then
    if checkActive "redis-server"; then
      clusterNodes="$(runRedisCmd CLUSTER NODES)"
    else
      clusterNodes="$(cat $NODE_CONF_FILE)"
    fi
  else
    clusterNodes="$(runRedisCmd -h "$targetIp" CLUSTER NODES)"
  fi

  local targetRoleInfo; targetRoleInfo="$(echo "$clusterNodes" |awk 'BEGIN{OFS=" "}{if($0~/'${targetIp//\./\\.}':'$REDIS_PORT'/){print $3,$4}}')"
  local targetRole; targetRole="$(echo "$targetRoleInfo"|awk '{split($1,role,",");print role[2]}')"
  if [[ "$targetRole" == "slave" ]]; then
      local targetMasterId; targetMasterId="$(echo "$targetRoleInfo" |awk '{print $2}')"
      local targetMasterIp; targetMasterIp="$(echo "$clusterNodes" |awk '{if ($1~/'$targetMasterId'/){split($2,ips,":");print ips[1]}}')"
      local ourGid; ourGid="$(echo "$REDIS_NODES" |xargs -n1 |grep -E "/(${targetMasterIp//\./\\.}|${targetIp//\./\\.})$" |cut -d "/" -f1 |uniq)"
      [[ $(echo "$ourGid" |awk '{print NF}') == 1 ]] || {
        log --debug "clusterNodes for $targetIp dismatched group: 
        $clusterNodes
        "
        groupMatched="false"
      }
  fi
  echo $groupMatched
}

getClusterMatched(){
  local clusterNodes clusterMatched="true" targetIp="${1:-$MY_IP}"
  if [[ "$targetIp" == "$MY_IP" ]]; then
    if checkActive "redis-server"; then
      clusterNodes="$(runRedisCmd CLUSTER NODES)"
    else
      clusterNodes="$(grep -v '^vars currentEpoch' $NODE_CONF_FILE)"
    fi
  else
    clusterNodes="$(runRedisCmd -h "$targetIp" CLUSTER NODES)"
  fi

  local expectedNodes; expectedNodes="("
  local node; for node in $REDIS_NODES; do
    node="${node##*/}"
    expectedNodes="$expectedNodes${node//\./\\.}:$REDIS_PORT|"
  done
  expectedNodes="${expectedNodes%|*})"
  if [[ "$(echo "$clusterNodes" |grep -Ev "$expectedNodes")" =~ [a-z0-9]+ ]];then
    log --debug "
      clusterNodes for node $targetIp dismatched cluster：
      $clusterNodes
    "
    clusterMatched="false"
  fi
  echo "$clusterMatched"
}

checkGroupMatched() {
  local targetIps="${1:-$MY_IP}"
  local targetIp; for targetIp in $targetIps; do
    [[ "$(getGroupMatched "$targetIp")" == "true" ]] || {
      log "Found mismatched group for node '$targetIp'."

      return $GROUP_MATCHED_ERR
    }
  done
}

checkClusterMatched() {
  local targetIps="${1:-$MY_IP}"
  local targetIp; for targetIp in $targetIps; do
    [[ "$(getClusterMatched "$targetIp")" == "true" ]] || {
      log "Found mismatched cluster for node '$targetIp'."
      return $CLUSTER_MATCHED_ERR
    }
  done
}

checkGroupMatchedCommand(){
  local needToCheckGroupMatchedCommand needToCheckGroupMatchedCommands
  needToCheckGroupMatchedCommand="${1?command is required}"
  needToCheckGroupMatchedCommands="preScaleOut preScaleIn"
  if [[ "$needToCheckGroupMatchedCommands" == *"$needToCheckGroupMatchedCommand"* ]]; then
    log "needToCheckGroupMatchedCommand: $needToCheckGroupMatchedCommand"
    local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
    checkGroupMatched "$stableNodesIps"
    checkClusterMatched "$stableNodesIps"
  fi
}

getNodesOrder() {
  local nodesStatus nodesList failInfo result
  nodesStatus="$(runRedisCmd CLUSTER NODES | awk -F "[ :]+" '{sub(/^myself,/,"",$4);{print $2"/"$4}}')"
  failInfo="$(echo "$nodesStatus"| xargs -n1 | awk -F "/" '$2 !~ /^(master|slave)$/{print}')"
  if [ "$failInfo" != "" ];then
    log "node fail: $(echo "$failInfo" | xargs -n1 | paste -sd ";" )"
    return $CLUSTER_NODE_ERR
  fi
  nodesList="$(join -1 5 -2 1 -t/ -o 1.1,2.2,1.4 <(echo "$REDIS_NODES" | xargs -n1 | sort -t "/" -k 5 ) <(echo "$nodesStatus" | xargs -n1 | sort))"
  result="$(echo "$nodesList" | xargs -n1 | sort -t"/" -k 2r,2 -k 1rn | cut -f3 -d/ | paste -sd ",")"
  log "$result"
  echo $result
}

getUserList() {
  log "log getUserList"
  [[ "$ENABLE_ACL" == "no" ]] && return $ACL_SWITCH_ERR
  local ACL_CMD=$(getRuntimeNameOfCmd ACL)
  awk '{ a=""
      if ($2!="default") {
        for (i=1;i<=NF;i++){
          if ($i ~ /^[+\-~&]|^(allchannels|resetchannels|allcommands|nocommands)/) {
            a=a$i" "
          }
        }
        print $2"\t"$3"\t"a
      }
    }' <(runRedisCmd $ACL_CMD list) \
  | jq -Rc 'split("\t") | [ . ]' | jq -s add | jq -c '{"labels":["user","switch","rules"],"data":.}'
}

aclList(){
  local ACL_CMD="$(getRuntimeNameOfCmd ACL)"
  runRedisCmd $ACL_CMD list
}

aclManage() {
  local command="$1"; shift 1
  local args=$@
  log "$command start"
  [[ "$ENABLE_ACL" == "no" ]] && {
    log "Add User Error Not ENABLE_ACL."
    return $ACL_SWITCH_ERR
  }
  local user="$(echo $args |jq -r .username)"
  [[ "$user" == "default" ]] && return $ACL_MANAGE_ERR
  local ACL_CMD="$(getRuntimeNameOfCmd ACL)"
  local acl_users="$(runRedisCmd $ACL_CMD USERS|awk 'BEGIN{ORS=" "}$0!="default"')"
  if [[ "$command" == "addUser" ]];then
    local passwd="$(echo -n "$(echo $args |jq -r .passwd)" | openssl sha256 | awk '{print "#"$NF}')"
    local switch="$(echo $args |jq -r .switch)" rules="$(echo $args |jq -j .rules|sed 's/\r//g'| xargs)"
    [[ " $acl_users " =~ " $user " ]] && return $ACL_MANAGE_ERR
    runRedisCmd $ACL_CMD SETUSER $user $switch $passwd $rules || {
      log "Add User Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "setUserRules" ]];then
    local sre_info=$(runRedisCmd $ACL_CMD LIST | awk -v user="$user" '$2==user{txt=$3; for (i=4;i<=NF;i++){if ($i~/^#/){txt=txt" "$i }};print txt}')
    local rules="$(echo $args |jq -j .rules|sed 's/\r//g'| xargs)"
    runRedisCmd $ACL_CMD DELUSER $user || {
      log "DELUSER User Error ($?)"
      return $ACL_MANAGE_ERR
    }
    runRedisCmd $ACL_CMD SETUSER $user $sre_info $rules || {
      log "Set User Rules Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "delUser" ]];then
    [[ " $acl_users " =~ " $user " ]] || return $ACL_MANAGE_ERR
    runRedisCmd $ACL_CMD DELUSER $user || {
      log "DELUSER User Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "setSwitch" ]];then
    [[ " $acl_users " =~ " $user " ]] || return $ACL_MANAGE_ERR
    local switch="$(echo $args |jq -r .switch)"
    runRedisCmd $ACL_CMD SETUSER $user $switch || {
      log "Setuser switch User Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "resetPasswd" ]];then
    [[ " $acl_users " =~ " $user " ]] || return $ACL_MANAGE_ERR
    local passwd="$(echo -n "$(echo $args |jq -r .passwd)" | openssl sha256 | awk '{print "#"$NF}')"
    runRedisCmd $ACL_CMD SETUSER $user resetpass || {
      log "$ACL_CMD SETUSER $user resetpass Error ($?)"
      return $ACL_MANAGE_ERR
    }
    runRedisCmd $ACL_CMD SETUSER $user $passwd || {
      log "$ACL_CMD SETUSER $user $passwd  Error ($?)"
      return $ACL_MANAGE_ERR
    }
  fi

  log "acl $command SAVE"
  runRedisCmd $ACL_CMD SAVE
  log "acl $command end"
}

