# Jedis code example

## How to configure Redis host

Update property `spring.redis.host` in `src/main/resources/application.yml`:
```
spring:
  redis:
    host: 192.168.2.253
```

## How to build

```
./gradlew build
```

## how to run

```
./gradlew bootRun
```
