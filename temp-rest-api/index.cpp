#include <node_api.h>
#include <napi.h>
#include "graph-lang.h"
#include <string>

// using C++ and including libstd for just this marshalling to zig is a bad idea
// SEE: https://github.com/staltz/zig-nodejs-example
// for removing the dependency eventually

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports["graph_to_source"] = Napi::Function::New(env, [](const Napi::CallbackInfo& info) -> Napi::Value {
    const auto graph = info[0].As<Napi::String>().Utf8Value();
    // FIXME: free
    const auto source = graph_to_source({graph.data(), graph.size()});
    return Napi::String::New(info.Env(), source.ptr);
  });

  exports["source_to_graph"] = Napi::Function::New(env, [](const Napi::CallbackInfo& info) -> Napi::Value {
    const auto source = info[0].As<Napi::String>().Utf8Value();
    // FIXME: free
    const auto graph = source_to_graph({source.data(), source.size()});
    return Napi::String::New(info.Env(), graph.ptr);
  });

  return exports;
}

NODE_API_MODULE(addon, Init)
