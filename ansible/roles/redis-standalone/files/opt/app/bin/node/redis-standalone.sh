FIND_MASTER_IP_ERR=210
LEAVING_REDIS_NODES_IS_NONE_ERR=211
LEAVING_REDIS_NODES_INCLUDE_MASTER_ERR=212
MASTER_SALVE_SWITCH_WHEN_DEL_NODE_ERR=213
LEAVING_REDIS_NODES_INCLUDE_SENTINEL_NODE=214
REDIS_COMMAND_EXECUTE_FAIL_ERR=220
RDB_FILE_EXIST_ERR=221
RDB_FILE_CHECK_ERR=222
CLUSTER_STATUS_ERR=223
NODES_NUMS_ERR=224
CONFIRM_ERR=225
BEYOND_DATABASES_ERR=226
CLUSTER_STATS_ERR=227
SENTINEL_RESET_ERR=228
SENTINEL_FLUSH_CONFIG_ERR=229
SENTINEL_START_ERR=230
REDIS_START_ERR=231
REDIS_STOP_ERR=232


initNode() {
  local redisPath="/data/redis"
  local caddyPath="/data/caddy"
  mkdir -p $redisPath/logs $caddyPath/upload
  chown -R redis.svc $redisPath
  chown -R caddy.svc $caddyPath
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _initNode
}

start() {
  isNodeInitialized || execute initNode
  configure && _start
}

stop() {
  if [ -z "$LEAVING_REDIS_NODES" ] && isSvcEnabled redis-sentinel; then
    stopSvc redis-sentinel
    local sentinelHost; for sentinelHost in $STABLE_REDIS_NODES; do
      if [[ "${sentinelHost##*/}" != "$MY_IP" ]]; then
        retry 150 0.1 0 checkSentinelStopped ${sentinelHost##*/} || log "WARN: sentinel '$sentinelHost' is still up."
      fi
    done
  fi

  _stop
}

revive() {
  checkSvc redis-server || configureForRedis
  _revive $@
  checkVip || setUpVip
}

findMasterIpByNodeIp(){
  local myRoleResult myRole nodeIp=${1:-$MY_IP}
  myRoleResult="$(runRedisCmd -h $nodeIp role)"
  myRole="$(echo "$myRoleResult" |head -n1)"
  if [[ "$myRole" == "master" ]]; then
    echo "$nodeIp"
  else
    echo "$myRoleResult" | sed -n '2p'
  fi
}

measure() {
  local masterIp replicaDelay; masterIp="$(findMasterIpByNodeIp)"
  if [[ "$masterIp" != "$MY_IP" ]]; then
    local masterReplication="$(runRedisCmd -h $masterIp info replication)"
    local masterOffset=$(echo "$masterReplication"|grep "master_repl_offset" |cut -d: -f2 |tr -d '\n\r')
    local myOffset=$(echo "$masterReplication" |grep -E "ip=${MY_IP//\./\\.}\,"| cut -d, -f4 |cut -d= -f2|tr -d '\n\r')
    replicaDelay=$(($masterOffset-$myOffset))
  else
    replicaDelay=0
  fi
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
    m["replica_delay"] = "'$replicaDelay'"
    for(k in m) print k FS m[k]
  }' | jq -R 'split(":")|{(.[0]):.[1]}' | jq -sc add || ( local rc=$?; log "Failed to measure Redis: $metrics" && return $rc )
}

checkMasterNotLeaving() {
  local master; master="$(findMasterIp)" || return $FIND_MASTER_IP_ERR
  if [[ "$LEAVING_REDIS_NODES " == *"/$master "* ]]; then return $LEAVING_REDIS_NODES_INCLUDE_MASTER_ERR; fi
}

findStableNodesCount() {
  echo "$STABLE_REDIS_NODES" |wc -w
}

preScaleIn() {
  [ -n "$LEAVING_REDIS_NODES" ] || return $LEAVING_REDIS_NODES_IS_NONE_ERR
  checkMasterNotLeaving

  # 防止最终计划剩余3个节点的时候，删除了 sentinel 节点
  if [[ $(findStableNodesCount) -ge 3 ]];then
    log --debug "check wether contain sentinel nodes"
    local firstToThirdNode="$(getSentinelNodes)"
    log "LEAVING_REDIS_NODES: $LEAVING_REDIS_NODES"
    log "sentinel nodes: $firstToThirdNode"
    local node;for node in $firstToThirdNode;do
      echo "$LEAVING_REDIS_NODES" |grep -vq "$node" || {
        log "leaving nodes include sentinel node: $node"
        return $LEAVING_REDIS_NODES_INCLUDE_SENTINEL_NODE
      }
    done
  fi
}

getSentinelNodes(){
  eval echo "$STABLE_REDIS_NODES $LEAVING_REDIS_NODES" |xargs -n1| sort -n -t'/' -k1| xargs|cut -d" " -f1-3
}

getStableNodesIps(){
  log --debug "STABLE_REDIS_NODES: $STABLE_REDIS_NODES"
  log --debug "LEAVING_REDIS_NODES: $LEAVING_REDIS_NODES"
  echo "$STABLE_REDIS_NODES" |xargs -n1 |awk -F/ '{print $3}'
}

destroy() {
  if [[ -n "$LEAVING_REDIS_NODES" ]]; then
    checkMasterNotLeaving
    execute stop
    checkVip || ( execute start && return $MASTER_SALVE_SWITCH_WHEN_DEL_NODE_ERR )
    local stableNodesCount=$(findStableNodesCount)
    log "stableNodesCount: $stableNodesCount"
    [[ $stableNodesCount -ne 1 ]] || {
      log "skip reset sentinel"
      return 0
      }
    # determine redis-server is down for leaving nodes
    log --debug "LEAVING_REDIS_NODES: $LEAVING_REDIS_NODES
    MY_IP：$MY_IP
    return code: $([[ "$LEAVING_REDIS_NODES " == *"/$MY_IP "* ]];echo $?)
    "
    if [[ "${LEAVING_REDIS_NODES%% *} " == *"/$MY_IP "* ]]; then
      log --debug "start check redis-server down"
      local leavingNode; for leavingNode in $LEAVING_REDIS_NODES; do
        log "${leavingNode##*/} is down?"
        retry 150 0.1 0 checkRedisStopped ${leavingNode##*/} || {
          log "WARN: redis-server '$leavingNode' is still up."
          return $REDIS_STOP_ERR
          }
        log "${leavingNode##*/} is down"
      done
      # 检查剩余的节点服务状态是 ok 的
      log --debug "REDIS_NODES: $STABLE_REDIS_NODES"
      log --debug "LEAVING_REDIS_NODES: $LEAVING_REDIS_NODES"
      local stableNodesIps masterIp; stableNodesIps="$(getStableNodesIps)"
      log "stableNodesIps: $stableNodesIps"
      masterIp=$(findMasterIpByNodeIp $(echo "$stableNodesIps" |head -n1))
      log --debug "masterIp: $masterIp"
      local replicaResultOnline="$(runRedisCmd -h $masterIp info replication |grep "state=online")"
      log --debug "replicaResultOnline: $replicaResultOnline"
      local stableNodeIp; for stableNodeIp in $stableNodesIps; do
        log "$stableNodeIp is ok?"
        [[ "$stableNodeIp" == "$masterIp" ]] || echo "$replicaResultOnline" |grep -q "ip=${stableNodeIp//\./\\.}," || return $CLUSTER_STATS_ERR
        log "$stableNodeIp is ok"
      done
      # 对所有的 sentinel 节点执行 sentinel reset
      log "start sentinel reset"
      local sentinelNodes; sentinelNodes="$(getSentinelNodes)"
      log --debug "sentinelNodes: $sentinelNodes"
      local sentinelNode; for sentinelNode in $sentinelNodes; do
        log "${sentinelNode##*/} reset?"
        runRedisCmd -h ${sentinelNode##*/} -p $SENTINEL_PORT SENTINEL RESET $SENTINEL_MONITOR_CLUSTER_NAME || return $SENTINEL_RESET_ERR
        runRedisCmd -h ${sentinelNode##*/} -p $SENTINEL_PORT SENTINEL FLUSHCONFIG || return $SENTINEL_FLUSH_CONFIG_ERR
        log "${sentinelNode##*/} reset"
      done

    fi

  fi
}

scaleIn() {
  if [[ $(findStableNodesCount) -eq 1 ]]; then
    stopSvc redis-sentinel && rm -f $runtimeSentinelFile*
  fi 
}

restore() {
  local scopeForRedis logsDirForRedis runtimeConfigFile
  scopeForRedis=/data/redis
  logsDirForRedis=$scopeForRedis/logs
  runtimeConfigFile=$scopeForRedis/redis.conf
  local oldValue; oldValue="$(awk '$1=="appendonly" {print $2}' $runtimeConfigFile)"
  log "Old Value is $oldValue for appendonly before restore"
  log "Start restore"
  # 仅保留 dump.rdb 文件
  find /data/redis -mindepth 1 ! -name dump.rdb -delete
  mkdir -p $logsDirForRedis
  chown -R redis.svc $logsDirForRedis

  # restore 方案可参考：https://community.pivotal.io/s/article/How-to-Backup-and-Restore-Open-Source-Redis
  # 修改 appendonly 为no (该操作位于 configForRestore) -- > 启动 redis-server --> 等待数据加载进内存 --> 生成新的 aof 文件 -->将 appendonly 属性改回
  execute start
  retry 240 1 $EC_RESTORE_LOAD_ERR checkLoadDataDone
  if [[ "$oldValue" == "yes" ]]; then
    runRedisCmd $(getRuntimeNameOfCmd BGREWRITEAOF)
    retry 80 3 $EC_RESTORE_BGREWRITEAOF_ERR checkReWriteAofDone
    local cmd; cmd="$(getRuntimeNameOfCmd CONFIG)"
    [[ $(runRedisCmd $cmd SET appendonly $oldValue) == "OK" ]] && [[ $(runRedisCmd $cmd REWRITE) == "OK" ]] || return $EC_RESTORE_UPDATE_APPENDONLY_ERR
  fi     
}

checkLoadDataDone(){
  runRedisCmd PING |grep -vq "loading the dataset in memory"
}

checkReWriteAofDone(){
  runRedisCmd info Persistence|grep -q "aof_rewrite_in_progress:0"
}

getRuntimeNameOfCmd() {
  if echo -e $DISABLED_COMMANDS | grep -oq $1;then
    encodeCmd $1
  else
    echo $1
  fi
}

runtimeSentinelFile=/data/redis/sentinel.conf

getmasterIpFromSentinelNodes(){
  log "getmasterIpFromSentinelNodes"
  local sentinelNodes firstSentinelNode; sentinelNodes="$(getSentinelNodes)"
  log --debug "sentinelNodes: $sentinelNodes"
  local sentinelNode; for sentinelNode in $sentinelNodes; do
    log "check ${sentinelNode##*/}?"
    retry 60 0.5 0 checkSentinelStarted ${sentinelNode##*/} || {
      log "${sentinelNode##*/} sentinel is not started"
      return $SENTINEL_START_ERR
    }
    retry 60 0.5 0 checkRedisStarted ${sentinelNode##*/} || {
      log "${sentinelNode##*/} redis-server is not started"
      return $REDIS_START_ERR
    }
    log "check ${sentinelNode##*/} end"
  done
  firstSentinelNode="$(echo "$sentinelNodes" |cut -d" " -f1)"
  log --debug "firstSentinelNode: $firstSentinelNode"
  log --debug "result: $(runRedisCmd --ip ${firstSentinelNode##*/} -p $SENTINEL_PORT sentinel get-master-addr-by-name $SENTINEL_MONITOR_CLUSTER_NAME)"
  local rc=0
  runRedisCmd --ip ${firstSentinelNode##*/} -p $SENTINEL_PORT sentinel get-master-addr-by-name $SENTINEL_MONITOR_CLUSTER_NAME |xargs \
        |awk '{if ($2 == '$REDIS_PORT') {print $1} else {'rc'=1;exit 1}}' || \
        log "get master ip from ${firstSentinelNode##*/} fail! rc=$rc"
  return $rc
}

getInitMasterIp() {
  local firstRedisNode=${STABLE_REDIS_NODES%% *}
  echo -n ${firstRedisNode##*/}
}

# 防止 revive 时从本地文件获取，导致双主以及vip 解绑
getMasterIpForRevive() {
  local sentinelNodes="$(getSentinelNodes)"
  log --debug "sentinelNodes: $sentinelNodes"
  log --debug "MY_IP: $MY_IP"
  if [[ "$sentinelNodes " == *"/$MY_IP "* ]]; then
    local rc=0
    if isSvcEnabled redis-sentinel;then
      local otherFirstNodeIp="$(echo $STABLE_REDIS_NODES |awk 'BEGIN{RS=" "} {if ($1!~/'$MY_IP'$/) {print $1;exit 0}}'|awk 'BEGIN{FS="/"} {print $3}')"
      runRedisCmd --ip ${otherFirstNodeIp} -p $SENTINEL_PORT sentinel get-master-addr-by-name $SENTINEL_MONITOR_CLUSTER_NAME |xargs \
        |awk '{if ($2 == '$REDIS_PORT') {print $1} else {'rc'=1;exit 1}}' || \
          log "get master ip from ${otherFirstNodeIp} fail! rc=$rc"
      return $rc
    else
      log "get masterIp from init"
      getInitMasterIp
    fi
  else
    getmasterIpFromSentinelNodes
  fi
}

getMasterIpByConf() {
  local sentinelNodes="$(getSentinelNodes)"
  log --debug "sentinelNodes: $sentinelNodes"
  log --debug "MY_IP: $MY_IP"
  if [[ "$sentinelNodes " == *"/$MY_IP "* ]]; then
    isSvcEnabled redis-sentinel && [ -f "$runtimeSentinelFile" ] \
      && awk 'BEGIN {rc=1} $0~/^sentinel monitor '$SENTINEL_MONITOR_CLUSTER_NAME' / {print $4; rc=0} END {exit rc}' $runtimeSentinelFile \
      || getInitMasterIp
  else
    getmasterIpFromSentinelNodes
  fi || getInitMasterIp
}

findMasterIp() {
  if [[ "$command" == "revive" ]];then
    getMasterIpForRevive
  else
    getMasterIpByConf
  fi
}

checkBgsaveDone(){
  local lastsaveCmd; lastsaveCmd="$(getRuntimeNameOfCmd "LASTSAVE")"
  [[ $(runRedisCmd --ip $REDIS_VIP $lastsaveCmd) > ${1?Lastsave time is required} ]]
}

backup(){
  log "Start backup"
  local lastsave="LASTSAVE" bgsave="BGSAVE"
  local lastsaveCmd bgsaveCmd; lastsaveCmd="$(getRuntimeNameOfCmd $lastsave)" bgsaveCmd="$(getRuntimeNameOfCmd $bgsave)"
  local lastTime; lastTime="$(runRedisCmd --ip $REDIS_VIP $lastsaveCmd)"
  runRedisCmd --ip $REDIS_VIP $bgsaveCmd
  retry 60 1 $EC_BACKUP_ERR checkBgsaveDone $lastTime
  log "backup successfully"
}

findMasterNodeId() {
  echo $STABLE_REDIS_NODES | xargs -n1 | awk -F/ '$3=="'$(findMasterIp)'" {print $2}'
}

runRedisCmd() {
  local redisIp=$MY_IP maxTime=5 result retCode=0
  if [[ "$1" == "--timeout" ]]; then maxTime=$2 && shift 2;fi
  if [ "$1" == "--ip" ]; then redisIp=$2 && shift 2; fi
  result="$(timeout --preserve-status ${maxTime}s /opt/redis/current/redis-cli -h $redisIp --no-auth-warning -a "$REDIS_PASSWORD" -p $REDIS_PORT $@ 2>&1)" || retCode=$?
  if [ "$retCode" != 0 ] || [[ "$result" == *ERR* ]]; then
    log "ERROR failed to run redis command '$@' ($retCode): $result." && retCode=$REDIS_COMMAND_EXECUTE_FAIL_ERR
  else
    echo "$result"
  fi
  return $retCode
} 

checkVip() {
  local vipResponse; vipResponse="$(runRedisCmd --ip $REDIS_VIP ROLE | sed -n '1{p;q}')"
  [ "$vipResponse" == "master" ]
}

setUpVip() {
  local masterIp; masterIp="${1:-$(findMasterIp)}"
  local myIps; myIps="$(hostname -I)"
  log "setting up vip: [master=$masterIp me=$myIps Vip=$REDIS_VIP] ..."
  if [ "$MY_IP" == "$masterIp" ]; then
    [[ " $myIps " == *" $REDIS_VIP "* ]] || {
      log "This is the master node, though VIP is unbound. Binding VIP ..."
      bindVip
    }
  else
    [[ " $myIps " != *" $REDIS_VIP "* ]] || {
      log "This is not the master node, though VIP is still bound. Unbinding VIP ..."
      unbindVip
    }
  fi
  log "setUpVip successful"
}

bindVip() {
  ip addr add $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: already bound
  arping -q -c 3 -A $REDIS_VIP -I eth0
}

unbindVip() {
  ip addr del $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: not bound
}

checkSentinelStarted(){
  nc -z -w3 $1 $SENTINEL_PORT
}

checkSentinelStopped() {
  ! checkSentinelStarted
}

checkRedisStarted(){
  nc -z -w3 $1 $REDIS_PORT
}

checkRedisStopped() {
  ! checkRedisStarted
}

encodeCmd() {
  echo -n ${1?command is required}${CLUSTER_ID} | sha256sum | cut -d' ' -f1
}

nodesFile=/data/redis/nodes
rootConfDir=/opt/app/conf/redis-standalone
changedConfigFile=$rootConfDir/redis.changed.conf
changedSentinelFile=$rootConfDir/sentinel.changed.conf
reload() {
  isNodeInitialized || return 0

  if [ "$1" == "redis-server" ]; then
    if [ -n "${JOINING_REDIS_NODES}" ]; then
      log --debug "scaling out ..."
      # 仅在从单个节点增加的时候才启动 sentinel
      if [[ $(findStableNodesCount) -eq 1 ]]; then
        configure && startSvc redis-sentinel
      fi
    elif [ -n "${LEAVING_REDIS_NODES}" ]; then
      log --debug "scaling in ..."
    elif checkFileChanged $changedConfigFile; then
      execute restart
    elif checkFileChanged $changedSentinelFile; then
      configureForSentinel && _reload redis-sentinel
    fi
  else
    _reload $@
  fi
}

checkFileChanged() {
  ! ([ -f "$1.1" ] && cmp -s $1 $1.1)
}

configureForRedis() {
  log --debug "exec configureForRedis"
  local runtimeConfigFile=/data/redis/redis.conf defaultConfigFile=$rootConfDir/redis.default.conf \
        slaveofFile=$rootConfDir/redis.slaveof.conf
  sudo -u redis touch $runtimeConfigFile && rotate $runtimeConfigFile
  local masterIp; masterIp="$(findMasterIp)" 
  log --debug "masterIp is $masterIp"
  # flush every time even no master IP switches, but port is changed or in case double-master in revive
  [ "$MY_IP" == "$masterIp" ] && > $slaveofFile || echo -e "slaveof $masterIp $REDIS_PORT\nreplicaof $masterIp $REDIS_PORT" > $slaveofFile

  awk '$0~/^[^ #$]/ ? $1~/^(client-output-buffer-limit|rename-command)$/ ? !a[$1$2]++ : !a[$1]++ : 0' \
    $changedConfigFile $slaveofFile $runtimeConfigFile.1 $defaultConfigFile > $runtimeConfigFile
}

configureForChangeVxnet() {
  log --debug "exec configureForChangeVxnet"
  local runtimeConfigFile=/data/redis/redis.conf 
  sudo -u redis touch $nodesFile && rotate $nodesFile
  echo "$STABLE_REDIS_NODES" | xargs -n1 > $nodesFile

  if checkFileChanged $nodesFile; then
    log "IP addresses changed from [$(paste -s $nodesFile.1)] to [$(paste -s $nodesFile)]. Updating config files accordingly ..."
    local replaceCmd="$(join -j1 -t/ -o1.3,2.3 $nodesFile.1 $nodesFile | sed 's#/# / #g; s#^#s/ #g; s#$# /g#g' | paste -sd';')"
    sed -i "$replaceCmd" $runtimeConfigFile $runtimeSentinelFile
  fi
}

configureForSentinel() {
  log --debug "exec configureForSentinel"
  local monitorFile=$rootConfDir/sentinel.monitor.conf
  sudo -u redis touch $runtimeSentinelFile && rotate $runtimeSentinelFile
  local masterIp; masterIp="$(findMasterIp)"
  log --debug "masterIp is $masterIp"
  # flush every time even no master IP switches, but port is changed
  echo "sentinel monitor $SENTINEL_MONITOR_CLUSTER_NAME $masterIp $REDIS_PORT 2" > $monitorFile

  if isSvcEnabled redis-sentinel; then
    # 处理升级过程中监控名称的改变
    sed -i 's/master/'"$SENTINEL_MONITOR_CLUSTER_NAME"'/g' $runtimeSentinelFile.1
    # 防止莫名的单个$0 出现
    awk '(NF>1 && $0~/^[^ #$]/) ? $1~/^sentinel/ ? $2~/^rename-/ ? !a[$1$2$3$4]++ : $2~/^(anno|deny-scr)/ ? !a[$1$2]++ : !a[$1$2$3]++ : !a[$1]++ : 0' \
      $monitorFile $changedSentinelFile <(sed -r '/^sentinel (auth-pass '"$SENTINEL_MONITOR_CLUSTER_NAME"'|rename-slaveof|rename-config|known-replica|known-slave)/d' $runtimeSentinelFile.1) > $runtimeSentinelFile
  else
    rm -f $runtimeSentinelFile*
  fi
}

configureForRestore(){
  if [[ "$command" =~ ^(restore|restoreByCustomRdb)$ ]]; then
    local runtimeConfigFile=/data/redis/redis.conf
    sed -i 's/^appendonly.*/appendonly no/g ' $runtimeConfigFile
  fi
}

configure() {
  configureForChangeVxnet
  configureForSentinel
  configureForRedis  
  local masterIp; masterIp="$(findMasterIp)"
  configureForRestore
  setUpVip $masterIp
}

runCommand(){
  local db="$(echo $1 |jq .db)" flushCmd="$(echo $1 |jq -r .cmd)" \
        params="$(echo $1 |jq -r .params)" maxTime=$(echo $1 |jq -r .timeout)
  local cmd="$(getRuntimeNameOfCmd $flushCmd)"
  if [[ "$flushCmd" == "BGSAVE" ]];then
    log "runCommand BGSAVE"
    backup
  else
    if [[ $db -ge $REDIS_DATABASES ]]; then return $BEYOND_DATABASES_ERR; fi
    runRedisCmd --timeout $maxTime --ip $REDIS_VIP -n $db $cmd $params
  fi
}

getMyRole(){
  runRedisCmd --ip $MY_IP ROLE | sed -n '1{p;q}'
}


restoreByCustomRdb(){
  local isConfirm; isConfirm="$(echo $1 |jq .confirm)"
  [[ "$isConfirm" == "\"yes\"" ]] || {
    log "user dont accept tips"
    return $CONFIRM_ERR
  }
  local uploadedRDBFile redisCheckRdbPath destRDBfile
  uploadedRDBFile="/data/caddy/upload/dump.rdb" redisCheckRdbPath="/opt/redis/current/redis-check-rdb" destRDBfile="/data/redis/dump.rdb"

  # 仅允许单个节点做恢复数据操作
  [[ $(echo "$STABLE_REDIS_NODES" |xargs -n1 |wc -l) == 1 ]] || return $NODES_NUMS_ERR
  # 检查 RDB 文件是否 OK
  local myRole; myRole="$(getMyRole)"
  [[ "$myRole" == "master" ]] || {
    log "[ERRO] cluster status is $myRole"
    return $CLUSTER_STATUS_ERR
  }
  [[ -e $uploadedRDBFile ]] || {
    log "[ERRO] RDB file is not exist"
    return $RDB_FILE_EXIST_ERR
  }
  $redisCheckRdbPath $uploadedRDBFile || {
    log "[ERRO] RDB file format err"
    return $RDB_FILE_CHECK_ERR
  }

  execute stop

  cp -f $uploadedRDBFile $destRDBfile
  restore
  rm -rf $uploadedRDBFile
}

check(){
  local ignoreCommand="(restoreByCustomRdb)"
  ps -ef |grep -E "$ignoreCommand" |grep -vq grep && {
    log "[Warning]Detected process $ignoreCommand，skip check"
    return 0
  }
  [[ "${REVIVE_ENABLED:-"true"}" == "true" ]] || return 0
  _check
  checkVip
}

getRedisRoles(){ 
  local stableNodesCount=$(findStableNodesCount)
  local node nodeIp myRole allow_deletion counter=0; for node in $(echo "$STABLE_REDIS_NODES" |sort -n -t"/" -k1); do
    counter=$(($counter+1))
    nodeIp="$(echo "$node" |cut -d"/" -f3)"
    myRole="$(runRedisCmd --ip "$nodeIp" role | head -n1 || echo "unknown")"
    if [[ $stableNodesCount -gt 3 ]]; then
      if [[ $counter -le 3 ]];then allow_deletion="false";else allow_deletion="true";fi
    else
      if [[ "$myRole" == "master" ]]; then allow_deletion="false";else allow_deletion="true";fi
    fi
    echo "$nodeIp $myRole $allow_deletion"
  done | jq -Rc 'split(" ") | [ . ]' | jq -s add | jq -c '{"labels":["ip","role","allow_deletion"],"data":.}'
}
