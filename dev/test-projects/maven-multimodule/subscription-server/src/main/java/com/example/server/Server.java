package com.example.server;

import com.example.manager.Manager;
import lombok.Builder;
import lombok.Value;

/**
 * Minimal subscription server entry-point.
 *
 * <p>Depends on {@link Manager} (which depends on {@code subscription-commons}) to exercise a
 * two-level transitive sibling dependency chain. Lombok {@code @Value} + {@code @Builder} require
 * the JAL agent to be present.
 */
@Value
@Builder
public class Server {

  Manager manager;

  public String describe() {
    return "subscription-server wrapping " + manager.describe();
  }
}
