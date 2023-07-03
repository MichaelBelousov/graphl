#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Slice {
  const char* ptr;
  size_t len;
} Slice;

Slice graph_to_source(Slice);
Slice source_to_graph(Slice);

#ifdef __cplusplus
} // extern C
#endif
