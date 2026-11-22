// The externs of curl_stub.c. Its header comment says how the thread, the
// command queue and the eventfd fit together.

///|
/// An engine: a CURLM and the thread that drives it. C owns it and frees it
/// after `engine_close`, once its transfers are released.
#external
priv type Engine

///|
/// One exchange: an easy handle and the buffers the thread shares with
/// MoonBit. C owns it; `transfer_release` hands it back, after which it is
/// never used again.
#external
priv type Xfer

///|
/// Bit 1: the libcurl has HTTP/2; bit 2: HTTP/3.
extern "c" fn curl_features() -> Int32 = "mttp_curl_features"

///|
extern "c" fn curl_version_bytes() -> Bytes = "mttp_curl_version"

///|
extern "c" fn engine_new_raw() -> Engine = "mttp_curl_engine_new"

///|
extern "c" fn engine_is_null(e : Engine) -> Bool = "mttp_curl_is_null"

///|
extern "c" fn engine_close(e : Engine) -> Unit = "mttp_curl_engine_close"

///|
#borrow(url, meth, cainfo)
extern "c" fn transfer_new_raw(
  e : Engine,
  url : Bytes,
  meth : Bytes,
  nobody : Bool,
  body : Int64,
  version : Int32,
  cainfo : Bytes,
  insecure : Bool,
  head_max : Int32,
  body_cap : Int32,
  max_age_s : Int32,
) -> Xfer = "mttp_curl_transfer_new"

///|
extern "c" fn xfer_is_null(t : Xfer) -> Bool = "mttp_curl_is_null"

///|
#borrow(line)
extern "c" fn transfer_header(t : Xfer, line : Bytes) -> Unit = "mttp_curl_transfer_header"

///|
extern "c" fn transfer_fd(t : Xfer) -> @types.Fd = "mttp_curl_transfer_fd"

///|
extern "c" fn transfer_start(t : Xfer) -> Unit = "mttp_curl_transfer_start"

///|
extern "c" fn transfer_state(t : Xfer) -> Int32 = "mttp_curl_transfer_state"

///|
extern "c" fn transfer_info(t : Xfer, which : Int32) -> Int32 = "mttp_curl_transfer_info"

///|
extern "c" fn transfer_text(t : Xfer, which : Int32) -> Bytes = "mttp_curl_transfer_text"

///|
#borrow(out)
extern "c" fn transfer_read(
  t : Xfer,
  out : FixedArray[Byte],
  max : Int32,
) -> Int32 = "mttp_curl_transfer_read"

///|
#borrow(data)
extern "c" fn transfer_push(t : Xfer, data : Bytes, eof : Bool) -> Unit = "mttp_curl_transfer_push"

///|
extern "c" fn transfer_release(t : Xfer) -> Unit = "mttp_curl_transfer_release"

// State bits of `transfer_state`, as curl_stub.c defines them.

///|
const ST_PREREQ = 1

///|
const ST_HEAD = 2

///|
const ST_DONE = 4

///|
const ST_WANTS_BODY = 8

///|
const ST_HEAD_TOO_LARGE = 32

///|
const ST_CLOSED = 64

///|
const ST_SENT = 128
