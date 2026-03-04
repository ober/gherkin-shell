#!chezscheme
;;; signal-handler.sls -- Gerbil :std/os/signal-handler compat
;;; Provides add-signal-handler! using FFI signal flag mechanism.
;;; In gerbil-shell, signal handling uses the C-level flag approach
;;; from ffi-shim.c rather than Gambit's add-signal-handler!.

(library (compat signal-handler)
  (export add-signal-handler! remove-signal-handler!)

  (import (chezscheme))

  ;; add-signal-handler! is a no-op in the Chez port because
  ;; gerbil-shell uses its own FFI-based signal flag mechanism
  ;; (ffi-signal-flag-install / ffi-signal-flag-check).
  ;; The signals.ss module installs handlers via the FFI directly.
  (define (add-signal-handler! sig handler)
    (void))

  (define (remove-signal-handler! sig)
    (void))

  ) ;; end library
