package com.example.bookstore;

import java.math.BigDecimal;

import lombok.Builder;
import lombok.NonNull;
import lombok.Value;

/** Immutable catalog entry for a book offered in the store. */
@Value
@Builder
public class Book {
  @NonNull String isbn;
  @NonNull String title;
  @NonNull String author;
  @NonNull BigDecimal price;
}
