#ifndef GRAPHL_H
#define GRAPHL_H

#include <cstdint>

typedef uint32_t graphl_status_t;
#define GRAPHLSTATUS_OK 0
#define GRAPHLSTATUS_UNKNOWN 1
#define GRAPHLSTATUS_OOM 2

const char* graphl_compileSource(
  const char* source_name,
  uint32_t source_name_len,
  const char* source_text,
  uint32_t source_text_len,
  // TODO: build a user function object via an API instead
  const char* user_func_json,
  uint32_t user_func_json_len,
  /** null terminated string */
  char** bad_status_message,
  graphl_status_t* out_status_code,
  uint32_t* result_len
);

#endif // GRAPHL_H
