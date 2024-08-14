(import (std io))

;; the visual graph must view each top level item separately

;;; TYPES
;;; I like this separate (required?) statement to assign types
;;; idk about haskell style generics though

(typeof (! int) int)
(func (! x)
  (if (<= x 1)
      1
      (* x (! (- x 1)))))

(typeof x int)
(var x (! 20))

;; overloads
(typeof (print int) none)
(typeof (print str) none)
;; NOTE: contrived
(func (print x)
  (if (= (typeof x) str)
    (io.console.write x)
    (io.console.write (to-str x))))

;; generics - capitalized single letters being
;; automatically interpreted as type variables... need to think more...
(typeof (map (fntype (A) R) (seq A)) R)
;; NOTE: contrived
(func (map f lst)
  (if (== (lst '()))
    '()
    '(
      $(f (car lst))
      $..(map (cdr lst))
     )
    ))
    ;'(cons (f (car lst)) (map (cdr lst)))))

#| multiline comment |#

;;; MACROS

;; variant one (goto)
(expr-macro (while c loop ...)
  (if c #!start
    (begin loop ...)
    (goto start)))

;; variant two (recursive)
(expr-macro (while c body ...)
  (define (impl)
    (cond (c (begin body ...))))
  (impl))

(define (contrived1)
  (type x rational)
  (var x 5.0)
  (while (< x 0)
    (set! x (- x 1.0))
    (io.console.print x)))

;; inspired by similar ue4 macro
(expr-macro (gate start-closed)
  (define locked start-closed)
  (if cond #!start
    (begin loop ...)
    (goto start)))

(expr-macro (sql x ...)
  '(x $(x)))

;;; MACROS THAT CREATE DEFINITIONS
;;; this is a tough one, because ideally the visual editor lists definitions,
;;; so where would you "edit" the code that expands to definitions?

(defs-macro (define-ast x)
  (define (symbol (fmt "print-{}" x)) 5)
  (define (symbol (fmt "print-{}" x)) 5))

(export sql)
