///|
/// Compares exchange phases.
pub extend Phase with Eq::{equal, not_equal}

///|
/// Formats an exchange phase for diagnostics.
pub extend Phase with @debug.Debug::{to_repr}

///|
/// Compares failure categories and their associated limits.
pub extend Kind with Eq::{equal, not_equal}

///|
/// Formats a failure category for diagnostics.
pub extend Kind with @debug.Debug::{to_repr}

///|
/// Formats a transport failure for diagnostics.
pub extend TransportError with @debug.Debug::{to_repr}

///|
/// Compares HTTP methods.
pub extend Method with Eq::{equal, not_equal}

///|
/// Writes the HTTP method token.
pub extend Method with Show::{output}

///|
/// Hashes an HTTP method.
pub extend Method with Hash::{hash, hash_combine}

///|
/// Formats an HTTP method for diagnostics.
pub extend Method with @debug.Debug::{to_repr}

///|
/// Compares request metadata.
pub extend RequestHead with Eq::{equal, not_equal}

///|
/// Formats request metadata for diagnostics.
pub extend RequestHead with @debug.Debug::{to_repr}

///|
/// Compares response metadata.
pub extend ResponseHead with Eq::{equal, not_equal}

///|
/// Formats response metadata for diagnostics.
pub extend ResponseHead with @debug.Debug::{to_repr}
