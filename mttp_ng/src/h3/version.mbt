///|
/// The version number of the linked ngtcp2, as `0xMMmmpp`.
pub extern "C" fn ngtcp2_version() -> Int32 = "mttp_ng_h3_ngtcp2_version"

///|
/// The version number of the linked nghttp3, as `0xMMmmpp`.
pub extern "C" fn nghttp3_version() -> Int32 = "mttp_ng_h3_nghttp3_version"

///|
/// Initialises ngtcp2's OpenSSL crypto library; 0 on success.
pub extern "C" fn crypto_init() -> Int32 = "mttp_ng_h3_crypto_init"
