package com.example.manager;

import com.example.commons.Commons;
import lombok.Value;

/**
 * Subscription manager -- uses {@link Commons} (sibling) and Lombok {@code @Value}.
 *
 * <p>Gradle resolves {@code project(':commons')} via its substitution mechanism, so this compiles
 * and detects agents correctly even without a local cache entry.
 */
@Value
public class Manager {

  String commonsVersion = Commons.version();

  public String describe() {
    return "subscription-manager using commons@" + commonsVersion;
  }
}
