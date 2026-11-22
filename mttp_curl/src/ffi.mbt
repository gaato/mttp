// The externs of curl_stub.c. Its header comment says how the thread, the
// command queue and the eventfd fit together.

///|
/// An engine: a CURLM and the thread that drives it, in a GC-managed box
/// that holds one reference to it (curl_stub.c says who else does).
priv type Engine

///|
/// One exchange: an easy handle and the buffers the thread shares with
/// MoonBit, in a GC-managed box that holds one reference to it. After
/// `transfer_release` its state is no longer read, but its memory stays
/// until the box goes.
priv type Xfer

///|
/// Bit 1: the libcurl has HTTP/2; bit 2: HTTP/3; bit 4: it reports when a
/// request was sent (8.10 or later).
extern "c" fn curl_features() -> Int32 = "mttp_curl_features"

///|
extern "c" fn curl_version_bytes() -> Bytes = "mttp_curl_version"

///|
extern "c" fn engine_new_raw() -> Engine = "mttp_curl_engine_new"

///|
#borrow(e)
extern "c" fn engine_is_null(e : Engine) -> Bool = "mttp_curl_engine_is_null"

///|
#borrow(e)
extern "c" fn engine_is_closed(e : Engine) -> Bool = "mttp_curl_engine_is_closed"

///|
#borrow(e)
extern "c" fn engine_close(e : Engine) -> Unit = "mttp_curl_engine_close"

///|
#borrow(e, url, meth, cainfo, proxy, noproxy)
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
  proxy : Bytes,
  noproxy : Bytes,
) -> Xfer = "mttp_curl_transfer_new"

///|
#borrow(t)
extern "c" fn xfer_is_null(t : Xfer) -> Bool = "mttp_curl_transfer_is_null"

///|
#borrow(t, line)
extern "c" fn transfer_header(t : Xfer, line : Bytes) -> Unit = "mttp_curl_transfer_header"

///|
#borrow(t)
extern "c" fn transfer_fd(t : Xfer) -> @types.Fd = "mttp_curl_transfer_fd"

///|
#borrow(t)
extern "c" fn transfer_start(t : Xfer) -> Unit = "mttp_curl_transfer_start"

///|
#borrow(t)
extern "c" fn transfer_state(t : Xfer) -> Int32 = "mttp_curl_transfer_state"

///|
#borrow(t)
extern "c" fn transfer_info(t : Xfer, which : Int32) -> Int32 = "mttp_curl_transfer_info"

///|
#borrow(t)
extern "c" fn transfer_text(t : Xfer, which : Int32) -> Bytes = "mttp_curl_transfer_text"

///|
#borrow(t, out)
extern "c" fn transfer_read(
  t : Xfer,
  out : FixedArray[Byte],
  max : Int32,
) -> Int32 = "mttp_curl_transfer_read"

///|
#borrow(t, data)
extern "c" fn transfer_push(t : Xfer, data : Bytes, eof : Bool) -> Unit = "mttp_curl_transfer_push"

///|
#borrow(t)
extern "c" fn transfer_abandon_upload(t : Xfer) -> Unit = "mttp_curl_transfer_abandon_upload"

///|
#borrow(t)
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

///|
const ST_FIRST_BYTE = 256

///|
const ST_NEW_CONN = 512
