///|
/// Number of slots the budget window is divided into. Counts older than the
/// window fall out one slot at a time, so the state is a fixed size.
let retry_budget_slots : Int32 = 10

///|
/// A cap on retries as a share of recent requests, shared by every send of a
/// Client. When a server fails, every caller's retries would otherwise
/// multiply its load just as it tries to recover.
///
/// Each request deposits one token; each retry withdraws one. A retry goes
/// ahead while the withdrawals of the last `window_ms` stay below
/// `min_per_second` times the window in seconds plus `percent` of the
/// deposits in the window. Time comes from the Client's clock. Pass the same
/// budget to several Clients to share it.
pub struct RetryBudget {
  priv unlimited : Bool
  priv percent : Double
  priv min_per_second : Int32
  priv window_ms : Int64
  priv slot_ms : Int64
  priv starts : FixedArray[Int64]
  priv deposits : FixedArray[Int32]
  priv withdrawals : FixedArray[Int32]
}

///|
/// Creates a budget: by default retries may add 20 % to the requests of the
/// last 10 seconds, plus 10 retries per second. A negative `percent` or
/// `min_per_second` counts as 0, and `window_ms` is at least 10 ms.
pub fn RetryBudget::new(
  percent~ : Double = 0.2,
  min_per_second~ : Int32 = 10,
  window_ms~ : Int32 = 10_000,
) -> RetryBudget {
  let window = window_ms.max(retry_budget_slots).to_int64()
  {
    unlimited: false,
    percent: if percent > 0.0 {
      percent
    } else {
      0.0
    },
    min_per_second: min_per_second.max(0),
    window_ms: window,
    slot_ms: window / retry_budget_slots.to_int64(),
    starts: FixedArray::make(retry_budget_slots, -1L),
    deposits: FixedArray::make(retry_budget_slots, 0),
    withdrawals: FixedArray::make(retry_budget_slots, 0),
  }
}

///|
/// A budget that never refuses a retry; the retry policy alone decides.
pub fn RetryBudget::unlimited() -> RetryBudget {
  { ..RetryBudget::new(), unlimited: true, }
}

///|
/// The slot for `now`, emptied when it last counted an earlier period.
fn RetryBudget::slot(self : RetryBudget, now : Int64) -> Int32 {
  let start = now - now % self.slot_ms
  let index = (start / self.slot_ms % retry_budget_slots.to_int64()).to_int()
  if self.starts[index] != start {
    self.starts[index] = start
    self.deposits[index] = 0
    self.withdrawals[index] = 0
  }
  index
}

///|
/// Deposits and withdrawals of the slots inside the window ending at `now`.
fn RetryBudget::totals(self : RetryBudget, now : Int64) -> (Int32, Int32) {
  let mut deposits = 0
  let mut withdrawals = 0
  for i in 0..<retry_budget_slots {
    let start = self.starts[i]
    if start >= 0L && start > now - self.window_ms && start <= now {
      deposits += self.deposits[i]
      withdrawals += self.withdrawals[i]
    }
  }
  (deposits, withdrawals)
}

///|
/// Records a request.
fn RetryBudget::deposit(self : RetryBudget, now : Int64) -> Unit {
  if !self.unlimited {
    let index = self.slot(now)
    self.deposits[index] += 1
  }
}

///|
/// Whether the budget has a retry left at `now`, without taking it.
fn RetryBudget::allows(self : RetryBudget, now : Int64) -> Bool {
  if self.unlimited {
    return true
  }
  let (deposits, withdrawals) = self.totals(now)
  let floor = self.min_per_second.to_double() *
    self.window_ms.to_double() /
    1000.0
  withdrawals.to_double() < floor + self.percent * deposits.to_double()
}

///|
/// Takes one retry from the budget at `now`, the moment the retry is sent,
/// or returns false when it is spent. Charging at the decision instead would
/// let a withdrawal leave the window during a long backoff, so retries that
/// converge on one moment could exceed the cap together.
fn RetryBudget::try_withdraw(self : RetryBudget, now : Int64) -> Bool {
  if !self.allows(now) {
    return false
  }
  if !self.unlimited {
    let index = self.slot(now)
    self.withdrawals[index] += 1
  }
  true
}
