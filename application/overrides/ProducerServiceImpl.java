package com.visualpathit.account.service;

import org.springframework.amqp.core.AmqpTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

@Service
public class ProducerServiceImpl implements ProducerService {

    private static final String EXCHANGE_NAME = "messages";

    private final AmqpTemplate amqpTemplate;

    @Autowired
    public ProducerServiceImpl(AmqpTemplate amqpTemplate) {
        this.amqpTemplate = amqpTemplate;
    }

    @Override
    public String produceMessage(String message) {
        amqpTemplate.convertAndSend(EXCHANGE_NAME, "", message);
        System.out.println(" [x] Sent '" + message + "'");
        return "response";
    }
}
