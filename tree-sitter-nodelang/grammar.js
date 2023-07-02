const ident_regex = /[a-zA-Z_][a-zA-Z0-9_]*/;

function commalist(l_delim, type, comma, r_delim) {
  return seq(l_delim, repeat(seq(type, comma)), optional(type), r_delim);
}

function quoted(delim, rdelim = delim) {
  // NOTE: perhaps a custom scanner would be better here
  return token(
    seq(
      delim,
      repeat(
        choice("\\" + rdelim, token.immediate(new RegExp(`[^\\\\${rdelim}]+`)))
      ),
      rdelim
    )
  );
}

module.exports = grammar({
  name: "nodelang",
  rules: {
    // NOTE: the first rule is the top-level one!
    source_file: ($) => repeat(choice($._stmt, $._decl)),
    body: ($) => seq("{", repeat(choice($._stmt, $._decl)), "}"),

    quoted: ($) => choice(quoted("'"), quoted('"')),
    identifier: ($) => choice(ident_regex, $.quoted),

    integer: ($) => /\d+/,
    float: ($) => /\d+\.\d+/,
    array: ($) => commalist("[", $._expr, ",", "]"),
    _literal: ($) => choice($.integer, $.float, $.array),

    group_decl: ($) => seq("group", field("name", $.identifier), $.body),

    var_decl: ($) =>
      seq(
        "const",
        field("name", $.identifier),
        optional(seq(":", field("type", $._expr))),
        "=",
        field("value", $._expr)
      ),

    _decl: ($) => choice($.var_decl, $.group_decl),

    _stmt: ($) => choice($.if, $._expr),

    word: ($) => $.identifier,

    assign: ($) =>
      seq(field("name", $.identifier), "=", field("value", $._expr)),

    append_assign: ($) =>
      seq(field("identifier", $.identifier), "+=", field("value", $._expr)),

    comment: ($) => token(/#.*/),

    if: ($) =>
      choice(
        seq(
          "if",
          "(",
          field("cond", $._expr),
          ")",
          field("then", $.body),
          optional(seq("else", $.body))
        )
      ),

    _arg: ($) =>
      seq(
        optional(seq(".", field("name", $.identifier), "=")),
        field("value", $._expr)
      ),
    args: ($) => commalist("(", $._arg, ",", ")"),

    // unary
    not: ($) => prec(1000, seq("!", $._expr)),
    group: ($) => prec(1000, seq("(", $._expr, ")")),
    _unary_expr: ($) => choice($.not, $.group),

    // binary
    eq: ($) => prec.left(2, seq($._expr, "==", $._expr)),
    or: ($) => prec.left(3, seq($._expr, "||", $._expr)),
    and: ($) => prec.left(4, seq($._expr, "&&", $._expr)),
    call: ($) => prec.left(5, seq(field("callee", $._expr), $.args)),
    deref: ($) => prec.left(6, seq($._expr, ".", $.identifier)),
    _binary_expr: ($) => choice($.eq, $.or, $.and, $.call, $.deref),

    _expr: ($) =>
      choice($._binary_expr, $._unary_expr, $._literal, $.identifier),
  },

  // prettier-ignore
  extras: ($) => [
    $.comment,
    /\s/, // whitespace
  ],
});
