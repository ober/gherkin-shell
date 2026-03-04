#!chezscheme
;;; sugar.sls -- Gerbil-compatible macros for Chez Scheme
;;; Each gsh module imports this alongside (chezscheme).

(library (compat sugar)
  (export
    def def*
    defrule
    gerbil-set!
    try/catch try/finally try/catch/finally
    with-catch
    unwind-protect
    while until
    chain
    defstruct
    error)

  (import (rename (chezscheme) (error chez:error)))

  ;; Gerbil-compatible error: (error msg . irritants)
  ;; Chez: (error who msg . irritants)
  (define (error msg . irritants)
    (apply chez:error #f msg irritants))

  ;; --- def ---
  (define-syntax def
    (lambda (stx)
      (syntax-case stx ()
        ((_ (name . args) body0 body* ...)
         #'(define (name . args) body0 body* ...))
        ((_ name expr)
         #'(define name expr))
        ((_ name)
         #'(define name (void))))))

  ;; --- def* (case-lambda) ---
  (define-syntax def*
    (lambda (stx)
      (syntax-case stx ()
        ((_ name clause ...)
         #'(define name (case-lambda clause ...))))))

  ;; --- defrule (single-pattern syntax-rules) ---
  (define-syntax defrule
    (syntax-rules ()
      ((_ (name . pattern) template)
       (define-syntax name
         (syntax-rules ()
           ((_ . pattern) template))))))

  ;; --- set! with struct-field support ---
  ;; (gerbil-set! (accessor obj) val) → (accessor-set! obj val)
  (define-syntax gerbil-set!
    (lambda (stx)
      (syntax-case stx ()
        ((_ (accessor obj) val)
         (identifier? #'accessor)
         (with-syntax ((setter (datum->syntax #'accessor
                         (string->symbol
                           (string-append
                             (symbol->string (syntax->datum #'accessor))
                             "-set!")))))
           #'(setter obj val)))
        ((_ var val)
         #'(set! var val)))))

  ;; --- try/catch ---
  (define-syntax try/catch
    (syntax-rules ()
      ((_ (body ...) e handler ...)
       (guard (e (#t handler ...))
         body ...))))

  ;; --- try/finally ---
  (define-syntax try/finally
    (syntax-rules ()
      ((_ (body ...) cleanup ...)
       (dynamic-wind
         void
         (lambda () body ...)
         (lambda () cleanup ...)))))

  ;; --- try/catch/finally ---
  (define-syntax try/catch/finally
    (syntax-rules ()
      ((_ (body ...) e (handler ...) cleanup ...)
       (dynamic-wind
         void
         (lambda ()
           (guard (e (#t handler ...))
             body ...))
         (lambda () cleanup ...)))))

  ;; --- with-catch ---
  (define-syntax with-catch
    (syntax-rules ()
      ((_ handler thunk)
       (guard (exn (#t (handler exn)))
         (thunk)))))

  ;; --- unwind-protect ---
  ;; (unwind-protect body cleanup ...) — execute body, then cleanup regardless
  (define-syntax unwind-protect
    (syntax-rules ()
      ((_ body cleanup ...)
       (dynamic-wind
         (lambda () (void))
         (lambda () body)
         (lambda () cleanup ...)))))

  ;; --- while / until ---
  (define-syntax while
    (syntax-rules ()
      ((_ test body ...)
       (let loop ()
         (when test body ... (loop))))))

  (define-syntax until
    (syntax-rules ()
      ((_ test body ...)
       (let loop ()
         (unless test body ... (loop))))))

  ;; --- chain ---
  ;; (chain val (f) (g x _)) threads val through calls
  (define-syntax chain
    (lambda (stx)
      (define (underscore? x)
        (and (identifier? x) (eq? (syntax->datum x) '_)))
      (define (has-underscore? form)
        (syntax-case form ()
          (x (underscore? #'x) #t)
          ((a . b) (or (has-underscore? #'a) (has-underscore? #'b)))
          (else #f)))
      (define (subst form val)
        (syntax-case form ()
          (x (underscore? #'x) val)
          ((a . b)
           (with-syntax ((sa (subst #'a val))
                         (sb (subst #'b val)))
             #'(sa . sb)))
          (other #'other)))
      (syntax-case stx ()
        ((_ expr) #'expr)
        ((_ expr (f a ...) rest ...)
         (if (has-underscore? #'(f a ...))
           (with-syntax ((applied (subst #'(f a ...) #'expr)))
             #'(chain applied rest ...))
           #'(chain (f expr a ...) rest ...)))
        ((_ expr f rest ...)
         (identifier? #'f)
         #'(chain (f expr) rest ...)))))

  ;; --- defstruct ---
  ;; (defstruct name (f1 f2 ...) transparent: #t)
  ;; → Chez define-record-type with Gerbil-named accessors/mutators
  (define-syntax defstruct
    (lambda (stx)
      (syntax-case stx ()
        ((_ name (field ...) . opts)
         (identifier? #'name)
         (let* ((name-sym (syntax->datum #'name))
                (name-str (symbol->string name-sym))
                (field-syms (map syntax->datum (syntax->list #'(field ...))))
                (field-specs
                  (map (lambda (f)
                         (let ((f-str (symbol->string f)))
                           `(mutable ,f
                              ,(string->symbol (string-append name-str "-" f-str))
                              ,(string->symbol (string-append name-str "-" f-str "-set!")))))
                       field-syms))
                (form
                  `(define-record-type ,name-sym
                     (nongenerative)
                     (sealed #f)
                     (fields ,@field-specs)
                     (protocol
                       (lambda (p)
                         (lambda ,field-syms
                           (p ,@field-syms)))))))
           (datum->syntax #'name form))))))

  ) ;; end library
