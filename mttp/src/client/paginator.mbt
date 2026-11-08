///|
/// One decoded page and its optional cursor for the following page.
pub(all) struct Page[T] {
  items : Array[T]
  next : String?
}

///|
/// A stateful paginator with expected failures as values. Transport errors
/// remain effects; a failed fetch never advances the cursor.
pub struct Paginator[T, E] {
  priv fetch : async () -> Result[Array[T]?, E]
  priv mut done : Bool
  priv mut pending : Array[T]?
}

///|
/// Creates a paginator whose fetch owns its cursor. None or an empty page ends
/// iteration. The fetch must advance its cursor only after a successful page.
pub fn[T, E] Paginator::new(
  fetch : async () -> Result[Array[T]?, E],
) -> Paginator[T, E] {
  { fetch, done: false, pending: None, }
}

///|
/// Creates a paginator which advances its string cursor only on Ok.
pub fn[T, E] Paginator::with_cursor(
  fetch : async (String?) -> Result[Page[T], E],
) -> Paginator[T, E] {
  let cursor : Ref[String?] = Ref(None)
  let finished = Ref(false)
  Paginator::new(() => {
    if finished.val {
      return Ok(None)
    }
    match fetch(cursor.val) {
      Err(error) => Err(error)
      Ok(page) => {
        cursor.val = page.next
        finished.val = page.next is None
        Ok(Some(page.items))
      }
    }
  })
}

///|
/// Fetches the next non-empty page, preserving unused items from collect.
pub async fn[T, E] Paginator::next_page(
  self : Paginator[T, E],
) -> Result[Array[T]?, E] {
  if self.pending is Some(items) {
    self.pending = None
    return Ok(Some(items))
  }
  if self.done {
    return Ok(None)
  }
  match (self.fetch)() {
    Err(error) => Err(error)
    Ok(Some(items)) if !items.is_empty() => Ok(Some(items))
    Ok(_) => {
      self.done = true
      Ok(None)
    }
  }
}

///|
/// Visits each item in page order, stopping at the first expected failure.
pub async fn[T, E] Paginator::each(
  self : Paginator[T, E],
  f : async (T) -> Result[Unit, E],
) -> Result[Unit, E] {
  for ;; {
    match self.next_page() {
      Err(error) => return Err(error)
      Ok(None) => return Ok(())
      Ok(Some(items)) =>
        for item in items {
          if f(item) is Err(error) {
            return Err(error)
          }
        }
    }
  }
}

///|
/// Collects at most max items, keeping unused items from the last page.
/// A non-positive maximum performs no requests.
pub async fn[T, E] Paginator::collect(
  self : Paginator[T, E],
  max~ : Int32,
) -> Result[Array[T], E] {
  let result = []
  if max <= 0 {
    return Ok(result)
  }
  while result.length() < max {
    let items = match self.next_page() {
      Err(error) => return Err(error)
      Ok(None) => break
      Ok(Some(items)) => items
    }
    for index, item in items {
      result.push(item)
      if result.length() == max {
        if index + 1 < items.length() {
          self.pending = Some(items[index + 1:].to_owned())
        }
        break
      }
    }
  }
  Ok(result)
}
