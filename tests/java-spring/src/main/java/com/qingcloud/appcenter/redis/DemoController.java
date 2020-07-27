package com.qingcloud.appcenter.redis;

import java.util.Date;
import java.util.concurrent.atomic.AtomicLong;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller
public class DemoController {
  private final Logger logger = LoggerFactory.getLogger(this.getClass());
  private static final String message = "Hello, %s!";
  private final AtomicLong counter = new AtomicLong();

  @Autowired
  private RedisTemplate<String, String> template;

  @GetMapping("/hello")
  @ResponseBody
  public String sayHello(@RequestParam(name="name", required=false, defaultValue="Stranger") String name) {
    logger.info("Processing ...");

    try {
      String key = String.format("%s-%s", name, new Date().getTime());
      String value = String.format("value of key %s", key);
      template.opsForValue().set(key, value);
      logger.info("k={} v={}.", key, template.opsForValue().get(key));
      Thread.sleep(500);
    } catch (Exception e) {
      logger.error("Exception occurred at name '{}': ", name, e);
    }

    logger.info("Done processing!");
    return String.format("#%s - %s.\n", counter.incrementAndGet(), String.format(message, name));
  }
}