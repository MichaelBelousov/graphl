(typeof (main)
        i32)
(define (main)
        (begin 
           (query-string
             (WHERE (FROM (SELECT "table")
                          "test")
                    (== col1 2)))
           (return 0)))
