package com.example.manager;

import com.example.commons.Commons;
import lombok.Value;

/**
 * Minimal subscription manager.
 *
 * <p>Uses {@link Commons} (sibling module) and Lombok's {@code @Value} to exercise both the
 * sibling-dependency resolution path and the Lombok agent detection path simultaneously.
 */
@Value
public class Manager {

  String commonsVersion = Commons.version();

  public String describe() {
    return "subscription-manager using commons@" + commonsVersion;
  }
}
