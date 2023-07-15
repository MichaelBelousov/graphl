;;; sample definition, just so we can parse the node shapes out of everything

(import (ffi cpp))
(import (ffi c))

(define (delay (f32 s)) (sleep (* 1000 s)))

(define-macro (do-once reset-name body (default start-closed #f))
  (define locked start-closed)
  (define (reset-name) (set! locked #f))
  (if (not done)
      (begin
        (set! locked #t)
        body)))

(define-c-struct vector
  ((f32 x)
   (f32 y)
   (f32 z)))

(define (vector-length (vector v))
  (sqrt (+ (sqr (.x v)) ;; what does clojure do for field access?
           (sqr (.y v))
           (sqr (.z v)))))

(define-c-opaque actor)

;; will this invoke a C++ compiler? then we need headers, defines, etc
;; what if it just compiles to C code? That might be ideal for game engines...
(define (get-actor-location (actor a))
  (cpp-call "AActor::GetLocation" a))

(define (get-actor-rotation (actor a))
  (cpp-call "AActor::GetRotation" a))

(define-c-opaque scene-component)

(define (get-socket-location (scene-component c) (string socket-name))
  (cpp-call "USceneComponent::GetSocketLocation" c socket-name))

;;; TODO: separate out to physics

;; enum could be a list of known values
(define-enum trace-channels
  ('visibility 'collision))

(define-enum draw-debug-types
  ('none 'line 'arrow))

(define (single-line-trace-by-channel
          (vector start)
          (vector end)
          (trace-channels channel)
          (bool trace-complex)
          ((list actor) actors-to-ignore)
          (draw-debug-types draw-debug-type 'none)
          (bool ignore-self #t))
  (cpp-call "UKismetMathLibrary::SingleLineTraceByChannel" start end channel trace-complex actors-to-ignore
                                                           draw-debug-type ignore-self))

(export do-once)
(export actor get-actor-location get-actor-rotation)
(export vector vector-length)
