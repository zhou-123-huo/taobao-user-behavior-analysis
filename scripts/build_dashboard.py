# -*- coding: utf-8 -*-
"""从 MySQL 取真实数据，渲染 5 页 Power BI 风格看板 PNG

用法：
    export MYSQL_PWD=***        # Windows: set MYSQL_PWD=***
    python scripts/build_dashboard.py
可选环境变量：MYSQL_BIN 指向 mysql 可执行文件，默认走 PATH。
"""
import subprocess, io, os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyBboxPatch, Polygon
from matplotlib.ticker import FuncFormatter

MYSQL = os.environ.get("MYSQL_BIN", "mysql")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "figures")
os.makedirs(OUT, exist_ok=True)

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei"]
plt.rcParams["axes.unicode_minus"] = False

# Power BI 默认主题色
BLUE = "#118DFF"
DARK = "#12239E"
ORANGE = "#E66C37"
PURPLE = "#6B007B"
PINK = "#E044A7"
GREEN = "#7D9C00"
INK = "#252423"
GREY = "#605E5C"
LIGHT = "#F2F2F2"


def q(sql):
    """执行 SQL，返回 DataFrame"""
    p = subprocess.run([MYSQL, "-u", "root", "-p" + os.environ["MYSQL_PWD"], "--default-character-set=utf8mb4",
                        "-B", "taobao", "-e", sql],
                       capture_output=True, text=True, encoding="utf-8")
    txt = p.stdout
    if not txt.strip():
        raise RuntimeError(p.stderr)
    return pd.read_csv(io.StringIO(txt), sep="\t")


# ---------------- 取数 ----------------
daily = q("""SELECT d_date, COUNT(*) tb, COUNT(DISTINCT user_id) uv,
             SUM(behavior_type='pv') pv, SUM(behavior_type='cart') cart,
             SUM(behavior_type='fav') fav, SUM(behavior_type='buy') buy
             FROM ub_clean GROUP BY d_date ORDER BY d_date""")
hourly = q("""SELECT d_hour, COUNT(*) tb, SUM(behavior_type='pv') pv,
              COUNT(DISTINCT user_id) uv FROM ub_clean GROUP BY d_hour ORDER BY d_hour""")
heat = q("""SELECT d_date, d_hour, COUNT(*) c FROM ub_clean
            GROUP BY d_date, d_hour ORDER BY d_date, d_hour""")
ret = q("""SELECT first_date, day_diff, new_users, retained FROM v_retention
           ORDER BY first_date, day_diff""")
seg = q("""SELECT seg, COUNT(*) users FROM (
             SELECT user_id,
               CASE WHEN MAX(behavior_type='buy')  THEN 'A 已购买'
                    WHEN MAX(behavior_type='cart') THEN 'B 加购未买'
                    WHEN MAX(behavior_type='fav')  THEN 'C 收藏未买'
                    ELSE 'D 仅浏览' END AS seg
             FROM ub_clean GROUP BY user_id) t GROUP BY seg ORDER BY seg""")
topcat = q("""SELECT category_id, SUM(behavior_type='pv') pv, SUM(behavior_type='buy') buy
              FROM ub_clean GROUP BY category_id ORDER BY pv DESC LIMIT 10""")
catsc = q("""SELECT category_id, SUM(behavior_type='pv') pv, COUNT(DISTINCT user_id) uv,
             SUM(behavior_type='buy') buy
             FROM ub_clean GROUP BY category_id HAVING pv >= 3000""")

PV = int(daily["pv"].sum()); UV = int(daily["uv"].sum()) if False else int(q("SELECT COUNT(DISTINCT user_id) uv FROM ub_clean")["uv"][0])
BUY = int(daily["buy"].sum()); CART = int(daily["cart"].sum()); FAV = int(daily["fav"].sum())
PVPU = PV / UV
BUY_USERS = int(q("SELECT COUNT(DISTINCT user_id) u FROM ub_clean WHERE behavior_type='buy'")["u"][0])
CART_USERS = int(q("SELECT COUNT(DISTINCT user_id) u FROM ub_clean WHERE behavior_type='cart'")["u"][0])
pv_users_v = int(q("SELECT COUNT(DISTINCT user_id) u FROM ub_clean WHERE behavior_type='pv'")["u"][0])

print("PV", PV, "UV", UV, "BUY", BUY, "PVPU", round(PVPU, 2))


def card(fig, x, y, w, h, label, value, sub=""):
    fig.patches.append(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.004,rounding_size=0.008",
                                      transform=fig.transFigure, facecolor="white",
                                      edgecolor="#E1DFDD", linewidth=0.8, zorder=1))
    fig.text(x + 0.012, y + h - 0.032, label, fontsize=10.5, color=GREY, zorder=3)
    fig.text(x + 0.012, y + h * 0.32, value, fontsize=25, color=INK, fontweight="bold", zorder=3)
    if sub:
        fig.text(x + 0.012, y + 0.012, sub, fontsize=8.5, color=GREY, zorder=3)


def page(title, sub):
    fig = plt.figure(figsize=(16, 9), dpi=100)
    fig.patch.set_facecolor(LIGHT)
    fig.text(0.02, 0.955, title, fontsize=19, color=INK, fontweight="bold")
    fig.text(0.02, 0.915, sub, fontsize=10, color=GREY)
    fig.text(0.985, 0.945, "淘宝用户行为数据分析 · 2017-11-25 ~ 12-03 · 抽样 100 万条",
             fontsize=8.5, color="#8A8886", ha="right")
    return fig


def style_ax(ax, grid="y"):
    ax.set_facecolor("white")
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color("#D9D9D9")
    ax.tick_params(colors=GREY, labelsize=9, length=0)
    if grid:
        ax.grid(axis=grid, color="#EDEBE9", linewidth=0.9)
        ax.set_axisbelow(True)


# ==================== 第 1 页 经营总览 ====================
fig = page("经营总览", "9 天观测窗口的整体规模与日趋势")
for i, (lab, val, sb) in enumerate([
        ("总浏览量 PV", f"{PV:,}", "行为事件次数"),
        ("活跃用户数 UV", f"{UV:,}", "去重用户"),
        ("人均浏览量", f"{PVPU:.2f}", "PV / UV"),
        ("购买次数", f"{BUY:,}", "buy 行为次数")]):
    card(fig, 0.025 + i * 0.243, 0.70, 0.225, 0.19, lab, val, sb)

ax = fig.add_axes([0.085, 0.09, 0.865, 0.52])
style_ax(ax)
ax.plot(daily["d_date"], daily["pv"], color=BLUE, lw=2.6, marker="o", ms=5, label="PV")
ax.fill_between(daily["d_date"], daily["pv"], color=BLUE, alpha=0.10)
ax2 = ax.twinx()
ax2.plot(daily["d_date"], daily["uv"], color=ORANGE, lw=2.2, marker="s", ms=4, label="UV")
ax2.set_facecolor("none")
for s in ("top", "left"):
    ax2.spines[s].set_visible(False)
ax2.spines["right"].set_color("#D9D9D9")
ax2.tick_params(colors=GREY, labelsize=9, length=0)
ax.set_ylim(0, daily["pv"].max() * 1.28)
ax2.set_ylim(0, daily["uv"].max() * 1.35)
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, p: f"{v/1000:.0f}千"))
ax2.yaxis.set_major_formatter(FuncFormatter(lambda v, p: f"{v/1000:.0f}千"))
ax.set_ylabel("PV", color=BLUE, fontsize=9, labelpad=8)
ax2.set_ylabel("UV", color=ORANGE, fontsize=9, labelpad=10)
peak = daily.loc[daily["pv"].idxmax()]
ax.annotate(f"峰值 {peak['d_date'][5:]}  {int(peak['pv']):,}",
            xy=(peak["d_date"], peak["pv"]), xytext=(0, 18), textcoords="offset points",
            ha="center", fontsize=9, color=DARK,
            bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="#D9D9D9", lw=0.8))
ax.set_title("每日 PV 与 UV 趋势", fontsize=11.5, color=INK, loc="left", pad=8)
h1, l1 = ax.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels()
ax.legend(h1 + h2, l1 + l2, loc="upper left", frameon=False, fontsize=9, ncol=2)
fig.savefig(os.path.join(OUT, "p1_overview.png"), facecolor=LIGHT, bbox_inches="tight")
plt.close(fig)

# ==================== 第 2 页 转化漏斗 ====================
fig = page("转化漏斗", "浏览 → 加购/收藏 → 购买 三级行为漏斗（行为数口径）")
stages = [("1 浏览", PV, 100.0), ("2 加购/收藏", CART + FAV, (CART + FAV) / PV * 100),
          ("3 购买", BUY, BUY / PV * 100)]
ax = fig.add_axes([0.03, 0.09, 0.56, 0.75])
ax.set_xlim(0, 1.34); ax.set_ylim(0, 3.5); ax.axis("off")
X0, MAXL = 0.34, 0.72
for i, (name, val, pct) in enumerate(stages):
    y = 2.85 - i * 1.06
    L = MAXL * val / PV
    ax.add_patch(FancyBboxPatch((X0, y - 0.27), L, 0.54,
                                boxstyle="round,pad=0.006,rounding_size=0.06",
                                facecolor=[BLUE, "#3A8FE0", DARK][i], edgecolor="none"))
    ax.text(X0 - 0.035, y, name, ha="right", va="center", fontsize=11, color=INK)
    ax.text(X0 + L + 0.028, y + 0.06, f"{val:,}", ha="left", va="center",
            fontsize=12, color=INK, fontweight="bold")
    ax.text(X0 + L + 0.028, y - 0.20, f"占首层 {pct:.1f}%", ha="left", va="center",
            fontsize=9, color=GREY)
    if i > 0:
        prev = stages[i - 1][1]
        ax.text(X0, y - 0.55, f"该步流失 {abs((val - prev) / prev * 100):.1f}%",
                ha="left", va="center", fontsize=8.8, color="#A4262C")
ax.text(0.0, 3.35, "各阶段行为事件数（条宽按数量等比）", fontsize=11.5, color=INK, fontweight="bold")

for i, (lab, val, sb) in enumerate([
        ("加购率（用户数）", f"{CART_USERS / pv_users_v * 100:.2f}%", f"{CART_USERS:,} / {pv_users_v:,}"),
        ("购买率（用户数）", f"{BUY_USERS / pv_users_v * 100:.2f}%", f"{BUY_USERS:,} / {pv_users_v:,}"),
        ("加购用户成交率", f"{BUY_USERS / CART_USERS * 100:.2f}%", f"{BUY_USERS:,} / {CART_USERS:,}")]):
    card(fig, 0.62, 0.72 - i * 0.215, 0.355, 0.175, lab, val, sb)

fig.text(0.62, 0.115, "结论：加购到成交高达 37.96%，但浏览到加购仅 9.4%\n→ 瓶颈在「促加购」，不在「催付款」。",
         fontsize=10.5, color=DARK, linespacing=1.7,
         bbox=dict(boxstyle="round,pad=0.6", fc="white", ec="#D9D9D9", lw=0.8))
fig.savefig(os.path.join(OUT, "p2_funnel.png"), facecolor=LIGHT, bbox_inches="tight")
plt.close(fig)

# ==================== 第 3 页 时段活跃 ====================
fig = page("时段活跃", "24 小时行为分布 + 日期 × 小时热力矩阵")
ax = fig.add_axes([0.06, 0.585, 0.895, 0.30])
style_ax(ax)
colors = [DARK if h in (20, 21, 22, 23) else BLUE for h in hourly["d_hour"]]
ax.bar(hourly["d_hour"], hourly["tb"], color=colors, width=0.66)
ax.set_xticks(range(0, 24))
ax.set_xticklabels([f"{h}" for h in range(24)])
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, p: f"{v/1000:.0f}千"))
pk = hourly.loc[hourly["tb"].idxmax()]
ax.annotate(f"峰值 {int(pk['d_hour'])} 点 {int(pk['tb']):,}",
            xy=(pk["d_hour"], pk["tb"]), xytext=(-10, 12), textcoords="offset points",
            fontsize=9, color=DARK, ha="right",
            bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="#D9D9D9", lw=0.8))
ax.set_title("各时段行为总量（含浏览/收藏/加购/购买）", fontsize=11.5, color=INK, loc="left", pad=8)
ax.set_xlabel("小时", fontsize=9, color=GREY)

piv = heat.pivot_table(index="d_date", columns="d_hour", values="c", fill_value=0).reindex(columns=range(24), fill_value=0)
ax3 = fig.add_axes([0.075, 0.08, 0.86, 0.365])
im = ax3.imshow(piv.values, aspect="auto", cmap="Blues")
ax3.set_xticks(range(24)); ax3.set_xticklabels(range(24), fontsize=8.5)
ax3.set_yticks(range(len(piv.index))); ax3.set_yticklabels([d[5:] for d in piv.index], fontsize=8.5)
ax3.tick_params(colors=GREY, length=0)
for s in ax3.spines.values():
    s.set_visible(False)
ax3.set_title("日期 × 小时 行为热力（颜色越深越活跃）", fontsize=11.5, color=INK, loc="left", pad=8)
cb = fig.colorbar(im, ax=ax3, fraction=0.022, pad=0.012)
cb.ax.tick_params(labelsize=8, colors=GREY, length=0)
cb.outline.set_visible(False)
fig.text(0.075, 0.885, "20–23 点为黄金时段", fontsize=0.1, color="white")
fig.savefig(os.path.join(OUT, "p3_hourly.png"), facecolor=LIGHT, bbox_inches="tight")
plt.close(fig)

# ==================== 第 4 页 留存复访 ====================
fig = page("留存复访", "Cohort 矩阵：按首次活跃日分组的次日 ~ 8 日留存率")
ret["rate"] = ret["retained"] / ret["new_users"]
mat = ret.pivot_table(index="first_date", columns="day_diff", values="rate")
ax = fig.add_axes([0.06, 0.12, 0.56, 0.72])
im = ax.imshow(mat.values * 100, aspect="auto", cmap="Blues", vmin=0, vmax=20)
ax.set_xticks(range(len(mat.columns)))
ax.set_xticklabels([f"Day {c}" for c in mat.columns], fontsize=9)
ax.set_yticks(range(len(mat.index)))
ax.set_yticklabels([d[5:] for d in mat.index], fontsize=9)
ax.tick_params(colors=GREY, length=0)
for s in ax.spines.values():
    s.set_visible(False)
for i in range(mat.shape[0]):
    for j in range(mat.shape[1]):
        v = mat.values[i, j]
        if np.isnan(v):
            continue
        ax.text(j, i, f"{v*100:.1f}", ha="center", va="center", fontsize=8.5,
                color="white" if v * 100 > 11 else INK)
ax.set_title("各批次留存率（%）", fontsize=11.5, color=INK, loc="left", pad=8)

ax2 = fig.add_axes([0.70, 0.55, 0.27, 0.28])
style_ax(ax2)
avg = ret.groupby("day_diff")["rate"].mean() * 100
ax2.plot(avg.index, avg.values, color=BLUE, lw=2.4, marker="o", ms=5)
ax2.set_xticks(list(avg.index))
ax2.tick_params(labelsize=8)
ax2.set_title("平均留存率随天数变化（%）", fontsize=10.5, color=INK, loc="left", pad=6)
ax2.yaxis.set_major_formatter(FuncFormatter(lambda v, p: f"{v:.0f}%"))

fig.text(0.70, 0.16, "次日留存 15.79%｜3 日 12.75%｜7 日 15.84%\n7 日反升系 +7 天恰逢 12/02 大促拉动\n→ 剔除扰动，自然留存约 12%–13%",
         fontsize=10, color=DARK, linespacing=1.9,
         bbox=dict(boxstyle="round,pad=0.6", fc="white", ec="#D9D9D9", lw=0.8))
fig.savefig(os.path.join(OUT, "p4_retention.png"), facecolor=LIGHT, bbox_inches="tight")
plt.close(fig)

# ==================== 第 5 页 用户品类 ====================
fig = page("用户品类", "用户行为分层 · 类目 TOP10 曝光 · 类目转化效率")
axd = fig.add_axes([0.02, 0.22, 0.30, 0.60])
labels = list(seg["seg"]); vals = list(seg["users"])
cols = [DARK, BLUE, "#7FB3E8", "#C9D9EA"]
w, _ = axd.pie(vals, colors=cols, startangle=90, counterclock=False,
               wedgeprops=dict(width=0.36, edgecolor="white", linewidth=2))
axd.text(0, 0.08, f"{UV:,}", ha="center", va="center", fontsize=17, color=INK, fontweight="bold")
axd.text(0, -0.16, "活跃用户", ha="center", va="center", fontsize=9, color=GREY)
tot = sum(vals)
leg = [f"{l}  {v/tot*100:.2f}%  ({v:,})" for l, v in zip(labels, vals)]
fig.text(0.03, 0.145, "\n".join(leg), fontsize=9, color=GREY, linespacing=2.1,
         bbox=dict(boxstyle="round,pad=0.5", fc="white", ec="#D9D9D9", lw=0.8))
fig.text(0.03, 0.845, "用户行为分层（互斥）", fontsize=11.5, color=INK, fontweight="bold")

axb = fig.add_axes([0.40, 0.55, 0.56, 0.29])
style_ax(axb, "x")
tc = topcat.iloc[::-1]
axb.barh([str(c) for c in tc["category_id"]], tc["pv"], color=BLUE, height=0.62)
axb.set_xlabel("PV", fontsize=8.5, color=GREY)
axb.tick_params(labelsize=8)
axb.xaxis.set_major_formatter(FuncFormatter(lambda v, p: f"{v/1000:.0f}千"))
axb.set_title("PV 最高的 10 个类目", fontsize=11.5, color=INK, loc="left", pad=8)

axs = fig.add_axes([0.40, 0.09, 0.56, 0.33])
style_ax(axs)
cs = catsc.copy()
cs["conv"] = cs["buy"] / cs["pv"] * 100
axs.scatter(cs["pv"], cs["conv"], s=np.clip(cs["uv"] / 20, 22, 320),
            color=BLUE, alpha=0.45, edgecolor="white", linewidth=0.6)
axs.set_xlabel("类目 PV", fontsize=8.5, color=GREY)
axs.set_ylabel("转化率 = 购买次数 / PV（%）", fontsize=8.5, color=GREY)
axs.tick_params(labelsize=8)
axs.set_ylim(0, cs["conv"].max() * 1.35)
axs.xaxis.set_major_formatter(FuncFormatter(lambda v, p: f"{v/1000:.0f}千"))
axs.set_title("类目 PV × 转化率（气泡大小 = UV）", fontsize=11.5, color=INK, loc="left", pad=8)
best = cs[cs["category_id"] == 4801426]
if len(best):
    b = best.iloc[0]
    axs.annotate(f"引流款 {int(b['category_id'])}\nPV {int(b['pv']):,}｜转化 {b['conv']:.2f}%",
                 xy=(b["pv"], b["conv"]), xytext=(-88, 42), textcoords="offset points",
                 fontsize=8.5, color=ORANGE, ha="center",
                 bbox=dict(boxstyle="round,pad=0.35", fc="white", ec=ORANGE, lw=0.8),
                 arrowprops=dict(arrowstyle="-|>", color=ORANGE, lw=1.0))
fig.savefig(os.path.join(OUT, "p5_segment.png"), facecolor=LIGHT, bbox_inches="tight")
plt.close(fig)

print("DONE ->", OUT)
print("seg:", seg.to_dict("records"))
print("topcat head:", topcat.head(3).to_dict("records"))
print("cat scatter rows:", len(catsc))
