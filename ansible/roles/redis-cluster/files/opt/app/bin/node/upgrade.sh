#!/usr/bin/env bash

set -eo pipefail

main() {
  local backupName=$(date +%y%m%d.%H%M%S)
  local backupDir=/data/backup/$backupName
  mkdir -p $backupDir/opt/
  rsync -aAX /opt/app/ $backupDir/opt/app/
  rsync -aAX /upgrade/opt/app/bin/node/ /opt/app/bin/node/
  ln -snf $backupName $(dirname $backupDir)/current
}

main $@
