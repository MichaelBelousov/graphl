{
  "targets": [
    {
      "target_name": "addon",
      "sources": [
        "index.cpp"
      ],
      "include_dirs": [
        '''<!@(node -p "require('node-addon-api').include")''',
      ],
      "defines": [
        "NAPI_CPP_EXCEPTIONS",
      ],
      "libraries": [
        "../zig-out/lib/libgraph-lang.a"
      ],
      "cflags!": [ "-fno-exceptions" ],
      "cflags_cc!": [ "-fno-exceptions" ],
      "cflags_cc": ["-std=c++17"],
      "conditions": [
        ["OS=='mac'", {
          "cflags+": ["-fvisibility=hidden"],
          "xcode_settings": {
            "GCC_SYMBOLS_PRIVATE_EXTERN": "YES",
            "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
          }
        }]
      ]
    }
  ]
}
