//! Chapter 11 capstone: a compiler front end the Zig way.
//! tokenizer -> SoA tokens (u8 tag + u32 start) -> Pratt parser -> SoA nodes {tag, main_token, lhs, rhs}
//! plus one `extra: Vec<u32>` -> post-order evaluator; a Box-per-node tree from the same tokens as the
//! baseline; and the flat arrays written to a file and read back.
//!
//! `cargo run --release -p ch11_capstone_flat_ast_compiler -- [N tokens] [--quick]`

// ---- harness ----
use std::hint::black_box;
use std::time::{Duration, Instant};

const RUNS: usize = 7;

/// Runs `f` once to warm up, then RUNS timed times. Returns the sorted timings.
fn bench_runs<R>(mut f: impl FnMut() -> R) -> [Duration; RUNS] {
    black_box(f());
    let mut t = [Duration::ZERO; RUNS];
    for slot in &mut t {
        let t0 = Instant::now();
        black_box(f());
        *slot = t0.elapsed();
    }
    t.sort_unstable();
    t
}

/// Median of RUNS timed runs (after one warm-up run).
#[allow(dead_code)]
fn bench<R>(f: impl FnMut() -> R) -> Duration {
    bench_runs(f)[RUNS / 2]
}

struct Args {
    n: usize,
    quick: bool,
}

/// Positional integer N (default 1 << 20) and `--quick` (caps N at 1 << 12).
fn parse_args() -> Args {
    let mut a = Args { n: 1 << 20, quick: false };
    for arg in std::env::args().skip(1) {
        if arg == "--quick" {
            a.quick = true
        } else if let Ok(n) = arg.parse() {
            a.n = n
        }
    }
    if a.quick {
        a.n = a.n.min(1 << 12)
    }
    a
}

/// Prints one machine-readable line for bench_all.sh:
/// BENCH {"id":"chNN-x","label":"...","lang":"rust","n":N,"ns":median,"samples":[...]}
/// `runs` must be sorted (as returned by `bench_runs`). `ns` is the median total time for one run.
fn emit_bench(id: &str, label: &str, n: usize, runs: &[Duration]) {
    let esc = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let samples: Vec<String> = runs.iter().map(|d| d.as_nanos().to_string()).collect();
    println!(
        "BENCH {{\"id\":\"{}\",\"label\":\"{}\",\"lang\":\"rust\",\"n\":{},\"ns\":{},\"samples\":[{}]}}",
        esc(id),
        esc(label),
        n,
        runs[runs.len() / 2].as_nanos(),
        samples.join(",")
    );
}
// ---- harness ----

/// Non-time results (bytes, throughput): "ns" is 0 and "value" carries the number.
fn emit_value(id: &str, label: &str, n: usize, value: f64, unit: &str) {
    println!(
        "BENCH {{\"id\":\"{id}\",\"label\":\"{label}\",\"lang\":\"rust\",\"n\":{n},\"ns\":0,\"value\":{value:.3},\"unit\":\"{unit}\"}}"
    );
}

// ======================= tokens: u8 tag + u32 start, stored SoA =======================

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
enum Tok {
    Eof, Invalid, Int, Ident, KwFn, KwLet, KwIf, KwElse, KwReturn, LParen, RParen, LBrace, RBrace,
    Comma, Semicolon, Equal, EqualEqual, Plus, Minus, Star, Slash, Percent, Less,
}
/// Byte -> Tok for loading a file without `unsafe` (a bad byte is an error, not UB).
const TOKS: [Tok; 23] = [
    Tok::Eof, Tok::Invalid, Tok::Int, Tok::Ident, Tok::KwFn, Tok::KwLet, Tok::KwIf, Tok::KwElse,
    Tok::KwReturn, Tok::LParen, Tok::RParen, Tok::LBrace, Tok::RBrace, Tok::Comma, Tok::Semicolon,
    Tok::Equal, Tok::EqualEqual, Tok::Plus, Tok::Minus, Tok::Star, Tok::Slash, Tok::Percent, Tok::Less,
];

/// Struct of arrays: no `end`, no line/column. Both are recomputed from `start` when needed.
#[derive(Default)]
struct Tokens {
    tag: Vec<Tok>,
    start: Vec<u32>,
}
const _: () = assert!(size_of::<Tok>() + size_of::<u32>() == 5);

fn is_ident(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

fn scan_while(src: &[u8], mut i: usize, f: impl Fn(u8) -> bool) -> usize {
    while i < src.len() && f(src[i]) {
        i += 1;
    }
    i
}

fn tokenize(src: &[u8]) -> Tokens {
    let mut t = Tokens::default();
    let guess = src.len() / 4 + 1; // ~4 source bytes per token in this language
    t.tag.reserve(guess);
    t.start.reserve(guess);
    let mut i = 0;
    loop {
        i = scan_while(src, i, |c| matches!(c, b' ' | b'\n' | b'\t' | b'\r'));
        if src[i..].starts_with(b"//") {
            i = scan_while(src, i, |c| c != b'\n');
            continue;
        }
        let start = i as u32;
        let Some(&c) = src.get(i) else {
            t.tag.push(Tok::Eof);
            t.start.push(start);
            return t;
        };
        let tag = match c {
            b'0'..=b'9' => {
                i = scan_while(src, i, |c| c.is_ascii_digit());
                Tok::Int
            }
            b'a'..=b'z' | b'A'..=b'Z' | b'_' => {
                let end = scan_while(src, i, is_ident);
                let word = &src[i..end];
                i = end;
                match word {
                    b"fn" => Tok::KwFn,
                    b"let" => Tok::KwLet,
                    b"if" => Tok::KwIf,
                    b"else" => Tok::KwElse,
                    b"return" => Tok::KwReturn,
                    _ => Tok::Ident,
                }
            }
            b'=' if src.get(i + 1) == Some(&b'=') => {
                i += 2;
                Tok::EqualEqual
            }
            _ => {
                i += 1;
                match c {
                    b'(' => Tok::LParen,
                    b')' => Tok::RParen,
                    b'{' => Tok::LBrace,
                    b'}' => Tok::RBrace,
                    b',' => Tok::Comma,
                    b';' => Tok::Semicolon,
                    b'=' => Tok::Equal,
                    b'+' => Tok::Plus,
                    b'-' => Tok::Minus,
                    b'*' => Tok::Star,
                    b'/' => Tok::Slash,
                    b'%' => Tok::Percent,
                    b'<' => Tok::Less,
                    _ => Tok::Invalid,
                }
            }
        };
        t.tag.push(tag);
        t.start.push(start);
    }
}

/// The token's text, recomputed from its tag and start ("calculate instead of store").
fn token_text(src: &[u8], tag: Tok, start: u32) -> &[u8] {
    let s = start as usize;
    let end = match tag {
        Tok::Int => scan_while(src, s, |c| c.is_ascii_digit()),
        Tok::Ident | Tok::KwFn | Tok::KwLet | Tok::KwIf | Tok::KwElse | Tok::KwReturn => scan_while(src, s, is_ident),
        Tok::EqualEqual => s + 2,
        Tok::Eof => s,
        _ => s + 1,
    };
    &src[s..end]
}

// ======================= string interning =======================

/// All identifier bytes in one buffer; symbol `s` is `bytes[starts[s]..starts[s + 1]]`.
struct Strings {
    bytes: Vec<u8>,
    starts: Vec<u32>,
}
impl Strings {
    fn get(&self, sym: u32) -> &[u8] {
        &self.bytes[self.starts[sym as usize] as usize..self.starts[sym as usize + 1] as usize]
    }
    fn len(&self) -> usize {
        self.starts.len() - 1
    }
    fn find(&self, s: &[u8]) -> Option<u32> {
        (0..self.len() as u32).find(|&i| self.get(i) == s)
    }
}

/// Open addressing over u32 slots (symbol + 1, 0 = empty), FNV-1a, linear probing, load <= 1/2.
struct Interner {
    strings: Strings,
    table: Vec<u32>,
}
fn fnv1a(s: &[u8]) -> u32 {
    s.iter().fold(0x811C_9DC5_u32, |h, &b| (h ^ b as u32).wrapping_mul(0x0100_0193))
}
impl Interner {
    fn new() -> Self {
        Interner { strings: Strings { bytes: Vec::new(), starts: vec![0] }, table: vec![0; 1024] }
    }
    fn intern(&mut self, s: &[u8]) -> u32 {
        let mask = self.table.len() - 1;
        let mut h = fnv1a(s) as usize & mask;
        loop {
            match self.table[h] {
                0 => break,
                e if self.strings.get(e - 1) == s => return e - 1,
                _ => h = (h + 1) & mask,
            }
        }
        let sym = self.strings.len() as u32;
        self.strings.bytes.extend_from_slice(s);
        self.strings.starts.push(self.strings.bytes.len() as u32);
        self.table[h] = sym + 1;
        if 2 * self.strings.len() > self.table.len() {
            self.grow();
        }
        sym
    }
    fn grow(&mut self) {
        let mut table = vec![0u32; self.table.len() * 2];
        let mask = table.len() - 1;
        for sym in 0..self.strings.len() as u32 {
            let mut h = fnv1a(self.strings.get(sym)) as usize & mask;
            while table[h] != 0 {
                h = (h + 1) & mask;
            }
            table[h] = sym + 1;
        }
        self.table = table;
    }
}

// ======================= flat AST: 13 bytes per node + extra =======================

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
enum Tag {
    Root,       // lhs..rhs = extra range of fn_decl nodes
    FnDecl,     // main_token = `fn`; lhs = extra index of {name_sym, n_params, param_sym...}; rhs = body
    BlockTwo,   // lhs, rhs = first and second statement (0 = none)
    Block,      // lhs..rhs = extra range of statements (3 or more)
    LetDecl,    // lhs = name symbol; rhs = initializer
    ReturnStmt, // lhs = value
    IfSimple,   // lhs = condition; rhs = then-block
    IfElse,     // lhs = condition; rhs = extra index of {then, else}
    IntLiteral, // lhs = value
    Identifier, // lhs = symbol
    Negate,     // lhs = operand
    Add, Sub, Mul, Div, Mod, LessThan, EqualEqual, // lhs op rhs
    CallOne,    // main_token = `(`; lhs = callee identifier; rhs = the argument (0 = none)
    Call,       // lhs = callee identifier; rhs = extra index of {args_start, args_end}
}
const TAGS: [Tag; 20] = [
    Tag::Root, Tag::FnDecl, Tag::BlockTwo, Tag::Block, Tag::LetDecl, Tag::ReturnStmt, Tag::IfSimple,
    Tag::IfElse, Tag::IntLiteral, Tag::Identifier, Tag::Negate, Tag::Add, Tag::Sub, Tag::Mul, Tag::Div,
    Tag::Mod, Tag::LessThan, Tag::EqualEqual, Tag::CallOne, Tag::Call,
];

/// Hand-written struct of arrays: Rust has no MultiArrayList or #soa, so each column is a Vec.
#[derive(Default)]
struct Nodes {
    tag: Vec<Tag>,
    main_token: Vec<u32>,
    lhs: Vec<u32>,
    rhs: Vec<u32>,
}
/// The same node as one struct (AoS) would be padded to 16 bytes; the columns use 13.
#[allow(dead_code)]
struct NodeAos {
    tag: Tag,
    main_token: u32,
    lhs: u32,
    rhs: u32,
}
const _: () = assert!(size_of::<NodeAos>() == 16);
const NODE_BYTES: usize = size_of::<Tag>() + 3 * size_of::<u32>();
const _: () = assert!(NODE_BYTES == 13);

struct Ast {
    tokens: Tokens,
    nodes: Nodes,
    extra: Vec<u32>,
    strings: Strings,
    main_sym: u32, // u32::MAX if there is no `main`
}

#[derive(Debug)]
struct ParseError {
    token: u32,
    expected: &'static str,
}
type PResult<T> = Result<T, ParseError>;

struct Parser<'a> {
    src: &'a [u8],
    tags: &'a [Tok],
    starts: &'a [u32],
    i: usize,
    nodes: Nodes,
    extra: Vec<u32>,
    scratch: Vec<u32>,
    interner: Interner,
}

fn binary_op(t: Tok) -> Option<(u8, Tag)> {
    Some(match t {
        Tok::EqualEqual => (1, Tag::EqualEqual),
        Tok::Less => (2, Tag::LessThan),
        Tok::Plus => (3, Tag::Add),
        Tok::Minus => (3, Tag::Sub),
        Tok::Star => (4, Tag::Mul),
        Tok::Slash => (4, Tag::Div),
        Tok::Percent => (4, Tag::Mod),
        _ => return None,
    })
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Tok {
        self.tags[self.i]
    }
    fn next(&mut self) -> u32 {
        self.i += 1;
        (self.i - 1) as u32
    }
    fn expect(&mut self, t: Tok, expected: &'static str) -> PResult<u32> {
        if self.peek() == t { Ok(self.next()) } else { Err(ParseError { token: self.i as u32, expected }) }
    }
    fn intern_token(&mut self, tok: u32) -> u32 {
        let text = token_text(self.src, Tok::Ident, self.starts[tok as usize]);
        self.interner.intern(text)
    }
    fn add(&mut self, tag: Tag, main_token: u32, lhs: u32, rhs: u32) -> u32 {
        let n = &mut self.nodes;
        n.tag.push(tag);
        n.main_token.push(main_token);
        n.lhs.push(lhs);
        n.rhs.push(rhs);
        (n.tag.len() - 1) as u32
    }
    /// Moves scratch[top..] into `extra` and returns the range: lists are built in one shared
    /// scratch stack, then copied once into their final, contiguous place.
    fn list_to_extra(&mut self, top: usize) -> (u32, u32) {
        let start = self.extra.len() as u32;
        self.extra.extend_from_slice(&self.scratch[top..]);
        self.scratch.truncate(top);
        (start, self.extra.len() as u32)
    }

    fn parse_root(&mut self) -> PResult<()> {
        self.add(Tag::Root, 0, 0, 0); // node 0, so index 0 can mean "none" everywhere else
        let top = self.scratch.len();
        while self.peek() != Tok::Eof {
            let f = self.parse_fn()?;
            self.scratch.push(f);
        }
        let (s, e) = self.list_to_extra(top);
        self.nodes.lhs[0] = s;
        self.nodes.rhs[0] = e;
        Ok(())
    }

    fn parse_fn(&mut self) -> PResult<u32> {
        let fn_tok = self.expect(Tok::KwFn, "`fn`")?;
        let name_tok = self.expect(Tok::Ident, "function name")?;
        let name = self.intern_token(name_tok);
        self.expect(Tok::LParen, "`(`")?;
        let top = self.scratch.len();
        if self.peek() != Tok::RParen {
            loop {
                let p = self.expect(Tok::Ident, "parameter name")?;
                let sym = self.intern_token(p);
                self.scratch.push(sym);
                if self.peek() != Tok::Comma {
                    break;
                }
                self.next();
            }
        }
        self.expect(Tok::RParen, "`)`")?;
        let proto = self.extra.len() as u32;
        let n_params = (self.scratch.len() - top) as u32;
        self.extra.extend([name, n_params]);
        self.list_to_extra(top);
        let body = self.parse_block()?;
        Ok(self.add(Tag::FnDecl, fn_tok, proto, body))
    }

    fn parse_block(&mut self) -> PResult<u32> {
        let lbrace = self.expect(Tok::LBrace, "`{`")?;
        let top = self.scratch.len();
        while self.peek() != Tok::RBrace {
            let s = self.parse_stmt()?;
            self.scratch.push(s);
        }
        self.next();
        if self.scratch.len() - top <= 2 {
            let a = self.scratch.get(top).copied().unwrap_or(0);
            let b = self.scratch.get(top + 1).copied().unwrap_or(0);
            self.scratch.truncate(top);
            Ok(self.add(Tag::BlockTwo, lbrace, a, b))
        } else {
            let (s, e) = self.list_to_extra(top);
            Ok(self.add(Tag::Block, lbrace, s, e))
        }
    }

    fn parse_stmt(&mut self) -> PResult<u32> {
        match self.peek() {
            Tok::KwLet => {
                let let_tok = self.next();
                let name_tok = self.expect(Tok::Ident, "variable name")?;
                let sym = self.intern_token(name_tok);
                self.expect(Tok::Equal, "`=`")?;
                let init = self.parse_expr(0)?;
                self.expect(Tok::Semicolon, "`;`")?;
                Ok(self.add(Tag::LetDecl, let_tok, sym, init))
            }
            Tok::KwReturn => {
                let ret = self.next();
                let value = self.parse_expr(0)?;
                self.expect(Tok::Semicolon, "`;`")?;
                Ok(self.add(Tag::ReturnStmt, ret, value, 0))
            }
            Tok::KwIf => self.parse_if(),
            Tok::Eof => Err(ParseError { token: self.i as u32, expected: "`}`" }),
            _ => {
                let e = self.parse_expr(0)?;
                self.expect(Tok::Semicolon, "`;`")?;
                Ok(e)
            }
        }
    }

    fn parse_if(&mut self) -> PResult<u32> {
        let if_tok = self.next();
        let cond = self.parse_expr(0)?;
        let then = self.parse_block()?;
        if self.peek() != Tok::KwElse {
            return Ok(self.add(Tag::IfSimple, if_tok, cond, then));
        }
        self.next();
        let els = if self.peek() == Tok::KwIf { self.parse_if()? } else { self.parse_block()? };
        let x = self.extra.len() as u32;
        self.extra.extend([then, els]);
        Ok(self.add(Tag::IfElse, if_tok, cond, x))
    }

    /// Pratt loop: operators that bind tighter than `min_prec` extend the left operand.
    fn parse_expr(&mut self, min_prec: u8) -> PResult<u32> {
        let mut lhs = self.parse_prefix()?;
        while let Some((prec, tag)) = binary_op(self.peek())
            && prec > min_prec
        {
            let op = self.next();
            let rhs = self.parse_expr(prec)?;
            lhs = self.add(tag, op, lhs, rhs);
        }
        Ok(lhs)
    }

    fn parse_prefix(&mut self) -> PResult<u32> {
        match self.peek() {
            Tok::Int => {
                let t = self.next();
                let text = token_text(self.src, Tok::Int, self.starts[t as usize]);
                let v = text.iter().try_fold(0u32, |v, &d| v.checked_mul(10)?.checked_add((d - b'0') as u32));
                let v = v.ok_or(ParseError { token: t, expected: "integer below 2^32" })?;
                Ok(self.add(Tag::IntLiteral, t, v, 0))
            }
            Tok::Ident => {
                let t = self.next();
                let sym = self.intern_token(t);
                let id = self.add(Tag::Identifier, t, sym, 0);
                if self.peek() == Tok::LParen { self.parse_call(id) } else { Ok(id) }
            }
            Tok::LParen => {
                self.next();
                let e = self.parse_expr(0)?;
                self.expect(Tok::RParen, "`)`")?;
                Ok(e) // no node for parentheses: the tree shape already says it
            }
            Tok::Minus => {
                let t = self.next();
                let operand = self.parse_prefix()?;
                Ok(self.add(Tag::Negate, t, operand, 0))
            }
            _ => Err(ParseError { token: self.i as u32, expected: "expression" }),
        }
    }

    /// Two encodings of one construct: `f()` and `f(x)` fit in the node; `f(x, y, ...)` spills to extra.
    fn parse_call(&mut self, callee: u32) -> PResult<u32> {
        let lparen = self.next();
        let top = self.scratch.len();
        if self.peek() != Tok::RParen {
            loop {
                let a = self.parse_expr(0)?;
                self.scratch.push(a);
                if self.peek() != Tok::Comma {
                    break;
                }
                self.next();
            }
        }
        self.expect(Tok::RParen, "`)`")?;
        if self.scratch.len() - top <= 1 {
            let arg = self.scratch.get(top).copied().unwrap_or(0);
            self.scratch.truncate(top);
            return Ok(self.add(Tag::CallOne, lparen, callee, arg));
        }
        let (s, e) = self.list_to_extra(top);
        let range = self.extra.len() as u32;
        self.extra.extend([s, e]);
        Ok(self.add(Tag::Call, lparen, callee, range))
    }
}

/// Takes the tokens by value: the AST owns them, as std.zig.Ast does.
fn parse(src: &[u8], tokens: Tokens) -> PResult<Ast> {
    let guess = tokens.tag.len() * 2 / 3 + 1; // about 0.63 nodes per token for this language
    let mut nodes = Nodes::default();
    nodes.tag.reserve(guess);
    nodes.main_token.reserve(guess);
    nodes.lhs.reserve(guess);
    nodes.rhs.reserve(guess);
    let mut p = Parser {
        src, tags: &tokens.tag, starts: &tokens.start, i: 0, nodes, extra: Vec::new(),
        scratch: Vec::new(), interner: Interner::new(),
    };
    p.parse_root()?;
    let main_sym = p.interner.strings.find(b"main").unwrap_or(u32::MAX);
    let (nodes, extra, strings) = (p.nodes, p.extra, p.interner.strings);
    Ok(Ast { tokens, nodes, extra, strings, main_sym })
}

// ======================= evaluator over the flat nodes =======================

/// Integer semantics shared by both evaluators: wrapping i64; x / 0 = 0 and x % 0 = 0.
fn apply(op: Tag, a: i64, b: i64) -> i64 {
    match op {
        Tag::Add => a.wrapping_add(b),
        Tag::Sub => a.wrapping_sub(b),
        Tag::Mul => a.wrapping_mul(b),
        Tag::Div => if b == 0 { 0 } else { a.wrapping_div(b) },
        Tag::Mod => if b == 0 { 0 } else { a.wrapping_rem(b) },
        Tag::LessThan => (a < b) as i64,
        Tag::EqualEqual => (a == b) as i64,
        _ => unreachable!(),
    }
}

/// Variables live on one stack of (symbol, value); a call sees only its own frame (env[base..]).
struct Env {
    vars: Vec<(u32, i64)>,
    base: usize,
    args: Vec<i64>,
}
impl Env {
    fn new() -> Self {
        Env { vars: Vec::new(), base: 0, args: Vec::new() }
    }
    fn lookup(&self, sym: u32) -> i64 {
        self.vars[self.base..].iter().rev().find(|v| v.0 == sym).map_or(0, |v| v.1)
    }
}

/// The columns are hoisted into plain slices once; every access below is an index into one of them.
struct FlatEval<'a> {
    tag: &'a [Tag],
    lhs: &'a [u32],
    rhs: &'a [u32],
    extra: &'a [u32],
    fns: Vec<u32>, // symbol -> fn_decl node (0 = none)
    env: Env,
}

impl<'a> FlatEval<'a> {
    fn run(ast: &'a Ast) -> i64 {
        let mut e = FlatEval {
            tag: &ast.nodes.tag, lhs: &ast.nodes.lhs, rhs: &ast.nodes.rhs, extra: &ast.extra,
            fns: vec![0; ast.strings.len()], env: Env::new(),
        };
        for &f in &ast.extra[ast.nodes.lhs[0] as usize..ast.nodes.rhs[0] as usize] {
            let name = ast.extra[ast.nodes.lhs[f as usize] as usize];
            e.fns[name as usize] = f;
        }
        e.call_sym(ast.main_sym, 0)
    }

    fn call_sym(&mut self, sym: u32, nargs: usize) -> i64 {
        let f = self.fns.get(sym as usize).copied().unwrap_or(0);
        let first = self.env.args.len() - nargs;
        if f == 0 {
            self.env.args.truncate(first);
            return 0;
        }
        let proto = self.lhs[f as usize] as usize;
        let n_params = self.extra[proto + 1] as usize;
        let (saved, base) = (self.env.base, self.env.vars.len());
        for k in 0..n_params.min(nargs) {
            self.env.vars.push((self.extra[proto + 2 + k], self.env.args[first + k]));
        }
        self.env.args.truncate(first);
        self.env.base = base;
        let r = self.exec(self.rhs[f as usize]).unwrap_or(0);
        self.env.vars.truncate(base);
        self.env.base = saved;
        r
    }

    /// Statements: Some(v) means `return v` happened.
    fn exec(&mut self, n: u32) -> Option<i64> {
        let (l, r) = (self.lhs[n as usize], self.rhs[n as usize]);
        match self.tag[n as usize] {
            Tag::BlockTwo => self.exec_list(&[l, r]),
            Tag::Block => self.exec_list(&self.extra[l as usize..r as usize]),
            Tag::LetDecl => {
                let v = self.eval(r);
                self.env.vars.push((l, v));
                None
            }
            Tag::ReturnStmt => Some(self.eval(l)),
            Tag::IfSimple => if self.eval(l) != 0 { self.exec(r) } else { None },
            Tag::IfElse => {
                let (then, els) = (self.extra[r as usize], self.extra[r as usize + 1]);
                if self.eval(l) != 0 { self.exec(then) } else { self.exec(els) }
            }
            _ => {
                self.eval(n);
                None
            }
        }
    }

    fn exec_list(&mut self, stmts: &[u32]) -> Option<i64> {
        let mark = self.env.vars.len();
        let mut out = None;
        for &s in stmts {
            if s == 0 {
                break;
            }
            out = self.exec(s);
            if out.is_some() {
                break;
            }
        }
        self.env.vars.truncate(mark);
        out
    }

    /// Expressions, children first (post-order).
    fn eval(&mut self, n: u32) -> i64 {
        let (l, r) = (self.lhs[n as usize], self.rhs[n as usize]);
        match self.tag[n as usize] {
            Tag::IntLiteral => l as i64,
            Tag::Identifier => self.env.lookup(l),
            Tag::Negate => self.eval(l).wrapping_neg(),
            Tag::CallOne => {
                let nargs = if r != 0 {
                    let v = self.eval(r);
                    self.env.args.push(v);
                    1
                } else {
                    0
                };
                self.call_sym(self.lhs[l as usize], nargs)
            }
            Tag::Call => {
                let (s, e) = (self.extra[r as usize] as usize, self.extra[r as usize + 1] as usize);
                for k in s..e {
                    let v = self.eval(self.extra[k]);
                    self.env.args.push(v);
                }
                self.call_sym(self.lhs[l as usize], e - s)
            }
            op => {
                let a = self.eval(l);
                let b = self.eval(r);
                apply(op, a, b)
            }
        }
    }
}

// ======================= baseline: one Box per node =======================

/// `token` is each node's source location (the flat tree's `main_token`); the evaluator never reads it,
/// but a real compiler needs it for error messages, so both trees keep the same information.
#[allow(dead_code)]
enum Node {
    Int { token: u32, value: i64 },
    Ident { token: u32, sym: u32 },
    Negate { token: u32, operand: Box<Node> },
    Binary { token: u32, op: Tag, lhs: Box<Node>, rhs: Box<Node> },
    Call { token: u32, callee: u32, args: Box<[Box<Node>]> },
    Let { token: u32, sym: u32, init: Box<Node> },
    Return { token: u32, value: Box<Node> },
    If { token: u32, cond: Box<Node>, then: Box<Node>, els: Option<Box<Node>> },
    Block { token: u32, stmts: Box<[Box<Node>]> },
    Fn { token: u32, name: u32, params: Box<[u32]>, body: Box<Node> },
}

struct BoxProgram {
    fns: Box<[Box<Node>]>,
    n_symbols: usize,
    main_sym: u32,
}

/// Same grammar, same tokens, same interner; only the tree representation differs.
struct BoxParser<'a> {
    src: &'a [u8],
    tags: &'a [Tok],
    starts: &'a [u32],
    i: usize,
    interner: Interner,
}

impl BoxParser<'_> {
    fn peek(&self) -> Tok {
        self.tags[self.i]
    }
    fn next(&mut self) -> u32 {
        self.i += 1;
        (self.i - 1) as u32
    }
    fn expect(&mut self, t: Tok, expected: &'static str) -> PResult<u32> {
        if self.peek() == t { Ok(self.next()) } else { Err(ParseError { token: self.i as u32, expected }) }
    }
    fn intern_token(&mut self, tok: u32) -> u32 {
        let text = token_text(self.src, Tok::Ident, self.starts[tok as usize]);
        self.interner.intern(text)
    }

    fn parse_program(mut self) -> PResult<BoxProgram> {
        let mut fns = Vec::new();
        while self.peek() != Tok::Eof {
            fns.push(self.parse_fn()?);
        }
        let main_sym = self.interner.strings.find(b"main").unwrap_or(u32::MAX);
        Ok(BoxProgram { fns: fns.into_boxed_slice(), n_symbols: self.interner.strings.len(), main_sym })
    }

    fn parse_fn(&mut self) -> PResult<Box<Node>> {
        let token = self.expect(Tok::KwFn, "`fn`")?;
        let name_tok = self.expect(Tok::Ident, "function name")?;
        let name = self.intern_token(name_tok);
        self.expect(Tok::LParen, "`(`")?;
        let mut params = Vec::new();
        if self.peek() != Tok::RParen {
            loop {
                let p = self.expect(Tok::Ident, "parameter name")?;
                params.push(self.intern_token(p));
                if self.peek() != Tok::Comma {
                    break;
                }
                self.next();
            }
        }
        self.expect(Tok::RParen, "`)`")?;
        let body = self.parse_block()?;
        Ok(Box::new(Node::Fn { token, name, params: params.into_boxed_slice(), body }))
    }

    fn parse_block(&mut self) -> PResult<Box<Node>> {
        let token = self.expect(Tok::LBrace, "`{`")?;
        let mut stmts = Vec::new();
        while self.peek() != Tok::RBrace {
            stmts.push(self.parse_stmt()?);
        }
        self.next();
        Ok(Box::new(Node::Block { token, stmts: stmts.into_boxed_slice() }))
    }

    fn parse_stmt(&mut self) -> PResult<Box<Node>> {
        match self.peek() {
            Tok::KwLet => {
                let token = self.next();
                let name_tok = self.expect(Tok::Ident, "variable name")?;
                let sym = self.intern_token(name_tok);
                self.expect(Tok::Equal, "`=`")?;
                let init = self.parse_expr(0)?;
                self.expect(Tok::Semicolon, "`;`")?;
                Ok(Box::new(Node::Let { token, sym, init }))
            }
            Tok::KwReturn => {
                let token = self.next();
                let value = self.parse_expr(0)?;
                self.expect(Tok::Semicolon, "`;`")?;
                Ok(Box::new(Node::Return { token, value }))
            }
            Tok::KwIf => self.parse_if(),
            Tok::Eof => Err(ParseError { token: self.i as u32, expected: "`}`" }),
            _ => {
                let e = self.parse_expr(0)?;
                self.expect(Tok::Semicolon, "`;`")?;
                Ok(e)
            }
        }
    }

    fn parse_if(&mut self) -> PResult<Box<Node>> {
        let token = self.next();
        let cond = self.parse_expr(0)?;
        let then = self.parse_block()?;
        let mut els = None;
        if self.peek() == Tok::KwElse {
            self.next();
            els = Some(if self.peek() == Tok::KwIf { self.parse_if()? } else { self.parse_block()? });
        }
        Ok(Box::new(Node::If { token, cond, then, els }))
    }

    fn parse_expr(&mut self, min_prec: u8) -> PResult<Box<Node>> {
        let mut lhs = self.parse_prefix()?;
        while let Some((prec, op)) = binary_op(self.peek())
            && prec > min_prec
        {
            let token = self.next();
            let rhs = self.parse_expr(prec)?;
            lhs = Box::new(Node::Binary { token, op, lhs, rhs });
        }
        Ok(lhs)
    }

    fn parse_prefix(&mut self) -> PResult<Box<Node>> {
        match self.peek() {
            Tok::Int => {
                let token = self.next();
                let text = token_text(self.src, Tok::Int, self.starts[token as usize]);
                let v = text.iter().try_fold(0u32, |v, &d| v.checked_mul(10)?.checked_add((d - b'0') as u32));
                let v = v.ok_or(ParseError { token, expected: "integer below 2^32" })?;
                Ok(Box::new(Node::Int { token, value: v as i64 }))
            }
            Tok::Ident => {
                let token = self.next();
                let sym = self.intern_token(token);
                if self.peek() != Tok::LParen {
                    return Ok(Box::new(Node::Ident { token, sym }));
                }
                let token = self.next();
                let mut args = Vec::new();
                if self.peek() != Tok::RParen {
                    loop {
                        args.push(self.parse_expr(0)?);
                        if self.peek() != Tok::Comma {
                            break;
                        }
                        self.next();
                    }
                }
                self.expect(Tok::RParen, "`)`")?;
                Ok(Box::new(Node::Call { token, callee: sym, args: args.into_boxed_slice() }))
            }
            Tok::LParen => {
                self.next();
                let e = self.parse_expr(0)?;
                self.expect(Tok::RParen, "`)`")?;
                Ok(e)
            }
            Tok::Minus => {
                let token = self.next();
                let operand = self.parse_prefix()?;
                Ok(Box::new(Node::Negate { token, operand }))
            }
            _ => Err(ParseError { token: self.i as u32, expected: "expression" }),
        }
    }
}

fn parse_boxed(src: &[u8], tokens: &Tokens) -> PResult<BoxProgram> {
    BoxParser { src, tags: &tokens.tag, starts: &tokens.start, i: 0, interner: Interner::new() }.parse_program()
}

/// Counts nodes, allocations and requested heap bytes (allocator headers not included).
#[derive(Default)]
struct BoxStats {
    nodes: usize,
    allocs: usize,
    bytes: usize,
}
fn box_stats(n: &Node, s: &mut BoxStats) {
    s.nodes += 1;
    s.allocs += 1;
    s.bytes += size_of::<Node>();
    let mut list = |len: usize, elem: usize| {
        if len > 0 {
            s.allocs += 1;
            s.bytes += len * elem;
        }
    };
    match n {
        Node::Int { .. } | Node::Ident { .. } => {}
        Node::Call { args, .. } => {
            list(args.len(), size_of::<Box<Node>>());
            args.iter().for_each(|a| box_stats(a, s));
        }
        Node::Block { stmts, .. } => {
            list(stmts.len(), size_of::<Box<Node>>());
            stmts.iter().for_each(|a| box_stats(a, s));
        }
        Node::Fn { params, body, .. } => {
            list(params.len(), size_of::<u32>());
            box_stats(body, s);
        }
        Node::Negate { operand: x, .. } | Node::Let { init: x, .. } | Node::Return { value: x, .. } => box_stats(x, s),
        Node::Binary { lhs, rhs, .. } => {
            box_stats(lhs, s);
            box_stats(rhs, s);
        }
        Node::If { cond, then, els, .. } => {
            box_stats(cond, s);
            box_stats(then, s);
            if let Some(e) = els {
                box_stats(e, s);
            }
        }
    }
}

struct BoxEval<'a> {
    fns: Vec<Option<&'a Node>>,
    env: Env,
}

impl<'a> BoxEval<'a> {
    fn run(p: &'a BoxProgram) -> i64 {
        let mut e = BoxEval { fns: vec![None; p.n_symbols], env: Env::new() };
        for f in &p.fns {
            if let Node::Fn { name, .. } = **f {
                e.fns[name as usize] = Some(f);
            }
        }
        e.call_sym(p.main_sym, 0)
    }

    fn call_sym(&mut self, sym: u32, nargs: usize) -> i64 {
        let first = self.env.args.len() - nargs;
        let Some(&Some(Node::Fn { params, body, .. })) = self.fns.get(sym as usize) else {
            self.env.args.truncate(first);
            return 0;
        };
        let (saved, base) = (self.env.base, self.env.vars.len());
        for (k, &p) in params.iter().take(nargs).enumerate() {
            self.env.vars.push((p, self.env.args[first + k]));
        }
        self.env.args.truncate(first);
        self.env.base = base;
        let r = self.exec(body).unwrap_or(0);
        self.env.vars.truncate(base);
        self.env.base = saved;
        r
    }

    fn exec(&mut self, n: &Node) -> Option<i64> {
        match n {
            Node::Block { stmts, .. } => {
                let mark = self.env.vars.len();
                let mut out = None;
                for s in stmts {
                    out = self.exec(s);
                    if out.is_some() {
                        break;
                    }
                }
                self.env.vars.truncate(mark);
                out
            }
            Node::Let { sym, init, .. } => {
                let v = self.eval(init);
                self.env.vars.push((*sym, v));
                None
            }
            Node::Return { value, .. } => Some(self.eval(value)),
            Node::If { cond, then, els, .. } => {
                if self.eval(cond) != 0 {
                    self.exec(then)
                } else if let Some(e) = els {
                    self.exec(e)
                } else {
                    None
                }
            }
            _ => {
                self.eval(n);
                None
            }
        }
    }

    fn eval(&mut self, n: &Node) -> i64 {
        match n {
            Node::Int { value, .. } => *value,
            Node::Ident { sym, .. } => self.env.lookup(*sym),
            Node::Negate { operand, .. } => self.eval(operand).wrapping_neg(),
            Node::Binary { op, lhs, rhs, .. } => {
                let a = self.eval(lhs);
                let b = self.eval(rhs);
                apply(*op, a, b)
            }
            Node::Call { callee, args, .. } => {
                for a in args {
                    let v = self.eval(a);
                    self.env.args.push(v);
                }
                self.call_sym(*callee, args.len())
            }
            _ => 0,
        }
    }
}

// ======================= seeded generator (byte-identical in all three languages) =======================

/// splitmix64: the same sequence in all three languages.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

const OPS: [&str; 7] = ["+", "-", "*", "/", "%", "<", "=="];
const PARAMS: [&str; 3] = ["a", "b", "c"];

/// Function i has level i % 3 and may call only functions one or two below it, so the call graph is a DAG
/// and evaluation does a bounded amount of work per function.
struct Gen {
    out: String,
    rng: Rng,
    tokens: usize,
    arity: Vec<usize>,
    vars: Vec<usize>, // 0..3 = params a b c, 3 + k = v{k}
    next_let: usize,
    calls_left: usize,
    cur: usize,
}

impl Gen {
    fn t(&mut self, s: &str) {
        self.out.push_str(s);
        self.tokens += 1;
    }
    fn sp(&mut self) {
        self.out.push(' ');
    }
    fn nl(&mut self) {
        self.out.push('\n');
    }
    fn ind(&mut self, k: usize) {
        (0..k).for_each(|_| self.out.push_str("    "));
    }
    fn var(&mut self, id: usize) {
        let name = if id < 3 { PARAMS[id].to_string() } else { format!("v{}", id - 3) };
        self.t(&name);
    }

    fn func(&mut self, i: usize) {
        let p = 1 + self.rng.below(3);
        self.arity.push(p);
        self.vars.clear();
        self.next_let = 0;
        self.calls_left = if i.is_multiple_of(3) { 0 } else { 2 };
        self.cur = i;
        self.t("fn");
        self.sp();
        self.t(&format!("f{i}"));
        self.t("(");
        for (k, name) in PARAMS.iter().take(p).enumerate() {
            if k > 0 {
                self.t(",");
                self.sp();
            }
            self.t(name);
            self.vars.push(k);
        }
        self.t(")");
        self.sp();
        self.t("{");
        self.nl();
        let n = 2 + self.rng.below(3);
        for _ in 0..n {
            self.stmt(1, 1);
        }
        self.ind(1);
        self.t("return");
        self.sp();
        self.expr(3);
        self.t(";");
        self.nl();
        self.t("}");
        self.nl();
        self.nl();
    }

    fn stmt(&mut self, indent: usize, nest: usize) {
        let r = self.rng.below(10);
        self.ind(indent);
        if r < 6 || nest >= 3 || (r == 9 && self.calls_left == 0) {
            let id = 3 + self.next_let;
            self.next_let += 1;
            self.t("let");
            self.sp();
            self.var(id);
            self.sp();
            self.t("=");
            self.sp();
            self.expr(3);
            self.t(";");
            self.nl();
            self.vars.push(id);
        } else if r < 9 {
            self.t("if");
            self.sp();
            self.expr(2);
            self.sp();
            self.t("{");
            self.nl();
            self.block(indent + 1, nest + 1);
            self.ind(indent);
            self.t("}");
            if self.rng.below(2) == 0 {
                self.sp();
                self.t("else");
                self.sp();
                self.t("{");
                self.nl();
                self.block(indent + 1, nest + 1);
                self.ind(indent);
                self.t("}");
            }
            self.nl();
        } else {
            self.call();
            self.t(";");
            self.nl();
        }
    }

    fn block(&mut self, indent: usize, nest: usize) {
        let mark = self.vars.len();
        let n = 1 + self.rng.below(2);
        for _ in 0..n {
            self.stmt(indent, nest);
        }
        if self.rng.below(3) == 0 {
            self.ind(indent);
            self.t("return");
            self.sp();
            self.expr(2);
            self.t(";");
            self.nl();
        }
        self.vars.truncate(mark);
    }

    fn expr(&mut self, depth: usize) {
        if depth == 0 || self.rng.below(3) == 0 {
            return self.atom();
        }
        match self.rng.below(10) {
            0 => {
                self.t("-");
                self.expr(depth - 1);
            }
            1 => {
                self.t("(");
                self.expr(depth - 1);
                self.t(")");
            }
            _ => {
                self.expr(depth - 1);
                self.sp();
                let op = OPS[self.rng.below(OPS.len())];
                self.t(op);
                self.sp();
                self.expr(depth - 1);
            }
        }
    }

    fn atom(&mut self) {
        let r = self.rng.below(10);
        if self.calls_left > 0 && r < 2 {
            self.call();
        } else if r < 6 {
            let id = self.vars[self.rng.below(self.vars.len())];
            self.var(id);
        } else {
            let v = self.rng.below(100);
            self.t(&v.to_string());
        }
    }

    fn call(&mut self) {
        self.calls_left -= 1;
        let j = self.cur - 1 - self.rng.below(self.cur % 3);
        self.t(&format!("f{j}"));
        self.t("(");
        for k in 0..self.arity[j] {
            if k > 0 {
                self.t(",");
                self.sp();
            }
            self.expr(1);
        }
        self.t(")");
    }
}

/// About `n_tokens` tokens of functions, then a `main` that calls each one and folds the results.
fn generate(n_tokens: usize, seed: u64) -> String {
    let mut g = Gen {
        out: String::new(), rng: Rng(seed), tokens: 0, arity: Vec::new(), vars: Vec::new(),
        next_let: 0, calls_left: 0, cur: 0,
    };
    let mut i = 0;
    while i == 0 || g.tokens < n_tokens {
        g.func(i);
        i += 1;
    }
    for s in ["fn", " ", "main", "(", ")", " ", "{", "\n", "    ", "let", " ", "acc", " ", "=", " ", "0", ";", "\n"] {
        if s.trim().is_empty() { g.out.push_str(s) } else { g.t(s) }
    }
    for j in 0..i {
        g.ind(1);
        g.out.push_str(&format!("let acc = acc * 3 + f{j}("));
        g.tokens += 9;
        for k in 0..g.arity[j] {
            if k > 0 {
                g.t(",");
                g.sp();
            }
            let v = g.rng.below(100);
            g.t(&v.to_string());
        }
        g.t(")");
        g.t(";");
        g.nl();
    }
    g.out.push_str("    return acc;\n}\n");
    g.tokens += 4;
    g.out
}

// ======================= zero-copy-style serialization =======================
// File: 8 x u32 header, then each column. u8 columns are padded to 4 bytes so every u32 column starts
// 4-byte aligned. Little-endian. Safe Rust cannot view &[u8] as &[u32] without `unsafe` (or a crate),
// so the reader decodes each column with as_chunks + from_le_bytes: one tight copy, no parsing.

const MAGIC: u32 = 0x3141_5344; // "DSA1"

fn put_u32s(out: &mut Vec<u8>, xs: &[u32]) {
    for x in xs {
        out.extend_from_slice(&x.to_le_bytes());
    }
}
fn pad4(out: &mut Vec<u8>) {
    out.resize(out.len().next_multiple_of(4), 0);
}

fn serialize(ast: &Ast) -> Vec<u8> {
    let (nt, nn) = (ast.tokens.tag.len(), ast.nodes.tag.len());
    let mut out = Vec::with_capacity(32 + 5 * nt + 13 * nn + 4 * ast.extra.len() + ast.strings.bytes.len() + 16);
    let s = &ast.strings;
    put_u32s(&mut out, &[MAGIC, nt as u32, nn as u32, ast.extra.len() as u32, s.bytes.len() as u32, s.len() as u32, ast.main_sym, 0]);
    out.extend(ast.tokens.tag.iter().map(|&t| t as u8));
    pad4(&mut out);
    put_u32s(&mut out, &ast.tokens.start);
    out.extend(ast.nodes.tag.iter().map(|&t| t as u8));
    pad4(&mut out);
    put_u32s(&mut out, &ast.nodes.main_token);
    put_u32s(&mut out, &ast.nodes.lhs);
    put_u32s(&mut out, &ast.nodes.rhs);
    put_u32s(&mut out, &ast.extra);
    out.extend_from_slice(&s.bytes);
    pad4(&mut out);
    put_u32s(&mut out, &s.starts);
    out
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}
impl<'a> Reader<'a> {
    fn bytes(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(n).filter(|&e| e <= self.b.len()).ok_or("file too short")?;
        let s = &self.b[self.at..end];
        self.at = end.next_multiple_of(4);
        Ok(s)
    }
    fn u32s(&mut self, n: usize) -> Result<Vec<u32>, String> {
        let (chunks, _) = self.bytes(4 * n)?.as_chunks::<4>();
        Ok(chunks.iter().map(|c| u32::from_le_bytes(*c)).collect())
    }
    fn tags<T: Copy>(&mut self, n: usize, table: &[T]) -> Result<Vec<T>, String> {
        self.bytes(n)?.iter().map(|&b| table.get(b as usize).copied().ok_or_else(|| format!("bad tag {b}"))).collect()
    }
}

fn deserialize(b: &[u8]) -> Result<Ast, String> {
    let mut r = Reader { b, at: 0 };
    let h = r.u32s(8)?;
    if h[0] != MAGIC {
        return Err("bad magic".into());
    }
    let [nt, nn, nx, nb, ns] = [h[1], h[2], h[3], h[4], h[5]].map(|x| x as usize);
    let tokens = Tokens { tag: r.tags(nt, &TOKS)?, start: r.u32s(nt)? };
    let tag = r.tags(nn, &TAGS)?;
    let nodes = Nodes { tag, main_token: r.u32s(nn)?, lhs: r.u32s(nn)?, rhs: r.u32s(nn)? };
    let extra = r.u32s(nx)?;
    let strings = Strings { bytes: r.bytes(nb)?.to_vec(), starts: r.u32s(ns + 1)? };
    // Indices are not checked against the array lengths here; a hostile file would make the evaluator
    // panic on a bounds check (never UB in safe Rust).
    Ok(Ast { tokens, nodes, extra, strings, main_sym: h[6] })
}

// ======================= driver =======================

fn main() {
    let args = parse_args();
    let src = generate(args.n, 0x5EED_0011);
    let bytes = src.as_bytes();
    let lines = bytes.iter().filter(|&&c| c == b'\n').count();

    let tokens = tokenize(bytes);
    let boxed = parse_boxed(bytes, &tokens).expect("boxed parse");
    let ast = match parse(bytes, tokens) {
        Ok(a) => a,
        Err(e) => panic!("parse error at token {}: expected {}", e.token, e.expected),
    };
    let (nt, nn, nx) = (ast.tokens.tag.len(), ast.nodes.tag.len(), ast.extra.len());
    let mut bs = BoxStats::default();
    boxed.fns.iter().for_each(|f| box_stats(f, &mut bs));
    bs.nodes += 1; // count the program root like the flat root node
    bs.allocs += 1;
    bs.bytes += boxed.fns.len() * size_of::<Box<Node>>();

    println!("source: {} bytes, {} lines, {} tokens, {} nodes, {} extra u32s, {} symbols", bytes.len(), lines, nt, nn, nx, ast.strings.len());
    println!("sizes: token {} B (SoA) vs {} B as a struct; node {NODE_BYTES} B (SoA) vs {} B as a struct; boxed Node = {} B", size_of::<Tok>() + 4, size_of::<(Tok, u32)>(), size_of::<NodeAos>(), size_of::<Node>());
    let node_avg = (NODE_BYTES * nn + 4 * nx) as f64 / nn as f64;
    let box_avg = bs.bytes as f64 / bs.nodes as f64;
    println!("bytes/token {:.2}, bytes/node fixed {NODE_BYTES}, avg incl. extra {node_avg:.2}; nodes/token {:.3}", 5.0, nn as f64 / nt as f64);
    println!("boxed: {} nodes, {} allocations, {:.2} requested B/node (allocator headers not counted)", bs.nodes, bs.allocs, box_avg);

    let r_flat = FlatEval::run(&ast);
    let r_box = BoxEval::run(&boxed);
    let file = serialize(&ast);
    let path = std::env::temp_dir().join("ch11-flat-ast-rust.bin");
    std::fs::write(&path, &file).expect("write");
    let loaded = deserialize(&std::fs::read(&path).expect("read")).expect("decode");
    let r_load = FlatEval::run(&loaded);
    let same = r_flat == r_box && r_flat == r_load;
    println!("eval: flat {r_flat}, boxed {r_box}, loaded from file {r_load}: {}", if same { "match" } else { "MISMATCH" });
    assert!(same, "results differ");
    println!("checksum {r_flat}");

    let t_tok = bench_runs(|| tokenize(black_box(bytes)).tag.len());
    let t_flat = bench_runs(|| {
        let t = tokenize(black_box(bytes));
        parse(bytes, t).map(|a| a.nodes.tag.len()).unwrap_or(0)
    });
    let t_box = bench_runs(|| {
        let t = tokenize(black_box(bytes));
        parse_boxed(bytes, &t).map(|p| p.fns.len()).unwrap_or(0)
    });
    let t_eval_flat = bench_runs(|| FlatEval::run(black_box(&ast)));
    let t_eval_box = bench_runs(|| BoxEval::run(black_box(&boxed)));
    let t_write = bench_runs(|| std::fs::write(&path, serialize(black_box(&ast))).is_ok());
    let t_read = bench_runs(|| deserialize(&std::fs::read(&path).expect("read")).map(|a| a.nodes.tag.len()).unwrap_or(0));
    std::fs::remove_file(&path).ok();

    let ms = |d: Duration| d.as_secs_f64() * 1e3;
    let tput = |d: Duration| (bytes.len() as f64 / d.as_secs_f64() / 1e6, lines as f64 / d.as_secs_f64() / 1e6);
    let (mb_f, ml_f) = tput(t_flat[RUNS / 2]);
    let (mb_b, ml_b) = tput(t_box[RUNS / 2]);
    println!("tokenize only        {:8.3} ms", ms(t_tok[RUNS / 2]));
    println!("flat  tokenize+parse {:8.3} ms  {mb_f:7.1} MB/s  {ml_f:6.2} M lines/s", ms(t_flat[RUNS / 2]));
    println!("boxed tokenize+parse {:8.3} ms  {mb_b:7.1} MB/s  {ml_b:6.2} M lines/s  (incl. freeing the tree)", ms(t_box[RUNS / 2]));
    println!("eval  flat {:8.3} ms, boxed {:8.3} ms", ms(t_eval_flat[RUNS / 2]), ms(t_eval_box[RUNS / 2]));
    println!("file: {} bytes ({:.2}x the source); write {:.3} ms, read+decode {:.3} ms", file.len(), file.len() as f64 / bytes.len() as f64, ms(t_write[RUNS / 2]), ms(t_read[RUNS / 2]));

    emit_bench("ch11-parse", "tokenize only", nt, &t_tok);
    emit_bench("ch11-parse", "flat: tokenize+parse", nt, &t_flat);
    emit_bench("ch11-parse", "boxed: tokenize+parse", nt, &t_box);
    emit_bench("ch11-eval", "flat nodes", nn, &t_eval_flat);
    emit_bench("ch11-eval", "boxed tree", nn, &t_eval_box);
    emit_bench("ch11-file", "write file", file.len(), &t_write);
    emit_bench("ch11-file", "read file", file.len(), &t_read);
    emit_value("ch11-bytes", "token", nt, 5.0, "B");
    emit_value("ch11-bytes", "node, fixed", nn, NODE_BYTES as f64, "B");
    emit_value("ch11-bytes", "node, avg incl. extra", nn, node_avg, "B");
    emit_value("ch11-bytes", "boxed node, avg", nn, box_avg, "B");
    emit_value("ch11-throughput", "flat", nt, ml_f, "M lines/s");
    emit_value("ch11-throughput", "boxed", nt, ml_b, "M lines/s");
}
