#include <node_api.h>
#include <napi.h>
#include "graph-lang.h"
#include <string>

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
