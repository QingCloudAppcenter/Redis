# Java/Spring code example

## 1. Configure

### Connect through Sentinel

Update property `spring.redis.sentinel` in `src/main/resources/application-sentinel.yml`:
```
spring:
  redis:
    sentinel:
      master: master
      nodes: 192.168.1.11:26379,192.168.1.12:26379,192.168.1.13:26379
```

### Connect to VIP

Update property `spring.redis.host` in `src/main/resources/application-vip.yml`:
```
spring:
  redis:
    host: 192.168.2.253
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

### Connect to Sentinel

#### by Jedis

```
java -Dspring.profiles.active=jedis,sentinel -jar build/libs/java-spring-0.2.0.jar
```

#### by Lettuce

```
java -Dspring.profiles.active=lettuce,sentinel -jar build/libs/java-spring-0.2.0.jar
```

### Connect to VIP

#### by Jedis

```
java -Dspring.profiles.active=jedis,vip -jar build/libs/java-spring-0.2.0.jar
```

#### by Lettuce

```
java -Dspring.profiles.active=lettuce,vip -jar build/libs/java-spring-0.2.0.jar
```

### Connect to Redis Cluster

#### by Jedis

```
java -Dspring.profiles.active=jedis,cluster -jar build/libs/java-spring-0.2.0.jar
```

#### by Lettuce

```
java -Dspring.profiles.active=lettuce,cluster -jar build/libs/java-spring-0.2.0.jar
```
