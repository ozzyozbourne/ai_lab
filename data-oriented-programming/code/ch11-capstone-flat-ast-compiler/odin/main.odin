// Chapter 11 capstone: a compiler front end the Zig way.
// tokenizer -> #soa tokens (u8 tag + u32 start) -> Pratt parser -> #soa nodes {tag, main_token, lhs, rhs}
// plus one `extra: [dynamic]u32` -> post-order evaluator; a ^Node-per-node tree from the same tokens as
// the baseline; and the flat arrays written to a file and viewed in place.
// `odin run odin -o:speed -vet -strict-style -- [N tokens] [--quick]`
package main

// ---- harness ----
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

RUNS :: 7

// Odin has no black_box: a volatile store into a file-private global keeps results alive.
@(private = "file")
sink: u64

keep :: proc "contextless" (v: $T) where size_of(T) <= 8 {
	intrinsics.volatile_store((^T)(&sink), v)
}

// Runs f(ctx) once to warm up, then RUNS timed times. Returns the sorted timings.
bench_runs :: proc(f: proc(ctx: $C) -> u64, ctx: C) -> (t: [RUNS]time.Duration) {
	keep(f(ctx))
	for &d in t {
		t0 := time.tick_now()
		keep(f(ctx))
		d = time.tick_since(t0)
	}
	slice.sort(t[:])
	return
}

// Median of RUNS timed runs (after one warm-up run).
bench :: proc(f: proc(ctx: $C) -> u64, ctx: C) -> time.Duration {
	t := bench_runs(f, ctx)
	return t[RUNS / 2]
}

Args :: struct {
	n:     int,
	quick: bool,
}

// Positional integer N (default 1 << 20) and `--quick` (caps N at 1 << 12).
parse_args :: proc() -> (a: Args) {
	a.n = 1 << 20
	for arg in os.args[1:] {
		if arg == "--quick" {
			a.quick = true
		} else if v, ok := strconv.parse_int(arg); ok {
			a.n = v
		}
	}
	if a.quick {
		a.n = min(a.n, 1 << 12)
	}
	return
}

// Prints one machine-readable line for bench_all.sh:
// BENCH {"id":"chNN-x","label":"...","lang":"odin","n":N,"ns":median,"samples":[...]}
// `runs` must be sorted (as returned by bench_runs). Labels must not contain `"` or `\`.
emit_bench :: proc(id, label: string, n: int, runs: []time.Duration) {
	sb := strings.builder_make(context.temp_allocator)
	for r, i in runs {
		fmt.sbprintf(&sb, "%s%d", i == 0 ? "" : ",", i64(r))
	}
	fmt.printfln(
		`BENCH {{"id":"%s","label":"%s","lang":"odin","n":%d,"ns":%d,"samples":[%s]}}`,
		id,
		label,
		n,
		i64(runs[len(runs) / 2]),
		strings.to_string(sb),
	)
	free_all(context.temp_allocator)
}
// ---- harness ----

// Non-time results (bytes, throughput): "ns" is 0 and "value" carries the number.
emit_value :: proc(id, label: string, n: int, value: f64, unit: string) {
	fmt.printfln(`BENCH {{"id":"%s","label":"%s","lang":"odin","n":%d,"ns":0,"value":%.3f,"unit":"%s"}}`, id, label, n, value, unit)
}

// ======================= tokens: u8 tag + u32 start, in a #soa array =======================

Tok :: enum u8 {
	Eof, Invalid, Int, Ident, Kw_Fn, Kw_Let, Kw_If, Kw_Else, Kw_Return, L_Paren, R_Paren, L_Brace, R_Brace,
	Comma, Semicolon, Equal, Equal_Equal, Plus, Minus, Star, Slash, Percent, Less,
}

// No `end`, no line/column: both are recomputed from `start` when needed.
Token :: struct {
	tag:   Tok,
	start: u32,
}
#assert(size_of(Token) == 8) // as one struct: padded; #soa stores the 1 B and 4 B columns separately

is_ident :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

scan_ident :: proc(src: []u8, start: int) -> int {
	i := start
	for i < len(src) && is_ident(src[i]) {
		i += 1
	}
	return i
}

scan_digits :: proc(src: []u8, start: int) -> int {
	i := start
	for i < len(src) && src[i] >= '0' && src[i] <= '9' {
		i += 1
	}
	return i
}

tokenize :: proc(src: []u8) -> (t: #soa[dynamic]Token) {
	reserve(&t, len(src) / 4 + 1) // ~4 source bytes per token in this language
	i := 0
	for {
		for i < len(src) && (src[i] == ' ' || src[i] == '\n' || src[i] == '\t' || src[i] == '\r') {
			i += 1
		}
		if i + 1 < len(src) && src[i] == '/' && src[i + 1] == '/' {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			continue
		}
		start := u32(i)
		if i == len(src) {
			append(&t, Token{.Eof, start})
			return
		}
		c := src[i]
		tag: Tok
		switch c {
		case '0' ..= '9':
			i = scan_digits(src, i)
			tag = .Int
		case 'a' ..= 'z', 'A' ..= 'Z', '_':
			end := scan_ident(src, i)
			switch string(src[i:end]) {
			case "fn":     tag = .Kw_Fn
			case "let":    tag = .Kw_Let
			case "if":     tag = .Kw_If
			case "else":   tag = .Kw_Else
			case "return": tag = .Kw_Return
			case:          tag = .Ident
			}
			i = end
		case:
			if c == '=' && i + 1 < len(src) && src[i + 1] == '=' {
				i += 2
				tag = .Equal_Equal
				break
			}
			i += 1
			switch c {
			case '(': tag = .L_Paren
			case ')': tag = .R_Paren
			case '{': tag = .L_Brace
			case '}': tag = .R_Brace
			case ',': tag = .Comma
			case ';': tag = .Semicolon
			case '=': tag = .Equal
			case '+': tag = .Plus
			case '-': tag = .Minus
			case '*': tag = .Star
			case '/': tag = .Slash
			case '%': tag = .Percent
			case '<': tag = .Less
			case:     tag = .Invalid
			}
		}
		append(&t, Token{tag, start})
	}
}

// The token's text, recomputed from its tag and start ("calculate instead of store").
token_text :: proc(src: []u8, tag: Tok, start: u32) -> []u8 {
	s := int(start)
	end: int
	#partial switch tag {
	case .Int:                                               end = scan_digits(src, s)
	case .Ident, .Kw_Fn, .Kw_Let, .Kw_If, .Kw_Else, .Kw_Return: end = scan_ident(src, s)
	case .Equal_Equal:                                       end = s + 2
	case .Eof:                                               end = s
	case:                                                    end = s + 1
	}
	return src[s:end]
}

// ======================= string interning =======================

// All identifier bytes in one buffer; symbol `s` is `bytes[starts[s]:starts[s + 1]]`.
Strings :: struct {
	bytes:  []u8,
	starts: []u32,
}

strings_get :: proc(s: Strings, sym: u32) -> string {
	return string(s.bytes[s.starts[sym]:s.starts[sym + 1]])
}

strings_len :: proc(s: Strings) -> int {
	return len(s.starts) - 1
}

strings_find :: proc(s: Strings, name: string) -> (u32, bool) {
	for i in 0 ..< strings_len(s) {
		if strings_get(s, u32(i)) == name {
			return u32(i), true
		}
	}
	return max(u32), false
}

fnv1a :: proc(s: []u8) -> u32 {
	h: u32 = 0x811C9DC5
	for b in s {
		h = (h ~ u32(b)) * 0x01000193
	}
	return h
}

// Open addressing over u32 slots (symbol + 1, 0 = empty), FNV-1a, linear probing, load <= 1/2.
Interner :: struct {
	bytes:  [dynamic]u8,
	starts: [dynamic]u32,
	table:  []u32,
}

interner_make :: proc() -> (in_: Interner) {
	append(&in_.starts, 0)
	in_.table = make([]u32, 1024)
	return
}

interner_strings :: proc(in_: ^Interner) -> Strings {
	return {in_.bytes[:], in_.starts[:]}
}

interner_destroy :: proc(in_: ^Interner) {
	delete(in_.bytes)
	delete(in_.starts)
	delete(in_.table)
}

intern :: proc(in_: ^Interner, s: []u8) -> u32 {
	mask := u32(len(in_.table) - 1)
	h := fnv1a(s) & mask
	for in_.table[h] != 0 {
		if strings_get(interner_strings(in_), in_.table[h] - 1) == string(s) {
			return in_.table[h] - 1
		}
		h = (h + 1) & mask
	}
	sym := u32(strings_len(interner_strings(in_)))
	append(&in_.bytes, ..s)
	append(&in_.starts, u32(len(in_.bytes)))
	in_.table[h] = sym + 1
	if 2 * strings_len(interner_strings(in_)) > len(in_.table) {
		table := make([]u32, 2 * len(in_.table))
		m := u32(len(table) - 1)
		for k in 0 ..< strings_len(interner_strings(in_)) {
			g := fnv1a(transmute([]u8)strings_get(interner_strings(in_), u32(k))) & m
			for table[g] != 0 {
				g = (g + 1) & m
			}
			table[g] = u32(k + 1)
		}
		delete(in_.table)
		in_.table = table
	}
	return sym
}

// ======================= flat AST: 13 bytes per node + extra =======================

Tag :: enum u8 {
	Root,        // lhs..rhs = extra range of fn_decl nodes
	Fn_Decl,     // main_token = `fn`; lhs = extra index of {name_sym, n_params, param_sym...}; rhs = body
	Block_Two,   // lhs, rhs = first and second statement (0 = none)
	Block,       // lhs..rhs = extra range of statements (3 or more)
	Let_Decl,    // lhs = name symbol; rhs = initializer
	Return_Stmt, // lhs = value
	If_Simple,   // lhs = condition; rhs = then-block
	If_Else,     // lhs = condition; rhs = extra index of {then, else}
	Int_Literal, // lhs = value
	Identifier,  // lhs = symbol
	Negate,      // lhs = operand
	Add, Sub, Mul, Div, Mod, Less_Than, Equal_Equal, // lhs op rhs
	Call_One,    // main_token = `(`; lhs = callee identifier; rhs = the argument (0 = none)
	Call,        // lhs = callee identifier; rhs = extra index of {args_start, args_end}
}

Node :: struct {
	tag:        Tag,
	main_token: u32,
	lhs:        u32,
	rhs:        u32,
}
#assert(size_of(Node) == 16) // as one struct: padded
#assert(size_of(Tag) + 3 * size_of(u32) == 13) // as #soa columns: not padded

Ast :: struct {
	tokens:   #soa[dynamic]Token,
	nodes:    #soa[dynamic]Node,
	extra:    [dynamic]u32,
	strings:  Strings,
	main_sym: u32, // max(u32) if there is no `main`
}

ast_destroy :: proc(a: ^Ast) {
	delete(a.tokens)
	delete(a.nodes)
	delete(a.extra)
	delete(a.strings.bytes)
	delete(a.strings.starts)
}

// What the evaluator needs: plain column slices. They can come from a parsed Ast or from a file.
Flat :: struct {
	tag:       []Tag,
	lhs:       []u32,
	rhs:       []u32,
	extra:     []u32,
	n_symbols: int,
	main_sym:  u32,
}

ast_flat :: proc(a: ^Ast) -> Flat {
	n := len(a.nodes)
	return {a.nodes.tag[:n], a.nodes.lhs[:n], a.nodes.rhs[:n], a.extra[:], strings_len(a.strings), a.main_sym}
}

Parse_Error :: struct {
	token:    u32,
	expected: string,
}
Error :: union {
	Parse_Error,
}

Bin_Op :: struct {
	prec: u8,
	tag:  Tag,
}

binary_op :: proc(t: Tok) -> (Bin_Op, bool) {
	#partial switch t {
	case .Equal_Equal: return {1, .Equal_Equal}, true
	case .Less:        return {2, .Less_Than}, true
	case .Plus:        return {3, .Add}, true
	case .Minus:       return {3, .Sub}, true
	case .Star:        return {4, .Mul}, true
	case .Slash:       return {4, .Div}, true
	case .Percent:     return {4, .Mod}, true
	}
	return {}, false
}

Parser :: struct {
	src:      []u8,
	tags:     []Tok,
	starts:   []u32,
	i:        u32,
	nodes:    #soa[dynamic]Node,
	extra:    [dynamic]u32,
	scratch:  [dynamic]u32,
	interner: Interner,
}

peek :: proc(p: ^Parser) -> Tok {
	return p.tags[p.i]
}

next :: proc(p: ^Parser) -> u32 {
	p.i += 1
	return p.i - 1
}

expect :: proc(p: ^Parser, t: Tok, expected: string) -> (u32, Error) {
	if peek(p) == t {
		return next(p), nil
	}
	return 0, Parse_Error{p.i, expected}
}

intern_token :: proc(p: ^Parser, tok: u32) -> u32 {
	return intern(&p.interner, token_text(p.src, .Ident, p.starts[tok]))
}

add :: proc(p: ^Parser, tag: Tag, main_token, lhs, rhs: u32) -> u32 {
	append(&p.nodes, Node{tag, main_token, lhs, rhs})
	return u32(len(p.nodes) - 1)
}

// Moves scratch[top:] into `extra` and returns the range: lists are built in one shared
// scratch stack, then copied once into their final, contiguous place.
list_to_extra :: proc(p: ^Parser, top: int) -> (start, end: u32) {
	start = u32(len(p.extra))
	append(&p.extra, ..p.scratch[top:])
	resize(&p.scratch, top)
	return start, u32(len(p.extra))
}

parse_root :: proc(p: ^Parser) -> (err: Error) {
	add(p, .Root, 0, 0, 0) // node 0, so index 0 can mean "none" everywhere else
	top := len(p.scratch)
	for peek(p) != .Eof {
		f := parse_fn(p) or_return
		append(&p.scratch, f)
	}
	p.nodes.lhs[0], p.nodes.rhs[0] = list_to_extra(p, top)
	return
}

parse_fn :: proc(p: ^Parser) -> (n: u32, err: Error) {
	fn_tok := expect(p, .Kw_Fn, "`fn`") or_return
	name := intern_token(p, expect(p, .Ident, "function name") or_return)
	expect(p, .L_Paren, "`(`") or_return
	top := len(p.scratch)
	if peek(p) != .R_Paren {
		for {
			param := expect(p, .Ident, "parameter name") or_return
			append(&p.scratch, intern_token(p, param))
			if peek(p) != .Comma {
				break
			}
			next(p)
		}
	}
	expect(p, .R_Paren, "`)`") or_return
	proto := u32(len(p.extra))
	append(&p.extra, name, u32(len(p.scratch) - top))
	list_to_extra(p, top)
	body := parse_block(p) or_return
	return add(p, .Fn_Decl, fn_tok, proto, body), nil
}

parse_block :: proc(p: ^Parser) -> (n: u32, err: Error) {
	lbrace := expect(p, .L_Brace, "`{`") or_return
	top := len(p.scratch)
	for peek(p) != .R_Brace {
		s := parse_stmt(p) or_return
		append(&p.scratch, s)
	}
	next(p)
	count := len(p.scratch) - top
	if count <= 2 {
		a := count > 0 ? p.scratch[top] : 0
		b := count > 1 ? p.scratch[top + 1] : 0
		resize(&p.scratch, top)
		return add(p, .Block_Two, lbrace, a, b), nil
	}
	s, e := list_to_extra(p, top)
	return add(p, .Block, lbrace, s, e), nil
}

parse_stmt :: proc(p: ^Parser) -> (n: u32, err: Error) {
	#partial switch peek(p) {
	case .Kw_Let:
		let_tok := next(p)
		sym := intern_token(p, expect(p, .Ident, "variable name") or_return)
		expect(p, .Equal, "`=`") or_return
		init := parse_expr(p, 0) or_return
		expect(p, .Semicolon, "`;`") or_return
		return add(p, .Let_Decl, let_tok, sym, init), nil
	case .Kw_Return:
		ret := next(p)
		value := parse_expr(p, 0) or_return
		expect(p, .Semicolon, "`;`") or_return
		return add(p, .Return_Stmt, ret, value, 0), nil
	case .Kw_If:
		return parse_if(p)
	case .Eof:
		return 0, Parse_Error{p.i, "`}`"}
	}
	e := parse_expr(p, 0) or_return
	expect(p, .Semicolon, "`;`") or_return
	return e, nil
}

parse_if :: proc(p: ^Parser) -> (n: u32, err: Error) {
	if_tok := next(p)
	cond := parse_expr(p, 0) or_return
	then := parse_block(p) or_return
	if peek(p) != .Kw_Else {
		return add(p, .If_Simple, if_tok, cond, then), nil
	}
	next(p)
	els: u32
	if peek(p) == .Kw_If {
		els = parse_if(p) or_return
	} else {
		els = parse_block(p) or_return
	}
	x := u32(len(p.extra))
	append(&p.extra, then, els)
	return add(p, .If_Else, if_tok, cond, x), nil
}

// Pratt loop: operators that bind tighter than `min_prec` extend the left operand.
parse_expr :: proc(p: ^Parser, min_prec: u8) -> (lhs: u32, err: Error) {
	lhs = parse_prefix(p) or_return
	for {
		op, ok := binary_op(peek(p))
		if !ok || op.prec <= min_prec {
			break
		}
		tok := next(p)
		rhs := parse_expr(p, op.prec) or_return
		lhs = add(p, op.tag, tok, lhs, rhs)
	}
	return
}

parse_prefix :: proc(p: ^Parser) -> (n: u32, err: Error) {
	#partial switch peek(p) {
	case .Int:
		t := next(p)
		v, ok := strconv.parse_u64_of_base(string(token_text(p.src, .Int, p.starts[t])), 10)
		if !ok || v > u64(max(u32)) {
			return 0, Parse_Error{t, "integer below 2^32"}
		}
		return add(p, .Int_Literal, t, u32(v), 0), nil
	case .Ident:
		t := next(p)
		id := add(p, .Identifier, t, intern_token(p, t), 0)
		if peek(p) == .L_Paren {
			return parse_call(p, id)
		}
		return id, nil
	case .L_Paren:
		next(p)
		e := parse_expr(p, 0) or_return
		expect(p, .R_Paren, "`)`") or_return
		return e, nil // no node for parentheses: the tree shape already says it
	case .Minus:
		t := next(p)
		operand := parse_prefix(p) or_return
		return add(p, .Negate, t, operand, 0), nil
	}
	return 0, Parse_Error{p.i, "expression"}
}

// Two encodings of one construct: `f()` and `f(x)` fit in the node; `f(x, y, ...)` spills to extra.
parse_call :: proc(p: ^Parser, callee: u32) -> (n: u32, err: Error) {
	lparen := next(p)
	top := len(p.scratch)
	if peek(p) != .R_Paren {
		for {
			a := parse_expr(p, 0) or_return
			append(&p.scratch, a)
			if peek(p) != .Comma {
				break
			}
			next(p)
		}
	}
	expect(p, .R_Paren, "`)`") or_return
	if len(p.scratch) - top <= 1 {
		arg := len(p.scratch) > top ? p.scratch[top] : 0
		resize(&p.scratch, top)
		return add(p, .Call_One, lparen, callee, arg), nil
	}
	s, e := list_to_extra(p, top)
	rng := u32(len(p.extra))
	append(&p.extra, s, e)
	return add(p, .Call, lparen, callee, rng), nil
}

// Takes ownership of the tokens: the AST owns them, as std.zig.Ast does.
parse :: proc(src: []u8, tokens: #soa[dynamic]Token) -> (ast: Ast, err: Error) {
	n := len(tokens)
	p := Parser{src = src, tags = tokens.tag[:n], starts = tokens.start[:n], interner = interner_make()}
	defer delete(p.scratch)
	reserve(&p.nodes, n * 2 / 3 + 1) // about 0.63 nodes per token for this language
	if e := parse_root(&p); e != nil {
		delete(p.nodes)
		delete(p.extra)
		interner_destroy(&p.interner)
		delete(tokens)
		return {}, e
	}
	delete(p.interner.table)
	strs := Strings{p.interner.bytes[:], p.interner.starts[:]}
	main_sym, _ := strings_find(strs, "main")
	return Ast{tokens, p.nodes, p.extra, strs, main_sym}, nil
}

// ======================= evaluator over the flat nodes =======================

// Integer semantics shared by both evaluators: wrapping i64 (Odin integers wrap); x / 0 = 0 and
// x % 0 = 0. min(i64) / -1 traps on x86, so dividing by -1 is spelled as a negation.
apply :: proc(op: Tag, a, b: i64) -> i64 {
	#partial switch op {
	case .Add:         return a + b
	case .Sub:         return a - b
	case .Mul:         return a * b
	case .Div:         return b == 0 ? 0 : b == -1 ? -a : a / b
	case .Mod:         return b == 0 || b == -1 ? 0 : a % b
	case .Less_Than:   return i64(a < b)
	case .Equal_Equal: return i64(a == b)
	}
	unreachable()
}

// Variables live on one stack of (symbol, value); a call sees only its own frame (vars[base:]).
Var :: struct {
	sym: u32,
	val: i64,
}
Env :: struct {
	vars: [dynamic]Var,
	base: int,
	args: [dynamic]i64,
}

env_destroy :: proc(e: ^Env) {
	delete(e.vars)
	delete(e.args)
}

lookup :: proc(e: ^Env, sym: u32) -> i64 {
	#reverse for v in e.vars[e.base:] {
		if v.sym == sym {
			return v.val
		}
	}
	return 0
}

Flat_Eval :: struct {
	flat: Flat,
	fns:     []u32, // symbol -> fn_decl node (0 = none)
	env:     Env,
}

flat_run :: proc(f: Flat) -> i64 {
	e := Flat_Eval{flat = f, fns = make([]u32, f.n_symbols)}
	defer delete(e.fns)
	defer env_destroy(&e.env)
	for fd in f.extra[f.lhs[0]:f.rhs[0]] {
		e.fns[f.extra[f.lhs[fd]]] = fd
	}
	return flat_call(&e, f.main_sym, 0)
}

flat_call :: proc(e: ^Flat_Eval, sym: u32, nargs: int) -> i64 {
	f := &e.flat
	first := len(e.env.args) - nargs
	fd := int(sym) < len(e.fns) ? e.fns[sym] : 0
	if fd == 0 {
		resize(&e.env.args, first)
		return 0
	}
	proto := f.lhs[fd]
	n_params := int(f.extra[proto + 1])
	saved, base := e.env.base, len(e.env.vars)
	for k in 0 ..< min(n_params, nargs) {
		append(&e.env.vars, Var{f.extra[int(proto) + 2 + k], e.env.args[first + k]})
	}
	resize(&e.env.args, first)
	e.env.base = base
	r, _ := flat_exec(e, f.rhs[fd])
	resize(&e.env.vars, base)
	e.env.base = saved
	return r
}

// Statements: returned == true means `return value` happened.
flat_exec :: proc(e: ^Flat_Eval, n: u32) -> (value: i64, returned: bool) {
	f := &e.flat
	l, r := f.lhs[n], f.rhs[n]
	#partial switch f.tag[n] {
	case .Block_Two:
		pair := [2]u32{l, r}
		return flat_exec_list(e, pair[:])
	case .Block:
		return flat_exec_list(e, f.extra[l:r])
	case .Let_Decl:
		v := flat_eval(e, r)
		append(&e.env.vars, Var{l, v})
		return 0, false
	case .Return_Stmt:
		return flat_eval(e, l), true
	case .If_Simple:
		if flat_eval(e, l) != 0 {
			return flat_exec(e, r)
		}
		return 0, false
	case .If_Else:
		return flat_exec(e, f.extra[r] if flat_eval(e, l) != 0 else f.extra[r + 1])
	}
	flat_eval(e, n)
	return 0, false
}

flat_exec_list :: proc(e: ^Flat_Eval, stmts: []u32) -> (value: i64, returned: bool) {
	mark := len(e.env.vars)
	defer resize(&e.env.vars, mark)
	for s in stmts {
		if s == 0 {
			break
		}
		value, returned = flat_exec(e, s)
		if returned {
			return
		}
	}
	return 0, false
}

// Expressions, children first (post-order).
flat_eval :: proc(e: ^Flat_Eval, n: u32) -> i64 {
	f := &e.flat
	l, r := f.lhs[n], f.rhs[n]
	#partial switch op := f.tag[n]; op {
	case .Int_Literal:
		return i64(l)
	case .Identifier:
		return lookup(&e.env, l)
	case .Negate:
		return -flat_eval(e, l)
	case .Call_One:
		if r != 0 {
			append(&e.env.args, flat_eval(e, r))
		}
		return flat_call(e, f.lhs[l], r != 0 ? 1 : 0)
	case .Call:
		s, end := f.extra[r], f.extra[r + 1]
		for a in f.extra[s:end] {
			append(&e.env.args, flat_eval(e, a))
		}
		return flat_call(e, f.lhs[l], int(end - s))
	case:
		a := flat_eval(e, l)
		b := flat_eval(e, r)
		return apply(op, a, b)
	}
}

// ======================= baseline: one heap allocation per node =======================

// `token` is each node's source location (the flat tree's `main_token`).
B_Int :: struct {
	token: u32,
	value: i64,
}
B_Ident :: struct {
	token, sym: u32,
}
B_Negate :: struct {
	token:   u32,
	operand: ^B_Node,
}
B_Binary :: struct {
	token:    u32,
	op:       Tag,
	lhs, rhs: ^B_Node,
}
B_Call :: struct {
	token, callee: u32,
	args:          []^B_Node,
}
B_Let :: struct {
	token, sym: u32,
	init:       ^B_Node,
}
B_Return :: struct {
	token: u32,
	value: ^B_Node,
}
B_If :: struct {
	token:           u32,
	cond, then, els: ^B_Node, // els may be nil
}
B_Block :: struct {
	token: u32,
	stmts: []^B_Node,
}
B_Fn :: struct {
	token, name: u32,
	params:      []u32,
	body:        ^B_Node,
}
B_Node :: union {
	B_Int, B_Ident, B_Negate, B_Binary, B_Call, B_Let, B_Return, B_If, B_Block, B_Fn,
}

Box_Program :: struct {
	fns:       []^B_Node,
	n_symbols: int,
	main_sym:  u32,
}

box_new :: proc(v: B_Node) -> ^B_Node {
	n := new(B_Node)
	n^ = v
	return n
}

box_free :: proc(n: ^B_Node) {
	if n == nil {
		return
	}
	switch x in n^ {
	case B_Int, B_Ident:
	case B_Negate: box_free(x.operand)
	case B_Binary:
		box_free(x.lhs)
		box_free(x.rhs)
	case B_Call:
		for a in x.args {
			box_free(a)
		}
		delete(x.args)
	case B_Let:    box_free(x.init)
	case B_Return: box_free(x.value)
	case B_If:
		box_free(x.cond)
		box_free(x.then)
		box_free(x.els)
	case B_Block:
		for s in x.stmts {
			box_free(s)
		}
		delete(x.stmts)
	case B_Fn:
		delete(x.params)
		box_free(x.body)
	}
	free(n)
}

box_program_destroy :: proc(p: ^Box_Program) {
	for f in p.fns {
		box_free(f)
	}
	delete(p.fns)
}

// Same grammar, same tokens, same interner; only the tree representation differs. It reuses Parser
// for peek/next/expect/intern_token and ignores its node arrays.
// (On a parse error the partial tree leaks; the generated input always parses.)
bx_fn :: proc(p: ^Parser) -> (n: ^B_Node, err: Error) {
	token := expect(p, .Kw_Fn, "`fn`") or_return
	name := intern_token(p, expect(p, .Ident, "function name") or_return)
	expect(p, .L_Paren, "`(`") or_return
	params: [dynamic]u32
	if peek(p) != .R_Paren {
		for {
			param := expect(p, .Ident, "parameter name") or_return
			append(&params, intern_token(p, param))
			if peek(p) != .Comma {
				break
			}
			next(p)
		}
	}
	expect(p, .R_Paren, "`)`") or_return
	shrink(&params)
	body := bx_block(p) or_return
	return box_new(B_Fn{token, name, params[:], body}), nil
}

bx_block :: proc(p: ^Parser) -> (n: ^B_Node, err: Error) {
	token := expect(p, .L_Brace, "`{`") or_return
	stmts: [dynamic]^B_Node
	for peek(p) != .R_Brace {
		s := bx_stmt(p) or_return
		append(&stmts, s)
	}
	next(p)
	shrink(&stmts)
	return box_new(B_Block{token, stmts[:]}), nil
}

bx_stmt :: proc(p: ^Parser) -> (n: ^B_Node, err: Error) {
	#partial switch peek(p) {
	case .Kw_Let:
		token := next(p)
		sym := intern_token(p, expect(p, .Ident, "variable name") or_return)
		expect(p, .Equal, "`=`") or_return
		init := bx_expr(p, 0) or_return
		expect(p, .Semicolon, "`;`") or_return
		return box_new(B_Let{token, sym, init}), nil
	case .Kw_Return:
		token := next(p)
		value := bx_expr(p, 0) or_return
		expect(p, .Semicolon, "`;`") or_return
		return box_new(B_Return{token, value}), nil
	case .Kw_If:
		return bx_if(p)
	case .Eof:
		return nil, Parse_Error{p.i, "`}`"}
	}
	e := bx_expr(p, 0) or_return
	expect(p, .Semicolon, "`;`") or_return
	return e, nil
}

bx_if :: proc(p: ^Parser) -> (n: ^B_Node, err: Error) {
	token := next(p)
	cond := bx_expr(p, 0) or_return
	then := bx_block(p) or_return
	els: ^B_Node
	if peek(p) == .Kw_Else {
		next(p)
		if peek(p) == .Kw_If {
			els = bx_if(p) or_return
		} else {
			els = bx_block(p) or_return
		}
	}
	return box_new(B_If{token, cond, then, els}), nil
}

bx_expr :: proc(p: ^Parser, min_prec: u8) -> (lhs: ^B_Node, err: Error) {
	lhs = bx_prefix(p) or_return
	for {
		op, ok := binary_op(peek(p))
		if !ok || op.prec <= min_prec {
			break
		}
		token := next(p)
		rhs := bx_expr(p, op.prec) or_return
		lhs = box_new(B_Binary{token, op.tag, lhs, rhs})
	}
	return
}

bx_prefix :: proc(p: ^Parser) -> (n: ^B_Node, err: Error) {
	#partial switch peek(p) {
	case .Int:
		token := next(p)
		v, ok := strconv.parse_u64_of_base(string(token_text(p.src, .Int, p.starts[token])), 10)
		if !ok || v > u64(max(u32)) {
			return nil, Parse_Error{token, "integer below 2^32"}
		}
		return box_new(B_Int{token, i64(v)}), nil
	case .Ident:
		token := next(p)
		sym := intern_token(p, token)
		if peek(p) != .L_Paren {
			return box_new(B_Ident{token, sym}), nil
		}
		lparen := next(p)
		args: [dynamic]^B_Node
		if peek(p) != .R_Paren {
			for {
				a := bx_expr(p, 0) or_return
				append(&args, a)
				if peek(p) != .Comma {
					break
				}
				next(p)
			}
		}
		expect(p, .R_Paren, "`)`") or_return
		shrink(&args)
		return box_new(B_Call{lparen, sym, args[:]}), nil
	case .L_Paren:
		next(p)
		e := bx_expr(p, 0) or_return
		expect(p, .R_Paren, "`)`") or_return
		return e, nil
	case .Minus:
		token := next(p)
		operand := bx_prefix(p) or_return
		return box_new(B_Negate{token, operand}), nil
	}
	return nil, Parse_Error{p.i, "expression"}
}

parse_boxed :: proc(src: []u8, tokens: ^#soa[dynamic]Token) -> (prog: Box_Program, err: Error) {
	n := len(tokens)
	p := Parser{src = src, tags = tokens.tag[:n], starts = tokens.start[:n], interner = interner_make()}
	defer interner_destroy(&p.interner)
	fns: [dynamic]^B_Node
	for peek(&p) != .Eof {
		f := bx_fn(&p) or_return
		append(&fns, f)
	}
	shrink(&fns)
	strs := interner_strings(&p.interner)
	main_sym, _ := strings_find(strs, "main")
	return Box_Program{fns[:], strings_len(strs), main_sym}, nil
}

// Counts nodes, allocations and requested heap bytes (allocator headers not included).
Box_Stats :: struct {
	nodes, allocs, bytes: int,
}

stats_list :: proc(s: ^Box_Stats, n, elem: int) {
	if n > 0 {
		s.allocs += 1
		s.bytes += n * elem
	}
}

stats_walk :: proc(s: ^Box_Stats, n: ^B_Node) {
	if n == nil {
		return
	}
	s.nodes += 1
	s.allocs += 1
	s.bytes += size_of(B_Node)
	switch x in n^ {
	case B_Int, B_Ident:
	case B_Call:
		stats_list(s, len(x.args), size_of(^B_Node))
		for a in x.args {
			stats_walk(s, a)
		}
	case B_Block:
		stats_list(s, len(x.stmts), size_of(^B_Node))
		for a in x.stmts {
			stats_walk(s, a)
		}
	case B_Fn:
		stats_list(s, len(x.params), size_of(u32))
		stats_walk(s, x.body)
	case B_Negate: stats_walk(s, x.operand)
	case B_Let:    stats_walk(s, x.init)
	case B_Return: stats_walk(s, x.value)
	case B_Binary:
		stats_walk(s, x.lhs)
		stats_walk(s, x.rhs)
	case B_If:
		stats_walk(s, x.cond)
		stats_walk(s, x.then)
		stats_walk(s, x.els)
	}
}

Box_Eval :: struct {
	fns: []^B_Node,
	env: Env,
}

box_run :: proc(p: ^Box_Program) -> i64 {
	e := Box_Eval{fns = make([]^B_Node, p.n_symbols)}
	defer delete(e.fns)
	defer env_destroy(&e.env)
	for f in p.fns {
		e.fns[f.(B_Fn).name] = f
	}
	return box_call(&e, p.main_sym, 0)
}

box_call :: proc(e: ^Box_Eval, sym: u32, nargs: int) -> i64 {
	first := len(e.env.args) - nargs
	f := int(sym) < len(e.fns) ? e.fns[sym] : nil
	if f == nil {
		resize(&e.env.args, first)
		return 0
	}
	fd := f.(B_Fn)
	saved, base := e.env.base, len(e.env.vars)
	for k in 0 ..< min(len(fd.params), nargs) {
		append(&e.env.vars, Var{fd.params[k], e.env.args[first + k]})
	}
	resize(&e.env.args, first)
	e.env.base = base
	r, _ := box_exec(e, fd.body)
	resize(&e.env.vars, base)
	e.env.base = saved
	return r
}

box_exec :: proc(e: ^Box_Eval, n: ^B_Node) -> (value: i64, returned: bool) {
	#partial switch x in n^ {
	case B_Block:
		mark := len(e.env.vars)
		defer resize(&e.env.vars, mark)
		for s in x.stmts {
			value, returned = box_exec(e, s)
			if returned {
				return
			}
		}
		return 0, false
	case B_Let:
		v := box_eval(e, x.init)
		append(&e.env.vars, Var{x.sym, v})
		return 0, false
	case B_Return:
		return box_eval(e, x.value), true
	case B_If:
		if box_eval(e, x.cond) != 0 {
			return box_exec(e, x.then)
		}
		if x.els != nil {
			return box_exec(e, x.els)
		}
		return 0, false
	}
	box_eval(e, n)
	return 0, false
}

box_eval :: proc(e: ^Box_Eval, n: ^B_Node) -> i64 {
	#partial switch x in n^ {
	case B_Int:
		return x.value
	case B_Ident:
		return lookup(&e.env, x.sym)
	case B_Negate:
		return -box_eval(e, x.operand)
	case B_Binary:
		a := box_eval(e, x.lhs)
		b := box_eval(e, x.rhs)
		return apply(x.op, a, b)
	case B_Call:
		for a in x.args {
			append(&e.env.args, box_eval(e, a))
		}
		return box_call(e, x.callee, len(x.args))
	}
	return 0
}

// ======================= seeded generator (byte-identical in all three languages) =======================

// splitmix64: the same sequence in all three languages.
Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

OPS := [7]string{"+", "-", "*", "/", "%", "<", "=="}
PARAMS := [3]string{"a", "b", "c"}

// Function i has level i % 3 and may call only functions one or two below it, so the call graph is a DAG
// and evaluation does a bounded amount of work per function.
Gen :: struct {
	out:        strings.Builder,
	rng:        Rng,
	tokens:     int,
	arity:      [dynamic]int,
	vars:       [dynamic]int, // 0..<3 = params a b c, 3 + k = v{k}
	next_let:   int,
	calls_left: int,
	cur:        int,
}

gt :: proc(g: ^Gen, s: string) {
	strings.write_string(&g.out, s)
	g.tokens += 1
}

gn :: proc(g: ^Gen, prefix: string, v: int) {
	strings.write_string(&g.out, prefix)
	strings.write_int(&g.out, v)
	g.tokens += 1
}

graw :: proc(g: ^Gen, s: string) {
	strings.write_string(&g.out, s)
}

gind :: proc(g: ^Gen, k: int) {
	for _ in 0 ..< k {
		graw(g, "    ")
	}
}

gvar :: proc(g: ^Gen, id: int) {
	if id < 3 {
		gt(g, PARAMS[id])
	} else {
		gn(g, "v", id - 3)
	}
}

gen_func :: proc(g: ^Gen, i: int) {
	p := 1 + rng_below(&g.rng, 3)
	append(&g.arity, p)
	clear(&g.vars)
	g.next_let = 0
	g.calls_left = i % 3 == 0 ? 0 : 2
	g.cur = i
	gt(g, "fn"); graw(g, " "); gn(g, "f", i); gt(g, "(")
	for k in 0 ..< p {
		if k > 0 {
			gt(g, ","); graw(g, " ")
		}
		gt(g, PARAMS[k])
		append(&g.vars, k)
	}
	gt(g, ")"); graw(g, " "); gt(g, "{"); graw(g, "\n")
	n := 2 + rng_below(&g.rng, 3)
	for _ in 0 ..< n {
		gen_stmt(g, 1, 1)
	}
	gind(g, 1); gt(g, "return"); graw(g, " "); gen_expr(g, 3); gt(g, ";"); graw(g, "\n")
	gt(g, "}"); graw(g, "\n\n")
}

gen_stmt :: proc(g: ^Gen, indent, nest: int) {
	r := rng_below(&g.rng, 10)
	gind(g, indent)
	if r < 6 || nest >= 3 || (r == 9 && g.calls_left == 0) {
		id := 3 + g.next_let
		g.next_let += 1
		gt(g, "let"); graw(g, " "); gvar(g, id); graw(g, " "); gt(g, "="); graw(g, " ")
		gen_expr(g, 3); gt(g, ";"); graw(g, "\n")
		append(&g.vars, id)
	} else if r < 9 {
		gt(g, "if"); graw(g, " "); gen_expr(g, 2); graw(g, " "); gt(g, "{"); graw(g, "\n")
		gen_block(g, indent + 1, nest + 1)
		gind(g, indent); gt(g, "}")
		if rng_below(&g.rng, 2) == 0 {
			graw(g, " "); gt(g, "else"); graw(g, " "); gt(g, "{"); graw(g, "\n")
			gen_block(g, indent + 1, nest + 1)
			gind(g, indent); gt(g, "}")
		}
		graw(g, "\n")
	} else {
		gen_call(g); gt(g, ";"); graw(g, "\n")
	}
}

gen_block :: proc(g: ^Gen, indent, nest: int) {
	mark := len(g.vars)
	n := 1 + rng_below(&g.rng, 2)
	for _ in 0 ..< n {
		gen_stmt(g, indent, nest)
	}
	if rng_below(&g.rng, 3) == 0 {
		gind(g, indent); gt(g, "return"); graw(g, " "); gen_expr(g, 2); gt(g, ";"); graw(g, "\n")
	}
	resize(&g.vars, mark)
}

gen_expr :: proc(g: ^Gen, depth: int) {
	if depth == 0 || rng_below(&g.rng, 3) == 0 {
		gen_atom(g)
		return
	}
	switch rng_below(&g.rng, 10) {
	case 0:
		gt(g, "-"); gen_expr(g, depth - 1)
	case 1:
		gt(g, "("); gen_expr(g, depth - 1); gt(g, ")")
	case:
		gen_expr(g, depth - 1); graw(g, " ")
		gt(g, OPS[rng_below(&g.rng, len(OPS))]); graw(g, " ")
		gen_expr(g, depth - 1)
	}
}

gen_atom :: proc(g: ^Gen) {
	r := rng_below(&g.rng, 10)
	if g.calls_left > 0 && r < 2 {
		gen_call(g)
	} else if r < 6 {
		gvar(g, g.vars[rng_below(&g.rng, len(g.vars))])
	} else {
		gn(g, "", rng_below(&g.rng, 100))
	}
}

gen_call :: proc(g: ^Gen) {
	g.calls_left -= 1
	j := g.cur - 1 - rng_below(&g.rng, g.cur % 3)
	gn(g, "f", j); gt(g, "(")
	for k in 0 ..< g.arity[j] {
		if k > 0 {
			gt(g, ","); graw(g, " ")
		}
		gen_expr(g, 1)
	}
	gt(g, ")")
}

// About `n_tokens` tokens of functions, then a `main` that calls each one and folds the results.
generate :: proc(n_tokens: int, seed: u64) -> []u8 {
	g := Gen{out = strings.builder_make(), rng = {seed}}
	defer delete(g.arity)
	defer delete(g.vars)
	i := 0
	for i == 0 || g.tokens < n_tokens {
		gen_func(&g, i)
		i += 1
	}
	graw(&g, "fn main() {\n    let acc = 0;\n")
	g.tokens += 10
	for j in 0 ..< i {
		gind(&g, 1)
		graw(&g, "let acc = acc * 3 + f"); strings.write_int(&g.out, j); graw(&g, "(")
		g.tokens += 9
		for k in 0 ..< g.arity[j] {
			if k > 0 {
				gt(&g, ","); graw(&g, " ")
			}
			gn(&g, "", rng_below(&g.rng, 100))
		}
		gt(&g, ")"); gt(&g, ";"); graw(&g, "\n")
	}
	graw(&g, "    return acc;\n}\n")
	g.tokens += 4
	return g.out.buf[:]
}

// ======================= zero-copy serialization =======================
// File: 8 x u32 header, then each column. u8 columns are padded to 4 bytes so every u32 column starts
// 4-byte aligned. Native (little-endian) byte order. Writing hands each column to os.write as it sits
// in memory; reading is one read into a []u32 buffer and slices that point into it.

MAGIC :: u32(0x31415344) // "DSA1"

write_ast :: proc(a: ^Ast, path: string) -> os.Error {
	f := os.create(path) or_return
	defer os.close(f)
	zeros: [4]u8
	pad := proc(n: int) -> int { return (4 - n % 4) % 4 }
	nt, nn, s := len(a.tokens), len(a.nodes), a.strings
	header := [8]u32{MAGIC, u32(nt), u32(nn), u32(len(a.extra)), u32(len(s.bytes)), u32(strings_len(s)), a.main_sym, 0}
	parts := [?][]u8 {
		slice.to_bytes(header[:]),
		slice.to_bytes(a.tokens.tag[:nt]), zeros[:pad(nt)],
		slice.to_bytes(a.tokens.start[:nt]),
		slice.to_bytes(a.nodes.tag[:nn]), zeros[:pad(nn)],
		slice.to_bytes(a.nodes.main_token[:nn]),
		slice.to_bytes(a.nodes.lhs[:nn]),
		slice.to_bytes(a.nodes.rhs[:nn]),
		slice.to_bytes(a.extra[:]),
		s.bytes, zeros[:pad(len(s.bytes))],
		slice.to_bytes(s.starts),
	}
	for part in parts {
		os.write(f, part) or_return
	}
	return nil
}

// A loaded file: every slice points into `buf`. Nothing is decoded or copied after the read.
Loaded :: struct {
	buf:        []u32,
	tok_tags:   []Tok,
	tok_starts: []u32,
	main_token: []u32,
	flat:       Flat,
}

Cursor :: struct {
	b:  []u8,
	at: int,
}

take :: proc(c: ^Cursor, n: int) -> ([]u8, bool) {
	if c.at > len(c.b) || n > len(c.b) - c.at {
		return nil, false
	}
	s := c.b[c.at:][:n]
	c.at += n + (4 - n % 4) % 4
	return s, true
}

take_u32 :: proc(c: ^Cursor, n: int) -> ([]u32, bool) {
	b, ok := take(c, 4 * n)
	return slice.reinterpret([]u32, b), ok
}

// Checks every byte before the bytes are viewed as an enum.
take_tags :: proc(c: ^Cursor, $T: typeid, n: int) -> ([]T, bool) where intrinsics.type_is_enum(T) {
	b, ok := take(c, n)
	for x in b {
		if int(x) >= len(T) {
			return nil, false
		}
	}
	return slice.reinterpret([]T, b), ok
}

load_ast :: proc(path: string) -> (l: Loaded, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return
	}
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil || size % 4 != 0 {
		return
	}
	buf := make([]u32, size / 4) // a []u32 buffer, so every u32 column is aligned
	defer if !ok {
		delete(buf) // every failure below returns ok = false; the caller never sees this buffer
	}
	l.buf = buf
	if _, rerr := os.read_full(f, slice.to_bytes(l.buf)); rerr != nil {
		return {}, false
	}
	c := Cursor{b = slice.to_bytes(l.buf)}
	h := take_u32(&c, 8) or_return
	if h[0] != MAGIC {
		return
	}
	l.tok_tags = take_tags(&c, Tok, int(h[1])) or_return
	l.tok_starts = take_u32(&c, int(h[1])) or_return
	l.flat.tag = take_tags(&c, Tag, int(h[2])) or_return
	l.main_token = take_u32(&c, int(h[2])) or_return
	l.flat.lhs = take_u32(&c, int(h[2])) or_return
	l.flat.rhs = take_u32(&c, int(h[2])) or_return
	l.flat.extra = take_u32(&c, int(h[3])) or_return
	take(&c, int(h[4])) or_return // string bytes
	take_u32(&c, int(h[5]) + 1) or_return // string starts
	// Indices are not checked against the array lengths here; a bad index hits Odin's bounds checks
	// (on by default, also at -o:speed), so a real cache would validate (or checksum) the file first.
	l.flat.n_symbols, l.flat.main_sym = int(h[5]), h[6]
	return l, true
}

// ======================= driver =======================

Ctx :: struct {
	src:   []u8,
	ast:   ^Ast,
	boxed: ^Box_Program,
	path:  string,
}

bench_tokenize :: proc(c: ^Ctx) -> u64 {
	t := tokenize(c.src)
	defer delete(t)
	return u64(len(t))
}

bench_flat :: proc(c: ^Ctx) -> u64 {
	a, err := parse(c.src, tokenize(c.src))
	if err != nil {
		return 0
	}
	defer ast_destroy(&a)
	return u64(len(a.nodes))
}

bench_boxed :: proc(c: ^Ctx) -> u64 {
	t := tokenize(c.src)
	defer delete(t)
	p, err := parse_boxed(c.src, &t)
	if err != nil {
		return 0
	}
	defer box_program_destroy(&p) // freeing the tree is part of its cost
	return u64(len(p.fns))
}

bench_eval_flat :: proc(c: ^Ctx) -> u64 {
	return u64(flat_run(ast_flat(c.ast)))
}

bench_eval_boxed :: proc(c: ^Ctx) -> u64 {
	return u64(box_run(c.boxed))
}

bench_write :: proc(c: ^Ctx) -> u64 {
	return write_ast(c.ast, c.path) == nil ? 1 : 0
}

bench_read :: proc(c: ^Ctx) -> u64 {
	l, ok := load_ast(c.path)
	if !ok {
		return 0
	}
	defer delete(l.buf)
	return u64(len(l.flat.tag))
}

main :: proc() {
	args := parse_args()
	src := generate(args.n, 0x5EED_0011)
	defer delete(src)
	lines := 0
	for c in src {
		lines += int(c == '\n')
	}

	tokens := tokenize(src)
	boxed, berr := parse_boxed(src, &tokens)
	assert(berr == nil, "boxed parse failed")
	defer box_program_destroy(&boxed)
	ast, perr := parse(src, tokens)
	if pe, failed := perr.(Parse_Error); failed {
		fmt.panicf("parse error at token %d: expected %s", pe.token, pe.expected)
	}
	defer ast_destroy(&ast)
	nt, nn, nx := len(ast.tokens), len(ast.nodes), len(ast.extra)
	bs: Box_Stats
	for f in boxed.fns {
		stats_walk(&bs, f)
	}
	bs.nodes += 1 // count the program root like the flat root node
	bs.allocs += 1
	bs.bytes += len(boxed.fns) * size_of(^B_Node)

	fmt.printfln("source: %d bytes, %d lines, %d tokens, %d nodes, %d extra u32s, %d symbols", len(src), lines, nt, nn, nx, strings_len(ast.strings))
	fmt.printfln(
		"sizes: token %d B (#soa) vs %d B as a struct; node %d B (#soa) vs %d B as a struct; boxed Node = %d B",
		size_of(Tok) + size_of(u32), size_of(Token), size_of(Tag) + 3 * size_of(u32), size_of(Node), size_of(B_Node),
	)
	node_avg := f64(13 * nn + 4 * nx) / f64(nn)
	box_avg := f64(bs.bytes) / f64(bs.nodes)
	fmt.printfln("bytes/token %.2f, bytes/node fixed 13, avg incl. extra %.2f; nodes/token %.3f", 5.0, node_avg, f64(nn) / f64(nt))
	fmt.printfln("boxed: %d nodes, %d allocations, %.2f requested B/node (allocator headers not counted)", bs.nodes, bs.allocs, box_avg)

	path := "/tmp/ch11-flat-ast-odin.bin"
	r_flat := flat_run(ast_flat(&ast))
	r_box := box_run(&boxed)
	if werr := write_ast(&ast, path); werr != nil {
		fmt.panicf("write %s: %v", path, werr)
	}
	loaded, lok := load_ast(path)
	assert(lok, "load failed")
	defer delete(loaded.buf)
	r_load := flat_run(loaded.flat)
	same := r_flat == r_box && r_flat == r_load
	fmt.printfln("eval: flat %d, boxed %d, loaded from file %d: %s", r_flat, r_box, r_load, same ? "match" : "MISMATCH")
	assert(same, "results differ")
	fmt.printfln("checksum %d", r_flat)

	ctx := Ctx{src, &ast, &boxed, path}
	t_tok := bench_runs(bench_tokenize, &ctx)
	t_flat := bench_runs(bench_flat, &ctx)
	t_box := bench_runs(bench_boxed, &ctx)
	t_eval_flat := bench_runs(bench_eval_flat, &ctx)
	t_eval_box := bench_runs(bench_eval_boxed, &ctx)
	t_write := bench_runs(bench_write, &ctx)
	t_read := bench_runs(bench_read, &ctx)
	file_len := 4 * len(loaded.buf)
	os.remove(path)

	M :: RUNS / 2
	ms := proc(d: time.Duration) -> f64 { return f64(i64(d)) / 1e6 }
	mb_f, ml_f := f64(len(src)) / ms(t_flat[M]) / 1e3, f64(lines) / ms(t_flat[M]) / 1e3
	mb_b, ml_b := f64(len(src)) / ms(t_box[M]) / 1e3, f64(lines) / ms(t_box[M]) / 1e3
	fmt.printfln("tokenize only        %8.3f ms", ms(t_tok[M]))
	fmt.printfln("flat  tokenize+parse %8.3f ms  %7.1f MB/s  %6.2f M lines/s", ms(t_flat[M]), mb_f, ml_f)
	fmt.printfln("boxed tokenize+parse %8.3f ms  %7.1f MB/s  %6.2f M lines/s  (incl. freeing the tree)", ms(t_box[M]), mb_b, ml_b)
	fmt.printfln("eval  flat %8.3f ms, boxed %8.3f ms", ms(t_eval_flat[M]), ms(t_eval_box[M]))
	fmt.printfln("file: %d bytes (%.2fx the source); write %.3f ms, read (views, no decode) %.3f ms", file_len, f64(file_len) / f64(len(src)), ms(t_write[M]), ms(t_read[M]))

	emit_bench("ch11-parse", "tokenize only", nt, t_tok[:])
	emit_bench("ch11-parse", "flat: tokenize+parse", nt, t_flat[:])
	emit_bench("ch11-parse", "boxed: tokenize+parse", nt, t_box[:])
	emit_bench("ch11-eval", "flat nodes", nn, t_eval_flat[:])
	emit_bench("ch11-eval", "boxed tree", nn, t_eval_box[:])
	emit_bench("ch11-file", "write file", file_len, t_write[:])
	emit_bench("ch11-file", "read file", file_len, t_read[:])
	emit_value("ch11-bytes", "token", nt, 5.0, "B")
	emit_value("ch11-bytes", "node, fixed", nn, 13.0, "B")
	emit_value("ch11-bytes", "node, avg incl. extra", nn, node_avg, "B")
	emit_value("ch11-bytes", "boxed node, avg", nn, box_avg, "B")
	emit_value("ch11-throughput", "flat", nt, ml_f, "M lines/s")
	emit_value("ch11-throughput", "boxed", nt, ml_b, "M lines/s")
}
