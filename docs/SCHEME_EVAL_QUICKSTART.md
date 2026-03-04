# Quick Start: Scheme Evaluation

Lines starting with comma (`,`) are evaluated as Gerbil Scheme:

```bash
$ gsh
gsh$ ,(+ 1 2 3)
6
gsh$ ,(string-append "Hello " "World")
"Hello World"
gsh$ ,(map (lambda (x) (* x x)) '(1 2 3 4 5))
(1 4 9 16 25)
gsh$ echo "Back to shell"
Back to shell
gsh$ ,(getenv "HOME")
"/home/user"
```

## Why?

- **Quick calculations** without spawning `bc` or `python`
- **File system queries** using Scheme predicates
- **Data transformations** with the full Gerbil standard library
- **Prototyping** Scheme code in your shell workflow
- **No context switching** between shell and REPL

## Examples

```bash
# Define a helper function
,(define (celsius->fahrenheit c) (+ (* c 9/5) 32))
,(celsius->fahrenheit 20)  # => 68

# File operations
,(filter (lambda (f) (pregexp-match "\\.txt$" f)) (directory-files "."))

# JSON processing
,(import :std/text/json)
,(call-with-input-file "config.json" read-json)
```

See [scheme-eval.md](./scheme-eval.md) for complete documentation.
