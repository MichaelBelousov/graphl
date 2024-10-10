(if (/ 1
       (+ 100
          over-time))
    (single-line-trace-by-channel actor-location
                                  (+ actor-location
                                     100)
                                  'visibility
                                  #t
                                  '()
                                  'arrow
                                  #f))
