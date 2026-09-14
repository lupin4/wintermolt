// Copyright The Fantastic Planet - By David Clabaugh
//
// curl_tls.zig -- TLS trust for every libcurl easy handle.
//
// Call configure(handle) right after EVERY curl_easy_init.
//
// WHY. On Windows wintermolt links MSYS2's static libcurl, built against
// OpenSSL. Its default CA bundle is a path baked in when MSYS2 built it
// (`curl-config --ca` = /ucrt64/etc/ssl/certs/ca-bundle.crt), and that path
// does not exist anywhere but inside an MSYS2 install. So every HTTPS request
// failed with CURLE_SSL_CACERT_BADFILE (77, "Problem with the SSL CA cert (path?
// access rights?)") while plain-HTTP Ollama kept working.
//
// CURLSSLOPT_NATIVE_CA makes OpenSSL trust the Windows certificate store, the
// same roots every other Windows program uses. Verification is NOT relaxed:
// CURLOPT_SSL_VERIFYPEER and CURLOPT_SSL_VERIFYHOST are never touched, so they
// keep libcurl's defaults (1 and 2) and a bad certificate still fails.
//
// Other platforms: a no-op. Their libcurl already finds the system bundle.
//
// Interim: HTTPS is planned to move off libcurl onto forNet's prebuilt.

const builtin = @import("builtin");

/// curl.h: CURLOPT(CURLOPT_SSL_OPTIONS, CURLOPTTYPE_VALUES, 216), and
/// CURLOPTTYPE_VALUES is CURLOPTTYPE_LONG, which is 0.
pub const CURLOPT_SSL_OPTIONS: c_int = 216;
/// curl.h: #define CURLSSLOPT_NATIVE_CA (1L << 4)
pub const CURLSSLOPT_NATIVE_CA: c_long = 1 << 4;

extern fn curl_easy_setopt(handle: *anyopaque, option: c_int, ...) c_int;

/// Trust the operating system's certificate store (Windows only).
pub fn configure(handle: *anyopaque) void {
    if (comptime builtin.os.tag != .windows) return;
    _ = curl_easy_setopt(handle, CURLOPT_SSL_OPTIONS, CURLSSLOPT_NATIVE_CA);
}
