#!chezscheme
;;; fdio.sls -- Gerbil :std/os/fdio compat
;;; Provides fdread, fdwrite, write-subu8vector via FFI.
;;; In gerbil-shell, these are provided by (gsh ffi) directly,
;;; so this module re-exports stubs or delegates.

(library (compat fdio)
  (export fdread fdwrite write-subu8vector)

  (import (chezscheme))

  ;; These are stubs — actual fd I/O is done via (gsh ffi) functions:
  ;; ffi-fdread, ffi-fdwrite. The :std/os/fdio import in gerbil-shell
  ;; is only used in builtins.ss for write-subu8vector.

  ;; fdread: read count bytes from fd, returns bytevector
  (define (fdread fd count)
    (let* ((buf (make-bytevector count))
           (n ((foreign-procedure "read" (int u8* unsigned-int) int) fd buf count)))
      (if (> n 0)
        (if (= n count) buf
          (let ((result (make-bytevector n)))
            (bytevector-copy! buf 0 result 0 n)
            result))
        (make-bytevector 0))))

  ;; fdwrite: write bytevector to fd, returns bytes written
  (define (fdwrite fd bv)
    ((foreign-procedure "write" (int u8* unsigned-int) int) fd bv (bytevector-length bv)))

  ;; write-subu8vector: write a slice of a bytevector to a port
  ;; Gerbil's write-subu8vector writes bytes to a port.
  ;; Chez note: current-output-port is textual, so convert to string.
  (define (write-subu8vector bv start end . port-opt)
    (let ((port (if (pair? port-opt) (car port-opt) (current-output-port))))
      (if (binary-port? port)
        (put-bytevector port bv start (- end start))
        ;; Textual port: convert bytevector slice to string
        (let ((sub (if (and (= start 0) (= end (bytevector-length bv)))
                     bv
                     (let ((r (make-bytevector (- end start))))
                       (bytevector-copy! bv start r 0 (- end start))
                       r))))
          (display (utf8->string sub) port)))))

  ) ;; end library
