## migrateSlots.sh 的使用

在使用该脚本之前需要您先下载 redis 并编译，详情请参考[redis 官网](https://redis.io/)

该脚本仅限迁移空的 redis cluster，含有数据的 redis cluster 使用该脚本会导致数据丢失

### 说明

该脚本中您可以配置的变量包含：

REDIS_CLIENT_PARH --> redis-cli 的路径

REDIS_PASSWORD --> 待连接的 redis cluster 的密码

REDIS_PORT --> 待连接的 redis cluster 的端口号

EXPECTED_SLOTS_MAP --> 期望的最终 slots map

### 使用举例

假设某一集群的实际 slots map 为

```shell
redis-cli cluster nodes
add8c28e1e074d78ac5972dbc631daf4f1471e23 192.168.2.35:6379@16379 master - 0 1573027097000 1 connected 0-5460
801bd7de6b0d3f79f6231b5bc6fbf42efba3f903 192.168.2.31:6379@16379 master - 0 1573027097634 2 connected 10922-16383
db23be700f3289aef3debf79239ccbfbd9a647e4 192.168.2.30:6379@16379 slave add8c28e1e074d78ac5972dbc631daf4f1471e23 0 1573027098000 1 connec
ted
692c02f6618908d56dee5e2d9b9515202bec40ab 192.168.2.36:6379@16379 slave c5e0463b4187767c5b4f8eb0417c048f5691845c 0 1573027098637 0 connec
ted
0478e01cf8000d81138c8a566b1ee24f8ac404a3 192.168.2.33:6379@16379 slave 801bd7de6b0d3f79f6231b5bc6fbf42efba3f903 0 1573027096000 2 connec
ted
c5e0463b4187767c5b4f8eb0417c048f5691845c 192.168.2.32:6379@16379 myself,master - 0 1573027096000 0 connected 5461-10921
```

我们需要将 slots map 修改为

```shell
redis-cli cluster nodes
add8c28e1e074d78ac5972dbc631daf4f1471e23 192.168.2.35:6379@16379 myself,master - 0 1573030363000 1 connected 4 8-5460
db23be700f3289aef3debf79239ccbfbd9a647e4 192.168.2.30:6379@16379 slave add8c28e1e074d78ac5972dbc631daf4f1471e23 0 1573030361828 1 connected
692c02f6618908d56dee5e2d9b9515202bec40ab 192.168.2.36:6379@16379 slave c5e0463b4187767c5b4f8eb0417c048f5691845c 0 1573030365840 3 connected
0478e01cf8000d81138c8a566b1ee24f8ac404a3 192.168.2.33:6379@16379 slave 801bd7de6b0d3f79f6231b5bc6fbf42efba3f903 0 1573030364837 2 connected
801bd7de6b0d3f79f6231b5bc6fbf42efba3f903 192.168.2.31:6379@16379 master - 0 1573030362831 2 connected 10922-16383
c5e0463b4187767c5b4f8eb0417c048f5691845c 192.168.2.32:6379@16379 master - 0 1573030364000 3 connected 0-3 5-7 5461-10921
```

我们只需要修改
```shell
EXPECTED_SLOTS_MAP="
192.168.2.35/[4],[8-5460]
192.168.2.32/[0-3],[5-7],[5461-10921]
192.168.2.31/[10922-16383]
"
```
并运行 ./migrateSlots.sh main ，等待 slots 迁移完即可
