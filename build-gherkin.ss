#!chezscheme
;;; build-gherkin.ss — Compile local .ss modules using the Gherkin compiler
;;; Usage: scheme -q --libdirs <gherkin-path>:src < build-gherkin.ss
;;;
;;; Reads .ss source files from the project root directory and compiles
;;; them to .sls (R6RS library) files in src/gsh/ via the Gherkin compiler.

(import
  (except (chezscheme) void box box? unbox set-box!
          andmap ormap iota last-pair find
          1+ 1- fx/ fx1+ fx1-
          error error? raise with-exception-handler identifier?
          hash-table? make-hash-table)
  (compiler compile))

;; --- Configuration ---
;; Source .ss files come from the gerbil-shell submodule, with local overrides
(define submodule-dir "gerbil-shell")
(define output-dir "src/gsh")

;; Find source file: check local override first, then submodule
(define (find-source name)
  (let ((local (string-append "./" name ".ss"))
        (sub   (string-append submodule-dir "/" name ".ss")))
    (cond
      ((file-exists? local) local)
      ((file-exists? sub)   sub)
      (else (error 'find-source "source file not found" name)))))

;; --- Import map: Gerbil module → Chez library ---
(define gsh-import-map
  '(;; Standard library mappings
    (:std/sugar        . (compat sugar))
    (:std/format       . (compat format))
    (:std/sort         . (compat sort))
    (:std/pregexp      . (compat pregexp))
    (:std/misc/string  . (compat misc))
    (:std/misc/list    . (compat misc))
    (:std/misc/path    . (compat misc))
    (:std/misc/hash    . (compat misc))
    (:std/iter         . #f)  ;; stripped — Gherkin compiles for-loops natively
    (:std/error        . (runtime error))
    (:std/os/signal    . (compat signal))
    (:std/os/signal-handler . (compat signal-handler))
    (:std/os/fdio      . (compat fdio))
    (:std/srfi/1       . (compat misc))
    (:std/foreign      . #f)  ;; stripped
    (:std/build-script . #f)  ;; stripped
    ;; Gerbil runtime
    (:gerbil/core      . #f)  ;; stripped
    (:gerbil/runtime   . #f)  ;; stripped
    (:gerbil/runtime/init . #f)
    (:gerbil/runtime/loader . #f)
    (:gerbil/expander   . #f)
    (:gerbil/compiler   . #f)
    ;; Relative imports
    ("./pregexp-compat" . (gsh pregexp-compat))
    ))

;; --- Base imports for all compiled modules ---
(define gsh-base-imports
  '((except (chezscheme) box box? unbox set-box!
            andmap ormap iota last-pair find
            1+ 1- fx/ fx1+ fx1-
            error error? raise with-exception-handler identifier?
            hash-table? make-hash-table
            sort sort! path-extension
            printf fprintf
            ;; Exclude Chez builtins that (compat gambit) replaces
            file-directory? file-exists? getenv close-port
            ;; Chez void takes 0 args; Gerbil's is variadic
            void
            ;; Gambit-compatible: handles /dev/fd/N and keyword args
            open-output-file open-input-file)
    (compat types)
    (except (runtime util)
            ;; These conflict with (compat gambit) exports
            string->bytes bytes->string
            ;; These conflict with (compat misc) exports
            string-split string-join find string-index
            ;; Unused internal helpers
            pgetq pgetv pget)
    (except (runtime table) string-hash)
    (runtime mop)
    (except (runtime error) with-catch with-exception-catcher)
    (runtime hash)
    ;; Import most of (compat gambit) — u8vector, threading, etc.
    ;; Exclude names that conflict with (chezscheme) builtins we still need:
    ;;   number->string, make-mutex, with-output-to-string
    (except (compat gambit) number->string make-mutex
            with-output-to-string)
    ;; Misc utilities (string-prefix?, path-expand, etc.)
    ;; from :std/misc/* which are stripped from :gerbil/core
    (compat misc)))

;; --- Import conflict resolution ---
;; In R6RS, local definitions can't shadow imported bindings.
;; After Gherkin compilation, fix imports by adding (except ...) clauses
;; for locally-defined names that conflict with library exports.
;; lib-form = (library <name> (export ...) (import ...) body-forms ...)
(define (fix-import-conflicts lib-form)
  (let* ((lib-name (cadr lib-form))
         (export-clause (caddr lib-form))       ;; (export ...)
         (import-clause (cadddr lib-form))       ;; (import ...)
         (body (cddddr lib-form))                ;; body forms
         (imports (cdr import-clause))
         ;; Collect all locally-defined names from the body
         (local-defs
           (let lp ((forms body) (names '()))
             (if (null? forms)
               names
               (lp (cdr forms)
                   (append (extract-def-names (car forms)) names)))))
         ;; Collect all names provided by EARLIER imports (for import-vs-import dedup)
         ;; Later imports that provide the same name must exclude it
         (all-earlier-names
           (let lp ((imps imports) (seen '()) (result '()))
             (if (null? imps)
               (reverse result)
               (let* ((imp (car imps))
                      (lib (get-import-lib-name imp))
                      (exports (if lib
                                 (or (begin (ensure-library-loaded lib)
                                       (guard (e (#t #f))
                                         (library-exports lib)))
                                     ;; Fallback: read exports from .sls file
                                     (read-sls-exports lib)
                                     '())
                                 '()))
                      ;; Names from this import that aren't already excluded
                      (provided (cond
                                  ((and (pair? imp) (eq? (car imp) 'except))
                                   (filter (lambda (s) (not (memq s (cddr imp))))
                                           exports))
                                  ((and (pair? imp) (eq? (car imp) 'only))
                                   (cddr imp))
                                  (else exports))))
                 (lp (cdr imps)
                     (append provided seen)
                     (cons seen result)))))))
    ;; Fix each import to exclude locally-defined names AND
    ;; names already provided by earlier imports
    (let ((fixed-imports
            (map (lambda (imp earlier-names)
                   (fix-one-import imp
                     (append local-defs earlier-names)))
                 imports all-earlier-names)))
      ;; Fix assigned exports: R6RS forbids exporting set!'d variables.
      ;; Replace (define name init) + (set! name impl) with an
      ;; indirection through a mutable internal variable.
      (let ((fixed-body (fix-assigned-exports
                          (cdr export-clause) ; export names
                          (list (cons 'import fixed-imports))
                          body)))
        `(library ,lib-name ,export-clause
          (import ,@fixed-imports) ,@fixed-body)))))

;; Fix exported variables that are set!'d (R6RS forbids this).
;; Pattern: (define name init) ... (set! name impl) in body
;; Fix: replace (define name init) with (define name (make-dispatch init))
;;      replace (set! name impl) with (dispatch-set! name impl)
;;      where dispatch wraps a mutable box
(define (fix-assigned-exports exports import-forms body)
  ;; Find all (set! name ...) anywhere in body where name is exported
  ;; Must recursively search inside function bodies
  (let ((assigned-names
          (let lp ((tree body) (names '()))
            (cond
              ((not (pair? tree)) names)
              ((and (eq? (car tree) 'set!)
                    (pair? (cdr tree))
                    (symbol? (cadr tree))
                    (memq (cadr tree) exports)
                    (not (memq (cadr tree) names)))
               (cons (cadr tree) names))
              (else
               (lp (cdr tree) (lp (car tree) names)))))))
    (if (null? assigned-names)
      body ;; no fixes needed
      ;; Use identifier-syntax for transparent get/set:
      ;; (define name-cell (vector initial-value))
      ;; (define-syntax name (identifier-syntax (id (vector-ref name-cell 0))
      ;;                                        ((set! id v) (vector-set! name-cell 0 v))))
      ;; All (set! name val) inside function bodies work automatically via the macro.
      (let ((new-body
              (let lp ((forms body) (result '()))
                (if (null? forms)
                  (reverse result)
                  (let ((form (car forms)))
                    (cond
                      ;; (define name init) or (define (name args...) body) where name is assigned
                      ((and (pair? form)
                            (eq? (car form) 'define)
                            (let ((def-name (if (pair? (cadr form)) (caadr form) (cadr form))))
                              (and (symbol? def-name) (memq def-name assigned-names))))
                       (let* ((def-name (if (pair? (cadr form)) (caadr form) (cadr form)))
                              (init (if (pair? (cadr form))
                                      ;; (define (name args) body) → (lambda (args) body)
                                      `(lambda ,(cdadr form) ,@(cddr form))
                                      ;; (define name init)
                                      (if (pair? (cddr form)) (caddr form) '(void))))
                              (cell-name (string->symbol
                                           (string-append (symbol->string def-name) "-cell"))))
                         (lp (cdr forms)
                             (append
                               (list
                                 ;; identifier-syntax: transparent getter/setter macro
                                 `(define-syntax ,def-name
                                    (identifier-syntax
                                      (id (vector-ref ,cell-name 0))
                                      ((set! id v) (vector-set! ,cell-name 0 v))))
                                 ;; Vector-cell: internal storage
                                 `(define ,cell-name (vector ,init)))
                               result))))
                      (else
                       (lp (cdr forms) (cons form result)))))))))
        new-body))))

;; Extract defined names from a top-level form
(define (extract-def-names form)
  (cond
    ((not (pair? form)) '())
    ((eq? (car form) 'define)
     (cond
       ((symbol? (cadr form)) (list (cadr form)))
       ((pair? (cadr form)) (list (caadr form)))
       (else '())))
    ((eq? (car form) 'define-syntax)
     (if (symbol? (cadr form)) (list (cadr form)) '()))
    ((eq? (car form) 'begin)
     (let lp ((forms (cdr form)) (names '()))
       (if (null? forms) names
           (lp (cdr forms) (append (extract-def-names (car forms)) names)))))
    (else '())))

;; Ensure a library is loaded so library-exports works
(define (ensure-library-loaded lib-name)
  (guard (e (#t #f))
    (eval `(import ,lib-name) (interaction-environment))
    #t))

;; Fallback: read exports directly from an .sls file
;; Parses (library <name> (export sym ...) ...) from the file
(define (read-sls-exports lib-name)
  (let ((path (lib-name->sls-path lib-name)))
    (if (and path (file-exists? path))
      (guard (e (#t #f))
        (call-with-input-file path
          (lambda (port)
            ;; Skip #!chezscheme line if present
            (let ((first (read port)))
              (let ((lib-form (if (and (pair? first) (eq? (car first) 'library))
                                first
                                (read port))))
                (if (and (pair? lib-form) (eq? (car lib-form) 'library))
                  (let ((export-clause (caddr lib-form)))
                    (if (and (pair? export-clause) (eq? (car export-clause) 'export))
                      (cdr export-clause)
                      #f))
                  #f))))))
      #f)))

;; Convert library name to .sls path
(define (lib-name->sls-path lib-name)
  (cond
    ((and (pair? lib-name) (= (length lib-name) 2)
          (eq? (car lib-name) 'gsh))
     (string-append output-dir "/" (symbol->string (cadr lib-name)) ".sls"))
    ((and (pair? lib-name) (= (length lib-name) 2)
          (eq? (car lib-name) 'compat))
     (string-append "src/compat/" (symbol->string (cadr lib-name)) ".sls"))
    (else #f)))

;; Fix one import spec to exclude locally-defined names
(define (fix-one-import imp local-defs)
  (let ((lib-name (get-import-lib-name imp)))
    (if (not lib-name)
      imp  ;; can't determine library name
      (let* ((_load (ensure-library-loaded lib-name))
             (lib-exports (or (guard (e (#t #f)) (library-exports lib-name))
                              (read-sls-exports lib-name)
                              '()))
             ;; Find local defs that actually conflict with this library
             (conflicts (filter (lambda (d) (memq d lib-exports))
                                local-defs)))
            (if (null? conflicts)
              imp  ;; no conflicts
              (cond
                ;; Already (except lib ...) — extend
                ((and (pair? imp) (eq? (car imp) 'except))
                 (let ((existing (cddr imp)))
                   `(except ,(cadr imp)
                      ,@existing
                      ,@(filter (lambda (d) (not (memq d existing)))
                                conflicts))))
                ;; (only lib ...) — remove conflicts from only-list
                ((and (pair? imp) (eq? (car imp) 'only))
                 (let ((kept (filter (lambda (s) (not (memq s conflicts)))
                                     (cddr imp))))
                   `(only ,(cadr imp) ,@kept)))
                ;; Bare library spec — wrap with except
                ((pair? imp)
                 `(except ,imp ,@conflicts))
                (else imp)))))))


;; Extract the bare library name from an import spec
(define (get-import-lib-name spec)
  (cond
    ((and (pair? spec)
          (memq (car spec) '(except only rename prefix)))
     (get-import-lib-name (cadr spec)))
    ((and (pair? spec) (symbol? (car spec)))
     spec)
    (else #f)))

;; --- Module compilation ---
(define (compile-module name)
  (let* ((input-path (find-source name))
         (output-path (string-append output-dir "/" name ".sls"))
         (lib-name `(gsh ,(string->symbol name))))
    (display (string-append "  Compiling: " name ".ss → " name ".sls\n"))
    (guard (exn
             (#t (display (string-append "  ERROR: " name ".ss failed: "))
                 (display (condition-message exn))
                 (when (irritants-condition? exn)
                   (display " — ")
                   (display (condition-irritants exn)))
                 (newline)
                 #f))
      (let* ((lib-form (gerbil-compile-to-library
                         input-path lib-name
                         gsh-import-map gsh-base-imports))
             ;; Post-process: fix import conflicts
             (lib-form (fix-import-conflicts lib-form)))
        ;; Write the library
        (call-with-output-file output-path
          (lambda (port)
            (display "#!chezscheme\n" port)
            (parameterize ([print-gensym #f])
              (pretty-print lib-form port)))
          'replace)
        (display (string-append "  OK: " output-path "\n"))
        #t))))

;; --- Main ---
(display "=== Gherkin Shell Builder ===\n\n")

;; Tier 1: No dependencies on other gsh modules
(display "--- Tier 1: Foundation ---\n")
(compile-module "ast")
(compile-module "registry")

;; Tier 2: Depends on Tier 1
(display "\n--- Tier 2: Core ---\n")
(compile-module "macros")
(compile-module "util")

;; Tier 3: Depends on Tier 1-2
(display "\n--- Tier 3: Modules ---\n")
(compile-module "environment")
(compile-module "lexer")
(compile-module "arithmetic")
(compile-module "glob")
(compile-module "fuzzy")
(compile-module "history")

;; Tier 4: Depends on Tier 1-3
(display "\n--- Tier 4: Processing ---\n")
(compile-module "parser")
(compile-module "functions")
(compile-module "signals")
(compile-module "expander")

;; Tier 5: Depends on Tier 1-4
(display "\n--- Tier 5: Execution ---\n")
(compile-module "redirect")
(compile-module "control")
(compile-module "jobs")
(compile-module "builtins")

;; Tier 6: Depends on Tier 1-5
(display "\n--- Tier 6: UI ---\n")
(compile-module "pipeline")
(compile-module "executor")
(compile-module "completion")
(compile-module "prompt")

;; Tier 7: Depends on all
(display "\n--- Tier 7: Top-level ---\n")
(compile-module "lineedit")
(compile-module "fzf")
(compile-module "script")
(compile-module "startup")
(compile-module "main")

;; --- Post-build: Force library invocation for side-effecting modules ---
;; Chez lazily invokes libraries — body expressions only run when a runtime
;; export is referenced. Modules like builtins.sls have defbuiltin calls
;; (expressions) that must run to register builtins. Fix: add a define in
;; main.sls that references a builtins export to force invocation.
(display "\n--- Post-build: Patching for Chez lazy invocation ---\n")
(let ()
  (define (string-find haystack needle)
    ;; Return index of needle in haystack, or #f
    (let ((hlen (string-length haystack))
          (nlen (string-length needle)))
      (let loop ((i 0))
        (cond
          ((> (+ i nlen) hlen) #f)
          ((string=? (substring haystack i (+ i nlen)) needle) i)
          (else (loop (+ i 1)))))))
  ;; Patch main.sls: add a define that references a builtins export
  ;; This forces Chez to invoke (gsh builtins) at library init time,
  ;; which executes the defbuiltin registration calls.
  (let* ((path "src/gsh/main.sls")
         (content (call-with-input-file path
                    (lambda (p) (get-string-all p)))))
    ;; Add (define _force-builtins special-builtin?) before first define
    (let ((needle (string #\newline #\space #\space #\( #\d #\e #\f #\i #\n #\e #\space)))
      (let ((idx (string-find content needle)))
        (if idx
          (begin
            (call-with-output-file path
              (lambda (p)
                (display (substring content 0 idx) p)
                (display "\n  ;; Force invocation of (gsh builtins) for defbuiltin registration\n" p)
                (display "  (define _force-builtins special-builtin?)" p)
                (display (substring content idx (string-length content)) p))
              'replace)
            (display "  Patched main.sls for lazy invocation\n"))
          (display "  WARNING: Could not find insertion point in main.sls\n"))))))

;; --- Post-build: Fix keyword dispatch in defclass constructors ---
;; Gherkin's defclass constructor incorrectly adds keyword values to the
;; positional arg list. The init! method is a case-lambda that uses positional
;; args (not keywords), so passing keyword values as positional breaks dispatch.
;; Fix: strip keyword pairs without adding values to positional.
;; Also fix callers (env-push-scope, env-clone) to use positional args.
(display "\n--- Post-build: Patching keyword dispatch ---\n")
(let ()
  (define (string-find haystack needle)
    (let ((hlen (string-length haystack))
          (nlen (string-length needle)))
      (let loop ((i 0))
        (cond
          ((> (+ i nlen) hlen) #f)
          ((string=? (substring haystack i (+ i nlen)) needle) i)
          (else (loop (+ i 1)))))))
  (define (patch-file! path old new)
    (let* ((content (call-with-input-file path
                      (lambda (p) (get-string-all p))))
           (idx (string-find content old)))
      (if idx
        (begin
          (call-with-output-file path
            (lambda (p)
              (display (substring content 0 idx) p)
              (display new p)
              (display (substring content (+ idx (string-length old))
                                 (string-length content)) p))
            'replace)
          (printf "  Patched ~a~n" path)
          #t)
        (begin
          (printf "  WARNING: Patch target not found in ~a~n" path)
          #f))))
  ;; Fix constructor: don't add keyword values to positional args
  (patch-file! "src/gsh/environment.sls"
    "(lp (cddr rest) (cons (cadr rest) acc))]"
    "(lp (cddr rest) acc)]")
  ;; Fix env-push-scope: use positional args instead of keywords
  (patch-file! "src/gsh/environment.sls"
    "(define (env-push-scope env)\n    (make-shell-environment\n      'parent:\n      env\n      'name:\n      (shell-environment-shell-name env)))"
    "(define (env-push-scope env)\n    (make-shell-environment env (shell-environment-shell-name env)))")
  ;; Fix env-clone: use no-arg constructor + set shell-name manually
  (patch-file! "src/gsh/environment.sls"
    "(define (env-clone env)\n    (let ([clone (make-shell-environment\n                   'name:\n                   (shell-environment-shell-name env))])"
    "(define (env-clone env)\n    (let ([clone (let ([e (make-shell-environment)])\n                   (shell-environment-shell-name-set! e (shell-environment-shell-name env))\n                   e)])"))

(display "\n--- Post-build: Patching exception-message for Chez ---\n")
(let ()
  (define (string-find haystack needle)
    (let ((hlen (string-length haystack))
          (nlen (string-length needle)))
      (let loop ((i 0))
        (cond
          ((> (+ i nlen) hlen) #f)
          ((string=? (substring haystack i (+ i nlen)) needle) i)
          (else (loop (+ i 1)))))))
  (define (patch-file! path old new)
    (let* ((content (call-with-input-file path
                      (lambda (p) (get-string-all p))))
           (idx (string-find content old)))
      (if idx
        (begin
          (call-with-output-file path
            (lambda (p)
              (display (substring content 0 idx) p)
              (display new p)
              (display (substring content (+ idx (string-length old))
                                 (string-length content)) p))
            'replace)
          (printf "  Patched ~a~n" path)
          #t)
        (begin
          (printf "  WARNING: Patch target not found in ~a~n" path)
          #f))))
  ;; Fix exception-message: Chez condition-message / Error-message return
  ;; raw format templates (e.g. "variable ~:s is not bound") instead of
  ;; formatted strings. Use display-condition which formats with irritants.
  (patch-file! "src/gsh/util.sls"
    "(define (exception-message e)\n    (cond\n      [(Error? e) (Error-message e)]\n      [(error-exception? e) (error-exception-message e)]\n      [(string? e) e]\n      [(os-exception? e)\n       (call-with-output-string\n         (lambda (p) (display-exception e p)))]\n      [else\n       (call-with-output-string\n         (lambda (p) (display-exception e p)))]))"
    "(define (exception-message e)\n    (define (format-condition e)\n      (let ([msg (call-with-string-output-port\n                   (lambda (p) (display-condition e p)))])\n        (if (and (> (string-length msg) 11)\n                 (string=? (substring msg 0 11) \"Exception: \"))\n            (substring msg 11 (string-length msg))\n            (if (and (> (string-length msg) 13)\n                     (string=? (substring msg 0 13) \"Exception in \"))\n                (let loop ([i 13])\n                  (cond\n                    [(>= (+ i 1) (string-length msg)) msg]\n                    [(and (char=? (string-ref msg i) #\\:)\n                          (char=? (string-ref msg (+ i 1)) #\\space))\n                     (substring msg (+ i 2) (string-length msg))]\n                    [else (loop (+ i 1))]))\n                msg))))\n    (cond\n      [(string? e) e]\n      [(condition? e) (format-condition e)]\n      [else (call-with-string-output-port\n              (lambda (p) (display e p)))]))"))

(display "\n--- Post-build: Patching pipeline for Chez ---\n")
(let ()
  (define (string-find haystack needle)
    (let ((hlen (string-length haystack))
          (nlen (string-length needle)))
      (let loop ((i 0))
        (cond
          ((> (+ i nlen) hlen) #f)
          ((string=? (substring haystack i (+ i nlen)) needle) i)
          (else (loop (+ i 1)))))))
  (define (patch-file! path old new)
    (let* ((content (call-with-input-file path
                      (lambda (p) (get-string-all p))))
           (idx (string-find content old)))
      (if idx
        (begin
          (call-with-output-file path
            (lambda (p)
              (display (substring content 0 idx) p)
              (display new p)
              (display (substring content (+ idx (string-length old))
                                 (string-length content)) p))
            'replace)
          (printf "  Patched ~a~n" path)
          #t)
        (begin
          (printf "  WARNING: Patch target not found in ~a~n" path)
          #f))))
  ;; Fix make-mutex: Chez requires symbol or #f, Gambit accepts strings
  (patch-file! "src/gsh/pipeline.sls"
    "(make-mutex \"pipeline-fd\")"
    "(make-mutex 'pipeline-fd)")
  ;; Fix void: Gerbil's void accepts any number of args, but the translated
  ;; (define (void) (void)) takes 0 args and infinitely recurses.
  (patch-file! "src/gsh/pipeline.sls"
    "(define (void) (void))"
    "(define (void . _) (if #f #f))"))

(display "\n=== Build complete ===\n")
