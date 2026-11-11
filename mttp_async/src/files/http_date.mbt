///|
/// The IMF-fixdate of a Unix time in seconds (RFC 9110, section 5.6.7), as
/// in `Sun, 06 Nov 1994 08:49:37 GMT`. `None` outside the years 1 to 9999,
/// which the format's four-digit year cannot carry.
fn http_date(unix_seconds : Int64) -> String? {
  let days = if unix_seconds >= 0L {
    unix_seconds / 86400L
  } else {
    (unix_seconds + 1L) / 86400L - 1L
  }
  let second_of_day = unix_seconds - days * 86400L
  // Civil date from days since 1970-01-01, on March-based 400-year eras.
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let day_of_era = z - era * 146097L
  let year_of_era = (
      day_of_era -
      day_of_era / 1460L +
      day_of_era / 36524L -
      day_of_era / 146096L
    ) /
    365L
  let day_of_year = day_of_era -
    (365L * year_of_era + year_of_era / 4L - year_of_era / 100L)
  let march_month = (5L * day_of_year + 2L) / 153L
  let day = day_of_year - (153L * march_month + 2L) / 5L + 1L
  let month = if march_month < 10L {
    march_month + 3L
  } else {
    march_month - 9L
  }
  let year = year_of_era + era * 400L + (if month <= 2L { 1L } else { 0L })
  guard year >= 1L && year <= 9999L else { return None }
  let weekday = ((days + 4L) % 7L + 7L) % 7L
  let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  let months = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let hour = second_of_day / 3600L
  let minute = second_of_day / 60L % 60L
  let second = second_of_day % 60L
  Some(
    "\{weekdays[weekday.to_int()]}, \{digits(day, 2)} \{months[month.to_int() - 1]} \{digits(year, 4)} \{digits(hour, 2)}:\{digits(minute, 2)}:\{digits(second, 2)} GMT",
  )
}

///|
/// `n` in decimal, padded with zeros to `width` digits.
fn digits(n : Int64, width : Int32) -> String {
  let text = n.to_string()
  "0".repeat(width - text.length()) + text
}
