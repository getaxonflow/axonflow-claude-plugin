#!/usr/bin/env bash
# Guard: no `producer | grep -q` in shell that runs under `set -o pipefail`.
#
# Why. `grep -q` exits at its first match. The producer on the left of the
# pipe may still be writing; it then takes SIGPIPE and exits non-zero, and
# under pipefail the pipeline's status is that non-zero, so a MATCH reads as a
# MISS. How often depends on output size and timing, so the assertion passes
# locally and fails on a busier machine. `grep -m N`, `grep -l` and `grep -L`
# stop early the same way. The safe forms: a here-string
# (`grep -q PATTERN <<<"$TEXT"`), a file argument, or a grep that reads to the
# end (`grep PATTERN >/dev/null`, `grep -c`).
#
# What is in scope. A shell file is under pipefail when it sets it (a `set`
# command whose options include `-o pipefail` in any arrangement: `set -o
# pipefail`, `set -euo pipefail`, `set -e -o pipefail`, `set -o errexit -o
# pipefail`; `shopt -so pipefail`; or pipefail among the interpreter line's
# options, `#!/usr/bin/env -S bash -eo pipefail`), when it lives under a `lib/` directory
# (files there are sourced into suites), or when a file under pipefail sources
# it (a sourced file inherits the caller's options), followed to a fixed point.
# A sourced path is resolved relative to the sourcing file; a leading variable
# (`"$PLUGIN_DIR/scripts/x.sh"`) is tried as that file's directory and each
# directory above it, and so is a leading command substitution such as
# `"$(dirname "$0")/x.sh"`; a variable holding the whole path is resolved when
# the file assigns it exactly one literal path.
#
# What is reported. Each logical line (backslash and trailing-pipe
# continuations joined, comments and here-document bodies skipped, quotes
# respected, ANSI-C `$'...'` strings included; a here-string and a shift
# inside arithmetic are not here-documents, and a body ends only at a line
# that is exactly its word, tabs stripped for `<<-`) with a `|` or `|&` pipe into grep, egrep or fgrep (as the
# shell sees the word: `\grep` and `"grep"` are grep), run directly, in a brace
# group, after if/elif/while/until, or through variable assignments, sudo, env, timeout, command, nice,
# stdbuf, exec or time, that carries an early-exit option: -q, -m, -l or -L
# (alone or in a short-option cluster, before an option that takes an
# argument: `-qm1` is reported, `-eq` is the pattern "q"), or --quiet,
# --silent, --max-count, --files-with-matches, --files-without-match, or an
# abbreviation GNU grep reads as one of them. An
# option's argument and anything after `--` are not options. The report names
# the file and the line the logical line starts on. A pipe inside a quoted
# string (`bash -c '... | grep -q x'`, `ssh host "... | grep -q x"`) runs in
# another shell and is not read; a pipe inside a command substitution, quoted
# or not (`"$(a | grep -q x)"`, backticks), runs in this shell's options and
# is. A newline inside a command substitution ends a command, so each line
# there is reported at its own line.
#
# Usage:
#   tests/no-grep-q-under-pipefail.sh                 scan this repository
#   tests/no-grep-q-under-pipefail.sh --scan <dir>    print findings for <dir>
#                                                     (path:line), exit 0
#   tests/no-grep-q-under-pipefail.sh --self-test     the fixtures under
#                                                     tests/fixtures/no-grep-q-under-pipefail
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/no-grep-q-under-pipefail"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required by this guard" >&2
  exit 1
fi

# scan <root> [<excluded dir> ...]: prints "relative/path:line" per finding.
scan() {
  python3 - "$@" <<'PY'
import os, re, shlex, sys

root = os.path.abspath(sys.argv[1])
excluded = [os.path.abspath(p) for p in sys.argv[2:]]

def shell_files(root):
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in ('.git', 'node_modules')]
        if any(os.path.abspath(d) == e or os.path.abspath(d).startswith(e + os.sep) for e in excluded):
            dirs[:] = []
            continue
        for f in files:
            p = os.path.join(d, f)
            if f.endswith('.sh'):
                yield p
                continue
            try:
                with open(p, 'rb') as fh:
                    head = fh.readline(200)
            except OSError:
                continue
            if re.match(rb'#!\s*(/usr/bin/env\s+)?(/\S*/)?(ba)?sh\b', head):
                yield p

# A here-document operator: `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`. Not a
# here-string (`<<<`), and not a shift inside arithmetic (`$((1 << N))`,
# `(( x <<= 2 ))`), which is blanked before this is matched.
HEREDOC = re.compile(r'(?<!<)<<(?!<)(-?)\s*\\?([\'"]?)([A-Za-z_][A-Za-z0-9_.-]*)\2')
ARITH = re.compile(r'\$?\(\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)\)')
HIDDEN = '\x01'

def lex_line(raw, stack):
    """One physical line. `stack` holds the open quotes and command
    substitutions carried from the lines before: "'", '"', '`', or a
    ['$(', depth] frame. Returns (code, blank, heredoc words): code is the line
    without its comment; blank is the same length, with quoted text replaced
    by a placeholder, so a | in a quoted string is not a pipe. A command
    substitution inside double quotes ("$(a | b)") is code again."""
    code, blank = [], []
    j, escaped = 0, False
    while j < len(raw):
        c = raw[j]
        top = stack[-1] if stack else None
        ctx = top[0] if isinstance(top, list) else top
        if ctx == "$'":
            # ANSI-C quoting: a backslash escapes the next character, \' included.
            code.append(c)
            if escaped:
                blank.append(HIDDEN); escaped = False
            elif c == '\\':
                blank.append(HIDDEN); escaped = True
            elif c == "'":
                stack.pop(); blank.append(c)
            else:
                blank.append(HIDDEN)
        elif ctx == "'":
            code.append(c)
            if c == "'":
                stack.pop(); blank.append(c)
            else:
                blank.append(HIDDEN)
        elif ctx == '"':
            if escaped:
                code.append(c); blank.append(HIDDEN); escaped = False
            elif c == '\\':
                code.append(c); blank.append(HIDDEN); escaped = True
            elif c == '"':
                stack.pop(); code.append(c); blank.append(c)
            elif c == '$' and raw[j + 1:j + 2] == '(' and raw[j + 2:j + 3] != '(':
                stack.append(['$(', 0]); code.append('$('); blank.append('$('); j += 2
                continue
            elif c == '`':
                stack.append('`'); code.append(c); blank.append(c)
            else:
                code.append(c); blank.append(HIDDEN)
        else:
            if escaped:
                code.append(c); blank.append(c); escaped = False
            elif c == '\\':
                code.append(c); blank.append(c); escaped = True
            elif c == '$' and raw[j + 1:j + 2] == "'":
                stack.append("$'"); code.append("$'"); blank.append("$'"); j += 2
                continue
            elif c in ("'", '"'):
                stack.append(c); code.append(c); blank.append(c)
            elif c == '#' and (j == 0 or raw[j - 1] in ' \t;|&()'):
                break
            elif c == '$' and raw[j + 1:j + 2] == '(' and raw[j + 2:j + 3] != '(':
                stack.append(['$(', 0]); code.append('$('); blank.append('$('); j += 2
                continue
            elif ctx == '$(' and c in '()':
                if c == '(':
                    top[1] += 1
                elif top[1] == 0:
                    stack.pop()
                else:
                    top[1] -= 1
                code.append(c); blank.append(c)
            elif ctx == '`' and c == '`':
                stack.pop(); code.append(c); blank.append(c)
            else:
                code.append(c); blank.append(c)
        j += 1
    code, blank = ''.join(code), ''.join(blank)
    words = []
    arith = ARITH.sub(lambda a: ' ' * len(a.group(0)), code)
    for m in HEREDOC.finditer(arith):
        if blank[m.start()] == '<':
            words.append((m.group(3), m.group(1) == '-'))
    return code, blank, words

def logical_lines(text):
    """Yield (start_line, code, blank) per logical line: comments and
    here-document bodies removed, quotes and command substitutions tracked
    across lines, backslash and trailing-pipe continuations joined."""
    lines = text.split('\n')
    stack = []
    i = 0
    code_buf, blank_buf, start = '', '', None
    while i < len(lines):
        lineno = i + 1
        code, blank, words = lex_line(lines[i], stack)
        i += 1
        if start is None:
            start = lineno
        # A here-document's body starts on the next physical line, whatever
        # construct the operator sits in.
        # The body ends at a line that is exactly the word (`<<-` also strips
        # leading tabs from it).
        for word, strip_tabs in words:
            while i < len(lines) and (lines[i].lstrip('\t') if strip_tabs else lines[i]) != word:
                i += 1
            i += 1
        code_buf += code
        blank_buf += blank
        # Inside a quoted string the newline is part of the string; inside a
        # command substitution it ends a command, as it does at the top.
        if stack and not isinstance(stack[-1], list) and stack[-1] != '`':
            code_buf += '\n'; blank_buf += '\n'
            continue
        stripped = code.rstrip()
        if stripped.endswith('\\') and not stripped.endswith('\\\\'):
            cut = len(code_buf.rstrip()) - 1
            code_buf = code_buf[:cut] + ' '
            blank_buf = blank_buf[:cut] + ' '
            continue
        if re.search(r'(^|[^|])\|&?\s*$', blank.rstrip()) and not blank.rstrip().endswith('||'):
            code_buf += ' '; blank_buf += ' '
            continue
        yield start, code_buf, blank_buf
        code_buf, blank_buf, start = '', '', None
    if code_buf.strip():
        yield start, code_buf, blank_buf

SEP = re.compile(r'\|\||&&|;|\)|\n|\bthen\b|\bdo\b')
PIPE = re.compile(r'(?<!\|)\|&?(?!\|)')
ASSIGNMENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*=\S*')
GREP = re.compile(r'(?:\S*/)?[ef]?grep')
# grep's options that take an argument: in a short cluster the rest of the
# cluster is that argument, and a bare one takes the next word.
SHORT_WITH_ARG = set('ABCDdef')
LONG_WITH_ARG = {'--regexp', '--file', '--after-context', '--before-context', '--context',
                 '--devices', '--directories', '--label', '--binary-files', '--exclude',
                 '--include', '--exclude-dir', '--exclude-from', '--group-separator'}
# The options that make grep stop before the end of its input.
SHORT_EARLY = set('qmlL')
LONG_EARLY = ('--quiet', '--silent', '--max-count', '--files-with-matches', '--files-without-match')
# GNU grep's other long options: an abbreviation (GNU accepts any unambiguous
# prefix) is early only when it cannot also name one of these.
LONG_OTHER = ('--after-context', '--basic-regexp', '--before-context', '--binary', '--binary-files',
              '--byte-offset', '--color', '--colour', '--context', '--count', '--dereference-recursive',
              '--devices', '--directories', '--exclude', '--exclude-dir', '--exclude-from',
              '--extended-regexp', '--file', '--fixed-strings', '--help', '--ignore-case', '--include',
              '--initial-tab', '--invert-match', '--label', '--line-buffered', '--line-number',
              '--line-regexp', '--no-filename', '--no-ignore-case', '--no-messages', '--null',
              '--null-data', '--only-matching', '--perl-regexp', '--recursive', '--regexp', '--text',
              '--version', '--with-filename', '--word-regexp')

def long_option(name):
    """The option a (possibly abbreviated) long name means: 'early', 'other'
    (with whether it takes an argument), or None when it is ambiguous between
    the two kinds or names nothing."""
    if name in LONG_EARLY:
        return 'early'
    if name in LONG_OTHER or name in LONG_WITH_ARG:
        return 'other'
    early = [o for o in LONG_EARLY if o.startswith(name)] if len(name) >= 3 else []
    other = [o for o in LONG_OTHER + tuple(LONG_WITH_ARG) if o.startswith(name)] if len(name) >= 3 else []
    if early and not other:
        return 'early'
    if other and not early:
        return 'other'
    return None

def command_words(words):
    """Skip what runs grep without being grep: assignments, a brace or
    subshell opener, `!`, sudo, env, timeout (with its duration), command,
    nice, stdbuf, exec, time, each with its options. Returns the words from the
    command itself."""
    k = 0
    while k < len(words):
        w = words[k]
        if ASSIGNMENT.fullmatch(w) or w in ('{', '(', '!', 'if', 'elif', 'while', 'until'):
            k += 1
        elif w == 'sudo':
            k += 1
            while k < len(words) and words[k].startswith('-'):
                k += 2 if words[k] in ('-u', '-g', '-C', '-h', '-p', '-r', '-t', '-U', '-D') else 1
        elif w == 'env':
            k += 1
            while k < len(words) and (words[k].startswith('-') or ASSIGNMENT.fullmatch(words[k])):
                k += 2 if words[k] in ('-u', '--unset', '-C', '--chdir', '-S', '--split-string') else 1
        elif w == 'timeout':
            k += 1
            while k < len(words) and words[k].startswith('-'):
                k += 2 if words[k] in ('-s', '--signal', '-k', '--kill-after') else 1
            k += 1  # the duration
        elif w in ('command', 'exec', 'time', 'builtin'):
            k += 1
            while k < len(words) and words[k] in ('-p', '-a', '-c', '-l'):
                k += 1
        elif w == 'nice':
            k += 1
            while k < len(words) and words[k].startswith('-'):
                k += 2 if words[k] == '-n' else 1
        elif w == 'stdbuf':
            k += 1
            while k < len(words) and words[k].startswith('-'):
                k += 1
        else:
            break
    return words[k:]

def early_exit_grep(words):
    words = command_words(words)
    if not words or not GREP.fullmatch(words[0]):
        return False
    k = 1
    while k < len(words):
        w = words[k]
        if w == '--':
            return False
        if w.startswith('--'):
            name = w.split('=', 1)[0]
            kind = long_option(name)
            if kind == 'early':
                return True
            takes_arg = any(o.startswith(name) for o in LONG_WITH_ARG) and kind == 'other'
            k += 2 if (takes_arg and '=' not in w) else 1
            continue
        if re.fullmatch(r'-[A-Za-z0-9]+', w):
            takes_next = False
            for pos, c in enumerate(w[1:], start=1):
                if c in SHORT_EARLY:
                    return True
                if c in SHORT_WITH_ARG:
                    takes_next = pos == len(w) - 1
                    break
            k += 2 if takes_next else 1
            continue
        k += 1
    return False

def shell_words(code_segment, blank_segment):
    """The words the shell would see: quotes and backslashes removed
    (`"grep"` and `\\grep` are grep). Falls back to the blanked text's words
    when the segment does not split (an unbalanced quote across a boundary)."""
    try:
        return shlex.split(code_segment, comments=False, posix=True)
    except ValueError:
        return blank_segment.split()

def early_exit_reader(code, blank):
    for m in PIPE.finditer(blank):
        start = m.end()
        rest = blank[start:]
        end = len(rest)
        for s in SEP.finditer(rest):
            end = s.start(); break
        nxt = PIPE.search(rest[:end])
        if nxt:
            end = nxt.start()
        if early_exit_grep(shell_words(code[start:start + end], rest[:end])):
            return True
    return False

SET_WORDS = re.compile(r'(?:^|[;&|({]|\bthen\b|\bdo\b|\belse\b)\s*(set|shopt)\b([^;&|)\n]*)')

SHEBANG_PIPEFAIL = re.compile(r'^#!.*\s-[A-Za-z]*o[A-Za-z]*\s+pipefail\b')

def sets_pipefail(text):
    # `#!/usr/bin/env -S bash -eo pipefail`: the interpreter's own options.
    if SHEBANG_PIPEFAIL.match(text.split('\n', 1)[0]):
        return True
    for _, _, blank in logical_lines(text):
        for m in SET_WORDS.finditer(blank):
            words = m.group(2).split()
            for k, w in enumerate(words[:-1]):
                if words[k + 1] != 'pipefail' or not re.fullmatch(r'-[A-Za-z]*o[A-Za-z]*', w):
                    continue
                if m.group(1) == 'set':
                    return True
                # shopt enables with -s, alongside -o: `shopt -so`, `shopt -s -o`
                if any(re.fullmatch(r'-[A-Za-z]*s[A-Za-z]*', x) for x in words):
                    return True
    return False

SOURCE = re.compile(r'(?:^|[;&|({]\s*|\bthen\s+|\bdo\s+|\belse\s+)(?:\.|source)\s+')

def shell_word_at(code, i):
    """The shell word starting at code[i], with its quotes and any command
    substitution inside it kept as written: `"$(dirname "$0")/x.sh"`."""
    out, quote, depth = [], None, 0
    while i < len(code):
        c = code[i]
        if quote:
            if c == quote and depth == 0:
                quote = None
            elif c == '$' and code[i + 1:i + 2] == '(':
                depth += 1; out.append('$('); i += 2; continue
            elif c == ')' and depth:
                depth -= 1
            out.append(c)
        else:
            if c in ' \t;&|' and depth == 0:
                break
            if c in '"\'' and depth == 0:
                quote = c
            elif c == '$' and code[i + 1:i + 2] == '(':
                depth += 1; out.append('$('); i += 2; continue
            elif c == ')' and depth:
                depth -= 1
            out.append(c)
        i += 1
    return ''.join(out)

def strip_leading_substitution(word):
    """`$(...)/rest` -> ('/rest' without quotes, True) for a substitution of
    any nesting; the word unquoted and False otherwise."""
    w = word.replace('"', '').replace("'", '') if not word.startswith(('"$(', '$(')) else word
    body = word[1:] if word.startswith('"') else word
    if body.startswith('$('):
        depth, j = 0, 0
        while j < len(body):
            if body[j:j + 2] == '$(' or body[j] == '(':
                depth += 1; j += 2 if body[j] == '$' else 1; continue
            if body[j] == ')':
                depth -= 1
                if depth == 0:
                    rest = body[j + 1:].replace('"', '').replace("'", '')
                    return rest, True
            j += 1
    return w, False
VAR_PREFIX = re.compile(r'^(?:\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*)/')

ASSIGNED_PATH = re.compile(r'^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=(["\']?)([^\s;"\']+)\2\s*$')

def sourced_paths(path, text, rels):
    here = os.path.dirname(path)
    found = []
    # `SCRIPT_PATH="${PLUGIN_DIR}/scripts/x.sh"` then `. "$SCRIPT_PATH"`: a
    # source through a variable assigned one path in this file is that path.
    assigned = {}
    for _, code, _ in logical_lines(text):
        a = ASSIGNED_PATH.match(code)
        if a:
            assigned.setdefault(a.group(1), set()).add(a.group(3))
    for _, code, _ in logical_lines(text):
        stripped = code.strip()
        for m in SOURCE.finditer(stripped):
            target, via_subst = strip_leading_substitution(shell_word_at(stripped, m.end()))
            if via_subst:
                if not target.startswith('/'):
                    continue
                target = '$SUBST' + target
            whole = re.fullmatch(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', target)
            if whole and len(assigned.get(whole.group(1), ())) == 1:
                target = next(iter(assigned[whole.group(1)]))
            had_var = bool(VAR_PREFIX.match(target))
            target = VAR_PREFIX.sub('', target)
            if '$' in target:
                continue
            cands = [os.path.join(here, target)]
            if had_var:
                # `$PLUGIN_DIR/scripts/lib/x.sh`: the variable names this file's
                # directory or one above it, up to the scanned root.
                d = here
                while True:
                    cands.append(os.path.join(d, target))
                    if d == root or len(d) <= len(root):
                        break
                    d = os.path.dirname(d)
            cands.append(os.path.join(here, os.path.basename(target)))
            hit = None
            for cand in cands:
                cand = os.path.normpath(cand)
                if os.path.isfile(cand):
                    hit = cand; break
            if hit is None and had_var:
                tail = os.path.normpath(target).lstrip('./')
                matches = [p for p, r in rels.items() if r == tail or r.endswith(os.sep + tail)]
                if len(matches) == 1:
                    hit = matches[0]
            if hit:
                found.append(hit)
    return found

files = {}
for p in shell_files(root):
    try:
        with open(p, encoding='utf-8', errors='replace') as fh:
            files[os.path.abspath(p)] = fh.read()
    except OSError:
        pass
rels = {p: os.path.relpath(p, root) for p in files}

in_scope = set()
for p, text in files.items():
    parts = rels[p].split(os.sep)
    if sets_pipefail(text) or 'lib' in parts[:-1]:
        in_scope.add(p)
changed = True
while changed:
    changed = False
    for p in list(in_scope):
        for t in sourced_paths(p, files[p], rels):
            if t in files and t not in in_scope:
                in_scope.add(t); changed = True

for p in sorted(in_scope):
    for line, code, blank in logical_lines(files[p]):
        if early_exit_reader(code, blank):
            print(f"{rels[p]}:{line}")
PY
}

# expected_findings <fixture dir>: the lines the fixtures mark, printed as
# "relative/path:line". A code line marked `# EXPECT` is expected; a comment
# line reading `# EXPECT-NEXT` marks the line after it (a line ending in a
# backslash cannot carry a comment).
expected_findings() {
  (cd "$1" && find . -name '*.sh' | sed 's|^\./||' | sort | while read -r f; do
    awk -v f="$f" '
      /^[[:space:]]*# EXPECT-NEXT[[:space:]]*$/ { next_marked = NR + 1; next }
      NR == next_marked { print f ":" NR; next }
      /^[[:space:]]*#/ { next }
      /# EXPECT/ { print f ":" NR }
    ' "$f"
  done | sort)
}

case "${1:-}" in
  --scan)
    scan "${2:?--scan needs a directory}"
    exit 0
    ;;
  --self-test)
    want=$(expected_findings "$FIXTURE_DIR")
    got=$(scan "$FIXTURE_DIR" | sort)
    if [ "$want" = "$got" ]; then
      echo "PASS: the guard reports exactly the $(printf '%s\n' "$want" | grep -c .) marked lines in its fixtures"
      exit 0
    fi
    echo "FAIL: the guard's findings differ from the fixtures' # EXPECT markers" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/  /' >&2
    exit 1
    ;;
  "")
    self=$("$0" --self-test 2>&1); rc=$?
    echo "$self"
    [ "$rc" -eq 0 ] || exit 1
    findings=$(scan "$REPO_DIR" "$FIXTURE_DIR")
    if [ -z "$findings" ]; then
      echo "PASS: no \`producer | grep -q\` under pipefail in this repository"
      exit 0
    fi
    echo "FAIL: \`producer | grep -q\` (or -m, -l, -L) under pipefail (a match can read as a miss). Use a here-string, a file, or a grep that reads to the end:" >&2
    printf '  %s\n' $findings >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [--scan <dir> | --self-test]" >&2
    exit 2
    ;;
esac
