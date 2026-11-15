///|
/// One generic WebSocket extension parameter. `None` is a bare parameter.
#derive(Eq, Debug)
pub(all) struct ExtensionParam {
  name : String
  value : String?
}

///|
/// Compares parameter names and optional decoded values.
pub extend ExtensionParam with Eq::{equal, not_equal}

///|
/// Formats an extension parameter for diagnostics.
pub extend ExtensionParam with @debug.Debug::{to_repr}

///|
/// One parsed Sec-WebSocket-Extensions element, preserving parameter order.
#derive(Eq, Debug)
pub(all) struct Extension {
  name : String
  params : Array[ExtensionParam]
}

///|
/// Compares extension names and ordered parameters.
pub extend Extension with Eq::{equal, not_equal}

///|
/// Formats a parsed extension for diagnostics.
pub extend Extension with @debug.Debug::{to_repr}

///|
/// A validated server handshake.
#derive(Eq, Debug)
pub(all) struct Accepted {
  subprotocol : String?
  extensions : Array[Extension]
}

///|
/// Compares the selected subprotocol and parsed extensions.
pub extend Accepted with Eq::{equal, not_equal}

///|
/// Formats an accepted handshake for diagnostics.
pub extend Accepted with @debug.Debug::{to_repr}

///|
/// Browser Origin admission. A missing Origin is allowed for every policy.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum OriginPolicy {
  SameOrigin
  Allow(Array[String])
  Any
}

///|
/// Compares origin policies and their allow lists.
pub extend OriginPolicy with Eq::{equal, not_equal}

///|
/// Formats an origin policy for diagnostics.
pub extend OriginPolicy with @debug.Debug::{to_repr}

///|
/// A server-side handshake refusal and the HTTP response metadata to send.
#derive(Debug)
pub(all) suberror Refusal {
  Refusal(status~ : Int32, headers~ : @mttp_core.Headers, detail~ : String)
}

///|
/// Formats a refusal status, headers and detail for diagnostics.
pub extend Refusal with @debug.Debug::{to_repr}

///|
/// A validated client offer. The supported fields retain the server policy
/// used during validation so `accept` cannot select an unconfigured value.
#derive(Eq, Debug)
pub(all) struct Offer {
  key : String
  subprotocols : Array[String]
  extensions : Array[Extension]
  supported_subprotocols : Array[String]
  supported_extensions : Array[Extension]
}

///|
/// Compares client offers and the server support captured with them.
pub extend Offer with Eq::{equal, not_equal}

///|
/// Formats a validated offer for diagnostics.
pub extend Offer with @debug.Debug::{to_repr}
