///|
/// Authorization is isolated by value, or bypasses caching entirely.
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum CredentialMode {
  Partition
  Bypass
}

///|
/// Result of this wrapper's cache decision, carried on response attributes.
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum CacheStatus {
  Hit
  Revalidated
  Miss
  Stale
  Bypass
}

///|
pub let cache_status : @mttp_core.AttributeKey[CacheStatus] = @mttp_core.AttributeKey::new(
  "httpcache.status",
)

///|
/// A canonical absolute URL without its fragment, plus Authorization.
/// Injected stores must hash the credential before persisting a key; the
/// default MemoryStore keeps it only in memory.
#derive(Eq)
pub struct CacheKey {
  url : String
  credential : String?
}

///|
pub extend CredentialMode with Eq::{equal, not_equal}

///|
pub extend CredentialMode with @debug.Debug::{to_repr}

///|
pub extend CacheStatus with Eq::{equal, not_equal}

///|
pub extend CacheStatus with @debug.Debug::{to_repr}

///|
pub extend CacheKey with Eq::{equal, not_equal}

///|
/// One complete GET representation. vary_headers contains the selected
/// request fields (absence stays absent); head contains the Vary names.
pub struct Stored {
  vary_headers : @mttp_core.Headers
  head : @mttp_core.ResponseHead
  body : Bytes
  request_time_ms : Int64
  response_time_ms : Int64
}

///|
/// A private cache's storage. Lookup returns variants oldest first; insert
/// replaces an equal Vary selection and makes it newest. Methods must be
/// safe for concurrent callers. Lookup/insert failures skip caching; a remove
/// failure disables caching in the wrapper because retained entries may be stale.
/// Persisted credentials must be hashed. remove invalidates the URL across
/// all credential partitions, so an authenticated mutation also invalidates
/// anonymous representations of the same resource. Variant eviction may
/// conservatively discard other partitions of that URL as well.
pub(open) trait CacheStore {
  async fn lookup(Self, CacheKey) -> Array[Stored]
  async fn insert(Self, CacheKey, Stored) -> Unit
  async fn remove(Self, CacheKey) -> Unit
}
