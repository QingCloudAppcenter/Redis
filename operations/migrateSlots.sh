#!/bin/bash
REDIS_CLIENT_PARH="/root/workspace/apps/redis/ansible/roles/redis-server/files/tmp/redis-5.0.5/src/redis-cli"
REDIS_PASSWORD=""
REDIS_PORT=6379
# 最终达到的slotsmap
# master-ip/slot-map 
# slot-map:[0-10],[11-12]  or [11] or [100-200] 
EXPECTED_SLOTS_MAP="
192.168.2.9/[0-3000]
192.168.2.10/[3001-6000]
192.168.2.11/[6001-10000]
192.168.2.13/[10001-13000]
192.168.2.16/[13001-16383]
"
ALL_NODES_IPS="$(echo $EXPECTED_SLOTS_MAP |xargs -n1 |sort |awk -F/ '{print $1}')"
NODE_COUNTS=$(echo "$ALL_NODES_IPS" |wc -l)
END_POINT="$(echo "$ALL_NODES_IPS" |head -n1)"


log() {
  if [ "$1" == "--debug" ]; then
    [ "$APPCTL_ENV" == "dev" ] || return 0
    shift
  fi
  logger -S 5000 -t appctl --id=$$ -- "[cmd=$command args='$args'] $@"
}

runRedisCmd() {
  local timeout=5; if [ "$1" == "--timeout" ]; then timeout=$2 && shift 2; fi
  local authOpt; [ -z "$REDIS_PASSWORD" ] || authOpt="--no-auth-warning -a $REDIS_PASSWORD"
  local result retCode=0
  result="$(timeout --preserve-status ${timeout}s $REDIS_CLIENT_PARH $authOpt -p "$REDIS_PORT" $@ 2>&1)"
  echo "$result"
}

changeDestNodeToImporting(){
  local destIp=${1?Pelease provide your destIp}
  local opratedSlot=${2?Pelease provide your opratedSlot}
  local sourceNodeId=${3?Pelease provide your sourceNodeId}
  runRedisCmd -c -h $destIp cluster setslot $opratedSlot importing $sourceNodeId
}

changeSourceNodeToMigrating(){
  local sourceIp=${1?Pelease provide your sourceIp}
  local opratedSlot=${2?Pelease provide your opratedSlot}
  local destNodeId=${3?Pelease provide your destNodeId}
  runRedisCmd -c -h $sourceIp cluster setslot $opratedSlot migrating $destNodeId
}

communicateWithAllNodes(){
  local opratedSlot=${1?Pelease provide your slot}
  local destNodeId=${2?Pelease provide your destNodeId}
  local allMasterNodeIps; allMasterNodeIps="$(awk '{split($3,ip,":");print ip[1]}' <(getClusterInfoByCheck))"
  local ip; for ip in $allMasterNodeIps;do
	  runRedisCmd -c -h $ip cluster setslot $opratedSlot node $destNodeId
  done
}

getClusterInfoByCheck(){
  local topTag="Performing Cluster Check"
  local lastTag="OK] All nodes agree about slots configuration."
  local result; result="$(runRedisCmd -h $END_POINT --cluster check $END_POINT:$REDIS_PORT)"
  local rowsForResult; rowsForResult=$(echo "$result" |wc -l)
  local topTagNum=$(echo "$result" |grep -n "$topTag" |awk -F: '{print $1}')
  local lastTagNum=$(echo "$result" |grep -n "$lastTag" |awk -F: '{print $1}')
  echo "$result" |head -n $(($lastTagNum-1)) |tail -n $(($lastTagNum-$topTagNum-1)) |xargs -n3 -d"\n" |awk -F "    " '$2~/master$/{print $1,"/"$2}'
}

getSourceIpBySlotScope(){
  local slotScope; slotScope="${1?Pelase provide your slot-scop}"
  local clusterInfo; clusterInfo="$(getClusterInfoByCheck)"
  echo "$clusterInfo" |grep "$slotScope" |awk 'BEGIN{FS="/"}{print $1}' |awk '{split($3,ip,":");print ip[1]}'
}

getSourceNodeIpBySlot(){
  local slot=${1?Pelease provide your slot}
  local clusterInfo; clusterInfo="$(getClusterInfoByCheck)"
  local slotsInfo; slotsInfo=$(echo "$clusterInfo" |awk -F/ '{print $2}' |awk '
    BEGIN{
      count=0
    };
    {
      count++;split($1,slots,":");a[count]=slots[2]
    }
    END{
      for(ct in a)
      {printf ct<NR ? a[ct]"," : a[ct]}
    }' | awk '{gsub(","," ");gsub("-",",");gsub("[\\[\\]]","");print $0}')
  
  local slots; for slots in $slotsInfo; do
    local slotsCount; slotsCount=$(echo $slots |awk 'BEGIN{FS=","}END{print NF}')
    if [ $slotsCount == 1 ];then
      [[ $slot == $slots ]] && getSourceIpBySlotScope $slots
    else
      local firstSlot; firstSlot=$(echo $slots |awk 'BEGIN{FS=","}{print $1}')
      local secondSlot; secondSlot=$(echo $slots |awk 'BEGIN{FS=","}{print $2}')
      if [[ $slot -ge $firstSlot && $slot -le $secondSlot ]]; then
        getSourceIpBySlotScope ${slots//,/-}
      fi
    fi
  done
}

getDestIpBySlotScope(){
  local slotScope; slotScope=${1? Pelease provide your slotScope}
  echo "$EXPECTED_SLOTS_MAP" |grep "$slotScope" |awk -F/ '{print $1}'
}

getDestNodeIpBySlot(){
  local slot; slot=${1? Pelease provide your slot}
  local slotsInfo;slotsInfo="$(echo "$EXPECTED_SLOTS_MAP" |awk -F/ 'BEGIN{ORS=" "}{print $2}' |awk '{gsub(","," ");gsub("-",",");gsub("[\\[\\]]","");print $0}')"
  local slots; for slots in $slotsInfo; do
    local slotsCount; slotsCount=$(echo $slots |awk 'BEGIN{FS=","}END{print NF}')
    if [ $slotsCount == 1 ];then
      [[ $slot == $slots ]] && getDestIpBySlotScope $slots
    else
      local firstSlot; firstSlot=$(echo $slots |awk 'BEGIN{FS=","}{print $1}')
      local secondSlot; secondSlot=$(echo $slots |awk 'BEGIN{FS=","}{print $2}')
      if [[ $slot -ge $firstSlot && $slot -le $secondSlot ]]; then
        getDestIpBySlotScope ${slots//,/-}
      fi
    fi
  done
}

getNodeIdByIp(){
  local ip; ip=${1?Pelease provide your ip}
  grep "$ip" <(getClusterInfoByCheck) |awk '{print $2}'
}

migrateSlot(){
  waitUntilAllNodesIsOk "$ALL_NODES_IPS"
  local migratedSlot=${1?Pelease provide your Slot}
  local sourceIp; sourceIp=$(getSourceNodeIpBySlot $migratedSlot)
  local destIp; destIp=$(getDestNodeIpBySlot $migratedSlot)
  local sourceNodeId; sourceNodeId=$(getNodeIdByIp $sourceIp)
  local destNodeId; destNodeId=$(getNodeIdByIp $destIp)
  [[ "$sourceIp" != "$destIp" ]] || { echo "slot $slot ip 一致";
    return 0
  }
  log "Migrate slot $slot start"
  log "changeDestNodeToImporting for $migratedSlot"
  changeDestNodeToImporting $destIp $migratedSlot $sourceNodeId
  log "changeSourceNodeToMigrating for $migratedSlot"
  changeSourceNodeToMigrating $sourceIp $migratedSlot $destNodeId
  log "communicateWithAllNodes"
  communicateWithAllNodes $migratedSlot $destNodeId
  log "Migrate slot $slot end"
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

waitUntilAllNodesIsOk(){
  local ip; for ip in ${1?stableNodesIps is required};do
    log --debug "check node $ip"
    retry 30 1 0 checkRedisStateIsOkByInfo $ip
    retry 30 1 0 checkForAllAgree $ip
  done
}

checkRedisStateIsOkByInfo(){
  local oKTag="cluster_state:ok" 
  local infoResponse=$(runRedisCmd -h ${1?node ip is required} cluster info)
  echo "$infoResponse" |grep -q "$oKTag"
}

getRedisCheckResponse(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(echo "$ALL_NODES_IPS" |head -n1)"
  runRedisCmd -h "${1?node Ip is required}" --cluster check $firstNodeIpInStableNode:$REDIS_PORT
}

checkForAllAgree(){
  local checkResponse; checkResponse=$(getRedisCheckResponse ${1?node Ip is required}) allAgreetag="OK] All nodes agree about slots configuration."
  echo "$checkResponse" |grep -q "$allAgreetag"
}

main(){
  local slot; for slot in $(seq 0 16383);do
    log "迁移 $slot"
    migrateSlot $slot
  done
}

set -eo pipefail
command=$1
args=${@:2}

$command $args

