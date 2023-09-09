(if (/ 1
       (+ 100
          over-time))
    (single-line-trace-by-channel (get-actor-location #void)
                                  (+ (get-actor-location #void)
                                     100)
                                  'visibility
                                  #t
                                  '()
                                  'arrow
                                  #f))
