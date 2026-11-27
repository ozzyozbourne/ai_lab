# Research notes: the MJWarp simulation pipeline

Area: `forward.py`, `smooth.py`, `passive.py`, `sensor.py`, `inverse.py`, `derivative.py`, `set_const.py`, `history.py`.

Paths below are relative to `mujoco_warp/_src/` in the source clone at
`scratchpad/src/mujoco_warp` (commit 8f5b9f1). Experiment scripts are in
`scratchpad/experiments/pipeline/` (e1.py to e10.py). They ran on CPU with the installed
mujoco-warp 4.0.1 and warp-lang 1.19.0.

> **Version warning for authors.** The cloned source is **newer than the pip release**.
> `forward.py` has 3908 lines in the clone and 3604 in the installed 4.0.1. `smooth.py`,
> `derivative.py` and `io.py` also differ a lot. The list of names exported from
> `mujoco_warp/__init__.py` is the same in both, and every snippet below calls only that
> public API. Colab installs a pip release, so course code should use only `mjw.*` names.
> When a chapter quotes internals such as line numbers or private helpers, say they come
> from the dev tree. Internals that exist only in the clone: `_slew_limit`, `_rk_stage_time`
> and `needs_eq_com_vel` in forward.py.

---

## 0. The big picture in one paragraph

`mjw.step(m, d)` runs `forward(m, d)` and then one integrator (`forward.py: step`).
`forward` is a fixed sequence of stages. **Position**: kinematics, center of mass,
collision, constraints, inertia. **Velocity**: velocity kinematics, passive forces, bias
forces. **Actuation**: actuator forces. **Acceleration**: sum the forces and solve
`M qacc_smooth = qfrc_smooth`. **Constraint solve**: `solver.solve` gives `qacc`.
Sensors run after the position, velocity and acceleration stages. Every array in `Data`
has a leading `nworld` axis. Every kernel is launched with `dim=(nworld, n_things)` and
starts with `worldid, i = wp.tid()`, so thousands of worlds run in one launch. Model
parameters can be batched per world too: kernels read `param[worldid % param.shape[0]]`.

---

## 1. Concepts, simple to deep

### 1.1 State and outputs (types.py `Data` docstring, line ~2560)

The **state** is what the integrator advances: `time (nworld,)`, `qpos (nworld,nq)`,
`qvel (nworld,nv)`, `act (nworld,na)`, `history (nworld,nhistory)` and
`plastic (nworld,nplastic)`. The **user inputs** are `ctrl (nworld,nu)`,
`qfrc_applied (nworld,nv)`, `xfrc_applied (nworld,nbody)` (spatial_vector),
`mocap_pos` and `mocap_quat`, and `eq_active`. Everything else is a derived **output**
that `forward` recomputes. `qacc_warmstart` is carried from step to step: `_advance` ends
with `wp.copy(d.qacc_warmstart, d.qacc)`.

Dtypes (checked in e1.py): floats are `float32`. Positions are `wp.vec3`, quaternions
`wp.quat`, and spatial quantities `wp.spatial_vector` (6: rotation then translation).
Inertias are `vec10`. So `d.xpos.shape == (nworld, nbody)` and each element is a vec3;
`.numpy()` gives `(nworld, nbody, 3)`.

### 1.2 Stage order: `forward()` (forward.py `_forward`, ~line 3809)

```
_forward(m, d):
  check_discrete(m)                      # validates discrete-integrator / flex combos
  fwd_position(m, d, factorize=False)
    fwd_kinematics: [sleep.wake] kinematics -> com_pos -> camlight -> flex -> tendon
    collision_driver.collision          (if m.opt.run_collision_detection)
    [com_vel if connect/weld eq present] constraint.make_constraint
    crb -> tendon_armature -> (factor_m if factorize) -> [island] -> transmission
    [derivative.eff_build if DISCRETE]
  d.sensordata.zero_(); sensor_pos; energy_pos
  fwd_velocity(m, d)
    _actuator_velocity, _tendon_velocity, com_vel, passive, rne, tendon_bias
    [eff_shift if DISCRETE]
  sensor_vel; energy_vel
  m.callback.control(m, d)   (if set and actuation enabled)
  fwd_actuation(m, d)
  fwd_acceleration(m, d, factorize=True)  # fused factorize+solve for qacc_smooth
  solver.solve(m, d)                      # constraint solve -> qacc, qfrc_constraint
  [discrete free-body gyro]
  rne_postconstraint (only if opt.run_rne_postconstraint or an acc sensor needs it)
  sensor_acc(skip_rne_postconstraint=True)
```

Source detail worth teaching: `_forward` calls `fwd_position(factorize=False)` and lets
`fwd_acceleration(factorize=True)` run a **fused factor and solve**
(`smooth.factor_solve_i`). If you call the stages yourself, the public defaults are
`fwd_position(factorize=True)` and `fwd_acceleration(factorize=False)`, which uses the
stored `qLD`. Both orders are valid. Do not mix them: `fwd_position(..., factorize=False)`
followed by `fwd_acceleration()` would solve with a stale factor.

`step` (forward.py ~3853):
```python
forward(m, d)
if   integrator == EULER:        euler(m, d)
elif integrator == RK4:          rungekutta4(m, d)
elif integrator in (IMPLICITFAST, IMPLICIT): implicit(m, d)
elif integrator == DISCRETE:     discrete(m, d)
```

`step1` and `step2` split the step around the control callback, as `mj_step1` and
`mj_step2` do in C. `step1` covers position, velocity and sensors and then calls
`callback.control`. `step2` covers actuation, acceleration, solve, acc sensors and the
integrator. **With RK4, step2 falls back to Euler.** The source comment says
`# note: RK4 defaults to Euler`. Verified in e3.py: step1, then setting ctrl, then step2
gives qpos identical to step (diff 0.0).

### 1.3 Where each stage writes in `Data` (cheat sheet)

| Stage / function (file) | Reads | Writes |
|---|---|---|
| `smooth.kinematics` = kinematics1+2 (smooth.py 464-520) | qpos, mocap_*, body_pos/quat, jnt_* | xpos, xquat, xanchor, xaxis, xipos, xiquat, geom_xpos, geom_xquat, site_xpos, site_xquat |
| `smooth.com_pos` (1106) | xipos, body_mass | subtree_com, cinert, cdof |
| `smooth.camlight` (1285) | xpos, subtree_com | cam_xpos, cam_xmat, light_xpos, light_xdir |
| `smooth.flex` (801) | qpos-derived | flexvert_xpos, flexedge_length, flexedge_J, ... |
| `smooth.tendon` (5532) | site/geom poses, cdof | ten_length, ten_J, ten_wrapadr/num, wrap_obj, wrap_xpos |
| `collision_driver.collision` | geom poses | d.contact.*, nacon |
| `constraint.make_constraint` | contacts, limits, eqs | d.efc.*, ne, nf, nl, nefc |
| `smooth.crb` (1418) | cinert, cdof | crb, M (CSR, nC values) |
| `smooth.tendon_armature` | ten_J | adds to M |
| `smooth.factor_m` (1832) | M | qLD, qLDiagInv |
| `smooth.transmission` (3889) | joints/tendons/sites | actuator_length, actuator_moment (sparse: moment_rownnz/rowadr/colind) |
| `_actuator_velocity` / `_tendon_velocity` (forward.py) | qvel, moments, ten_J | actuator_velocity, ten_velocity |
| `smooth.com_vel` (3245) | qvel, cdof | cvel, cdof_dot |
| `passive.passive` (passive.py 5252) | qpos, qvel, ... | qfrc_spring, qfrc_damper, qfrc_gravcomp, qfrc_fluid, qfrc_adhesion, qfrc_passive |
| `smooth.rne` (2036) | cvel, cdof_dot, cinert, gravity | cacc (bias acc), cfrc_int, qfrc_bias |
| `smooth.tendon_bias` | tendon armature | adds to qfrc_bias |
| `fwd_actuation` (forward.py 3592) | ctrl (or delayed ctrl), act, actuator_length/velocity | act_dot, actuator_force, qfrc_actuator |
| `fwd_acceleration` (3758) | qfrc_passive, qfrc_bias, qfrc_actuator, qfrc_applied, xfrc_applied | qfrc_smooth, qacc_smooth |
| `solver.solve` | efc, qacc_smooth | qacc, qfrc_constraint, efc.force, efc.Ma |
| `smooth.rne_postconstraint` (2623) | efc forces, xfrc_applied | cacc, cfrc_ext, cfrc_int |
| `sensor_pos`, `sensor_vel`, `sensor_acc` (sensor.py 933, 1588, 2974) | stage outputs | sensordata |
| `energy_pos`, `energy_vel` (3368, 3458) | xipos, cvel ... | energy[0] potential, energy[1] kinetic |
| integrator (`_advance`) | qacc, qvel, act_dot | qpos, qvel, act, time, history, qacc_warmstart |

Force bookkeeping (forward.py `_qfrc_smooth` kernel, ~3723):
`qfrc_smooth = qfrc_passive - qfrc_bias + qfrc_actuator + qfrc_applied`, and then
`xfrc_accumulate` adds `J^T xfrc_applied`.
`qfrc_passive = spring + damper + gravcomp (unless the actuator applies it) + fluid + adhesion`
(passive.py `_qfrc_passive_kernel`, ~823).

### 1.4 Kinematics: parallel over branches (smooth.py `_kinematics_branch`, ~line 62)

`kinematics1` launches `dim=(nworld, m.nbranch)`. Each thread walks **one root-to-leaf
branch** of the body tree in order (`body_branches[body_branch_start[b]:...+1]`). For
each body it applies the parent pose, the fixed `body_pos` and `body_quat` offset, and
then each joint. A FREE joint sets pose from qpos directly. A BALL joint multiplies by the
normalized quaternion. A SLIDE joint translates along `xaxis * (qpos - qpos0)`. A HINGE
joint rotates by `axis_angle_to_quat(axis, qpos - qpos0)`. Joints that rotate off-center
use an anchor correction: `xpos = xanchor - rot(jnt_pos)`. Mocap bodies take
`mocap_pos` and `mocap_quat`.

Verified on humanoid (e9.py): `nbody=17`, `nbranch=5`,
`body_branches=[1,2 | 1,3,4,5,6,7 | 1,3,4,8,9,10 | 1,11,12,13 | 1,14,15,16]`.
**Shared prefixes such as the torso (body 1) are recomputed redundantly in every branch.**
That costs a few extra flops but needs no synchronization between tree levels, and it
runs in a single kernel launch. `kinematics2` is then embarrassingly parallel over bodies,
geoms and sites (`_compute_body_inertial_frames`, `_geom_local_to_global`,
`_site_local_to_global`).

The same branch-walk pattern is used for `com_vel` (`_comvel_branch`) and for the forward
pass of RNE (`_cacc_branch`).

### 1.5 Subtree sums: contiguous ranges instead of level loops

`com_pos` (`_subtree_com`), `crb` (`_crb_subtree`) and the RNE backward pass
(`_cfrc_subtree`) use the fact that a body's subtree is the **contiguous index range**
`[b, b + body_subtreenum[b])`. The docstrings say exactly this. One thread per body sums
its range, with no per-level launches. Humanoid `body_subtreenum = [17,16,1,8,7,3,...]`.
The world body (0) is handled by a separate kernel (`_subtree_com_world`, with a tiled
version for many roots, `WORLD_SUM_BLOCK = 128`).

Outputs of `com_pos`: `subtree_com`, `cinert` (10-vector inertia about the subtree com of
the body's root, `_cinert`), and `cdof` (the motion axis of each dof in com coordinates,
`_cdof`). `cdof` is the column of the Jacobian, so it is the key ingredient of M, RNE and
all Jacobians.

### 1.6 Inertia matrix M and its factorization (smooth.py `crb`, `factor_m`, `factor_solve_i`, `solve_m`)

* `crb`: `_crb_subtree` makes the composite inertia `crb` per body. Then `_M` launches
  `dim=(nworld, nv)` to fill the **CSR lower triangle including the diagonal**: row i
  holds the entries for the ancestors of dof i, then i itself. It adds `dof_armature` and
  actuator armature on the diagonal.
  Verified (e1.py, 2-link pendulum): `M_rownnz=[1,2]`, `M_rowadr=[0,1]`,
  `d.M[0]=[M00, M10, M11]=[0.669, 0.209, 0.090]`, which matches
  `mujoco.mj_fullM(mjm, mjd, full)`.
  (MuJoCo 4 API: `mj_fullM(m, d, dst)`, and the C field is `mjd.M`, not `qM`.)
* `M` has shape `(nworld, nC)`. `nC` is the number of non-zeros (humanoid: nv=27,
  nC=243).
* **Block structure per kinematic tree.** `m.M_tiles` is a list of `TileSet(size, adr,
  elemid)`. Each tree's dof block is factored on its own:
  * compact blocks (diagonal only): reciprocal diagonal into `qLDiagInv`
  * small full blocks: scalar Cholesky (`_small_cholesky_factorize_block`, used when
    `elemid.size == 0`)
  * larger dense blocks: Warp **tile Cholesky** (`_tile_cholesky_factorize_block`, which
    uses `wp.tile_load_indexed` to densify from CSR, then `wp.tile_cholesky_inplace`)
  * oversized blocks: sparse L'DL (`_factor_LD_sparse_fused`), stored at offset
    `qLD_block_total` in `qLD`
  `d.qLD` has shape `(nworld, qLD_block_total + nC_sparse)`.
  Humanoid: `M_tiles=[(27, 1 block, 729 elems)]` and `qLD_block_total=729`, so it is one
  dense 27x27 tile Cholesky. 2-link pendulum: `qLD_block_total=4`, a single 2x2 scalar
  Cholesky, with `qLD=[L00, L01, 0, L11]` (packed upper).
* `factor_solve_i(m, d, M, L, D, x, y, store_factor)` factors and solves in one pass. It is
  used by `fwd_acceleration(factorize=True)`, `euler` and `implicitfast`. `store_factor`
  is True only for the CG solver or noslip (`fwd_acceleration`), because only those need
  the factor later.
* `solve_m(m, d, x, y)` computes `x = M^-1 y` with the stored factor.
  `support.mul_m(m, d, res, vec)` computes `res = M vec`. Verified round trip (e7.py) on a
  free sphere of mass 1: `M^-1 * 1 = [1,1,1,250,250,250]`. The inertia `2/5 m r^2 = 0.004`
  gives 1/0.004 = 250. `mul_m` brings it back to ones.
* `smooth.skip_qacc_smooth`: if `m.opt.run_qacc_smooth` is False (experimental) and the
  solver is Newton with warmstart, `qacc_smooth` and the M factorization are skipped.
  Default is True (e1.py printed `run_qacc_smooth True`).

### 1.7 Velocity stage: com_vel, passive, rne

* `com_vel` (smooth.py 3245): `cvel` per body (spatial velocity at the com frame) and
  `cdof_dot = cvel x cdof`. It walks branches, like kinematics.
* `passive.passive` (passive.py 5252) adds:
  joint springs and dampers (`_spring_damper_dof_passive`, one thread per joint, which
  handles FREE (6 dofs), BALL (3) and hinge/slide (1)). Damping is polynomial: the
  `dof_dampingpoly` and `util_misc._poly_force` terms, plus actuator `damping`.
  Then tendon springs and dampers, flex elasticity and bending, gravity compensation
  (`_gravity_force` into `qfrc_gravcomp`), fluid forces (`_fluid` if `m.has_fluid`),
  adhesion, and finally `callback.passive`. SPRING and DAMPER disable flags short-circuit
  it.
* `smooth.rne(m, d, flg_acc=False)` (2036) is recursive Newton-Euler:
  `_rne_cacc_world` sets `cacc[world body] = (0, -gravity)` (the gravity trick). The
  forward branch pass `_cacc_branch` adds `cdof_dot * qvel` (and `cdof * qacc` if
  `flg_acc`). `_cfrc` gives `cfrc_body = I*cacc + cvel x* (I*cvel)`. The backward pass
  `_cfrc_subtree` sums subtrees into `cfrc_int`. Finally `_qfrc_bias` gives
  `qfrc_bias[i] = cdof[i] . cfrc_int[body(i)]`.
  Verified (e3.py): a free ball under gravity gives `qfrc_bias[z] = 4.905` (= 0.5 kg x 9.81).
* **Pitfall:** after a normal step, `d.cacc` holds the bias acceleration, which includes
  `+g` from the world-acceleration trick, not the true acceleration. `d.cfrc_ext` is zero.
  The real values appear only after `rne_postconstraint`. That runs only if
  `m.opt.run_rne_postconstraint = True` or the model has a sensor that needs it
  (accelerometer, force, torque, frame acc ...; `m.sensor_rne_postconstraint`).
  Verified (e7.py), sphere resting on a plane:
  * flag False: `cfrc_ext = 0`, `cacc_z = 9.81`
  * flag True: `cfrc_ext_z = 9.791` (contact), `cacc_z = 9.791`
* `subtree_vel` (`subtree_linvel`, `subtree_angmom`) is **not** called by forward. Call
  `mjw.subtree_vel(m, d)` yourself, or add a subtree sensor. Verified (e7.py): zero before
  the call and correct after.

### 1.8 Transmission and actuation (smooth.py `transmission`; forward.py `fwd_actuation`, `_actuator_force`)

* `transmission` (position stage) computes `actuator_length` and the **sparse**
  `actuator_moment` (`moment_rownnz`, `moment_rowadr` and `moment_colind`, all per world,
  shape `(nworld, nJmom)`) for TrnType JOINT, JOINTINPARENT, SLIDERCRANK, TENDON, SITE
  and BODY.
* `fwd_actuation` (forward.py ~3592):
  1. If `nhistory > 0`, `ctrl` comes from `history.read_ctrl_delayed` (actuator delay);
     otherwise it is `d.ctrl`.
  2. `_actuator_force` runs with `dim=(nworld, nactuator)`. It clamps ctrl (unless
     CLAMPCTRL is disabled; it reads the clamp, **d.ctrl is not modified**). Dynamics give
     `act_dot` (INTEGRATOR, FILTER, FILTEREXACT, MUSCLE, DCMOTOR, PID, USER). `actearly`
     uses the next act. Gain: FIXED `gainprm[0]`, AFFINE `g0 + g1*len + g2*vel`, MUSCLE,
     DCMOTOR, PID, SO3. Bias: AFFINE, MUSCLE, DCMOTOR. Then `force = gain*ctrl_act + bias`,
     clamped by `forcerange`.
  3. Callbacks `act_dyn`, `act_gain` and `act_bias` (if set).
  4. Tendon force limits (`_tendon_actuator_force`, `_tendon_actuator_force_clamp`).
  5. `qfrc_actuator = moment^T * actuator_force` (`_qfrc_actuator`), then joint gravity
     compensation and `jnt_actfrcrange` clamps (`_qfrc_actuator_gravcomp_limits`).
  Verified (e3.py): a motor with ctrl 0.3 gives actuator_force 0.3. A position servo with
  kp=20, ctrl=0.5 and qpos=0 gives force 10.0.
* If `nactuator == 0` or ACTUATION is disabled, `act_dot`, `qfrc_actuator` and
  `actuator_force` are zeroed.

### 1.9 Integrators (forward.py)

All of them end in `_advance(m, d, qacc, qvel=None, act_dot=None)`. In order:
1. `_next_activation`: integrate act. It uses an exact filter for FILTEREXACT and clamps
   to `actrange`.
2. `_next_velocity`: `qvel += qacc * dt` (dim `(nworld, nv)`).
3. `_next_position`: dim `(nworld, njnt)`. It uses the **new** qvel (semi-implicit),
   unless an explicit `qvel` is passed (RK4 passes its weighted average). FREE joints:
   position is linear, the quaternion goes through `math.quat_integrate`. BALL: quaternion
   integrate. HINGE/SLIDE: `q += dt*v`.
4. Plasticity and rod twist updates (flex/plastic models only).
5. `history.insert_ctrl_history` (delay buffers).
6. `_next_time_builder`: `time += dt`, plus the **overflow** bitmask check (nacon vs
   naconmax, nefc vs njmax).
7. Sleep bookkeeping, then `qacc_warmstart = qacc`.

`timestep` is read as `opt_timestep[worldid % opt_timestep.shape[0]]`, so it **can differ
per world**.

| Integrator (`IntegratorType`, value) | What `step` does after `forward` | Cost |
|---|---|---|
| EULER (0) | `euler`: unless EULERDAMP or DAMPER is disabled, it builds `M + dt*diag(dD/dv)` (the damping derivative, `_compute_damping_deriv`, `_euler_damp_qfrc`), then factor-solves `qacc = (M + hD)^-1 (M qacc)`, using `d.efc.Ma` from the solver as the RHS. **Implicit only in joint damping.** | ~1 forward |
| RK4 (1) | `rungekutta4`: tableau `A=[.5,.5,1]`, `B=[1/6,1/3,1/3,1/6]`. It saves t0 state, runs `_forward(skip_sensor=True)` 3 more times at perturbed states (`_rk_perturb_state`), applies an RKMK correction for ball and free rotation (`_rk_correct_velocity`), accumulates `qvel_rk` and `qacc_rk`, restores t0 and calls `_advance(qacc_rk, qvel_rk, act_dot_rk)`. Sensors stay from the start of the step. `qacc_warmstart` comes from the last stage. | 4 forwards (e6: about 4x Euler) |
| IMPLICITFAST (3) | `implicit`: `qDeriv = derivative.deriv_smooth_vel` (M minus dt times the d(actuator+passive)/dqvel, in M's CSR layout). Then `_implicit_free_body_reset_m`, `factor_solve_i` (symmetric) and `implicit_free_body`. If ACTUATION, SPRING and DAMPER are all disabled it just calls `_advance(d.qacc)`. | ~1.1 forwards |
| IMPLICIT (2) | `implicit_qlu`: as above plus the **RNE velocity derivative** (`derivative.deriv_rne_vel`, Coriolis/centrifugal), mapped from the M layout to the D layout (`_map_m2d`). It gives a **non-symmetric** matrix, solved by sparse LU (`smooth.factor_solve_lu`, a fused kernel, `dim=(nworld,)`, one thread per world). | heavier; see pitfalls |
| DISCRETE (4) | `discrete`: `_advance(d.qacc)`. The heavy work happens inside forward: `derivative.eff_build`, `eff_shift`, `eff_actuation` and `eff_solve` solve the constraint problem in an "effective metric" `M_hat = M + h*D + h^2*K`. Needed for stable Neo-Hookean flex and passive flex contact. See `check_discrete` for the rules. | flex-oriented |

Verified parity with MuJoCo C (e2.py, double pendulum, dt=0.01, 300 steps). The maximum
qpos difference from `mujoco.mj_step` is at most 1e-6 for all of EULER, RK4, IMPLICIT,
IMPLICITFAST and DISCRETE, with and without damping=5.

**Energy behaviour (e10.py; great chart data).** Undamped double pendulum,
`qpos0=[1.2,0]`, dt=0.02. Total energy is sampled every 30 steps (0.6 s) for 6 s:

```
Euler        [16.065, 16.603, 16.274, 16.984, 17.689, 17.326, 18.279, 18.962, 18.814, 20.37, 20.657]  (gains energy)
RK4          [16.065, 16.065, 16.065, 16.065, 16.065, 16.065, 16.065, 16.065, 16.065, 16.065, 16.065]  (conserves)
implicit     [16.065, 15.977, 15.556, 15.371, 15.316, 14.94, 14.934, 14.92, 14.588, 14.418, 14.499]   (numerical damping)
implicitfast identical to Euler here (no velocity-dependent forces, so qDeriv = 0)
```

CPU timings (e6.py, humanoid, nworld=8; only relative numbers matter):
Euler 4.3 ms, RK4 17.2 ms, IMPLICIT 5.8 ms, IMPLICITFAST 4.9 ms.

### 1.10 Sensors (sensor.py)

Three entry points match the stages: `sensor_pos` (933), `sensor_vel` (1588) and
`sensor_acc` (2974). Each returns immediately if `DisableBit.SENSOR` is set. Values go
into `d.sensordata (nworld, nsensordata)` at `sensor_adr`.
`forward` zeroes `sensordata` before `sensor_pos`.

* **pos**: MAGNETOMETER, CAMPROJECTION, RANGEFINDER (uses `ray.rays`), JOINTPOS,
  TENDONPOS, ACTUATORPOS, BALLQUAT, JOINT/TENDON LIMITPOS, FRAMEPOS/XAXIS/YAXIS/ZAXIS/QUAT,
  SUBTREECOM, GEOMDIST/NORMAL/FROMTO, INSIDESITE, E_POTENTIAL, CLOCK
* **vel**: VELOCIMETER, GYRO, JOINTVEL, TENDONVEL, ACTUATORVEL, BALLANGVEL,
  JOINT/TENDON LIMITVEL, FRAMELINVEL/ANGVEL, SUBTREELINVEL/ANGMOM, E_KINETIC
* **acc**: TOUCH, CONTACT, ACCELEROMETER, FORCE, TORQUE, ACTUATORFRC, TENDONACTFRC,
  JOINTACTFRC, JOINT/TENDON LIMITFRC, FRAMELINACC/ANGACC, TACTILE, USER (callback)
* Sensor plugins are not supported (`io.py put_model` raises NotImplementedError).
* Sensors can have `delay=`, `nsample=` and `interp=` (handled by `history.apply_sensor_delay`).
* `energy_pos` / `energy_vel` fill `d.energy[:, 0]` (potential) and `[:, 1]` (kinetic),
  only if `<flag energy="enable"/>`. Otherwise energy is zeroed.
* RK4: sensors keep the values from the **start** of the step (test
  `forward_test.test_rungekutta4_sensors`).

Verified (e3.py): per-world sensordata differs when ctrl differs per world. An
accelerometer at rest reads `+9.81` on z, because it measures the specific force.

### 1.11 Inverse dynamics (inverse.py `inverse`)

```
check_discrete; fwd_position; sensor_pos; fwd_velocity; sensor_vel
if INVDISCRETE flag or DISCRETE integrator: save qacc; discrete_acc() converts it to a continuous qacc
   (Euler: (M + h*D) qacc; IMPLICIT: qLU*qacc; IMPLICITFAST: qDeriv*qacc; RK4 -> NotImplementedError)
inv_constraint (constraint forces from qacc via solver.create_inverse_context/init_context)
rne; tendon_bias; sensor_acc
qfrc_inverse = qfrc_bias + M*qacc - qfrc_passive - qfrc_constraint
restore qacc if converted
```

Docstring identity (types.py): `qfrc_inverse` should equal
`qfrc_applied + J^T xfrc_applied + qfrc_actuator`. Verified (e3.py), after `forward` and
then `inverse` on the arm-plus-ball model: max |qfrc_inverse - (qfrc_applied +
qfrc_actuator)| = 1.8e-6.

Note: `inverse` is exported but, unlike most stage functions, has no `@event_scope`
decorator, so it does not show up in `EventTracer`.

### 1.12 Derivatives (derivative.py)

* Public: `mjw.deriv_smooth_vel(m, d, out)`. `out` has shape `(nworld, m.nC)` in M's CSR
  layout. Per the docstring it holds `M - dt*qDeriv`: the analytic derivative of actuator
  and passive (damping, fluid) forces with respect to qvel, folded into M. Usage is in
  `derivative_test.test_smooth_vel`: run `fwd_position(factorize=False)` and
  `fwd_velocity`, then call it. Densify with
  `mujoco.mju_sym2dense(out, vals, mjm.M_rownnz, mjm.M_rowadr, mjm.M_colind)`.
* `deriv_rne_vel` (private) is the RNE derivative used only by IMPLICIT. It allocates
  `Dcvel (nworld, nbody, nv)`, `Dcdof_dot (nworld, nv, nv)` and `Dcacc (nworld, nbody, nv)`
  of spatial vectors **on every call**. Memory grows as nworld x nbody x nv x 24 bytes x 3.
  That matters for big models with big nworld.
* `eff_*` functions are the effective-metric machinery of the DISCRETE integrator
  (`eff_build`, `eff_shift`, `eff_actuation`, `eff_solve`, `eff_mul_m`). They return
  immediately for other integrators.

### 1.13 set_const (set_const.py `set_const`)

Use it after changing model parameters at runtime, including per-world randomization.
`set_const(m, d, groups=SetConstGroup.ALL, restore=True)` recomputes the derived constants:
* FIXED: `body_subtreemass`, geom bounds (aabb, rbound)
* KIN0: `tendon_length0`, `eq_data` anchors, camera and light references
* INERT0: `dof_invweight0`, `body_invweight0`, `tendon_invweight0`, `actuator_acc0`

The docstring has a table of which group to use for which edit (body_mass needs ALL,
dof_armature needs INERT0, qpos0 needs KIN0|INERT0, ...). It temporarily runs kinematics
at qpos0 with sleep disabled, then restores `d.qpos` and mocap. `set_const_0` and
`set_const_fixed` are deprecated wrappers. `set_length_range` only copies joint and
tendon ranges times the gear (no simulation-based length range).

**Pitfall (verified, e4/e5):** derived fields are batched only if you batch them. Give
`body_mass` a per-world size with `put_model(mjm, batch_sizes={"body_mass": 3})` but leave
`body_subtreemass` and `actuator_acc0` unbatched, and `set_const` writes only one shared
row. Batch the derived fields as well:
```python
m = mjw.put_model(mjm, batch_sizes={"body_mass": 3, "body_subtreemass": 3,
                                    "actuator_acc0": 3, "dof_invweight0": 3, "body_invweight0": 3})
```
Then `set_const` gives `body_subtreemass=[[1,1],[2,2],[4,4]]` and
`actuator_acc0=[1, .5, .25]`. The dynamics already use per-world `body_mass` through
`cinert` and `crb` without set_const: `qacc` per world was `[1, .5, .25]` for masses
1, 2 and 4.

`batch_sizes` keys must be top-level `Model` field names with a `*` leading spec.
`"opt.timestep"` raises `ValueError: Model field 'opt.timestep' is not a batched array field.`
To vary the timestep per world, **replace the array instead** (verified, e4.py):
`m.opt.timestep = wp.array([0.001, 0.01, 0.02], dtype=float)`. After 10 steps
`d.time = [0.01, 0.1, 0.2]`.

### 1.14 History: actuator and sensor delays (history.py)

* MJCF: `<motor joint="slide" delay="0.03" nsample="5" interp="linear"/>` and
  `<jointpos joint="slide" delay="0.02" nsample="4"/>`. `interp` is 0 for ZOH, 1 for
  linear, 2 for cubic.
* Buffers live in `d.history (nworld, nhistory)` as ring buffers. Each one holds a cursor,
  times and values; `_history_physical_index` and `_history_find_index` do a circular
  binary search that matches C `historyFindIndex`.
* Flow: `fwd_actuation` reads the delayed ctrl (`read_ctrl_delayed`), `_advance` inserts
  the current ctrl (`insert_ctrl_history`) before time advances, and sensors overwrite
  `sensordata` with delayed values and insert the fresh ones (`apply_sensor_delay`).
* Public: `read_ctrl`, `read_sensor`, `init_ctrl_history`, `init_sensor_history` and
  `reset_history`.
* Verified (e4.py): dt=0.01, delay=0.03, constant ctrl=1. `actuator_force` is 0 for steps
  0-2 and 1.0 from step 3. The delayed sensor lags the fresh one by 2 steps. For that model
  `nhistory=22` and `d.history.shape == (2, 22)`.

### 1.15 Instrumentation: `@event_scope` and `EventTracer` (warp_util.py)

Most stage functions carry `@event_scope`. Inside `warp_util.EventTracer()` they record
CUDA events, so you get a nested timing tree (step, forward, fwd_position, kinematics, ...).
**CUDA only:** on CPU it fails with `RuntimeError: Device cpu is not a CUDA device`
(verified, e6.py). The CLI `mjwarp-testspeed --event_trace` uses it (cli.py `unroll`).
Good for a Colab "where does the time go" chapter.

`@cache_kernel` caches kernel factories keyed by their arguments, such as
`_next_position(enable_sleep)`. It exists to avoid crashes in graph-conditional code.
Many kernels are generated per configuration with `wp.static(...)` branches, so a flag
change compiles a new kernel.

---

## 2. Verified API snippets

All of these were run on CPU (marked [RAN]) unless noted.

**A. Minimal: load, batch, step, read** [RAN e1/e3]
```python
import mujoco, numpy as np, warp as wp, mujoco_warp as mjw
mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1024, nconmax=16, njmax=64)   # or mjw.put_data(mjm, mjd, nworld=...)
d.ctrl.assign(np.random.uniform(-1, 1, (1024, mjm.nu)).astype(np.float32))
for _ in range(100):
    mjw.step(m, d)
qpos = d.qpos.numpy()          # (1024, nq)
```

**B. Stage by stage (manual forward)** [RAN e3]
```python
mjw.fwd_position(m, d)              # kinematics, com, collision, constraints, M, factor, transmission
mjw.fwd_velocity(m, d)              # cvel, passive, qfrc_bias
mjw.fwd_actuation(m, d)             # actuator_force, qfrc_actuator
mjw.fwd_acceleration(m, d)          # qfrc_smooth, qacc_smooth (uses qLD from fwd_position)
mjw.solve(m, d)                     # qacc, qfrc_constraint
```
Measured on the arm-plus-ball model: `qfrc_smooth[4] = -4.905` and
`qacc_smooth[4] = -9.81` (the ball falls). The contact solve changed the arm's qacc from
`[-141.7, 449.7]` to `[-105.1, 206.6]`.

**C. step1 / step2 with control in between** [RAN e3]
```python
mjw.step1(m, d)
d.ctrl.assign(policy(d.sensordata.numpy()))   # control from fresh sensors
mjw.step2(m, d)
```

**D. Switching integrators** [RAN e2/e6]. Either set it in XML with
`<option integrator="RK4"/>` (also "Euler", "implicit", "implicitfast", "discrete"), or
set it directly: `m.opt.integrator = mjw.IntegratorType.RK4`. It is a Python int read at
dispatch. **If you captured a CUDA graph, recapture after the change.**

**E. Energy** [RAN e2]: `<option><flag energy="enable"/></option>`, then
`d.energy.numpy()` gives `(nworld, 2)` = [potential, kinetic].

**F. Inverse dynamics check** [RAN e3]
```python
mjw.forward(m, d); mjw.inverse(m, d)
np.abs(d.qfrc_inverse.numpy() - (d.qfrc_applied.numpy() + d.qfrc_actuator.numpy())).max()  # ~1e-6
```

**G. Mass solve and multiply** [RAN e7]
```python
x = wp.zeros((d.nworld, mjm.nv), dtype=float); y = wp.ones((d.nworld, mjm.nv), dtype=float)
mjw.factor_m(m, d); mjw.solve_m(m, d, x, y)     # x = M^-1 y
z = wp.zeros_like(x); mjw.mul_m(m, d, z, x)     # z = M x  (== y)
```

**H. Compare one world with MuJoCo C** [RAN e1/e2]
```python
mjd = mujoco.MjData(mjm); mjw.get_data_into(mjd, mjm, d, world_id=0)
```

**I. Post-constraint body forces** [RAN e7]: `m.opt.run_rne_postconstraint = True`, then
`d.cfrc_ext` and `d.cacc` hold real values.

**J. CUDA graph capture (Colab GPU only, NOT run here)**. This is the pattern from
cli.py `unroll` and `forward_test`:
```python
mjw.step(m, d)                       # warm-up: compiles kernels
with wp.ScopedCapture() as capture:
    mjw.step(m, d)
graph = capture.graph
for _ in range(1000):
    wp.capture_launch(graph)
wp.synchronize()
```

**K. Event trace (Colab GPU only, NOT run here; it errors on CPU)**
```python
from mujoco_warp._src import warp_util
with warp_util.EventTracer() as tr:
    mjw.step(m, d); wp.synchronize()
    print(tr.trace())   # {'step': ((ms,), {'forward': (..., {'fwd_position': ...})})}
```

**L. Delays** [RAN e4]: see 1.14. Read a delayed value with
`res = wp.zeros(d.nworld, dtype=float); mjw.read_ctrl(m, d, 0, wp.array([t0, t1], dtype=float), -1, res)`.

---

## 3. Data shapes and flow (quick reference)

Per world (leading axis `nworld` everywhere):
```
qpos (nq) --kinematics--> xpos,xquat (nbody) -> xipos,xiquat, geom_x*, site_x*
          --com_pos-----> subtree_com (nbody), cinert (nbody,10), cdof (nv,6)
          --crb---------> crb (nbody,10) -> M (nC CSR) --factor--> qLD, qLDiagInv
          --tendon/transmission--> ten_length, ten_J (nJten), actuator_length (nu), actuator_moment (nJmom)
qvel (nv) --com_vel-----> cvel (nbody,6), cdof_dot (nv,6)
          --passive-----> qfrc_spring/damper/gravcomp/fluid/adhesion -> qfrc_passive (nv)
          --rne---------> cacc, cfrc_int (nbody,6) -> qfrc_bias (nv)
          --> actuator_velocity (nu), ten_velocity (ntendon)
ctrl (nu), act (na) --actuation--> act_dot (na), actuator_force (nu) -> qfrc_actuator (nv)
qfrc_applied, xfrc_applied --> qfrc_smooth (nv) --M^-1--> qacc_smooth (nv)
contacts/efc --solver--> qacc (nv), qfrc_constraint (nv)
integrator: qacc -> qvel -> qpos, act_dot -> act, time += dt
```
Sizes from the examples: 2-link pendulum nq=nv=2, nC=3. Arm plus free ball: nq=9, nv=8
(the free joint adds 7 qpos and 6 qvel). Humanoid: nq=28, nv=27, nbody=17, nu=21, nC=243.

---

## 4. Diagram and animation ideas

1. **The pipeline conveyor belt** (hero animation for the chapter). Five stations:
   Position, Velocity, Actuation, Acceleration, Solve, then an Integrate loop arrow back
   to the start. A "state packet" (qpos, qvel, act, ctrl) slides along. At each station,
   output chips light up and drop into a "Data" shelf (xpos, M, cvel, qfrc_bias,
   actuator_force, qacc_smooth, qacc). Sensor taps flash after pos, vel and acc. Toggle
   for RK4: the belt loops 4 times with stage weights 1/6, 1/3, 1/3, 1/6 shown.
2. **Many worlds = a grid of threads.** A 2D grid with `worldid` rows and `body`/`dof`
   columns. When "launch kinematics2" is pressed, all cells light at once. Contrast with a
   CPU loop that lights cells one at a time.
3. **Branch-parallel kinematics.** Draw the humanoid tree with its 5 branches in colours.
   Five "threads" (dots) start at the root and walk down their branches in parallel. The
   torso node pulses 5 times to show redundant recomputation. Next to it is a
   "level-by-level" alternative that needs a barrier per depth.
4. **Subtree as a contiguous slice.** The body array laid out in DFS order
   `[0..16]`, with the subtree of body 3 highlighted as indices 3..10
   (`body_subtreenum[3]=8`). An animation sums masses into the subtree com.
5. **Mass matrix sparsity.** Animate the CSR lower triangle being filled row by row,
   walking ancestors (`dof_parentid`). Then show the block-diagonal structure for a scene
   with several free bodies plus an arm. Each block gets a factorization label: compact
   1/diag, scalar Cholesky, tile Cholesky, sparse LDL.
6. **Joint types in kinematics.** A small interactive SVG with sliders for hinge angle,
   slide distance and ball quaternion, showing how `xanchor` and `xaxis` move and the
   off-center correction `xpos = xanchor - R*jnt_pos`.
7. **RNE two-pass sweep.** A forward pass (blue arrows, root to leaves) carries cvel and
   cacc. A backward pass (red arrows, leaves to root) carries cfrc. Last step: projection
   onto cdof gives qfrc_bias. Show the "gravity trick": the world body accelerates upward
   by g.
8. **Force budget bar.** A stacked bar per dof of qfrc_passive, -qfrc_bias, qfrc_actuator,
   qfrc_applied and J^T xfrc, summing to qfrc_smooth. Then M^-1 gives qacc_smooth, and the
   constraint force bar gives qacc. Use the numbers from snippet B.
9. **Integrator energy race** (Chart.js line chart, using the e10 data). Euler drifts up,
   implicit drifts down, RK4 stays flat. Pair it with an animated double pendulum per
   integrator, side by side, that slowly desyncs.
10. **Semi-implicit Euler phase portrait.** A (q, v) phase plane for a 1-D spring. The
    explicit Euler spiral goes outward, semi-implicit gives a closed ellipse, implicit
    spirals inward. Use a CSS keyframe or a canvas.
11. **Euler implicit damping.** A slider for damping x dt. Show the explicit update going
    unstable when `h*b/m > 2` while the `(M + hD)` solve stays stable.
12. **step1/step2 split.** A timeline with a gap where "your policy" runs, reading
    sensordata after step1 and writing ctrl before step2.
13. **Delay ring buffer.** A circular buffer with a cursor that advances each step. A query
    time `t - delay` does binary search and interpolation between two slots. Show the
    actuator force starting 3 steps late (e4 data).
14. **Sensor stage map.** Three columns (pos, vel, acc) with sensor-type chips. Hovering a
    chip highlights which Data fields it reads.
15. **CUDA graph capture.** Show many small kernel launches from Python (each one a
    gap-and-bar on a timeline) collapsing into one graph launch with no gaps.

---

## 5. Pitfalls, unsupported features, performance and GPU vs CPU

* **float32 everywhere.** Results match MuJoCo C (float64) to about 1e-6 per step but
  drift over long rollouts. Use loose tolerances when comparing (tests use 5e-5 x 10).
* **cacc, cfrc_ext and cfrc_int are not "real" unless rne_postconstraint ran** (see 1.7).
  **subtree_linvel and subtree_angmom need `mjw.subtree_vel`.**
* **step2 with RK4 runs Euler.** If you need RK4, use `step` with `callback.control`.
* **Changing `m.opt.*` int flags** (integrator, disableflags, enableflags, solver) changes
  which kernels launch and their `wp.static` branches. That means a new compile on first
  use, and **any CUDA graph must be recaptured**. Array options (timestep, gravity, wind,
  density, ...) can be changed in place, even inside a graph.
* **Per-world parameters**: kernels index `x[worldid % x.shape[0]]`. Use `put_model`
  `batch_sizes`, or assign a new `wp.array` of length nworld. Remember to batch derived
  fields before calling `set_const` (1.13).
* **Allocations inside step**: `euler` (M clone, damping derivative), `implicit`
  (`deriv_rne_vel` allocates O(nworld x nbody x nv) memory) and `rungekutta4` (clones of
  qpos, qvel, ...) call `wp.empty`, `wp.zeros` and `wp.clone` every step. Under CUDA graph
  capture these come from the graph's memory pool. Without a graph, each step pays
  allocation overhead. **Always graph-capture on GPU.**
* **The RK4 cost is about 4x Euler.** IMPLICIT is the costliest per step among the
  standard ones on big trees, because the LU is one thread per world
  (`factor_solve_lu` has `dim=(nworld,)`). IMPLICITFAST is the usual robotics choice: it
  is symmetric and uses the blocked Cholesky.
* **First call compiles kernels.** First `forward` took 11 s on CPU with a cold cache, 0.3 s
  with a warm one, and 5 ms after that (e1). On Colab, expect the first step to take tens
  of seconds; the kernel cache lives in `~/.cache/warp`.
* **CPU vs GPU**: `EventTracer` and `wp.ScopedCapture` need CUDA. Tile Cholesky uses
  `block_dim=1` on CPU (`_factor_i_sparse` picks `block_dim` only if `L.device.is_cuda`).
  The CPU is fine for correctness checks and small nworld.
* **Overflow**: `_next_time_builder` sets the `d.overflow` bitmask when nacon exceeds
  naconmax or nefc exceeds njmax. Size `nconmax` and `njmax` in `make_data`, or set
  `m.opt.warn_overflow`.
* **Unsupported or restricted** (io.py `put_model` checks, ~line 644):
  * body, actuator and sensor plugins
  * DisableBit MIDPHASE and AUTORESET; EnableBit OVERRIDE, FWDINV, ISLAND and DIAGEXACT
    (comments in types.py)
  * SetConstGroup SPRING
  * dense Jacobian with nv > 60
  * noslip with the discrete integrator
  * sleep only with the Newton solver
  * flex-specific limits (quadratic interpolation, flex-SDF, ...)
  * `discrete_acc` with RK4 raises NotImplementedError for INVDISCRETE inverse
  * flex elasticity with implicit/implicitfast raises ValueError (use discrete, or Euler
    with a small dt; see `check_discrete`)
* **MuJoCo 4 API changes, for C comparisons in notebooks:** `mjd.M` (not `qM`) and
  `mujoco.mj_fullM(mjm, mjd, dst)`.
* **`ctrl` is clamped on read, not written back.** `d.ctrl` keeps your unclamped values.
* **Determinism**: `m.opt.deterministic` (DeterminismType CONTACTS, CONSTRAINT, ATOMICS)
  switches to deterministic atomics kernels in transmission, passive, tendon armature and
  actuator force accumulation. Off by default. It costs speed.

---

## 6. Suggested chapters for this area (easy to hard)

1. **The `step` function: one tick of physics.** State versus derived data; `step =
   forward + integrate`; the conveyor-belt animation; reading `time`, `qpos` and `qvel`
   across many worlds. (Snippets A and H.)
2. **Inside `forward`: the five stages.** The stage order from `_forward`; the stage-to-Data
   cheat sheet; calling the stages yourself (snippet B); step1/step2 (snippet C); the
   force budget diagram.
3. **Kinematics on the GPU.** Joint types, branch-parallel `_kinematics_branch`,
   `kinematics2`, the contiguous subtree trick, `com_pos`/`cdof`, camlight, tendons and
   transmission lengths.
4. **Mass matrix and solving with M.** `crb`, the CSR layout, block tiles (scalar, tile,
   sparse Cholesky), `factor_m`, `solve_m`, `mul_m`; compare with `mj_fullM`
   (snippet G).
5. **Forces: passive, bias (RNE) and actuators.** `passive.passive`, the two RNE sweeps
   with the gravity trick, `rne_postconstraint` pitfalls, the actuator gain/bias/dynamics
   model and the force-budget bar.
6. **Integrators compared.** Semi-implicit Euler with implicit damping, RK4 with RKMK,
   implicitfast vs implicit (LU), discrete; the energy race chart (e10 data); costs; how to
   choose.
7. **Sensors and energy.** Stage-based sensors, sensordata layout, energy flag, RK4 sensor
   semantics, accelerometer reading +g.
8. **Time delays and history buffers.** Actuator and sensor delay, the ring buffer, the
   `read_*` and `init_*` APIs (e4 data).
9. **Inverse dynamics and derivatives.** `inverse`, the qfrc_inverse identity,
   INVDISCRETE, `deriv_smooth_vel` and its use inside the implicit integrators.
10. **Changing the model at runtime: batching and set_const.** Per-world parameters
    (`worldid % shape`), `batch_sizes`, `set_const` groups, timestep per world.
11. **Performance and profiling the pipeline.** CUDA graphs, EventTracer trees, allocation
    costs, recompiles on flag changes, overflow, determinism.
12. **(Advanced, optional) The discrete integrator and the effective metric.**
    `check_discrete` rules and `eff_*`; mostly relevant for flex and soft bodies.
