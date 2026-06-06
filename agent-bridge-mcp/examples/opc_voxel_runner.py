#!/usr/bin/env python3
# opc-ourworlds 驱动循环：opc-ourworlds(OpenClaw, GPT-5.5) 当大脑做文字推理，
# 本脚本在宿主机上通过 AgentBridge(TCP 8970) 执行它的决定。
# 额外职责（自愈）：记录它盖过的每座建筑+指纹格，每轮抽查是否被破坏，
# 把"被毁清单"喂给大脑，由它自己决定去重建（眼睛=这里的代码，判断=OpenClaw 提示词）。
import os, socket, json, subprocess, time, re, sys

# 你本地 openclaw.mjs 的路径（用 OPENCLAW_MJS 环境变量覆盖；默认假设在 ~/.openclaw 下）
OC = os.environ.get("OPENCLAW_MJS", os.path.expanduser("~/.openclaw/openclaw.mjs"))
PORT = int(os.environ.get("OW_AGENT_PORT", "8970"))
TICK_SLEEP = 18
MAX_ACTIONS = 6
SAFE_TOOLS = {"goto", "build", "place", "break", "say", "set_goal", "remember", "get_block", "scan", "look"}

built = []        # [{"template","anchor":[x,y,z],"fp":[[x,y,z]...]}]  —— 它盖过的建筑
CHECKS_PER_TICK = 3
HOME = [None, None]   # 出生锚点(x,z)：第一次观测到的位置。所有建造围绕它，禁止远离
HOME_RADIUS = 36      # 只在锚点 ~36 格内活动，确保站在出生点的玩家能亲眼看到它建造

def clamp_home(args):
    if HOME[0] is None:
        return args
    if "x" in args:
        args["x"] = max(HOME[0] - HOME_RADIUS, min(HOME[0] + HOME_RADIUS, int(args["x"])))
    if "z" in args:
        args["z"] = max(HOME[1] - HOME_RADIUS, min(HOME[1] + HOME_RADIUS, int(args["z"])))
    return args

def connect():
    last = None
    for _ in range(400):                      # 耐心等你开游戏(~10分钟)，开了就自动连
        try:
            return socket.create_connection(("127.0.0.1", PORT), timeout=5)
        except OSError as e:
            last = e
            time.sleep(1.5)
    raise last

def make_call(sock_box):
    state = {"buf": b"", "id": 0}
    def call(tool, args=None):
        state["id"] += 1
        sock_box[0].sendall((json.dumps({"id": state["id"], "tool": tool, "args": args or {}}) + "\n").encode())
        while b"\n" not in state["buf"]:
            chunk = sock_box[0].recv(65536)
            if not chunk:
                raise RuntimeError("bridge closed")
            state["buf"] += chunk
        line, state["buf"] = state["buf"].split(b"\n", 1)
        return json.loads(line)
    return call

# 盖完一座后，在 anchor 上方/邻格取最多 6 个实心格作为"这座还在不在"的指纹
def fingerprint(call, x, y, z):
    fp = []
    for dy in range(0, 5):
        for dx, dz in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
            try:
                r = call("get_block", {"x": x + dx, "y": y + dy, "z": z + dz})
            except Exception:
                return fp
            if isinstance(r.get("result"), dict) and r["result"].get("solid"):
                fp.append([x + dx, y + dy, z + dz])
                if len(fp) >= 6:
                    return fp
    return fp

def record_build(call, template, x, y, z):
    fp = fingerprint(call, x, y, z)
    if not fp:
        return
    for b in built:                       # 同 anchor 去重(重建时更新指纹)
        if b["anchor"] == [x, y, z]:
            b["fp"] = fp
            b["template"] = template
            return
    built.append({"template": template, "anchor": [x, y, z], "fp": fp})
    if len(built) > 240:
        built.pop(0)

# 每轮轮询抽查几座，过半指纹格变空气=被破坏
def detect_damage(call, idx):
    dmg = []
    n = len(built)
    if n == 0:
        return dmg, idx
    for _ in range(min(CHECKS_PER_TICK, n)):
        b = built[idx % n]
        idx += 1
        if not b["fp"]:
            continue
        solid = 0
        for c in b["fp"]:
            try:
                r = call("get_block", {"x": c[0], "y": c[1], "z": c[2]})
                if isinstance(r.get("result"), dict) and r["result"].get("solid"):
                    solid += 1
            except Exception:
                solid += 1                # 出错按"还在"算，避免误报
        if solid <= len(b["fp"]) // 2:
            dmg.append({"template": b["template"], "anchor": b["anchor"]})
    return dmg, idx

def think(world, memory, damaged, tick):
    msg = "WORLD:\n" + json.dumps(world, ensure_ascii=False) + "\nMEMORY:\n" + json.dumps(memory, ensure_ascii=False)
    if HOME[0] is not None:
        msg += (f"\nHOME=[{HOME[0]},{HOME[1]}] —— 这是你的城镇中心，人类玩家就站在这附近看着你建造。"
                f"所有 goto/build 必须落在 HOME 的 {HOME_RADIUS} 格半径内，绝对不要走远！"
                f"无视任何'把主路往远处延伸'之类的旧念头，就在 HOME 周围密集地盖，让它越来越热闹。")
    if damaged:
        msg += ("\nDAMAGED (你之前盖的这些被破坏了！最优先去修：对每一个，goto 到它的 anchor，再 build 同样的 template、同样坐标): "
                + json.dumps(damaged, ensure_ascii=False))
    msg += "\nReply with your JSON action array now (JSON only, no prose)."
    # 每轮一个全新会话(用唯一 --to 号码派生 session key)：耐久记忆全在游戏侧(remember/get_memory)，
    # openclaw 会话只当单次草稿纸 —— 上下文永不累积、不溢出、也更稳。大脑=你的订阅账户(Codex/GPT-5.4-mini)。
    p = subprocess.run(
        ["node", OC, "agent", "--agent", "opc-ourworlds",
         "--model", "codex/gpt-5.4-mini",
         "--to", f"+1555{tick % 10000000:07d}",
         "--message", msg, "--timeout", "120"],
        capture_output=True, text=True, timeout=150,
    )
    out = p.stdout + "\n" + p.stderr
    for m in re.finditer(r"\[.*?\]", out, re.DOTALL):
        try:
            arr = json.loads(m.group(0))
            if isinstance(arr, list) and arr and isinstance(arr[0], dict):
                return arr
        except Exception:
            continue
    m = re.search(r"\[.*\]", out, re.DOTALL)
    if m:
        try:
            arr = json.loads(m.group(0))
            if isinstance(arr, list):
                return arr
        except Exception:
            pass
    return []

def main():
    sock_box = [connect()]
    call = make_call(sock_box)
    print("=== opc-ourworlds runner 启动，大脑=订阅账户(codex/gpt-5.4-mini, 每轮新会话)，自愈巡检已开 ===", flush=True)
    tick = 0
    check_idx = 0
    while True:
        tick += 1
        try:
            obs = call("observe").get("result", {})
            mem = call("get_memory").get("result", {})
            damaged, check_idx = detect_damage(call, check_idx)
        except Exception as e:
            print(f"[tick {tick}] 桥异常 {e}，重连…", flush=True)
            time.sleep(4)
            try:
                sock_box[0] = connect()
            except Exception:
                pass
            continue
        if HOME[0] is None and isinstance(obs.get("pos"), list) and len(obs["pos"]) >= 3:
            HOME[0], HOME[1] = int(obs["pos"][0]), int(obs["pos"][2])
            print(f"[tick {tick}] 🏠 锚定城镇中心 HOME=[{HOME[0]},{HOME[1]}]（只在 {HOME_RADIUS} 格内建造）", flush=True)
        if damaged:
            print(f"[tick {tick}] ⚠️ 巡检发现 {len(damaged)} 座被破坏: {damaged}", flush=True)
        print(f"[tick {tick}] 思考中 pos={obs.get('pos')} region={obs.get('region')} 已记录建筑={len(built)}", flush=True)
        try:
            actions = think(obs, mem, damaged, tick)
        except subprocess.TimeoutExpired:
            print(f"[tick {tick}] 模型超时，跳过", flush=True)
            time.sleep(TICK_SLEEP)
            continue
        if not actions:
            print(f"[tick {tick}] 未解析到动作，跳过", flush=True)
            time.sleep(TICK_SLEEP)
            continue
        for a in actions[:MAX_ACTIONS]:
            if not isinstance(a, dict):
                continue
            tool = a.get("tool") or a.get("name") or a.get("action")
            if tool not in SAFE_TOOLS:
                continue
            if isinstance(a.get("args"), dict):
                args = dict(a["args"])
            else:
                args = {k: v for k, v in a.items() if k not in ("tool", "name", "action")}
            if tool in ("goto", "build"):
                args = clamp_home(args)      # 硬护栏：永远不让它走出 HOME 半径
            if tool == "set_goal" and "goal" in args and "text" not in args:
                args["text"] = args.pop("goal")
            if tool in ("say", "remember") and "message" in args and "text" not in args:
                args["text"] = args.pop("message")
            try:
                r = call(tool, args)
                res = r.get("result", r.get("error"))
                print(f"   {tool} {args} -> {res}", flush=True)
                if tool == "build" and isinstance(res, dict) and res.get("changed", 0) > 0 \
                        and all(k in args for k in ("x", "y", "z")):
                    record_build(call, str(args.get("template", "")), int(args["x"]), int(args["y"]), int(args["z"]))
            except Exception as e:
                print(f"   {tool} 执行异常: {e}", flush=True)
        time.sleep(TICK_SLEEP)

if __name__ == "__main__":
    main()
