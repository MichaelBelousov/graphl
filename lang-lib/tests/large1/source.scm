(import utils (define-ranged))
(import utils ((as define-ranged dr)))

(define a (define-ranged 1 100 42))
(+ 11 a)
