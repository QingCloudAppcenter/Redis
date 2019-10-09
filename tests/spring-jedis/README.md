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
      nodes: 192.168.1.11:26379,192.168.1.12:26379,,192.168.1.13:26379
```

## 2. Build

```
./gradlew build
```

## 3. Run

### Connect to VIP

```
./gradlew -Dspring.profiles.active=vip bootRun
```

### Connect to Sentinel

```
./gradlew -Dspring.profiles.active=sentinel bootRun
```
