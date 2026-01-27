# Common helper functions for NeoIPC Surveillance reports
# This file is sourced by all report types

#' Format integer with locale-specific thousand separator
#' @param x numeric value to format
#' @param big_mark thousand separator character
#' @return formatted string
format_integer <- function(x, big_mark = sR$digit_group_separator)
  dplyr::if_else(x < 10000, format(as.integer(x), big.mark = ""), format(as.integer(x), big.mark = big_mark))
