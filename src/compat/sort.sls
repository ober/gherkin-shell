#!chezscheme
;;; sort.sls -- Gerbil sort compatibility
;;; Gerbil: (sort lst pred) — Chez: (list-sort pred lst) (arg order swap)

(library (compat sort)
  (export sort sort!)
  (import (except (chezscheme) sort sort!))

  (define (sort lst pred)
    (list-sort pred lst))

  ;; sort! is the same as sort (Chez has no in-place list sort)
  (define sort! sort)

  ) ;; end library
