package com.example.server;

import com.example.manager.Manager;
import lombok.Builder;
import lombok.Value;

/**
 * Subscription server entry-point.
 *
 * <p>Depends on {@link Manager} via {@code project(':manager')}, exercising a two-level transitive
 * Gradle project substitution chain (server -> manager -> commons).
 */
@Value
@Builder
public class Server {

  Manager manager;

  public String describe() {
    return "subscription-server wrapping " + manager.describe();
  }
}
