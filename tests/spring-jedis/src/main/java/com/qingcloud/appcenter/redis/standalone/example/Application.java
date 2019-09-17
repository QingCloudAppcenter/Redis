package com.qingcloud.appcenter.redis.standalone.example;

import java.util.stream.IntStream;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.data.redis.core.RedisTemplate;

@SpringBootApplication
public class Application {
  private final Logger logger = LoggerFactory.getLogger(this.getClass());

  public static void main(String[] args) {
    SpringApplication.run(Application.class, args);
  }

  @Autowired
  private RedisTemplate<String, String> template;

  @Bean
  public CommandLineRunner commandLineRunner(ApplicationContext ctx) {
    return args -> {
      logger.info("Starting to process redis cluster ...");

      IntStream.range(0, 0x100000).forEach(i -> {
        try {
          String key = String.format("key%05d", i);
          String value = String.format("%05d", i);
          template.opsForValue().set(key, value);
          logger.info("k={} v={}.", key, template.opsForValue().get(key));
        } catch (Exception e) {
          logger.error("Exception occurred at key '{}': ", i, e);
        }
      });
    };
  }

}
