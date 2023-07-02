;;;; BLUEPRINT MACROS

;; reset-name adds a module-level name
(defmacro (do-once reset-name body (default start-closed #f))
  (define locked start-closed)
  (define (reset-name) (set! locked #f))
  (if (not done)
      (begin
        (set! locked #t)
        body)))


;;;; EVENT GRAPH
;;; translated from https://i.pinimg.com/originals/4b/75/80/4b7580742ac20edd4ce1e19fd5d34415.png

(define-event (tick)
  (set! "over-time"
    (/ (vector-length (- (get-actor-location self)
                         (get-actor-location current-spawn-point)))
       speed))
  (delay 0.1)
  (switch drone-state
    (('move-to-player
      ;;; FIXME: sequence is not idiomatic... nested begin would be better?
      ;; first move to target and then check if something is near
      (sequence 
        ;; we need to fire MoveComponent only ONCE
        ((do-once we-need-to-fire-MoveComponent-only-ONCE
            (move-component-to-move component: capsule-component
                               target-relative-rotation: (get-actor-rotation self))))
        ;; check if obstacle is forward to drone
        ((single-line-trace-by-channel start: (get-socket-location mesh "TraceSocket")
                                       end: (get-socket-location mesh "EndTraceSocket")
                                       ignore-self: #t)
         ;;; FIXME: how to reuse previous un-named nodes results?
         (if $prev.out
           ;;; FIXME: what are clojure's syntax extensions?
           ;; if we hit AIMainPawn
           (cast AI_MainPawn $prev.hit
              ;; We hit AIMain_Pawn Stop the movement and then change state and CheckAgain
              (sequence
                ;; Move Drone to TargetPoint
                ((goto (move-component-to-stop)))
                ;; Change State
                ((set! "Drone State" 'move-up)
                 (custom-tick self)))
              ;; We haven't hit anything - Check Again
              (custom-tick))
           ;; Check Again
           (custom-tick)))))
     ('move-up)
     ('dead
      (begin
        ;; we need to do this only once
        (do-once))))

;; type arguments?
(define (max (type n) (n a) (n b))
  (if (> a b) a b))

(define (subgraph (vec4 color) (vec4 color))
  (group "name"
    (define x 5)
    (define y (+ 10 x)))
  (group)
  )
