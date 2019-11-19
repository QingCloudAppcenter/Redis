package com.qingcloud.appcenter.redis;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.data.redis.core.RedisTemplate;

import java.util.stream.IntStream;

@SpringBootApplication
public class App implements CommandLineRunner {
    private final Logger logger = LoggerFactory.getLogger(this.getClass());

    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    @Autowired
    private RedisTemplate<String, String> template;

    @Override
    public void run(String... args) {
        logger.info("Processing ...");

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

        logger.info("Done processing!");
    }
}
