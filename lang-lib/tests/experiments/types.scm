(import (std io))

;; the visual graph must view each top level item separately

(type (! int) int)
(func (! x)
  (if (<= x 1)
      1
      (* x (! (- x 1)))))

(type x int)
(var x (! 20))

;; we need a main function in this lisp
(define (main)
  (io.console.print x))
