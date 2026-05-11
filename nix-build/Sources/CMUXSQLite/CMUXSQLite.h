#ifndef CMUX_NIX_CSQLITE3_SHIM_H
#define CMUX_NIX_CSQLITE3_SHIM_H

/* Shim that re-exports the standard sqlite3 C API.
 *
 * Why: nixpkgs's apple-sdk-14.4 declares `module SQLite3 { header "sqlite3.h" }`
 * in its module.modulemap but doesn't ship `sqlite3.h` itself. We get the real
 * header from `pkgs.sqlite` via clang's -I include path (NIX_CFLAGS_COMPILE),
 * wrap it as a fresh `CMUXSQLite` module here, and have upstream cmux code
 * `import CMUXSQLite` instead of `import SQLite3` under `#if CMUX_NIX_BUILD`.
 *
 * C ABI is identical; only the Swift module name differs.
 */
#include <sqlite3.h>

#endif /* CMUX_NIX_CSQLITE3_SHIM_H */
