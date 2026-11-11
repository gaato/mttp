///|
/// TLS peer verification for socket backends. JavaScript fetch uses the
/// host's trust store and ignores this setting. PemFile replaces system
/// roots; supply a combined PEM bundle to trust private and system roots.
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum Trust {
  System
  Insecure
  PemFile(String)
}

///|
/// Compares certificate trust policies.
pub extend Trust with Eq::{equal, not_equal}

///|
/// Formats a certificate trust policy for diagnostics.
pub extend Trust with @debug.Debug::{to_repr}
