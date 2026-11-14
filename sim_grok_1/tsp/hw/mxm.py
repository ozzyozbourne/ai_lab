"""MXM: one matrix plane.

A plane holds `lanes x lanes` weights (ledger G11), all zero at reset.  The
toy instruction set has two instructions (ledger B9):

- Iw(dtype, entries): install whole weight rows sampled from streams; at
  most `iw_max_streams` streams per instruction (ledger B8).  The rows take
  effect at the end of cycle t + d_func - 1 (ledger T11).
- Abc(dtype, src, out, n_rows): out[r] = sum_c W[r][c] * x[c] for r < n_rows,
  zero for r >= n_rows (ledger B19).  The result appears d_func cycles after
  dispatch (ledger T12).

Arithmetic (ledger B6, B7):
- int8: weights and activation widened to int64, summed, wrapped to int32.
- fp16: weights and activation converted to float64, accumulated in
  ascending lane order (acc += W[:, c] * x[c] for c = 0, 1, ...), rounded once
  to float32.
"""

import numpy as np

from .. import isa
from ..errors import ProgramError

MXM_DTYPES = ("int8", "fp16")


def iw_stream_count(instr):
    """Number of streams an Iw samples: one plane per byte of each row."""
    return len(instr.entries) * isa.width(instr.dtype)


class MxmPlane:
    """Weight state of one MXM plane."""

    def __init__(self, lanes, iw_max_streams):
        self.lanes = lanes
        self.iw_max_streams = iw_max_streams
        # Exact values of the installed weights (int8 and fp16 are both exact in float64).
        self.weights = np.zeros((lanes, lanes), dtype=np.float64)
        # Data type each row was installed with; None = never installed (zero).
        self.row_dtype = [None] * lanes

    def check_iw(self, instr):
        """Structural limits of an Iw (ledger B8, G11)."""
        if instr.dtype not in MXM_DTYPES:
            raise ProgramError(f"Iw does not accept {instr.dtype}")
        if iw_stream_count(instr) > self.iw_max_streams:
            raise ProgramError(
                f"Iw samples {iw_stream_count(instr)} streams; at most {self.iw_max_streams} allowed"
            )
        for row, _ in instr.entries:
            if not 0 <= row < self.lanes:
                raise ProgramError(f"Iw row {row} out of range")

    def install(self, dtype, rows):
        """Commit rows: list of (row index, array of `lanes` values of dtype)."""
        for row, values in rows:
            self.weights[row, :] = np.asarray(values).astype(np.float64)
            self.row_dtype[row] = dtype

    def abc(self, dtype, x, n_rows):
        """Matrix-vector product with the installed weights; returns `lanes` values (int32 or fp32)."""
        if dtype not in MXM_DTYPES:
            raise ProgramError(f"Abc does not accept {dtype}")
        if not 0 <= n_rows <= self.lanes:
            raise ProgramError(f"Abc n_rows {n_rows} out of range")
        for r in range(n_rows):
            if self.row_dtype[r] not in (None, dtype):
                raise ProgramError(f"Abc {dtype}: weight row {r} was installed as {self.row_dtype[r]}")
        w = self.weights[:n_rows, :]
        if dtype == "int8":
            acc = w.astype(np.int64) @ np.asarray(x).astype(np.int64)
            out = np.zeros(self.lanes, dtype=np.int32)
            out[:n_rows] = acc.astype(np.int32)  # wrap to int32 (B6)
            return out
        xf = np.asarray(x).astype(np.float64)
        acc = np.zeros(n_rows, dtype=np.float64)
        for c in range(self.lanes):
            acc += w[:, c] * xf[c]
        out = np.zeros(self.lanes, dtype=np.float32)
        out[:n_rows] = acc.astype(np.float32)
        return out
