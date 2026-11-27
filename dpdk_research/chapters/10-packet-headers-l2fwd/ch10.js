/* Chapter 10 widgets: packet byte map + tunnel gallery, checksum folding
 * (stepper with predict), ptype decoder, and the l2fwd TX-buffer / drain
 * timer animation. Vanilla JS on top of ../../assets/course.js. Colours only
 * via CSS classes / variables so light and dark themes both work. */
(function () {
  'use strict';
  var S = CourseJS.svg;
  function $(id) { return document.getElementById(id); }
  function hex(n, w) { var s = (n >>> 0).toString(16); while (s.length < w) s = '0' + s; return s; }
  function bytesOf(h) { var a = []; for (var i = 0; i < h.length; i += 2) a.push(parseInt(h.substr(i, 2), 16)); return a; }
  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

  /* =====================================================================
   * 1. Packet byte map and tunnel gallery
   * =================================================================== */
  // field: [label, offset, length, layer class, C member, kind, note]
  function F(label, off, len, layer, member, kind, note) {
    return { label: label, off: off, len: len, layer: layer, member: member, kind: kind || 'hex', note: note || '' };
  }
  function eth(o) {
    return [
      F('dst MAC', o, 6, 'l2', 'rte_ether_hdr.dst_addr', 'mac', 'Who the frame is for. l2fwd overwrites it.'),
      F('src MAC', o + 6, 6, 'l2', 'rte_ether_hdr.src_addr', 'mac', 'Sender. rte_ether_addr_copy() copies all 6 bytes.'),
      F('ether_type', o + 12, 2, 'l2', 'rte_ether_hdr.ether_type', 'u16', 'Big-endian. Compare with RTE_BE16(RTE_ETHER_TYPE_IPV4) or convert with rte_be_to_cpu_16().')
    ];
  }
  function vlan(o, inner) {
    return [
      F('vlan_tci', o, 2, 'l2b', 'rte_vlan_hdr.vlan_tci', 'tci', 'PCP (3 bits) | DEI (1) | VLAN id (12).'),
      F(inner ? 'eth_proto' : 'eth_proto', o + 2, 2, 'l2b', 'rte_vlan_hdr.eth_proto', 'u16', 'The ether_type of what follows the tag.')
    ];
  }
  function ipv4(o, pfx) {
    pfx = pfx || '';
    return [
      F(pfx + 'version_ihl', o, 1, 'l3', 'rte_ipv4_hdr.version_ihl', 'vihl', 'High nibble: version 4. Low nibble: header length in 32-bit words; rte_ipv4_hdr_len() = IHL * 4.'),
      F(pfx + 'type_of_service', o + 1, 1, 'l3', 'rte_ipv4_hdr.type_of_service', 'u8', 'DSCP (6 bits) + ECN (2 bits).'),
      F(pfx + 'total_length', o + 2, 2, 'l3', 'rte_ipv4_hdr.total_length', 'u16', 'IP header + payload, in bytes. Check it against the mbuf length before trusting it.'),
      F(pfx + 'packet_id', o + 4, 2, 'l3', 'rte_ipv4_hdr.packet_id', 'u16', 'Identifies the fragments of one datagram.'),
      F(pfx + 'fragment_offset', o + 6, 2, 'l3', 'rte_ipv4_hdr.fragment_offset', 'frag', 'Flags DF/MF (RTE_IPV4_HDR_DF_FLAG, _MF_FLAG) + offset in 8-byte units (RTE_IPV4_HDR_OFFSET_MASK).'),
      F(pfx + 'time_to_live', o + 8, 1, 'l3', 'rte_ipv4_hdr.time_to_live', 'u8', 'A router decrements it and must then update the checksum.'),
      F(pfx + 'next_proto_id', o + 9, 1, 'l3', 'rte_ipv4_hdr.next_proto_id', 'proto', 'IPPROTO_UDP (17), IPPROTO_TCP (6), IPPROTO_ICMP (1)...'),
      F(pfx + 'hdr_checksum', o + 10, 2, 'ck', 'rte_ipv4_hdr.hdr_checksum', 'u16', 'Covers the IP header only. Stored exactly as rte_ipv4_cksum() returns it: no byte swap.'),
      F(pfx + 'src_addr', o + 12, 4, 'l3', 'rte_ipv4_hdr.src_addr', 'ip4', 'rte_be32_t. Only 2-byte aligned in a frame (offset 26), which is why the struct is __rte_aligned(2) + packed.'),
      F(pfx + 'dst_addr', o + 16, 4, 'l3', 'rte_ipv4_hdr.dst_addr', 'ip4', 'rte_be32_t. RTE_IPV4(a,b,c,d) builds the HOST-order value; wrap it in rte_cpu_to_be_32().')
    ];
  }
  function ipv6(o) {
    return [
      F('vtc_flow', o, 4, 'l3', 'rte_ipv6_hdr.vtc_flow', 'vtc', '26.11: no bitfields. Version (4) | traffic class (8) | flow label (20); use RTE_IPV6_HDR_TC_MASK/_SHIFT and _FL_MASK on rte_be_to_cpu_32(vtc_flow).'),
      F('payload_len', o + 4, 2, 'l3', 'rte_ipv6_hdr.payload_len', 'u16', 'Everything after the 40-byte header, extension headers included.'),
      F('proto', o + 6, 1, 'l3', 'rte_ipv6_hdr.proto', 'proto', 'Next header: an L4 protocol or an extension header (0 = hop-by-hop).'),
      F('hop_limits', o + 7, 1, 'l3', 'rte_ipv6_hdr.hop_limits', 'u8', 'IPv6 TTL. No header checksum to fix when you decrement it.'),
      F('src_addr', o + 8, 16, 'l3', 'rte_ipv6_hdr.src_addr', 'ip6', 'struct rte_ipv6_addr { uint8_t a[16]; } (26.11). Compare with rte_ipv6_addr_eq().'),
      F('dst_addr', o + 24, 16, 'l3', 'rte_ipv6_hdr.dst_addr', 'ip6', 'Static initialiser: RTE_IPV6(0xfd00, 0x10, 0, 0, 0, 0, 0, 2).')
    ];
  }
  function udp(o, pfx) {
    pfx = pfx || '';
    return [
      F(pfx + 'src_port', o, 2, 'l4', 'rte_udp_hdr.src_port', 'u16', ''),
      F(pfx + 'dst_port', o + 2, 2, 'l4', 'rte_udp_hdr.dst_port', 'u16', 'For a tunnel this port says what follows: 4789 VXLAN, 6081 GENEVE, 2152 GTP-U.'),
      F(pfx + 'dgram_len', o + 4, 2, 'l4', 'rte_udp_hdr.dgram_len', 'u16', 'UDP header + data.'),
      F(pfx + 'dgram_cksum', o + 6, 2, 'ck', 'rte_udp_hdr.dgram_cksum', 'u16', 'Covers a pseudo-header (IPs, proto, length) + UDP header + data. 0 = "no checksum" (IPv4 only).')
    ];
  }
  function tcp(o, pfx) {
    pfx = pfx || '';
    return [
      F(pfx + 'src_port', o, 2, 'l4', 'rte_tcp_hdr.src_port', 'u16'),
      F(pfx + 'dst_port', o + 2, 2, 'l4', 'rte_tcp_hdr.dst_port', 'u16'),
      F(pfx + 'sent_seq', o + 4, 4, 'l4', 'rte_tcp_hdr.sent_seq', 'u32'),
      F(pfx + 'recv_ack', o + 8, 4, 'l4', 'rte_tcp_hdr.recv_ack', 'u32'),
      F(pfx + 'data_off', o + 12, 1, 'l4', 'rte_tcp_hdr.data_off', 'u8', 'High nibble = header length in 32-bit words.'),
      F(pfx + 'tcp_flags', o + 13, 1, 'l4', 'rte_tcp_hdr.tcp_flags', 'u8', 'RTE_TCP_SYN_FLAG 0x02, RTE_TCP_ACK_FLAG 0x10...'),
      F(pfx + 'rx_win', o + 14, 2, 'l4', 'rte_tcp_hdr.rx_win', 'u16'),
      F(pfx + 'cksum', o + 16, 2, 'ck', 'rte_tcp_hdr.cksum', 'u16', 'Same pseudo-header rule as UDP, but never optional.'),
      F(pfx + 'tcp_urp', o + 18, 2, 'l4', 'rte_tcp_hdr.tcp_urp', 'u16')
    ];
  }
  function payload(o, n, layer) { return [F('payload', o, n, layer || 'pl', '(data)', 'ascii', 'Application bytes.')]; }

  var FRAMES = {
    udp4: {
      title: 'Ethernet / IPv4 / UDP', src: 'mixed.pcap frame #1 (real bytes)',
      bytes: '02000000000202000000000108004500002800010000401166ae0a0a00010a0a000203e807d00014eea1636831302d7061796c6f6164',
      fields: [].concat(eth(0), ipv4(14), udp(34), payload(42, 12))
    },
    vlan: {
      title: 'Ethernet / 802.1Q / IPv4 / UDP', src: 'mixed.pcap frame #7: the tag pushes IPv4 to offset 18',
      bytes: '0200000000020200000000018100a06408004500002800010000401166ae0a0a00010a0a000203e907d10014ee9f636831302d7061796c6f6164',
      fields: [].concat(eth(0), vlan(14), ipv4(18), udp(38), payload(46, 12))
    },
    udp6: {
      title: 'Ethernet / IPv6 / UDP', src: 'mixed.pcap frame #5: tc 0xb8, flow label 0x12345',
      bytes: '02000000000202000000000186dd6b81234500141140fd000010000000000000000000000001fd00001000000000000000000000000214e914e90014ea79636831302d7061796c6f6164',
      fields: [].concat(eth(0), ipv6(14), udp(54), payload(62, 12))
    },
    vxlan: {
      title: 'VXLAN: outer Eth/IPv4/UDP:4789 + VXLAN + inner Eth/IPv4/TCP', src: 'mixed.pcap frame #9',
      bytes: '02000000000202000000000108004500005a000100004011667c0a0a00010a0a0002c00012b50046000008000000001388000200000000bb0200000000aa080045000028000100004006957bc0a83201c0a83202823501bb000003e8000000005010ffff42a80000',
      fields: [].concat(eth(0), ipv4(14), udp(34), [
        F('vx_flags', 42, 4, 'tun', 'rte_vxlan_hdr.vx_flags', 'u32', 'Byte 0 = 0x08: the I flag ("VNI is valid"). The other 24 bits are reserved.'),
        F('vx_vni', 46, 4, 'tun', 'rte_vxlan_hdr.vx_vni', 'vni', 'VNI in the top 24 bits: rte_be_to_cpu_32(vx_vni) >> 8. The last byte is reserved.')
      ], eth(50).map(function (f) { f.label = 'inner ' + f.label; f.layer = 'in'; return f; }),
         ipv4(64, 'inner ').map(function (f) { if (f.layer !== 'ck') f.layer = 'in'; return f; }),
         tcp(84, 'inner ').map(function (f) { if (f.layer !== 'ck') f.layer = 'in'; return f; }))
    },
    geneve: {
      title: 'GENEVE header (8 bytes + options), after UDP:6081', src: 'built by hand: VNI 5000, inner Ethernet',
      bytes: '0000655800138800',
      fields: [
        F('ver | opt_len', 0, 1, 'tun', 'rte_geneve_hdr.ver:2, opt_len:6', 'u8', 'Bitfields in the struct (endianness-dependent order). opt_len counts 4-byte words of options.'),
        F('oam | critical', 1, 1, 'tun', 'rte_geneve_hdr.oam:1, critical:1', 'u8'),
        F('proto', 2, 2, 'tun', 'rte_geneve_hdr.proto', 'u16', 'An ether_type: RTE_GENEVE_TYPE_ETH (0x6558) = an Ethernet frame follows.'),
        F('vni', 4, 3, 'tun', 'rte_geneve_hdr.vni[3]', 'u24', '24-bit virtual network id as a byte array.'),
        F('reserved2', 7, 1, 'tun', 'rte_geneve_hdr.reserved2', 'u8')
      ], gallery: 'lib/net/rte_geneve.h, RTE_GENEVE_DEFAULT_PORT 6081, ptype RTE_PTYPE_TUNNEL_GENEVE'
    },
    gtpu: {
      title: 'GTP-U header (8 bytes), after UDP:2152', src: 'built by hand: G-PDU, TEID 12345',
      bytes: '30ff001c00003039',
      fields: [
        F('gtp_hdr_info', 0, 1, 'tun', 'rte_gtp_hdr.gtp_hdr_info (ver:3 pt:1 e:1 s:1 pn:1)', 'u8', '0x30 = version 1, PT 1 (GTP), no optional fields.'),
        F('msg_type', 1, 1, 'tun', 'rte_gtp_hdr.msg_type', 'u8', '0xff = G-PDU: a user IP packet follows.'),
        F('plen', 2, 2, 'tun', 'rte_gtp_hdr.plen', 'u16', 'Bytes after the 8-byte mandatory header.'),
        F('teid', 4, 4, 'tun', 'rte_gtp_hdr.teid', 'u32', 'Tunnel endpoint id: which mobile session this is.')
      ], gallery: 'lib/net/rte_gtp.h, RTE_GTPU_UDP_PORT 2152, ptype RTE_PTYPE_TUNNEL_GTPU'
    },
    mpls: {
      title: 'MPLS label stack entry (4 bytes), ether_type 0x8847', src: 'built by hand: label 1000, bottom of stack, TTL 64',
      bytes: '003e8140',
      fields: [
        F('tag_msb', 0, 2, 'tun', 'rte_mpls_hdr.tag_msb', 'u16', 'The high 16 of the 20-bit label.'),
        F('tag_lsb | tc | bs', 2, 1, 'tun', 'rte_mpls_hdr.tag_lsb:4, tc:3, bs:1', 'u8', 'Low 4 label bits, traffic class, bottom-of-stack flag.'),
        F('ttl', 3, 1, 'tun', 'rte_mpls_hdr.ttl', 'u8')
      ], gallery: 'lib/net/rte_mpls.h, RTE_ETHER_TYPE_MPLS 0x8847, ptype RTE_PTYPE_L2_ETHER_MPLS'
    },
    toy: {
      title: 'toy_tun_hdr (8 bytes, packed), after UDP:47000', src: 'build_packets.c frame 6',
      bytes: '0101c0ffee010007',
      fields: [
        F('ver', 0, 1, 'tun', 'toy_tun_hdr.ver', 'u8'),
        F('flags', 1, 1, 'tun', 'toy_tun_hdr.flags', 'u8'),
        F('session', 2, 4, 'tun', 'toy_tun_hdr.session', 'u32', 'Offset 2: without __rte_packed_begin/__rte_packed_end the compiler would pad 2 bytes before it (struct size 12, not 8).'),
        F('seq', 6, 2, 'tun', 'toy_tun_hdr.seq', 'u16')
      ], gallery: 'your own header: struct __rte_packed_begin toy_tun_hdr {...} __rte_packed_end;'
    }
  };
  var LAYER_NAME = { l2: 'Ethernet', l2b: 'VLAN tag', l3: 'IP', l4: 'L4', ck: 'checksum', tun: 'tunnel', 'in': 'inner frame', pl: 'payload' };

  function decode(f, b, hostLoad) {
    var v = b.slice(f.off, f.off + f.len), i, n;
    function be(arr) { var x = 0; for (var k = 0; k < arr.length; k++) x = x * 256 + arr[k]; return x; }
    function le(arr) { var x = 0; for (var k = arr.length - 1; k >= 0; k--) x = x * 256 + arr[k]; return x; }
    var raw = v.map(function (x) { return hex(x, 2); }).join(' ');
    var lines = [];
    var w = f.len * 2;
    switch (f.kind) {
      case 'mac': lines.push(v.map(function (x) { return hex(x, 2); }).join(':') + (v[0] & 1 ? '  (multicast/broadcast bit set)' : '  (unicast' + (v[0] & 2 ? ', locally administered)' : ')'))); break;
      case 'ip4': lines.push(v.join('.') + '   rte_be_to_cpu_32() = 0x' + hex(be(v), 8)); break;
      case 'ip6': n = []; for (i = 0; i < 16; i += 2) n.push(hex(v[i] * 256 + v[i + 1], 4)); lines.push(n.join(':')); break;
      case 'ascii': lines.push('"' + v.map(function (x) { return x >= 32 && x < 127 ? String.fromCharCode(x) : '.'; }).join('') + '"'); break;
      case 'vihl': lines.push('version ' + (v[0] >> 4) + ', IHL ' + (v[0] & 15) + ' -> rte_ipv4_hdr_len() = ' + (v[0] & 15) * 4 + ' bytes'); break;
      case 'proto': lines.push(v[0] + ({ 1: ' (ICMP)', 6: ' (TCP)', 17: ' (UDP)', 0: ' (IPv6 hop-by-hop ext)', 58: ' (ICMPv6)' }[v[0]] || '')); break;
      case 'tci': n = be(v); lines.push('PCP ' + (n >> 13) + ', DEI ' + ((n >> 12) & 1) + ', VID ' + (n & 0xfff)); break;
      case 'frag': n = be(v); lines.push('DF=' + ((n >> 14) & 1) + ' MF=' + ((n >> 13) & 1) + ' offset=' + (n & 0x1fff) + '*8 = ' + (n & 0x1fff) * 8 + ' bytes'); break;
      case 'vtc': n = be(v); lines.push('version ' + (n >>> 28) + ', traffic class 0x' + hex((n >>> 20) & 0xff, 2) + ' (DSCP ' + (((n >>> 20) & 0xff) >> 2) + '), flow label 0x' + hex(n & 0xfffff, 5)); break;
      case 'vni': n = be(v); lines.push('VNI ' + (n >>> 8) + ' (0x' + hex(n >>> 8, 6) + ')'); break;
      case 'u24': lines.push(be(v) + ' (0x' + hex(be(v), 6) + ')'); break;
      default: n = be(v); lines.push(n + ' (0x' + hex(n, w) + ')');
    }
    if (f.len === 2 || f.len === 4) {
      var conv = f.len === 2 ? 'rte_be_to_cpu_16' : 'rte_be_to_cpu_32';
      lines.push(hostLoad
        ? '<span class="w-err">plain load on x86 (little-endian), no ' + conv + '(): 0x' + hex(le(v), w) + ' = ' + le(v) + '</span>'
        : conv + '(): 0x' + hex(be(v), w) + ' = ' + be(v));
    }
    return { raw: raw, lines: lines };
  }

  function byteMap() {
    var root = $('w-bytes');
    if (!root) return;
    var grid = root.querySelector('.bm-grid'), info = root.querySelector('.bm-info'),
      flist = root.querySelector('.bm-fields'), tabs = root.querySelector('.bm-tabs'),
      host = $('bm-host'), cur = 'udp4', sel = null, cells = [];

    Object.keys(FRAMES).forEach(function (k) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn small'; b.textContent = {
        udp4: 'IPv4/UDP', vlan: '802.1Q', udp6: 'IPv6/UDP', vxlan: 'VXLAN', geneve: 'GENEVE', gtpu: 'GTP-U', mpls: 'MPLS', toy: 'toy (packed)' }[k];
      b.dataset.k = k;
      b.addEventListener('click', function () { cur = k; sel = null; draw(); });
      tabs.appendChild(b);
    });
    function show(fi) {
      var fr = FRAMES[cur], b = bytesOf(fr.bytes);
      cells.forEach(function (c) { c.classList.remove('on'); });
      Array.prototype.forEach.call(flist.children, function (c, i) { c.classList.toggle('on', i === fi); });
      if (fi === null) {
        info.innerHTML = '<div class="bm-t">' + esc(fr.title) + '</div><div class="muted small">' + esc(fr.src) + ' &middot; ' + b.length +
          ' bytes. Hover or tap a byte or a field name.</div>' + (fr.gallery ? '<div class="small bm-gal">' + esc(fr.gallery) + '</div>' : '');
        return;
      }
      var f = fr.fields[fi], d = decode(f, b, host.checked);
      for (var i = f.off; i < f.off + f.len; i++) if (cells[i]) cells[i].classList.add('on');
      info.innerHTML = '<div class="bm-t"><code>' + esc(f.member) + '</code></div>' +
        '<div class="small">offset <b>' + f.off + '</b>, length <b>' + f.len + '</b> byte' + (f.len > 1 ? 's' : '') +
        ' &middot; layer: ' + LAYER_NAME[f.layer] + '</div>' +
        '<div class="mono small">bytes: ' + d.raw + '</div>' +
        d.lines.map(function (l) { return '<div class="mono small">' + l + '</div>'; }).join('') +
        (f.note ? '<div class="small bm-note">' + esc(f.note) + '</div>' : '');
    }
    function draw() {
      var fr = FRAMES[cur], b = bytesOf(fr.bytes), owner = [];
      Array.prototype.forEach.call(tabs.children, function (t) { t.classList.toggle('primary', t.dataset.k === cur); });
      fr.fields.forEach(function (f, i) { for (var k = f.off; k < f.off + f.len; k++) owner[k] = i; });
      grid.innerHTML = ''; flist.innerHTML = ''; cells = [];
      b.forEach(function (x, i) {
        var c = document.createElement('span'), fi = owner[i];
        c.className = 'bm-b ly-' + (fi !== undefined ? fr.fields[fi].layer : 'pl');
        c.innerHTML = '<i>' + i + '</i>' + hex(x, 2);
        c.title = fi !== undefined ? fr.fields[fi].label : '';
        c.addEventListener('mouseenter', function () { if (fi !== undefined) { sel = fi; show(fi); } });
        c.addEventListener('click', function () { if (fi !== undefined) { sel = fi; show(fi); } });
        grid.appendChild(c); cells.push(c);
      });
      fr.fields.forEach(function (f, i) {
        var e = document.createElement('button');
        e.type = 'button'; e.className = 'bm-f ly-' + f.layer;
        e.textContent = f.label + ' @' + f.off;
        e.addEventListener('mouseenter', function () { sel = i; show(i); });
        e.addEventListener('click', function () { sel = i; show(i); });
        flist.appendChild(e);
      });
      show(sel);
    }
    host.addEventListener('change', function () { show(sel); });
    draw();
  }

  /* =====================================================================
   * 2. Checksum folding, step by step (predict, then step)
   * =================================================================== */
  function cksumStepper() {
    var root = $('w-cksum');
    if (!root) return;
    var input = $('ck-hex'), tbody = root.querySelector('tbody'), res = root.querySelector('.ck-res'), msg = $('ck-msg');
    var PRESETS = {
      'textbook header': '450000730000400040110000c0a80001c0a800c7',
      'after TTL 64->63': '45000073000040003f110000c0a80001c0a800c7',
      'mixed.pcap #1': '4500002800010000401100000a0a00010a0a0002',
      'checksum NOT zeroed': '45000073000040004011b861c0a80001c0a800c7'
    };
    var pre = $('ck-presets');
    Object.keys(PRESETS).forEach(function (k) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn small'; b.textContent = k;
      b.addEventListener('click', function () { input.value = PRESETS[k]; recompute(); stepper.go(0); });
      pre.appendChild(b);
    });
    input.value = PRESETS['textbook header'];
    var words = [];
    function recompute() {
      var h = input.value.replace(/[^0-9a-fA-F]/g, '');
      msg.textContent = '';
      if (h.length !== 40) { msg.textContent = 'need exactly 20 bytes (40 hex digits); got ' + h.length / 2; h = (h + '0'.repeat(40)).substr(0, 40); }
      words = [];
      for (var i = 0; i < 40; i += 4) words.push(parseInt(h.substr(i, 4), 16));
      if (words[5] !== 0) msg.textContent = 'note: the checksum field (word 5) is not 0, so the result will be wrong unless you are verifying.';
    }
    recompute();
    input.addEventListener('change', function () { recompute(); stepper.go(0); });
    tbody.innerHTML = '';
    var rows = [];
    for (var i = 0; i < 10; i++) {
      var tr = document.createElement('tr');
      tr.innerHTML = '<td class="num">' + i + '</td><td class="mono"></td><td class="mono num"></td><td class="mono num"></td><td class="small"></td>';
      tbody.appendChild(tr); rows.push(tr);
    }
    function sumTo(k) { var s = 0; for (var i = 0; i < k; i++) s += words[i]; return s; }
    function fold(s) { while (s > 0xffff) s = (s & 0xffff) + Math.floor(s / 65536); return s; }
    var NAMES = ['version_ihl | tos', 'total_length', 'packet_id', 'fragment_offset', 'ttl | proto', 'hdr_checksum', 'src_addr hi', 'src_addr lo', 'dst_addr hi', 'dst_addr lo'];

    function setRes(parts) {
      res.innerHTML = parts.map(function (p) { return '<div class="stat' + (p[2] ? ' ' + p[2] : '') + '"><div class="stat-label">' + p[0] + '</div><div class="stat-value mono">' + p[1] + '</div></div>'; }).join('');
    }
    var steps = [{ caption: 'A 20-byte IPv4 header is ten 16-bit words in network order. The checksum field (word 5) must be 0 while we compute.' }];
    for (var k = 0; k < 10; k++) (function (k) {
      steps.push({
        caption: 'Add word ' + k + ' (' + NAMES[k] + ') to the running 32-bit sum.' + (k === 6 ? ' Watch the sum grow past 0xffff: the extra bits are carries.' : ''),
        run: function (ctx, isCur) {
          var r = rows[k];
          r.classList.add('done');
          r.classList.toggle('cur', isCur);
          r.children[3].textContent = '0x' + hex(sumTo(k + 1), 5);
          var before = sumTo(k), after = sumTo(k + 1);
          r.children[4].textContent = (Math.floor(after / 65536) > Math.floor(before / 65536)) ? 'sum passed another 0x10000: a carry' : '';
          setRes([['32-bit sum', '0x' + hex(after, 5)]]);
        }
      });
    })(k);
    steps.push({
      caption: 'Fold: add the bits above 16 back into the low 16 bits (end-around carry). Repeat until nothing is left above bit 15.',
      predict: { question: 'The sum has bits above bit 15 (the carries). What happens to them?', options: ['They are dropped (mod 65536)', 'They are added back into the low 16 bits', 'They are shifted into the checksum high byte'], answer: 1, explain: 'One\'s-complement addition wraps carries around: 0x2479c becomes 0x479c + 0x2 = 0x479e. That is what makes the sum independent of byte order.' },
      run: function () {
        var s = sumTo(10);
        setRes([['32-bit sum', '0x' + hex(s, 5)], ['fold', '0x' + hex(s & 0xffff, 4) + ' + 0x' + Math.floor(s / 65536).toString(16) + ' = 0x' + hex(fold(s), 4), 'hl']]);
      }
    });
    steps.push({
      caption: 'Invert all 16 bits. This is the checksum, written big-endian into hdr_checksum.',
      predict: { question: 'Which value goes into hdr_checksum?', options: ['the folded sum itself', 'its bitwise NOT (~sum)', 'its two\'s-complement negation (-sum)'], answer: 1, explain: 'The checksum is the one\'s complement (~) of the one\'s-complement sum. rte_ipv4_cksum() returns exactly that.' },
      run: function () {
        var s = fold(sumTo(10)), c = (~s) & 0xffff;
        setRes([['folded', '0x' + hex(s, 4)], ['~folded = checksum', '0x' + hex(c, 4), 'hl'], ['bytes on the wire', hex(c >> 8, 2) + ' ' + hex(c & 255, 2)]]);
      }
    });
    steps.push({
      caption: 'Verify: a receiver sums all ten words INCLUDING the checksum. A correct header gives 0xffff (rte_raw_cksum() == 0xffff).',
      predict: { question: 'Summing the header again, now with the checksum in word 5, gives...', options: ['0x0000', '0xffff', 'the checksum again'], answer: 1, explain: 'x + ~x = 0xffff in 16-bit one\'s complement, so a valid header always sums (and folds) to 0xffff.' },
      run: function () {
        var s = fold(sumTo(10)), c = (~s) & 0xffff, v = fold(sumTo(10) - words[5] + c);
        setRes([['checksum', '0x' + hex(c, 4)], ['sum with checksum', '0x' + hex(v, 4), v === 0xffff ? 'good' : 'bad']]);
      }
    });
    var stepper = new CourseJS.Stepper(root, {
      reset: function () {
        rows.forEach(function (r, i) {
          r.classList.remove('done', 'cur');
          r.children[1].textContent = hex(words[i] >> 8, 2) + ' ' + hex(words[i] & 255, 2);
          r.children[2].textContent = '0x' + hex(words[i], 4);
          r.children[3].textContent = '';
          r.children[4].textContent = i === 5 ? (words[5] ? 'NOT zero!' : 'zero while computing') : '';
        });
        setRes([['32-bit sum', '0x00000']]);
      },
      steps: steps, interval: 1400
    });
  }

  /* =====================================================================
   * 3. ptype decoder
   * =================================================================== */
  var PT = {
    l2: { shift: 0, name: 'L2', v: { 1: 'L2_ETHER', 2: 'L2_ETHER_TIMESYNC', 3: 'L2_ETHER_ARP', 4: 'L2_ETHER_LLDP', 5: 'L2_ETHER_NSH', 6: 'L2_ETHER_VLAN', 7: 'L2_ETHER_QINQ', 8: 'L2_ETHER_PPPOE', 9: 'L2_ETHER_FCOE', 10: 'L2_ETHER_MPLS' } },
    l3: { shift: 4, name: 'L3', v: { 1: 'L3_IPV4', 3: 'L3_IPV4_EXT', 4: 'L3_IPV6', 9: 'L3_IPV4_EXT_UNKNOWN', 12: 'L3_IPV6_EXT', 14: 'L3_IPV6_EXT_UNKNOWN' } },
    l4: { shift: 8, name: 'L4', v: { 1: 'L4_TCP', 2: 'L4_UDP', 3: 'L4_FRAG', 4: 'L4_SCTP', 5: 'L4_ICMP', 6: 'L4_NONFRAG', 7: 'L4_IGMP', 8: 'L4_ESP' } },
    tun: { shift: 12, name: 'TUNNEL', v: { 1: 'TUNNEL_IP', 2: 'TUNNEL_GRE', 3: 'TUNNEL_VXLAN', 4: 'TUNNEL_NVGRE', 5: 'TUNNEL_GENEVE', 6: 'TUNNEL_GRENAT', 7: 'TUNNEL_GTPC', 8: 'TUNNEL_GTPU', 9: 'TUNNEL_ESP', 10: 'TUNNEL_L2TP', 11: 'TUNNEL_VXLAN_GPE', 12: 'TUNNEL_MPLS_IN_GRE', 13: 'TUNNEL_MPLS_IN_UDP' } },
    il2: { shift: 16, name: 'INNER_L2', v: { 1: 'INNER_L2_ETHER', 2: 'INNER_L2_ETHER_VLAN', 3: 'INNER_L2_ETHER_QINQ' } },
    il3: { shift: 20, name: 'INNER_L3', v: { 1: 'INNER_L3_IPV4', 2: 'INNER_L3_IPV4_EXT', 3: 'INNER_L3_IPV6', 4: 'INNER_L3_IPV4_EXT_UNKNOWN', 5: 'INNER_L3_IPV6_EXT', 6: 'INNER_L3_IPV6_EXT_UNKNOWN' } },
    il4: { shift: 24, name: 'INNER_L4', v: { 1: 'INNER_L4_TCP', 2: 'INNER_L4_UDP', 3: 'INNER_L4_FRAG', 4: 'INNER_L4_SCTP', 5: 'INNER_L4_ICMP', 6: 'INNER_L4_NONFRAG', 8: 'INNER_L4_ESP' } }
  };
  var PT_ORDER = ['l2', 'l3', 'l4', 'tun', 'il2', 'il3', 'il4'];
  var PT_CLASS = { l2: 'c1', l3: 'c2', l4: 'c3', tun: 'c5', il2: 'c1', il3: 'c2', il4: 'c3' };

  function ptypeDecoder() {
    var root = $('w-ptype');
    if (!root) return;
    var inp = $('pt-hex'), tbody = root.querySelector('tbody'), svg = root.querySelector('svg'), warn = $('pt-warn'), nameEl = $('pt-name');
    var PRE = [['0x00000211', 'IPv4/UDP'], ['0x00000216', '802.1Q'], ['0x00000217', 'QinQ'], ['0x000002c1', 'IPv6+ext/UDP'],
      ['0x01113211', 'VXLAN, inner TCP'], ['0x00000311', 'IPv4 fragment'], ['0x03000011', 'IPv4/ICMP (26.11 result)'], ['0x00000201', 'IHL=3 frame']];
    var pre = $('pt-presets');
    PRE.forEach(function (p) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn small'; b.textContent = p[1];
      b.addEventListener('click', function () { inp.value = p[0]; draw(); });
      pre.appendChild(b);
    });
    function draw() {
      var v = parseInt(inp.value.replace(/^0x/i, ''), 16);
      if (isNaN(v)) v = 0;
      v = v >>> 0;
      tbody.innerHTML = '';
      var names = [], layers = [];
      PT_ORDER.forEach(function (k) {
        var d = PT[k], nib = (v >>> d.shift) & 15, nm = nib ? (d.v[nib] || '(reserved value)') : '';
        if (nib) { names.push(nm); layers.push([k, nm]); }
        var tr = document.createElement('tr');
        if (nib) tr.className = 'on';
        tr.innerHTML = '<td class="mono">RTE_PTYPE_' + d.name + '_MASK</td><td class="mono num">0x' + hex(15 << d.shift, 8) + '</td><td class="mono num">' + nib + '</td><td class="mono">' + (nib ? 'RTE_PTYPE_' + nm : '<span class="muted">unknown / not parsed</span>') + '</td>';
        tbody.appendChild(tr);
      });
      nameEl.textContent = 'rte_get_ptype_name(): "' + (names.length ? names.join(' ') + ' ' : 'UNKNOWN') + '"';
      var inner = v & 0x0fff0000, tun = v & 0xf000;
      warn.textContent = (inner && !tun) ? 'Inconsistent: INNER_* bits without a TUNNEL_* bit. This is the 26.11 IPv4/ICMP case: protocol 1 equals RTE_VXLAN_GPE_TYPE_IPV4, so the ICMP message was decoded as an "inner" IPv4 header. Treat such a value as untrustworthy.' : '';
      // layered drawing
      S.clear(svg);
      var x = 8;
      var W = { l2: 92, l3: 92, l4: 80, tun: 86, il2: 92, il3: 92, il4: 80 };
      if (!layers.length) S.text(svg, 330, 40, 'no layer recognised (RTE_PTYPE_UNKNOWN)', 'svg-label center muted');
      layers.forEach(function (l) {
        var w = W[l[0]], inn = l[0].charAt(0) === 'i';
        S.rect(svg, x, inn ? 24 : 14, w - 4, inn ? 34 : 54, 'svg-box ' + PT_CLASS[l[0]] + (inn ? ' dashed' : ''));
        S.text(svg, x + (w - 4) / 2, inn ? 42 : 42, l[1].replace(/^INNER_/, 'in ').replace(/_/g, ' '), 'svg-label center small');
        x += w;
      });
      if (inner) {
        var start = 8; layers.forEach(function (l) { if (l[0].charAt(0) !== 'i') start += W[l[0]]; });
        if (start < x) S.text(svg, (start + x) / 2, 10, 'inner (encapsulated) headers', 'svg-label center small muted');
      }
    }
    inp.addEventListener('input', draw);
    inp.value = '0x01113211';
    draw();
  }

  /* =====================================================================
   * 4. l2fwd data flow: TX buffer + drain timer (animation)
   * =================================================================== */
  function l2fwdAnim() {
    var root = $('w-l2fwd');
    if (!root) return;
    var svg = root.querySelector('svg');
    var rateIn = $('l2-rate'), sizeIn = $('l2-size'), drainIn = $('l2-drain');
    var RATES = [2000, 5000, 10000, 20000, 50000, 100000, 200000, 400000];
    var SIZES = [4, 8, 16, 32];
    var DRAINS = [25, 50, 100, 200, 0];
    var SCALE = 100;             // simulated microseconds per real second
    var st, layer, slotsG, timerBar, timerTxt, bufTxt;
    function rate() { return RATES[+rateIn.value]; }
    function size() { return SIZES[+sizeIn.value]; }
    function drain() { return DRAINS[+drainIn.value]; }

    var SX = 310, SY = 100, SW = 300, LANE = 100;   // slot strip and packet lane
    function slotX(i) { var n = size(), w = SW / n; return SX + i * w + w / 2; }
    function box(x, y, w, h, t1, t2, cls) {
      S.rect(svg, x, y, w, h, 'svg-box ' + cls);
      S.text(svg, x + w / 2, y + 17, t1, 'svg-label center small bold');
      if (t2) S.text(svg, x + w / 2, y + h + 14, t2, 'svg-label center small mono muted');
    }
    function build() {
      S.clear(svg);
      box(10, 62, 90, 56, 'port 0 RX', 'rx_burst()', 'c4');
      box(140, 62, 130, 56, 'lcore: rewrite MACs', 'l2fwd_mac_updating()', 'c1');
      S.rect(svg, SX - 6, SY - 28, SW + 12, 56, 'svg-box c5 dashed');
      S.text(svg, SX + SW / 2, SY - 36, 'tx_buffer[1]: rte_eth_tx_buffer()', 'svg-label center small mono');
      slotsG = S.group(svg);
      var n = size(), w = SW / n;
      for (var i = 0; i < n; i++) S.rect(slotsG, SX + i * w + 1, SY - 18, w - 2, 36, 'svg-slot');
      bufTxt = S.text(svg, SX + SW / 2, SY + 44, '', 'svg-label center small');
      box(646, 62, 68, 56, 'port 1 TX', 'tx_burst()', 'c4');
      S.arrow(svg, 100, LANE, 138, LANE, 'c7');
      S.arrow(svg, 270, LANE, SX - 8, LANE, 'c7');
      S.arrow(svg, SX + SW + 8, LANE, 644, LANE, 'c7');
      // drain timer bar
      S.rect(svg, SX, 160, SW, 12, 'svg-box c7 ghost');
      timerBar = S.rect(svg, SX, 160, 0, 12, 'svg-box c6');
      timerTxt = S.text(svg, SX + SW / 2, 190, '', 'svg-label center small');
      S.text(svg, SX - 10, 170, 'drain timer', 'svg-label small muted', { 'text-anchor': 'end' });
      layer = S.group(svg);
    }
    function stat(id, v) { var e = $(id); if (e) e.textContent = v; }
    function flush(reason) {
      if (!st.buf.length) return;
      var wsum = 0;
      st.buf.forEach(function (p) {
        p.tx = 680; p.ty = LANE; p.leaving = true;
        var w = st.t - p.born; wsum += w; if (w > st.maxWait) st.maxWait = w;
      });
      st.waitSum += wsum; st.waitN += st.buf.length;
      st.tx += st.buf.length;
      if (reason === 'full') st.full++; else st.timer++;
      st.last = reason === 'full' ? 'buffer full: rte_eth_tx_buffer() sent ' + st.buf.length : 'drain timer: rte_eth_tx_buffer_flush() sent ' + st.buf.length;
      st.buf = [];
    }
    var anim = new CourseJS.Animator({
      root: root, autoplay: 'visible', speed: 1,
      onReset: function () {
        st = { t: 0, next: 0, tick: 0, buf: [], pk: [], rx: 0, tx: 0, full: 0, timer: 0, waitSum: 0, waitN: 0, maxWait: 0, last: '' };
        build();
      },
      onFrame: function (dt) {
        var simDt = dt * SCALE, d = drain(), n = size();
        st.t += simDt;
        // arrivals: Poisson-ish -> deterministic spacing with jitter
        var gap = 1e6 / rate();
        if (st.next === 0) st.next = gap * Math.random();
        while (st.t >= st.next) {
          var p = S.packet(layer, 55, LANE, 14, 12, 'c2');
          p.born = st.next; p.tx = 205; p.ty = LANE; p.phase = 0;
          st.pk.push(p); st.rx++;
          p.slot = st.buf.length; st.buf.push(p);
          if (st.buf.length >= n) flush('full');
          st.next += gap * (0.5 + Math.random());
        }
        // drain timer (l2fwd: if (cur_tsc - prev_tsc > drain_tsc) flush)
        if (d) {
          st.tick += simDt;
          if (st.tick >= d) { flush('timer'); st.tick = 0; }
          timerBar.setAttribute('width', Math.min(1, st.tick / d) * SW);
          timerTxt.textContent = Math.round(st.tick) + ' / ' + d + ' µs';
        } else {
          timerBar.setAttribute('width', 0);
          timerTxt.textContent = 'drain timer off: a partial buffer waits forever';
        }
        // move packets
        var speed = 360 * dt;
        st.pk = st.pk.filter(function (p) {
          if (!p.leaving) {
            if (p.phase === 0 && p._x >= 200) { p.phase = 1; p.body.setAttribute('class', 'svg-packet c1'); }
            if (p.phase === 1) { p.tx = slotX(p.slot); }
          }
          var dx = p.tx - p._x, dy = p.ty - p._y, dist = Math.sqrt(dx * dx + dy * dy);
          if (dist <= speed) S.moveTo(p, p.tx, p.ty);
          else S.moveTo(p, p._x + dx / dist * speed, p._y + dy / dist * speed);
          if (p.leaving && dist <= speed) { p.remove(); return false; }
          return true;
        });
        // the moving packet object from S.packet is a group: remove it via parent
        bufTxt.textContent = 'buffered ' + st.buf.length + ' / ' + n + (st.last ? '  — last: ' + st.last : '');
        stat('l2-rx', CourseJS.fmt(st.rx)); stat('l2-tx', CourseJS.fmt(st.tx));
        stat('l2-full', CourseJS.fmt(st.full)); stat('l2-timer', CourseJS.fmt(st.timer));
        stat('l2-wait', st.waitN ? CourseJS.fmt(st.waitSum / st.waitN, 1) : '-');
        stat('l2-max', st.waitN ? CourseJS.fmt(st.maxWait, 1) : '-');
        stat('l2-t', CourseJS.fmt(st.t / 1000, 2));
      }
    });
    // sliders: rate takes effect at the next arrival; size/drain restart the run
    CourseJS.bindRange('#l2-rate', '#l2-rate-o', function (v) { return CourseJS.fmt(RATES[v]) + ' pps'; });
    CourseJS.bindRange('#l2-size', '#l2-size-o', function (v) { return SIZES[v] + ' pkts'; });
    CourseJS.bindRange('#l2-drain', '#l2-drain-o', function (v) { return DRAINS[v] ? DRAINS[v] + ' \u00b5s' : 'off'; });
    sizeIn.addEventListener('change', function () { anim.reset(); });
    drainIn.addEventListener('change', function () { anim.reset(); });
  }

  CourseJS.ready(function () {
    byteMap();
    cksumStepper();
    ptypeDecoder();
    l2fwdAnim();
  });
})();
