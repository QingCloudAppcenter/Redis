# Design for Redis App

```
managed - by appctl (mainly for rename-commands) requiring restart
   |
   V
hotconfig - by user through web console without restart
   |
   V
runtime - the previous configuration actually used by redis
   |
   V
default - with default static values
   |
   V
initial - with default values (mainly replicaof) at cluster/node creation time
```

<details>
<summary>redis.conf</summary>
<p>

## Managed

```
aof-rewrite-incremental-fsync yes
appendfilename appendonly.aof
auto-aof-rewrite-percentage 60
auto-aof-rewrite-min-size 64mb
bind 0.0.0.0
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit pubsub 32mb 8mb 60
client-output-buffer-limit slave 256mb 64mb 60
databases 16
dbfilename dump.rdb
dir /data/redis
hll-sparse-max-bytes 3000
hz 10
logfile /data/redis/logs/redis-server.log
loglevel notice
pidfile /var/run/redis/redis-server.pid
rdbchecksum yes
rdbcompression yes
repl-disable-tcp-nodelay no
save ""
slave-priority 100
slave-read-only yes
slave-serve-stale-data yes
slowlog-max-len 128
stop-writes-on-bgsave-error yes
supervised systemd
tcp-backlog 511
```

## Updated

### Changes Requiring Restart

```
# rename-command by disabled-commands and enable-commands
```

### Changes at Runtime without Restart

```
activerehashing
appendfsync
appendonly
hash-max-ziplist-entries
hash-max-ziplist-value
latency-monitor-threshold
# list-max-ziplist-entries
# list-max-ziplist-value
lua-time-limit
maxclients
maxmemory
maxmemory-policy
maxmemory-samples
min-slaves-max-lag
min-slaves-to-write
no-appendfsync-on-rewrite
notify-keyspace-events
port
repl-backlog-size
repl-backlog-ttl
repl-timeout
requirepass
set-max-intset-entries
slowlog-log-slower-than
slowlog-max-len
tcp-keepalive
timeout
zset-max-ziplist-entries
zset-max-ziplist-value
```

## Sentinel Managed Fields

```
slaveof
```

## Initial Fields

```
```

</p>
</details>

