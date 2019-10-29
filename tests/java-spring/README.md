# Jedis code example

## 1. Configure

### Connect to VIP

Update property `spring.redis.host` in `src/main/resources/application-vip.yml`:
```
spring:
  redis:
    host: 192.168.2.253
```

### Connect through Sentinel

Update property `spring.redis.sentinel` in `src/main/resources/application-sentinel.yml`:
```
spring:
  redis:
    sentinel:
      master: master
      nodes: 192.168.1.11:26379,192.168.1.12:26379,192.168.1.13:26379
```

### Connect to Redis Cluster

Update property `spring.redis.cluster.nodes` in `src/main/resources/application-cluster.yml`:
```
spring:
  redis:
    cluster:
      nodes: 192.168.2.55:6379,192.168.2.57:6379,192.168.2.58:6379
```

## 2. Build

```
./gradlew build
```

## 3. Run

### Connect to VIP

#### by Jedis

```
./gradlew -Dspring.profiles.active=jedis,vip bootRun
```

#### by Lettuce

```
./gradlew -Dspring.profiles.active=lettuce,vip bootRun
```

### Connect to Sentinel

#### by Jedis

```
./gradlew -Dspring.profiles.active=jedis,sentinel bootRun
```

#### by Lettuce

```
./gradlew -Dspring.profiles.active=lettuce,sentinel bootRun
```

### Connect to Redis Cluster

#### by Jedis

```
./gradlew -Dspring.profiles.active=jedis,cluster bootRun
```

#### by Lettuce

```
./gradlew -Dspring.profiles.active=lettuce,cluster bootRun
```
