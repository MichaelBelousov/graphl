;;; A gate macro
(define-macro (gate (bool in-locked #f) (code body))
  ;; definition is local to the macro... macros in this way are closures
  (define locked in-locked) ;; redefs are just sets (except set! not allowed to come after)
  (define (unlock) (set! locked #f)) ;; need alias for #t/#f true/false
  (define (lock) (set! locked #t))
  (define (run) body)
  (define () (run)))

;;; usage
(define say-hello
  (gate #f
    (print "hello!")))
(say-hello.run)
(say-hello.open) ;; what about (open say-hello?)
(say-hello.run)
((gate #f 2))

;; really similar to functional closures (e.g. JS)
;; function gate(inLocked: boolean = false, cb: () => any) {
;;   let locked = inLocked;
;;   return {
;;     unlock() { locked = false; },
;;     lock() { locked = true; },
;;     run: cb,
;;   };
;; }

;;; A gate macro type 2
(define-macro (gate (bool in-locked #f) (code body))
  ;; definition is local to the macro... macros in this way are closures
  (define locked in-locked) ;; redefs are just sets (except set! not allowed to come after)
  ; but does this continue then?
  ($unlock (set! locked #f))
  ($lock (set! locked #t))
  ($run (run) body))
