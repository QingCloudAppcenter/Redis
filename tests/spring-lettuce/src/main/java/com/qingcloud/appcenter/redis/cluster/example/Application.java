package com.qingcloud.appcenter.redis.cluster.example;

import java.util.stream.IntStream;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.data.redis.connection.RedisClusterConnection;
import org.springframework.data.redis.connection.RedisConnectionFactory;

@SpringBootApplication
public class Application {
  private final Logger logger = LoggerFactory.getLogger(this.getClass());

  public static void main(String[] args) {
    SpringApplication.run(Application.class, args);
  }

  @Autowired
  private RedisConnectionFactory redisConnectionFactory;

  @Bean
  public CommandLineRunner commandLineRunner(ApplicationContext ctx) {
    return args -> {
      logger.info("Starting to process redis cluster ...");
      RedisClusterConnection connection = redisConnectionFactory.getClusterConnection();

      IntStream.range(0, 0x100000).forEach(i -> {
        try {
          byte[] key = String.format("key%05d", i).getBytes();
          byte[] value = String.format("%05d", i).getBytes();
          connection.set(key, value);
          logger.info("k={} v={}.", new String(key), new String(connection.get(key)));
        } catch (Exception e) {
          logger.error("Exception occurred at key '{}': ", i, e);
        }
      });
    };
  }

}
