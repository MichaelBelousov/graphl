#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Slice {
  const char* ptr;
  size_t len;
} Slice;

typedef struct Loc {
  size_t line, col, index;
} Loc;

typedef union SourceToGraphErr {
  Loc unexpectedEof;
} SourceToGraphErr;

typedef union SourceToGraphResult {
  Slice ok;
  SourceToGraphErr err;
} SourceToGraphResult;

typedef union GraphToSourceErr {
  //Loc unexpectedEof;
} GraphToSourceErr;

typedef union GraphToSourceResult {
  Slice ok;
  GraphToSourceErr err;
} GraphToSourceResult;

GraphToSourceResult graph_to_source(Slice);
SourceToGraphResult source_to_graph(Slice);

#ifdef __cplusplus
} // extern C
#endif
