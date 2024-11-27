(typeof (main)
        i32)
(define (main)
        (begin 
           (query-string
             (WHERE (FROM (SELECT "col1")
                          "table")
                    (== col1 2)))
           (return 0)))
