# Research notes: constraints and the constraint solver in MuJoCo Warp

Area: `constraint.py`, `solver.py`, `block_cholesky.py`, `island.py`, `sleep.py` (plus the parts of `io.py`, `types.py`, `forward.py` and `sort.py` they rely on).
Source: `mujoco_warp/_src/` at commit 8f5b9f1. Installed: mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco 4.0.1.
Experiments: `/tmp/claude-0/-home-user-ouramp/2cb48c5e-749c-5a1c-9549-b06105ff67b3/scratchpad/experiments/constraint-solver/exp1.py` .. `exp7.py`, run on CPU (no GPU here).
Every snippet marked **[RAN]** was executed and its printed output is quoted. Snippets marked **[NOT RUN]** are only illustrations.

Line numbers point at the file at this commit and will drift. Cite function names first.

---

## 0. Where this fits in the pipeline

`forward.py` calls the stages in this order (see `fwd_position` around L2925-2955 and `forward` around L3815-3830):

```
collision_driver.collision(m, d)            # fills d.contact (shared across worlds, worldid per contact)
smooth.com_vel(m, d)                         # only if connect/weld need Jdot*v (needs_eq_com_vel)
constraint.make_constraint(m, d)             # builds efc rows: J, D, aref, pos, vel, frictionloss, type, id
sleep.wake_equality(...)                     # sleep only
smooth.crb / factor_m                        # M and its factor (qLD)
island.island(m, d)                          # only with sleep enabled and ISLAND not disabled
... fwd_velocity, fwd_actuation, fwd_acceleration (qacc_smooth, qfrc_smooth)
constraint.regularize_constraint(m, d)       # only for the DISCRETE integrator
solver.solve(m, d)                           # qacc, efc.force, efc.state, qfrc_constraint
```

In `step`, after integration, `wp.copy(d.qacc_warmstart, d.qacc)` (forward.py ~L1596) stores the warmstart for the next step, and `sleep.sleep(m, d)` runs when sleep is enabled.

Public entry points (`mujoco_warp/__init__.py`): `mjw.make_constraint`, `mjw.solve`, `mjw.island`, plus `mjw.forward`, `mjw.step`. Enums: `mjw.ConeType`, `mjw.SolverType`, `mjw.DisableBit`, `mjw.OverflowType`. `noslip` is not exported. It runs inside `solve` when `m.opt.noslip_iterations > 0`.

---

## 1. Concepts, from simple to deep

### 1.1 What a constraint is in MuJoCo: soft and convex

MuJoCo does not treat contacts as hard complementarity constraints (LCP). It solves a **convex optimization problem** in accelerations every step. Classic MuJoCo calls this the "primal" formulation (MuJoCo docs, Computation chapter):

```
qacc* = argmin_a   1/2 (a - qacc_smooth)^T M (a - qacc_smooth)  +  sum_i s_i( J_i a - aref_i )
         "Gauss" term: stay close to the unconstrained motion      constraint cost per row
```

- `qacc_smooth = M^-1 qfrc_smooth`: the acceleration with no constraints.
- `J` (nefc x nv): constraint Jacobian. One row per scalar constraint.
- `aref`: reference acceleration, the spring-damper the constraint should follow: `aref = -b*vel - k*imp*pos`.
- `s_i`: a convex cost that is piecewise quadratic (or quadratic plus linear for friction loss, or a cone distance for elliptic contacts). Its weight is `D_i = 1/R_i`, where `R` is the regularizer that makes constraints soft.
- Constraint force: `efc_force = -ds/d(Ja - aref)`, and `qfrc_constraint = J^T efc_force`.

MJWarp keeps this formulation exactly. It implements the two **primal** solvers (CG and Newton) and leaves out PGS, which is a dual solver.

`types.SolverType` (types.py L593):
```python
CG = mujoco.mjtSolver.mjSOL_CG
NEWTON = mujoco.mjtSolver.mjSOL_NEWTON
# unsupported: PGS
```

**[RAN] exp6.py**: this checks the optimization view numerically. For a tilted box sliding on a plane, it rebuilds the cost in NumPy from `d.efc.J`, `d.efc.D`, `d.efc.aref`, `d.qacc_smooth` and the dense `M` from `mujoco.mj_fullM(mjm, mjd, M)` (MuJoCo 4.0 signature: `(m, d, dst)`). The force from the cost formula matches `d.efc.force`, and `M(qacc - qacc_smooth) = J^T f` holds to about 7e-4:
```
force from cost formula [ 32.0745  32.0745 140.3068   0.      32.0747  32.0747 140.3065   0.    ]
efc.force               [ 32.0746  32.0746 140.3063   0.      32.0746  32.0746 140.3063   0.    ]
M qacc - qfrc_smooth vs J^T f: 0.0007095336913494066
state [1 1 1 0 1 1 1 0]          # 1 = QUADRATIC (active), 0 = SATISFIED (inactive)
```
Random perturbations of `qacc` (size 1e-3) never lowered the cost by more than 1e-3 out of 1.6e4 (relative 1e-7). That is float32 noise: **MJWarp computes in float32** (Warp `float`). Explain this to learners when they compare against MuJoCo C, which uses float64.

### 1.2 Constraint types and row layout (the `efc` arrays)

`types.ConstraintType` (types.py L624): `EQUALITY, FRICTION_DOF, FRICTION_TENDON, LIMIT_JOINT, LIMIT_TENDON, CONTACT_FRICTIONLESS, CONTACT_PYRAMIDAL, CONTACT_ELLIPTIC` (the same values as `mjtConstraint`).

`types.ConstraintState` (types.py L606): `SATISFIED` (0 cost), `QUADRATIC`, `LINEARNEG`/`LINEARPOS` (friction loss saturated), `CONE` (elliptic middle zone).

Rows are grouped by category, in this order per world: **equality (ne) | friction loss (nf) | limits (nl) | contacts**. Many kernels rely on it. For example, `_efc_contact_update` starts at `efcid_start = ne + nf + nl`, and `_eval_constraint` decides `is_equality = efcid < ne` and `is_friction = efcid < ne + nf`.

`make_constraint` (constraint.py L5428) launches the kernels in this order:
1. `_zero_constraint_counts` zeroes ne, nf, nl, nefc, jtdaj_nblock, and the nnz counter.
2. Equality (unless `DisableBit.EQUALITY`): `_equality_connect`, `_equality_weld`, `_equality_joint`, `_equality_tendon`, then flex (`_equality_flex_alloc`, `_equality_flex`, `_equality_flexstrain`).
3. Friction loss (unless `FRICTIONLOSS`): `_friction_dof`, `_friction_tendon`.
4. Limits (unless `LIMIT`): `_limit_slide_hinge`, `_limit_ball`, `_limit_tendon`.
5. Contacts (unless `CONTACT`): `_efc_contact_init` (allocate rows), then the Jacobian kernel (`_efc_contact_jac_sparse` / `_efc_contact_jac_dense`, or the `_flex` variants), then `_add_surface_vel` if `m.flg_surfacevel`, then `_efc_contact_update` (D, aref, pos, type).
6. Sparse only: `_efc_nnz_overflow`. If `m.opt.deterministic & DeterminismType.CONSTRAINT`: `sort.constraints(m, d, efc_nnz)`.
The whole block is skipped when `DisableBit.CONSTRAINT` is set.

**Row allocation is GPU-parallel through atomics.** Each thread does `efcid = wp.atomic_add(nefc_out, worldid, 1)` (contacts reserve `ndim` rows at once: `base_efcid = wp.atomic_add(nefc_out, worldid, ndim)`). So:
- Within a category, row order is **not deterministic** run to run, unless `m.opt.deterministic` includes `DeterminismType.CONSTRAINT` (canonical sort in `sort.constraints`).
- Equality rows come out per kernel (all connects, then welds, then joints, then tendons), not in eq-id order as in MuJoCo C.
- If `nefc` would exceed `njmax`, the counter still grows (`d.nefc` can be > `njmax`!), extra rows are dropped, and `d.overflow |= OverflowType.NEFC`. A contact that straddles the boundary is rejected as a whole (`_reject_contact_efc`).

`types.Constraint` (types.py L2506), the `d.efc` fields and their shapes:

| field | shape | meaning |
|---|---|---|
| `type`, `id` | (nworld, njmax) | ConstraintType; object id (eq id, dof id, jnt id, **contact id** for contacts) |
| `J` | dense: (nworld, njmax_pad, nv_pad); sparse: (nworld, 1, njmax_nnz) | Jacobian |
| `J_rownnz`, `J_rowadr` | sparse: (nworld, njmax); dense: (nworld, 0) | CSR row sizes and offsets |
| `J_colind` | sparse: (nworld, 1, njmax_nnz); dense: (nworld, 0, 0) | CSR column indices |
| `pos`, `margin`, `vel`, `aref`, `frictionloss`, `force` | (nworld, njmax) | per-row values |
| `D` | (nworld, njmax_pad) | constraint "mass" 1/R |
| `state` | (nworld, njmax_pad) | ConstraintState |
| `island` | (nworld, njmax) | island id (sleep only) |
| `jtdaj_adr`, `jtdaj_nrow`, `jtdaj_nblock` | (nworld, njmax) / (nworld,) | row blocks for the sparse Newton J^T D J (one block per contact or equality) |
| `Ma` (warp only) | (nworld, nv) | M @ qacc |
| `Jqvel` (warp only) | (nworld, njmax) | J @ qvel |

Per-world counters on `d`: `d.ne, d.nf, d.nl, d.nefc` (nworld,). Per contact: `d.contact.efc_address` (naconmax, nmaxpyramid) maps a contact to its rows (-1 if none).

**[RAN] exp1.py**: one box resting on a plane (4 contacts, condim 3) plus a hinge with frictionloss, nworld=2:
```
cone pyramidal is_sparse False nv 7 nv_pad 8 njmax 64 njmax_pad 64 naconmax 96
 opt.solver 2 iterations 50 ls_iterations 20 tolerance [1.e-06] ls_tol [0.01] graph_conditional True
 efc.J shape (2, 64, 8) efc.D (2, 64) efc.force (2, 64) contact.efc_address (96, 4)
 ne nf nl nefc [0 0] [1 1] [0 0] [17 17] nacon [8] | mujoco C nefc 17 ncon 4
 efc.type [1 6 6 6 ...]  C: [1 6 6 6 ...]          # 1 = FRICTION_DOF, 6 = CONTACT_PYRAMIDAL
 efc.force [-0. 6.14 6.14 ...] C: [-0. 6.14 6.14 ...]
cone elliptic ... nefc [13 13]   efc.type [1 7 7 7 ...]   # 7 = CONTACT_ELLIPTIC, 3 rows/contact
 efc.force [-0. 24.56 0. -0. 24.56 ...]               # normal row carries force, tangent rows ~0 at rest
```
Notes: `nacon` is a **single global count over all worlds** (8 = 4 contacts x 2 worlds), because contacts live in one shared array with a `worldid` field. Pyramidal: 4 rows per condim-3 contact (`2*(condim-1)`). Elliptic: 3 rows (`condim`). `njmax_pad` is njmax rounded up to the tile size (16).

### 1.3 The sparse Jacobian (CSR) and when it is used

`io.is_sparse(mjm)` (io.py L548): with `jacobian="auto"` the model is sparse iff `nv > 32`. Otherwise it follows `mj_isSparse`. A dense Jacobian is refused for `nv > 60`:
`ValueError: Dense is unsupported for nv > 60 (nv = 66).` **[RAN] exp4.py**

**[RAN] exp5.py**: 6 free boxes (nv 36, sparse):
```
efc.J (1, 1, 2400) J_colind (1, 1, 2400) J_rownnz (1, 200)
nefc 72 rownnz [6 6 6 6 6 6] rowadr [ 0  6 12 18 24 30]
row0 colind [5 4 3 2 1 0] vals [ 0.   0.1 -0.1  1.   0.   0. ]
contact.efc_address[:4] [[ 0  1  2 -1] [ 3  4  5 -1] [ 6  7  8 -1] [ 9 10 11 -1]]
```
Column indices come out in **descending** dof order. `_efc_contact_init` counts nonzeros by walking the two bodies' dof chains up through `dof_parentid` until they meet (common ancestor dofs cancel). `njmax_nnz` defaults to `_default_njmax_nnz` (io.py L2426), or to `njmax*nv` for dense. Overflow sets `OverflowType.NJMAX_NNZ`.

### 1.4 Softness: solref, solimp, impedance, D and aref

`_contact_kbimp` (constraint.py L145) turns `solref = (timeconst, dampratio)` and `solimp = (dmin, dmax, width, mid, power)` into `(k, b, imp)`:
- Positive solref (standard): `k = 1/(dmax^2 * timeconst^2 * dampratio^2)`, `b = 2/(dmax*timeconst)`.
- Negative solref (direct): `k = -solref[0]/dmax^2`, `b = -solref[1]/dmax`.
- Unless `DisableBit.REFSAFE`: `timeconst = max(timeconst, 2*timestep)`. This is why very stiff solref values cannot make a step explode.
- Impedance `imp(x)`, with `x = |pos|/width`, is a sigmoid built from two power curves joined at `mid`, between dmin and dmax. Values are clamped to `[MJ_MINIMP, MJ_MAXIMP]`.

`_efc_row` (constraint.py L214) writes, for the continuous-time integrators:
```
D    = 1 / max(invweight * (1 - imp)/imp, MJ_MINVAL)     # _efc_D: R = invweight*(1-imp)/imp
aref = -k*imp*pos - b*vel                                 # vel = J*qvel
```
The DISCRETE integrator uses a different formula: `f = 1 + h*b + h^2*k*imp`, `R = max(R0/f, Rmin)`, plus a discrete refsafe.

`invweight` is an approximation of the diagonal of `J M^-1 J^T`, taken from `body_invweight0` / `dof_invweight0` / `tendon_invweight0` (computed at qpos0). For pyramidal contacts with condim > 1, `_efc_contact_update` scales it: `invweight = (1 + mu^2) * invweight * 2 * mu^2 * impratio_invsqrt^2`, where `mu = friction[0]`. For elliptic tangent rows, `D` is divided by `impratio_invsqrt^2 * mu0^2/mui^2`.

Warp-only: `m.opt.impratio_invsqrt` stores `1/sqrt(impratio)` (io.py L762), not impratio.

**[RAN] exp1.py**: for the box, pyramidal `efc.D = 38` and elliptic `efc.D = 152` for the normal row, and the frictionloss row has `D = 1.2`. Diagram idea: impedance curve (below).

### 1.5 Contacts: pyramidal and elliptic friction cones

**Activation** (`_efc_contact_init`): a contact gets rows iff `dist - includemargin < 0`, or adhesion != 0 when `m.flg_adhesion`. Contacts whose `type` lacks `ContactType.CONSTRAINT` are skipped (sensor-only contacts).

**Pyramidal** (`ConeType.PYRAMIDAL`, the default): condim c gives `2*(c-1)` rows (1 row for c=1). Each row is the normal plus or minus mu_i times a tangent (or torsional/rolling) direction. In `_efc_contact_jac_dense`: `J = J_normal + frii_sign * J_tangent_i`, with `dimid2 = dimid/2 + 1` and the sign alternating with `dimid & 1`. Each row is a 1-D non-negativity constraint: active (QUADRATIC) when `Jaref < 0`, SATISFIED otherwise. Rows are independent, which makes them cheap and GPU friendly. `nmaxpyramid = max(1, 2*(nmaxcondim-1))`.

**Elliptic** (`ConeType.ELLIPTIC`): condim c gives c rows (normal, then tangents, then torsion and rolling). The rows of one contact are coupled through the cone `N >= mu*||T||`. `_eval_constraint` has three zones:
- top: `N >= mu*T` → SATISFIED, force 0
- bottom: `mu*N + T <= 0` → QUADRATIC on every row
- middle: CONE state, cost `0.5*dm*(N - mu*T)^2`, with `dm = D0/(mu^2 (1+mu^2))` (`_eval_elliptic_middle`)

Because the rows are coupled, the elliptic linesearch has to precompute per-contact quadratics (`quad`, `quad1`, `quad2`) with a barrier sync, and the dense Newton Hessian needs "virtual cone rows" (`_cone_virtual_row`, `_rewrite_cone_rows`, `ctx.cone_coef/weight/base`). **Elliptic also turns off the incremental Hessian path**: `_use_incremental(m)` returns `NEWTON and cone != ELLIPTIC`.

Friction loss rows (`_eval_constraint`, `is_friction` branch): Huber-like. Quadratic for `|jaref| < rf = frictionloss/D`, linear beyond it (LINEARNEG/LINEARPOS) with force saturated at ±frictionloss. In `_efc_row`, `k = 0` for friction rows (no position spring).

### 1.6 The solver loop (`solver.solve`)

`solve(m, d)` (solver.py L5484):
- `nv == 0`: niter=0, return.
- sleep enabled: `island.update_active_dofs`, then `solve_compact` (a dense Newton on the compacted active dofs). Sleep needs Newton.
- `njmax == 0`: `qacc = qacc_smooth`, no solve.
- otherwise: `ctx = create_solver_context(m, d, inplace_cholesky=True)`, `_solve(m, d, ctx)`, then `noslip(m, d)` if `opt.noslip_iterations > 0`, then island mapping if sleep is on.

`_solve` (L5519):
1. `_solve_init_dof`: `qacc = qacc_warmstart` if warmstart is enabled and `nefc>0`, else `qacc_smooth`.
2. `init_context`: `inertia_scale = 1/trace(M)` (`launch_inertia_scale`), `Jaref = J@qacc - aref` (`_init_jaref`), `Ma = M@qacc`, `_update_constraint` (forces and states), `_update_gradient`.
3. CG only: `_solve_init_search_cg_tiled` (search = -M^-1 grad).
4. Iterate `_solver_iteration` either:
   - with `wp.capture_while(nsolving, while_body=_solver_iteration, ...)` when `m.opt.graph_conditional` is True (the default, set to True in io.py L773). This is a CUDA graph conditional loop that stops when every world is done.
   - or with a Python `for _ in range(m.opt.iterations)` loop (the JAX path, and `graph_conditional=False`).
5. Incremental Newton: rebuild `qfrc_constraint` from the gradient (`_qfrc_constraint_from_grad`).

`_solver_iteration` (L5066): **linesearch** → update efc force/state → `qfrc_constraint = J^T force` → **gradient and search direction** → convergence test.

**Gradient**: `grad = Ma - qfrc_smooth - qfrc_constraint` (comment in `_update_gradient`).

**CG** (`SolverType.CG`): preconditioned with M. `Mgrad = M^-1 grad` (`smooth.solve_m`, using the factor from `factor_m`). Search direction by **Hager-Zhang** (`_solve_search_update_cg_tiled`):
`beta = max(0, (y'Mgrad - 2 (y'My)/(d'y) * d'grad)/(d'y))` and `search = -Mgrad + beta*search`. The code comments that it diverges from MuJoCo C here: beta is clamped to >= 0 (HZ+) for float32 robustness. It restarts (beta=0) when `d'y < MJ_MINVAL`.

**Newton** (`SolverType.NEWTON`): `H = M + J^T diag(D*active) J` (dense tiles `_update_gradient_JTDAJ_dense_tiled`, or sparse `_JTDACJ_sparse` over jtdaj blocks), then Cholesky `search = -H^-1 grad` (`_cholesky_factorize_solve`):
- `nv <= H_ONE_TILE_MAX (48)`: a single-tile Cholesky (`_update_gradient_cholesky`).
- `nv <= 96 (_SPARSE_BLOCK_CHOLESKY_DIM)` or `M_tile_full`: blocked Cholesky with 16x16 tiles (`block_cholesky.create_blocked_cholesky_*`).
- larger: a sparse-tiles **reverse** block Cholesky that skips zero tiles (`create_blocked_cholesky_sparse_tiles_factorize_solve_newton_func`, with `h_row_mask`/`h_col_mask` bitmasks and `ctz64`/`clz64`). Its symbolic fill-in comes from `_symbolic_h_tile_cholesky`.
- Incremental (pyramidal Newton): only rows whose QUADRATIC flag flipped update H (`_update_gradient_h_incremental`, `quad_changed_ids`). Worlds with no state change take a "stable fast path": the gradient changes only by a scalar along the same ray (`ctx.grad_scale`), and the factorization is reused (`*_skip_unchanged`).

**Linesearch** (`_linesearch_iterative_kernel`, L1079): exact 1-D minimization along `search`. The cost along the ray is piecewise quadratic: `quad_gauss = [0, search'(Ma - qfrc_smooth), 0.5 search'M search]` plus row terms from `Jaref + alpha*jv`. The algorithm:
1. Try the Newton step from alpha=0 (`lo_alpha_in = -p0[1]/p0[2]`). Accept it if `|derivative| < gtol` and the cost improved.
2. Otherwise bracket [lo, hi] and, for up to `m.opt.ls_iterations` rounds, evaluate **three candidate alphas at once** (Newton step from lo, Newton step from hi, midpoint) with one block-wide reduction (`_compute_efc_eval_pt_3alphas`). Then swap the brackets.
3. Apply `qacc += alpha*search`, `Ma += alpha*mv`, `Jaref += alpha*jv`.
`gtol = tolerance * ls_tolerance * ||search|| / inertia_scale`-style scaling (see the kernel). `ls_iterations` is a **compile-time constant** (`LS_ITERATIONS`), so changing it triggers a new kernel compile. `opt.ls_parallel` was removed in 3.9.1, and `override_model` raises if you use it.

**Termination** (`_solve_done` for Newton, inside `_solve_search_update_cg_tiled` for CG). All terms are scaled by `inertia_scale = 1/trace(M)`:
```
done = alpha == 0
    or 0 < improvement*scale < tolerance
    or ||grad||*scale < tolerance
    or (Newton only) 0.5*newton_decrement*scale < tolerance
stop = done or niter == opt.iterations   # stopping without done sets OverflowType.ITERATIONS and prints a warning
```
`d.solver_niter` is (nworld,). Each world converges independently. `nsolving` counts the worlds still running and drives `capture_while`.

**Warmstart**: `qacc_warmstart` (the last step's qacc). MuJoCo C picks the cheaper of warmstart and qacc_smooth. MJWarp does that only for DISCRETE (`_warmstart_best`, with a TODO to extend it). Other integrators always start from the warmstart when nefc>0.

### 1.7 noslip (post-processing)

`noslip(m, d)` (solver.py L6870): projected Gauss-Seidel over the **friction rows only** (dof/tendon frictionloss and contact friction). It uses the unregularized Delassus `A = J M^-1 J^T` (`_noslip_minv_jt`, `_noslip_delassus`) and small QCQP solves for the elliptic cones (`_qcqp2/3/5`). Normal forces stay fixed. It allocates `noslip_Y (nworld, njmax, nv)` on each call, which costs memory for big models. It raises `NotImplementedError` for DISCRETE. `put_model` checks this too (io.py L682).

### 1.8 Islands (island.py)

An island is a set of kinematic trees coupled by constraints. MJWarp finds islands with a **GPU-parallel disjoint-set union** (`direct_dsu`, `_island_dsu`): each efc row hooks the trees it touches with `wp.atomic_min` (`_dsu_union`: the higher root hooks onto the lower one), and `_dsu_find` does path shortening. `_finalize_dsu` numbers the islands in ascending tree order. `compute_island_mapping` fills `d.tree_island`, `d.nisland`, `d.efc.island`, `island_nv/nefc/ne/nf`, `map_dof2idof`, and the other maps.

Difference from MuJoCo C: in MJWarp **islands are computed only when sleep is enabled** (`forward.py`: `if sleep_enabled and not (DisableBit.ISLAND): island.island(m, d)`). The solve stays per world, over the compacted active dofs. Islands are not solved one by one as MuJoCo C can do. `EnableBit` notes `# unsupported: OVERRIDE, FWDINV, ISLAND, DIAGEXACT`.

### 1.9 Sleeping (sleep.py)

`d.tree_asleep[w, t]`: a value < 0 means awake. It is a countdown that starts at `K_AWAKE_VAL = -(1 + MJ_MINAWAKE)` and goes up by one per still step. A value >= 0 means asleep, and the value is the next tree in a circular linked list of the sleeping island (a lone tree is a self-cycle, `tree_asleep = t`).
- `_tree_can_sleep`: no xfrc_applied or qfrc_applied, and `|dof_length * qvel| < opt.sleep_tolerance` on every dof of the tree. `SleepPolicy.AUTO_NEVER` blocks sleep.
- `sleep()` → `_sweep_awake_trees` → `_check_island_can_sleep` (every tree of the island must be ready) → `_build_cycles` (link the trees, zero qvel and qacc).
- `wake`, `wake_collision`, `wake_tendon`, `wake_equality` wake trees that are touched or perturbed. `update_sleep` recomputes `tree_awake`, `body_awake`, `dof_awake`, `ntree_awake`.
- In `solve`: `island.update_active_dofs` builds the `dof_cdof` / `cdof_dof` maps. Then `solve_compact` gathers M, J and vectors into `nvmax_pad`-sized buffers, runs the dense Newton on a `dataclasses.replace`'d (m, d) with `nv=nvmax_pad, is_sparse=False`, and scatters the results back. Sleeping dofs stay at 0.
- Requirements: **Newton only** (`ValueError: sleeping requires the Newton solver (got solver=CG)` **[RAN]**). No flex equality with sleep. `make_data(..., nvmax=...)` sets the capacity, and overflow gives `OverflowType.NVMAX`.

**[RAN] exp5.py**: 6 separated boxes, sleep enabled, elliptic:
```
nisland [6] tree_island [0 1 2 3 4 5]
after 1500 steps tree_asleep [0 1 2 3 4 5] ntree_awake [0] nefc [0]
```
Every box became a self-cycle, and asleep trees produce no efc rows. That took 1.5 min on CPU, so use fewer steps or a GPU in the course.

---

## 2. Verified API snippets

### 2.1 Inspect efc rows **[RAN, exp1.py]**
```python
import mujoco, numpy as np, mujoco_warp as mjw
mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2)            # njmax default from io._default_njmax (64 here)
mjw.forward(m, d)
n = d.nefc.numpy()[0]
print(d.ne.numpy(), d.nf.numpy(), d.nl.numpy(), d.nefc.numpy(), d.nacon.numpy())
print(d.efc.type.numpy()[0, :n], d.efc.state.numpy()[0, :n], d.efc.force.numpy()[0, :n])
```

### 2.2 njmax overflow, the number one pitfall **[RAN, exp3.py]**
```python
m.opt.warn_overflow = 0                     # silence printf warnings (bool or OverflowType mask)
d = mjw.make_data(mjm, nworld=2)            # default njmax=64
for _ in range(20): mjw.step(m, d)
print(d.njmax, d.nefc.numpy(), d.overflow.numpy(), bool(d.overflow.numpy()[0] & mjw.OverflowType.NEFC))
# -> 64 [80 80] [1 1] True       (5 stacked boxes need 80 pyramidal rows)
d = mjw.make_data(mjm, nworld=2, njmax=128)
# -> nefc [80 80] overflow [0 0]
```
With warnings on, the kernel prints `nefc overflow - please increase njmax beyond 64` on every step. Dropped rows mean **missing contacts**: objects sink through each other without any error.

### 2.3 Solver choice and iteration counts **[RAN, exp2.py]** (5 stacked boxes, nv=30, nworld=4 with different initial velocities, 100 steps)
```
Newton pyramidal  niter mean [1.8  3.03 3.22 4.25] max 8
Newton elliptic   niter mean [1.01 1.31 1.29 1.49] max 5
CG pyramidal      niter mean [ 9.71 20.49 27.93 26.32] max 73
CG elliptic       niter mean [ 3.69 19.8  17.19 19.35] max 61
C Newton niter mean 0.99 | C CG niter mean 16.1
```
(That run used the default njmax=64 and overflowed. Read it as qualitative only: Newton needs about 10x fewer iterations, and each world has its own count.)

### 2.4 Iteration cap and `OverflowType.ITERATIONS` **[RAN, exp3.py]**
```python
mjm.opt.solver = mujoco.mjtSolver.mjSOL_CG; mjm.opt.iterations = 5
m = mjw.put_model(mjm); m.opt.warn_overflow = 0
d = mjw.put_data(mjm, mjd, njmax=128); mjw.forward(m, d)
d.solver_niter.numpy(), bool(d.overflow.numpy()[0] & mjw.OverflowType.ITERATIONS)
# CG iters 1 -> niter 1, ITER True, qacc[2]=-0.49 ; iters 5 -> 0.058 (still wrong) ; iters 20 -> niter 13, ITER False, 0.0259
# Newton: niter 1 for all caps (converged from warmstart)
```

### 2.5 Per-world tolerance (Option arrays are batched with `"*"`) **[RAN, exp7.py]**
```python
m.opt.tolerance = wp.array([1e-2, 1e-4, 1e-6, 1e-8], dtype=float)  # kernels read tolerance[worldid % shape[0]]
mjw.forward(m, d); d.solver_niter.numpy()   # -> [0 2 4 5]
```
`opt.tolerance`, `ls_tolerance`, `timestep`, `impratio_invsqrt`, `noslip_tolerance` and `sleep_tolerance` all have shape `("*",)`. `iterations`, `ls_iterations`, `cone` and `solver` are Python ints (one value for all worlds).

### 2.6 Running the constraint stages by hand **[RAN, exp7.py]**
```python
mjw.forward(m, d); q = d.qacc.numpy().copy()
mjw.make_constraint(m, d)   # rebuild rows from current d.contact & kinematics
mjw.solve(m, d)             # needs qacc_smooth, qfrc_smooth, M factor from forward
np.abs(d.qacc.numpy() - q).max()   # -> 0.0
```

### 2.7 Disabling parts **[RAN partly, exp7.py used WARMSTART]**
```python
m.opt.disableflags |= mjw.DisableBit.WARMSTART      # or CONTACT, EQUALITY, FRICTIONLOSS, LIMIT, CONSTRAINT, REFSAFE
m.opt.disableflags &= ~mjw.DisableBit.WARMSTART
```
Or use `mjw.override_model(m, {"opt.solver": "CG", "opt.iterations": 10, "opt.cone": "elliptic"})`. String overrides go through `io.override_model` (io.py L4064). They also accept `"opt.deterministic": True` (= `DeterminismType.ALL`) and `"opt.jacobian"` on an `MjModel` only. [NOT RUN in this form]

### 2.8 Unsupported-feature errors **[RAN, exp4.py]**
```
PGS              -> NotImplementedError mjSOL_PGS is unsupported.
noslip+discrete  -> NotImplementedError noslip solver not implemented for the discrete integrator.
noslip+euler     OK
sleep+CG         -> ValueError sleeping requires the Newton solver (got solver=CG)
dense nv=66      -> ValueError Dense is unsupported for nv > 60 (nv = 66).
auto nv=66       -> is_sparse True
```

### 2.9 Optimization-view notebook cell **[RAN, exp6.py]**: see section 1.1. It is a strong "aha" cell: rebuild the cost and forces in NumPy and match them against MJWarp.

---

## 3. Data flow between stages

```
d.contact (naconmax, shared over worlds; dist, pos, frame, friction, solref, solimp, dim, worldid, geom)
   │  _efc_contact_init: active? reserve ndim rows -> contact.efc_address[conid, :]
   ▼
efc rows (per world, prefix [0, nefc)):  [ eq | frictionloss | limits | contacts ]
   J (dense tile or CSR), Jqvel, pos, margin, vel, D, aref, frictionloss, type, id
   │  (+ M, qLD from factor_m; qacc_smooth, qfrc_smooth from fwd_acceleration; qacc_warmstart from last step)
   ▼
solver context (types.SolverContext, create_solver_context):
   Jaref (nworld,njmax), search (nworld,nv), mv, jv, quad (vec3 per row), grad, Mgrad (CG), h/hfactor (Newton, nworld,nv_pad,nv_pad),
   alpha, improvement, done, inertia_scale, quad_changed_ids (incremental), cone_* (elliptic dense Newton)
   │ iterate: linesearch -> efc force/state -> qfrc_constraint -> grad/search -> done?
   ▼
outputs: d.qacc, d.efc.force, d.efc.state, d.qfrc_constraint, d.efc.Ma, d.solver_niter, d.overflow
   │ step: qacc_warmstart <- qacc ; integrate ; sleep()
```
Memory: dense `efc.J` is `nworld*njmax_pad*nv_pad` floats. Newton `h` is `nworld*nv_pad^2` (plus `hfactor` when nv > 48). For nworld=8192, njmax=512, nv=60 (nv_pad 64), dense J alone is about 1 GB in float32. Size njmax carefully.

---

## 4. Diagram and animation ideas

1. **"Soft constraint spring" animation**: a ball sinks a little into a floor. Show `pos` (penetration) and `vel` arrows, and a spring-damper icon whose stiffness comes from solref. A slider for timeconst and dampratio changes how the ball settles (underdamped vs critically damped). Plot `aref = -b*vel - k*imp*pos` over time.
2. **Impedance curve (solimp)**: an SVG plot of `imp(x)` from `_contact_kbimp`, with handles for dmin, dmax, width, mid and power. Mark the `[MJ_MINIMP, MJ_MAXIMP]` clamps.
3. **The efc row strip**: a horizontal strip per world, colored blocks `eq | friction | limit | contact`. Contacts expand into 4 rows (pyramidal, condim 3) or 3 rows (elliptic). Arrows go from `contact.efc_address[conid]` to its rows. Animate rows popping in through `atomic_add` in random order (to show non-determinism), then the sorted version with `DeterminismType.CONSTRAINT`. A red "njmax" line: rows past it fade out and an `OverflowType.NEFC` badge lights up.
4. **Friction cones**: a 3D-ish CSS/SVG view of the pyramid (4 edge vectors `n ± mu t_i`) next to a circular cone. Animate a force vector moving from inside to outside the cone. On the elliptic side, color the three zones (SATISFIED top, CONE middle, QUADRATIC bottom) as in `_eval_constraint`.
5. **The cost landscape**: a 2-D contour plot of `0.5||a - a_smooth||_M^2 + sum s_i(J_i a - aref_i)` for a 2-dof toy. Half-planes `J_i a - aref_i < 0` are shaded where a row is active. Animate Newton iterates (1-2 steps) vs CG iterates (zigzag, many steps) to the same minimum.
6. **The linesearch along the ray**: a 1-D piecewise-quadratic cost curve with kinks where rows change state. Show three probe points per iteration (lo Newton step, hi Newton step, midpoint) and the bracket shrinking. Label them `lo_next_alpha`, `hi_next_alpha`, `mid_alpha`.
7. **Newton Hessian assembly**: animate `H = M + J^T D J` as tiles (16x16) filling a matrix. Active rows add outer products, then a blocked Cholesky sweeps tile by tile. For large nv, gray out the zero tiles that the sparse-tiles variant skips (bitmask `h_row_mask`).
8. **Incremental update**: two consecutive iterations where only 2 rows flip state. Highlight those rows, and show H being updated only by their rank-1 terms. Other worlds take the "stable fast path" (skip refactor).
9. **Per-world convergence on the GPU**: a grid of 64 worlds, each lighting up green when `done`. A counter `nsolving` ticks down, and the `capture_while` loop stops at 0. Compare it with a fixed `for` loop that runs every iteration.
10. **Islands and DSU**: trees drawn as nodes. Contacts and equality constraints appear as edges, and union-find merges them into colored islands (animated `atomic_min` hooks to the lowest root).
11. **Sleep cycle**: boxes that come to rest. Each tree's countdown goes from `-(1+MJ_MINAWAKE)` to -1, then the island turns into a circular linked list (arrows t0→t2→t5→t0) and fades to gray. A push wakes the whole cycle.
12. **noslip**: before and after views of a box creeping on a slope. Soft friction shows a small drift, and noslip removes it. Show the PGS sweep over friction rows only.

---

## 5. Pitfalls, unsupported features, performance and GPU vs CPU

- **njmax / nconmax overflow** is silent apart from a printf and the `d.overflow` bits. Default njmax comes from a small heuristic (`_default_njmax`: about 53 rows rounded up to 64 unless there are hfields, flex or SDF). Pass `njmax=` and `nconmax=`/`naconmax=` to `make_data`/`put_data`. Check `d.overflow` and `d.nefc.numpy().max()`. Note that `d.nefc` can be larger than `njmax`.
- **`nacon` is global**, not per world. `naconmax` is the total over all worlds. `nconmax` is the per-world value, multiplied by nworld.
- **Pyramidal uses about twice the rows of elliptic** for condim 3 (4 vs 3), and 10 vs 6 for condim 6. Size njmax for the cone you use.
- **Elliptic** disables the incremental Newton path. It needs barrier-synchronized per-contact quads in the linesearch and extra cone buffers. Expect it to be slower per iteration, but it often needs fewer iterations (exp2).
- **float32** everywhere: expect about 1e-4 relative differences from MuJoCo C. Very small `tolerance` (< about 1e-7 relative) cannot be met (see the `_ALPHA_NOISE_EPS = 8 * float32 eps` comment in solver.py). The tests compare cost within 2.5% (`solver_test.test_solve`: `mjwarp_cost <= mj_cost * 1.025`).
- **Row order** is non-deterministic within a category unless `m.opt.deterministic |= DeterminismType.CONSTRAINT` (and `ATOMICS` for bit-identical reductions). This matters for reproducible RL rollouts and for comparing `efc_*` arrays with MuJoCo C.
- **`graph_conditional`** (default True) uses `wp.capture_while`, a CUDA graph conditional node, so converged batches stop early on the GPU. With JAX or `graph_conditional=False`, all `opt.iterations` run (converged worlds return early inside the kernels, but launches still happen). So a high `iterations` costs real time without conditionals.
- **CPU (this machine)**: no CUDA graphs. Side streams (`side_stream`) and the fused paths that need `d.qacc.device.is_cuda and nworld >= 4*sm_count` are off. Kernel compile on first use takes about 25 s and is cached in `~/.cache/warp`. Several code paths differ (for example `threads_per_group = 1 if elliptic and cpu`), so CPU timing says nothing about GPU timing.
- **`ls_iterations` and cone/solver/sparsity are compile-time** (`cache_kernel` factories). Changing them recompiles kernels. `iterations` and `tolerance` are runtime values.
- **Dense limit nv <= 60**. `jacobian="auto"` switches to sparse at nv > 32. The Newton Cholesky path depends on nv: <=48 single tile, <=96 blocked, else sparse tiles.
- **Unsupported**: PGS solver. noslip with DISCRETE. Sleep with CG. Flex equality with sleep. `EnableBit.ISLAND` (MuJoCo C's per-island solve) is not supported, and islands exist only for sleep. `opt.ls_parallel` was removed.
- **Warmstart**: `qacc_warmstart` is only updated by `step` (forward.py ~L1596), not by `forward`. Calling `forward` repeatedly starts from a stale warmstart, which is harmless but affects iteration counts. MJWarp does not choose "best of warmstart vs smooth" except for DISCRETE.
- **noslip memory**: `(nworld, njmax, nv)` scratch per call.
- **Sleep** needs `nvmax` capacity (compacted dofs). Asleep trees generate no rows (nefc 0 in exp5), which is a big win for scenes at rest.
- **Debugging**: look at `d.solver_niter`, `d.overflow` (bit test with `mjw.OverflowType.*`), and `d.efc.state` (how many QUADRATIC/CONE rows). `mjw.get_data_into(mjd, mjm, d, world_id=i)` copies one world into MjData for MuJoCo viewers and tools. It truncates to `min(nefc, njmax)`.

---

## 6. Suggested chapters (easy to hard)

1. **Contacts and constraints as optimization**: the Gauss principle, soft constraints, and why MuJoCo is convex rather than an LCP. Notebook: rebuild the cost from `d.efc` (exp6) and verify the forces.
2. **Anatomy of the efc arrays**: ne/nf/nl/contacts, efc fields and shapes, `contact.efc_address`, dense vs CSR Jacobian, njmax/njmax_pad, and overflow (exp1, exp3, exp5).
3. **Softness: solref, solimp, impedance, D and aref**: `_contact_kbimp`, `_efc_row`, refsafe, impratio. Interactive impedance and spring plots, and a drop-test sweep over solref.
4. **Friction: frictionloss, pyramidal vs elliptic cones, condim 1/3/4/6**: row counts, states, adhesion. Animated cone zones.
5. **Inside `make_constraint`**: the kernel order, atomics for row allocation, determinism and `sort.constraints`, and the disable flags.
6. **The primal solvers: CG vs Newton**: gradient, M-preconditioned CG with Hager-Zhang, Newton with `H = M + J'DJ`. Iteration-count experiments (exp2) and the termination criteria (`_solve_done`).
7. **The exact linesearch**: the piecewise-quadratic cost along a ray, the three-alpha bracketing, and `ls_iterations`/`ls_tolerance`.
8. **GPU-scale solving**: per-world convergence, `capture_while`/graph conditionals, tile-based Cholesky (`block_cholesky.py`), sparse tiles, the incremental Hessian and the stable fast path, and float32 limits.
9. **noslip and the classic-MuJoCo differences**: PGS missing, noslip limits, warmstart differences, unsupported flags. A migration checklist from MuJoCo C.
10. **Islands and sleeping**: DSU islands, the sleep countdown and cycles, wake triggers, `solve_compact`/nvmax, and why asleep scenes are cheap.
11. **Tuning and debugging the solver for RL at scale** (capstone): choosing njmax/nconmax, cone, solver, iterations and tolerance; reading `d.overflow` and `solver_niter`; and timing on a Colab GPU with `mjwarp-testspeed`.
