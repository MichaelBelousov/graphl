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

;;; MACROS THAT CREATE DEFINITIONS
;;; this is a tough one, because ideally the visual editor lists definitions,
;;; so where would you "edit" the code that expands to definitions?



;; note that the callback on-enter must be easily interpretable
;; as an output of the visual node version!

;; inspired by similar ue4 macro
;; idea: use a namespace as a node...
(macro (gate start-closed on-enter)
  ;; basically just a closure
  ;; defines a node with exec pin entries defined by the labels, and exec out pins
  ;; defined by the 
  (namespace
    (var closed start-closed)

    #!is-closed
    (begin closed)

    #!enter
    (lambda ()
      (cond ((not closed) (on-enter))))

    #!open
    (lambda ()
      (set! closed false))

    #!close
    (lambda ()
      (set! closed true))))

(defs-macro (define-ast x)
  (define (symbol (fmt "print-{}" x)) 5)
  (define (symbol (fmt "print-{}" x)) 5))

(export sql)
