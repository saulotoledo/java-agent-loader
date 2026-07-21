package com.example.bookstore;

import java.math.BigDecimal;

/**
 * Tiny bookstore demo used to exercise JAL with Lombok, JaCoCo, and the
 * OpenTelemetry Java agent declared in the project build.
 */
public final class BookstoreApp {

  private BookstoreApp() {}

  public static void main(String[] args) {
    Cart cart = sampleCart();
    System.out.printf("Cart: %d book(s), total %s%n", cart.size(), cart.total());
  }

  static Cart sampleCart() {
    Cart cart = new Cart();
    cart.add(Book.builder()
        .isbn("978-0134685991")
        .title("Effective Java")
        .author("Joshua Bloch")
        .price(new BigDecimal("45.00"))
        .build());
    cart.add(Book.builder()
        .isbn("978-0596009205")
        .title("Head First Design Patterns")
        .author("Eric Freeman")
        .price(new BigDecimal("39.99"))
        .build());
    return cart;
  }
}
