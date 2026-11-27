#!/usr/bin/env python3
"""Build chapters/04-memory-hugepages/index.html from index.src.html.

Placeholders:
  {{CODE:file[:a-b][:hl]}}  escaped source lines a..b of code/file (whole file without range)
  {{TERM:key}}              terminal block from code/expected_output.txt (see TERMS)
  {{ERRDATA}}               JSON for the error decoder (from code/errors.tsv + output)
  {{SEGDATA}}               JSON with the real va/iova pairs of run 3a
"""
import html, json, re, sys, os

CH = '/home/user/ai_lab/dpdk_research/chapters/04-memory-hugepages'
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'index.src.html')
OUT = open(os.path.join(CH, 'code/expected_output.txt')).read().split('\n')


def find(prefix, start=0):
    for i in range(start, len(OUT)):
        if OUT[i].startswith(prefix):
            return i
    sys.exit('marker not found: ' + prefix)


def until(i, pat):
    """lines from i to the first line matching pat (inclusive)"""
    r = re.compile(pat)
    j = i
    while j < len(OUT) and not r.search(OUT[j]):
        j += 1
    return OUT[i:j + 1]


def blk(prefix, end=r'^\[exit code', after=None, drop_exit=True):
    s = find(after) if after else 0
    i = find(prefix, s)
    lines = until(i, end)
    if drop_exit and lines and lines[-1].startswith('[exit code'):
        lines = lines[:-1]
    return lines


HL = [r'IOVA mode\s+:', r'iova=', r'FAILED', r'\bOK\b', r'usable=', r'median', r'mem event', r'validator',
      r'EEXIST|ENOSPC|ENAMETOOLONG', r'rte_dev_dma_map', r'socket 1', r'HugetlbPages', r'files left',
      r'NOT adjacent', r'rte_mem_event_callback_register', r'grew by', r'per object', r'rte_malloc\(64 MB\)',
      r'mapped now', r'external = 1', r'RTE_BAD_IOVA']
ERR = [r'FAILED', r'= -1', r'NULL', r'ENOSPC', r'EEXIST', r'ENAMETOOLONG', r'Cannot', r'No free', r'Not enough',
       r'unknown argument', r'unavailable', r'Invalid argument', r'Permission denied', r'not supported']


def term(lines, title='code/expected_output.txt', hl=None, err=None):
    hl = [re.compile(p) for p in (hl if hl is not None else HL)]
    err = [re.compile(p) for p in (err if err is not None else ERR)]
    out = []
    for ln in lines:
        e = html.escape(ln)
        if ln.startswith('$ '):
            out.append('<span class="prompt">$ </span><span class="cmd">' + html.escape(ln[2:]) + '</span>')
        elif re.match(r'^\s*(EAL|VIRTIO|VHOST|ARGPARSE):', ln) and not any(p.search(ln) for p in err):
            out.append('<span class="dim">' + e + '</span>')
        elif any(p.search(ln) for p in err):
            out.append('<span class="err">' + e + '</span>')
        elif any(p.search(ln) for p in hl):
            out.append('<span class="hl">' + e + '</span>')
        else:
            out.append(e)
    return ('<div class="terminal" data-copy>\n  <div class="term-bar"><span class="title">' + title +
            '</span></div>\n<pre>' + '\n'.join(out) + '</pre>\n</div>')


TERMS = {
    'hm1': lambda: blk('$ ./hello_memory -l 0 --no-pci --no-huge -m 64'),
    'hm2': lambda: blk('$ ./hello_memory -l 0 --no-pci -m 64 --file-prefix=ch04-hm2'),
    'tlb': lambda: blk('$ ./tlb_bench -l 0 --no-pci --no-huge') + blk('$ ./tlb_bench -l 0 --no-pci --huge-unlink'),
    'files': lambda: until(find('HugePages_Free before'), r'^  files left: '),
    'ms_pa': lambda: blk('$ ./memseg_walk -l 0 --no-pci -m 32'),
    'ms_tries': lambda: until(find('--- 3b.'), r'try 5'),
    'ms_va': lambda: blk('$ ./memseg_walk -l 0 --no-pci --iova-mode=va'),
    'ms_nohuge': lambda: blk('$ ./memseg_walk -l 0 --no-pci --no-huge'),
    'mz': lambda: blk('$ ./memzones -l 0'),
    'ev_a': lambda: blk('$ ./heap_events -l 0 --no-pci --huge-unlink'),
    'ev_b': lambda: blk('$ ./heap_events -l 0 --no-pci -m 16'),
    'ev_c': lambda: blk('$ ./heap_events -l 0 --no-pci --no-huge'),
    'ev_d': lambda: until(find('$ ./heap_events -l 0 --no-pci --legacy-mem'), r'hugepage files left by the legacy'),
    'xdma': lambda: blk('$ ./extmem_dma'),
    'errs': lambda: until(find('==== errors.tsv'), r'left by this script'),
    'ex1': lambda: blk('$ ./solutions/overhead'),
    'ex2': lambda: blk('$ ./solutions/no_cap -l 0 --no-pci -m 32 --huge') + blk('$ ./solutions/no_cap -l 0 --no-pci -m 32 --numa-limit'),
}


def code(spec):
    parts = spec.split(':')
    fname = parts[0]
    lines = open(os.path.join(CH, 'code', fname)).read().rstrip('\n').split('\n')
    start = 1
    if len(parts) > 1 and parts[1]:
        a, b = parts[1].split('-')
        start = int(a)
        lines = lines[int(a) - 1:int(b)]
    hl = parts[2] if len(parts) > 2 else ''
    lang = 'bash' if fname.endswith('.sh') else ('make' if fname == 'Makefile' else 'c')
    attrs = ' data-lines'
    if start != 1:
        attrs += ' data-start="%d"' % start
    if hl:
        attrs += ' data-hl="%s"' % hl
    return ('<div class="code-block">\n  <div class="code-head"><span class="file">code/%s</span>'
            '<span class="lang">%s</span></div>\n<pre%s><code class="language-%s">%s</code></pre>\n</div>'
            % (fname, {'c': 'C', 'bash': 'bash', 'make': 'make'}[lang], attrs, lang,
               html.escape('\n'.join(lines))))


# --- error decoder data -------------------------------------------------------
MATCH = {  # regexes that recognise each error in pasted text (authored; tested in the page)
    'E1': r'lcore \d+ unavailable|No valid lcores|invalid coremask or core-list',
    'E2': r'unknown argument|ARGPARSE',
    'E3': r'Cannot create lock|Is another primary process running|Cannot init config',
    'E4': r'No free \d+ kB hugepages|Cannot get hugepage information',
    'E5': r'Not enough memory available! Requested',
    'E6': r'attempted to allocate \d+ segments|alloc_seg\(\): mmap\(\) failed|^\s*(EAL: )?Cannot init memory\s*$',
    'E7': r'Not enough memory available on socket',
    'E8': r"Cannot use IOVA as 'PA'",
    'E9': r'rte_malloc_socket.*NULL',
}
PHASE = {'1 parse arguments': 1, '2 config and lock': 2, '4 IOVA mode': 4, '5 hugepage info': 5,
         '6 memory init': 6, 'after init (allocation)': 9}


def errdata():
    rows = [l.split('\t') for l in open(os.path.join(CH, 'code/errors.tsv')).read().strip().split('\n')[1:]]
    data = []
    for r in rows:
        eid, phase, trig, key, errno, cause, fix = r
        i = find('---- [%s]' % eid)
        log = [l.strip() for l in until(i + 1, r'^(---- \[|\s*$|====)')[1:] if l.strip()]
        log = [l for l in log if not l.startswith('---- [') and not l.startswith('====')]
        if eid == 'E6':
            log = [l for l in log if not l.startswith('(with')]
        data.append(dict(id=eid, phase=PHASE[phase], phaseName=phase, trigger=trig, key=key, errno=errno,
                         cause=cause, fix=fix, log=log, re=MATCH[eid]))
    return json.dumps(data, indent=1)


def segdata():
    i = find('$ ./memseg_walk -l 0 --no-pci -m 32')
    segs = []
    for l in until(i, r'^\[exit code'):
        m = re.search(r'seg (\d+): va=(0x[0-9a-f]+) iova=(0x[0-9a-f]+)', l)
        if m:
            segs.append(dict(va=m.group(2), iova=m.group(3)))
    return json.dumps(segs)


src = open(SRC).read()
src = re.sub(r'\{\{CODE:([^}]+)\}\}', lambda m: code(m.group(1)), src)
src = re.sub(r'\{\{TERM:([a-z0-9_]+)\}\}', lambda m: term(TERMS[m.group(1)]()), src)
src = src.replace('{{ERRDATA}}', errdata()).replace('{{SEGDATA}}', segdata())
left = re.findall(r'\{\{[^}]*\}\}', src)
if left:
    sys.exit('unfilled placeholders: %s' % left[:5])
open(os.path.join(CH, 'index.html'), 'w').write(src)
print('wrote index.html', len(src), 'bytes')
