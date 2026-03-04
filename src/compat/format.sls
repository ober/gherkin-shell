#!chezscheme
;;; format.sls -- Gerbil format compatibility for Chez Scheme
;;; Chez format is nearly identical to Gerbil's. Main difference:
;;; Gerbil's (format #f fmt ...) returns string; Chez's (format #f fmt ...) also does.
;;; So this is mostly a passthrough, plus fprintf/printf aliases.

(library (compat format)
  (export fprintf printf)
  (import (except (chezscheme) fprintf printf))

  ;; fprintf is just format to a port
  (define (fprintf port fmt . args)
    (apply format port fmt args))

  ;; printf is format to stdout
  (define (printf fmt . args)
    (apply format (current-output-port) fmt args))

  ) ;; end library
