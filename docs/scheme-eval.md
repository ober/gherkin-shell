# Scheme Evaluation in gsh

gsh allows you to evaluate Gerbil Scheme expressions directly at the shell prompt using the **comma meta-command**.

## Usage

Any line starting with a comma (`,`) is evaluated as Gerbil Scheme instead of being parsed as shell syntax.

### Basic Examples

```bash
# Arithmetic
,(+ 1 2 3 4 5)              # => 15
,(* 6 7)                    # => 42
,(expt 2 10)                # => 1024

# String operations
,(string-append "hello" " " "world")     # => "hello world"
,(string-upcase "gerbil")               # => "GERBIL"

# List processing
,(map (lambda (x) (* x x)) '(1 2 3 4 5))    # => (1 4 9 16 25)
,(filter even? '(1 2 3 4 5 6))              # => (2 4 6)
```

### Accessing Shell Environment

Scheme expressions can access and modify the shell environment:

```bash
# Read environment variables
export MY_VAR="hello"
,(getenv "MY_VAR")          # => "hello"

# Set environment variables from Scheme
,(begin (setenv "NEW_VAR" "from scheme") (void))
echo $NEW_VAR               # prints: from scheme

# Get current directory
pwd                         # /home/user/project
,(current-directory)        # => "/home/user/project/"
```

### File System Operations

```bash
# Check file existence
,(file-exists? "/etc/passwd")              # => #t
,(if (file-exists? "/tmp") "yes" "no")    # => "yes"

# List directory contents
,(directory-files "/tmp")   # => ("." ".." "file1" ...)
```

### Definitions and State

Definitions made in Scheme persist across commands:

```bash
,(define greeting "Hello, World!")
,greeting                                   # => "Hello, World!"

,(define (factorial n) (if (<= n 1) 1 (* n (factorial (- n 1)))))
,(factorial 5)                              # => 120
,(factorial 10)                             # => 3628800
```

### Mixing Shell and Scheme

You can freely mix shell commands and Scheme expressions:

```bash
echo "Current directory (shell):"
pwd
echo "Current directory (Scheme):"
,(current-directory)

# Use Scheme for complex calculations
result=$(echo "scale=2; 22/7" | bc)
echo "Pi (bc): $result"
,(/ 22.0 7.0)               # => 3.142857142857143
```

## Error Handling

Scheme errors are caught and displayed without terminating the shell:

```bash
,(/ 1 0)                    # Scheme error: Divide by zero
echo "Shell continues"      # Still works!

,(undefined-function)       # Scheme error: Unbound variable
ls                          # Shell commands still work
```

## Output Format

- Simple values (numbers, booleans, strings) are printed using `write`
- Lists and vectors are pretty-printed
- `#<void>` (returned by definitions and side-effect operations) produces no output
- Errors show the exception message and stack trace

## Where It Works

The comma meta-command works in:

✅ Interactive REPL
✅ Script files
✅ Piped input (`echo ",(+ 1 2)" | gsh`)
✅ Command strings (`gsh -c ",(+ 1 2)"`)

## Limitations

- **Multi-line expressions:** Each comma line must be a complete Scheme expression. Multi-line forms must be on a single line:

  ```bash
  # ✅ Works (single line)
  ,(begin (define x 1) (define y 2) (+ x y))

  # ❌ Doesn't work (multiple lines)
  ,(begin
      (define x 1)
      (define y 2))
  ```

- **No shell expansion:** Comma lines bypass the shell parser entirely. Shell variables are not expanded:

  ```bash
  export X=5
  ,(+ $X 1)     # ❌ Error: $X is literal text
  ,(+ 5 1)      # ✅ Works
  ```

- **Exit status:** Scheme expressions set `$?` to 0 on success, 1 on error (same as shell commands).

## Use Cases

### Quick Calculations
```bash
# Convert bytes to gigabytes
,(/ 4294967296 (expt 1024 3))   # => 4.0

# Date calculations
,(import :std/srfi/19)
,(date->string (current-date) "~Y-~m-~d")
```

### Testing File Paths
```bash
# Find readable files in a directory
,(filter file-exists? (directory-files "."))

# Check permissions
,(file-executable? "/usr/bin/bash")  # => #t
```

### JSON/Data Processing
```bash
,(import :std/text/json)
,(string->json-object "{\"name\":\"gerbil\",\"version\":\"0.18\"}")
# => #<json-object #1 name: "gerbil" version: "0.18">
```

### Quick Prototyping
```bash
# Test a regex
,(import :std/pregexp)
,(pregexp-match "^[0-9]+" "123abc")  # => ("123")

# Hash table operations
,(let ((h (make-hash-table))) (hash-put! h 'a 1) (hash-put! h 'b 2) h)
# => #<hash-table #1 a: 1 b: 2>
```

## Implementation Details

- Scheme code is evaluated using Gambit's `eval`
- Expressions run in the same runtime as the shell
- Standard library modules can be imported with `(import ...)`
- The full Gambit/Gerbil runtime is available

## See Also

- [Gerbil Documentation](https://cons.io/)
- [Gambit Scheme](http://gambitscheme.org/)
- [examples/scheme-eval-demo.sh](../examples/scheme-eval-demo.sh) - Full demo script
