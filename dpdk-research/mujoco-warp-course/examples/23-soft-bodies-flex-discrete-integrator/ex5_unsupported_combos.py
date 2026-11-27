"""Example 23.5 - every flex combination that MJWarp 4.0.1 refuses, and the message it gives.

Each case builds a small model, then calls mjw.put_model (the io.py checks) and, if that
passes, mjw.forward (forward.py::check_discrete runs at the start of every forward/step).
We catch the exception and print its type and message. The MuJoCo 4.0.1 C compiler itself
refuses four integrator combinations (SNH or passive flex contact without DISCRETE, flex
elasticity with implicitfast, edge stiffness with DISCRETE), so those cases compile with an
accepted integrator and then set mjm.opt.integrator, to reach MJWarp's own checks. SNH is
MjSpec-only (it cannot be written to MJCF): that case sets spec.flexes[0].elastic3d = 1.
Run: python ex5_unsupported_combos.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def cloth(extra="", inner="", count="4 4 1", dim=2, attrs=""):
    """A small flexcomp grid; `inner` goes inside <flexcomp>, `extra` into <worldbody>."""
    return f"""<mujoco><worldbody>{extra}
      <flexcomp name="f" type="grid" count="{count}" spacing=".1 .1 .1" dim="{dim}"
                radius=".01" mass=".1" {attrs}>{inner}</flexcomp>
    </worldbody></mujoco>"""


def with_option(xml, option):
    return xml.replace("<mujoco>", f"<mujoco>{option}", 1)


EDGE_EQ = '<edge equality="true"/>'
STRETCH = '<elasticity young="1e4" poisson="0.2" thickness="1e-3" elastic2d="stretch"/>'
SDF_ASSET = """<extension><plugin plugin="mujoco.sdf.torus"><instance name="torus">
  <config key="radius1" value="0.3"/><config key="radius2" value="0.1"/></instance></plugin>
  </extension><asset><mesh name="torus"><plugin instance="torus"/></mesh></asset>"""
HFIELD_ASSET = '<asset><hfield name="h" nrow="3" ncol="3" size="1 1 .1 .1"/></asset>'


DISCRETE = '<option integrator="discrete"/>'


def snh_model():
    xml = cloth(inner='<elasticity young="1e4" poisson="0.3"/>', count="3 3 3", dim=3)
    spec = mujoco.MjSpec.from_string(with_option(xml, DISCRETE))
    spec.flexes[0].elastic3d = 1          # stable Neo-Hookean; the C compiler needs DISCRETE...
    mjm = spec.compile()
    mjm.opt.integrator = mujoco.mjtIntegrator.mjINT_EULER   # ...so switch afterwards
    return mjm


def switched(xml, integrator):
    """Compile xml as given, then change the integrator on the compiled MjModel."""
    def build():
        mjm = mujoco.MjModel.from_xml_string(xml)
        mjm.opt.integrator = integrator
        return mjm
    return build


CASES = [
    # (key, what, MJCF or builder)
    ("snh", "stable Neo-Hookean, integrator Euler", snh_model),
    ("quadratic", 'dof="quadratic" interpolation',
     cloth(inner=STRETCH, count="3 3 3", dim=3, attrs='dof="quadratic"')),
    ("eq_sleep", "flex edge equality + sleep",
     with_option(cloth(inner=EDGE_EQ), '<option><flag sleep="enable"/></option>')),
    ("hfield", "flex + hfield geom (contype=0)",
     cloth(extra='<geom type="hfield" hfield="h" contype="0" conaffinity="0"/>')
     .replace("<worldbody>", HFIELD_ASSET + "<worldbody>", 1)),
    ("sdf", "flex + SDF geom",
     cloth(extra='<geom type="sdf" mesh="torus" pos="0 0 -1"><plugin instance="torus"/></geom>')
     .replace("<worldbody>", SDF_ASSET + "<worldbody>", 1)),
    ("rigid", 'rigid flex (flexcomp rigid="true")', cloth(attrs='rigid="true"')),
    ("passive_interp", "passive contact, trilinear flex",
     with_option(cloth(inner='<contact passive="true" selfcollide="none"/>', count="3 3 3", dim=3,
                       attrs='dof="trilinear"'), DISCRETE)),
    ("self_interp", "self-collision, trilinear flex",
     cloth(inner='<contact selfcollide="auto"/>', count="3 3 3", dim=3, attrs='dof="trilinear"')),
    ("noslip", "discrete + noslip_iterations",
     with_option(cloth(inner=EDGE_EQ), '<option integrator="discrete" noslip_iterations="2"/>')),
    ("attach_newton", "discrete + Newton, cloth on a moving body",
     with_option(f"""<mujoco><worldbody><body name="base" pos="0 0 1"><freejoint/>
       <geom type="box" size=".05 .05 .05"/>
       <flexcomp name="f" type="grid" count="3 3 1" spacing=".1 .1 .1" dim="2" radius=".01"
                 mass=".1"><pin id="0"/>{STRETCH}</flexcomp></body></worldbody></mujoco>""",
                 '<option integrator="discrete" solver="Newton"/>')),
    ("implicitfast", "implicitfast + flex elasticity",
     switched(cloth(inner=STRETCH), mujoco.mjtIntegrator.mjINT_IMPLICITFAST)),
    ("passive_euler", "passive contact, integrator Euler",
     switched(with_option(cloth(inner='<contact passive="true"/>'), DISCRETE),
              mujoco.mjtIntegrator.mjINT_EULER)),
    ("edge_stiff", "discrete + edge stiffness (1-D rope)",
     switched(cloth(inner='<edge stiffness="100"/>', count="5 1 1", dim=1),
              mujoco.mjtIntegrator.mjINT_DISCRETE)),
]

results = []
for key, what, src in CASES:
    mjm = src() if callable(src) else mujoco.MjModel.from_xml_string(src)
    stage = "put_model"
    try:
        m = mjw.put_model(mjm)
        stage = "forward"
        d = mjw.make_data(mjm, nworld=1)
        mjw.forward(m, d)
        stage, err, msg = "-", "OK", "accepted"
    except Exception as e:                      # NotImplementedError or ValueError
        err, msg = type(e).__name__, str(e)
    results.append({"key": key, "what": what, "stage": stage, "error": err, "message": msg})
    print(f"[{key}] {what}\n    {stage}: {err}: {msg}")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(results, f, indent=0)
    print("wrote", args.dump_json, len(results), "cases")
