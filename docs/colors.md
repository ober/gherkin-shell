# Terminal Color Variables

gsh provides 34 pre-defined shell variables containing ANSI terminal color escape sequences. These are set automatically at shell startup and are available in `~/.gshrc`, `PS1`, and any shell script.

## Usage

Wrap color variables in `\[...\]` inside prompt strings so the shell can correctly calculate the visible prompt width:

```bash
# Colored prompt: green user@host, blue directory
PS1='\[$_fg_norm_green\]\u@\h\[$_ansi_reset\]:\[$_fg_norm_blue\]\w\[$_ansi_reset\]\$ '

# Bold red errors, cyan info
alias err='echo "${_ansi_bold}${_fg_norm_red}ERROR:${_ansi_reset}"'
alias info='echo "${_fg_norm_cyan}INFO:${_ansi_reset}"'
```

The `\[...\]` brackets are only needed in `PS1`/`PS2`/`PS4` prompt strings. In regular `echo` or `printf` commands, use the variables directly.

## Available Variables

### Attributes

| Variable | ANSI Code | Effect |
|---|---|---|
| `_ansi_reset` | `ESC[0m` | Reset all attributes and colors |
| `_ansi_bold` | `ESC[1m` | Bold / bright text |

### Foreground Colors (Normal)

| Variable | ANSI Code | Color |
|---|---|---|
| `_fg_norm_black_` | `ESC[30m` | Black |
| `_fg_norm_red` | `ESC[31m` | Red |
| `_fg_norm_green` | `ESC[32m` | Green |
| `_fg_norm_yellow` | `ESC[33m` | Yellow |
| `_fg_norm_blue` | `ESC[34m` | Blue |
| `_fg_norm_magenta` | `ESC[35m` | Magenta |
| `_fg_norm_cyan` | `ESC[36m` | Cyan |
| `_fg_norm_white` | `ESC[37m` | White |

### Foreground Colors (Bright)

| Variable | ANSI Code | Color |
|---|---|---|
| `_fg_bright_black` | `ESC[90m` | Bright Black (Gray) |
| `_fg_bright_red` | `ESC[91m` | Bright Red |
| `_fg_bright_green` | `ESC[92m` | Bright Green |
| `_fg_bright_yellow` | `ESC[93m` | Bright Yellow |
| `_fg_bright_blue` | `ESC[94m` | Bright Blue |
| `_fg_bright_magenta` | `ESC[95m` | Bright Magenta |
| `_fg_bright_cyan` | `ESC[96m` | Bright Cyan |
| `_fg_bright_white` | `ESC[97m` | Bright White |

### Background Colors (Normal)

| Variable | ANSI Code | Color |
|---|---|---|
| `_bg_norm_black_` | `ESC[40m` | Black |
| `_bg_norm_red` | `ESC[41m` | Red |
| `_bg_norm_green` | `ESC[42m` | Green |
| `_bg_norm_yellow` | `ESC[43m` | Yellow |
| `_bg_norm_blue` | `ESC[44m` | Blue |
| `_bg_norm_magenta` | `ESC[45m` | Magenta |
| `_bg_norm_cyan` | `ESC[46m` | Cyan |
| `_bg_norm_white` | `ESC[47m` | White |

### Background Colors (Bright)

| Variable | ANSI Code | Color |
|---|---|---|
| `_bg_bright_black` | `ESC[100m` | Bright Black (Gray) |
| `_bg_bright_red` | `ESC[101m` | Bright Red |
| `_bg_bright_green` | `ESC[102m` | Bright Green |
| `_bg_bright_yellow` | `ESC[103m` | Bright Yellow |
| `_bg_bright_blue` | `ESC[104m` | Bright Blue |
| `_bg_bright_magenta` | `ESC[105m` | Bright Magenta |
| `_bg_bright_cyan` | `ESC[106m` | Bright Cyan |
| `_bg_bright_white` | `ESC[107m` | Bright White |

## Examples

### Colored Prompt with Git Branch

```bash
# ~/.gshrc
git_branch() {
  git branch 2>/dev/null | grep '^\*' | sed 's/^\* //'
}

PS1='\[$_fg_norm_green\]\u@\h\[$_ansi_reset\]:\[$_fg_norm_blue\]\w\[$_ansi_reset\] \[$_fg_norm_yellow\]$(git_branch)\[$_ansi_reset\]\$ '
```

### Minimal Prompt

```bash
PS1='\[$_fg_bright_cyan\]\w\[$_ansi_reset\] \$ '
```

### Bold and Background Colors

```bash
# Red background alert
echo "${_bg_norm_red}${_fg_norm_white}${_ansi_bold} ALERT ${_ansi_reset} Something happened"

# Combine bold with foreground
echo "${_ansi_bold}${_fg_norm_blue}Title${_ansi_reset}"
```

### Status-Aware Prompt

```bash
# Show red $ when last command failed, green otherwise
prompt_symbol() {
  if [ $? -eq 0 ]; then
    printf '%s' "${_fg_norm_green}\$${_ansi_reset}"
  else
    printf '%s' "${_fg_norm_red}\$${_ansi_reset}"
  fi
}

PS1='\w $(prompt_symbol) '
```

## Notes

- The variables contain raw ANSI escape bytes, not literal `\e[...` text. They work directly with `echo`, `printf`, and prompt strings.
- The trailing underscore on `_fg_norm_black_` and `_bg_norm_black_` is intentional (black text is often invisible on dark terminals).
- These variables are not exported to child processes. They are internal to the gsh session.
- The ANSI codes are hardcoded (not derived from `tput` or terminfo). They work on all modern terminal emulators.
