#!chezscheme
;; Entry point for gherkin-shell
(import (chezscheme) (gsh main) (except (gsh builtins) list-head)
        (gsh registry) (gsh script)
        (only (compiler compile) gerbil-compile-top)
        (only (reader reader) gerbil-read))

;; Set tier and force builtin registration
(*gsh-tier* "small")
;; Touch a builtins export to force Chez to invoke (gsh builtins),
;; which runs the defbuiltin registration side effects.
(let () special-builtin? (void))

;; Helper: capture output to string (Chez native)
(define (output-to-string proc)
  (let ((p (open-output-string)))
    (proc p)
    (get-output-string p)))

;; Read Gerbil forms using the Gerbil reader (handles [...], {...}, keywords)
(define (gerbil-read-all port)
  (let lp ((forms '()))
    (let ((datum (gerbil-read port)))
      (if (eof-object? datum)
        (reverse forms)
        (lp (cons datum forms))))))

(define (gerbil-read-all-from-string str)
  (gerbil-read-all (open-input-string str)))

;; Pre-load Gerbil runtime into eval environment on first use.
;; Also installs Gambit-compatible shims for primitives used by Gerbil code.
(define *gerbil-env-ready* #f)
(define (ensure-gerbil-env!)
  (unless *gerbil-env-ready*
    (set! *gerbil-env-ready* #t)
    (let ((env (interaction-environment)))
      ;; Import Gherkin runtime modules
      (for-each
        (lambda (lib) (eval `(import ,lib) env))
        '((except (runtime util) string->bytes bytes->string
            string-split string-join find string-index pgetq pgetv pget)
          (except (runtime table) string-hash)
          (runtime hash)
          (except (runtime mop) class-type-flag-system
            class-type-flag-metaclass class-type-flag-sealed
            class-type-flag-struct type-flag-id type-flag-concrete
            type-flag-macros type-flag-extensible type-flag-opaque)
          (runtime error)
          (compat types)))
      ;; Gambit f64vector shims (Chez uses flvector)
      (eval '(define (make-f64vector n . rest)
               (if (null? rest) (make-flvector n)
                 (make-flvector n (car rest)))) env)
      (eval '(define f64vector-ref flvector-ref) env)
      (eval '(define f64vector-set! flvector-set!) env)
      ;; Gambit ##process-statistics shim
      ;; Returns an flvector compatible with Gambit layout:
      ;; [0]=user-cpu [2]=real-time [5]=gc-time
      (eval `(define (,(string->symbol "##process-statistics"))
               (let ((v (make-flvector 14 0.0)))
                 (flvector-set! v 0 (/ (cpu-time) 1000.0))
                 (flvector-set! v 2 (/ (real-time) 1000.0))
                 v)) env)
      ;; Gambit threading shims (Chez uses fork-thread + mutex/condition)
      ;; Thread object: #(thunk mtx cnd result done?)
      (eval '(define (make-thread thunk)
               (vector thunk (make-mutex) (make-condition) #f #f)) env)
      (eval '(define (thread-start! thr)
               (let ((thunk (vector-ref thr 0))
                     (mtx   (vector-ref thr 1))
                     (cnd   (vector-ref thr 2)))
                 (fork-thread
                   (lambda ()
                     (let ((v (thunk)))
                       (mutex-acquire mtx)
                       (vector-set! thr 3 v)
                       (vector-set! thr 4 #t)
                       (condition-broadcast cnd)
                       (mutex-release mtx))))
                 thr)) env)
      (eval '(define (thread-join! thr)
               (let ((mtx (vector-ref thr 1))
                     (cnd (vector-ref thr 2)))
                 (mutex-acquire mtx)
                 (let lp ()
                   (if (vector-ref thr 4)
                     (let ((r (vector-ref thr 3)))
                       (mutex-release mtx) r)
                     (begin (condition-wait cnd mtx) (lp)))))) env)
      (eval '(define (thread-sleep! secs)
               (sleep (make-time 'time-duration
                        (exact (round (* (- secs (floor secs)) 1000000000)))
                        (exact (floor secs))))) env)
      ;; Gambit SMP primitives — no-ops on Chez (threads are always OS-level)
      (eval `(define (,(string->symbol "##set-parallelism-level!") n) (void)) env)
      (eval `(define (,(string->symbol "##startup-parallelism!")) (void)) env)
      (eval `(define (,(string->symbol "##current-vm-processor-count")) 8) env)
      ;; Gambit I/O shims
      (eval '(define (force-output . args)
               (flush-output-port
                 (if (null? args) (current-output-port) (car args)))) env))))

;; Compile and eval Gerbil forms in the interaction-environment.
;; Skips (export ...) and (import ...) forms (Gerbil std imports aren't
;; available as Chez libraries; runtime is pre-loaded by ensure-gerbil-env!).
(define (gerbil-eval-forms gerbil-forms)
  (ensure-gerbil-env!)
  (let ((env (interaction-environment)))
    (let loop ((fs gerbil-forms) (last (void)))
      (if (null? fs) last
        (let ((form (car fs)))
          (cond
            ;; Skip (export ...) — meaningless in interactive env
            ((and (pair? form) (eq? (car form) 'export))
             (loop (cdr fs) last))
            ;; Skip (import ...) — Gerbil std modules aren't Chez libraries;
            ;; runtime already loaded via ensure-gerbil-env!
            ((and (pair? form) (eq? (car form) 'import))
             (loop (cdr fs) last))
            (else
             (let ((chez-form (gerbil-compile-top form)))
               (loop (cdr fs) (eval chez-form env))))))))))

;; Format a result value for display
(define (format-result result)
  (cond
    [(eq? result (void)) ""]
    [(or (pair? result) (vector? result))
     (output-to-string (lambda (port) (pretty-print result port)))]
    [else
     (output-to-string (lambda (port) (write result port)))]))

;; ,use file.ss — read a Gerbil source file, compile through Gherkin, and eval
(define (handle-use-command path-str)
  (let ((path (string-trim-whitespace path-str)))
    (unless (file-exists? path)
      (error 'use (string-append "file not found: " path)))
    (let* ((port (open-input-file path))
           (forms (gerbil-read-all port)))
      (close-input-port port)
      (let ((result (gerbil-eval-forms forms)))
        (fprintf (current-error-port) "loaded: ~a (~a forms)~n"
                 path (length forms))
        result))))

(define (string-trim-whitespace s)
  (let* ((len (string-length s))
         (start (let lp ((i 0))
                  (if (and (< i len) (char-whitespace? (string-ref s i)))
                    (lp (+ i 1)) i)))
         (end (let lp ((i len))
                (if (and (> i start) (char-whitespace? (string-ref s (- i 1))))
                  (lp (- i 1)) i))))
    (substring s start end)))

(define (string-prefix? prefix str)
  (and (>= (string-length str) (string-length prefix))
       (string=? (substring str 0 (string-length prefix)) prefix)))

;; Install Gerbil eval handler with ,use / ,exports meta-commands
(*meta-command-handler*
  (lambda (expr-str)
    (guard (exn
             [#t (cons
                   (output-to-string
                     (lambda (port)
                       (display "Gerbil error: " port)
                       (display-condition exn port)))
                   1)])
      (cond
        ;; ,use file.ss — compile and load a Gerbil source file
        [(string-prefix? "use " expr-str)
         (let ((result (handle-use-command
                         (substring expr-str 4 (string-length expr-str)))))
           (cons (format-result result) 0))]
        ;; Normal Gerbil eval
        [else
         (let* ((gerbil-forms (gerbil-read-all-from-string expr-str))
                (result (gerbil-eval-forms gerbil-forms)))
           (cons (format-result result) 0))]))))

;; Get args from GSH_ARGC/GSH_ARGn env vars (set by gsh-main.c)
;; or fall back to (command-line) for interpreted mode.
(define (get-real-args)
  (let ((argc-str (getenv "GSH_ARGC")))
    (if argc-str
      ;; Binary mode: custom main saved args in env vars
      (let ((argc (string->number argc-str)))
        (let loop ((i 0) (acc '()))
          (if (>= i argc)
            (reverse acc)
            (let ((val (getenv (format "GSH_ARG~a" i))))
              (loop (+ i 1) (cons (or val "") acc))))))
      ;; Interpreted mode (--program): use (command-line)
      (let ((cmdline (command-line)))
        (if (pair? cmdline) (cdr cmdline) '())))))

(apply main (get-real-args))
