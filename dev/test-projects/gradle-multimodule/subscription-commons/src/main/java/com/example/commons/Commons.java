package com.example.commons;

/**
 * Shared utility.
 *
 * <p>Gradle resolves this as {@code project(':commons')} in sibling subprojects.
 */
public final class Commons {

  private Commons() {}

  public static String version() {
    return "0.0.1";
  }
}
