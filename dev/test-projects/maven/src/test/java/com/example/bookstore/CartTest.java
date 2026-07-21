package com.example.bookstore;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.math.BigDecimal;

import org.junit.jupiter.api.Test;

class CartTest {

  @Test
  void totalSumsBookPrices() {
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

    assertEquals(2, cart.size());
    assertEquals(new BigDecimal("84.99"), cart.total());
  }

  @Test
  void emptyCartHasZeroTotal() {
    assertEquals(BigDecimal.ZERO, new Cart().total());
  }
}
