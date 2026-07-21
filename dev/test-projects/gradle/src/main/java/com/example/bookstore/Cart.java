package com.example.bookstore;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Shopping cart that holds books and computes the checkout total. */
public class Cart {

  private final List<Book> items = new ArrayList<>();

  public void add(Book book) {
    items.add(book);
  }

  public List<Book> getItems() {
    return Collections.unmodifiableList(items);
  }

  public BigDecimal total() {
    return items.stream()
        .map(Book::getPrice)
        .reduce(BigDecimal.ZERO, BigDecimal::add);
  }

  public int size() {
    return items.size();
  }
}
