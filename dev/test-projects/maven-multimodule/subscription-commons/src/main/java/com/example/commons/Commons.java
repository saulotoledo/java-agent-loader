package com.example.commons;

/**
 * Placeholder shared utility.
 *
 * <p>Kept minimal -- the module's sole purpose in this test reactor is to be an uninstalled sibling
 * that subscription-manager depends on.
 */
public final class Commons {

  private Commons() {}

  public static String version() {
    return "0.0.1";
  }
}
