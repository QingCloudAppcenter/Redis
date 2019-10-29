package com.qingcloud.appcenter.redis;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.data.redis.RedisProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.data.redis.connection.RedisClusterConfiguration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.connection.RedisSentinelConfiguration;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.repository.configuration.EnableRedisRepositories;

import java.util.HashSet;

@Configuration
@EnableRedisRepositories
public class RedisConfig {
    @Autowired
    RedisProperties redisProperties;

    @Bean
    @Profile("sentinel")
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
    @Profile("vip")
    public RedisStandaloneConfiguration redisStandaloneConfiguration() {
        return new RedisStandaloneConfiguration(redisProperties.getHost(), redisProperties.getPort());
    }

    // > Jedis

    @Bean
    @Profile("jedis & sentinel")
    public RedisConnectionFactory jedisSentinelConnectionFactory() {
        return new JedisConnectionFactory(redisSentinelConfiguration());
    }

    @Bean
    @Profile("jedis & vip")
    public RedisConnectionFactory jedisVipConnectionFactory() {
        return new JedisConnectionFactory(redisStandaloneConfiguration());
    }

    @Bean
    @Profile("jedis & cluster")
    public RedisConnectionFactory jedisClusterConnectionFactory() {
        return new JedisConnectionFactory(new RedisClusterConfiguration(redisProperties.getCluster().getNodes()));
    }

    // < Jedis

    // > Lettuce

    @Bean
    @Profile("lettuce & sentinel")
    public RedisConnectionFactory lettuceSentinelConnectionFactory() {
        return new LettuceConnectionFactory(redisSentinelConfiguration());
    }

    @Bean
    @Profile("lettuce & vip")
    public RedisConnectionFactory lettuceVipConnectionFactory() {
        return new LettuceConnectionFactory(redisStandaloneConfiguration());
    }

    @Bean
    @Profile("lettuce & cluster")
    public RedisConnectionFactory lettuceClusterConnectionFactory() {
        return new LettuceConnectionFactory(new RedisClusterConfiguration(redisProperties.getCluster().getNodes()));
    }

    // < Lettuce
}
