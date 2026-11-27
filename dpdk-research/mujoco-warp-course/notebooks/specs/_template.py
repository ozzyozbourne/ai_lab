# Notebook spec for the template chapter. Build with:
#   python3 tools/make_notebook.py notebooks/specs/_template.py
SLUG = "_template"
TITLE = "Ch 00 · Chapter Template"
CELLS = [
    ["md", "## 1. One launch, many worlds\nEach example below is the same file as on the chapter page."],
    ["example", "ex01_ball_drop.py", "0.1"],
    ["md", "## 2. A custom Warp kernel over MJWarp state"],
    ["example", "ex02_energy_kernel.py", "0.2"],
    ["md", "## Exercise 0.1: landing time\nPredict when a ball dropped from 1 m (radius 0.1 m) touches the floor."],
    ["code", "t_pred = ...  # your formula\n# assert abs(t_sim - t_pred) / t_pred < 0.05"],
    ["solution", "t_pred = (2 * 0.9 / 9.81) ** 0.5\nprint(f\"predicted landing time: {t_pred:.3f} s\")", "Exercise 0.1"],
]
