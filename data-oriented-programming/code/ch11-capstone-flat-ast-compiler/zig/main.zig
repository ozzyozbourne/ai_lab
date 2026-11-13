// Chapter 11 capstone: a compiler front end the Zig way.
// tokenizer -> MultiArrayList tokens (u8 tag + u32 start) -> Pratt parser -> MultiArrayList nodes
// {tag, main_token, lhs, rhs} plus one `extra: []u32` -> post-order evaluator; a *Node-per-node tree
// from the same tokens as the baseline; and the flat arrays written to a file and viewed in place.
// `zig run -O fast main.zig -- [N tokens] [--quick]`

// ---- harness ----
const std = @import("std");
const Io = std.Io;

const RUNS = 7;

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// Runs `f(ctx)` once to warm up, then RUNS timed times. Returns the sorted timings in ns.
fn benchRuns(io: Io, comptime f: anytype, ctx: anytype) [RUNS]u64 {
    std.mem.doNotOptimizeAway(f(ctx));
    var t: [RUNS]u64 = undefined;
    for (&t) |*slot| {
        const t0 = nowNs(io);
        std.mem.doNotOptimizeAway(f(ctx));
        slot.* = @intCast(nowNs(io) - t0);
    }
    std.mem.sort(u64, &t, {}, std.sort.asc(u64));
    return t;
}

/// Median of RUNS timed runs (after one warm-up run), in ns.
fn bench(io: Io, comptime f: anytype, ctx: anytype) u64 {
    return benchRuns(io, f, ctx)[RUNS / 2];
}

const Args = struct { n: usize, quick: bool };

/// Positional integer N (default 1 << 20) and `--quick` (caps N at 1 << 12).
fn parseArgs(init: std.process.Init) !Args {
    var n: usize = 1 << 20;
    var quick = false;
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--quick")) quick = true else n = try std.fmt.parseInt(usize, a, 10);
    }
    if (quick) n = @min(n, 1 << 12);
    return .{ .n = n, .quick = quick };
}

/// Prints one machine-readable line for bench_all.sh:
/// BENCH {"id":"chNN-x","label":"...","lang":"zig","n":N,"ns":median,"samples":[...]}
/// `runs` must be sorted (as returned by `benchRuns`). Labels must not contain `"` or `\`.
fn emitBench(out: *Io.Writer, id: []const u8, label: []const u8, n: usize, runs: []const u64) !void {
    try out.print("BENCH {{\"id\":\"{s}\",\"label\":\"{s}\",\"lang\":\"zig\",\"n\":{d},\"ns\":{d},\"samples\":[", .{ id, label, n, runs[runs.len / 2] });
    for (runs, 0..) |r, i| try out.print("{s}{d}", .{ if (i == 0) "" else ",", r });
    try out.writeAll("]}\n");
}
// ---- harness ----

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Non-time results (bytes, throughput): "ns" is 0 and "value" carries the number.
fn emitValue(out: *Io.Writer, id: []const u8, label: []const u8, n: usize, value: f64, unit: []const u8) !void {
    try out.print("BENCH {{\"id\":\"{s}\",\"label\":\"{s}\",\"lang\":\"zig\",\"n\":{d},\"ns\":0,\"value\":{d:.3},\"unit\":\"{s}\"}}\n", .{ id, label, n, value, unit });
}

// ======================= tokens: u8 tag + u32 start, in a MultiArrayList =======================

const Tok = enum(u8) {
    eof,
    invalid,
    int,
    ident,
    kw_fn,
    kw_let,
    kw_if,
    kw_else,
    kw_return,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    comma,
    semicolon,
    equal,
    equal_equal,
    plus,
    minus,
    star,
    slash,
    percent,
    less,
};

/// No `end`, no line/column: both are recomputed from `start` when needed.
const Token = struct { tag: Tok, start: u32 };
const TokenList = std.MultiArrayList(Token);
comptime {
    assert(@sizeOf(Token) == 8); // as one struct: padded
    assert(TokenList.capacityInBytes(1) == 5); // as columns: not padded
}

const keywords = std.StaticStringMap(Tok).initComptime(.{
    .{ "fn", .kw_fn }, .{ "let", .kw_let }, .{ "if", .kw_if }, .{ "else", .kw_else }, .{ "return", .kw_return },
});

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn scanIdent(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and isIdent(src[i])) i += 1;
    return i;
}

fn scanDigits(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
    return i;
}

fn tokenize(gpa: Allocator, src: []const u8) Allocator.Error!TokenList {
    var t: TokenList = .empty;
    errdefer t.deinit(gpa);
    try t.ensureTotalCapacity(gpa, src.len / 4 + 1); // ~4 source bytes per token in this language
    var i: usize = 0;
    while (true) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\n' or src[i] == '\t' or src[i] == '\r')) i += 1;
        if (std.mem.startsWith(u8, src[i..], "//")) {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        const start: u32 = @intCast(i);
        if (i == src.len) {
            try t.append(gpa, .{ .tag = .eof, .start = start });
            return t;
        }
        const c = src[i];
        const tag: Tok = switch (c) {
            '0'...'9' => blk: {
                i = scanDigits(src, i);
                break :blk .int;
            },
            'a'...'z', 'A'...'Z', '_' => blk: {
                const end = scanIdent(src, i);
                defer i = end;
                break :blk keywords.get(src[i..end]) orelse .ident;
            },
            else => blk: {
                if (c == '=' and i + 1 < src.len and src[i + 1] == '=') {
                    i += 2;
                    break :blk .equal_equal;
                }
                i += 1;
                break :blk switch (c) {
                    '(' => .l_paren,
                    ')' => .r_paren,
                    '{' => .l_brace,
                    '}' => .r_brace,
                    ',' => .comma,
                    ';' => .semicolon,
                    '=' => .equal,
                    '+' => .plus,
                    '-' => .minus,
                    '*' => .star,
                    '/' => .slash,
                    '%' => .percent,
                    '<' => .less,
                    else => .invalid,
                };
            },
        };
        try t.append(gpa, .{ .tag = tag, .start = start });
    }
}

/// The token's text, recomputed from its tag and start ("calculate instead of store").
fn tokenText(src: []const u8, tag: Tok, start: u32) []const u8 {
    const end = switch (tag) {
        .int => scanDigits(src, start),
        .ident, .kw_fn, .kw_let, .kw_if, .kw_else, .kw_return => scanIdent(src, start),
        .equal_equal => start + 2,
        .eof => start,
        else => start + 1,
    };
    return src[start..end];
}

// ======================= string interning =======================

/// All identifier bytes in one buffer; symbol `s` is `bytes[starts[s]..starts[s + 1]]`.
const Strings = struct {
    bytes: []const u8,
    starts: []const u32,

    fn get(s: Strings, sym: u32) []const u8 {
        return s.bytes[s.starts[sym]..s.starts[sym + 1]];
    }
    fn len(s: Strings) usize {
        return s.starts.len - 1;
    }
    fn find(s: Strings, name: []const u8) ?u32 {
        for (0..s.len()) |i| if (std.mem.eql(u8, s.get(@intCast(i)), name)) return @intCast(i);
        return null;
    }
};

fn fnv1a(s: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (s) |b| h = (h ^ b) *% 0x01000193;
    return h;
}

/// Open addressing over u32 slots (symbol + 1, 0 = empty), FNV-1a, linear probing, load <= 1/2.
/// (The Zig compiler's AstGen does the same with `std.HashMapUnmanaged(u32, void, StringIndexContext, ...)`.)
const Interner = struct {
    bytes: std.ArrayList(u8) = .empty,
    starts: std.ArrayList(u32) = .empty,
    table: []u32 = &.{},

    fn init(gpa: Allocator) Allocator.Error!Interner {
        var in: Interner = .{};
        try in.starts.append(gpa, 0);
        in.table = try gpa.alloc(u32, 1024);
        @memset(in.table, 0);
        return in;
    }
    fn deinit(in: *Interner, gpa: Allocator) void {
        in.bytes.deinit(gpa);
        in.starts.deinit(gpa);
        gpa.free(in.table);
    }
    fn strings(in: *const Interner) Strings {
        return .{ .bytes = in.bytes.items, .starts = in.starts.items };
    }
    fn intern(in: *Interner, gpa: Allocator, s: []const u8) Allocator.Error!u32 {
        const mask = in.table.len - 1;
        var h = fnv1a(s) & mask;
        while (in.table[h] != 0) : (h = (h + 1) & mask) {
            if (std.mem.eql(u8, in.strings().get(in.table[h] - 1), s)) return in.table[h] - 1;
        }
        const sym: u32 = @intCast(in.strings().len());
        try in.bytes.appendSlice(gpa, s);
        try in.starts.append(gpa, @intCast(in.bytes.items.len));
        in.table[h] = sym + 1;
        if (2 * in.strings().len() > in.table.len) try in.grow(gpa);
        return sym;
    }
    fn grow(in: *Interner, gpa: Allocator) Allocator.Error!void {
        const table = try gpa.alloc(u32, in.table.len * 2);
        @memset(table, 0);
        const mask = table.len - 1;
        for (0..in.strings().len()) |sym| {
            var h = fnv1a(in.strings().get(@intCast(sym))) & mask;
            while (table[h] != 0) h = (h + 1) & mask;
            table[h] = @intCast(sym + 1);
        }
        gpa.free(in.table);
        in.table = table;
    }
};

// ======================= flat AST: 13 bytes per node + extra =======================

const Tag = enum(u8) {
    root, // lhs..rhs = extra range of fn_decl nodes
    fn_decl, // main_token = `fn`; lhs = extra index of {name_sym, n_params, param_sym...}; rhs = body
    block_two, // lhs, rhs = first and second statement (0 = none)
    block, // lhs..rhs = extra range of statements (3 or more)
    let_decl, // lhs = name symbol; rhs = initializer
    return_stmt, // lhs = value
    if_simple, // lhs = condition; rhs = then-block
    if_else, // lhs = condition; rhs = extra index of {then, else}
    int_literal, // lhs = value
    identifier, // lhs = symbol
    negate, // lhs = operand
    add,
    sub,
    mul,
    div,
    mod,
    less_than,
    equal_equal, // lhs op rhs
    call_one, // main_token = `(`; lhs = callee identifier; rhs = the argument (0 = none)
    call, // lhs = callee identifier; rhs = extra index of {args_start, args_end}
};

const Node = struct { tag: Tag, main_token: u32, lhs: u32, rhs: u32 };
const NodeList = std.MultiArrayList(Node);
comptime {
    assert(@sizeOf(Node) == 16); // as one struct: padded
    assert(NodeList.capacityInBytes(1) == 13); // as columns: not padded
}

const Ast = struct {
    tokens: TokenList.Slice,
    nodes: NodeList.Slice,
    extra: []u32,
    strings: Strings,
    main_sym: u32, // maxInt(u32) if there is no `main`

    fn deinit(a: *Ast, gpa: Allocator) void {
        a.tokens.deinit(gpa);
        a.nodes.deinit(gpa);
        gpa.free(a.extra);
        gpa.free(a.strings.bytes);
        gpa.free(a.strings.starts);
    }
    fn flat(a: *const Ast) Flat {
        return .{
            .tag = a.nodes.items(.tag),
            .lhs = a.nodes.items(.lhs),
            .rhs = a.nodes.items(.rhs),
            .extra = a.extra,
            .n_symbols = a.strings.len(),
            .main_sym = a.main_sym,
        };
    }
};

const Error = error{ ParseFailed, OutOfMemory };

const BinOp = struct { prec: u8, tag: Tag };

fn binaryOp(t: Tok) ?BinOp {
    return switch (t) {
        .equal_equal => .{ .prec = 1, .tag = .equal_equal },
        .less => .{ .prec = 2, .tag = .less_than },
        .plus => .{ .prec = 3, .tag = .add },
        .minus => .{ .prec = 3, .tag = .sub },
        .star => .{ .prec = 4, .tag = .mul },
        .slash => .{ .prec = 4, .tag = .div },
        .percent => .{ .prec = 4, .tag = .mod },
        else => null,
    };
}

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    tags: []const Tok,
    starts: []const u32,
    i: u32 = 0,
    nodes: NodeList = .empty,
    extra: std.ArrayList(u32) = .empty,
    scratch: std.ArrayList(u32) = .empty,
    interner: Interner,
    err_token: u32 = 0,
    expected: []const u8 = "",

    fn peek(p: *const Parser) Tok {
        return p.tags[p.i];
    }
    fn next(p: *Parser) u32 {
        p.i += 1;
        return p.i - 1;
    }
    fn fail(p: *Parser, expected: []const u8) error{ParseFailed} {
        p.err_token = p.i;
        p.expected = expected;
        return error.ParseFailed;
    }
    fn expect(p: *Parser, t: Tok, expected: []const u8) Error!u32 {
        return if (p.peek() == t) p.next() else p.fail(expected);
    }
    fn internToken(p: *Parser, tok: u32) Error!u32 {
        return p.interner.intern(p.gpa, tokenText(p.src, .ident, p.starts[tok]));
    }
    fn add(p: *Parser, tag: Tag, main_token: u32, lhs: u32, rhs: u32) Error!u32 {
        try p.nodes.append(p.gpa, .{ .tag = tag, .main_token = main_token, .lhs = lhs, .rhs = rhs });
        return @intCast(p.nodes.len - 1);
    }
    /// Moves scratch[top..] into `extra` and returns the range: lists are built in one shared
    /// scratch stack, then copied once into their final, contiguous place.
    fn listToExtra(p: *Parser, top: usize) Error![2]u32 {
        const start: u32 = @intCast(p.extra.items.len);
        try p.extra.appendSlice(p.gpa, p.scratch.items[top..]);
        p.scratch.shrinkRetainingCapacity(top);
        return .{ start, @intCast(p.extra.items.len) };
    }

    fn parseRoot(p: *Parser) Error!void {
        _ = try p.add(.root, 0, 0, 0); // node 0, so index 0 can mean "none" everywhere else
        const top = p.scratch.items.len;
        while (p.peek() != .eof) {
            const f = try p.parseFn();
            try p.scratch.append(p.gpa, f);
        }
        const r = try p.listToExtra(top);
        p.nodes.items(.lhs)[0] = r[0];
        p.nodes.items(.rhs)[0] = r[1];
    }

    fn parseFn(p: *Parser) Error!u32 {
        const fn_tok = try p.expect(.kw_fn, "`fn`");
        const name = try p.internToken(try p.expect(.ident, "function name"));
        _ = try p.expect(.l_paren, "`(`");
        const top = p.scratch.items.len;
        if (p.peek() != .r_paren) while (true) {
            const sym = try p.internToken(try p.expect(.ident, "parameter name"));
            try p.scratch.append(p.gpa, sym);
            if (p.peek() != .comma) break;
            _ = p.next();
        };
        _ = try p.expect(.r_paren, "`)`");
        const proto: u32 = @intCast(p.extra.items.len);
        const n_params: u32 = @intCast(p.scratch.items.len - top);
        try p.extra.appendSlice(p.gpa, &.{ name, n_params });
        _ = try p.listToExtra(top);
        const body = try p.parseBlock();
        return p.add(.fn_decl, fn_tok, proto, body);
    }

    fn parseBlock(p: *Parser) Error!u32 {
        const lbrace = try p.expect(.l_brace, "`{`");
        const top = p.scratch.items.len;
        while (p.peek() != .r_brace) {
            const s = try p.parseStmt();
            try p.scratch.append(p.gpa, s);
        }
        _ = p.next();
        const stmts = p.scratch.items[top..];
        if (stmts.len <= 2) {
            const a = if (stmts.len > 0) stmts[0] else 0;
            const b = if (stmts.len > 1) stmts[1] else 0;
            p.scratch.shrinkRetainingCapacity(top);
            return p.add(.block_two, lbrace, a, b);
        }
        const r = try p.listToExtra(top);
        return p.add(.block, lbrace, r[0], r[1]);
    }

    fn parseStmt(p: *Parser) Error!u32 {
        switch (p.peek()) {
            .kw_let => {
                const let_tok = p.next();
                const sym = try p.internToken(try p.expect(.ident, "variable name"));
                _ = try p.expect(.equal, "`=`");
                const init_expr = try p.parseExpr(0);
                _ = try p.expect(.semicolon, "`;`");
                return p.add(.let_decl, let_tok, sym, init_expr);
            },
            .kw_return => {
                const ret = p.next();
                const value = try p.parseExpr(0);
                _ = try p.expect(.semicolon, "`;`");
                return p.add(.return_stmt, ret, value, 0);
            },
            .kw_if => return p.parseIf(),
            .eof => return p.fail("`}`"),
            else => {
                const e = try p.parseExpr(0);
                _ = try p.expect(.semicolon, "`;`");
                return e;
            },
        }
    }

    fn parseIf(p: *Parser) Error!u32 {
        const if_tok = p.next();
        const cond = try p.parseExpr(0);
        const then = try p.parseBlock();
        if (p.peek() != .kw_else) return p.add(.if_simple, if_tok, cond, then);
        _ = p.next();
        const els = if (p.peek() == .kw_if) try p.parseIf() else try p.parseBlock();
        const x: u32 = @intCast(p.extra.items.len);
        try p.extra.appendSlice(p.gpa, &.{ then, els });
        return p.add(.if_else, if_tok, cond, x);
    }

    /// Pratt loop: operators that bind tighter than `min_prec` extend the left operand.
    fn parseExpr(p: *Parser, min_prec: u8) Error!u32 {
        var lhs = try p.parsePrefix();
        while (binaryOp(p.peek())) |op| {
            if (op.prec <= min_prec) break;
            const tok = p.next();
            const rhs = try p.parseExpr(op.prec);
            lhs = try p.add(op.tag, tok, lhs, rhs);
        }
        return lhs;
    }

    fn parsePrefix(p: *Parser) Error!u32 {
        switch (p.peek()) {
            .int => {
                const t = p.next();
                const v = std.fmt.parseInt(u32, tokenText(p.src, .int, p.starts[t]), 10) catch {
                    p.i = t;
                    return p.fail("integer below 2^32");
                };
                return p.add(.int_literal, t, v, 0);
            },
            .ident => {
                const t = p.next();
                const id = try p.add(.identifier, t, try p.internToken(t), 0);
                return if (p.peek() == .l_paren) p.parseCall(id) else id;
            },
            .l_paren => {
                _ = p.next();
                const e = try p.parseExpr(0);
                _ = try p.expect(.r_paren, "`)`");
                return e; // no node for parentheses: the tree shape already says it
            },
            .minus => {
                const t = p.next();
                const operand = try p.parsePrefix();
                return p.add(.negate, t, operand, 0);
            },
            else => return p.fail("expression"),
        }
    }

    /// Two encodings of one construct: `f()` and `f(x)` fit in the node; `f(x, y, ...)` spills to extra.
    fn parseCall(p: *Parser, callee: u32) Error!u32 {
        const lparen = p.next();
        const top = p.scratch.items.len;
        if (p.peek() != .r_paren) while (true) {
            const a = try p.parseExpr(0);
            try p.scratch.append(p.gpa, a);
            if (p.peek() != .comma) break;
            _ = p.next();
        };
        _ = try p.expect(.r_paren, "`)`");
        if (p.scratch.items.len - top <= 1) {
            const arg = if (p.scratch.items.len > top) p.scratch.items[top] else 0;
            p.scratch.shrinkRetainingCapacity(top);
            return p.add(.call_one, lparen, callee, arg);
        }
        const r = try p.listToExtra(top);
        const range: u32 = @intCast(p.extra.items.len);
        try p.extra.appendSlice(p.gpa, &r);
        return p.add(.call, lparen, callee, range);
    }
};

/// Takes ownership of the tokens: the AST owns them, as std.zig.Ast does.
fn parse(gpa: Allocator, src: []const u8, tokens_in: TokenList, err: ?*Parser) Error!Ast {
    var tokens = tokens_in;
    errdefer tokens.deinit(gpa);
    var p: Parser = .{ .gpa = gpa, .src = src, .tags = tokens.items(.tag), .starts = tokens.items(.start), .interner = try .init(gpa) };
    defer p.scratch.deinit(gpa);
    errdefer {
        p.nodes.deinit(gpa);
        p.extra.deinit(gpa);
        p.interner.deinit(gpa);
        if (err) |e| e.* = p;
    }
    try p.nodes.ensureTotalCapacity(gpa, tokens.len * 2 / 3 + 1); // about 0.63 nodes per token here
    try p.parseRoot();
    gpa.free(p.interner.table);
    p.interner.table = &.{};
    const strings: Strings = .{ .bytes = try p.interner.bytes.toOwnedSlice(gpa), .starts = try p.interner.starts.toOwnedSlice(gpa) };
    return .{
        .tokens = tokens.toOwnedSlice(),
        .nodes = p.nodes.toOwnedSlice(),
        .extra = try p.extra.toOwnedSlice(gpa),
        .strings = strings,
        .main_sym = strings.find("main") orelse std.math.maxInt(u32),
    };
}

// ======================= evaluator over the flat nodes =======================

/// Integer semantics shared by both evaluators: wrapping i64; x / 0 = 0 and x % 0 = 0.
fn apply(op: Tag, a: i64, b: i64) i64 {
    return switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .div => if (b == 0) 0 else if (b == -1) 0 -% a else @divTrunc(a, b),
        .mod => if (b == 0 or b == -1) 0 else @rem(a, b),
        .less_than => @intFromBool(a < b),
        .equal_equal => @intFromBool(a == b),
        else => unreachable,
    };
}

/// Variables live on one stack of (symbol, value); a call sees only its own frame (vars[base..]).
const Env = struct {
    const Var = struct { sym: u32, val: i64 };
    vars: std.ArrayList(Var) = .empty,
    base: usize = 0,
    args: std.ArrayList(i64) = .empty,

    fn deinit(e: *Env, gpa: Allocator) void {
        e.vars.deinit(gpa);
        e.args.deinit(gpa);
    }
    fn lookup(e: *const Env, sym: u32) i64 {
        var k = e.vars.items.len;
        while (k > e.base) {
            k -= 1;
            if (e.vars.items[k].sym == sym) return e.vars.items[k].val;
        }
        return 0;
    }
};

/// What the evaluator needs: plain column slices. They can come from a parsed Ast or from a file.
const Flat = struct {
    tag: []const Tag,
    lhs: []const u32,
    rhs: []const u32,
    extra: []const u32,
    n_symbols: usize,
    main_sym: u32,
};

const FlatEval = struct {
    gpa: Allocator,
    f: Flat,
    fns: []u32, // symbol -> fn_decl node (0 = none)
    env: Env = .{},

    fn run(gpa: Allocator, f: Flat) Allocator.Error!i64 {
        var e: FlatEval = .{ .gpa = gpa, .f = f, .fns = try gpa.alloc(u32, f.n_symbols) };
        defer gpa.free(e.fns);
        defer e.env.deinit(gpa);
        @memset(e.fns, 0);
        for (f.extra[f.lhs[0]..f.rhs[0]]) |fd| e.fns[f.extra[f.lhs[fd]]] = fd;
        return e.callSym(f.main_sym, 0);
    }

    fn callSym(e: *FlatEval, sym: u32, nargs: usize) Allocator.Error!i64 {
        const first = e.env.args.items.len - nargs;
        const fd = if (sym < e.fns.len) e.fns[sym] else 0;
        if (fd == 0) {
            e.env.args.shrinkRetainingCapacity(first);
            return 0;
        }
        const proto = e.f.lhs[fd];
        const n_params = e.f.extra[proto + 1];
        const saved = e.env.base;
        const base = e.env.vars.items.len;
        for (0..@min(n_params, nargs)) |k| {
            try e.env.vars.append(e.gpa, .{ .sym = e.f.extra[proto + 2 + k], .val = e.env.args.items[first + k] });
        }
        e.env.args.shrinkRetainingCapacity(first);
        e.env.base = base;
        const r = (try e.exec(e.f.rhs[fd])) orelse 0;
        e.env.vars.shrinkRetainingCapacity(base);
        e.env.base = saved;
        return r;
    }

    /// Statements: a value means `return value` happened.
    fn exec(e: *FlatEval, n: u32) Allocator.Error!?i64 {
        const l = e.f.lhs[n];
        const r = e.f.rhs[n];
        switch (e.f.tag[n]) {
            .block_two => return e.execList(&.{ l, r }),
            .block => return e.execList(e.f.extra[l..r]),
            .let_decl => {
                const v = try e.eval(r);
                try e.env.vars.append(e.gpa, .{ .sym = l, .val = v });
                return null;
            },
            .return_stmt => return try e.eval(l),
            .if_simple => return if (try e.eval(l) != 0) e.exec(r) else null,
            .if_else => return if (try e.eval(l) != 0) e.exec(e.f.extra[r]) else e.exec(e.f.extra[r + 1]),
            else => {
                _ = try e.eval(n);
                return null;
            },
        }
    }

    fn execList(e: *FlatEval, stmts: []const u32) Allocator.Error!?i64 {
        const mark = e.env.vars.items.len;
        defer e.env.vars.shrinkRetainingCapacity(mark);
        for (stmts) |s| {
            if (s == 0) break;
            if (try e.exec(s)) |v| return v;
        }
        return null;
    }

    /// Expressions, children first (post-order).
    fn eval(e: *FlatEval, n: u32) Allocator.Error!i64 {
        const l = e.f.lhs[n];
        const r = e.f.rhs[n];
        switch (e.f.tag[n]) {
            .int_literal => return l,
            .identifier => return e.env.lookup(l),
            .negate => return 0 -% try e.eval(l),
            .call_one => {
                if (r != 0) try e.env.args.append(e.gpa, try e.eval(r));
                return e.callSym(e.f.lhs[l], @intFromBool(r != 0));
            },
            .call => {
                const s = e.f.extra[r];
                const end = e.f.extra[r + 1];
                for (e.f.extra[s..end]) |a| try e.env.args.append(e.gpa, try e.eval(a));
                return e.callSym(e.f.lhs[l], end - s);
            },
            else => |op| {
                const a = try e.eval(l);
                const b = try e.eval(r);
                return apply(op, a, b);
            },
        }
    }
};

// ======================= baseline: one heap allocation per node =======================

/// `token` is each node's source location (the flat tree's `main_token`).
const BNode = union(enum) {
    int: struct { token: u32, value: i64 },
    ident: struct { token: u32, sym: u32 },
    negate: struct { token: u32, operand: *BNode },
    binary: struct { token: u32, op: Tag, lhs: *BNode, rhs: *BNode },
    call: struct { token: u32, callee: u32, args: []*BNode },
    let: struct { token: u32, sym: u32, init: *BNode },
    ret: struct { token: u32, value: *BNode },
    @"if": struct { token: u32, cond: *BNode, then: *BNode, els: ?*BNode },
    block: struct { token: u32, stmts: []*BNode },
    @"fn": struct { token: u32, name: u32, params: []u32, body: *BNode },
};

const BoxProgram = struct {
    fns: []*BNode,
    n_symbols: usize,
    main_sym: u32,

    fn deinit(p: *BoxProgram, gpa: Allocator) void {
        for (p.fns) |f| destroyTree(gpa, f);
        gpa.free(p.fns);
    }
};

fn destroyTree(gpa: Allocator, n: *BNode) void {
    switch (n.*) {
        .int, .ident => {},
        .negate => |x| destroyTree(gpa, x.operand),
        .binary => |x| {
            destroyTree(gpa, x.lhs);
            destroyTree(gpa, x.rhs);
        },
        .call => |x| {
            for (x.args) |a| destroyTree(gpa, a);
            gpa.free(x.args);
        },
        .let => |x| destroyTree(gpa, x.init),
        .ret => |x| destroyTree(gpa, x.value),
        .@"if" => |x| {
            destroyTree(gpa, x.cond);
            destroyTree(gpa, x.then);
            if (x.els) |e| destroyTree(gpa, e);
        },
        .block => |x| {
            for (x.stmts) |s| destroyTree(gpa, s);
            gpa.free(x.stmts);
        },
        .@"fn" => |x| {
            gpa.free(x.params);
            destroyTree(gpa, x.body);
        },
    }
    gpa.destroy(n);
}

/// Same grammar, same tokens, same interner; only the tree representation differs.
/// (On a parse error the partial tree leaks; the generated input always parses.)
const BoxParser = struct {
    gpa: Allocator,
    src: []const u8,
    tags: []const Tok,
    starts: []const u32,
    i: u32 = 0,
    interner: Interner,

    fn peek(p: *const BoxParser) Tok {
        return p.tags[p.i];
    }
    fn next(p: *BoxParser) u32 {
        p.i += 1;
        return p.i - 1;
    }
    fn expect(p: *BoxParser, t: Tok) Error!u32 {
        return if (p.peek() == t) p.next() else error.ParseFailed;
    }
    fn internToken(p: *BoxParser, tok: u32) Error!u32 {
        return p.interner.intern(p.gpa, tokenText(p.src, .ident, p.starts[tok]));
    }
    fn new(p: *BoxParser, n: BNode) Error!*BNode {
        const b = try p.gpa.create(BNode);
        b.* = n;
        return b;
    }

    fn parseFn(p: *BoxParser) Error!*BNode {
        const token = try p.expect(.kw_fn);
        const name = try p.internToken(try p.expect(.ident));
        _ = try p.expect(.l_paren);
        var params: std.ArrayList(u32) = .empty;
        if (p.peek() != .r_paren) while (true) {
            try params.append(p.gpa, try p.internToken(try p.expect(.ident)));
            if (p.peek() != .comma) break;
            _ = p.next();
        };
        _ = try p.expect(.r_paren);
        const body = try p.parseBlock();
        return p.new(.{ .@"fn" = .{ .token = token, .name = name, .params = try params.toOwnedSlice(p.gpa), .body = body } });
    }

    fn parseBlock(p: *BoxParser) Error!*BNode {
        const token = try p.expect(.l_brace);
        var stmts: std.ArrayList(*BNode) = .empty;
        while (p.peek() != .r_brace) try stmts.append(p.gpa, try p.parseStmt());
        _ = p.next();
        return p.new(.{ .block = .{ .token = token, .stmts = try stmts.toOwnedSlice(p.gpa) } });
    }

    fn parseStmt(p: *BoxParser) Error!*BNode {
        switch (p.peek()) {
            .kw_let => {
                const token = p.next();
                const sym = try p.internToken(try p.expect(.ident));
                _ = try p.expect(.equal);
                const init_expr = try p.parseExpr(0);
                _ = try p.expect(.semicolon);
                return p.new(.{ .let = .{ .token = token, .sym = sym, .init = init_expr } });
            },
            .kw_return => {
                const token = p.next();
                const value = try p.parseExpr(0);
                _ = try p.expect(.semicolon);
                return p.new(.{ .ret = .{ .token = token, .value = value } });
            },
            .kw_if => return p.parseIf(),
            .eof => return error.ParseFailed,
            else => {
                const e = try p.parseExpr(0);
                _ = try p.expect(.semicolon);
                return e;
            },
        }
    }

    fn parseIf(p: *BoxParser) Error!*BNode {
        const token = p.next();
        const cond = try p.parseExpr(0);
        const then = try p.parseBlock();
        var els: ?*BNode = null;
        if (p.peek() == .kw_else) {
            _ = p.next();
            els = if (p.peek() == .kw_if) try p.parseIf() else try p.parseBlock();
        }
        return p.new(.{ .@"if" = .{ .token = token, .cond = cond, .then = then, .els = els } });
    }

    fn parseExpr(p: *BoxParser, min_prec: u8) Error!*BNode {
        var lhs = try p.parsePrefix();
        while (binaryOp(p.peek())) |op| {
            if (op.prec <= min_prec) break;
            const token = p.next();
            const rhs = try p.parseExpr(op.prec);
            lhs = try p.new(.{ .binary = .{ .token = token, .op = op.tag, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parsePrefix(p: *BoxParser) Error!*BNode {
        switch (p.peek()) {
            .int => {
                const token = p.next();
                const v = std.fmt.parseInt(u32, tokenText(p.src, .int, p.starts[token]), 10) catch return error.ParseFailed;
                return p.new(.{ .int = .{ .token = token, .value = v } });
            },
            .ident => {
                const token = p.next();
                const sym = try p.internToken(token);
                if (p.peek() != .l_paren) return p.new(.{ .ident = .{ .token = token, .sym = sym } });
                const lparen = p.next();
                var args: std.ArrayList(*BNode) = .empty;
                if (p.peek() != .r_paren) while (true) {
                    try args.append(p.gpa, try p.parseExpr(0));
                    if (p.peek() != .comma) break;
                    _ = p.next();
                };
                _ = try p.expect(.r_paren);
                return p.new(.{ .call = .{ .token = lparen, .callee = sym, .args = try args.toOwnedSlice(p.gpa) } });
            },
            .l_paren => {
                _ = p.next();
                const e = try p.parseExpr(0);
                _ = try p.expect(.r_paren);
                return e;
            },
            .minus => {
                const token = p.next();
                const operand = try p.parsePrefix();
                return p.new(.{ .negate = .{ .token = token, .operand = operand } });
            },
            else => return error.ParseFailed,
        }
    }
};

fn parseBoxed(gpa: Allocator, src: []const u8, tokens: *const TokenList) Error!BoxProgram {
    var p: BoxParser = .{ .gpa = gpa, .src = src, .tags = tokens.items(.tag), .starts = tokens.items(.start), .interner = try .init(gpa) };
    defer p.interner.deinit(gpa);
    var fns: std.ArrayList(*BNode) = .empty;
    while (p.peek() != .eof) try fns.append(gpa, try p.parseFn());
    return .{
        .fns = try fns.toOwnedSlice(gpa),
        .n_symbols = p.interner.strings().len(),
        .main_sym = p.interner.strings().find("main") orelse std.math.maxInt(u32),
    };
}

/// Counts nodes, allocations and requested heap bytes (allocator headers not included).
const BoxStats = struct {
    nodes: usize = 0,
    allocs: usize = 0,
    bytes: usize = 0,

    fn list(s: *BoxStats, len: usize, elem: usize) void {
        if (len > 0) {
            s.allocs += 1;
            s.bytes += len * elem;
        }
    }
    fn walk(s: *BoxStats, n: *const BNode) void {
        s.nodes += 1;
        s.allocs += 1;
        s.bytes += @sizeOf(BNode);
        switch (n.*) {
            .int, .ident => {},
            .call => |x| {
                s.list(x.args.len, @sizeOf(*BNode));
                for (x.args) |a| s.walk(a);
            },
            .block => |x| {
                s.list(x.stmts.len, @sizeOf(*BNode));
                for (x.stmts) |a| s.walk(a);
            },
            .@"fn" => |x| {
                s.list(x.params.len, @sizeOf(u32));
                s.walk(x.body);
            },
            .negate => |x| s.walk(x.operand),
            .let => |x| s.walk(x.init),
            .ret => |x| s.walk(x.value),
            .binary => |x| {
                s.walk(x.lhs);
                s.walk(x.rhs);
            },
            .@"if" => |x| {
                s.walk(x.cond);
                s.walk(x.then);
                if (x.els) |e| s.walk(e);
            },
        }
    }
};

const BoxEval = struct {
    gpa: Allocator,
    fns: []?*const BNode,
    env: Env = .{},

    fn run(gpa: Allocator, p: *const BoxProgram) Allocator.Error!i64 {
        var e: BoxEval = .{ .gpa = gpa, .fns = try gpa.alloc(?*const BNode, p.n_symbols) };
        defer gpa.free(e.fns);
        defer e.env.deinit(gpa);
        @memset(e.fns, null);
        for (p.fns) |f| e.fns[f.@"fn".name] = f;
        return e.callSym(p.main_sym, 0);
    }

    fn callSym(e: *BoxEval, sym: u32, nargs: usize) Allocator.Error!i64 {
        const first = e.env.args.items.len - nargs;
        const f = (if (sym < e.fns.len) e.fns[sym] else null) orelse {
            e.env.args.shrinkRetainingCapacity(first);
            return 0;
        };
        const saved = e.env.base;
        const base = e.env.vars.items.len;
        for (f.@"fn".params[0..@min(f.@"fn".params.len, nargs)], 0..) |sym_p, k| {
            try e.env.vars.append(e.gpa, .{ .sym = sym_p, .val = e.env.args.items[first + k] });
        }
        e.env.args.shrinkRetainingCapacity(first);
        e.env.base = base;
        const r = (try e.exec(f.@"fn".body)) orelse 0;
        e.env.vars.shrinkRetainingCapacity(base);
        e.env.base = saved;
        return r;
    }

    fn exec(e: *BoxEval, n: *const BNode) Allocator.Error!?i64 {
        switch (n.*) {
            .block => |x| {
                const mark = e.env.vars.items.len;
                defer e.env.vars.shrinkRetainingCapacity(mark);
                for (x.stmts) |s| if (try e.exec(s)) |v| return v;
                return null;
            },
            .let => |x| {
                const v = try e.eval(x.init);
                try e.env.vars.append(e.gpa, .{ .sym = x.sym, .val = v });
                return null;
            },
            .ret => |x| return try e.eval(x.value),
            .@"if" => |x| {
                if (try e.eval(x.cond) != 0) return e.exec(x.then);
                return if (x.els) |els| e.exec(els) else null;
            },
            else => {
                _ = try e.eval(n);
                return null;
            },
        }
    }

    fn eval(e: *BoxEval, n: *const BNode) Allocator.Error!i64 {
        return switch (n.*) {
            .int => |x| x.value,
            .ident => |x| e.env.lookup(x.sym),
            .negate => |x| 0 -% try e.eval(x.operand),
            .binary => |x| blk: {
                const a = try e.eval(x.lhs);
                const b = try e.eval(x.rhs);
                break :blk apply(x.op, a, b);
            },
            .call => |x| blk: {
                for (x.args) |a| try e.env.args.append(e.gpa, try e.eval(a));
                break :blk e.callSym(x.callee, x.args.len);
            },
            else => 0,
        };
    }
};

// ======================= seeded generator (byte-identical in all three languages) =======================

/// splitmix64: the same sequence in all three languages.
const Rng = struct {
    state: u64,
    fn next(r: *Rng) u64 {
        r.state +%= 0x9E3779B97F4A7C15;
        var z = r.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
    fn below(r: *Rng, n: usize) usize {
        return @intCast(r.next() % n);
    }
};

const OPS = [_][]const u8{ "+", "-", "*", "/", "%", "<", "==" };
const PARAMS = [_][]const u8{ "a", "b", "c" };

/// Function i has level i % 3 and may call only functions one or two below it, so the call graph is a DAG
/// and evaluation does a bounded amount of work per function.
const Gen = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    rng: Rng,
    tokens: usize = 0,
    arity: std.ArrayList(usize) = .empty,
    vars: std.ArrayList(usize) = .empty, // 0..3 = params a b c, 3 + k = v{k}
    next_let: usize = 0,
    calls_left: usize = 0,
    cur: usize = 0,

    fn t(g: *Gen, s: []const u8) !void {
        try g.out.appendSlice(g.gpa, s);
        g.tokens += 1;
    }
    fn tf(g: *Gen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.gpa, fmt, args);
        g.tokens += 1;
    }
    fn raw(g: *Gen, s: []const u8) !void {
        try g.out.appendSlice(g.gpa, s);
    }
    fn ind(g: *Gen, k: usize) !void {
        for (0..k) |_| try g.raw("    ");
    }
    fn variable(g: *Gen, id: usize) !void {
        if (id < 3) try g.t(PARAMS[id]) else try g.tf("v{d}", .{id - 3});
    }

    fn func(g: *Gen, i: usize) !void {
        const p = 1 + g.rng.below(3);
        try g.arity.append(g.gpa, p);
        g.vars.clearRetainingCapacity();
        g.next_let = 0;
        g.calls_left = if (i % 3 == 0) 0 else 2;
        g.cur = i;
        try g.t("fn");
        try g.raw(" ");
        try g.tf("f{d}", .{i});
        try g.t("(");
        for (PARAMS[0..p], 0..) |name, k| {
            if (k > 0) {
                try g.t(",");
                try g.raw(" ");
            }
            try g.t(name);
            try g.vars.append(g.gpa, k);
        }
        try g.t(")");
        try g.raw(" ");
        try g.t("{");
        try g.raw("\n");
        const n = 2 + g.rng.below(3);
        for (0..n) |_| try g.stmt(1, 1);
        try g.ind(1);
        try g.t("return");
        try g.raw(" ");
        try g.expr(3);
        try g.t(";");
        try g.raw("\n");
        try g.t("}");
        try g.raw("\n\n");
    }

    fn stmt(g: *Gen, indent: usize, nest: usize) anyerror!void {
        const r = g.rng.below(10);
        try g.ind(indent);
        if (r < 6 or nest >= 3 or (r == 9 and g.calls_left == 0)) {
            const id = 3 + g.next_let;
            g.next_let += 1;
            try g.t("let");
            try g.raw(" ");
            try g.variable(id);
            try g.raw(" ");
            try g.t("=");
            try g.raw(" ");
            try g.expr(3);
            try g.t(";");
            try g.raw("\n");
            try g.vars.append(g.gpa, id);
        } else if (r < 9) {
            try g.t("if");
            try g.raw(" ");
            try g.expr(2);
            try g.raw(" ");
            try g.t("{");
            try g.raw("\n");
            try g.block(indent + 1, nest + 1);
            try g.ind(indent);
            try g.t("}");
            if (g.rng.below(2) == 0) {
                try g.raw(" ");
                try g.t("else");
                try g.raw(" ");
                try g.t("{");
                try g.raw("\n");
                try g.block(indent + 1, nest + 1);
                try g.ind(indent);
                try g.t("}");
            }
            try g.raw("\n");
        } else {
            try g.call();
            try g.t(";");
            try g.raw("\n");
        }
    }

    fn block(g: *Gen, indent: usize, nest: usize) anyerror!void {
        const mark = g.vars.items.len;
        const n = 1 + g.rng.below(2);
        for (0..n) |_| try g.stmt(indent, nest);
        if (g.rng.below(3) == 0) {
            try g.ind(indent);
            try g.t("return");
            try g.raw(" ");
            try g.expr(2);
            try g.t(";");
            try g.raw("\n");
        }
        g.vars.shrinkRetainingCapacity(mark);
    }

    fn expr(g: *Gen, depth: usize) anyerror!void {
        if (depth == 0 or g.rng.below(3) == 0) return g.atom();
        switch (g.rng.below(10)) {
            0 => {
                try g.t("-");
                try g.expr(depth - 1);
            },
            1 => {
                try g.t("(");
                try g.expr(depth - 1);
                try g.t(")");
            },
            else => {
                try g.expr(depth - 1);
                try g.raw(" ");
                try g.t(OPS[g.rng.below(OPS.len)]);
                try g.raw(" ");
                try g.expr(depth - 1);
            },
        }
    }

    fn atom(g: *Gen) anyerror!void {
        const r = g.rng.below(10);
        if (g.calls_left > 0 and r < 2) {
            try g.call();
        } else if (r < 6) {
            try g.variable(g.vars.items[g.rng.below(g.vars.items.len)]);
        } else {
            try g.tf("{d}", .{g.rng.below(100)});
        }
    }

    fn call(g: *Gen) anyerror!void {
        g.calls_left -= 1;
        const j = g.cur - 1 - g.rng.below(g.cur % 3);
        try g.tf("f{d}", .{j});
        try g.t("(");
        for (0..g.arity.items[j]) |k| {
            if (k > 0) {
                try g.t(",");
                try g.raw(" ");
            }
            try g.expr(1);
        }
        try g.t(")");
    }
};

/// About `n_tokens` tokens of functions, then a `main` that calls each one and folds the results.
fn generate(gpa: Allocator, n_tokens: usize, seed: u64) ![]u8 {
    var g: Gen = .{ .gpa = gpa, .rng = .{ .state = seed } };
    defer g.arity.deinit(gpa);
    defer g.vars.deinit(gpa);
    errdefer g.out.deinit(gpa);
    var i: usize = 0;
    while (i == 0 or g.tokens < n_tokens) : (i += 1) try g.func(i);
    try g.raw("fn main() {\n    let acc = 0;\n");
    g.tokens += 10;
    for (0..i) |j| {
        try g.ind(1);
        try g.out.print(gpa, "let acc = acc * 3 + f{d}(", .{j});
        g.tokens += 9;
        for (0..g.arity.items[j]) |k| {
            if (k > 0) {
                try g.t(",");
                try g.raw(" ");
            }
            try g.tf("{d}", .{g.rng.below(100)});
        }
        try g.t(")");
        try g.t(";");
        try g.raw("\n");
    }
    try g.raw("    return acc;\n}\n");
    g.tokens += 4;
    return g.out.toOwnedSlice(gpa);
}

// ======================= zero-copy serialization =======================
// File: 8 x u32 header, then each column. u8 columns are padded to 4 bytes so every u32 column starts
// 4-byte aligned. Native (little-endian) byte order. Writing is one vectored write of the columns as
// they sit in memory; reading is one read into a u32-aligned buffer and slices that point into it.

const MAGIC: u32 = 0x31415344; // "DSA1"
const zeros = [4]u8{ 0, 0, 0, 0 };

fn pad4(n: usize) []const u8 {
    return zeros[0 .. (4 - n % 4) % 4];
}

fn writeAst(io: Io, ast: *const Ast, path: []const u8) !void {
    const s = ast.strings;
    const header = [8]u32{
        MAGIC,                 @intCast(ast.tokens.len), @intCast(ast.nodes.len), @intCast(ast.extra.len),
        @intCast(s.bytes.len), @intCast(s.len()),        ast.main_sym,            0,
    };
    const tok_tags: []const u8 = @ptrCast(ast.tokens.items(.tag));
    const node_tags: []const u8 = @ptrCast(ast.nodes.items(.tag));
    var vecs = [_][]const u8{
        std.mem.sliceAsBytes(&header),
        tok_tags,
        pad4(tok_tags.len),
        std.mem.sliceAsBytes(ast.tokens.items(.start)),
        node_tags,
        pad4(node_tags.len),
        std.mem.sliceAsBytes(ast.nodes.items(.main_token)),
        std.mem.sliceAsBytes(ast.nodes.items(.lhs)),
        std.mem.sliceAsBytes(ast.nodes.items(.rhs)),
        std.mem.sliceAsBytes(ast.extra),
        s.bytes,
        pad4(s.bytes.len),
        std.mem.sliceAsBytes(s.starts),
    };
    var file = try Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeVecAll(&vecs);
    try fw.interface.flush();
}

/// A loaded file: every slice points into `buf`. Nothing is decoded or copied after the read.
const Loaded = struct {
    buf: []align(4) u8,
    tok_tags: []const Tok,
    tok_starts: []const u32,
    main_token: []const u32,
    flat: Flat,
};

const Cursor = struct {
    b: []align(4) const u8,
    at: usize = 0,

    fn bytes(c: *Cursor, n: usize) ![]align(4) const u8 {
        if (c.at > c.b.len or n > c.b.len - c.at) return error.FileTooShort;
        const s: []align(4) const u8 = @alignCast(c.b[c.at..][0..n]);
        c.at = std.mem.alignForward(usize, c.at + n, 4);
        return s;
    }
    fn words(c: *Cursor, n: usize) ![]const u32 {
        return std.mem.bytesAsSlice(u32, try c.bytes(4 * n));
    }
    /// Checks every byte before the bytes are viewed as an exhaustive enum.
    fn tags(c: *Cursor, comptime T: type, n: usize) ![]const T {
        const raw = try c.bytes(n);
        for (raw) |b| if (b >= @typeInfo(T).@"enum".field_names.len) return error.BadTag;
        return @ptrCast(raw);
    }
};

fn loadAst(gpa: Allocator, io: Io, path: []const u8) !Loaded {
    const buf = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u32), null);
    errdefer gpa.free(buf);
    var c: Cursor = .{ .b = buf };
    const h = try c.words(8);
    if (h[0] != MAGIC) return error.BadMagic;
    const tok_tags = try c.tags(Tok, h[1]);
    const tok_starts = try c.words(h[1]);
    const tag = try c.tags(Tag, h[2]);
    const main_token = try c.words(h[2]);
    const lhs = try c.words(h[2]);
    const rhs = try c.words(h[2]);
    const extra = try c.words(h[3]);
    _ = try c.bytes(h[4]); // string bytes
    _ = try c.words(h[5] + 1); // string starts
    // Indices are not checked against the array lengths here; in -O safe a bad index panics, in -O fast
    // it is undefined behaviour, so a real cache would validate (or checksum) the file first.
    return .{
        .buf = buf,
        .tok_tags = tok_tags,
        .tok_starts = tok_starts,
        .main_token = main_token,
        .flat = .{ .tag = tag, .lhs = lhs, .rhs = rhs, .extra = extra, .n_symbols = h[5], .main_sym = h[6] },
    };
}

// ======================= driver =======================

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    src: []const u8,
    ast: *const Ast,
    boxed: *const BoxProgram,
    path: []const u8,
};

fn benchTokenize(c: *const Ctx) usize {
    var t = tokenize(c.gpa, c.src) catch return 0;
    defer t.deinit(c.gpa);
    return t.len;
}
fn benchFlat(c: *const Ctx) usize {
    const t = tokenize(c.gpa, c.src) catch return 0;
    var a = parse(c.gpa, c.src, t, null) catch return 0;
    defer a.deinit(c.gpa);
    return a.nodes.len;
}
fn benchBoxed(c: *const Ctx) usize {
    var t = tokenize(c.gpa, c.src) catch return 0;
    defer t.deinit(c.gpa);
    var p = parseBoxed(c.gpa, c.src, &t) catch return 0;
    defer p.deinit(c.gpa); // freeing the tree is part of its cost
    return p.fns.len;
}
fn benchEvalFlat(c: *const Ctx) i64 {
    return FlatEval.run(c.gpa, c.ast.flat()) catch 0;
}
fn benchEvalBoxed(c: *const Ctx) i64 {
    return BoxEval.run(c.gpa, c.boxed) catch 0;
}
fn benchWrite(c: *const Ctx) bool {
    writeAst(c.io, c.ast, c.path) catch return false;
    return true;
}
fn benchRead(c: *const Ctx) usize {
    const l = loadAst(c.gpa, c.io, c.path) catch return 0;
    defer c.gpa.free(l.buf);
    return l.flat.tag.len;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var out_buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &out_buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const src = try generate(gpa, args.n, 0x5EED0011);
    defer gpa.free(src);
    const lines = std.mem.countScalar(u8, src, '\n');

    var tokens = try tokenize(gpa, src);
    var boxed = try parseBoxed(gpa, src, &tokens);
    defer boxed.deinit(gpa);
    var perr: Parser = undefined;
    var ast = parse(gpa, src, tokens, &perr) catch |e| {
        if (e == error.ParseFailed) std.process.fatal("parse error at token {d}: expected {s}", .{ perr.err_token, perr.expected });
        return e;
    };
    defer ast.deinit(gpa);
    const nt = ast.tokens.len;
    const nn = ast.nodes.len;
    const nx = ast.extra.len;
    var bs: BoxStats = .{};
    for (boxed.fns) |f| bs.walk(f);
    bs.nodes += 1; // count the program root like the flat root node
    bs.allocs += 1;
    bs.bytes += boxed.fns.len * @sizeOf(*BNode);

    const fl = struct {
        fn f(x: usize) f64 {
            return @floatFromInt(x);
        }
    }.f;
    try out.print("source: {d} bytes, {d} lines, {d} tokens, {d} nodes, {d} extra u32s, {d} symbols\n", .{ src.len, lines, nt, nn, nx, ast.strings.len() });
    try out.print("sizes: token {d} B (SoA) vs {d} B as a struct; node {d} B (SoA) vs {d} B as a struct; boxed Node = {d} B\n", .{
        TokenList.capacityInBytes(1), @sizeOf(Token), NodeList.capacityInBytes(1), @sizeOf(Node), @sizeOf(BNode),
    });
    const node_avg = fl(13 * nn + 4 * nx) / fl(nn);
    const box_avg = fl(bs.bytes) / fl(bs.nodes);
    try out.print("bytes/token {d:.2}, bytes/node fixed 13, avg incl. extra {d:.2}; nodes/token {d:.3}\n", .{ 5.0, node_avg, fl(nn) / fl(nt) });
    try out.print("boxed: {d} nodes, {d} allocations, {d:.2} requested B/node (allocator headers not counted)\n", .{ bs.nodes, bs.allocs, box_avg });

    const path = "/tmp/ch11-flat-ast-zig.bin";
    const r_flat = try FlatEval.run(gpa, ast.flat());
    const r_box = try BoxEval.run(gpa, &boxed);
    try writeAst(io, &ast, path);
    const loaded = try loadAst(gpa, io, path);
    defer gpa.free(loaded.buf);
    const r_load = try FlatEval.run(gpa, loaded.flat);
    const same = r_flat == r_box and r_flat == r_load;
    try out.print("eval: flat {d}, boxed {d}, loaded from file {d}: {s}\n", .{ r_flat, r_box, r_load, if (same) "match" else "MISMATCH" });
    if (!same) {
        try out.flush();
        return error.ResultsDiffer;
    }
    try out.print("checksum {d}\n", .{r_flat});

    const ctx: Ctx = .{ .gpa = gpa, .io = io, .src = src, .ast = &ast, .boxed = &boxed, .path = path };
    const t_tok = benchRuns(io, benchTokenize, &ctx);
    const t_flat = benchRuns(io, benchFlat, &ctx);
    const t_box = benchRuns(io, benchBoxed, &ctx);
    const t_eval_flat = benchRuns(io, benchEvalFlat, &ctx);
    const t_eval_box = benchRuns(io, benchEvalBoxed, &ctx);
    const t_write = benchRuns(io, benchWrite, &ctx);
    const t_read = benchRuns(io, benchRead, &ctx);
    const file_len = loaded.buf.len;
    Io.Dir.deleteFileAbsolute(io, path) catch {};

    const M = RUNS / 2;
    const ms = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.f;
    const mb_f = fl(src.len) / ms(t_flat[M]) / 1e3;
    const ml_f = fl(lines) / ms(t_flat[M]) / 1e3;
    const mb_b = fl(src.len) / ms(t_box[M]) / 1e3;
    const ml_b = fl(lines) / ms(t_box[M]) / 1e3;
    try out.print("tokenize only        {d:8.3} ms\n", .{ms(t_tok[M])});
    try out.print("flat  tokenize+parse {d:8.3} ms  {d:7.1} MB/s  {d:6.2} M lines/s\n", .{ ms(t_flat[M]), mb_f, ml_f });
    try out.print("boxed tokenize+parse {d:8.3} ms  {d:7.1} MB/s  {d:6.2} M lines/s  (incl. freeing the tree)\n", .{ ms(t_box[M]), mb_b, ml_b });
    try out.print("eval  flat {d:8.3} ms, boxed {d:8.3} ms\n", .{ ms(t_eval_flat[M]), ms(t_eval_box[M]) });
    try out.print("file: {d} bytes ({d:.2}x the source); write {d:.3} ms, read (views, no decode) {d:.3} ms\n", .{ file_len, fl(file_len) / fl(src.len), ms(t_write[M]), ms(t_read[M]) });

    try emitBench(out, "ch11-parse", "tokenize only", nt, &t_tok);
    try emitBench(out, "ch11-parse", "flat: tokenize+parse", nt, &t_flat);
    try emitBench(out, "ch11-parse", "boxed: tokenize+parse", nt, &t_box);
    try emitBench(out, "ch11-eval", "flat nodes", nn, &t_eval_flat);
    try emitBench(out, "ch11-eval", "boxed tree", nn, &t_eval_box);
    try emitBench(out, "ch11-file", "write file", file_len, &t_write);
    try emitBench(out, "ch11-file", "read file", file_len, &t_read);
    try emitValue(out, "ch11-bytes", "token", nt, 5.0, "B");
    try emitValue(out, "ch11-bytes", "node, fixed", nn, 13.0, "B");
    try emitValue(out, "ch11-bytes", "node, avg incl. extra", nn, node_avg, "B");
    try emitValue(out, "ch11-bytes", "boxed node, avg", nn, box_avg, "B");
    try emitValue(out, "ch11-throughput", "flat", nt, ml_f, "M lines/s");
    try emitValue(out, "ch11-throughput", "boxed", nt, ml_b, "M lines/s");
    try out.flush();
}
