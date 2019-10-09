package com.qingcloud.appcenter.redis.standalone.example;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.data.redis.RedisProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.data.redis.connection.RedisSentinelConfiguration;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.repository.configuration.EnableRedisRepositories;

import java.util.HashSet;

@Configuration
@EnableRedisRepositories
@Profile("sentinel")
public class JedisSentinelConfig {
    @Autowired
    RedisProperties redisProperties;

    @Bean
    public RedisSentinelConfiguration redisSentinelConfiguration() {
        RedisProperties.Sentinel sentinelProp = redisProperties.getSentinel();
        RedisSentinelConfiguration config = new RedisSentinelConfiguration(
                sentinelProp.getMaster(),
                new HashSet<>(sentinelProp.getNodes())
        );
        config.setPassword(redisProperties.getPassword());
        return config;
    }

    @Bean
    public JedisConnectionFactory redisConnectionFactory() {
        return new JedisConnectionFactory(redisSentinelConfiguration());
    }
}
