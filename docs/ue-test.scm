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
  (set! over-time
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
        ((do-once reset-do-once1
            (move-component-to-move component: capsule-component
                                    target-relative-location: (get-actor-location self)
                                    target-relative-rotation: (get-actor-rotation self)
                                    over-time: over-time)))
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
                ((goto (move-component-to-stop))) ;;; FIXME: how to determine that this macro has two entry points?
                ;; Change State
                ((set! drone-state 'move-up)
                 (custom-tick self)))
              ;; We haven't hit anything - Check Again
              (custom-tick self))
           ;; Check Again
           (custom-tick self)))))
     ('move-up
      ;;; FIXME: this double begin is not idiomatic from the code side... need to think about how better to
      ;;; do this. It will be common that in the graph realm that someone wants to do goto segment A followed by
      ;;; segment B. In the text realm that will be much harder...
      (begin
        (begin
          ;; We need to do this only once!
          (do-once reset-do-once2
            ;; move up by 150 points
            (move-component-to-move component: capsule-component
                                    target-relative-location: (+ '(0 0 150) (get-actor-location self))
                                    target-relative-rotation: (get-actor-rotation self)
                                    over-time: (/ 150 over-time))))
        (begin
          (if (single-line-trace-by-channel start: (get-socket-location mesh "TraceSocket")
                                        end: (get-socket-location mesh "EndTraceSocket")
                                        ignore-self: #t)
            ;; We are still near AiMain_Pawn - lets Check Again
            (custom-tick self)
            ;; We can move to Target Again
            (begin
              (set! drone-state 'move-to-player)
              ;; Reset DoOnece - so it can fire again
              (begin (begin (move-component-to-stop)))
                     (begin (do-once1-reset))
                     (begin (do-once2-reset))
                     ;; And CheckAgain
                     (begin (custom-tick self))))))))))

